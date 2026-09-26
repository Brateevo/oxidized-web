#!/usr/bin/env bash
# =============================================================================
#  apply-maps.sh - configure LibreNMS map backend (Yandex/OpenStreetMap)
#
#  Standalone runtime for the map-patch logic that ships inside deploy/install.sh.
#  Run it on ANY existing LibreNMS installation to switch the basemap and the
#  "Map" button next to device coordinates - no installer run required.
#
#  What it patches:
#    * DB config leaflet.tile_url  -> Yandex core-renderer tiles (or removes
#      the override to fall back to LibreNMS stock / OpenStreetMap)
#    * html/js/librenms.js         -> EllipsoidMercator CRS (EPSG:3395) so the
#      Yandex tile grid aligns with markers (stock spherical 3857 shifts it)
#    * resources/views/map/fullscreen.blade.php -> tile_url via @json
#    * FullscreenMapController.php -> fullscreenMap() made public (maps UI)
#    * device overview + geo-map   -> "Map" button target (yandex/google)
#    * librenmsv1.blade.php        -> asset version bump to bust browser cache
#
#  Every edit is idempotent: safe to re-run, survives upstream git pulls.
#
#  Usage:
#    sudo bash deploy/apply-maps.sh [--view openstreetmap|yandex]
#                                   [--link yandex|google]
#                                   [--root /opt/librenms]
#
#    Without flags it asks interactively (defaults: yandex / yandex).
#
#  Requires: root, mysql cli, python3, LibreNMS .env (DB creds) at $LNMS_ROOT.
#  Target: Debian 12 / Ubuntu 22.04 / Ubuntu 24.04.
# =============================================================================
set -Eeuo pipefail

LNMS_ROOT="${LNMS_ROOT:-/opt/librenms}"

C_B=""; C_N=""; C_G=""; C_Y=""; C_R=""; C_BLU=""
log()  { echo -e "${C_G}[maps]${C_N} $*"; }
warn() { echo -e "${C_Y}[warn]${C_N} $*"; }
die()  { echo -e "${C_R}[error]${C_N} $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || { echo "Run as root: sudo bash deploy/apply-maps.sh" >&2; exit 1; }
command -v python3 >/dev/null || die "python3 is required"
command -v mysql  >/dev/null || die "mysql client is required"
[ -d "$LNMS_ROOT/.git" ] || die "LibreNMS checkout not found at $LNMS_ROOT"
[ -s "$LNMS_ROOT/.env" ] || die "LibreNMS .env is missing or empty at $LNMS_ROOT"

# ---- parse args --------------------------------------------------------------
MAP_VIEW="${MAP_VIEW:-}"
MAP_LINK="${MAP_LINK:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --view)  MAP_VIEW="${2:?--view needs openstreetmap|yandex}"; shift 2 ;;
    --link)  MAP_LINK="${2:?--link needs yandex|google}";        shift 2 ;;
    --root)  LNMS_ROOT="${2:?--root needs a path}";              shift 2 ;;
    -h|--help)
      sed -n '2,27p' "$0"; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

# ---- interactive defaults ----------------------------------------------------
[ -n "$MAP_VIEW" ] || MAP_VIEW=yandex
[ -n "$MAP_LINK" ] || MAP_LINK=yandex
if [ -t 0 ]; then
  read -r -p "Подложка карт LibreNMS? (openstreetmap/yandex) [${MAP_VIEW}] " _sel
  [ -n "$_sel" ] && MAP_VIEW="$_sel"
  read -r -p "Сервис кнопки \"Map\" у устройства? (yandex/google) [${MAP_LINK}] " _sel
  [ -n "$_sel" ] && MAP_LINK="$_sel"
fi
case "$MAP_VIEW" in openstreetmap|yandex) ;; *) die "MAP_VIEW must be openstreetmap or yandex";; esac
case "$MAP_LINK" in yandex|google) ;; *) die "MAP_LINK must be yandex or google";; esac

# ---- DB credentials from .env -------------------------------------------------
# dotenv value extraction: KEY="value"; strips surrounding quotes, no source
# (the file may contain non-bash syntax used by other apps).
env_get() {
  grep -m1 "^$1=" "$LNMS_ROOT/.env" | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}
LX_DB_NAME="$(env_get DB_DATABASE)"
LX_DB_USER="$(env_get DB_USERNAME)"
LX_DB_PASS="$(env_get DB_PASSWORD)"
LX_DB_HOST="$(env_get DB_HOST)"
[ -n "$LX_DB_NAME" ] && [ -n "$LX_DB_USER" ] || die "DB_DATABASE / DB_USERNAME missing in $LNMS_ROOT/.env"
LX_DB_HOST="${LX_DB_HOST:-localhost}"
export MYSQL_PWD="$LX_DB_PASS"   # mysql 8.0.24+ / WinAuth warning on -p*

# ---- basemap tile url in DB ----------------------------------------------------
if [ "$MAP_VIEW" = "yandex" ]; then
  YMAP_URL='https://core-renderer-tiles.maps.yandex.net/tiles?l=map&v=21.06.20&x={x}&y={y}&z={z}&scale=1&lang=ru_RU'
  YMAP_JSON="$(printf '%s' "$YMAP_URL" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    || die "could not JSON-encode Yandex tile url"
  mysql --host="$LX_DB_HOST" --user="$LX_DB_USER" "$LX_DB_NAME" \
    -e "INSERT INTO config (config_name, config_value) VALUES ('leaflet.tile_url', '${YMAP_JSON}') ON DUPLICATE KEY UPDATE config_value=VALUES(config_value);" \
    || die "could not set leaflet.tile_url in LibreNMS config"
  log "leaflet.tile_url -> Yandex basemap"
else
  mysql --host="$LX_DB_HOST" --user="$LX_DB_USER" "$LX_DB_NAME" \
    -e "DELETE FROM config WHERE config_name='leaflet.tile_url';" \
    || die "could not clear leaflet.tile_url in LibreNMS config"
  log "leaflet.tile_url override removed (OpenStreetMap)"
fi

# ---- file patches --------------------------------------------------------------
export LNMS_ROOT MAP_VIEW MAP_LINK
python3 - <<'PYEOF'
import os, re

ROOT = os.environ["LNMS_ROOT"]
MAP_VIEW = os.environ.get("MAP_VIEW", "yandex")
MAP_LINK = os.environ.get("MAP_LINK", "yandex")

def status(msg):
    print("  map-patch:", msg, flush=True)

def write_file(path, data):
    st = os.stat(path)
    tmp = path + ".map.tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(data)
    os.chmod(tmp, st.st_mode & 0o7777)
    os.replace(tmp, path)
    os.chown(path, st.st_uid, st.st_gid)

def swap_once(path, old, new, label):
    data = open(path, encoding="utf-8").read()
    if new in data:
        return
    n = data.count(old)
    assert n == 1, (path, label, "anchor count", n)
    status("%s: %s" % (label, path.split("/")[-1]))
    write_file(path, data.replace(old, new, 1))

# CRS fix for Yandex basemap (stock librenms.js kept for openstreetmap)
if MAP_VIEW == "yandex":
    js = os.path.join(ROOT, "html/js/librenms.js")
    src = open(js, encoding="utf-8").read()

    crs_block = """
// Yandex core-renderer tiles are in ellipsoidal Mercator (EPSG:3395), but Leaflet
// normally assumes spherical web Mercator (EPSG:3857). The mismatch shifts the tile
// grid by a few kilometres (up to ~0.18 degrees of latitude). Use a custom CRS so
// tiles, markers and coordinates stay aligned.
L.Projection.EllipsoidMercator = {
    R: 6378137.0,
    E: 0.0818191908426214943348,
    project: function (latlng) {
        var d = Math.PI / 180,
            e = this.E, R = this.R,
            lat = latlng.lat * d, lon = latlng.lng * d,
            s = Math.sin(lat),
            factor = Math.pow((1 - e * s) / (1 + e * s), e / 2);
        return new L.Point(R * lon, R * (Math.log(Math.tan(Math.PI / 4 + lat / 2)) + Math.log(factor)));
    },
    unproject: function (point) {
        var d = Math.PI / 180,
            e = this.E, R = this.R,
            y = point.y, lon = point.x / R / d,
            phi = 0;
        for (var i = 0; i < 10; i++) {
            var s = Math.sin(phi),
                factor = Math.pow((1 - e * s) / (1 + e * s), e / 2);
            phi = 2 * Math.atan(Math.exp(y / R) / factor) - Math.PI / 2;
        }
        return new L.LatLng(phi / d, lon);
    }
};

L.CRS.EPSG3395 = L.extend({}, L.CRS.EPSG3857, {
    code: 'EPSG:3395',
    projection: L.Projection.EllipsoidMercator
});
"""

    changed = False
    if "L.CRS.EPSG3395" not in src:
        anchor = "\nfunction init_map(id, config = {}) {"
        assert src.count(anchor) == 1, "init_map anchor not unique"
        src = src.replace(anchor, crs_block + anchor, 1)
        changed = True

    if "const map_crs" not in src:
        map_crs = "    const map_crs = (config.tile_url && /core-renderer-tiles\\.maps\\.yandex\\.net/i.test(build_tile_url(config.tile_url))) ? L.CRS.EPSG3395 : L.CRS.EPSG3857;"
        anchor = "    leaflet = L.map(id, {\n"
        assert src.count(anchor) == 1, "L.map anchor not unique"
        src = src.replace(anchor, map_crs + "\n" + anchor + "        crs: map_crs,\n", 1)
        changed = True

    # drop the stock "Leaflet" attribution prefix + replace the OSM label in the
    # tile layer with a Russian flag + "Яндекс" caption
    if "setPrefix" not in src:
        anchor = "    window.maps[id] = leaflet;\n"
        assert src.count(anchor) == 1, "attribution prefix anchor"
        src = src.replace(anchor, anchor + "    if (leaflet.attributionControl) { leaflet.attributionControl.setPrefix(''); }\n", 1)
        changed = True

    attribution_old = "            attribution: '&copy; <a href=\"http://www.openstreetmap.org/copyright\">OpenStreetMap</a>'"
    attribution_new = "            attribution: '<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"18\" height=\"12\" viewBox=\"0 0 18 12\" style=\"vertical-align:-2px\"><rect width=\"18\" height=\"4\" fill=\"white\"/><rect y=\"4\" width=\"18\" height=\"4\" fill=\"#0039A6\"/><rect y=\"8\" width=\"18\" height=\"4\" fill=\"#D52B1E\"/></svg> Яндекс'"
    if attribution_old in src:
        src = src.replace(attribution_old, attribution_new, 1)
        changed = True

    if changed:
        status("librenms.js: applying Yandex EPSG3395 CRS patch")
        if "L.CRS.EPSG3395" not in src:
            raise SystemExit("librenms.js CRS block missing after patch")
        write_file(js, src)
else:
    # revert a previously applied Yandex JS patch back to the stock file
    js = os.path.join(ROOT, "html/js/librenms.js")
    src = open(js, encoding="utf-8").read()
    changed = False
    if "L.CRS.EPSG3395" in src:
        m = re.search(r"\n// Yandex core-renderer tiles.*?L\.CRS\.EPSG3395 = L\.extend\(.*?\n\}\);\s*", src, re.S)
        assert m, "librenms.js EPSG3395 block not found, cannot revert"
        src = src.replace(m.group(0), "\n", 1)
        changed = True
    map_crs = "    const map_crs = (config.tile_url && /core-renderer-tiles\\.maps\\.yandex\\.net/i.test(build_tile_url(config.tile_url))) ? L.CRS.EPSG3395 : L.CRS.EPSG3857;\n"
    crs_line = "        crs: map_crs,\n"
    prefix_line = "    if (leaflet.attributionControl) { leaflet.attributionControl.setPrefix(''); }\n"
    for frag in (map_crs, crs_line, prefix_line):
        if frag in src:
            src = src.replace(frag, "", 1)
            changed = True
    attribution_old = "            attribution: '&copy; <a href=\"http://www.openstreetmap.org/copyright\">OpenStreetMap</a>'"
    attribution_new = "            attribution: '<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"18\" height=\"12\" viewBox=\"0 0 18 12\" style=\"vertical-align:-2px\"><rect width=\"18\" height=\"4\" fill=\"white\"/><rect y=\"4\" width=\"18\" height=\"4\" fill=\"#0039A6\"/><rect y=\"8\" width=\"18\" height=\"4\" fill=\"#D52B1E\"/></svg> Яндекс'"
    if attribution_new in src:
        src = src.replace(attribution_new, attribution_old, 1)
        changed = True
    if changed:
        status("librenms.js: reverting Yandex EPSG3395 patch")
        write_file(js, src)

# tile_url must reach the JS config safely in both modes
fb = os.path.join(ROOT, "resources/views/map/fullscreen.blade.php")
data = open(fb, encoding="utf-8").read()
if "@json($tile_url)" not in data:
    old = '"tile_url": "{{$tile_url}}"'
    new = '"tile_url": @json($tile_url)'
    assert data.count(old) == 1, "fullscreen tile_url anchor"
    status("fullscreen.blade.php: tile_url via @json")
    write_file(fb, data.replace(old, new, 1))

# route method must be callable by the maps UI in both modes
ctrl = os.path.join(ROOT, "app/Http/Controllers/Maps/FullscreenMapController.php")
data = open(ctrl, encoding="utf-8").read()
if "public function fullscreenMap" not in data:
    old = "    protected function fullscreenMap(Request $request): View|RedirectResponse"
    new = "    public function fullscreenMap(Request $request): View|RedirectResponse"
    assert data.count(old) == 1, "controller anchor"
    status("FullscreenMapController: method public")
    write_file(ctrl, data.replace(old, new, 1))

# "Map" button target: static link (device overview) + draggable-marker handler
static_google = "https://maps.google.com/?q={{ $device->location->lat }},{{ $device->location->lng }}"
static_yandex = "https://yandex.ru/maps/?ll={{ $device->location->lng }},{{ $device->location->lat }}&pt={{ $device->location->lng }},{{ $device->location->lat }}&z=17&l=map"
js_google = '"https://maps.google.com/?q=" + new_location.lat + "," + new_location.lng'
js_yandex = '"https://yandex.ru/maps/?ll=" + new_location.lng + "," + new_location.lat + "&pt=" + new_location.lng + "," + new_location.lat + "&z=17&l=map"'
sysv = os.path.join(ROOT, "resources/views/components/device/overview/system.blade.php")
gm = os.path.join(ROOT, "resources/views/components/geo-map.blade.php")
if MAP_LINK == "yandex":
    swap_once(sysv, static_google, static_yandex, "Map link -> Yandex")
    swap_once(gm, js_google, js_yandex, "Map link -> Yandex")
else:
    swap_once(sysv, static_yandex, static_google, "Map link -> Google")
    swap_once(gm, js_yandex, js_google, "Map link -> Google")

# only the Yandex basemap changes librenms.js, so bump its asset version then
if MAP_VIEW == "yandex":
    lay = os.path.join(ROOT, "resources/views/layouts/librenmsv1.blade.php")
    data = open(lay, encoding="utf-8").read()
    if "librenms.js?ver=20260925-yandex" not in data:
        new, n = re.subn(r"js/librenms\.js\?ver=[A-Za-z0-9_.-]*",
                         "js/librenms.js?ver=20260925-yandex", data, count=1)
        assert n == 1, "librenmsv1 asset anchor"
        status("librenmsv1.blade.php: librenms.js asset version bumped")
        write_file(lay, new)

print("  map-patch: DONE", flush=True)
PYEOF

# ---- reset caches so file + DB changes are picked up immediately --------------
# pick the app user from resources ownership (files were re-written by write_file
# with their original owner preserved, so this also matches the .env owner)
LNMS_USER="$(stat -c '%U' "$LNMS_ROOT/resources" 2>/dev/null || echo librenms)"
[ "$LNMS_USER" = root ] && LNMS_USER="$(stat -c '%U' "$LNMS_ROOT/.env" 2>/dev/null || echo librenms)"
id "$LNMS_USER" >/dev/null 2>&1 || LNMS_USER=librenms
su -s /bin/bash "$LNMS_USER" -c "cd '$LNMS_ROOT' && php artisan view:clear && php artisan cache:clear && php lnms config:clear" >/dev/null 2>&1 \
  || warn "could not rebuild LibreNMS caches (artisan as $LNMS_USER failed); run manually: php artisan view:clear; php artisan cache:clear; php lnms config:clear"

log "map setup installed: view=${MAP_VIEW}, Map link=${MAP_LINK}"