#!/usr/bin/env bash
# =============================================================================
#  install.sh - ONE-SHOT DEPLOY of the full stack on a bare Linux server
#
#  Stack installed (mirrors the production reference):
#    * LibreNMS   - network/inventory monitoring  (git install, /opt/librenms)
#    * MariaDB    - backend for LibreNMS + dedicated app read account
#    * Oxidized   - config backup daemon (Ruby), REST API on 127.0.0.1:8888,
#                   device list pulled FROM LibreNMS REST API /api/v0/oxidized
#    * oxidized-web - custom PHP front end on port 8889 (this repo)
#    * nginx + php-fpm (two pools), rrdtool, redis, snmp
#
#  Target: Debian 12 / Ubuntu 22.04 / Ubuntu 24.04 (amd64).
#  Run as root:   sudo bash deploy/install.sh
#  INTERACTIVE: the script asks for every value below (default shown in [..]).
#               Empty password = random generation.
#               Last questions: SSH login/password (and optional ENABLE secret)
#               Oxidized uses to read device configs, then map choices:
#               basemap (openstreetmap/yandex) and the "Map" link service
#               (yandex/google) next to device coordinates in LibreNMS.
#  Idempotent: rerun reapplies migrations/config and validates the stack.
# =============================================================================
set -Eeuo pipefail
umask 077

C_B=""; C_N=""; C_G=""; C_Y=""; C_R=""; C_BLU=""
log()  { echo -e "${C_G}[install]${C_N} $*"; }
warn() { echo -e "${C_Y}[warn]${C_N} $*"; }
die()  { echo -e "${C_R}[error]${C_N} $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || { echo "Run as root: sudo bash deploy/install.sh" >&2; exit 1; }
command -v apt-get >/dev/null || die "This script targets Debian/Ubuntu (apt-get)."
# Log only location/status, never BASH_COMMAND (it may contain credentials).
ERR_LOG="$(mktemp /var/log/oxidized-web-install.XXXXXX)"
chmod 600 "$ERR_LOG"
CURRENT_PHASE="preflight"
trap 'es=$?; if [ "$es" -ne 0 ]; then printf ">> install.sh FAILED phase=%s at %s:%s, status=%s\n" "$CURRENT_PHASE" "${BASH_SOURCE[0]}" "${LINENO}" "$es" >> "$ERR_LOG"; fi' EXIT
log "Failure diagnostics (no command/secret values): ${ERR_LOG}"
. /etc/os-release
case "${ID}:${VERSION_ID}" in
    ubuntu:22.04|ubuntu:24.04|debian:12) ;;
    *) die "Unsupported OS ${PRETTY_NAME:-${ID} ${VERSION_ID}}. Supported: Debian 12, Ubuntu 22.04/24.04." ;;
esac
[ "$(dpkg --print-architecture)" = amd64 ] || die "Only amd64 is supported."

ROOTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo checkout

# The script needs the whole repo (nginx templates + PHP app sources), so
# running it from a partial copy must fail before writing secrets or packages.
for need in \
    deploy/templates/nginx-librenms.conf \
    deploy/templates/nginx-oxidized-web.conf \
    deploy/asustor-defs/resources/definitions/os_detection/asustor.yaml \
    deploy/asustor-defs/resources/definitions/os_discovery/asustor.yaml \
    deploy/asustor-defs/mibs/asustor/ASUSTOR-SYSTEM-MIB.txt \
    deploy/asustor-defs/html/images/os/asustor.svg \
    public/index.php \
    src; do
    [ -e "${ROOTDIR}/${need}" ] || die "missing ${ROOTDIR}/${need} - copy the whole oxidized-web repo, not just install.sh"
done
APP_DIR="/opt/oxidized-web"

# colours are optional under a non-tty shell.
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    C_B=$(tput bold); C_N=$(tput sgr0); C_G=$(tput setaf 2); C_Y=$(tput setaf 3); C_R=$(tput setaf 1); C_BLU=$(tput setaf 4)
fi

ask() { # ask "<prompt>" <varname> [default]
    local prompt="$1" var="$2" def="${3:-}" val
    # automated/redirected reruns (no tty) reuse values already loaded from
    # /root/oxidized-web-deploy.secrets instead of pestering for input
    if [ ! -t 0 ] && [ -n "${!var:-}" ]; then return; fi
    val=""
    # EOF-safe: read returns 1 at end of input, which set -e must not treat as fatal
    read -r -p "${C_B}${C_BLU}${prompt}${C_N} ${def:+[$def] }" val || true
    printf -v "$var" '%s' "${val:-$def}"
}

ask_choice() { # ask_choice "<prompt>" <varname> "<choice1/choice2>" <default>
    local prompt="$1" var="$2" choices="$3" def="${4:-}" val
    # automated/redirected reruns (no tty) reuse loaded secrets
    if [ ! -t 0 ] && [ -n "${!var:-}" ]; then return; fi
    while :; do
        read -r -p "${C_B}${C_BLU}${prompt}${C_N} (${choices}) [${def}] " val || true
        val="${val:-$def}"
        case "/${choices}/" in
            */"$val"/*) printf -v "$var" '%s' "$val"; return;;
            *) warn "Допустимые значения: ${choices} (введено: ${val})";;
        esac
    done
}

ask_pass() { # ask_pass "<prompt>" <varname> <default> [minlen]
    local prompt="$1" var="$2" def="$3" minlen="${4:-0}" p1 p2
    if [ ! -t 0 ] && [ -n "${!var:-}" ]; then return; fi
    while :; do
        p1=""
        read -r -s -p "${C_B}${C_BLU}${prompt}${C_N} (пусто = сгенерировать) " || true
        p1="$REPLY"; echo
        if [ -z "$p1" ]; then
            p1="$def"
            printf -v "$var" '%s' "$p1"
            return
        fi
        case "$p1" in *"'"*) warn "Пароль не должен содержать апостроф (')."; continue;; esac
        if [ "$minlen" -gt 0 ] && [ "${#p1}" -lt "$minlen" ]; then
            warn "Минимум ${minlen} символов в пароле."
            continue
        fi
        p2=""
        read -r -s -p "${C_B}${C_BLU}  повторите:${C_N} " || true
        p2="$REPLY"; echo
        [ "$p1" = "$p2" ] && { printf -v "$var" '%s' "$p1"; return; }
        warn "Пароли не совпадают, попробуйте ещё раз."
        # no tty (automated run): a mismatch would loop forever on EOF -> fall back
        [ ! -t 0 ] || continue
        printf -v "$var" '%s' "$def"
        return
    done
}

# ------------------------------------------------------------------ wizard ---
echo -e "${C_B}${C_BLU}═══ Настройка стека (Enter = значение по умолчанию) ═══${C_N}"

# Reuse credentials/settings from a previous run so a rerun never churns the
# DB passwords (the running stack keeps the old values, so keeping defaults
# stable is what makes "rebuild after failure" honest).
if [ -e /root/oxidized-web-deploy.secrets ]; then
  [ -f /root/oxidized-web-deploy.secrets ] || die "secrets path is not a regular file"
  [ "$(stat -c %u /root/oxidized-web-deploy.secrets)" = 0 ] || die "secrets file must be owned by root"
  [ "$(stat -c %a /root/oxidized-web-deploy.secrets)" = 600 ] || die "secrets file must have mode 600"
  # shellcheck source=/dev/null
  . /root/oxidized-web-deploy.secrets
elif [ -e /opt/oxidized-web/data/oxidized.db ] || [ -e /opt/librenms/.env ]; then
  die "existing installation found but /root/oxidized-web-deploy.secrets is missing; restore it before rerunning to avoid credential drift"
fi

# --- generate any still-missing secrets NOW, before the asks -----------------
# A command substitution that fails inside a function argument silently
# degrades to an EMPTY string, so an automated/non-tty run could end up with
# empty passwords in /root/oxidized-web-deploy.secrets (seen live: all four
# password defaults came back empty because openssl is NOT installed on a bare
# box - phase 0 installs it later). gen_secret prefers openssl and falls back
# to /dev/urandom (od is in coreutils, always present); the guard below turns
# any remaining empty secret into a loud error rather than an insecure install.
gen_secret() {
    local n="$1" out=""
    if command -v openssl >/dev/null 2>&1; then
        out="$(openssl rand -hex "$n" 2>/dev/null || true)"
    fi
    [ -n "$out" ] || out="$(od -An -N"$n" -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || true)"
    printf '%s' "$out"
}
LX_DB_PASS="${LX_DB_PASS:-$(gen_secret 16)}"
APP_DB_PASS="${APP_DB_PASS:-$(gen_secret 16)}"
LX_ADMIN_PASS="${LX_ADMIN_PASS:-$(gen_secret 10)}"
OX_WEB_ADMIN_PASS="${OX_WEB_ADMIN_PASS:-$(gen_secret 10)}"

LX_DB_NAME="${LX_DB_NAME:-librenms}"
ask "Имя БД LibreNMS?"            LX_DB_NAME       "librenms"
ask "MySQL-логин для LibreNMS?"   LX_DB_USER       "librenms"
ask_pass "Пароль MySQL-пользователя '${LX_DB_USER}':" LX_DB_PASS "$LX_DB_PASS"

APP_DB_USER="${APP_DB_USER:-oxidized_web}"
ask "MySQL-аккаунт для oxidized-web (read-only)?" APP_DB_USER "oxidized_web"
ask_pass "Пароль MySQL-пользователя '${APP_DB_USER}':" APP_DB_PASS "$APP_DB_PASS"

ask_pass "Пароль админа LibreNMS (web):"  LX_ADMIN_PASS   "$LX_ADMIN_PASS" 8
ask "Логин админа LibreNMS (web)?"        LX_ADMIN_USER   "admin"
ask "Email админа LibreNMS?"              LX_ADMIN_EMAIL  "admin@localhost"

ask_pass "Пароль админа oxidized-web:"    OX_WEB_ADMIN_PASS "$OX_WEB_ADMIN_PASS" 8
ask "Логин админа oxidized-web?"          OX_WEB_ADMIN_USER "admin"

## ---- nginx / слушатели -----------------------------------------------------
DEFAULT_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
ask "IP/домен LibreNMS (nginx listen+server_name)?" LX_SITE_FQDN "${LX_SITE_FQDN:-$DEFAULT_IP}"
ask "Порт LibreNMS nginx?"               LX_SITE_PORT    "80"
ask "IP/домен oxidized-web?"             OXWEB_FQDN      "${OXWEB_FQDN:-${LX_SITE_FQDN}}"
ask "Порт oxidized-web nginx?"           OXWEB_PORT      "8889"
ask "Oxidized REST host (bind)?"         OX_HOST         "127.0.0.1"
ask "Oxidized REST порт?"                OX_PORT         "8888"
ask "Группа Oxidized по умолчанию?"      LX_DEFAULT_GROUP "default"
ask "SSH-логин для чтения конфигов (Oxidized)?" OX_DV_USER "${OX_DV_USER:-oxidized}"
OX_DV_PASS="${OX_DV_PASS:-$(gen_secret 16)}"
ask_pass "Пароль устройства для Oxidized (SSH/telnet):" OX_DV_PASS "$OX_DV_PASS"
ask_pass "ENABLE-пароль устройства (опционально):"      OX_ENABLE   "${OX_ENABLE:-}"

# Карты LibreNMS: подложка (обратите внимание, Яндекс использует свой тайловый
# сервер, OSM - публичные тайлы) и сервис для кнопки "Map" у координат устройства.
LX_MAP_VIEW="${LX_MAP_VIEW:-yandex}"
ask_choice "Подложка карт LibreNMS?"      LX_MAP_VIEW  "openstreetmap/yandex" "$LX_MAP_VIEW"
LX_MAP_LINK="${LX_MAP_LINK:-yandex}"
ask_choice "Сервис кнопки \"Map\" у устройства?"  LX_MAP_LINK  "yandex/google" "$LX_MAP_LINK"

APP_URL_DEFAULT="http://${LX_SITE_FQDN}"
[ "${LX_SITE_PORT}" = "80" ] || APP_URL_DEFAULT="http://${LX_SITE_FQDN}:${LX_SITE_PORT}"
ask "FQDN для исходящих ссылок LibreNMS (base_url)?" LX_APP_URL "${LX_APP_URL:-$APP_URL_DEFAULT}"

# Values are embedded in SQL, YAML, URLs, and generated PHP. Restrict them to
# deliberately supported characters rather than risking broken config/injection.
valid_ident() { [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]; }
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_secret() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._@%+=,:!/-]*$ ]]; }
valid_host() {
  local host="$1" label octet
  [[ "$host" =~ ^[A-Za-z0-9.-]+$ && "$host" != .* && "$host" != *. && "$host" != *..* ]] || return 1
  IFS=. read -r -a labels <<< "$host"
  for label in "${labels[@]}"; do
    [ ${#label} -le 63 ] && [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
  if [[ "$host" =~ ^[0-9.]+$ ]]; then
    [ "${#labels[@]}" -eq 4 ] || return 1
    for octet in "${labels[@]}"; do
      [[ "$octet" =~ ^[0-9]{1,3}$ ]] && [ "$octet" -le 255 ] || return 1
    done
  fi
}
valid_email() { [[ "$1" = "admin@localhost" || "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }
nginx_listen_addr() { [[ "$1" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && printf '%s' "$1" || printf '0.0.0.0'; }
valid_ident "$LX_DB_NAME" && valid_ident "$LX_DB_USER" && valid_ident "$APP_DB_USER" || die "DB names/users may contain only letters, digits, underscore."
[ "$LX_DB_USER" != "$APP_DB_USER" ] || die "LibreNMS and oxidized-web must use separate MySQL accounts."
[[ "$LX_DB_USER" != root && "$APP_DB_USER" != root ]] || die "Do not use the MariaDB root account for applications."
valid_ident "$LX_ADMIN_USER" && valid_ident "$OX_WEB_ADMIN_USER" && valid_ident "$OX_DV_USER" || die "User names may contain only letters, digits, underscore."
valid_email "$LX_ADMIN_EMAIL" || die "Invalid LibreNMS admin email address."
valid_host "$LX_SITE_FQDN" && valid_host "$OXWEB_FQDN" || die "IP/domain must contain only a hostname or IPv4 address."
valid_port "$LX_SITE_PORT" && valid_port "$OXWEB_PORT" && valid_port "$OX_PORT" || die "Ports must be integers from 1 to 65535."
[ "$LX_SITE_PORT" != "$OXWEB_PORT" ] && [ "$LX_SITE_PORT" != "$OX_PORT" ] && [ "$OXWEB_PORT" != "$OX_PORT" ] || die "LibreNMS, oxidized-web and Oxidized must use different ports."
[[ "$OX_HOST" = 127.0.0.1 || "$OX_HOST" = localhost ]] || die "Oxidized REST is unauthenticated; it must bind only to 127.0.0.1 or localhost."
[[ "$LX_DEFAULT_GROUP" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Oxidized default group may contain only letters, digits, dot, underscore, and hyphen."
case "$LX_MAP_VIEW" in openstreetmap|yandex) ;; *) die "LX_MAP_VIEW must be openstreetmap or yandex";; esac
case "$LX_MAP_LINK" in yandex|google) ;; *) die "LX_MAP_LINK must be yandex or google";; esac
if [[ "$LX_APP_URL" =~ ^https?://([^/:]+)(:([0-9]{1,5}))?/?$ ]]; then
  APP_URL_HOST="${BASH_REMATCH[1]}"
  APP_URL_PORT="${BASH_REMATCH[3]:-}"
  valid_host "$APP_URL_HOST" || die "Invalid hostname in LibreNMS base URL."
  [ -z "$APP_URL_PORT" ] || valid_port "$APP_URL_PORT" || die "Invalid port in LibreNMS base URL."
else
  die "LibreNMS base URL must be http(s)://hostname[:port]."
fi
LX_LISTEN_ADDR="$(nginx_listen_addr "$LX_SITE_FQDN")"
OXWEB_LISTEN_ADDR="$(nginx_listen_addr "$OXWEB_FQDN")"
for v in LX_DB_PASS APP_DB_PASS LX_ADMIN_PASS OX_WEB_ADMIN_PASS OX_DV_PASS; do
  valid_secret "${!v}" || die "${v} contains unsupported characters; use letters, digits, and . _ @ % + = , : ! / -"
done
[ -z "$OX_ENABLE" ] || valid_secret "$OX_ENABLE" || die "ENABLE password contains unsupported characters."
[[ ${#LX_ADMIN_PASS} -ge 8 && ${#OX_WEB_ADMIN_PASS} -ge 8 ]] || die "LibreNMS and oxidized-web admin passwords must be at least 8 characters."

# every generated secret MUST be non-empty at this point - an empty LX_DB_PASS
# or OX_WEB_ADMIN_PASS would silently yield an insecure install
for v in LX_DB_PASS APP_DB_PASS LX_ADMIN_PASS OX_WEB_ADMIN_PASS OX_DV_PASS; do
  [ -n "${!v}" ] || die "секреты не сгенерировались (пустое значение ${v}) - проверьте openssl, затем перезапустите установку"
done

warn "Значения приняты. Установка начнётся. Пароли при необходимости сохранит в /root/oxidized-web-deploy.secrets"
{
  printf 'LX_DB_NAME=%q\nLX_DB_USER=%q\nLX_DB_PASS=%q\n' "$LX_DB_NAME" "$LX_DB_USER" "$LX_DB_PASS"
  printf 'APP_DB_USER=%q\nAPP_DB_PASS=%q\nLX_ADMIN_USER=%q\nLX_ADMIN_PASS=%q\nLX_ADMIN_EMAIL=%q\n' "$APP_DB_USER" "$APP_DB_PASS" "$LX_ADMIN_USER" "$LX_ADMIN_PASS" "$LX_ADMIN_EMAIL"
  printf 'OX_WEB_ADMIN_USER=%q\nOX_WEB_ADMIN_PASS=%q\nLX_SITE_FQDN=%q\nLX_SITE_PORT=%q\n' "$OX_WEB_ADMIN_USER" "$OX_WEB_ADMIN_PASS" "$LX_SITE_FQDN" "$LX_SITE_PORT"
  printf 'OXWEB_FQDN=%q\nOXWEB_PORT=%q\nOX_HOST=%q\nOX_PORT=%q\nLX_DEFAULT_GROUP=%q\n' "$OXWEB_FQDN" "$OXWEB_PORT" "$OX_HOST" "$OX_PORT" "$LX_DEFAULT_GROUP"
  printf 'LX_APP_URL=%q\nOX_DV_USER=%q\nOX_DV_PASS=%q\nOX_ENABLE=%q\n' "$LX_APP_URL" "$OX_DV_USER" "$OX_DV_PASS" "$OX_ENABLE"
  printf 'LX_MAP_VIEW=%q\nLX_MAP_LINK=%q\n' "$LX_MAP_VIEW" "$LX_MAP_LINK"
} > /root/oxidized-web-deploy.secrets
chmod 600 /root/oxidized-web-deploy.secrets

# =============================================================================
log "== Phase 0: base packages ==============================================="
CURRENT_PHASE="phase 0: packages and PHP"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget git snmp snmpd rrdtool whois net-tools unzip \
    software-properties-common ca-certificates openssl redis-server cron \
    nginx mariadb-server mariadb-client \
    python3 python3-pip python3-mysqldb python3-dotenv python3-paramiko \
    composer
# ruby + native-devel for the oxidized (rugged/libgit2) gem build.
# rugged vendors libgit2 and builds it with cmake; libssh2/libcurl are needed
# for the SSH/HTTPS transports. Missing any of these -> "ERROR: Failed to build
# gem native extension" when installing the oxidized gem.
apt-get install -y ruby ruby-dev build-essential cmake pkg-config zlib1g-dev \
    libsqlite3-dev libssl-dev libssh2-1-dev libcurl4-openssl-dev
# fping: LibreNMS availability/ping checks (DeviceIsPingable) exec it; without
# it every device is "Could not ping" and gets added as down.
# libicu-dev: builds charlock_holmes, a native dep of the oxidized-web gem
# (Oxidized >=0.35 moved its REST API from "rest:" to the oxidized-web gem).
apt-get install -y fping libicu-dev

# --- newest PHP (LibreNMS web requires >= 8.5) ---------------------------------
# Official LibreNMS docs require PHP 8.5 minimum. Ubuntu 24.04 itself only ships
# PHP 8.3, so we add the sury.org PPA (ppa:ondrej/php) to get 8.5+ lines and pick
# the greatest php<X.Y> version >= 8.5 whose FULL module set is available in apt.
# A brand-new PHP line often lags a couple of modules (php-redis is usually the
# last one to be rebuilt), so "newest" is tried first and we step back one line
# until a complete set >= 8.5 is found. If the PPA is unreachable and no complete
# PHP >= 8.5 exists we abort - LibreNMS web will NOT run on PHP < 8.5.
# Debian uses packages.sury.org; Ubuntu uses the Ondrej PHP PPA.
if [ "$ID" = ubuntu ]; then
  add-apt-repository -y ppa:ondrej/php || die "could not add ppa:ondrej/php"
else
  apt-get install -y apt-transport-https
  curl -fsSLo /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb
  dpkg -i /tmp/debsuryorg-archive-keyring.deb
  printf 'deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ %s main\n' "$VERSION_CODENAME" > /etc/apt/sources.list.d/php.list
fi
apt-get update -y
PHP_MODULES="fpm cli mysql curl gd gmp xml mbstring sqlite3 redis bcmath intl zip snmp"
PHP_VER=""
while IFS= read -r cand; do
  ver="${cand#php}"
  # skip lines below PHP 8.5 (LibreNMS web requirements)
  if echo "$ver" | awk -F. '{exit ($1 > 8 || ($1 == 8 && $2 >= 5)) ? 1 : 0}'; then
    continue
  fi
  missing=""
  for mod in $PHP_MODULES; do
    apt-cache show "php${ver}-${mod}" >/dev/null 2>&1 || missing="$missing ${mod}"
  done
  if [ -z "$missing" ]; then
    PHP_VER="$ver"
    break
  fi
  warn "PHP ${ver}: modules not built yet:$missing - stepping back one line"
done < <(apt-cache search '^php[0-9]+\.[0-9]+-fpm$' 2>/dev/null | sed 's/-fpm.*//' | sort -Vr)
if [ -z "$PHP_VER" ]; then
  die "no complete PHP >= 8.5 found - LibreNMS web requires PHP 8.5+; verify the configured PHP repository"
fi
PHP_FPM_BIN="php-fpm${PHP_VER}"
SYSTEM_DEFAULT_PHP_SOCK="/run/php/php${PHP_VER}-fpm.sock"
PHP_PKGS=""
for mod in $PHP_MODULES; do PHP_PKGS="$PHP_PKGS php${PHP_VER}-${mod}"; done
log "Using PHP: ${PHP_VER} (${PHP_FPM_BIN})"
apt-get install -y $PHP_PKGS
command -v "$PHP_FPM_BIN" >/dev/null || die "${PHP_FPM_BIN} was not installed"
for ext in curl gd gmp intl mbstring mysqli pdo_mysql pdo_sqlite redis snmp sqlite3 xml zip; do
  php${PHP_VER} -m | tr '[:upper:]' '[:lower:]' | grep -qx "$ext" || die "PHP ${PHP_VER} extension missing after package install: ${ext}"
done
# The META packages pulled in by other deps (e.g. apt 'composer' -> php-cli)
# register the plain "php" alternative to the newest *meta* line, which may be
# a newer line WITHOUT our drivers (pdo_mysql/pdo_sqlite/redis), so unversioned
# "php" calls (artisan, php -r) would die with "could not find driver".
# Pin the alternatives to OUR version so every "php" invocation uses the full
# module set we installed above.
if [ -x "/usr/bin/php${PHP_VER}" ] && command -v update-alternatives >/dev/null 2>&1; then
  update-alternatives --set php "/usr/bin/php${PHP_VER}"
  update-alternatives --set phar "/usr/bin/phar${PHP_VER}"
  log "forced /usr/bin/php -> php${PHP_VER}"
fi
php -r 'exit((PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION) === $argv[1] ? 0 : 1);' "$PHP_VER" || die "CLI PHP version does not match installed FPM PHP ${PHP_VER}"

# =============================================================================
log "== Phase 1: MariaDB - databases and accounts ============================"
CURRENT_PHASE="phase 1: MariaDB"
systemctl enable --now mariadb redis-server
for attempt in $(seq 1 30); do
  mysqladmin ping --silent >/dev/null 2>&1 && break
  [ "$attempt" -lt 30 ] || die "MariaDB did not become ready (see journalctl -u mariadb)"
  sleep 2
done

# --- LibreNMS main db + user ---
mysql -e "CREATE DATABASE IF NOT EXISTS \`${LX_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null
mysql -e "CREATE USER IF NOT EXISTS '${LX_DB_USER}'@'localhost' IDENTIFIED BY '${LX_DB_PASS}';"
mysql -e "ALTER USER '${LX_DB_USER}'@'localhost' IDENTIFIED BY '${LX_DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON \`${LX_DB_NAME}\`.* TO '${LX_DB_USER}'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# --- read-only account for oxidized-web (devices + locations) ---
# Drop legacy broader accounts created by older installer versions.
mysql -e "DROP USER IF EXISTS '${APP_DB_USER}'@'localhost', '${APP_DB_USER}'@'%';"
mysql -e "DROP USER IF EXISTS '${APP_DB_USER}'@'127.0.0.1';"
mysql -e "CREATE USER '${APP_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${APP_DB_PASS}';"

# =============================================================================
log "== Phase 2: LibreNMS (git install into /opt/librenms) ==================="
CURRENT_PHASE="phase 2: LibreNMS"
id librenms >/dev/null 2>&1 || useradd -r -M -d /opt/librenms -s /bin/bash librenms
if [ ! -d /opt/librenms/.git ]; then
  git clone https://github.com/librenms/librenms.git /opt/librenms 2>/dev/null || \
    die "git clone of librenms failed"
  # .env with generated credentials (write BEFORE composer so artisan can work)
  # APP_KEY is baked in here - "artisan key:generate" fails on a fresh .env and
  # is not needed at all.
  cat > /opt/librenms/.env <<EOF
APP_NAME=LibreNMS
APP_ENV=production
APP_DEBUG=false
APP_URL=${LX_APP_URL}
APP_KEY=base64:$(openssl rand -base64 32)

DB_HOST=localhost
DB_PORT=3306
DB_USERNAME=${LX_DB_USER}
DB_PASSWORD=${LX_DB_PASS}
DB_DATABASE=${LX_DB_NAME}

DB_SSLMODE=disabled
CACHE_DRIVER=redis
SESSION_DRIVER=file
QUEUE_CONNECTION=redis
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
EOF
else
  log "LibreNMS repository already present - reapplying dependencies, migrations and configuration"
fi
if [ ! -s /opt/librenms/.env ]; then
  die "LibreNMS .env is missing or empty"
fi
# Keep installer-managed connection values synchronized on reruns without
# rotating APP_KEY or discarding unrelated user settings. Inputs are validated
# above and cannot contain the sed delimiter.
sed -i \
  -e "s|^APP_URL=.*|APP_URL=${LX_APP_URL}|" \
  -e "s|^DB_USERNAME=.*|DB_USERNAME=${LX_DB_USER}|" \
  -e "s|^DB_PASSWORD=.*|DB_PASSWORD=${LX_DB_PASS}|" \
  -e "s|^DB_DATABASE=.*|DB_DATABASE=${LX_DB_NAME}|" /opt/librenms/.env
chmod 600 /opt/librenms/.env
chown -R librenms:librenms /opt/librenms
# composer MUST run as librenms; its failure is fatal because artisan/migrations
# and the web UI cannot be trusted without the matching vendor dependencies.
su -s /bin/bash librenms -c "cd /opt/librenms && php /usr/bin/composer install --no-dev --no-interaction --no-progress" \
    2>&1 | tail -5 || die "composer install failed; see preceding output"
# Re-apply schema and seed data on every run. These operations are idempotent.
su -s /bin/bash librenms -c "cd /opt/librenms && php artisan migrate --force" 2>&1 | tail -5 || die "LibreNMS migrations failed"
su -s /bin/bash librenms -c "cd /opt/librenms && php artisan db:seed --force" 2>&1 | tail -5 || die "LibreNMS seeding failed"
# LibreNMS 26 creates this table through its schema; fail instead of masking a
# missing/broken schema since core config lookups depend on it.
mysql "${LX_DB_NAME}" -e "CREATE TABLE IF NOT EXISTS config (
  config_id int unsigned NOT NULL AUTO_INCREMENT,
  config_name varchar(255) NOT NULL,
  config_value mediumtext NOT NULL,
  PRIMARY KEY (config_id),
  UNIQUE KEY config_config_name_unique (config_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"
# Grant only the two inventory tables required by the app and only to its loopback
# account. Never expose this read-only account to arbitrary remote hosts.
mysql -e "GRANT SELECT (ip, hostname, sysName, location_id) ON \`${LX_DB_NAME}\`.\`devices\` TO '${APP_DB_USER}'@'127.0.0.1';"
mysql -e "GRANT SELECT (id, location) ON \`${LX_DB_NAME}\`.\`locations\` TO '${APP_DB_USER}'@'127.0.0.1';"
mysql -e "FLUSH PRIVILEGES;"
# Create the initial LibreNMS admin only when absent. Password remains in the
# root-only secrets file; do not print DB or web-admin credentials to stdout.
ADM_EXISTS="$(mysql -N -e "SELECT COUNT(*) FROM \`${LX_DB_NAME}\`.users WHERE username='${LX_ADMIN_USER}';")"
if [ "${ADM_EXISTS}" = "0" ]; then
  RES="$(su -s /bin/bash librenms -c "cd /opt/librenms && php artisan user:add '${LX_ADMIN_USER}' --password='${LX_ADMIN_PASS}' --role=admin --email='${LX_ADMIN_EMAIL}' --full-name='${LX_ADMIN_USER}'" 2>&1)" || die "LibreNMS user:add failed (details in protected installer log)"
  echo "$RES" | tail -2
else
  log "LibreNMS admin '${LX_ADMIN_USER}' already exists - skipping creation"
fi
# polling + discovery cron
cat > /etc/cron.d/librenms <<'CRON'
*/5 * * * *   librenms  /opt/librenms/poller-wrapper.py 16 >> /dev/null 2>&1
*/5 * * * *   librenms  /opt/librenms/discovery-wrapper.py 1 >> /dev/null 2>&1
15    */6 * * * librenms  /opt/librenms/billing-cron.php >> /dev/null 2>&1
*/5 * * * *   librenms  /opt/librenms/alerts-cron.php >> /dev/null 2>&1
33   0 * * *   librenms  /opt/librenms/daily.sh >> /dev/null 2>&1
CRON
chmod 644 /etc/cron.d/librenms

# ---- python deps for the poller/discovery wrappers ------------------------
# poller-wrapper.py / discovery-wrapper.py import command_runner, psutil,
# redis, PyMySQL, python-dotenv. Without them every cron poll crashes silently
# and NO device is ever polled -> no RRD data -> empty graphs.
# Recent pip versions enforce PEP 668; older supported distro pip versions do
# not know --break-system-packages, so add it only when the installed pip offers it.
if [ -f /opt/librenms/requirements.txt ]; then
  PIP_SYSTEM_FLAG=()
  python3 -m pip install --help 2>/dev/null | grep -q -- '--break-system-packages' && PIP_SYSTEM_FLAG=(--break-system-packages) || true
  python3 -m pip install "${PIP_SYSTEM_FLAG[@]}" -r /opt/librenms/requirements.txt 2>&1 | tail -5 || \
    die "LibreNMS Python dependencies failed to install; polling would not work"
fi

# ---- modern extras: maintenance scheduler + admin convenience --------------
# LibreNMS 26 schedules its maintenance tasks through Laravel; validate.php
# wants the .timer installed (runs "schedule:run" every minute). The 5-minute
# poller/discovery runs stay on cron (poller-wrapper.py) - that is the way
# LibreNMS 26 actually polls on a single-node install (schedule:run only holds
# maintenance + operational-check tasks).
if [ -f /opt/librenms/dist/librenms-scheduler.service ] && [ -f /opt/librenms/dist/librenms-scheduler.timer ]; then
  cp /opt/librenms/dist/librenms-scheduler.service /opt/librenms/dist/librenms-scheduler.timer /etc/systemd/system/
systemctl daemon-reload
  systemctl enable --now librenms-scheduler.timer
else
  die "LibreNMS scheduler service/timer missing from checkout"
fi
ln -sf /opt/librenms/lnms /usr/local/bin/lnms
systemctl enable --now cron
mkdir -p /etc/bash_completion.d
cp /opt/librenms/misc/lnms-completion.bash /etc/bash_completion.d/ 2>/dev/null || true
cp /opt/librenms/misc/librenms.logrotate /etc/logrotate.d/librenms 2>/dev/null || true

# repair helper for pre-existing installs: APP_KEY in .env is mandatory
grep -q '^APP_KEY=' /opt/librenms/.env 2>/dev/null || \
  echo "APP_KEY=base64:$(openssl rand -base64 32)" >> /opt/librenms/.env

# ---- ASUSTOR custom OS definitions (mirror of the production box) ----------
# Device 10.200.11.6 (Asustor NAS) is only matched as generic "linux" by
# upstream LibreNMS; this box ships the same custom detection the prod host
# uses (os_detection regex + os_discovery modules + MIBs + icon). Without them
# the device shows up as linux/Generic ARMv8 instead of asustor/AS3302Tv2.
# Idempotent: copies are overwritten on every run, so upstream upgrades cannot
# silently "forget" the custom defs.
if [ -f "${ROOTDIR}/deploy/asustor-defs/resources/definitions/os_detection/asustor.yaml" ]; then
  install -D -o librenms -g librenms -m 0644 "${ROOTDIR}/deploy/asustor-defs/resources/definitions/os_detection/asustor.yaml" /opt/librenms/resources/definitions/os_detection/asustor.yaml
  install -D -o librenms -g librenms -m 0644 "${ROOTDIR}/deploy/asustor-defs/resources/definitions/os_discovery/asustor.yaml" /opt/librenms/resources/definitions/os_discovery/asustor.yaml
  mkdir -p /opt/librenms/mibs
  install -d -o librenms -g librenms -m 0755 /opt/librenms/mibs/asustor
  install -o librenms -g librenms -m 0644 "${ROOTDIR}/deploy/asustor-defs/mibs/asustor/"* /opt/librenms/mibs/asustor/
  install -D -o librenms -g librenms -m 0644 "${ROOTDIR}/deploy/asustor-defs/html/images/os/asustor.svg" /opt/librenms/html/images/os/asustor.svg
  log "installed ASUSTOR OS definitions (os=asustor detection)"
fi

# --- enable Oxidized integration inside LibreNMS config.php ------------------
LX_CFG=/opt/librenms/config.php
# A fresh git clone has no config.php. Keep the installer-owned Oxidized settings
# in a separate PHP file: never overwrite a user's config.php or append settings
# that may conflict with existing values.
if [ ! -e "$LX_CFG" ]; then
  printf '<?php\n' > "$LX_CFG"
elif [ ! -s "$LX_CFG" ] || ! grep -q '^<?php' "$LX_CFG" 2>/dev/null; then
  die "$LX_CFG exists but is empty or not a PHP config; refusing to overwrite it"
fi
grep -q '?>' "$LX_CFG" && die "$LX_CFG contains a closing PHP tag; remove it before appending installer settings"
LX_CFG_TMP="$(mktemp)"
read -r LX_BLOCK_BEGIN LX_BLOCK_END < <(awk '{ line=$0; sub(/\r$/, "", line); if (line == "// BEGIN OXIDIZED-WEB INSTALLER BLOCK") b++; if (line == "// END OXIDIZED-WEB INSTALLER BLOCK") e++ } END { print b+0, e+0 }' "$LX_CFG")
[ "$LX_BLOCK_BEGIN" = "$LX_BLOCK_END" ] || die "Unbalanced OxidizedWeb markers in LibreNMS config.php; refusing to rewrite it"
awk '
  { line=$0; sub(/\r$/, "", line) }
  line == "// BEGIN OXIDIZED-WEB INSTALLER BLOCK" { skip=1; next }
  line == "// END OXIDIZED-WEB INSTALLER BLOCK" { skip=0; next }
  !skip { print $0 }
' "$LX_CFG" > "$LX_CFG_TMP"
cat >> "$LX_CFG_TMP" <<EOF

// BEGIN OXIDIZED-WEB INSTALLER BLOCK
\$config['oxidized']['enabled'] = true;
\$config['oxidized']['url'] = 'http://127.0.0.1:${OX_PORT}';
\$config['oxidized']['default_group'] = '${LX_DEFAULT_GROUP}';
\$config['oxidized']['features']['versioning'] = true;
\$config['oxidized']['reload_nodes'] = true;
\$config['oxidized']['groups'] = false;
\$config['api']['enabled'] = true;
// END OXIDIZED-WEB INSTALLER BLOCK
EOF
chown librenms:librenms "$LX_CFG_TMP"
chmod 640 "$LX_CFG_TMP"
php -l "$LX_CFG_TMP" >/dev/null || die "Generated LibreNMS config.php is invalid PHP"
mv -f "$LX_CFG_TMP" "$LX_CFG"
# ConfigRepository caches the merged settings (Laravel file cache). Without a
# clear, a previously broken/empty config.php stays cached and Oxidized stays
# hidden in the UI even after the file is fixed.
su -s /bin/bash librenms -c "cd /opt/librenms && php lnms config:clear" >/dev/null 2>&1 || die "LibreNMS config cache clear failed"

# ---- Map backend for LibreNMS --------------------------------------------
# LX_MAP_VIEW  openstreetmap|yandex : basemap used by all LibreNMS map pages.
#   Yandex core-renderer tiles use ellipsoidal Mercator (EPSG:3395), Leaflet
#   assumes spherical web Mercator (EPSG:3857); without a matching CRS the tile
#   grid is offset by up to ~0.18 deg of latitude, so a matching JS + DB change
#   is only applied when Yandex was chosen. openstreetmap keeps the stock setup.
# LX_MAP_LINK  yandex|google : provider opened by the "Map" button next to the
#   device coordinates (device overview + draggable marker handler).
# All edits are idempotent and reapplied on every installer run, so they also
# survive upstream `git pull` upgrades that restore pristine files.
if [ "$LX_MAP_VIEW" = "yandex" ]; then
  # config_value is stored JSON-encoded (the DB row must be readable via
  # json_decode without quoting issues), then flush the LibreNMS config cache
  # so leaflet.tile_url is picked up from the database immediately.
  YMAP_URL='https://core-renderer-tiles.maps.yandex.net/tiles?l=map&v=21.06.20&x={x}&y={y}&z={z}&scale=1&lang=ru_RU'
  YMAP_JSON=$(printf '%s' "$YMAP_URL" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))') \
    || die "could not JSON-encode Yandex tile url"
  mysql -e "INSERT INTO ${LX_DB_NAME}.config (config_name, config_value) VALUES ('leaflet.tile_url', '${YMAP_JSON}') ON DUPLICATE KEY UPDATE config_value=VALUES(config_value);" \
    || die "could not set leaflet.tile_url in LibreNMS config"
else
  # openstreetmap: drop the override so LibreNMS falls back to its stock tiles
  mysql -e "DELETE FROM ${LX_DB_NAME}.config WHERE config_name='leaflet.tile_url';" \
    || die "could not clear leaflet.tile_url in LibreNMS config"
fi
export LX_MAP_VIEW LX_MAP_LINK
python3 - <<'PYEOF'
import os, re

MAP_VIEW = os.environ.get("LX_MAP_VIEW", "yandex")
MAP_LINK = os.environ.get("LX_MAP_LINK", "yandex")

def status(msg):
    print("  map-patch:", msg, flush=True)

def write_file(path, data):
    tmp = path + ".map.tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(data)
    os.chmod(tmp, os.stat(path).st_mode & 0o7777)
    os.replace(tmp, path)

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
    js = "/opt/librenms/html/js/librenms.js"
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

# tile_url must reach the JS config safely in both modes
fb = "/opt/librenms/resources/views/map/fullscreen.blade.php"
data = open(fb, encoding="utf-8").read()
if "@json($tile_url)" not in data:
    old = '"tile_url": "{{$tile_url}}"'
    new = '"tile_url": @json($tile_url)'
    assert data.count(old) == 1, "fullscreen tile_url anchor"
    status("fullscreen.blade.php: tile_url via @json")
    write_file(fb, data.replace(old, new, 1))

# route method must be callable by the maps UI in both modes
ctrl = "/opt/librenms/app/Http/Controllers/Maps/FullscreenMapController.php"
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
sysv = "/opt/librenms/resources/views/components/device/overview/system.blade.php"
gm = "/opt/librenms/resources/views/components/geo-map.blade.php"
if MAP_LINK == "yandex":
    swap_once(sysv, static_google, static_yandex, "Map link -> Yandex")
    swap_once(gm, js_google, js_yandex, "Map link -> Yandex")
else:
    swap_once(sysv, static_yandex, static_google, "Map link -> Google")
    swap_once(gm, js_yandex, js_google, "Map link -> Google")

# only the Yandex basemap changes librenms.js, so bump its asset version then
if MAP_VIEW == "yandex":
    lay = "/opt/librenms/resources/views/layouts/librenmsv1.blade.php"
    data = open(lay, encoding="utf-8").read()
    if "librenms.js?ver=20260925-yandex" not in data:
        new, n = re.subn(r"js/librenms\.js\?ver=[A-Za-z0-9_.-]*",
                         "js/librenms.js?ver=20260925-yandex", data, count=1)
        assert n == 1, "librenmsv1 asset anchor"
        status("librenmsv1.blade.php: librenms.js asset version bumped")
        write_file(lay, new)

print("  map-patch: DONE", flush=True)
PYEOF
# Rebuild both caches after file + DB modifications
su -s /bin/bash librenms -c "cd /opt/librenms && php artisan view:clear" >/dev/null 2>&1 || die "LibreNMS view clear failed"
su -s /bin/bash librenms -c "cd /opt/librenms && php artisan cache:clear" >/dev/null 2>&1 || die "LibreNMS app cache clear failed"
su -s /bin/bash librenms -c "cd /opt/librenms && php lnms config:clear" >/dev/null 2>&1 || die "LibreNMS config cache clear failed"
log "installed map setup: view=${LX_MAP_VIEW}, Map link=${LX_MAP_LINK}"

# LibreNMS nginx + fpm
log "== Phase 3: nginx + php-fpm (LibreNMS) ================================="
CURRENT_PHASE="phase 3: LibreNMS web server"
# rrd_dir (validate.php wants /opt/librenms/rrd on 0775; storage/rrd is the
# newer default the graph code also uses) - both writable by the librenms user.
mkdir -p /opt/librenms/rrd /opt/librenms/storage/rrd /opt/librenms/bootstrap/cache
chown -R librenms:librenms /opt/librenms
chmod 775 /opt/librenms/rrd

cat > /etc/php/${PHP_VER}/fpm/pool.d/librenms.conf <<'LIBPOOL'
[librenms]
user = librenms
group = librenms
listen = /run/php-fpm-librenms.sock
; nginx runs as www-data on Debian/Ubuntu (no system user "nginx" exists)
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = dynamic
pm.max_children = 12
pm.start_servers = 4
pm.min_spare_servers = 2
pm.max_spare_servers = 6
security.limit_extensions = .php
php_admin_value[open_basedir] = /opt/librenms/:/tmp/
LIBPOOL

sed -e 's/^    listen      80;/    listen      '"${LX_LISTEN_ADDR}:${LX_SITE_PORT}"';/' \
    -e 's/server_name.*;/server_name '"${LX_SITE_FQDN}"';/' \
    "${ROOTDIR}/deploy/templates/nginx-librenms.conf" > /etc/nginx/conf.d/librenms.conf

# =============================================================================
log "== Phase 4: Oxidized (Ruby daemon + REST :8888) ========================"
CURRENT_PHASE="phase 4: Oxidized"
if ! command -v oxidized >/dev/null 2>&1; then
  if ! gem install oxidized --no-document 2>&1 | tail -5; then
    echo -e "\n[error] rugged (libgit2) native build failed. Last lines of gem_make.out:"
    find /var/lib/gems -path '*/extensions/*' -name gem_make.out -exec tail -25 {} \; 2>/dev/null | tail -45
    die "gem install oxidized failed (see the cmake/gcc error above)"
  fi
fi
# Oxidized >=0.35: the former "rest:" built-in API moved to the oxidized-web
# gem. Without it oxidized aborts with "oxidized-web not found" on startup.
# libicu-dev (Phase 0) is required to build its charlock_holmes dependency.
if ! gem list oxidized-web -i 2>/dev/null | grep -q true; then
  gem install oxidized-web --no-document 2>&1 | tail -5 || die "oxidized-web gem failed to install"
fi

mkdir -p /etc/oxidized /home/oxidized/configs /home/oxidized/.config/oxidized
id oxidized >/dev/null 2>&1 || useradd -r -m -d /home/oxidized -s /bin/bash oxidized
chown -R oxidized:oxidized /home/oxidized

# Oxidized pulls the device list from LibreNMS REST API.
# LibreNMS /api/v0/oxidized requires a valid API token, so one is created for
# the LibreNMS admin below and injected into the source http headers.
# (Reuse an existing token on reruns so reruns don't pile up DB tokens.)
OX_TOKEN="$(sed -n "s/.*X-Auth-Token: '\([^']*\)'.*/\1/p" /etc/oxidized/config 2>/dev/null | sed -n '1p')" || true
if [ -n "$OX_TOKEN" ]; then
  TOKEN_HTTP="$(curl -sS --connect-timeout 3 --max-time 8 -o /dev/null -w '%{http_code}' -H "X-Auth-Token: ${OX_TOKEN}" "http://${LX_SITE_FQDN}:${LX_SITE_PORT}/api/v0/oxidized" 2>/dev/null || true)"
  [ "$TOKEN_HTTP" = 200 ] || OX_TOKEN=""
fi
if [ -z "$OX_TOKEN" ]; then
  TOKEN_OUTPUT="$(su -s /bin/bash librenms -c "cd /opt/librenms && php artisan api:token-create '${LX_ADMIN_USER}' --name=oxidized" 2>&1)" || die "LibreNMS API token creation failed"
  OX_TOKEN="$(awk '/^[0-9]+\|/{print; exit}' <<< "$TOKEN_OUTPUT")"
  [ -n "$OX_TOKEN" ] || die "LibreNMS API token output did not contain a token"
  echo ">> Oxidized API token created"
fi
# yaml: 'vars:' with no children is invalid, so a bare 'vars: {}' is emitted
# unless an ENABLE secret was provided (single password devices have none).
ENABLE_LINE="vars: {}"
[ -n "$OX_ENABLE" ] && ENABLE_LINE="vars:
  enable: ${OX_ENABLE}"
cat > /etc/oxidized/config <<EOF
---
username: ${OX_DV_USER}
password: ${OX_DV_PASS}
resolve_dns: false
${ENABLE_LINE}
next_adds_job: true
interval: 3600
use_syslog: false
debug: false
threads: 30
timeout: 20
retries: 3

extensions:
  oxidized-web:
    load: true
    listen: ${OX_HOST}
    port: ${OX_PORT}
    hide_node_vars:
      - enable
      - password

input:
  default: ssh, telnet
  debug: false
  ssh:
    secure: false
  telnet: {}

output:
  default: git
  git:
    user: Oxidized
    email: oxidized@localhost
    repo: /home/oxidized/configs
    as_directory: true

source:
  default: http
  http:
    url: http://${LX_SITE_FQDN}:${LX_SITE_PORT}/api/v0/oxidized
    scheme: http
    secure: false
    debug: false
    reload_interval: 300
    delimiter: !ruby/regexp /:/
    map:
      name: hostname
      model: os
      group: group
GROUPS: {}
hooks: {}
EOF
# inject the API token into the http source block (matters for LibreNMS 401s)
if [ -n "$OX_TOKEN" ]; then
  sed -i "s/^GROUPS: {}/    headers:\n      X-Auth-Token: '${OX_TOKEN}'\nGROUPS: {}/" /etc/oxidized/config
else
  die "No LibreNMS API token available for Oxidized"
fi
chown -R oxidized:oxidized /etc/oxidized

OXIDIZED_BIN="$(command -v oxidized || true)"
if [ -z "$OXIDIZED_BIN" ]; then
    for c in /usr/local/bin/oxidized /var/lib/gems/*/bin/oxidized /usr/lib/ruby/gems/*/bin/oxidized; do
        [ -x "$c" ] && { OXIDIZED_BIN="$c"; break; }
    done
fi
[ -n "$OXIDIZED_BIN" ] || die "oxidized binary not found after gem installation"

cat > /etc/systemd/system/oxidized.service <<UNIT
[Unit]
Description=Oxidized - Network Device Configuration Backup
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${OXIDIZED_BIN:-/usr/local/bin/oxidized}
User=oxidized
KillSignal=SIGTERM
TimeoutStopSec=30
Environment="OXIDIZED_HOME=/etc/oxidized"
Restart=on-failure
RestartSec=300s

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable oxidized
systemctl start oxidized >/dev/null 2>&1 || warn "oxidized is waiting for a usable LibreNMS node source"

# =============================================================================
log "== Phase 5: oxidized-web PHP app (:${OXWEB_PORT}) ======================"
CURRENT_PHASE="phase 5: oxidized-web"
[ -d /opt/oxidized-web ] || mkdir -p /opt/oxidized-web
# Copy the app sources into a staging dir FIRST: when the repo checkout IS
# /opt/oxidized-web (git clone into the app dir) the rm -rf below would
# otherwise delete the very files we are about to copy.
STAGE="$(mktemp -d /tmp/oxweb-src.XXXXXX)"
cp -r "${ROOTDIR}/public" "$STAGE/public"
cp -r "${ROOTDIR}/src" "$STAGE/src"
rm -rf /opt/oxidized-web/public /opt/oxidized-web/src
cp -r "$STAGE/public" "$STAGE/src" /opt/oxidized-web/
rm -rf "$STAGE"
mkdir -p /opt/oxidized-web/data/sessions
chown -R www-data:www-data /opt/oxidized-web

# real config from example (fills in DB app account)
cat > /opt/oxidized-web/config.php <<EOF
<?php
declare(strict_types=1);
const OX_LX_HOST = '127.0.0.1';
const OX_LX_DB   = '${LX_DB_NAME}';
const OX_LX_USER = '${APP_DB_USER}';
const OX_LX_PASS = '${APP_DB_PASS}';
EOF
chown root:www-data /opt/oxidized-web/config.php
chmod 640 /opt/oxidized-web/config.php

cat > /etc/php/${PHP_VER}/fpm/pool.d/oxidized.conf <<'OXPOOL'
[oxidized]
user = www-data
group = www-data
listen = /run/php-fpm-oxidized.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = dynamic
pm.max_children = 6
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
security.limit_extensions = .php
php_admin_value[open_basedir]            = /opt/oxidized-web/:/tmp/
php_admin_value[session.save_path]       = /opt/oxidized-web/data/sessions
php_admin_value[session.use_strict_mode] = 1
php_admin_value[upload_max_filesize]     = 4M
php_admin_value[post_max_size]           = 4M
OXPOOL

sed -e "s/listen .*8889;/listen ${OXWEB_LISTEN_ADDR}:${OXWEB_PORT};/" \
    "${ROOTDIR}/deploy/templates/nginx-oxidized-web.conf" > /etc/nginx/conf.d/oxidized-web.conf

# =============================================================================
log "== Phase 6: start services + first admin ================================"
CURRENT_PHASE="phase 6: service startup and admin"
php-fpm${PHP_VER} -t >/dev/null || die "PHP-FPM configuration test failed"
nginx -t >/dev/null 2>&1 || die "nginx configuration test failed"
systemctl restart "php${PHP_VER}-fpm" nginx
sleep 3
# oxidized crashed early (LibreNMS wasn't up yet); restart it so it picks up
# the freshly injected API token and the now-live LibreNMS API
systemctl restart oxidized >/dev/null 2>&1 || warn "oxidized is not yet running; it may need a usable device in LibreNMS"
sleep 2

# Bootstrap the configured admin only if that username is absent; preserve any
# other users and credentials on reruns.
if ! php -r '$d=new PDO("sqlite:/opt/oxidized-web/data/oxidized.db"); $s=$d->prepare("SELECT COUNT(*) FROM users WHERE username=?"); $s->execute([$argv[1]]); exit((int)$s->fetchColumn()>0?0:1);' "${OX_WEB_ADMIN_USER}" 2>/dev/null; then
  php -r '
    $dir="/opt/oxidized-web/data";
    if(!is_dir($dir)){mkdir($dir,0770,true);}
    $d=new PDO("sqlite:".$dir."/oxidized.db");
    $d->exec("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL UNIQUE, password_hash TEXT NOT NULL, role TEXT NOT NULL DEFAULT '\''user'\'', email TEXT NOT NULL DEFAULT '\'''\'', created_at TEXT NOT NULL DEFAULT (datetime('\''now'\'')), last_login TEXT DEFAULT NULL)");
    $u="$argv[2]"; $p=password_hash($argv[1], PASSWORD_DEFAULT);
    $s=$d->prepare("INSERT INTO users (username, password_hash, role) VALUES (?,?, '\''admin'\'')");
    $s->execute([$u,$p]); echo "created admin login=".$u."\n";
  ' "${OX_WEB_ADMIN_PASS}" "${OX_WEB_ADMIN_USER}" 2>&1 || die "failed to bootstrap oxidized-web admin"
fi
chown -R www-data:www-data /opt/oxidized-web
chown root:www-data /opt/oxidized-web/config.php
chmod 640 /opt/oxidized-web/config.php

# =============================================================================
log "== Verify ==============================================================="
CURRENT_PHASE="verification"
for svc in nginx "php${PHP_VER}-fpm" mariadb redis-server cron librenms-scheduler.timer; do
  state="$(systemctl is-active "$svc" 2>/dev/null || true)"
  echo "${svc}: ${state:-inactive}"
  [ "$state" = active ] || die "required service ${svc} is not active"
done
echo -n "oxidized:    "; systemctl is-active oxidized || true
# oxidized intentionally stays down while LibreNMS has no devices (stock
# behavior: "source returns no usable nodes"); it retries every 300s
systemctl is-active oxidized >/dev/null 2>&1 || \
  warn "oxidized не активен: штатно, пока в LibreNMS нет устройств (см. шаг 2 в итогах)"
php-fpm${PHP_VER} -t >/dev/null || die "PHP-FPM configuration test failed"
nginx -t >/dev/null 2>&1 || die "nginx configuration test failed"
php -r 'foreach (["curl","pdo_mysql","pdo_sqlite","sqlite3"] as $e) { if (!extension_loaded($e)) { fwrite(STDERR,"missing PHP extension: $e\n"); exit(1); } }' || die "required PHP extension is missing"
mysql -N -e "SELECT ip,hostname FROM \`${LX_DB_NAME}\`.devices LIMIT 0" >/dev/null || die "LibreNMS devices table is unavailable"
mysql -N -e "SELECT id,location FROM \`${LX_DB_NAME}\`.locations LIMIT 0" >/dev/null || die "LibreNMS locations table is unavailable"
su -s /bin/bash www-data -c "php -r 'require \"/opt/oxidized-web/config.php\"; \$p=new PDO(\"mysql:host=\".OX_LX_HOST.\";dbname=\".OX_LX_DB.\";charset=utf8mb4\",OX_LX_USER,OX_LX_PASS); \$p->query(\"SELECT ip,hostname,sysName FROM devices LIMIT 0\"); \$p->query(\"SELECT d.location_id,l.id,l.location FROM devices d LEFT JOIN locations l ON l.id=d.location_id LIMIT 0\");'" \
  || die "oxidized-web DB account cannot read required inventory fields"
TOKEN_HTTP="$(curl -sS --connect-timeout 3 --max-time 8 -o /dev/null -w '%{http_code}' -H "X-Auth-Token: ${OX_TOKEN}" "http://${LX_SITE_FQDN}:${LX_SITE_PORT}/api/v0/oxidized" 2>/dev/null || true)"
[ "$TOKEN_HTTP" = 200 ] || die "Oxidized LibreNMS API token check failed (HTTP ${TOKEN_HTTP:-connection-error})"
for pair in "${LX_SITE_FQDN}:${LX_SITE_PORT}" "${OXWEB_FQDN}:${OXWEB_PORT}"; do
  status="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "http://${pair}/" || true)"
  [[ "$status" =~ ^(200|301|302|303|307|308)$ ]] || die "HTTP health check failed for ${pair} (status ${status:-connection-error})"
  echo "HTTP ${pair} -> ${status}"
done

log "== DONE ================================================================"
cat <<SUMMARY

Stack deployed:
  LibreNMS      http://${LX_SITE_FQDN}:${LX_SITE_PORT}/   admin ${LX_ADMIN_USER} / (см. секреты)
  Oxidized REST http://${OX_HOST}:${OX_PORT}
  oxidized-web  http://${OXWEB_FQDN}:${OXWEB_PORT}/       admin ${OX_WEB_ADMIN_USER} / (см. секреты)

Секреты сохранены: /root/oxidized-web-deploy.secrets (chmod 600)

Remaining manual steps:
  1. Зайдите в LibreNMS (admin из мастер-вопросов), добавьте устройства.
  2. Oxidized читает устройства из REST API LibreNMS. Пока в LibreNMS нет
     ни одного устройства, демон штатно не держится в run ("source returns
     no usable nodes") и автоматически повторяет попытку каждые 300 c —
     первого добавленного устройства достаточно, чтобы он поднялся.
  3. oxidized-web подхватит устройства при открытии (имена/локации из MySQL).
  4. Oxidized берёт SSH-доступ устройства из мастера установки
     (OX_DV_USER / OX_DV_PASS / OX_ENABLE, см. /root/oxidized-web-deploy.secrets).
     Если у отдельных устройств другие доступы - укажите их в /etc/oxidized/config (верхний блок).
  5. За TLS следите отдельно, если хост в открытом интернете.
SUMMARY
