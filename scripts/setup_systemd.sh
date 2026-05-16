#!/usr/bin/env bash
set -Eeuo pipefail
set +x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
STACK_DIR="/opt/remnanode-stack"
UNIT_NAME="remnanode-stack.service"
UNIT_FILE="/etc/systemd/system/${UNIT_NAME}"
UNIT_TEMPLATE="${PROJECT_DIR}/templates/remnanode-stack.service.tpl"
COMPOSE_FILE="${STACK_DIR}/docker-compose.yml"

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"; }
info() { log INFO "$*"; }
warn() { log WARN "$*" >&2; }
error() { log ERROR "$*" >&2; }
die() { error "$*"; exit 1; }

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
}

require_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "systemctl is required"
}

require_runtime_files() {
  [[ -d "$STACK_DIR" ]] || die "Runtime directory is missing: ${STACK_DIR}"
  [[ -f "$COMPOSE_FILE" ]] || die "Compose file is missing: ${COMPOSE_FILE}"
  [[ -f "$UNIT_TEMPLATE" ]] || die "Unit template is missing: ${UNIT_TEMPLATE}"
}

require_docker_compose_v2() {
  [[ -x /usr/bin/docker ]] || die "Docker CLI is expected at /usr/bin/docker for the systemd unit"
  /usr/bin/docker compose version >/dev/null 2>&1 || die "Docker Compose V2 is required: /usr/bin/docker compose is not available"
}

install_unit() {
  cp "$UNIT_TEMPLATE" "$UNIT_FILE"
  chmod 644 "$UNIT_FILE"
  info "Generated ${UNIT_FILE}"
}

reload_systemd() {
  info "Reloading systemd daemon"
  systemctl daemon-reload
}

enable_docker() {
  info "Enabling docker.service"
  systemctl enable docker.service >/dev/null

  if ! systemctl is-active --quiet docker.service; then
    info "Starting docker.service"
    systemctl start docker.service
  fi
}

enable_stack() {
  info "Enabling ${UNIT_NAME}"
  systemctl enable "$UNIT_NAME" >/dev/null

  if systemctl is-active --quiet "$UNIT_NAME"; then
    info "Restarting ${UNIT_NAME}"
    systemctl restart "$UNIT_NAME"
  else
    info "Starting ${UNIT_NAME}"
    systemctl start "$UNIT_NAME"
  fi
}

check_unit_state() {
  info "Checking docker.service enabled state"
  systemctl is-enabled docker.service

  info "Checking docker.service active state"
  systemctl is-active docker.service

  info "Checking ${UNIT_NAME} enabled state"
  systemctl is-enabled "$UNIT_NAME"

  info "Checking ${UNIT_NAME} active state"
  systemctl is-active "$UNIT_NAME"
}

setup_systemd() {
  require_root
  require_systemd
  require_runtime_files
  require_docker_compose_v2

  install_unit
  reload_systemd
  enable_docker
  enable_stack
  check_unit_state

  info "Systemd autostart is ready for ${UNIT_NAME}"
}

setup_systemd
