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
#               Oxidized uses to read device configs.
#  Idempotent: rerun is safe (it detects already-created pieces).
# =============================================================================
set -Eeuo pipefail

# under set -e a failing pipeline aborts silently (and with stdout redirected
# to a file the last buffered lines can be lost), so log the exact failing
# line to a dedicated file - makes automated runs truly diagnosable.
trap '[ $? -ne 0 ] && { s=$?; echo ">> install.sh FAILED at ${BASH_SOURCE[0]}:${LINENO}, status=$s, cmd: ${BASH_COMMAND}" >> /tmp/oxidized-install-err.log 2>&1; } || true' ERR

ROOTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo checkout

# The script needs the whole repo (nginx templates + PHP app sources), so
# running it from a partial copy (only install.sh) fails deep in Phase 3/5
# with cryptic errors. Refuse loudly and upfront instead.
for need in \
    deploy/templates/nginx-librenms.conf \
    deploy/templates/nginx-oxidized-web.conf \
    public/index.php \
    src; do
    [ -e "${ROOTDIR}/${need}" ] || die "missing ${ROOTDIR}/${need} - copy the whole oxidized-web repo, not just install.sh"
done
APP_DIR="/opt/oxidized-web"

# colours are optional: under a non-tty shell (ssh without -t, cron, piped
# output) TERM is "unknown" and tput fails -> with set -e that would kill the
# script, so fall back to plain text when there is no terminal.
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    C_B=$(tput bold); C_N=$(tput sgr0); C_G=$(tput setaf 2); C_Y=$(tput setaf 3); C_R=$(tput setaf 1)
else
    C_B=""; C_N=""; C_G=""; C_Y=""; C_R=""
fi
log()  { echo -e "${C_G}[install]${C_N} $*"; }
warn() { echo -e "${C_Y}[warn]${C_N} $*"; }
die()  { echo -e "${C_R}[error]${C_N} $*" >&2; exit 1; }

ask() { # ask "<prompt>" <varname> [default]
    local prompt="$1" var="$2" def="${3:-}" val
    # automated/redirected reruns (no tty) reuse values already loaded from
    # /root/oxidized-web-deploy.secrets instead of pestering for input
    if [ ! -t 0 ] && [ -n "${!var:-}" ]; then return; fi
    val=""
    # EOF-safe: read returns 1 at end of input, which set -e must not treat as fatal
    read -r -p "${C_B}${prompt}${C_N} ${def:+[$def] }" val || true
    printf -v "$var" '%s' "${val:-$def}"
}

ask_pass() { # ask_pass "<prompt>" <varname> <default> [minlen]
    local prompt="$1" var="$2" def="$3" minlen="${4:-0}" p1 p2
    if [ ! -t 0 ] && [ -n "${!var:-}" ]; then return; fi
    while :; do
        p1=""
        read -r -s -p "${C_B}${prompt}${C_N} (пусто = сгенерировать) " || true
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
        read -r -s -p "  повторите: " || true
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
log "═══ Настройка стека (нажмите Enter = значение по умолчанию) ═══"

# Reuse credentials/settings from a previous run so a rerun never churns the
# DB passwords (the running stack keeps the old values, so keeping defaults
# stable is what makes "rebuild after failure" honest).
if [ -f /root/oxidized-web-deploy.secrets ]; then
  # shellcheck source=/dev/null
  . /root/oxidized-web-deploy.secrets
fi

LX_DB_NAME="librenms"
ask "Имя БД LibreNMS?"            LX_DB_NAME       "librenms"
ask "MySQL-логин для LibreNMS?"   LX_DB_USER       "librenms"
ask_pass "Пароль MySQL-пользователя '${LX_DB_USER}':" LX_DB_PASS "${LX_DB_PASS:-$(openssl rand -hex 16)}"

APP_DB_USER="oxidized_web"
ask "MySQL-аккаунт для oxidized-web (read-only)?" APP_DB_USER "oxidized_web"
ask_pass "Пароль MySQL-пользователя '${APP_DB_USER}':" APP_DB_PASS "${APP_DB_PASS:-$(openssl rand -hex 16)}"

ask_pass "Пароль админа LibreNMS (web):"  LX_ADMIN_PASS   "${LX_ADMIN_PASS:-$(openssl rand -hex 10)}" 8
ask "Логин админа LibreNMS (web)?"        LX_ADMIN_USER   "admin"
ask "Email админа LibreNMS?"              LX_ADMIN_EMAIL  "admin@localhost"

ask_pass "Пароль админа oxidized-web:"    OX_WEB_ADMIN_PASS "${OX_WEB_ADMIN_PASS:-$(openssl rand -hex 10)}" 8
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
ask_pass "Пароль устройства для Oxidized (SSH/telnet):" OX_DV_PASS "${OX_DV_PASS:-change_me_device_pass}"
ask_pass "ENABLE-пароль устройства (опционально):"      OX_ENABLE   "${OX_ENABLE:-}"

ask "FQDN для исходящих ссылок LibreNMS (base_url)?" LX_APP_URL "http://${LX_SITE_FQDN}"
[ "${LX_SITE_PORT}" != "80" ] && LX_APP_URL="http://${LX_SITE_FQDN}:${LX_SITE_PORT}" || true

warn "Значения приняты. Установка начнётся. Пароли при необходимости сохранит в /root/oxidized-web-deploy.secrets"
cat > /root/oxidized-web-deploy.secrets <<SECF
LX_DB_NAME=${LX_DB_NAME}
LX_DB_USER=${LX_DB_USER}
LX_DB_PASS=${LX_DB_PASS}
APP_DB_USER=${APP_DB_USER}
APP_DB_PASS=${APP_DB_PASS}
LX_ADMIN_USER=${LX_ADMIN_USER}
LX_ADMIN_PASS=${LX_ADMIN_PASS}
LX_ADMIN_EMAIL=${LX_ADMIN_EMAIL}
OX_WEB_ADMIN_USER=${OX_WEB_ADMIN_USER}
OX_WEB_ADMIN_PASS=${OX_WEB_ADMIN_PASS}
LX_SITE_FQDN=${LX_SITE_FQDN}
LX_SITE_PORT=${LX_SITE_PORT}
OXWEB_FQDN=${OXWEB_FQDN}
OXWEB_PORT=${OXWEB_PORT}
OX_HOST=${OX_HOST}
OX_PORT=${OX_PORT}
LX_DEFAULT_GROUP=${LX_DEFAULT_GROUP}
OX_DV_USER=${OX_DV_USER}
OX_DV_PASS=${OX_DV_PASS}
OX_ENABLE=${OX_ENABLE}
SECF
chmod 600 /root/oxidized-web-deploy.secrets

# ------------------------------------------------------------------ guard -----
[ "$(id -u)" = 0 ] || { echo "Run as root: sudo bash deploy/install.sh"; exit 1; }
command -v apt-get >/dev/null || die "This script targets Debian/Ubuntu (apt-get)."

# =============================================================================
log "== Phase 0: base packages ==============================================="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget git snmp snmpd rrdtool whois net-tools unzip \
    software-properties-common ca-certificates redis-server \
    nginx mariadb-server mariadb-client \
    python3 python3-pip python3-mysqldb python3-dotenv python3-paramiko \
    composer 2>/dev/null || true
# ruby + native-devel for the oxidized (rugged/libgit2) gem build.
# rugged vendors libgit2 and builds it with cmake; libssh2/libcurl are needed
# for the SSH/HTTPS transports. Missing any of these -> "ERROR: Failed to build
# gem native extension" when installing the oxidized gem.
apt-get install -y ruby ruby-dev build-essential cmake pkg-config zlib1g-dev \
    libsqlite3-dev libssl-dev libssh2-1-dev libcurl4-openssl-dev 2>/dev/null || true
# fping: LibreNMS availability/ping checks (DeviceIsPingable) exec it; without
# it every device is "Could not ping" and gets added as down.
# libicu-dev: builds charlock_holmes, a native dep of the oxidized-web gem
# (Oxidized >=0.35 moved its REST API from "rest:" to the oxidized-web gem).
apt-get install -y fping libicu-dev 2>/dev/null || true

# --- newest PHP (8.3 is the distro max; add ondrej/php for newer lines) ------
# Ubuntu 24.04 only ships PHP 8.3 in its repos. To run the newest stable line
# (8.4, 8.5, 8.6 and later) we add the well-known sury.org PPA (ppa:ondrej/php)
# and pick the greatest php<X.Y> version whose FULL module set is available in
# apt. A brand-new PHP line often lags a couple of modules (php-redis is usually
# the last one to be rebuilt), so "newest" is tried first and we step back to
# the previous line until a complete set is found. If the PPA is unreachable we
# fall back to distro 8.3.
add-apt-repository -y ppa:ondrej/php 2>&1 | tail -1 || \
  warn "ppa:ondrej/php could not be added - will use the distro PHP"
apt-get update -y 2>/dev/null || true
PHP_MODULES="fpm cli mysql curl gd xml mbstring sqlite3 redis bcmath gmp intl zip"
PHP_VER=""
for cand in $(apt-cache search '^php[0-9]+\.[0-9]+-fpm$' 2>/dev/null | sed 's/-fpm.*//' | sort -Vr); do
  ver="${cand#php}"
  missing=""
  for mod in $PHP_MODULES; do
    apt-cache show "php${ver}-${mod}" >/dev/null 2>&1 || missing="$missing ${mod}"
  done
  if [ -z "$missing" ]; then
    PHP_VER="$ver"
    break
  fi
  warn "PHP ${ver}: modules not built yet:$missing - stepping back one line"
done
if [ -z "$PHP_VER" ]; then
  PHP_VER=8.3
  warn "no complete PHP line found - falling back to distro 8.3"
fi
PHP_FPM_BIN="php${PHP_VER}-fpm"
SYSTEM_DEFAULT_PHP_SOCK="/run/php/php${PHP_VER}-fpm.sock"
PHP_PKGS=""
for mod in $PHP_MODULES; do PHP_PKGS="$PHP_PKGS php${PHP_VER}-${mod}"; done
log "Using PHP: ${PHP_VER} (${PHP_FPM_BIN})"
apt-get install -y $PHP_PKGS 2>&1 | tail -3 || \
  die "installing PHP ${PHP_VER} failed (check ppa:ondrej/php)"
command -v "$PHP_FPM_BIN" || apt-get install -y "$PHP_FPM_BIN"

# =============================================================================
log "== Phase 1: MariaDB - databases and accounts ============================"
systemctl enable --now mariadb redis-server >/dev/null 2>&1 || true
sleep 2

# --- LibreNMS main db + user ---
mysql -e "CREATE DATABASE IF NOT EXISTS \`${LX_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null
mysql -e "CREATE USER IF NOT EXISTS '${LX_DB_USER}'@'localhost' IDENTIFIED BY '${LX_DB_PASS}';"
mysql -e "ALTER USER '${LX_DB_USER}'@'localhost' IDENTIFIED BY '${LX_DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON \`${LX_DB_NAME}\`.* TO '${LX_DB_USER}'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# --- read-only account for oxidized-web (devices + locations) ---
mysql -e "CREATE USER IF NOT EXISTS '${APP_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${APP_DB_PASS}';"
mysql -e "CREATE USER IF NOT EXISTS '${APP_DB_USER}'@'localhost' IDENTIFIED BY '${APP_DB_PASS}';"
mysql -e "CREATE USER IF NOT EXISTS '${APP_DB_USER}'@'%' IDENTIFIED BY '${APP_DB_PASS}';"
# ALTER keeps the runtime password in sync with the secrets file on reruns
mysql -e "ALTER USER '${APP_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${APP_DB_PASS}';"
mysql -e "ALTER USER '${APP_DB_USER}'@'localhost' IDENTIFIED BY '${APP_DB_PASS}';"
mysql -e "ALTER USER '${APP_DB_USER}'@'%' IDENTIFIED BY '${APP_DB_PASS}';"
# GRANT on db.* does not require tables to exist (unlike db.table, which trips
# on "ERROR 1146 Table doesn't exist" before LibreNMS migrate has run in Phase 2)
mysql -e "GRANT SELECT ON \`${LX_DB_NAME}\`.* TO '${APP_DB_USER}'@'127.0.0.1';"
mysql -e "GRANT SELECT ON \`${LX_DB_NAME}\`.* TO '${APP_DB_USER}'@'localhost';"
mysql -e "GRANT SELECT ON \`${LX_DB_NAME}\`.* TO '${APP_DB_USER}'@'%';"
mysql -e "FLUSH PRIVILEGES;"

# =============================================================================
log "== Phase 2: LibreNMS (git install into /opt/librenms) ==================="
if [ ! -d /opt/librenms/.git ]; then
  id librenms >/dev/null 2>&1 || useradd -r -M -d /opt/librenms -s /bin/bash librenms
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
  chown -R librenms:librenms /opt/librenms
  # composer MUST run as the librenms user (running as root disables plugins and
  # breaks the post-autoload-dump hook -> composer exits non-zero)
  su -s /bin/bash librenms -c "cd /opt/librenms && php /usr/bin/composer install --no-dev --no-interaction --no-progress" \
      2>&1 | tail -3 || warn "composer install failed (rerun manually: su -s /bin/bash librenms -c 'composer install')"
  # load schema (roles admin/global-read/user come from db:seed -> RolesSeeder)
  su -s /bin/bash librenms -c "cd /opt/librenms && php artisan migrate --force" 2>&1 | tail -2 || \
    warn "migrate failed (maybe composer is broken; fix composer first)"
  su -s /bin/bash librenms -c "cd /opt/librenms && php artisan db:seed --force" 2>&1 | tail -2 || \
    warn "db:seed failed (roles may be missing; add the admin in the web UI)"
  # modern LibreNMS keeps runtime config in the DB ("config" table); the web
  # installer creates it but a git install does not. Without it every config
  # lookup throws "Table 'librenms.config' doesn't exist" and discovery/polling
  # mark devices as down. Schema matches resources/definitions/schema/db_schema.yaml.
  mysql "${LX_DB_NAME}" -e "CREATE TABLE IF NOT EXISTS config (
    config_id int unsigned NOT NULL AUTO_INCREMENT,
    config_name varchar(255) NOT NULL,
    config_value mediumtext NOT NULL,
    PRIMARY KEY (config_id),
    UNIQUE KEY config_config_name_unique (config_name)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;" 2>/dev/null || \
    warn "could not ensure the 'config' table exists (check mysql grants)"
  # table-level SELECT grants for the app (safe now: migrate created the tables)
  mysql -e "GRANT SELECT ON \`${LX_DB_NAME}\`.\`devices\`   TO '${APP_DB_USER}'@'127.0.0.1','${APP_DB_USER}'@'localhost','${APP_DB_USER}'@'%';" 2>/dev/null || true
  mysql -e "GRANT SELECT ON \`${LX_DB_NAME}\`.\`locations\` TO '${APP_DB_USER}'@'127.0.0.1','${APP_DB_USER}'@'localhost','${APP_DB_USER}'@'%';" 2>/dev/null || true
  mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true
  # first LibreNMS admin (official CLI: user:add --role=admin).
  # NOTE: older LibreNMS used scripts/adduser.php and a users.level column; both
  # are gone in the current role-based (Spatie) user model, which is why the
  # raw-SQL insert previously died with "Unknown column 'level'".
  ADM_EXISTS="$(mysql -N -e "SELECT COUNT(*) FROM \`${LX_DB_NAME}\`.users WHERE username='${LX_ADMIN_USER}';" 2>/dev/null || echo 0)"
  if [ "${ADM_EXISTS}" = "0" ]; then
    # LibreNMS requires a >=8 char password: a short one (typed interactively,
    # or saved by an older run and reloaded from the secrets file on rerun)
    # makes user:add fail. Auto-heal: swap in a strong one and retry, then
    # persist it so the next rerun keeps using a working password.
    ADDED=0
    for try in 1 2 3; do
      RES="$(su -s /bin/bash librenms -c "cd /opt/librenms && php artisan user:add '${LX_ADMIN_USER}' --password='${LX_ADMIN_PASS}' --role=admin --email='${LX_ADMIN_EMAIL}' --full-name='${LX_ADMIN_USER}'" 2>&1)" || true
      echo "$RES" | tail -2
      ADM_EXISTS="$(mysql -N -e "SELECT COUNT(*) FROM \`${LX_DB_NAME}\`.users WHERE username='${LX_ADMIN_USER}';" 2>/dev/null || echo 0)"
      [ "${ADM_EXISTS}" != "0" ] && { ADDED=1; break; }
      if [ "$try" -lt 3 ]; then
        LX_ADMIN_PASS="$(openssl rand -hex 12)"
        warn "user:add failed for '${LX_ADMIN_USER}' - retrying with a generated 24-char password"
      fi
    done
    [ "$ADDED" = "1" ] || warn "user:add failed 3x (create '${LX_ADMIN_USER}' in the LibreNMS web UI)"
    sed -i "s|^LX_ADMIN_PASS=.*|LX_ADMIN_PASS=${LX_ADMIN_PASS}|" /root/oxidized-web-deploy.secrets 2>/dev/null || true
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
else
  log "LibreNMS already present - skipping git setup"
fi

# ---- python deps for the poller/discovery wrappers ------------------------
# poller-wrapper.py / discovery-wrapper.py import command_runner, psutil,
# redis, PyMySQL, python-dotenv. Without them every cron poll crashes silently
# and NO device is ever polled -> no RRD data -> empty graphs.
# Ubuntu 24.04 ships an externally-managed pip, hence --break-system-packages.
if [ -f /opt/librenms/requirements.txt ]; then
  python3 -m pip install --break-system-packages -r /opt/librenms/requirements.txt 2>&1 | tail -1 || \
    warn "python deps not installed - LibreNMS will not poll (graphs stay empty)"
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
  systemctl enable --now librenms-scheduler.timer >/dev/null 2>&1 || true
fi
ln -sf /opt/librenms/lnms /usr/local/bin/lnms
mkdir -p /etc/bash_completion.d
cp /opt/librenms/misc/lnms-completion.bash /etc/bash_completion.d/ 2>/dev/null || true
cp /opt/librenms/misc/librenms.logrotate /etc/logrotate.d/librenms 2>/dev/null || true

# repair helper for pre-existing installs: APP_KEY in .env is mandatory
grep -q '^APP_KEY=' /opt/librenms/.env 2>/dev/null || \
  echo "APP_KEY=base64:$(openssl rand -base64 32)" >> /opt/librenms/.env

# --- enable Oxidized integration inside LibreNMS config.php ------------------
LX_CFG=/opt/librenms/config.php
# A fresh git clone (or empty/tag-less file) makes the stanzas below inert:
# without the "<?php" open tag config.php is echoed as HTML, never executed,
# so Oxidized never shows up in the LibreNMS UI. Write a complete valid file
# when missing/empty/without open tag; otherwise append only what's absent.
if [ ! -s "$LX_CFG" ] || ! grep -q '^<?php' "$LX_CFG" 2>/dev/null; then
  {
    echo '<?php'
    echo ''
    echo "\$config['oxidized']['enabled']   = true;"
    echo "\$config['oxidized']['url']       = 'http://127.0.0.1:${OX_PORT}';"
    echo "\$config['oxidized']['default_group'] = '${LX_DEFAULT_GROUP}';"
    echo "\$config['oxidized']['features']['versioning'] = true;"
    echo "\$config['oxidized']['reload_nodes'] = true;"
    echo "\$config['oxidized']['groups'] = false;"
    echo ''
    echo "\$config['api']['enabled'] = true;"
  } > "$LX_CFG"
  chown librenms:librenms "$LX_CFG"
  chmod 644 "$LX_CFG"
else
  grep -q "'oxidized'" "$LX_CFG" 2>/dev/null || cat >> "$LX_CFG" <<EOF

// --- oxidized integration (added by deploy/install.sh) ---
\$config['oxidized']['enabled']   = true;
\$config['oxidized']['url']       = 'http://127.0.0.1:${OX_PORT}';
\$config['oxidized']['default_group'] = '${LX_DEFAULT_GROUP}';
\$config['oxidized']['features']['versioning'] = true;
\$config['oxidized']['reload_nodes'] = true;
\$config['oxidized']['groups'] = false;
EOF
  grep -q "api\['enabled'\]" "$LX_CFG" 2>/dev/null || \
    printf "\n\$config['api']['enabled'] = true;\n" >> "$LX_CFG"
fi
# ConfigRepository caches the merged settings (Laravel file cache). Without a
# clear, a previously broken/empty config.php stays cached and Oxidized stays
# hidden in the UI even after the file is fixed.
su -s /bin/bash librenms -c "cd /opt/librenms && php lnms config:clear" >/dev/null 2>&1 || true

# LibreNMS nginx + fpm
log "== Phase 3: nginx + php-fpm (LibreNMS) ================================="
# rrd_dir (validate.php wants /opt/librenms/rrd on 0775; storage/rrd is the
# newer default the graph code also uses) - both writable by the librenms user.
mkdir -p /opt/librenms/rrd /opt/librenms/storage/rrd /opt/librenms/bootstrap/cache
chown -R librenms:librenms /opt/librenms 2>/dev/null || true
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

sed -e 's/^    listen      80;/    listen      '"${LX_SITE_FQDN}:${LX_SITE_PORT}"';/' \
    -e 's/server_name.*;/server_name '"${LX_SITE_FQDN}"';/' \
    "${ROOTDIR}/deploy/templates/nginx-librenms.conf" > /etc/nginx/conf.d/librenms.conf

# =============================================================================
log "== Phase 4: Oxidized (Ruby daemon + REST :8888) ========================"
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
  gem install oxidized-web --no-document 2>&1 | tail -4 || \
    warn "oxidized-web gem failed to install - REST API on :${OX_PORT} will not work"
fi

mkdir -p /etc/oxidized /home/oxidized/configs /home/oxidized/.config/oxidized
id oxidized >/dev/null 2>&1 || useradd -r -m -d /home/oxidized -s /bin/bash oxidized
chown -R oxidized:oxidized /home/oxidized

# Oxidized pulls the device list from LibreNMS REST API.
# LibreNMS /api/v0/oxidized requires a valid API token, so one is created for
# the LibreNMS admin below and injected into the source http headers.
# (Reuse an existing token on reruns so reruns don't pile up DB tokens.)
OX_TOKEN="$(sed -n "s/.*X-Auth-Token: '\([^']*\)'.*/\1/p" /etc/oxidized/config 2>/dev/null | head -1)" || true
if [ -z "$OX_TOKEN" ]; then
  # pipefail-safe: a non-zero artisan exit must never abort the whole install
  # (a silent pipeline failure under set -euo pipefail kills the run mid-phase).
  # The error text is kept visible so a failure is diagnosable in the log.
  OX_TOKEN="$(su -s /bin/bash librenms -c "cd /opt/librenms && php artisan api:token-create '${LX_ADMIN_USER}' --name=oxidized" 2>&1 | awk '/^[0-9]+\|/{print; exit}')" || true
  if [ -n "$OX_TOKEN" ]; then
    echo ">> Oxidized API token created"
  else
    warn "could not create a LibreNMS API token for Oxidized"
  fi
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
  warn "No LibreNMS API token could be created - Oxidized cannot fetch devices (add X-Auth-Token to /etc/oxidized/config)"
fi
chown -R oxidized:oxidized /etc/oxidized

OXIDIZED_BIN="$(command -v oxidized || true)"
if [ -z "$OXIDIZED_BIN" ]; then
    for c in /usr/local/bin/oxidized /var/lib/gems/*/bin/oxidized /usr/lib/ruby/gems/*/bin/oxidized; do
        [ -x "$c" ] && { OXIDIZED_BIN="$c"; break; }
    done
fi
[ -n "$OXIDIZED_BIN" ] || warn "oxidized binary not found - supply ExecStart in /etc/systemd/system/oxidized.service"

cat > /etc/systemd/system/oxidized.service <<UNIT
[Unit]
Description=Oxidized - Network Device Configuration Backup
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${OXIDIZED_BIN:-/usr/local/bin/oxidized}
User=oxidized
KillSignal=SIGKILL
Environment="OXIDIZED_HOME=/etc/oxidized"
Restart=on-failure
RestartSec=300s

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now oxidized >/dev/null 2>&1 || warn "oxidized start delayed (needs LibreNMS running)"

# =============================================================================
log "== Phase 5: oxidized-web PHP app (:${OXWEB_PORT}) ======================"
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

sed -e "s/listen .*8889;/listen ${OXWEB_FQDN}:${OXWEB_PORT};/" \
    "${ROOTDIR}/deploy/templates/nginx-oxidized-web.conf" > /etc/nginx/conf.d/oxidized-web.conf

# =============================================================================
log "== Phase 6: start services + first admin ================================"
systemctl restart "php${PHP_VER}-fpm" nginx >/dev/null 2>&1 || true
sleep 3
# oxidized crashed early (LibreNMS wasn't up yet); restart it so it picks up
# the freshly injected API token and the now-live LibreNMS API
systemctl restart oxidized >/dev/null 2>&1 || true
sleep 2

# bootstrap first admin in oxidized-web (idempotent: only if users table empty)
if ! php -r '$d=new PDO("sqlite:/opt/oxidized-web/data/oxidized.db"); $n=(int)$d->query("SELECT COUNT(*) FROM users")->fetchColumn(); exit($n>0?0:1);' 2>/dev/null; then
  php -r '
    $dir="/opt/oxidized-web/data";
    if(!is_dir($dir)){mkdir($dir,0770,true);}
    $d=new PDO("sqlite:".$dir."/oxidized.db");
    $d->exec("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL UNIQUE, password_hash TEXT NOT NULL, role TEXT NOT NULL DEFAULT '\''user'\'', email TEXT NOT NULL DEFAULT '\'''\'', created_at TEXT NOT NULL DEFAULT (datetime('\''now'\'')), last_login TEXT DEFAULT NULL)");
    $u="$argv[2]"; $p=password_hash($argv[1], PASSWORD_DEFAULT);
    $s=$d->prepare("INSERT INTO users (username, password_hash, role) VALUES (?,?, '\''admin'\'')");
    $s->execute([$u,$p]); echo "created admin login=".$u."\n";
  ' "${OX_WEB_ADMIN_PASS}" "${OX_WEB_ADMIN_USER}" 2>&1 | grep -E "created admin|Fatal|Exception"
fi
chown -R www-data:www-data /opt/oxidized-web

# =============================================================================
log "== Verify ==============================================================="
# note: systemctl is-active returns non-zero when a unit is not active, so
# every call needs "|| true" - otherwise set -e would abort the verify block
echo -n "nginx:       "; systemctl is-active nginx || true
echo -n "php-fpm:     "; systemctl is-active "php${PHP_VER}-fpm" || true
echo -n "mariadb:     "; systemctl is-active mariadb || true
echo -n "redis:       "; systemctl is-active redis-server || true
echo -n "oxidized:    "; systemctl is-active oxidized || true
# oxidized intentionally stays down while LibreNMS has no devices (stock
# behavior: "source returns no usable nodes"); it retries every 300s
systemctl is-active oxidized >/dev/null 2>&1 || \
  warn "oxidized не активен: штатно, пока в LibreNMS нет устройств (см. шаг 2 в итогах)"
echo -n "librenms db: "; mysql -e "SELECT 1 FROM \`${LX_DB_NAME}\`.devices LIMIT 1" >/dev/null 2>&1 && echo OK || echo "(empty - fine)"
curl -s -o /dev/null -w "LibreNMS  :${LX_SITE_PORT}      -> HTTP %{http_code}\n"  "http://${LX_SITE_FQDN}:${LX_SITE_PORT}/" || true
curl -s -o /dev/null -w "oxidized-web :${OXWEB_PORT} -> HTTP %{http_code}\n" "http://${OXWEB_FQDN}:${OXWEB_PORT}/" || true

log "== DONE ================================================================"
cat <<SUMMARY

Stack deployed:
  LibreNMS      http://${LX_SITE_FQDN}:${LX_SITE_PORT}/   admin ${LX_ADMIN_USER} / (см. секреты)
  Oxidized REST http://${OX_HOST}:${OX_PORT}
  oxidized-web  http://${OXWEB_FQDN}:${OXWEB_PORT}/       admin ${OX_WEB_ADMIN_USER} / (см. секреты)

MySQL accounts:
  ${LX_DB_USER} (all on ${LX_DB_NAME})  pass: ${LX_DB_PASS}
  ${APP_DB_USER} (SELECT only)          pass: ${APP_DB_PASS}

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