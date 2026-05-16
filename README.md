# Remnanode Stack Installer

Новая версия установщика remnanode управляется через интерактивное меню.

Есть два способа подготовки:

- GitHub bootstrap одной командой;
- ручной запуск из папки установщика.

После установки основная команда управления:

```bash
sudo remnanode-stack
```

`remnanode-stack` - это launcher в `/usr/local/bin/remnanode-stack`. Он запускает `install.sh` из `/opt/remnanode-stack-installer` и открывает то же меню из любого места на сервере.

Быстрые команды с аргументами отключены. Если запустить установщик с любым аргументом, кроме внутреннего bootstrap-режима, он просто откроет меню.

## GitHub Bootstrap

Named mode:

```bash
curl -fsSL https://raw.githubusercontent.com/chapaayy/remnanode-stack-installer/main/bootstrap.sh | sudo bash -s -- \
  --panel-api-token "TOKEN" \
  --acme-email "admin@example.com" \
  --panel-domain "panel.example.com" \
  --config-profile-uuid "PROFILE_UUID" \
  --active-inbounds "INBOUND_UUID1,INBOUND_UUID2" \
  --domain "node1.example.com" \
  --auto-install
```

Positional mode:

```bash
curl -fsSL https://raw.githubusercontent.com/chapaayy/remnanode-stack-installer/main/bootstrap.sh | sudo bash -s -- \
  "TOKEN" \
  "admin@example.com" \
  "panel.example.com" \
  "PROFILE_UUID" \
  "INBOUND_UUID1,INBOUND_UUID2" \
  "node1.example.com" \
  --auto-install
```

Порядок positional mode:

```text
1. PANEL_API_TOKEN
2. ACME_EMAIL
3. PANEL_DOMAIN
4. PANEL_CONFIG_PROFILE_UUID
5. PANEL_ACTIVE_INBOUND_UUIDS
6. DOMAIN
```

Для следующей ноды обычно меняется только последний аргумент:

```text
node1.example.com -> node2.example.com
```

Важно: токен в команде может попасть в shell history. Запускайте команду на доверенном сервере и не публикуйте историю shell, скриншоты или логи с токеном.

Если в `bootstrap.sh` не заменён встроенный `DEFAULT_REPO_URL`, передайте репозиторий явно:

```bash
--repo-url "https://github.com/chapaayy/remnanode-stack-installer.git"
```

## Что делает bootstrap

Bootstrap:

- скачивает/обновляет установщик в `/opt/remnanode-stack-installer`;
- создаёт `.env` в `/opt/remnanode-stack-installer/.env`;
- синхронизирует `.env` в `/opt/remnanode-stack/.env`;
- делает backup существующих `.env`;
- выставляет `chmod 600` на `.env`;
- не печатает `PANEL_API_TOKEN`;
- не печатает `SECRET_KEY`;
- при `--auto-install` запускает внутренний режим установки.

Summary bootstrap всегда скрывает секреты:

```text
PANEL_API_TOKEN=***hidden***
SECRET_KEY=***generated/hidden***
```

## Индикатор прогресса

Bootstrap и установка показывают понятные этапы с процентами:

```text
[########................]  33% 2/6 Downloading and syncing installer
[#################.......]  71% 10/14 Настройка logrotate
```

Проценты считаются по этапам установки. Для операций вроде установки Docker или `docker compose up` точный внутренний прогресс недоступен, поэтому рядом остаются обычные логи команд.

Во время долгих Docker/apt операций установщик показывает живой индикатор активности с таймером:

```text
[....#.................]  28s Installing Docker Engine and Compose V2 packages
```

Подробный лог установки Docker пишется в `/tmp/remnanode-stack-install-docker.log`. Если команда завершится ошибкой, установщик покажет последние строки этого лога.

## Ручной первый запуск

Если установщик уже лежит на сервере:

```bash
cd remnanode-stack-installer
cp .env.example .env
nano .env
sudo bash install.sh
```

В меню выберите:

```text
1) Установить / обновить remnanode stack
```

Если `/opt/remnanode-stack/.env` ещё нет, установщик скопирует локальный `.env` в `/opt/remnanode-stack/.env`.

## Формат .env

```env
DOMAIN=
ACME_EMAIL=
NODE_NAME=
TZ=Europe/Berlin
NODE_PORT=2222
SECRET_KEY=
PANEL_DOMAIN=
PANEL_API_TOKEN=
PANEL_CONFIG_PROFILE_UUID=
PANEL_CONFIG_PROFILE_NAME=
PANEL_ACTIVE_INBOUND_UUIDS=
PANEL_AUTO_REGISTER_NODE=1
PANEL_NODE_UUID=
PANEL_NODE_ADDRESS=
PANEL_NODE_COUNTRY_CODE=XX
PANEL_PROVIDER_UUID=
REMNANODE_IMAGE=remnawave/node:latest
DOCKER_LOG_MAX_SIZE=10m
DOCKER_LOG_MAX_FILE=5
```

Значения по умолчанию в bootstrap:

- `NODE_NAME` равен `DOMAIN`, если не передан `--node-name`;
- `TZ=Europe/Berlin`;
- `NODE_PORT=2222`;
- `SECRET_KEY` генерируется автоматически, если не передан `--secret-key`;
- `PANEL_CONFIG_PROFILE_NAME` пустой;
- `PANEL_AUTO_REGISTER_NODE=1`;
- `PANEL_NODE_UUID` пустой;
- `PANEL_NODE_ADDRESS` равен `DOMAIN`, если не передан `--node-address`;
- `PANEL_NODE_COUNTRY_CODE=XX`, можно передать `--country-code`;
- `PANEL_PROVIDER_UUID` пустой, можно передать `--provider-uuid`;
- `REMNANODE_IMAGE=remnawave/node:latest`;
- `DOCKER_LOG_MAX_SIZE=10m`;
- `DOCKER_LOG_MAX_FILE=5`.

## Меню управления

Запуск меню после установки:

```bash
sudo remnanode-stack
```

Пункты меню:

```text
1) Установить / обновить remnanode stack
2) Показать статус
3) Показать все логи
4) Показать логи Caddy
5) Показать логи remnanode
6) Перезапустить весь stack
7) Перезапустить только Caddy
8) Перезапустить только remnanode
9) Диагностика
10) Безопасный repair
11) Проверка после reboot
12) Отключить старые конфликтующие сервисы
13) Показать пути и конфиги
0) Выход
```

Если установлен `whiptail`, меню будет графическим в терминале. Если `whiptail` нет, будет обычное bash-меню.

Опасные действия спрашивают подтверждение:

- установка/обновление;
- перезапуск всего stack;
- перезапуск Caddy;
- перезапуск remnanode;
- безопасный repair;
- отключение старых конфликтующих сервисов.

## Архитектура

Runtime-файлы:

```text
/opt/remnanode-stack/
  .env
  docker-compose.yml
  Caddyfile
  site/
  logs/
    caddy/
    remnanode/
  diagnostics/
  backups/
```

Установщик:

```text
/opt/remnanode-stack-installer/
```

Launcher:

```text
/usr/local/bin/remnanode-stack
```

Systemd unit:

```text
/etc/systemd/system/remnanode-stack.service
```

Systemd запускает стек так:

```bash
/usr/bin/docker compose --project-directory /opt/remnanode-stack up -d --remove-orphans
```

## Что больше не используется

В новой версии нет:

- nginx вообще: публичный reverse proxy делает Caddy, static fallback обслуживается Caddy и внутренним `busybox`;
- `acme.sh`;
- `remnawave-acme-renew.service`;
- `remnawave-acme-renew.timer`;
- `remnawave-port80-lockdown.service`;
- ручного открытия/закрытия порта 80;
- ручного вмешательства в `DOCKER-USER`;
- nginx fail2ban.

## Проверка после reboot

Меню не делает reboot автоматически.

Выберите:

```text
11) Проверка после reboot
```

Установщик покажет команды:

```bash
systemctl is-active docker
systemctl is-active remnanode-stack
docker ps -a
cd /opt/remnanode-stack && docker compose ps
journalctl -u docker -b -n 200 --no-pager
journalctl -u remnanode-stack -b -n 200 --no-pager
curl -I https://DOMAIN
```

## Если Docker после reboot пустой

Откройте меню:

```bash
sudo remnanode-stack
```

Сначала выберите статус, затем диагностику. Если нужно, запустите безопасный repair.

Repair включает Docker/containerd, делает Compose pull/up, показывает статус и логи. Он не удаляет `/var/lib/docker`, не делает `docker system prune -a`, не трогает firewall и не удаляет Caddy volumes.

## Если HTTPS не выпустился

В меню откройте логи Caddy и статус. Проверьте, что домен указывает на сервер, а порты 80 и 443 доступны снаружи.

Не запускайте nginx или другой публичный reverse proxy на 80/443 рядом с Caddy.

## Если нода offline в панели

Контейнер `remnanode` может быть запущен, но панель будет показывать ноду offline, если панель не может подключиться к адресу ноды:

```text
DOMAIN:NODE_PORT
```

По умолчанию это:

```text
your-node-domain.example:2222
```

Проверьте на VPS:

```bash
ss -ltnp | grep ':2222'
docker logs --tail=200 remnanode
docker exec remnanode tail -n 120 /var/log/supervisor/xray.err.log
docker exec remnanode tail -n 120 /var/log/supervisor/xray.out.log
```

Порт `NODE_PORT` должен быть доступен с сервера панели. Инсталлер не открывает firewall автоматически и не меняет `DOCKER-USER`.

Если в логах есть:

```text
RN-001
SPAWN_ERROR: xray
Xray core failed to start
```

то Docker/Caddy уже не главная проблема. Это означает, что Xray внутри `remnanode` не может стартовать из-за конфигурации, которую панель отправила ноде. Обычно нужно исправить Xray Config / Config Profile / inbounds в панели и сохранить профиль заново.

Частые причины после перехода со старой nginx/acme-схемы:

- inbound в Xray Config пытается слушать `0.0.0.0:443`, но порт `443` уже занят Caddy;
- Xray Config ссылается на старые файлы сертификатов вроде `/opt/nginx/certs/*_fullchain.pem`;
- в Config Profile выбран старый TLS inbound, рассчитанный на nginx/acme cert paths.

В новой архитектуре Caddy владеет портами `80/443`. Для Xray нужно выбрать профиль/inbound, который не конфликтует с Caddy, или перенести Xray inbound на отдельный порт и открыть его снаружи.

## Опасная очистка Docker

Обычный repair не удаляет Docker data, volumes Caddy или `/var/lib/docker`.

Не используйте агрессивную очистку Docker как стандартное решение. Сначала сохраните диагностику, проверьте свободное место и убедитесь, что понимаете, какие images, containers, networks или volumes будут затронуты.
