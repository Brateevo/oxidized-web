#!/usr/bin/env bash
# =============================================================================
#  install.sh - ONE-SHOT DEPLOY of the full stack on a bare Linux server
#
#  Stack installed (mirrors the production reference at <SERVER_IP>):
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
#  Idempotent: rerun is safe (it detects already-created pieces).
# =============================================================================
set -Eeuo pipefail

ROOTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo checkout
APP_DIR="/opt/oxidized-web"

C_N=$(tput sgr0); C_G=$(tput setaf 2); C_Y=$(tput setaf 3); C_R=$(tput setaf 1)
log()  { echo -e "${C_G}[install]${C_N} $*"; }
warn() { echo -e "${C_Y}[warn]${C_N} $*"; }
die()  { echo -e "${C_R}[error]${C_N} $*" >&2; exit 1; }

ask() { # ask "<prompt>" <varname> [default]
    local prompt="$1" var="$2" def="${3:-}" val
    read -r -p "$(tput bold)${prompt}${C_N} ${def:+[$def] }" val
    printf -v "$var" '%s' "${val:-$def}"
}

ask_pass() { # ask_pass "<prompt>" <varname> <default>
    local prompt="$1" var="$2" def="$3" p1 p2
    while :; do
        read -r -s -p "$(tput bold)${prompt}${C_N} (пусто = сгенерировать) "
        p1="$REPLY"; echo
        if [ -z "$p1" ]; then
            p1="$def"
            printf -v "$var" '%s' "$p1"
            return
        fi
        read -r -s -p "  повторите: "
        p2="$REPLY"; echo
        [ "$p1" = "$p2" ] && { printf -v "$var" '%s' "$p1"; return; }
        warn "Пароли не совпадают, попробуйте ещё раз."
    done
}

# ------------------------------------------------------------------ wizard ---
log "═══ Настройка стека (нажмите Enter = значение по умолчанию) ═══"

LX_DB_NAME="librenms"
ask "Имя БД LibreNMS?"            LX_DB_NAME       "librenms"
ask "MySQL-логин для LibreNMS?"   LX_DB_USER       "librenms"
ask_pass "Пароль MySQL-пользователя '${LX_DB_USER}':" LX_DB_PASS "$(openssl rand -hex 16)"

APP_DB_USER="oxidized_web"
ask "MySQL-аккаунт для oxidized-web (read-only)?" APP_DB_USER "oxidized_web"
ask_pass "Пароль MySQL-пользователя '${APP_DB_USER}':" APP_DB_PASS "$(openssl rand -hex 16)"

ask_pass "Пароль админа LibreNMS (web):"  LX_ADMIN_PASS   "$(openssl rand -hex 10)"
ask "Логин админа LibreNMS (web)?"        LX_ADMIN_USER   "admin"
ask "Email админа LibreNMS?"              LX_ADMIN_EMAIL  "admin@localhost"

ask_pass "Пароль админа oxidized-web:"    OX_WEB_ADMIN_PASS "$(openssl rand -hex 10)"
ask "Логин админа oxidized-web?"          OX_WEB_ADMIN_USER "admin"

## ---- nginx / слушатели -----------------------------------------------------
DEFAULT_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
ask "IP/домен LibreNMS (nginx listen+server_name)?" LX_SITE_FQDN "$DEFAULT_IP"
ask "Порт LibreNMS nginx?"               LX_SITE_PORT    "80"
ask "IP/домен oxidized-web?"             OXWEB_FQDN      "${LX_SITE_FQDN}"
ask "Порт oxidized-web nginx?"           OXWEB_PORT      "8889"
ask "Oxidized REST host (bind)?"         OX_HOST         "127.0.0.1"
ask "Oxidized REST порт?"                OX_PORT         "8888"
ask "Группа Oxidized по умолчанию?"      LX_DEFAULT_GROUP "default"

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
    php-fpm php-cli php-cgi php-mysql php-curl php-gd php-xml php-mbstring \
    php-sqlite3 php-redis php-bcmath php-gmp php-intl php-zip php-json \
    python3 python3-pip python3-mysqldb python3-dotenv python3-paramiko \
    composer libapache2-mod-php 2>/dev/null || true
apt-get install -y ruby ruby-dev build-essential libsqlite3-dev libssl-dev 2>/dev/null || true

# PHP version autodetect
PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
PHP_FPM_BIN="php${PHP_VER}-fpm"
command -v "$PHP_FPM_BIN" || apt-get install -y "$PHP_FPM_BIN"
SYSTEM_DEFAULT_PHP_SOCK="/run/php/php${PHP_VER}-fpm.sock"

# =============================================================================
log "== Phase 1: MariaDB - databases and accounts ============================"
systemctl enable --now mariadb redis-server >/dev/null 2>&1 || true
sleep 2

# --- LibreNMS main db + user ---
mysql -e "CREATE DATABASE IF NOT EXISTS \`${LX_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null
mysql -e "CREATE USER IF NOT EXISTS '${LX_DB_USER}'@'localhost' IDENTIFIED BY '${LX_DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON \`${LX_DB_NAME}\`.* TO '${LX_DB_USER}'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# --- read-only account for oxidized-web (devices + locations) ---
mysql -e "CREATE USER IF NOT EXISTS '${APP_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${APP_DB_PASS}';"
mysql -e "CREATE USER IF NOT EXISTS '${APP_DB_USER}'@'localhost' IDENTIFIED BY '${APP_DB_PASS}';"
mysql -e "CREATE USER IF NOT EXISTS '${APP_DB_USER}'@'%' IDENTIFIED BY '${APP_DB_PASS}';"
mysql -e "GRANT SELECT ON \`librenms\`.* TO '${APP_DB_USER}'@'127.0.0.1';"
mysql -e "GRANT SELECT ON \`librenms\`.\`locations\` TO '${APP_DB_USER}'@'localhost';"
mysql -e "GRANT SELECT ON \`librenms\`.\`devices\`  TO '${APP_DB_USER}'@'localhost';"
mysql -e "GRANT SELECT ON \`librenms\`.\`locations\` TO '${APP_DB_USER}'@'%';"
mysql -e "GRANT SELECT ON \`librenms\`.\`devices\`  TO '${APP_DB_USER}'@'%';"
mysql -e "FLUSH PRIVILEGES;"

# =============================================================================
log "== Phase 2: LibreNMS (git install into /opt/librenms) ==================="
if [ ! -d /opt/librenms/.git ]; then
  id librenms >/dev/null 2>&1 || useradd -r -M -d /opt/librenms -s /bin/bash librenms
  git clone https://github.com/librenms/librenms.git /opt/librenms 2>/dev/null || \
    die "git clone of librenms failed"
  cd /opt/librenms
  composer install --no-dev --no-interaction 2>&1 | tail -3 || \
    warn "composer install had warnings (may be fine if retried)"
  # .env with generated credentials
  cat > /opt/librenms/.env <<EOF
APP_NAME=LibreNMS
APP_ENV=production
APP_DEBUG=false
APP_URL=${LX_APP_URL}

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
  sudo -u librenms php /opt/librenms/artisan key:generate --force  2>/dev/null || true
  sudo -u librenms php /opt/librenms/artisan migrate --force 2>&1 | tail -2 || \
    warn "migrate failed - rerun after services are up"
  # first LibreNMS admin (official CLI helper; level 10 = admin)
  if [ -f /opt/librenms/scripts/adduser.php ]; then
    sudo -u librenms php /opt/librenms/scripts/adduser.php \
        "${LX_ADMIN_USER}" "${LX_ADMIN_PASS}" "${LX_ADMIN_EMAIL}" 10 \
        2>&1 | tail -2 || warn "adduser.php failed (rerun manually)"
  else
    warn "scripts/adduser.php not found - create admin in web UI"
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

# --- enable Oxidized integration inside LibreNMS config.php ------------------
LX_CFG=/opt/librenms/config.php
touch "$LX_CFG"
grep -q "'oxidized'" "$LX_CFG" 2>/dev/null || cat >> "$LX_CFG" <<EOF

// --- oxidized integration (added by deploy/install.sh) ---
\$config['oxidized']['enabled']   = true;
\$config['oxidized']['url']       = 'http://127.0.0.1:${OX_PORT}';
\$config['oxidized']['default_group'] = '${LX_DEFAULT_GROUP}';
\$config['oxidized']['features']['versioning'] = true;
\$config['oxidized']['groups'] = false;
EOF
grep -q "api\['enabled'\]" "$LX_CFG" 2>/dev/null || cat >> "$LX_CFG" <<'EOF'

// --- LibreNMS REST API (consumed by Oxidized for device list) ---
$config['api']['enabled'] = true;
EOF

# LibreNMS nginx + fpm
log "== Phase 3: nginx + php-fpm (LibreNMS) ================================="
mkdir -p /opt/librenms/storage/rrd /opt/librenms/bootstrap/cache
chown -R librenms:librenms /opt/librenms 2>/dev/null || true

cat > /etc/php/${PHP_VER}/fpm/pool.d/librenms.conf <<'LIBPOOL'
[librenms]
user = librenms
group = librenms
listen = /run/php-fpm-librenms.sock
listen.owner = nginx
listen.group = nginx
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
  gem install oxidized --no-document 2>&1 | tail -3 || die "gem install oxidized failed"
fi

mkdir -p /etc/oxidized /home/oxidized/configs /home/oxidized/.config/oxidized
id oxidized >/dev/null 2>&1 || useradd -r -m -d /home/oxidized -s /bin/bash oxidized
chown -R oxidized:oxidized /home/oxidized

# Oxidized pulls the device list from LibreNMS REST API.
# An API token is optional-prod; LibreNMS accepts reads for the /api/v0/oxidized
# endpoint with an enabled API. Adapt headers if your install requires a token:
#   headers: X-Auth-Token: <your_librenms_api_token>
cat > /etc/oxidized/config <<EOF
---
username: oxidized
password: change_me_device_pass
resolve_dns: false
vars:
  enable: enable_secret
next_adds_job: true
interval: 3600
use_syslog: false
debug: false
threads: 30
timeout: 20
retries: 3
rest: ${OX_HOST}:${OX_PORT}

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
    delimiter: !ruby/regexp /:/
    map:
      name: hostname
      model: os
      group: group
GROUPS: {}
hooks: {}
EOF
chown -R oxidized:oxidized /etc/oxidized

cat > /etc/systemd/system/oxidized.service <<UNIT
[Unit]
Description=Oxidized - Network Device Configuration Backup
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$(command -v oxidized)
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
cp -r "${ROOTDIR}/public" "${ROOTDIR}/src" /opt/oxidized-web/
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
echo -n "nginx:       "; systemctl is-active nginx
echo -n "php-fpm:     "; systemctl is-active "php${PHP_VER}-fpm"
echo -n "mariadb:     "; systemctl is-active mariadb
echo -n "redis:       "; systemctl is-active redis-server
echo -n "oxidized:    "; systemctl is-active oxidized
echo -n "librenms db: "; mysql -e "SELECT 1 FROM \`${LX_DB_NAME}\`.devices LIMIT 1" >/dev/null 2>&1 && echo OK || echo "(empty - fine)"
curl -s -o /dev/null -w "LibreNMS  :${LX_SITE_PORT}      -> HTTP %{http_code}\n"  "http://${OXWEB_FQDN}:${LX_SITE_PORT}/" || true
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
  2. Устройства автоматически появятся в Oxidized (он читает /api/v0/oxidized).
  3. oxidized-web подхватит их при открытии (имена/локации из MySQL).
  4. Впишите рабочие SSH/ENABLE доступы в /etc/oxidized/config (верхний блок).
  5. За TLS следите отдельно, если хост в открытом интернете.
SUMMARY