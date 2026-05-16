#!/usr/bin/env bash
set -Eeuo pipefail
set +x

STACK_DIR="/opt/remnanode-stack"
ENV_FILE="${STACK_DIR}/.env"
DOMAIN_VALUE=""
PANEL_API_TOKEN_VALUE=""
SECRET_KEY_VALUE=""

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"; }
info() { log INFO "$*"; }
warn() { log WARN "$*" >&2; }
error() { log ERROR "$*" >&2; }
die() { error "$*"; exit 1; }

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
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

load_runtime_env_for_checks() {
  [[ -r "$ENV_FILE" ]] || return 0

  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -n "$line" && "${line:0:1}" != "#" ]] || continue
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue

    key="${BASH_REMATCH[1]}"
    value="$(strip_quotes "${BASH_REMATCH[2]}")"
    case "$key" in
      DOMAIN) DOMAIN_VALUE="$value" ;;
      PANEL_API_TOKEN) PANEL_API_TOKEN_VALUE="$value" ;;
      SECRET_KEY) SECRET_KEY_VALUE="$value" ;;
    esac
  done < "$ENV_FILE"
}

escape_sed_pattern() {
  printf '%s' "$1" | sed 's/[][\\.^$*+?{}()|]/\\&/g'
}

redact_stream() {
  local sed_args=(
    -e 's|(PANEL_API_TOKEN[=:][[:space:]]*)[^[:space:]]+|\1[REDACTED_PANEL_API_TOKEN]|g'
    -e 's|(SECRET_KEY[=:][[:space:]]*)[^[:space:]]+|\1[REDACTED_SECRET_KEY]|g'
  )

  if [[ -n "$PANEL_API_TOKEN_VALUE" ]]; then
    sed_args+=(-e "s|$(escape_sed_pattern "$PANEL_API_TOKEN_VALUE")|[REDACTED_PANEL_API_TOKEN]|g")
  fi
  if [[ -n "$SECRET_KEY_VALUE" ]]; then
    sed_args+=(-e "s|$(escape_sed_pattern "$SECRET_KEY_VALUE")|[REDACTED_SECRET_KEY]|g")
  fi

  sed -E "${sed_args[@]}"
}

require_stack_dir() {
  [[ -d "$STACK_DIR" ]] || die "Runtime directory is missing: ${STACK_DIR}"
  [[ -f "${STACK_DIR}/docker-compose.yml" ]] || die "Compose file is missing: ${STACK_DIR}/docker-compose.yml"
}

require_docker_compose_v2() {
  command -v docker >/dev/null 2>&1 || die "Docker CLI is not installed"
  docker compose version >/dev/null 2>&1 || die "Docker Compose V2 is required: docker compose is not available"
}

enable_container_services() {
  command -v systemctl >/dev/null 2>&1 || {
    warn "systemctl is not available; skipped docker/containerd enable"
    return 0
  }

  info "Enabling and starting docker/containerd"
  if ! systemctl enable --now docker containerd; then
    warn "systemctl enable --now docker containerd returned an error; continuing with Docker checks"
  fi
}

compose_pull() {
  info "Pulling Compose images"
  if ! docker compose --project-directory "$STACK_DIR" pull 2>&1 | redact_stream; then
    warn "docker compose pull failed; continuing with existing local images"
  fi
}

compose_up() {
  info "Starting Compose stack"
  docker compose --project-directory "$STACK_DIR" up -d --remove-orphans 2>&1 | redact_stream
}

compose_status() {
  info "Compose status"
  docker compose --project-directory "$STACK_DIR" ps 2>&1 | redact_stream || true

  info "Recent Compose logs"
  docker compose --project-directory "$STACK_DIR" logs --tail=100 2>&1 | redact_stream || true

  info "Recent remnanode Xray logs"
  docker exec remnanode sh -c '
    for file in /var/log/supervisor/xray.out.log /var/log/supervisor/xray.err.log; do
      echo "== ${file} =="
      if [ -f "$file" ]; then
        tail -n 100 "$file"
      else
        echo "missing"
      fi
    done
  ' 2>&1 | redact_stream || true
}

check_url() {
  local url="$1"

  if ! command -v curl >/dev/null 2>&1; then
    warn "curl is not available; skipped check: ${url}"
    return 0
  fi

  info "Checking ${url}"
  if ! curl -kI --max-time 20 --retry 2 "$url"; then
    warn "curl check failed: ${url}"
  fi
}

check_domain() {
  if [[ -z "$DOMAIN_VALUE" ]]; then
    warn "DOMAIN is empty or .env is missing; skipped HTTP/HTTPS checks"
    return 0
  fi

  check_url "http://${DOMAIN_VALUE}"
  check_url "https://${DOMAIN_VALUE}"
}

repair_stack() {
  require_root
  load_runtime_env_for_checks
  enable_container_services
  require_stack_dir
  require_docker_compose_v2

  cd "$STACK_DIR"
  compose_pull
  compose_up
  compose_status
  check_domain

  info "Repair completed without deleting Docker data, firewall rules, or Caddy volumes"
}

repair_stack
