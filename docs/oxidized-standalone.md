# Автономная установка Oxidized + oxidized-web

Вариант **без LibreNMS**: список устройств ведётся вручную в CSV-файле, веб-панель
показывает имя узла, модель, IP, группу и статус. Колонка «Локация» останется пустой —
приложение подставит `-`.

Вариант с инвентарём LibreNMS (список устройств берётся из базы, имена и локации
подтягиваются в панель, добавлять устройства нужно в LibreNMS) описан в
[`oxidized-librenms.md`](oxidized-librenms.md).

## Что получится

| Компонент | Версия | Роль |
|---|---|---|
| Oxidized | 0.37.0 | ходит по SSH на устройства, снимает конфигурации, хранит их в git |
| oxidized-web | 0.18.1 | REST API: список узлов, текущая конфигурация, история версий |
| oxidized-web (PHP) | из этого репозитория | веб-интерфейс |

Схема потока:

```text
устройства ──SSH──> Oxidized ──git──> /home/oxidized/configs
                       │
                       └──REST 127.0.0.1:8888──> oxidized-web (PHP) ──> браузер
```

## 1. Пакеты

```bash
sudo apt update
sudo apt install -y \
  ruby ruby-dev build-essential \
  libssl-dev libyaml-dev zlib1g-dev libffi-dev \
  git openssh-client inetutils-telnet
```

`build-essential` и `ruby-dev` нужны только на время установки gem — нативные расширения
(`rugged`, `bcrypt_pbkdf`, `slop`) собираются локально.

## 2. Установка gem

```bash
sudo gem install oxidized oxidized-web
oxidized --version
```

Устанавливается в системные каталоги gem (`/usr/local/bin/oxidized`), отдельный
виртуальный окружение не требуется.

## 3. Пользователь и каталоги

```bash
sudo useradd -m -d /home/oxidized -s /bin/bash oxidized
sudo mkdir -p /home/oxidized/.config/oxidized
sudo chown -R oxidized:oxidized /home/oxidized
```

Каталог конфигурации (`OXIDIZED_HOME`) по умолчанию — `~/.config/oxidized`, сам конфиг
лежит в `$OXIDIZED_HOME/config`. Логи и pid — там же.

## 4. Скелет конфига

```bash
sudo -u oxidized -H oxidized
```

Первый запуск создаст `/home/oxidized/.config/oxidized/config` и выйдет с ошибкой
`NoConfig` — так и задумано, дальше конфиг заполняется руками.

## 5. Конфиг

`/home/oxidized/.config/oxidized/config` — минимально рабочий автономный вариант:

```yaml
username: oxidized
password: 'CHANGE_ME'
resolve_dns: false
interval: 3600
use_syslog: false
debug: false
threads: 30
timeout: 20
retries: 3
next_adds_job: true

extensions:
  oxidized-web:
    load: true
    listen: 127.0.0.1
    port: 8888

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
    email: oxidized@example.net
    repo: /home/oxidized/configs
    as_directory: true

source:
  default: csv
  csv:
    file: /home/oxidized/.config/oxidized/router.db
    delimiter: !ruby/regexp /:/
    map:
      name: 0
      ip: 1
      model: 2
      username: 3
      password: 4
    vars_map:
      enable: 5
      ssh_port: 6
```

Что важно понимать:

- `source.default: csv` — список устройств берётся из локального файла. В Oxidized
  0.37 доступны источники `csv`, `jsonfile`, `sql` и `http`; отдельной базы `router.db`
  больше нет, а `router.db` — это просто имя файла по умолчанию для CSV-источника;
- `map` — какое поле строки становится каким свойством. Обязателен только `name`;
  остальное можно убрать, тогда возьмутся глобальные `username` / `password`;
- `vars_map` — необязательные столбцы, которые уходят в `vars` узла. В примере это
  `enable` для устройств, требующих перехода в привилегированный режим, и `ssh_port`
  для нестандартного порта SSH (это единственный способ его задать — глобального
  параметра порта у входа SSH нет, значение по умолчанию 22 берётся из var `ssh_port`);
- `next_adds_job: true` — новые строки подхватываются сразу, а не только на очередном
  цикле. По умолчанию параметр выключен (`false`);
- `interval` — период полного обхода, `threads` — сколько устройств опрашивается
  одновременно;
- `extensions.oxidized-web` — встроенный REST API и веб-страница самого Oxidized. Слушает
  только локальный адрес: наружу его выставлять не нужно, панель ходит к нему с той же
  машины.

Проверить итоговую сборку конфига вместе со значениями по умолчанию:

```bash
sudo -u oxidized -H oxidized --show-exhaustive-config
```

## 6. Список устройств

`/home/oxidized/.config/oxidized/router.db` — обычный текст, поля разделены двоеточием,
комментарии начинаются с `#`:

```text
# name:ip:model:username:password:enable:ssh_port
rtr01.example.net:192.0.2.1:ios:oxidized:secret::
sw01.example.net:192.0.2.2:ios:oxidized:secret:Cisco:
fw01.example.net:192.0.2.3:ios:oxidized:secret::2222
```

Столбцы, которые не нужны, оставляются пустыми — разделители всё равно должны стоять.
Если `username` и `password` в строке не указаны, возьмутся глобальные значения из
конфига.

```bash
sudo chown oxidized:oxidized /home/oxidized/.config/oxidized/router.db
sudo chmod 600 /home/oxidized/.config/oxidized/router.db
```

Значение `model` должно совпадать с именем файла в каталоге моделей:

```bash
ls "$(ruby -e 'puts Gem::Specification.find_by_name("oxidized").gem_dir')/lib/oxidized/model/" | grep -x ios.rb
```

Если `ip` не указан, имя хоста резолвится через DNS — для больших парков лучше указывать
IP явно, это заметно ускоряет старт.

Альтернатива CSV — JSON-файл (`source.default: jsonfile`), формат объектов вместо
двоеточий удобнее тем, что не требует экранирования:

```yaml
source:
  default: jsonfile
  jsonfile:
    file: /home/oxidized/.config/oxidized/router.json
    map:
      name: hostname
      model: os
```

## 7. Репозиторий для конфигураций

Каталог `repo` из блока `output.git` Oxidized создаёт сам, но git начислит его
недоверенным, если запускать из-под другого пользователя:

```bash
sudo git config --global --add safe.directory /home/oxidized/configs
```

## 8. Автозапуск

Юнит-файл идёт в комплекте с gem:

```bash
sudo cp "$(ruby -e 'puts Gem::Specification.find_by_name("oxidized").gem_dir')/extra/oxidized.service" \
        /etc/systemd/system/oxidized.service
sudo systemctl daemon-reload
sudo systemctl enable --now oxidized
systemctl status oxidized
```

Если конфиг лежит не в домашнем каталоге пользователя, а в `/etc/oxidized`, раскомментируйте
в юните строку `Environment="OXIDIZED_HOME=/etc/oxidized"`.

## 9. Веб-панель

```bash
sudo mkdir -p /opt/oxidized-web/data/sessions
sudo cp -r public src /opt/oxidized-web/
sudo chown -R www-data:www-data /opt/oxidized-web
```

`config.php` в этом варианте **не нужен** — панель создаёт собственный SQLite
(`/opt/oxidized-web/data/oxidized.db`) для пользователей, а подстановка имён и локаций
из внешней БД просто отключается. Дальше — пул php-fpm и виртуальный хот nginx из
[основного README](../README.md#установка), затем первый администратор по адресу
`http://<ВАШ_IP>:8889`.

## 10. Проверка

```bash
curl -s http://127.0.0.1:8888/nodes.json | head -c 300   # список узлов
git -C /home/oxidized/configs log --oneline             # история коммитов с конфигами
sudo journalctl -u oxidized -f                          # живой журнал
```

Ожидаемый результат: в `nodes.json` видны узлы, в репозитории появились файлы вида
`10.0.0.1` или `group/10.0.0.1` (если включены группы), в панели — те же устройства со
сравнением версий.

## 11. Добавить устройство

Дописать строку в `router.db` и перечитать список:

```bash
echo 'rtr02.example.net:192.0.2.4:ios:oxidized:secret::' | sudo -u oxidized tee -a \
  /home/oxidized/.config/oxidized/router.db
sudo systemctl restart oxidized
```

При `next_adds_job: true` устройство попадёт в список сразу после перезапуска, первый
бэкап снимется в ближайшем цикле `interval`.

## Отладка

| Симптом | Что делать |
|---|---|
| Устройство не появилось | `sudo -u oxidized -H oxidized -d` — подробный вывод в терминал |
| Узел в списке, но статус `unsupported` | нет модели: сверьте `model` в строке с файлами в `lib/oxidized/model/` |
| Не логинится по SSH | проверьте пару в `username`/`password` или в строке, для Cisco нужен непустой `enable` |
| `fatal: detected dubious ownership` | `git config --global --add safe.directory /home/oxidized/configs` |
| Панель открывается, список пуст | Oxidized не отвечает на `127.0.0.1:8888` — проверьте блок `extensions` и `systemctl status oxidized` |

Полная документация лежит внутри установленного gem — там же, где он установлен:

```bash
GDIR="$(ruby -e 'puts Gem::Specification.find_by_name("oxidized").gem_dir')"
ls "$GDIR/docs"   # Configuration.md, Sources.md, Inputs.md, Outputs.md, Troubleshooting.md
```
