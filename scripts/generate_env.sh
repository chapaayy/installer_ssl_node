#!/usr/bin/env bash
set -Eeuo pipefail
set +x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
STACK_DIR="/opt/remnanode-stack"
ENV_FILE="${STACK_DIR}/.env"
EXAMPLE_ENV="${PROJECT_DIR}/.env.example"
LOCAL_ENV="${PROJECT_DIR}/.env"
OLD_ENV="${OLD_ENV:-${PROJECT_DIR}/../installer_ssl_node/installer.env}"
BACKUP_ROOT="${STACK_DIR}/backups"

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"; }
info() { log INFO "$*"; }
warn() { log WARN "$*" >&2; }
error() { log ERROR "$*" >&2; }
die() { error "$*"; exit 1; }

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
}

allowed_key() {
  case "$1" in
    DOMAIN|ACME_EMAIL|NODE_NAME|TZ|NODE_PORT|SECRET_KEY|STACK_DIR|REMNANODE_IMAGE|\
    DOCKER_LOG_MAX_SIZE|DOCKER_LOG_MAX_FILE|PANEL_DOMAIN|PANEL_API_TOKEN|PANEL_AUTO_REGISTER_NODE|\
    PANEL_NODE_UUID|PANEL_NODE_ADDRESS|PANEL_NODE_COUNTRY_CODE|PANEL_CONFIG_PROFILE_UUID|\
    PANEL_CONFIG_PROFILE_NAME|PANEL_ACTIVE_INBOUND_UUIDS|PANEL_PROVIDER_UUID)
      return 0
      ;;
    PANEL_NODE_NAME)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

migration_target_key() {
  case "$1" in
    PANEL_NODE_NAME) printf 'NODE_NAME' ;;
    *) printf '%s' "$1" ;;
  esac
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

get_env_value() {
  local file="$1" wanted="$2" line key value
  [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -n "$line" && "${line:0:1}" != "#" ]] || continue
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    [[ "$key" == "$wanted" ]] || continue
    value="$(strip_quotes "${BASH_REMATCH[2]}")"
    printf '%s' "$value"
    return 0
  done < "$file"
  return 1
}

backup_env() {
  [[ -f "$ENV_FILE" ]] || return 0
  local backup_dir
  backup_dir="${BACKUP_ROOT}/$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$backup_dir"
  cp "$ENV_FILE" "${backup_dir}/.env"
  chmod 700 "$backup_dir"
  chmod 600 "${backup_dir}/.env"
  info "Backed up .env to ${backup_dir}/.env"
}

escape_sed() {
  printf '%s' "$1" | sed 's/[\/&]/\\&/g'
}

set_env_key() {
  local key="$1" value="$2" escaped
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "${key} must be a single-line value"
  escaped="$(escape_sed "$value")"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i "s/^${key}=.*/${key}=${escaped}/" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

migrate_old_env_names() {
  [[ -f "$OLD_ENV" ]] || return 0
  info "Old installer.env found; copying allowed missing values without printing them"

  local existing_before="$1"
  local line source_key target_key value current changed=0 backed_up=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -n "$line" && "${line:0:1}" != "#" ]] || continue
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue

    source_key="${BASH_REMATCH[1]}"
    allowed_key "$source_key" || continue

    target_key="$(migration_target_key "$source_key")"
    value="$(strip_quotes "${BASH_REMATCH[2]}")"
    [[ -n "$value" ]] || continue

    current="$(get_env_value "$ENV_FILE" "$target_key" || true)"
    [[ -z "$current" ]] || continue

    if [[ "$existing_before" == "existing" && "$backed_up" -eq 0 ]]; then
      backup_env
      backed_up=1
    fi

    set_env_key "$target_key" "$value"
    changed=1
  done < "$OLD_ENV"

  if [[ "$changed" -eq 1 ]]; then
    info "Old installer.env migration completed; secret values were not printed"
  else
    info "No missing allowed values to migrate from old installer.env"
  fi
}

load_env() {
  local line key value
  [[ -f "$ENV_FILE" ]] || die "Missing .env: ${ENV_FILE}"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -n "$line" && "${line:0:1}" != "#" ]] || continue
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    [[ "$key" == "STACK_DIR" ]] && continue
    value="$(strip_quotes "${BASH_REMATCH[2]}")"
    printf -v "$key" '%s' "$value"
    export "$key"
  done < "$ENV_FILE"
}

is_truthy() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    die "Required variable ${name} is empty in ${ENV_FILE}"
  fi
}

validate_domain() {
  local domain="$1"
  [[ "$domain" != *"*"* ]] || return 1
  [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

validate_email() {
  local email="$1"
  [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]]
}

validate_node_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1 && port <= 65535 ))
}

validate_env() {
  load_env

  PANEL_AUTO_REGISTER_NODE="${PANEL_AUTO_REGISTER_NODE:-1}"
  NODE_PORT="${NODE_PORT:-2222}"
  TZ="${TZ:-Europe/Berlin}"

  require_var DOMAIN
  require_var ACME_EMAIL
  require_var NODE_NAME
  require_var NODE_PORT
  require_var TZ

  validate_domain "$DOMAIN" || die "DOMAIN has invalid format in ${ENV_FILE}"
  validate_email "$ACME_EMAIL" || die "ACME_EMAIL has invalid email format in ${ENV_FILE}"
  validate_node_port "$NODE_PORT" || die "NODE_PORT must be a number in range 1..65535"

  if ! is_truthy "$PANEL_AUTO_REGISTER_NODE"; then
    require_var SECRET_KEY
  elif [[ -z "${PANEL_DOMAIN:-}" || -z "${PANEL_API_TOKEN:-}" ]] && [[ -z "${SECRET_KEY:-}" ]]; then
    warn "PANEL_* registration variables are incomplete and SECRET_KEY is empty; install will skip panel registration and stop before Compose if SECRET_KEY is still missing"
  fi

  info "Runtime .env validated. Secret values were not printed"
}

generate_env() {
  mkdir -p "$STACK_DIR"

  if [[ ! -f "$ENV_FILE" ]]; then
    if [[ -f "$LOCAL_ENV" ]]; then
      cp "$LOCAL_ENV" "$ENV_FILE"
      chmod 600 "$ENV_FILE"
      migrate_old_env_names "new"
      validate_env
      info "Copied local .env to ${ENV_FILE}. Secret values were not printed"
      return 0
    fi

    [[ -f "$EXAMPLE_ENV" ]] || die "Missing ${EXAMPLE_ENV}"
    cp "$EXAMPLE_ENV" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    migrate_old_env_names "new"
    warn "Заполни .env и запусти снова: ${ENV_FILE}"
    exit 2
  fi

  chmod 600 "$ENV_FILE"
  migrate_old_env_names "existing"
  validate_env
}

require_root
generate_env
