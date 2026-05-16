#!/usr/bin/env bash
set -Eeuo pipefail
set +x

STACK_DIR="/opt/remnanode-stack"
LOGROTATE_FILE="/etc/logrotate.d/remnanode-stack"

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"; }
info() { log INFO "$*"; }
warn() { log WARN "$*" >&2; }
error() { log ERROR "$*" >&2; }
die() { error "$*"; exit 1; }

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
}

setup_logrotate() {
  mkdir -p "${STACK_DIR}/logs/caddy" "${STACK_DIR}/logs/remnanode"
  cat > "$LOGROTATE_FILE" <<EOF
${STACK_DIR}/logs/caddy/*.log ${STACK_DIR}/logs/remnanode/*.log {
    size 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
EOF
  chmod 644 "$LOGROTATE_FILE"
  info "Logrotate config installed: ${LOGROTATE_FILE}"
}

require_root
setup_logrotate
