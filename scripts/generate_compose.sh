#!/usr/bin/env bash
set -Eeuo pipefail
set +x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
STACK_DIR="/opt/remnanode-stack"
ENV_FILE="${STACK_DIR}/.env"
BACKUP_ROOT="${STACK_DIR}/backups"

COMPOSE_TEMPLATE="${PROJECT_DIR}/templates/docker-compose.yml.tpl"
CADDY_TEMPLATE="${PROJECT_DIR}/templates/Caddyfile.tpl"

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"; }
info() { log INFO "$*"; }
warn() { log WARN "$*" >&2; }
error() { log ERROR "$*" >&2; }
die() { error "$*"; exit 1; }

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || die "Missing required file: ${path}"
}

load_env() {
  [[ -f "$ENV_FILE" ]] || die "Missing runtime .env: ${ENV_FILE}. Run install.sh first and fill .env."

  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -n "$line" && "${line:0:1}" != "#" ]] || continue
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue

    key="${BASH_REMATCH[1]}"
    [[ "$key" == "STACK_DIR" ]] && continue
    value="${BASH_REMATCH[2]}"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"

    printf -v "$key" '%s' "$value"
    export "$key"
  done < "$ENV_FILE"
}

escape_sed() {
  printf '%s' "$1" | sed 's/[\/&]/\\&/g'
}

backup_file() {
  local src="$1"
  local dst_dir="$2"

  [[ -e "$src" ]] || return 1
  mkdir -p "$dst_dir"
  cp -a "$src" "${dst_dir}/"
  if [[ "$(basename "$src")" == ".env" ]]; then
    chmod 600 "${dst_dir}/.env" 2>/dev/null || true
  fi
  return 0
}

backup_runtime_files() {
  local ts backup_dir backed_up=0

  ts="$(date '+%Y%m%d-%H%M%S')"
  backup_dir="${BACKUP_ROOT}/${ts}"

  backup_file "${STACK_DIR}/docker-compose.yml" "$backup_dir" && backed_up=1 || true
  backup_file "${STACK_DIR}/Caddyfile" "$backup_dir" && backed_up=1 || true
  backup_file "$ENV_FILE" "$backup_dir" && backed_up=1 || true

  if [[ "$backed_up" -eq 1 ]]; then
    chmod 700 "$backup_dir" 2>/dev/null || true
    info "Backed up runtime files to ${backup_dir}"
  fi
}

ensure_runtime_dirs() {
  mkdir -p \
    "$STACK_DIR" \
    "${STACK_DIR}/site" \
    "${STACK_DIR}/logs/caddy" \
    "${STACK_DIR}/logs/remnanode" \
    "$BACKUP_ROOT"

  chmod 755 "$STACK_DIR" "${STACK_DIR}/site" "${STACK_DIR}/logs" 2>/dev/null || true
  chmod 700 "$BACKUP_ROOT" 2>/dev/null || true
}

write_minimal_site() {
  local dst="${STACK_DIR}/site/index.html"

  cat > "$dst" <<'HTML'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Remnanode</title>
    <style>
      body { margin: 0; min-height: 100vh; display: grid; place-items: center; font-family: system-ui, sans-serif; background: #111827; color: #f9fafb; }
      main { text-align: center; max-width: 42rem; padding: 2rem; }
      h1 { font-size: clamp(2rem, 5vw, 4rem); margin: 0 0 1rem; }
      p { color: #cbd5e1; margin: 0; }
    </style>
  </head>
  <body>
    <main>
      <h1>Remnanode</h1>
      <p>Static fallback site is running.</p>
    </main>
  </body>
</html>
HTML
}

copy_site() {
  local src="${PROJECT_DIR}/site"
  local dst="${STACK_DIR}/site"

  mkdir -p "$dst"
  if [[ -d "$src" ]] && find "$src" -mindepth 1 -print -quit | grep -q .; then
    if command -v rsync >/dev/null 2>&1; then
      rsync -a "${src}/" "${dst}/"
    else
      cp -a "${src}/." "${dst}/"
    fi
    info "Copied fallback site to ${dst}"
    return 0
  fi

  warn "Installer site directory is empty; writing a minimal fallback page"
  write_minimal_site
}

render_compose() {
  local dst="${STACK_DIR}/docker-compose.yml"
  local remnanode_image log_size log_file

  require_file "$COMPOSE_TEMPLATE"

  remnanode_image="$(escape_sed "${REMNANODE_IMAGE:-remnawave/node:latest}")"
  log_size="$(escape_sed "${DOCKER_LOG_MAX_SIZE:-10m}")"
  log_file="$(escape_sed "${DOCKER_LOG_MAX_FILE:-5}")"

  sed \
    -e "s/__REMNANODE_IMAGE__/${remnanode_image}/g" \
    -e "s/__DOCKER_LOG_MAX_SIZE__/${log_size}/g" \
    -e "s/__DOCKER_LOG_MAX_FILE__/${log_file}/g" \
    "$COMPOSE_TEMPLATE" > "$dst"
}

render_caddyfile() {
  require_file "$CADDY_TEMPLATE"
  cp "$CADDY_TEMPLATE" "${STACK_DIR}/Caddyfile"
}

generate_compose() {
  mkdir -p "$STACK_DIR"
  load_env
  ensure_runtime_dirs
  backup_runtime_files
  copy_site
  render_compose
  render_caddyfile

  chmod 600 "$ENV_FILE" 2>/dev/null || true
  chmod 644 "${STACK_DIR}/docker-compose.yml" "${STACK_DIR}/Caddyfile"

  info "Generated docker-compose.yml and Caddyfile in ${STACK_DIR}"
}

require_root
generate_compose
