#!/usr/bin/env bash
set -Eeuo pipefail
set +x

LOG_FILE="/tmp/remnanode-stack-install-docker.log"

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

activity_bar() {
  local tick="$1"
  local width=22
  local pos=$((tick % width))
  local i

  printf '['
  for ((i = 0; i < width; i++)); do
    if [[ "$i" -eq "$pos" ]]; then
      printf '#'
    else
      printf '.'
    fi
  done
  printf ']'
}

run_with_activity() {
  local message="$1"
  shift

  local start tick=0 pid rc elapsed
  start="$SECONDS"

  info "${message}"
  "$@" >>"$LOG_FILE" 2>&1 &
  pid="$!"

  while kill -0 "$pid" >/dev/null 2>&1; do
    elapsed=$((SECONDS - start))
    printf '\r%s [INFO] %s %3ss %s' \
      "$(date '+%Y-%m-%d %H:%M:%S')" \
      "$(activity_bar "$tick")" \
      "$elapsed" \
      "$message" >&2
    tick=$((tick + 1))
    sleep 1
  done

  set +e
  wait "$pid"
  rc="$?"
  set -e

  printf '\r%*s\r' 120 '' >&2

  if [[ "$rc" -ne 0 ]]; then
    error "${message} failed with exit code ${rc}"
    error "Last Docker install log lines from ${LOG_FILE}:"
    tail -n 80 "$LOG_FILE" >&2 || true
    return "$rc"
  fi

  elapsed=$((SECONDS - start))
  info "Done in ${elapsed}s: ${message}"
}

detect_os() {
  have_cmd apt-get || die "apt-get is required on Ubuntu/Debian"
  have_cmd dpkg || die "dpkg is required on Ubuntu/Debian"
  [[ -r /etc/os-release ]] || die "Cannot detect OS: /etc/os-release is missing"

  # shellcheck disable=SC1091
  . /etc/os-release

  OS_ID="${ID:-}"
  OS_CODENAME="${VERSION_CODENAME:-}"

  if [[ -z "$OS_CODENAME" && -r /etc/lsb-release ]]; then
    # shellcheck disable=SC1091
    . /etc/lsb-release
    OS_CODENAME="${DISTRIB_CODENAME:-}"
  fi

  case "$OS_ID" in
    ubuntu|debian) ;;
    *) die "Unsupported OS for Docker apt repository: ${PRETTY_NAME:-$OS_ID}" ;;
  esac

  [[ -n "$OS_CODENAME" ]] || die "Cannot detect OS codename for Docker apt repository"
}

ensure_log_file() {
  : > "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null || true
  info "Docker install detailed log: ${LOG_FILE}"
}

ensure_base_packages() {
  run_with_activity "apt-get update for base packages" \
    env DEBIAN_FRONTEND=noninteractive apt-get update

  run_with_activity "Installing base packages: ca-certificates curl gnupg" \
    env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg
}

configure_docker_repo() {
  local arch repo_file key_file
  arch="$(dpkg --print-architecture)"
  repo_file="/etc/apt/sources.list.d/docker.list"
  key_file="/etc/apt/keyrings/docker.asc"

  install -m 0755 -d /etc/apt/keyrings

  run_with_activity "Downloading Docker apt signing key" \
    curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" -o "$key_file"

  chmod a+r "$key_file"

  printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/%s %s stable\n' \
    "$arch" "$key_file" "$OS_ID" "$OS_CODENAME" > "$repo_file"

  run_with_activity "apt-get update for Docker repository" \
    env DEBIAN_FRONTEND=noninteractive apt-get update
}

install_docker_packages() {
  run_with_activity "Installing Docker Engine and Compose V2 packages" \
    env DEBIAN_FRONTEND=noninteractive apt-get install -y \
      docker-ce \
      docker-ce-cli \
      containerd.io \
      docker-buildx-plugin \
      docker-compose-plugin
}

enable_docker_service() {
  if have_cmd systemctl; then
    run_with_activity "Enabling and starting docker.service" \
      systemctl enable --now docker
  else
    warn "systemctl is not available; Docker service was not enabled"
  fi
}

verify_docker() {
  run_with_activity "Checking Docker daemon" docker info
  run_with_activity "Checking Docker Compose V2" docker compose version
  info "Docker and Docker Compose V2 are ready"
}

install_docker() {
  ensure_log_file
  detect_os

  if have_cmd docker && docker compose version >/dev/null 2>&1; then
    info "Docker and Docker Compose V2 already exist"
    enable_docker_service
    verify_docker
    return 0
  fi

  ensure_base_packages
  configure_docker_repo
  install_docker_packages
  enable_docker_service
  verify_docker
}

require_root
install_docker
