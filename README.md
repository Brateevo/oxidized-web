# OxidizedWeb

Веб-интерфейс к [Oxidized](https://github.com/ytti/oxidized) — системе резервного
копирования конфигураций сетевого оборудования.

## Что такое Oxidized

Oxidized — демон, который:

- обходит сетевые устройства по SSH/Telnet и забирает их конфигурации;
- хранит конфиги в git: каждый узел — отдельный файл, каждое изменение — коммит
  с возможностью откатиться на любую версию;
- отдаёт список устройств и конфигурации по REST API.

`oxidized-web` добавляет к этому браузерный интерфейс: список устройств, просмотр
и сравнение версий конфигураций, пользователей с ролями и API-токены.

## Скриншоты

> На скриншотах — демонстрационные данные: имена, локации и IP-адреса вымышленные.

Вход:

![Вход — OxidizedWeb](docs/screenshots/oxidized-web-login.png)

Список устройств:

![Устройства — OxidizedWeb](docs/screenshots/oxidized-web-dashboard.png)

## Интерфейс с телефона

Проверять, что с конфигурациями всё в порядке, часто удобнее не из кабинета, а с
телефона — в дороге, на обходе или прямо от стойки. Отдельной мобильной версии у
OxidizedWeb нет: это **тот же самый интерфейс**, который просто подстраивается под
ширину экрана. Всё, что есть на десктопе — список устройств, текущая конфигурация,
история версий и сравнение — доступно и на телефоне.

<p align="center">
  <img src="docs/screenshots/oxidized-web-mobile.png" width="270" alt="Список устройств на телефоне">
  &nbsp;&nbsp;
  <img src="docs/screenshots/oxidized-web-mobile-login.png" width="270" alt="Вход на телефоне">
</p>

Чтобы пользоваться с телефона, достаточно открыть адрес панели в браузере и добавить
страницу на домашний экран — устанавливать ничего не нужно. Для Android есть готовый
APK — тонкая обёртка того же веб-интерфейса:
[`apk/OxidizedMobile-v1.3.apk`](apk/OxidizedMobile-v1.3.apk). Исходников мобильной
части в этом репозитории не хранятся, залит только артефакт.

## Возможности

- Список узлов: имя, модель, группа, IP, время последнего бэкапа, статус.
- Просмотр текущей конфигурации узла — `/config`.
- История версий и сравнение (diff) любых двух версий — `/versions`, `/diff`.
- Пользователи с ролями `admin` / `user`; для `user` можно ограничить видимые устройства.
- API-токены (Bearer) для автоматизации и внешних интеграций.
- Первичная настройка через мастер `/setup`.
- Безопасность: пароли `bcrypt`, CSRF-токены, блокировка после 5 неудачных попыток
  входа на 15 минут.

## Требования

- **Oxidized** запущен и отвечает по REST API (по умолчанию `http://127.0.0.1:8888`):
  ```bash
  curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8888/nodes   # ожидаем 200
  ```
- **nginx** и **PHP-FPM 8.5+** с расширениями `pdo_mysql`, `sqlite3`, `curl`, `mbstring`.
- **База данных с инвентарём устройств** — необязательно. Нужна, только если хотите видеть
  в панели нормальные имена и локации вместо IP и прочерка. По умолчанию это LibreNMS,
  база `librenms`, таблицы `devices` и `locations`; для автономной установки шаг
  можно пропустить.

`PHP_VER` в командах ниже — ваша версия PHP (`ls /etc/php/`), например `8.5`.

## Установка

Два независимых сценария:

| Сценарий | Где читать |
|---|---|
| **Автономно**, список устройств вручную, без LibreNMS | [`docs/oxidized-standalone.md`](docs/oxidized-standalone.md) — установка Oxidized, список узлов, systemd |
| **С инвентарём LibreNMS**, устройства добавляются в LibreNMS | шаги ниже + [«Как добавить устройство»](#как-добавить-устройство) |

Шаги 1, 4, 5 и 6 одинаковы в обоих случаях — это установка самой панели. Шаги 2 и 3
относятся только к варианту с LibreNMS.

### 1. Скопировать приложение

```bash
sudo mkdir -p /opt/oxidized-web/data/sessions
sudo cp -r public src /opt/oxidized-web/
sudo cp config.example.php /opt/oxidized-web/config.php
sudo chown -R www-data:www-data /opt/oxidized-web
sudo chown root:www-data /opt/oxidized-web/config.php
sudo chmod 640 /opt/oxidized-web/config.php
```

Без LibreNMS файл `config.php` не нужен — панель работает на своём SQLite, а колонки
«Имя» и «Локация» подставят `-`.

### 2. Учётка БД только на чтение

_Только для варианта с LibreNMS._

```bash
DB_PASS="$(openssl rand -base64 18)"
sudo mysql -e "CREATE USER IF NOT EXISTS 'oxidized_web'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
                CREATE USER IF NOT EXISTS 'oxidized_web'@'localhost'  IDENTIFIED BY '${DB_PASS}';
                GRANT SELECT ON librenms.devices   TO 'oxidized_web'@'127.0.0.1';
                GRANT SELECT ON librenms.devices   TO 'oxidized_web'@'localhost';
                GRANT SELECT ON librenms.locations TO 'oxidized_web'@'127.0.0.1';
                GRANT SELECT ON librenms.locations TO 'oxidized_web'@'localhost';
                FLUSH PRIVILEGES;"
echo "пароль БД: ${DB_PASS}"   # он же пойдёт в OX_LX_PASS на шаге 3
```

### 3. Заполнить `config.php`

_Только для варианта с LibreNMS._

```php
<?php
declare(strict_types=1);
const OX_LX_HOST = '127.0.0.1';
const OX_LX_DB   = 'librenms';
const OX_LX_USER = 'oxidized_web';
const OX_LX_PASS = '<ПАРОЛЬ из шага 2>';
```

### 4. Пул php-fpm

`/etc/php/${PHP_VER}/fpm/pool.d/oxidized.conf`:

```ini
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
```

### 5. Виртуальный хост nginx

```bash
sudo cp deploy/templates/nginx-oxidized-web.conf /etc/nginx/conf.d/oxidized-web.conf
# подставьте свой адрес вместо 10.0.0.10
sudo sed -i "s|listen <SERVER_IP>:8889;|listen 10.0.0.10:8889;|" /etc/nginx/conf.d/oxidized-web.conf
sudo nginx -t && sudo systemctl reload nginx
```

### 6. Запуск и первый администратор

```bash
sudo systemctl restart "php${PHP_VER}-fpm"
```

Откройте `http://<ВАШ_IP>:8889` — сработает мастер **«Создайте первого
администратора»**. Готово.

## Как это работает

oxidized-web ничего не опрашивает по SSH — работа с устройствами целиком на Oxidized.
Приложение использует его REST API:

| Запрос | Что даёт |
|---|---|
| `GET /nodes.json` | список узлов: имя, модель, группа, статус, IP, время бэкапа |
| `GET /node/fetch/<имя>` | текущая конфигурация узла |
| `GET /node/version.json?node_full=<имя>` | история версий |
| `GET /node/version/view?node=<имя>&oid=<oid>` | содержимое конкретной версии |

Diff между версиями считается локально. Имена и локации устройств берутся из базы
данных (шаг 2) и подставляются в таблицу; при недоступной БД приложение не падает —
подставляет `-`.

## Как добавить устройство

В этой связке единственный источник правды — **инвентарь LibreNMS**. Oxidized сам
забирает из него список узлов по HTTP (`source: http`), поэтому отдельно заводить хосты
в Oxidized не нужно: достаточно добавить устройство в LibreNMS.

> Этот раздел — про вариант с LibreNMS. В автономной установке источником служит CSV-файл,
> и устройство добавляется дописыванием строки — см.
> [`docs/oxidized-standalone.md`](docs/oxidized-standalone.md#11-добавить-устройство).

Порядок:

1. В LibreNMS откройте **Устройства → Добавить устройство** и укажите IP или hostname,
   версию и community SNMP. Устройство должно отвечать по SNMP, иначе LibreNMS его не
   примет.
2. Проверьте, что LibreNMS верно определил ОС — именно она становится моделью Oxidized
   (`routeros`, `ios`, `dlink`, `eltex`, …):

   ```bash
   mysql -N -e "SELECT hostname, os FROM librenms.devices ORDER BY hostname"
   ```
3. Проверьте, что для этой модели есть поддержка в Oxidized:

   ```bash
   ls /var/lib/gems/*/gems/oxidized-*/lib/oxidized/model/ | grep -x routeros.rb
   ```

   Если модели нет, узел всё равно появится, но со статусом `unsupported` и без
   сохранённой конфигурации.
4. Проверьте, что SSH-логин и пароль устройства совпадают с заданными в
   `/etc/oxidized/config` (`username` / `password`). По умолчанию это одна пара на весь
   парк.
5. Готово. Oxidized подхватит новый узел в течение `reload_interval` (в этом конфиге
   `300` секунд), а первую конфигурацию снимет на ближайшем цикле (`interval`, здесь
   `3600` секунд). В веб-панели устройство появится автоматически.

Заставить применить изменения немедленно:

```bash
sudo systemctl restart oxidized     # перечитывает источник и запускает цикл заново
```

Чего делать не нужно:

- **править файлы вручную.** В Oxidized 0.37 нет `router.db`: список узлов хранится в
  памяти и целиком строится из источника. Добавленные «в обход» хосты исчезнут, потому
  что `next_adds_job: true` удаляет узлы, которых нет в источнике;
- **заводить устройство в веб-панели oxidized-web.** Страница «Пользователи» управляет
  только логинами и доступом пользователей к уже существующим устройствам, но не самим
  парком оборудования.

Если устройство есть в LibreNMS, но не появляется в Oxidized, посмотрите, что реально
отдаёт API — LibreNMS пропускает устройства с признаком `disabled`, а также попадающие
под `oxidized.ignore_types`, `oxidized.ignore_os` или персональный атрибут
`override_Oxidized_disable`:

```bash
TOKEN=$(sudo grep -A2 "headers:" /etc/oxidized/config | grep -oE '[a-f0-9]{32}' | head -1)
curl -s -H "X-Auth-Token: $TOKEN" http://127.0.0.1/api/v0/oxidized
```

Ответ — список вида `[{"hostname":"10.0.0.1","os":"routeros","ip":"10.0.0.1"}, …]`;
из `hostname` берётся имя узла, из `os` — модель. Группы в интерфейс Oxidized можно
передавать полем `group` (включается опциями `oxidized.group_support` и
`oxidized.default_group` в конфиге LibreNMS).

Устройства, которого нет в LibreNMS, штатным способом добавить нельзя: источником задан
именно LibreNMS. Чтобы вести список вручную, пришлось бы менять `source` в
`/etc/oxidized/config` (например, на `csv` или `sqlite` со списком узлов) и отказаться
от автосинхронизации с инвентарём.

## Где что лежит

| Путь | Что это |
|---|---|
| `/opt/oxidized-web/public` | код фронтенда (front-controller `index.php`) |
| `/opt/oxidized-web/src` | ядро: работа с БД, авторизация, клиент Oxidized REST |
| `/opt/oxidized-web/config.php` | параметры подключения к БД (в `.gitignore`) |
| `/opt/oxidized-web/data/oxidized.db` | SQLite: пользователи, привязки к устройствам, API-токены |
| `/etc/nginx/conf.d/oxidized-web.conf` | виртуальный хост |
| `/etc/php/<ver>/fpm/pool.d/oxidized.conf` | пул php-fpm |
| `/etc/oxidized/config` | конфигурация самого Oxidized |
| `/home/oxidized/configs` | git-репозиторий с сохранёнными конфигами |

## Полезные команды

```bash
sudo systemctl restart oxidized        # перезапустить Oxidized после правки конфига
sudo journalctl -u oxidized -f         # журнал Oxidized
sudo systemctl restart php8.5-fpm      # перезапустить пул oxidized-web
sudo tail -f /var/log/nginx/oxidized-web.error.log
git -C /home/oxidized/configs log      # история изменений конфигураций
```

## Мобильное приложение

См. раздел [«Интерфейс с телефона»](#интерфейс-с-телефона) и
[`apk/OxidizedMobile-v1.3.apk`](apk/OxidizedMobile-v1.3.apk).
