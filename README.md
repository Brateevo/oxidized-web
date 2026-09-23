# OxidizedWeb — LibreNMS + Oxidized

Web-интерфейс поверх **Oxidized** (резервное копирование конфигураций сетевых устройств)
с данными из **LibreNMS** (инвентаризация, имена, локации). Плюs — автономный и подробный
разбор архитектуры и всех шагов интеграции.

## Состав репозитория

| Файл | Назначение |
|------|------------|
| `config.example.php` | Шаблон конфигурации подключения к БД LibreNMS. **Скопируйте в `config.php`** и укажите свой пароль. Реальный `config.php` в git не попадает (`.gitignore`) |
| `src/oxidized.php` | Ядро интеграции: REST-клиент Oxidized (`/nodes`, `/node/fetch`, версии, diff), helpers `oxz_sysname()` и `oxz_location()` для подтягивания имён/локаций из LibreNMS |
| `public/index.php` | Единая точка входа (front-controller): роутер, таблица устройств, страницы конфига/версий/diff, контроли доступа по пользователям |
| `.gitignore` | Исключает `config.php`, keystore'ы, кэши и локальные файлы сборки |

## Как это устроено (архитектура)

```
LibreNMS ──(inventory: MySQL devices/locations)──► OxidizedWeb (PHP, port 8889)
    │                                                   │
    │ (built-in Oxidized integration)                   │ pulls REST
    ▼                                                   ▼
 Oxidized ────────────────(REST API :8888)───────────► /\nodes.json, /node/fetch
    │
    ▼
 configs backup (git storage)
```

1. **LibreNMS** — система мониторинга/инвентаризации. В её MySQL живут таблицы
   `devices` (IP, hostname, sysName, `location_id`) и `locations` (само название локации).
2. **Oxidized** — демон резервного копирования конфигов. LibreNMS сама передаёт ему список
   устройств через свою встроенную интеграцию, Oxidized хранит конфиги в git.
3. **OxidizedWeb** — кастомный PHP-фронтенд. Он **читает** Oxidized по REST API и
   **обогащает** список устройства данными из БД LibreNMS (константы `OX_LX_*` из `config.php`).

## Пошагово: LibreNMS ↔ Oxidized интеграция

### 1. Oxidized (демон + REST)
- Демон слушает REST API на `127.0.0.1:8888` (`OX_API` в `src/oxidized.php`).
- Эндпоинты, которые использует приложение:
  - `GET /nodes.json` (fallback `/nodes`) — список узлов `[name, model, group, status, ip, time]`
    (`ox_nodes()`);
  - `GET /node/fetch/<name>` — текущий конфиг узла (`ox_fetch_config()`);
  - `GET /node/version.json?node_full=<name>` — история версий (`ox_versions()`);
  - `GET /node/version/view?node=<name>&oid=<oid>&format=json` — содержимое конкретной
    версии (`ox_version_view()`).
- Diff между версиями считается локально LCS-алгоритмом (`render_unified_diff()`),
  без внешних бинарников.

### 2. LibreNMS → обогащение данных
- Приложение подключается к MySQL LibreNMS по учётке из `config.php`
  (`OX_LX_HOST=127.0.0.1`, `OX_LX_DB=librenms`, `OX_LX_USER=oxidized_web`, `OX_LX_PASS=…`).
- `oxz_sysname(string $ip): string` — по IP/имени берёт `sysName` устройства, fallback — hostname:
  ```sql
  SELECT COALESCE(NULLIF(sysName, ''), hostname)
  FROM devices WHERE ip = ? OR hostname = ? LIMIT 1
  ```
- `oxz_location(string $ip): string` — локация через связку `devices.location_id → locations.id`:
  ```sql
  SELECT COALESCE(NULLIF(l.location, ''), '-')
  FROM devices d
  LEFT JOIN locations l ON l.id = d.location_id
  WHERE d.ip = ? OR d.hostname = ? LIMIT 1
  ```
- Провал БД (недоступный MySQL, ошибка подключения) **не валит страницу** — обе функции
  глотают исключение (`Throwable`) и возвращают fallback (`$ip` / `'-'`).

### 3. Права БД (важно!)
Учётке приложения в MySQL LibreNMS должен быть выдан `SELECT` на все используемые таблицы.
**Симптом отсутствия привилегии** на `locations`: колонка «Локация» у всех устройств пустая
(запрос падает с `SELECT command denied`, функция возвращает `-`).

```sql
GRANT SELECT ON librenms.devices   TO 'oxidized_web'@'127.0.0.1';
GRANT SELECT ON librenms.locations TO 'oxidized_web'@'127.0.0.1';
GRANT SELECT ON librenms.*         TO 'oxidized_web'@'127.0.0.1';
FLUSH PRIVILEGES;
```
(аналогично для хостов `'oxidized_web'@'%'` и `'localhost'`, если приложение ходит через них).

### 4. Фронтенд (public/index.php)
- Front-controller: единственный `index.php` разбирает путь и рендерит страницы.
- Таблица устройств на главной (`GET /`): Имя (sysname/имя из LibreNMS), Модель, **Локация**,
  IP, Группа, время бэкапа, статус. Для не-админов список фильтруется по `user_devices`
  (`filter_nodes_by_user()`).
- Страницы: `/config` (текущий конфиг), `/versions` (история), `/version` (версия),
  `/diff` (сравнение), `/users` (управление пользователями), `/login`, `/logout`.
- Защита: авторизация (`require_auth()`), CSRF-токены (`csrf_check()`), HTML-экранирование
  через `e()`.

## APK / мобильное приложение

Репозиторий содержит только **веб-часть** (выбор сделан осознанно, чтобы не тащить
секреты сборки в публичный гит). Мобильная реализация лежит вне этого репозитория —
Android-проект (Kotlin) и приложение на базе веб-представления:
- `OxidizedMobile/app` — исходники Android-приложения (Gradle), собирается в APK;
- `OxidizedPWA` — PWA-обёртка веб-интерфейса для установки на устройство.

> Честно: в рамках сессии, по которой собирается этот репозиторий, детально разобрана и
> проверена именно **веб-интеграция** (файлы в `src/` и `public/` — точные копии рабочей
> инсталляции). Мобильная часть перенесена в отдельные проекты и в этот гит-набор не входит.

## Развёртывание (кратко)

```bash
# 1) скопировать файлы на веб-сервер (пример: /opt/oxidized-web)
# 2) создать конфиг
cp config.example.php config.php   # и вписать OX_LX_PASS

# 3) права БД (см. выше), сделать документ-root на public/
# 4) проверить синтаксис
php -l src/oxidized.php && php -l public/index.php

# 5) nginx: root → /opt/oxidized-web/public, PHP-FPM, порт 8889 (пример слушателя)
```

Требования: PHP 8.1+ (расширения `pdo_mysql`, `curl`, `mbstring`), доступ к MySQL LibreNMS,
доступ по HTTP к Oxidized REST (`127.0.0.1:8888`).