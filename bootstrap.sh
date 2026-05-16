#!/usr/bin/env bash
set -Eeuo pipefail
set +x

INSTALLER_DIR="/opt/remnanode-stack-installer"
STACK_DIR="/opt/remnanode-stack"
INSTALLER_ENV="${INSTALLER_DIR}/.env"
STACK_ENV="${STACK_DIR}/.env"
LAUNCHER_PATH="/usr/local/bin/remnanode-stack"
DEFAULT_REPO_URL="https://github.com/chapaayy/remnanode-stack-installer.git"
REPO_URL="${REPO_URL:-$DEFAULT_REPO_URL}"
BRANCH="${BRANCH:-main}"
AUTO_INSTALL=0

PANEL_API_TOKEN=""
ACME_EMAIL=""
PANEL_DOMAIN=""
PANEL_CONFIG_PROFILE_UUID=""
PANEL_ACTIVE_INBOUND_UUIDS=""
DOMAIN=""

NODE_NAME=""
TZ="Europe/Berlin"
NODE_PORT="2222"
SECRET_KEY=""
SECRET_KEY_WAS_GENERATED=0
PANEL_CONFIG_PROFILE_NAME=""
PANEL_AUTO_REGISTER_NODE="1"
PANEL_NODE_UUID=""
PANEL_NODE_ADDRESS=""
PANEL_NODE_COUNTRY_CODE="XX"
PANEL_PROVIDER_UUID=""
REMNANODE_IMAGE="remnawave/node:latest"
DOCKER_LOG_MAX_SIZE="10m"
DOCKER_LOG_MAX_FILE="5"

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"; }
info() { log INFO "$*" >&2; }
warn() { log WARN "$*" >&2; }
error() { log ERROR "$*" >&2; }
die() { error "$*"; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  bootstrap.sh --panel-api-token TOKEN --acme-email EMAIL --panel-domain DOMAIN \
    --config-profile-uuid UUID --active-inbounds UUID1,UUID2 --domain NODE_DOMAIN [options]

Positional mode:
  bootstrap.sh TOKEN ACME_EMAIL PANEL_DOMAIN PROFILE_UUID INBOUND_UUIDS DOMAIN [--auto-install]

Options:
  --node-name VALUE
  --node-port VALUE
  --secret-key VALUE
  --profile-name VALUE
  --country-code VALUE
  --provider-uuid VALUE
  --node-address VALUE
  --repo-url VALUE
  --branch VALUE
  --auto-install
USAGE
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run bootstrap as root, for example with sudo"
}

need_value() {
  local flag="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || die "${flag} requires a value"
}

parse_args() {
  local -a positional=()

  while (($# > 0)); do
    case "$1" in
      --panel-api-token)
        need_value "$1" "${2:-}"; PANEL_API_TOKEN="$2"; shift 2 ;;
      --acme-email)
        need_value "$1" "${2:-}"; ACME_EMAIL="$2"; shift 2 ;;
      --panel-domain)
        need_value "$1" "${2:-}"; PANEL_DOMAIN="$2"; shift 2 ;;
      --config-profile-uuid)
        need_value "$1" "${2:-}"; PANEL_CONFIG_PROFILE_UUID="$2"; shift 2 ;;
      --active-inbounds)
        need_value "$1" "${2:-}"; PANEL_ACTIVE_INBOUND_UUIDS="$2"; shift 2 ;;
      --domain)
        need_value "$1" "${2:-}"; DOMAIN="$2"; shift 2 ;;
      --node-name)
        need_value "$1" "${2:-}"; NODE_NAME="$2"; shift 2 ;;
      --node-port)
        need_value "$1" "${2:-}"; NODE_PORT="$2"; shift 2 ;;
      --secret-key)
        need_value "$1" "${2:-}"; SECRET_KEY="$2"; shift 2 ;;
      --profile-name)
        need_value "$1" "${2:-}"; PANEL_CONFIG_PROFILE_NAME="$2"; shift 2 ;;
      --country-code)
        need_value "$1" "${2:-}"; PANEL_NODE_COUNTRY_CODE="$2"; shift 2 ;;
      --provider-uuid)
        need_value "$1" "${2:-}"; PANEL_PROVIDER_UUID="$2"; shift 2 ;;
      --node-address)
        need_value "$1" "${2:-}"; PANEL_NODE_ADDRESS="$2"; shift 2 ;;
      --repo-url)
        need_value "$1" "${2:-}"; REPO_URL="$2"; shift 2 ;;
      --branch)
        need_value "$1" "${2:-}"; BRANCH="$2"; shift 2 ;;
      --auto-install)
        AUTO_INSTALL=1; shift ;;
      -h|--help)
        usage; exit 0 ;;
      --)
        shift
        while (($# > 0)); do positional+=("$1"); shift; done
        ;;
      -*)
        die "Unknown flag: $1" ;;
      *)
        positional+=("$1"); shift ;;
    esac
  done

  PANEL_API_TOKEN="${PANEL_API_TOKEN:-${positional[0]:-}}"
  ACME_EMAIL="${ACME_EMAIL:-${positional[1]:-}}"
  PANEL_DOMAIN="${PANEL_DOMAIN:-${positional[2]:-}}"
  PANEL_CONFIG_PROFILE_UUID="${PANEL_CONFIG_PROFILE_UUID:-${positional[3]:-}}"
  PANEL_ACTIVE_INBOUND_UUIDS="${PANEL_ACTIVE_INBOUND_UUIDS:-${positional[4]:-}}"
  DOMAIN="${DOMAIN:-${positional[5]:-}}"

  if ((${#positional[@]} > 6)); then
    die "Too many positional arguments. Expected: TOKEN ACME_EMAIL PANEL_DOMAIN PROFILE_UUID INBOUND_UUIDS DOMAIN"
  fi
}

validate_required() {
  [[ -n "$PANEL_API_TOKEN" ]] || die "PANEL_API_TOKEN is required"
  [[ -n "$ACME_EMAIL" ]] || die "ACME_EMAIL is required"
  [[ -n "$PANEL_DOMAIN" ]] || die "PANEL_DOMAIN is required"
  [[ -n "$PANEL_CONFIG_PROFILE_UUID" ]] || die "PANEL_CONFIG_PROFILE_UUID is required"
  [[ -n "$PANEL_ACTIVE_INBOUND_UUIDS" ]] || die "PANEL_ACTIVE_INBOUND_UUIDS is required"
  [[ -n "$DOMAIN" ]] || die "DOMAIN is required"

  validate_domain "$DOMAIN" || die "DOMAIN has invalid format"
  validate_email "$ACME_EMAIL" || die "ACME_EMAIL has invalid format"
  [[ "$NODE_PORT" =~ ^[0-9]+$ ]] || die "NODE_PORT must be numeric"
  (( NODE_PORT >= 1 && NODE_PORT <= 65535 )) || die "NODE_PORT must be in range 1..65535"
  [[ "$PANEL_NODE_COUNTRY_CODE" =~ ^[A-Za-z]{2}$ ]] || die "PANEL_NODE_COUNTRY_CODE must be two letters"
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

generate_secret_key() {
  if [[ -n "$SECRET_KEY" ]]; then
    return 0
  fi

  if command -v openssl >/dev/null 2>&1; then
    SECRET_KEY="$(openssl rand -hex 32)"
  else
    SECRET_KEY="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 64)"
  fi

  [[ -n "$SECRET_KEY" ]] || die "Failed to generate SECRET_KEY"
  SECRET_KEY_WAS_GENERATED=1
}

apply_defaults() {
  NODE_NAME="${NODE_NAME:-$DOMAIN}"
  PANEL_NODE_ADDRESS="${PANEL_NODE_ADDRESS:-$DOMAIN}"
  PANEL_NODE_COUNTRY_CODE="${PANEL_NODE_COUNTRY_CODE^^}"
  generate_secret_key
}

github_slug_from_url() {
  local url="$1" slug
  slug="${url#https://github.com/}"
  slug="${slug#http://github.com/}"
  slug="${slug#git@github.com:}"
  slug="${slug%.git}"
  slug="${slug#/}"
  printf '%s' "$slug"
}

download_repo_to_tmp() {
  local tmp_dir="$1"
  local repo_dir="${tmp_dir}/repo"
  local slug archive

  if [[ "$REPO_URL" == "https://github.com/USER/REPO.git" ]]; then
    die "Set --repo-url to your GitHub repository URL or edit DEFAULT_REPO_URL in bootstrap.sh before publishing"
  fi

  if command -v git >/dev/null 2>&1; then
    info "Downloading installer from GitHub branch ${BRANCH}"
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$repo_dir" >/dev/null
    printf '%s' "$repo_dir"
    return 0
  fi

  command -v curl >/dev/null 2>&1 || die "curl is required to download installer when git is unavailable"
  command -v tar >/dev/null 2>&1 || die "tar is required to unpack installer when git is unavailable"

  slug="$(github_slug_from_url "$REPO_URL")"
  [[ "$slug" == */* ]] || die "Cannot derive GitHub slug from --repo-url: ${REPO_URL}"
  archive="${tmp_dir}/repo.tar.gz"

  info "Downloading installer archive from GitHub branch ${BRANCH}"
  curl -fsSL "https://github.com/${slug}/archive/refs/heads/${BRANCH}.tar.gz" -o "$archive"
  mkdir -p "$repo_dir"
  tar -xzf "$archive" -C "$repo_dir" --strip-components=1
  printf '%s' "$repo_dir"
}

sync_installer_source() {
  local repo_dir="$1"
  local src_dir=""

  if [[ -f "${repo_dir}/remnanode-stack-installer/install.sh" ]]; then
    src_dir="${repo_dir}/remnanode-stack-installer"
  elif [[ -f "${repo_dir}/install.sh" && -d "${repo_dir}/scripts" && -d "${repo_dir}/templates" ]]; then
    src_dir="$repo_dir"
  else
    die "Downloaded repository does not contain remnanode-stack-installer"
  fi

  mkdir -p "$INSTALLER_DIR"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a \
      --exclude '.env' \
      --exclude 'backups/' \
      --exclude 'diagnostics/' \
      "${src_dir}/" "${INSTALLER_DIR}/"
  else
    command -v tar >/dev/null 2>&1 || die "tar is required to sync installer when rsync is unavailable"
    (
      cd "$src_dir"
      tar --exclude='./.env' --exclude='./backups' --exclude='./diagnostics' -cf - .
    ) | (
      cd "$INSTALLER_DIR"
      tar -xf -
    )
  fi

  chmod +x "${INSTALLER_DIR}/install.sh" 2>/dev/null || true
  [[ -f "${INSTALLER_DIR}/bootstrap.sh" ]] && chmod +x "${INSTALLER_DIR}/bootstrap.sh" 2>/dev/null || true
  info "Installer synced to ${INSTALLER_DIR}"
}

install_or_update_installer() {
  local tmp_dir repo_dir

  tmp_dir="$(mktemp -d)"
  repo_dir="$(download_repo_to_tmp "$tmp_dir")"
  sync_installer_source "$repo_dir"
  rm -rf "$tmp_dir"
}

quote_shell_arg() {
  printf '%q' "$1"
}

install_launcher() {
  local quoted_script
  quoted_script="$(quote_shell_arg "${INSTALLER_DIR}/install.sh")"

  mkdir -p "$(dirname "$LAUNCHER_PATH")"
  cat > "$LAUNCHER_PATH" <<EOF
#!/usr/bin/env bash
exec bash ${quoted_script} "\$@"
EOF
  chmod 755 "$LAUNCHER_PATH"
  info "Launcher installed: ${LAUNCHER_PATH}"
}

env_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\\$}"
  value="${value//\`/\\\`}"
  printf '"%s"' "$value"
}

backup_env_file() {
  local file="$1"
  local backup_root="$2"
  local backup_dir

  [[ -f "$file" ]] || return 0
  backup_dir="${backup_root}/$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$backup_dir"
  cp -a "$file" "${backup_dir}/$(basename "$file")"
  chmod 700 "$backup_dir" 2>/dev/null || true
  chmod 600 "${backup_dir}/$(basename "$file")" 2>/dev/null || true
  info "Existing $(basename "$file") backed up to ${backup_dir}"
}

write_env_file() {
  local file="$1"

  cat > "$file" <<EOF
DOMAIN=$(env_quote "$DOMAIN")
ACME_EMAIL=$(env_quote "$ACME_EMAIL")
NODE_NAME=$(env_quote "$NODE_NAME")
TZ=$(env_quote "$TZ")
NODE_PORT=$(env_quote "$NODE_PORT")
SECRET_KEY=$(env_quote "$SECRET_KEY")
PANEL_DOMAIN=$(env_quote "$PANEL_DOMAIN")
PANEL_API_TOKEN=$(env_quote "$PANEL_API_TOKEN")
PANEL_CONFIG_PROFILE_UUID=$(env_quote "$PANEL_CONFIG_PROFILE_UUID")
PANEL_CONFIG_PROFILE_NAME=$(env_quote "$PANEL_CONFIG_PROFILE_NAME")
PANEL_ACTIVE_INBOUND_UUIDS=$(env_quote "$PANEL_ACTIVE_INBOUND_UUIDS")
PANEL_AUTO_REGISTER_NODE=$(env_quote "$PANEL_AUTO_REGISTER_NODE")
PANEL_NODE_UUID=$(env_quote "$PANEL_NODE_UUID")
PANEL_NODE_ADDRESS=$(env_quote "$PANEL_NODE_ADDRESS")
PANEL_NODE_COUNTRY_CODE=$(env_quote "$PANEL_NODE_COUNTRY_CODE")
PANEL_PROVIDER_UUID=$(env_quote "$PANEL_PROVIDER_UUID")
REMNANODE_IMAGE=$(env_quote "$REMNANODE_IMAGE")
DOCKER_LOG_MAX_SIZE=$(env_quote "$DOCKER_LOG_MAX_SIZE")
DOCKER_LOG_MAX_FILE=$(env_quote "$DOCKER_LOG_MAX_FILE")
EOF
  chmod 600 "$file"
}

write_envs() {
  mkdir -p "$INSTALLER_DIR" "$STACK_DIR" "${INSTALLER_DIR}/backups" "${STACK_DIR}/backups"

  backup_env_file "$INSTALLER_ENV" "${INSTALLER_DIR}/backups"
  backup_env_file "$STACK_ENV" "${STACK_DIR}/backups"

  write_env_file "$INSTALLER_ENV"
  cp -a "$INSTALLER_ENV" "$STACK_ENV"
  chmod 600 "$STACK_ENV"
}

print_summary() {
  cat <<EOF
Bootstrap complete.

INSTALLER_DIR=${INSTALLER_DIR}
STACK_DIR=${STACK_DIR}
LAUNCHER=${LAUNCHER_PATH}
DOMAIN=${DOMAIN}
ACME_EMAIL=${ACME_EMAIL}
NODE_NAME=${NODE_NAME}
NODE_PORT=${NODE_PORT}
PANEL_DOMAIN=${PANEL_DOMAIN}
PANEL_API_TOKEN=***hidden***
PANEL_CONFIG_PROFILE_UUID=${PANEL_CONFIG_PROFILE_UUID}
PANEL_ACTIVE_INBOUND_UUIDS=${PANEL_ACTIVE_INBOUND_UUIDS}
PANEL_AUTO_REGISTER_NODE=${PANEL_AUTO_REGISTER_NODE}
PANEL_NODE_ADDRESS=${PANEL_NODE_ADDRESS}
PANEL_NODE_COUNTRY_CODE=${PANEL_NODE_COUNTRY_CODE}
PANEL_PROVIDER_UUID=${PANEL_PROVIDER_UUID}
SECRET_KEY=***generated/hidden***
REMNANODE_IMAGE=${REMNANODE_IMAGE}
DOCKER_LOG_MAX_SIZE=${DOCKER_LOG_MAX_SIZE}
DOCKER_LOG_MAX_FILE=${DOCKER_LOG_MAX_FILE}
EOF
}

run_auto_install() {
  [[ "$AUTO_INSTALL" -eq 1 ]] || return 0
  info "Running installer internal auto-install mode"
  bash "${INSTALLER_DIR}/install.sh" --internal-auto-install
}

main() {
  require_root
  parse_args "$@"
  validate_required
  apply_defaults
  install_or_update_installer
  install_launcher
  write_envs
  print_summary
  run_auto_install
}

main "$@"
