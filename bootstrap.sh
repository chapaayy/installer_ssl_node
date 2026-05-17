#!/usr/bin/env bash
set -Eeuo pipefail

INSTALLER_DIR="/opt/remnanode-stack-installer"
STACK_DIR="/opt/remnanode-stack"
DEFAULT_REPO_URL="https://github.com/chapaayy/remnanode-stack-installer.git"

log() { printf '%s [INFO] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
ok() { printf '%s [OK] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
die() { printf '%s [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  bootstrap.sh --panel-api-token TOKEN --acme-email admin@example.com --panel-domain panel.example.com \
    --config-profile-uuid PROFILE_UUID --active-inbounds INBOUND_UUID1,INBOUND_UUID2 \
    --domain node1.example.com --auto-install

Positional mode:
  bootstrap.sh TOKEN admin@example.com panel.example.com PROFILE_UUID INBOUND_UUID1,INBOUND_UUID2 node1.example.com --auto-install

Positional order:
  1. PANEL_API_TOKEN
  2. ACME_EMAIL
  3. PANEL_DOMAIN
  4. PANEL_CONFIG_PROFILE_UUID
  5. PANEL_ACTIVE_INBOUND_UUIDS
  6. DOMAIN

Optional flags:
  --node-name
  --node-port
  --secret-key
  --profile-name
  --country-code
  --provider-uuid
  --node-address
  --repo-url
  --branch
  --auto-install
USAGE
}

quote_env_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

generate_secret_key() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
    return 0
  fi
  head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 64
}

backup_file_if_exists() {
  local file="$1"
  if [[ -f "$file" ]]; then
    cp -a "$file" "${file}.backup.$(date +%Y%m%d%H%M%S)"
  fi
}

normalize_github_repo_url() {
  local repo_url="$1"
  repo_url="${repo_url%.git}"
  repo_url="${repo_url#git@github.com:}"
  repo_url="${repo_url#https://github.com/}"
  repo_url="${repo_url#http://github.com/}"
  printf '%s' "$repo_url"
}

download_or_update_repo() {
  local repo_url="$1" branch="$2" repo_path tar_url tmp_dir archive extracted

  mkdir -p "$INSTALLER_DIR"
  if [[ -n "$repo_url" && "$repo_url" != "$DEFAULT_REPO_URL" ]] && command -v git >/dev/null 2>&1; then
    if [[ -d "$INSTALLER_DIR/.git" ]]; then
      log "Updating installer repository in $INSTALLER_DIR"
      git -C "$INSTALLER_DIR" fetch --depth=1 origin "$branch"
      git -C "$INSTALLER_DIR" checkout -f FETCH_HEAD
    else
      log "Cloning installer repository to $INSTALLER_DIR"
      rm -rf "$INSTALLER_DIR"
      git clone --depth=1 --branch "$branch" "$repo_url" "$INSTALLER_DIR"
    fi
    return 0
  fi

  if [[ "$repo_url" == "$DEFAULT_REPO_URL" ]]; then
    warn "Using placeholder repo URL. Set --repo-url after publishing the repository."
    if [[ -f "$INSTALLER_DIR/install.sh" ]]; then
      warn "Using existing installer files from $INSTALLER_DIR"
      return 0
    fi
    if (( AUTO_INSTALL == 1 )); then
      die "install.sh is not present in $INSTALLER_DIR. Check --repo-url or repository availability."
    fi
    return 0
  fi

  repo_path="$(normalize_github_repo_url "$repo_url")"
  tar_url="https://github.com/${repo_path}/archive/refs/heads/${branch}.tar.gz"
  tmp_dir="$(mktemp -d)"
  archive="$tmp_dir/repo.tar.gz"
  log "Downloading installer archive from GitHub"
  curl -fsSL "$tar_url" -o "$archive"
  tar -xzf "$archive" -C "$tmp_dir"
  extracted="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [[ -n "$extracted" ]] || die "Unable to extract installer archive"
  rm -rf "$INSTALLER_DIR"
  mkdir -p "$INSTALLER_DIR"
  cp -a "$extracted"/. "$INSTALLER_DIR"/
  rm -rf "$tmp_dir"
}

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
PANEL_CONFIG_PROFILE_NAME=""
PANEL_AUTO_REGISTER_NODE="1"
PANEL_NODE_UUID=""
PANEL_NODE_ADDRESS=""
PANEL_NODE_COUNTRY_CODE="XX"
PANEL_PROVIDER_UUID=""
REMNANODE_IMAGE="remnawave/node:latest"
DOCKER_LOG_MAX_SIZE="10m"
DOCKER_LOG_MAX_FILE="5"
REPO_URL="${REPO_URL:-$DEFAULT_REPO_URL}"
BRANCH="${BRANCH:-main}"
AUTO_INSTALL=0
POSITIONAL=()

while (($# > 0)); do
  case "$1" in
    --panel-api-token) PANEL_API_TOKEN="${2:-}"; shift 2 ;;
    --acme-email) ACME_EMAIL="${2:-}"; shift 2 ;;
    --panel-domain) PANEL_DOMAIN="${2:-}"; shift 2 ;;
    --config-profile-uuid) PANEL_CONFIG_PROFILE_UUID="${2:-}"; shift 2 ;;
    --active-inbounds) PANEL_ACTIVE_INBOUND_UUIDS="${2:-}"; shift 2 ;;
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --node-name) NODE_NAME="${2:-}"; shift 2 ;;
    --node-port) NODE_PORT="${2:-}"; shift 2 ;;
    --secret-key) SECRET_KEY="${2:-}"; shift 2 ;;
    --profile-name) PANEL_CONFIG_PROFILE_NAME="${2:-}"; shift 2 ;;
    --country-code) PANEL_NODE_COUNTRY_CODE="${2:-}"; shift 2 ;;
    --provider-uuid) PANEL_PROVIDER_UUID="${2:-}"; shift 2 ;;
    --node-address) PANEL_NODE_ADDRESS="${2:-}"; shift 2 ;;
    --repo-url) REPO_URL="${2:-}"; shift 2 ;;
    --branch) BRANCH="${2:-}"; shift 2 ;;
    --auto-install) AUTO_INSTALL=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --) shift; break ;;
    -*) die "Unknown flag: $1" ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

if ((${#POSITIONAL[@]} > 0)); then
  ((${#POSITIONAL[@]} <= 6)) || die "Too many positional arguments. Expected exactly 6 values before flags."
  PANEL_API_TOKEN="${PANEL_API_TOKEN:-${POSITIONAL[0]:-}}"
  ACME_EMAIL="${ACME_EMAIL:-${POSITIONAL[1]:-}}"
  PANEL_DOMAIN="${PANEL_DOMAIN:-${POSITIONAL[2]:-}}"
  PANEL_CONFIG_PROFILE_UUID="${PANEL_CONFIG_PROFILE_UUID:-${POSITIONAL[3]:-}}"
  PANEL_ACTIVE_INBOUND_UUIDS="${PANEL_ACTIVE_INBOUND_UUIDS:-${POSITIONAL[4]:-}}"
  DOMAIN="${DOMAIN:-${POSITIONAL[5]:-}}"
fi

[[ -n "$PANEL_API_TOKEN" ]] || die "PANEL_API_TOKEN is required"
[[ -n "$ACME_EMAIL" ]] || die "ACME_EMAIL is required"
[[ -n "$PANEL_DOMAIN" ]] || die "PANEL_DOMAIN is required"
[[ -n "$PANEL_CONFIG_PROFILE_UUID" ]] || die "PANEL_CONFIG_PROFILE_UUID is required"
[[ -n "$PANEL_ACTIVE_INBOUND_UUIDS" ]] || die "PANEL_ACTIVE_INBOUND_UUIDS is required"
[[ -n "$DOMAIN" ]] || die "DOMAIN is required"
[[ "$NODE_PORT" =~ ^[0-9]+$ ]] || die "NODE_PORT must be numeric"

NODE_NAME="${NODE_NAME:-$DOMAIN}"
PANEL_NODE_ADDRESS="${PANEL_NODE_ADDRESS:-$DOMAIN}"
SECRET_KEY="${SECRET_KEY:-$(generate_secret_key)}"

download_or_update_repo "$REPO_URL" "$BRANCH"
mkdir -p "$INSTALLER_DIR" "$STACK_DIR"

ENV_FILE="$INSTALLER_DIR/.env"
STACK_ENV_FILE="$STACK_DIR/.env"
backup_file_if_exists "$ENV_FILE"
backup_file_if_exists "$STACK_ENV_FILE"

cat > "$ENV_FILE" <<ENV
DOMAIN=$(quote_env_value "$DOMAIN")
ACME_EMAIL=$(quote_env_value "$ACME_EMAIL")
NODE_NAME=$(quote_env_value "$NODE_NAME")
TZ=$(quote_env_value "$TZ")
NODE_PORT=$(quote_env_value "$NODE_PORT")
SECRET_KEY=$(quote_env_value "$SECRET_KEY")
PANEL_DOMAIN=$(quote_env_value "$PANEL_DOMAIN")
PANEL_API_TOKEN=$(quote_env_value "$PANEL_API_TOKEN")
PANEL_CONFIG_PROFILE_UUID=$(quote_env_value "$PANEL_CONFIG_PROFILE_UUID")
PANEL_CONFIG_PROFILE_NAME=$(quote_env_value "$PANEL_CONFIG_PROFILE_NAME")
PANEL_ACTIVE_INBOUND_UUIDS=$(quote_env_value "$PANEL_ACTIVE_INBOUND_UUIDS")
PANEL_AUTO_REGISTER_NODE=$(quote_env_value "$PANEL_AUTO_REGISTER_NODE")
PANEL_NODE_UUID=$(quote_env_value "$PANEL_NODE_UUID")
PANEL_NODE_ADDRESS=$(quote_env_value "$PANEL_NODE_ADDRESS")
PANEL_NODE_COUNTRY_CODE=$(quote_env_value "$PANEL_NODE_COUNTRY_CODE")
PANEL_PROVIDER_UUID=$(quote_env_value "$PANEL_PROVIDER_UUID")
REMNANODE_IMAGE=$(quote_env_value "$REMNANODE_IMAGE")
DOCKER_LOG_MAX_SIZE=$(quote_env_value "$DOCKER_LOG_MAX_SIZE")
DOCKER_LOG_MAX_FILE=$(quote_env_value "$DOCKER_LOG_MAX_FILE")
ENV

chmod 600 "$ENV_FILE"
cp -f "$ENV_FILE" "$STACK_ENV_FILE"
chmod 600 "$STACK_ENV_FILE"

ok ".env written: $ENV_FILE"
ok ".env synced: $STACK_ENV_FILE"
cat <<SUMMARY

Summary:
  DOMAIN=$DOMAIN
  ACME_EMAIL=$ACME_EMAIL
  NODE_NAME=$NODE_NAME
  NODE_PORT=$NODE_PORT
  PANEL_DOMAIN=$PANEL_DOMAIN
  PANEL_API_TOKEN=***hidden***
  PANEL_CONFIG_PROFILE_UUID=$PANEL_CONFIG_PROFILE_UUID
  PANEL_ACTIVE_INBOUND_UUIDS=$PANEL_ACTIVE_INBOUND_UUIDS
  SECRET_KEY=***generated/hidden***
  REMNANODE_IMAGE=$REMNANODE_IMAGE

Management command after install:
  sudo remnanode-stack
SUMMARY

if (( AUTO_INSTALL == 1 )); then
  [[ -f "$INSTALLER_DIR/install.sh" ]] || die "install.sh not found in $INSTALLER_DIR"
  log "Starting internal auto-install"
  bash "$INSTALLER_DIR/install.sh" --internal-auto-install
fi
