#!/usr/bin/env bash
set -Eeuo pipefail
set +x

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"; }
info() { log INFO "$*"; }
warn() { log WARN "$*" >&2; }
error() { log ERROR "$*" >&2; }
die() { error "$*"; exit 1; }

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

ensure_download_tools() {
  if have_cmd curl; then
    return 0
  fi

  have_cmd apt-get || die "curl is required and apt-get is not available"
  info "Installing curl and ca-certificates"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update >/dev/null
  apt-get install -y curl ca-certificates >/dev/null
}

install_docker() {
  if have_cmd docker; then
    info "Docker binary already exists"
  else
    ensure_download_tools
    info "Installing Docker with the official convenience script"
    local tmp
    tmp="$(mktemp)"
    curl -fsSL https://get.docker.com -o "$tmp"
    sh "$tmp"
    rm -f "$tmp"
  fi

  if have_cmd systemctl; then
    systemctl enable --now docker
  else
    warn "systemctl is not available; Docker service was not enabled"
  fi

  docker info >/dev/null
  docker compose version >/dev/null
  info "Docker and Docker Compose V2 are ready"
}

require_root
install_docker
