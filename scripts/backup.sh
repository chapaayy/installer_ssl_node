#!/usr/bin/env bash
set -Eeuo pipefail
set +x

STACK_DIR="/opt/remnanode-stack"
BACKUP_ROOT="${STACK_DIR}/backups"

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"; }
info() { log INFO "$*"; }
warn() { log WARN "$*" >&2; }
error() { log ERROR "$*" >&2; }
die() { error "$*"; exit 1; }

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
}

backup_runtime() {
  require_root
  [[ -d "$STACK_DIR" ]] || {
    info "No runtime stack directory yet; backup skipped"
    return 0
  }

  local backup_dir
  backup_dir="${BACKUP_ROOT}/$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$backup_dir"

  for file in .env docker-compose.yml Caddyfile; do
    if [[ -f "${STACK_DIR}/${file}" ]]; then
      cp "${STACK_DIR}/${file}" "$backup_dir/"
    fi
  done

  chmod 700 "$backup_dir"
  [[ -f "${backup_dir}/.env" ]] && chmod 600 "${backup_dir}/.env"
  info "Runtime config backup created: ${backup_dir}"
}

backup_runtime
