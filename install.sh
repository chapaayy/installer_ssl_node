#!/usr/bin/env bash
set -Eeuo pipefail
set +x

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
STACK_DIR="/opt/remnanode-stack"
ENV_FILE="${STACK_DIR}/.env"
COMPOSE_FILE="${STACK_DIR}/docker-compose.yml"
BACKUP_ROOT="${STACK_DIR}/backups"
LAUNCHER_PATH="/usr/local/bin/remnanode-stack"
UNIT_FILE="/etc/systemd/system/remnanode-stack.service"
AUTO_YES=0

OLD_SYSTEMD_UNITS=(
  remnawave-port80-lockdown.service
  remnawave-acme-renew.service
  remnawave-acme-renew.timer
)

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"; }
info() { log INFO "$*"; }
warn() { log WARN "$*" >&2; }
error() { log ERROR "$*" >&2; }
die() { error "$*"; exit 1; }

PROGRESS_TOTAL=0
PROGRESS_CURRENT=0

progress_reset() {
  PROGRESS_TOTAL="$1"
  PROGRESS_CURRENT=0
}

progress_bar() {
  local pct="$1"
  local width=24
  local filled empty

  filled=$((pct * width / 100))
  empty=$((width - filled))
  printf '['
  printf '%*s' "$filled" '' | tr ' ' '#'
  printf '%*s' "$empty" '' | tr ' ' '.'
  printf '] %3d%%' "$pct"
}

progress_step() {
  local message="$1"
  local pct=100

  if [[ "$PROGRESS_TOTAL" -gt 0 ]]; then
    PROGRESS_CURRENT=$((PROGRESS_CURRENT + 1))
    pct=$((PROGRESS_CURRENT * 100 / PROGRESS_TOTAL))
  fi

  info "$(progress_bar "$pct") ${PROGRESS_CURRENT}/${PROGRESS_TOTAL} ${message}"
}

progress_done() {
  info "$(progress_bar 100) Done"
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Нужен root: запусти sudo bash install.sh или sudo remnanode-stack"
}

require_debian_or_ubuntu() {
  [[ -r /etc/os-release ]] || die "Не могу определить ОС: нет /etc/os-release"

  # shellcheck disable=SC1091
  . /etc/os-release

  local os_id="${ID:-}"
  local os_like=" ${ID_LIKE:-} "
  case "$os_id" in
    ubuntu|debian)
      info "Поддерживаемая ОС: ${PRETTY_NAME:-$os_id}"
      return 0
      ;;
  esac

  if [[ "$os_like" == *" debian "* ]]; then
    info "Debian-like ОС: ${PRETTY_NAME:-$os_id}"
    return 0
  fi

  die "Неподдерживаемая ОС: ${PRETTY_NAME:-unknown}. Нужен Ubuntu/Debian."
}

run_script() {
  local script="$1"
  shift || true
  [[ -f "${SCRIPT_DIR}/scripts/${script}" ]] || die "Нет скрипта: ${SCRIPT_DIR}/scripts/${script}"
  bash "${SCRIPT_DIR}/scripts/${script}" "$@"
}

ensure_env_ready() {
  local rc=0

  set +e
  run_script generate_env.sh
  rc=$?
  set -e

  return "$rc"
}

ensure_secret_ready() {
  if [[ -z "${SECRET_KEY:-}" ]]; then
    die "SECRET_KEY пустой. Заполни SECRET_KEY вручную или настрой PANEL_DOMAIN/PANEL_API_TOKEN/PANEL_CONFIG_PROFILE_UUID/PANEL_ACTIVE_INBOUND_UUIDS для регистрации через панель."
  fi
}

strip_quotes() {
  local value="$1"
  value="${value%$'\r'}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "$value"
}

load_env() {
  [[ -f "$ENV_FILE" ]] || die "Нет runtime .env: ${ENV_FILE}"

  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -n "$line" && "${line:0:1}" != "#" ]] || continue
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue

    key="${BASH_REMATCH[1]}"
    value="$(strip_quotes "${BASH_REMATCH[2]}")"
    if [[ "$key" == "STACK_DIR" ]]; then
      [[ -z "$value" || "$value" == "$STACK_DIR" ]] || warn "STACK_DIR в .env игнорируется; runtime-путь фиксированный: ${STACK_DIR}"
      continue
    fi
    printf -v "$key" '%s' "$value"
    export "$key"
  done < "$ENV_FILE"
}

load_env_if_exists() {
  [[ -f "$ENV_FILE" ]] && load_env || true
}

escape_sed_pattern() {
  printf '%s' "$1" | sed 's/[][\\.^$*+?{}()|]/\\&/g'
}

redact_stream() {
  local sed_args=(
    -e 's|(PANEL_API_TOKEN[=:][[:space:]]*)[^[:space:]]+|\1[REDACTED_PANEL_API_TOKEN]|g'
    -e 's|(SECRET_KEY[=:][[:space:]]*)[^[:space:]]+|\1[REDACTED_SECRET_KEY]|g'
  )

  if [[ -n "${PANEL_API_TOKEN:-}" ]]; then
    sed_args+=(-e "s|$(escape_sed_pattern "$PANEL_API_TOKEN")|[REDACTED_PANEL_API_TOKEN]|g")
  fi
  if [[ -n "${SECRET_KEY:-}" ]]; then
    sed_args+=(-e "s|$(escape_sed_pattern "$SECRET_KEY")|[REDACTED_SECRET_KEY]|g")
  fi

  sed -E "${sed_args[@]}"
}

require_docker_compose_v2() {
  command -v docker >/dev/null 2>&1 || die "Docker CLI не установлен"
  docker compose version >/dev/null 2>&1 || die "Нужен Docker Compose V2: docker compose недоступен"
}

compose() {
  require_docker_compose_v2
  [[ -f "$COMPOSE_FILE" ]] || die "Compose file не найден: ${COMPOSE_FILE}"
  docker compose --project-directory "$STACK_DIR" "$@"
}

show_cmd() {
  printf '\n$ %s\n' "$*"
  "$@" || true
}

confirm() {
  local message="$1"

  if [[ "${AUTO_YES:-0}" -eq 1 ]]; then
    info "Auto-confirmed: ${message}"
    return 0
  fi

  if command -v whiptail >/dev/null 2>&1; then
    whiptail --title "Remnanode Stack" --yesno "$message" 10 78
    return $?
  fi

  local answer
  printf '%s [y/N]: ' "$message"
  read -r answer
  case "${answer,,}" in
    y|yes|д|да) return 0 ;;
    *) return 1 ;;
  esac
}

pause_menu() {
  printf '\nНажми Enter, чтобы вернуться в меню...'
  read -r _ || true
}

quote_shell_arg() {
  printf '%q' "$1"
}

install_launcher() {
  require_root

  local script_path quoted_script
  script_path="${SCRIPT_DIR}/install.sh"
  quoted_script="$(quote_shell_arg "$script_path")"

  mkdir -p "$(dirname "$LAUNCHER_PATH")"
  cat > "$LAUNCHER_PATH" <<EOF
#!/usr/bin/env bash
exec bash ${quoted_script} "\$@"
EOF
  chmod 755 "$LAUNCHER_PATH"
  info "Launcher установлен: ${LAUNCHER_PATH}"
}

backup_old_unit() {
  local unit="$1"
  local backup_dir="$2"
  local path

  mkdir -p "$backup_dir"
  systemctl cat "$unit" > "${backup_dir}/${unit}.systemctl-cat.txt" 2>/dev/null || true

  for path in \
    "/etc/systemd/system/${unit}" \
    "/run/systemd/system/${unit}" \
    "/usr/lib/systemd/system/${unit}" \
    "/lib/systemd/system/${unit}"
  do
    if [[ -e "$path" ]]; then
      cp -a "$path" "${backup_dir}/"
    fi
  done
}

unit_exists() {
  local unit="$1"
  systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q . && return 0
  systemctl status "$unit" >/dev/null 2>&1 && return 0
  return 1
}

old_services_present() {
  command -v systemctl >/dev/null 2>&1 || return 1

  local unit
  for unit in "${OLD_SYSTEMD_UNITS[@]}"; do
    if unit_exists "$unit"; then
      return 0
    fi
  done
  return 1
}

disable_old_services() {
  require_root

  command -v systemctl >/dev/null 2>&1 || {
    warn "systemctl недоступен; старые сервисы отключить нельзя"
    return 0
  }

  if ! old_services_present; then
    info "Старые конфликтующие сервисы не найдены"
    return 0
  fi

  confirm "Отключить старые конфликтующие сервисы nginx/acme/port80-lockdown? Перед отключением будет создан backup." || {
    warn "Отключение старых сервисов отменено"
    return 1
  }

  local ts backup_dir unit
  ts="$(date '+%Y%m%d-%H%M%S')"
  backup_dir="${BACKUP_ROOT}/${ts}/old-systemd-units"

  mkdir -p "$BACKUP_ROOT"
  chmod 700 "$BACKUP_ROOT" 2>/dev/null || true

  for unit in "${OLD_SYSTEMD_UNITS[@]}"; do
    if unit_exists "$unit"; then
      backup_old_unit "$unit" "$backup_dir"
      info "Останавливаю и отключаю старый unit: ${unit}"
      systemctl disable --now "$unit" >/dev/null 2>&1 || warn "Не удалось полностью отключить ${unit}; проверь systemctl status ${unit}"
    else
      info "Unit не найден: ${unit}"
    fi
  done

  chmod -R go-rwx "${BACKUP_ROOT}/${ts}" 2>/dev/null || true
  systemctl daemon-reload || true
  info "Backup старых unit сохранён: ${backup_dir}"
}

show_service_logs_tail() {
  local service="$1"
  local lines="${2:-80}"

  if [[ -f "$COMPOSE_FILE" ]] && command -v docker >/dev/null 2>&1; then
    warn "Последние логи ${service}:"
    docker compose --project-directory "$STACK_DIR" logs --tail="$lines" "$service" 2>&1 | redact_stream || true
  fi
}

show_remnanode_xray_logs() {
  command -v docker >/dev/null 2>&1 || return 0
  docker ps -a --format '{{.Names}}' | grep -qx remnanode || return 0

  warn "Внутренние логи Xray в контейнере remnanode:"
  docker exec remnanode sh -c '
    for file in /var/log/supervisor/xray.out.log /var/log/supervisor/xray.err.log; do
      echo "== ${file} =="
      if [ -f "$file" ]; then
        tail -n 120 "$file"
      else
        echo "missing"
      fi
    done
  ' 2>&1 | redact_stream || true
}

check_remnanode_xray_errors() {
  command -v docker >/dev/null 2>&1 || return 0
  docker ps -a --format '{{.Names}}' | grep -qx remnanode || return 0

  local recent xray_logs
  recent="$(docker logs --tail=250 remnanode 2>&1 | redact_stream || true)"
  xray_logs="$(
    docker exec remnanode sh -c '
      cat /var/log/supervisor/xray.out.log /var/log/supervisor/xray.err.log 2>/dev/null | tail -n 260
    ' 2>&1 | redact_stream || true
  )"

  if printf '%s\n%s\n' "$recent" "$xray_logs" | grep -Eq 'RN-001|SPAWN_ERROR: xray|Xray core failed to start|ECONNREFUSED 127\.0\.0\.1:61000|bind: address already in use|/opt/nginx/certs'; then
    warn "remnanode запущен, но Xray внутри контейнера падает. Нода может отображаться offline в панели."
    printf '%s\n%s\n' "$recent" "$xray_logs" | grep -E 'RN-001|SPAWN_ERROR: xray|Xray core failed to start|ECONNREFUSED 127\.0\.0\.1:61000|bind: address already in use|/opt/nginx/certs' | tail -n 30 >&2 || true

    if printf '%s\n' "$xray_logs" | grep -q 'listen tcp 0.0.0.0:443: bind: address already in use'; then
      warn "Xray inbound из панели пытается занять 443/tcp, но 443 уже занят Caddy. В новой архитектуре Caddy владеет 80/443."
      warn "Исправь inbound в Config Profile панели: перенеси Xray TLS inbound с 443 на другой порт или используй профиль без прямого TLS inbound на 443."
    fi

    if printf '%s\n' "$xray_logs" | grep -q '/opt/nginx/certs'; then
      warn "Xray config из панели всё ещё ссылается на старые nginx/acme сертификаты в /opt/nginx/certs."
      warn "В новой Caddy-архитектуре эти пути не создаются. Убери старые certificateFile/keyFile из Xray Config или замени профиль на совместимый с Caddy."
    fi

    show_remnanode_xray_logs
    return 1
  fi

  info "Критичных ошибок Xray в свежих логах remnanode не найдено"
}

check_url_once() {
  local url="$1"

  if ! command -v curl >/dev/null 2>&1; then
    warn "curl недоступен; проверка пропущена: ${url}"
    return 0
  fi

  curl -kI --max-time 20 "$url"
}

check_url() {
  local url="$1"
  local attempts="${2:-1}"
  local delay="${3:-10}"
  local i

  info "Проверяю ${url}"
  for ((i = 1; i <= attempts; i++)); do
    if check_url_once "$url"; then
      return 0
    fi
    if ((i < attempts)); then
      warn "Проверка не прошла: ${url}; повтор через ${delay}s (${i}/${attempts})"
      sleep "$delay"
    fi
  done

  warn "HTTP-проверка не прошла: ${url}"
  return 1
}

check_node_port() {
  load_env_if_exists

  local port="${NODE_PORT:-2222}"

  info "Проверяю локальный порт remnanode: 127.0.0.1:${port}"
  if command -v ss >/dev/null 2>&1; then
    if ss -ltn "( sport = :${port} )" | grep -q ":${port}"; then
      info "remnanode слушает порт ${port}"
    else
      warn "remnanode не слушает порт ${port}; панель не сможет увидеть ноду"
      show_service_logs_tail remnanode 120
      return 1
    fi
  elif ! timeout 5 bash -c "</dev/tcp/127.0.0.1/${port}" >/dev/null 2>&1; then
    warn "Не удалось подключиться к 127.0.0.1:${port}; панель не сможет увидеть ноду"
    show_service_logs_tail remnanode 120
    return 1
  fi

  warn "Проверь, что панель может достучаться до ${DOMAIN:-DOMAIN}:${port}. Инсталлер не открывает firewall автоматически."
  check_remnanode_xray_errors
}

wait_for_compose_settle() {
  local seconds="${1:-20}"
  info "Жду ${seconds}s, чтобы контейнеры успели пройти healthcheck и Caddy начал выпуск сертификата"
  sleep "$seconds"
}

post_failure_hints() {
  local https_failed="$1"
  local node_failed="$2"

  if [[ "$https_failed" -eq 1 ]]; then
    warn "HTTPS ещё не поднялся. Чаще всего это DNS, закрытые 80/443 снаружи или задержка выпуска сертификата Caddy."
    show_service_logs_tail caddy 120
  fi

  if [[ "$node_failed" -eq 1 ]]; then
    warn "Нода в панели будет offline, если ${DOMAIN:-DOMAIN}:${NODE_PORT:-2222} недоступен с сервера панели."
    warn "Если порт слушается, но Xray падает с RN-001/SPAWN_ERROR, исправь Xray Config в панели и сохрани профиль."
    warn "Минимальная проверка на VPS: ss -ltnp | grep ':${NODE_PORT:-2222}', docker logs --tail=200 remnanode и docker exec remnanode tail -n 120 /var/log/supervisor/xray.err.log"
  fi
}

final_status() {
  load_env_if_exists
  local https_failed=0
  local node_failed=0

  wait_for_compose_settle 20
  info "Compose status"
  compose ps || true

  info "Docker containers"
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true

  if [[ -n "${DOMAIN:-}" ]]; then
    check_url "http://${DOMAIN}" 2 5 || true
    check_url "https://${DOMAIN}" 6 10 || https_failed=1
  else
    warn "DOMAIN пустой; HTTP/HTTPS-проверки пропущены"
  fi

  check_node_port || node_failed=1
  post_failure_hints "$https_failed" "$node_failed"
}

do_install() {
  confirm "Установить или обновить remnanode stack? Это изменит файлы в /opt/remnanode-stack и перезапустит стек." || {
    info "Установка/обновление отменены"
    return 0
  }

  progress_reset 14

  progress_step "Проверка root и ОС"
  require_root
  require_debian_or_ubuntu

  local rc=0
  progress_step "Подготовка окружения и .env в ${STACK_DIR}"
  set +e
  ensure_env_ready
  rc=$?
  set -e
  if [[ "$rc" -eq 2 ]]; then
    warn "Создан .env. Заполни его и снова запусти меню установки."
    return 0
  fi
  [[ "$rc" -eq 0 ]] || return "$rc"

  progress_step "Загрузка runtime .env"
  load_env

  progress_step "Установка Docker и Docker Compose V2"
  run_script install_docker.sh

  progress_step "Проверка Docker Compose V2"
  require_docker_compose_v2

  progress_step "Отключение старых конфликтующих сервисов"
  disable_old_services || return 1

  progress_step "Регистрация ноды в панели"
  run_script register_panel.sh

  progress_step "Проверка переменных remnanode"
  load_env
  ensure_secret_ready

  progress_step "Генерация docker-compose.yml и Caddyfile"
  run_script generate_compose.sh

  progress_step "Настройка logrotate"
  run_script setup_logrotate.sh

  progress_step "Настройка systemd unit"
  run_script setup_systemd.sh

  progress_step "Установка launcher remnanode-stack"
  install_launcher

  progress_step "Запуск remnanode stack"
  docker compose --project-directory "$STACK_DIR" up -d --remove-orphans

  progress_step "Финальная проверка статуса"
  final_status
  progress_done
}

show_status() {
  require_root
  load_env_if_exists

  if command -v systemctl >/dev/null 2>&1; then
    show_cmd systemctl is-active docker
    show_cmd systemctl is-active remnanode-stack
  else
    warn "systemctl недоступен"
  fi

  if [[ -f "$COMPOSE_FILE" ]]; then
    printf '\n$ cd %s && docker compose ps\n' "$STACK_DIR"
    (cd "$STACK_DIR" && docker compose ps) || true
  else
    warn "Compose file не найден: ${COMPOSE_FILE}"
  fi

  if command -v docker >/dev/null 2>&1; then
    show_cmd docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
  else
    warn "docker недоступен"
  fi

  show_cmd df -h /
}

show_logs_all() {
  require_root
  load_env_if_exists
  compose logs --tail=200 2>&1 | redact_stream || true
}

show_logs_caddy() {
  require_root
  load_env_if_exists
  compose logs --tail=200 caddy 2>&1 | redact_stream || true
}

show_logs_node() {
  require_root
  load_env_if_exists
  compose logs --tail=200 remnanode 2>&1 | redact_stream || true
}

restart_stack() {
  confirm "Перезапустить весь remnanode stack?" || {
    info "Перезапуск stack отменён"
    return 0
  }

  require_root
  compose up -d --remove-orphans
  compose restart
  final_status
}

restart_caddy() {
  confirm "Перезапустить только Caddy?" || {
    info "Перезапуск Caddy отменён"
    return 0
  }

  require_root
  compose up -d caddy
  compose restart caddy
  compose ps caddy
}

restart_node() {
  confirm "Перезапустить только remnanode?" || {
    info "Перезапуск remnanode отменён"
    return 0
  }

  require_root
  compose up -d remnanode
  compose restart remnanode
  compose ps remnanode
}

latest_diagnostic_report() {
  local latest
  latest="$(find "${STACK_DIR}/diagnostics" -maxdepth 1 -type f -name '*.txt' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 {print $2}')"
  [[ -n "$latest" ]] && printf '%s' "$latest"
}

run_diagnose() {
  require_root
  run_script diagnose.sh

  local report
  report="$(latest_diagnostic_report || true)"
  if [[ -n "$report" ]]; then
    info "Последний diagnostic report: ${report}"
  fi
}

run_repair() {
  confirm "Запустить безопасный repair? Он не удаляет /var/lib/docker, не делает prune, не трогает firewall и Caddy volumes." || {
    info "Repair отменён"
    return 0
  }

  require_root
  run_script repair.sh

  if [[ -f "$COMPOSE_FILE" ]]; then
    compose ps || true
  fi
}

read_domain_for_reboot_test() {
  local line key value

  if [[ ! -r "$ENV_FILE" ]]; then
    printf 'DOMAIN'
    return 0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -n "$line" && "${line:0:1}" != "#" ]] || continue
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    [[ "$key" == "DOMAIN" ]] || continue
    value="$(strip_quotes "${BASH_REMATCH[2]}")"
    [[ -n "$value" ]] || break
    printf '%s' "$value"
    return 0
  done < "$ENV_FILE"

  printf 'DOMAIN'
}

show_reboot_check() {
  local domain
  domain="$(read_domain_for_reboot_test)"

  cat <<EOF
Команда reboot здесь НЕ выполняется.
После ручной перезагрузки проверь:

systemctl is-active docker
systemctl is-active remnanode-stack
docker ps -a
cd /opt/remnanode-stack && docker compose ps
journalctl -u docker -b -n 200 --no-pager
journalctl -u remnanode-stack -b -n 200 --no-pager
curl -I https://${domain}
EOF
}

show_paths() {
  cat <<EOF
STACK_DIR=${STACK_DIR}
.env path=${ENV_FILE}
docker-compose.yml path=${COMPOSE_FILE}
Caddyfile path=${STACK_DIR}/Caddyfile
logs path=${STACK_DIR}/logs
diagnostics path=${STACK_DIR}/diagnostics
systemd unit path=${UNIT_FILE}
launcher path=${LAUNCHER_PATH}
installer project path=${SCRIPT_DIR}
EOF
}

menu_choice_whiptail() {
  whiptail --title "Remnanode Stack" --menu "Выбери действие" 24 86 14 \
    "1" "Установить / обновить remnanode stack" \
    "2" "Показать статус" \
    "3" "Показать все логи" \
    "4" "Показать логи Caddy" \
    "5" "Показать логи remnanode" \
    "6" "Перезапустить весь stack" \
    "7" "Перезапустить только Caddy" \
    "8" "Перезапустить только remnanode" \
    "9" "Диагностика" \
    "10" "Безопасный repair" \
    "11" "Проверка после reboot" \
    "12" "Отключить старые конфликтующие сервисы" \
    "13" "Показать пути и конфиги" \
    "0" "Выход" \
    3>&1 1>&2 2>&3
}

menu_choice_plain() {
  local choice
  cat >&2 <<'MENU'

Remnanode Stack
---------------
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
MENU
  printf '\nВыбор: ' >&2
  read -r choice
  printf '%s' "$choice"
}

menu_choice() {
  if command -v whiptail >/dev/null 2>&1; then
    menu_choice_whiptail
  else
    menu_choice_plain
  fi
}

run_action() {
  local action="$1"
  local rc=0

  set +e
  ("$action")
  rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    warn "Действие завершилось с ошибкой: ${action} (exit ${rc})"
  fi

  pause_menu
}

main_menu() {
  local choice

  while true; do
    set +e
    choice="$(menu_choice)"
    local rc=$?
    set -e

    [[ "$rc" -eq 0 ]] || exit 0

    case "$choice" in
      1) run_action do_install ;;
      2) run_action show_status ;;
      3) run_action show_logs_all ;;
      4) run_action show_logs_caddy ;;
      5) run_action show_logs_node ;;
      6) run_action restart_stack ;;
      7) run_action restart_caddy ;;
      8) run_action restart_node ;;
      9) run_action run_diagnose ;;
      10) run_action run_repair ;;
      11) run_action show_reboot_check ;;
      12) run_action disable_old_services ;;
      13) run_action show_paths ;;
      0) exit 0 ;;
      *) warn "Неизвестный пункт меню: ${choice}"; pause_menu ;;
    esac
  done
}

if [[ "${1:-}" == "--internal-auto-install" && "$#" -eq 1 ]]; then
  AUTO_YES=1
  do_install
  exit $?
fi

if (($# > 0)); then
  warn "Быстрые команды отключены. Открываю меню..."
fi

main_menu
