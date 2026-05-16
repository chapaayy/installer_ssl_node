#!/usr/bin/env bash
set -Eeuo pipefail
set +x

STACK_DIR="/opt/remnanode-stack"
ENV_FILE="${STACK_DIR}/.env"
BACKUP_ROOT="${STACK_DIR}/backups"
REGISTRATION_FILE="${STACK_DIR}/panel-registration.env"

PANEL_DOMAIN="${PANEL_DOMAIN:-}"
PANEL_API_TOKEN="${PANEL_API_TOKEN:-}"
PANEL_AUTO_REGISTER_NODE="${PANEL_AUTO_REGISTER_NODE:-1}"
PANEL_NODE_UUID="${PANEL_NODE_UUID:-}"
PANEL_NODE_ADDRESS="${PANEL_NODE_ADDRESS:-}"
PANEL_NODE_COUNTRY_CODE="${PANEL_NODE_COUNTRY_CODE:-XX}"
PANEL_CONFIG_PROFILE_UUID="${PANEL_CONFIG_PROFILE_UUID:-}"
PANEL_CONFIG_PROFILE_NAME="${PANEL_CONFIG_PROFILE_NAME:-}"
PANEL_ACTIVE_INBOUND_UUIDS="${PANEL_ACTIVE_INBOUND_UUIDS:-}"
PANEL_PROVIDER_UUID="${PANEL_PROVIDER_UUID:-}"
NODE_NAME="${NODE_NAME:-}"
DOMAIN="${DOMAIN:-}"
NODE_PORT="${NODE_PORT:-2222}"
SECRET_KEY="${SECRET_KEY:-}"

ENV_BACKED_UP=0

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"; }
info() { log INFO "$*"; }
warn() { log WARN "$*" >&2; }
error() { log ERROR "$*" >&2; }
die() { error "$*"; exit 1; }
ok() { log OK "$*"; }

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
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

load_env() {
  [[ -f "$ENV_FILE" ]] || die "Missing runtime .env: ${ENV_FILE}"

  local line key value
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

  PANEL_AUTO_REGISTER_NODE="${PANEL_AUTO_REGISTER_NODE:-1}"
  PANEL_NODE_COUNTRY_CODE="${PANEL_NODE_COUNTRY_CODE:-XX}"
  NODE_PORT="${NODE_PORT:-2222}"
}

is_truthy() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[\/&\\]/\\&/g'
}

escape_sed_pattern() {
  printf '%s' "$1" | sed 's/[][\\.^$*+?{}()|]/\\&/g'
}

redact_text() {
  if [[ -n "${PANEL_API_TOKEN:-}" ]]; then
    printf '%s' "$1" | sed -E \
      -e "s|$(escape_sed_pattern "$PANEL_API_TOKEN")|[REDACTED_PANEL_API_TOKEN]|g" \
      -e 's|(PANEL_API_TOKEN[=:][[:space:]]*)[^[:space:]]+|\1[REDACTED_PANEL_API_TOKEN]|g'
  else
    printf '%s' "$1" | sed -E 's|(PANEL_API_TOKEN[=:][[:space:]]*)[^[:space:]]+|\1[REDACTED_PANEL_API_TOKEN]|g'
  fi
}

backup_env_once() {
  [[ "$ENV_BACKED_UP" -eq 0 ]] || return 0
  [[ -f "$ENV_FILE" ]] || return 0

  local backup_dir
  backup_dir="${BACKUP_ROOT}/$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$backup_dir"
  cp -a "$ENV_FILE" "${backup_dir}/.env"
  chmod 700 "$backup_dir" 2>/dev/null || true
  chmod 600 "${backup_dir}/.env" 2>/dev/null || true
  ENV_BACKED_UP=1
  info "Backed up .env before panel registration update: ${backup_dir}/.env"
}

set_env_key() {
  local key="$1" value="$2" escaped
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "${key} must be a single-line value"
  escaped="$(escape_sed_replacement "$value")"

  backup_env_once
  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i "s/^${key}=.*/${key}=${escaped}/" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

normalize_panel_domain() {
  local domain="$1"
  domain="${domain#http://}"
  domain="${domain#https://}"
  domain="${domain%/}"
  printf '%s' "$domain"
}

panel_base_url() {
  PANEL_DOMAIN="$(normalize_panel_domain "$PANEL_DOMAIN")"
  printf 'https://%s' "$PANEL_DOMAIN"
}

install_panel_tools() {
  local missing=()
  have_cmd curl || missing+=("curl")
  have_cmd jq || missing+=("jq")
  ((${#missing[@]} == 0)) && return 0

  info "Installing panel API tools: ${missing[*]}"
  have_cmd apt-get || die "apt-get is required to install curl/jq on this installer path"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update >/dev/null
  apt-get install -y curl jq ca-certificates >/dev/null

  have_cmd curl || die "curl is not available after install"
  have_cmd jq || die "jq is not available after install"
}

panel_api_request() {
  local method="$1"
  local path="$2"
  local payload="${3:-}"
  local url response rc http_code body error_message

  [[ -n "$PANEL_API_TOKEN" ]] || die "PANEL_API_TOKEN is empty"
  url="$(panel_base_url)$path"

  set +e
  if [[ -n "$payload" ]]; then
    response="$(
      curl -sS \
        --connect-timeout 10 \
        --max-time 45 \
        -X "$method" \
        -H "Authorization: Bearer $PANEL_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "$payload" \
        -w $'\n%{http_code}' \
        "$url" 2>&1
    )"
    rc=$?
  else
    response="$(
      curl -sS \
        --connect-timeout 10 \
        --max-time 45 \
        -X "$method" \
        -H "Authorization: Bearer $PANEL_API_TOKEN" \
        -w $'\n%{http_code}' \
        "$url" 2>&1
    )"
    rc=$?
  fi
  set -e

  if [[ "$rc" -ne 0 ]]; then
    die "Panel API request failed for ${method} ${path}: $(redact_text "$response")"
  fi

  http_code="${response##*$'\n'}"
  body="${response%$'\n'*}"

  if [[ ! "$http_code" =~ ^2 ]]; then
    error_message="$(printf '%s' "$body" | jq -r '.message // .error // (.errors[0].message // empty)' 2>/dev/null || true)"
    [[ -n "$error_message" && "$error_message" != "null" ]] || error_message="$body"
    die "Panel API returned HTTP ${http_code} for ${method} ${path}: $(redact_text "$error_message")"
  fi

  printf '%s' "$body"
}

validate_node_port() {
  [[ "$NODE_PORT" =~ ^[0-9]+$ ]] || die "NODE_PORT must be numeric for panel registration"
  (( NODE_PORT >= 1 && NODE_PORT <= 65535 )) || die "NODE_PORT must be in range 1..65535"
}

derived_node_name() {
  local base="${NODE_NAME:-}"
  if [[ -z "$base" ]]; then
    base="${DOMAIN%%.*}"
  fi
  if [[ -z "$base" ]]; then
    base="$(hostname -s 2>/dev/null || echo node)"
  fi
  base="${base^^}"
  base="${base//[^A-Z0-9_-]/-}"
  printf '%s' "${base:-NODE}"
}

default_country_code() {
  local value="${1:-}" label
  if [[ -n "${PANEL_NODE_COUNTRY_CODE:-}" && "$PANEL_NODE_COUNTRY_CODE" != "XX" ]]; then
    printf '%s' "${PANEL_NODE_COUNTRY_CODE^^}"
    return 0
  fi

  label="${value%%.*}"
  label="${label,,}"
  if [[ "$label" =~ ^([a-z]{2})[a-z0-9-]*$ ]]; then
    printf '%s' "${BASH_REMATCH[1]^^}"
  else
    printf 'XX'
  fi
}

apply_panel_defaults() {
  PANEL_DOMAIN="$(normalize_panel_domain "$PANEL_DOMAIN")"
  PANEL_NODE_NAME="${PANEL_NODE_NAME:-${NODE_NAME:-$(derived_node_name)}}"
  PANEL_NODE_ADDRESS="${PANEL_NODE_ADDRESS:-${DOMAIN:-}}"
  PANEL_NODE_COUNTRY_CODE="$(default_country_code "$PANEL_NODE_ADDRESS")"
  PANEL_ACTIVE_INBOUND_UUIDS="${PANEL_ACTIVE_INBOUND_UUIDS//,/ }"

  [[ ${#PANEL_NODE_NAME} -ge 3 && ${#PANEL_NODE_NAME} -le 30 ]] || die "Panel node name must be 3..30 characters"
  [[ -n "$PANEL_NODE_ADDRESS" ]] || die "Panel node address is empty; set DOMAIN or PANEL_NODE_ADDRESS"
  [[ "$PANEL_NODE_COUNTRY_CODE" =~ ^[A-Z]{2}$ ]] || die "PANEL_NODE_COUNTRY_CODE must be two letters"
  validate_node_port
}

panel_fetch_config_profiles() {
  panel_api_request GET '/api/config-profiles'
}

panel_fetch_keygen_secret() {
  local json
  json="$(panel_api_request GET '/api/keygen')"
  SECRET_KEY="$(printf '%s' "$json" | jq -r '.response.pubKey // empty')"
  [[ -n "$SECRET_KEY" && "$SECRET_KEY" != "null" ]] || die "Panel did not return node secret key from /api/keygen"
  info "Secret key received from panel and will be saved to .env; value is not printed"
}

select_config_profile() {
  local profiles_json="$1"
  local total profile_index

  total="$(printf '%s' "$profiles_json" | jq -r '.response.configProfiles | length')"
  [[ "$total" =~ ^[0-9]+$ ]] || die "Cannot parse config profiles from panel response"
  (( total > 0 )) || die "Panel has no config profiles"

  if [[ -n "$PANEL_CONFIG_PROFILE_UUID" ]]; then
    profile_index="$(printf '%s' "$profiles_json" | jq -r --arg uuid "$PANEL_CONFIG_PROFILE_UUID" '.response.configProfiles | map(.uuid) | index($uuid)')"
    [[ "$profile_index" =~ ^[0-9]+$ ]] || die "PANEL_CONFIG_PROFILE_UUID was not found in panel"
  else
    if (( total != 1 )); then
      warn "PANEL_CONFIG_PROFILE_UUID is empty and panel has ${total} config profiles; skipping panel registration"
      return 1
    fi
    profile_index="0"
    PANEL_CONFIG_PROFILE_UUID="$(printf '%s' "$profiles_json" | jq -r '.response.configProfiles[0].uuid')"
  fi

  PANEL_CONFIG_PROFILE_NAME="$(printf '%s' "$profiles_json" | jq -r ".response.configProfiles[$profile_index].name // empty")"
  return 0
}

select_active_inbounds() {
  local profiles_json="$1"
  local profile_index_json="$2"
  local total inbound_uuid idx
  local -a selected_uuids=()
  local -A seen=()

  total="$(printf '%s' "$profiles_json" | jq -r ".response.configProfiles[$profile_index_json].inbounds | length")"
  [[ "$total" =~ ^[0-9]+$ ]] || die "Cannot parse inbounds from selected config profile"
  (( total > 0 )) || die "Selected config profile has no inbounds"

  if [[ -n "$PANEL_ACTIVE_INBOUND_UUIDS" ]]; then
    read -r -a selected_uuids <<< "${PANEL_ACTIVE_INBOUND_UUIDS//,/ }"
    for inbound_uuid in "${selected_uuids[@]}"; do
      [[ -n "$inbound_uuid" ]] || continue
      idx="$(printf '%s' "$profiles_json" | jq -r --arg uuid "$inbound_uuid" ".response.configProfiles[$profile_index_json].inbounds | map(.uuid) | index(\$uuid)")"
      [[ "$idx" =~ ^[0-9]+$ ]] || die "PANEL_ACTIVE_INBOUND_UUIDS contains UUID not found in selected config profile"
      [[ -n "${seen[$inbound_uuid]+x}" ]] && continue
      seen[$inbound_uuid]=1
    done
  else
    if (( total != 1 )); then
      warn "PANEL_ACTIVE_INBOUND_UUIDS is empty and selected profile has ${total} inbounds; skipping panel registration"
      return 1
    fi
    inbound_uuid="$(printf '%s' "$profiles_json" | jq -r ".response.configProfiles[$profile_index_json].inbounds[0].uuid")"
    [[ -n "$inbound_uuid" && "$inbound_uuid" != "null" ]] || die "Cannot read the only inbound UUID from panel response"
    selected_uuids=("$inbound_uuid")
  fi

  ((${#selected_uuids[@]} > 0)) || die "At least one active inbound UUID is required"
  PANEL_ACTIVE_INBOUND_UUIDS="${selected_uuids[*]}"
  return 0
}

prepare_panel_selection() {
  local profiles_json profile_index_json

  profiles_json="$(panel_fetch_config_profiles)"
  select_config_profile "$profiles_json" || return 1

  profile_index_json="$(printf '%s' "$profiles_json" | jq -r --arg uuid "$PANEL_CONFIG_PROFILE_UUID" '.response.configProfiles | map(.uuid) | index($uuid)')"
  [[ "$profile_index_json" =~ ^[0-9]+$ ]] || die "Cannot find selected config profile in panel response"

  select_active_inbounds "$profiles_json" "$profile_index_json" || return 1

  info "Panel registration settings prepared: panel=${PANEL_DOMAIN}, node=${PANEL_NODE_NAME}, address=${PANEL_NODE_ADDRESS}, port=${NODE_PORT}, profile=${PANEL_CONFIG_PROFILE_NAME:-$PANEL_CONFIG_PROFILE_UUID}"
  return 0
}

panel_inbounds_json() {
  local -a inbound_uuids=()
  read -r -a inbound_uuids <<< "$PANEL_ACTIVE_INBOUND_UUIDS"
  printf '%s\n' "${inbound_uuids[@]}" | jq -R . | jq -s .
}

panel_find_existing_node_uuid() {
  local nodes_json="$1"
  local existing matches count line found_uuid

  if [[ -n "$PANEL_NODE_UUID" ]]; then
    existing="$(printf '%s' "$nodes_json" | jq -r --arg uuid "$PANEL_NODE_UUID" '.response[]? | select(.uuid == $uuid) | .uuid' | head -n1)"
    if [[ -n "$existing" ]]; then
      printf '%s' "$existing"
      return 0
    fi
    warn "Saved PANEL_NODE_UUID was not found in panel; searching by node name/address"
  fi

  matches="$(printf '%s' "$nodes_json" | jq -r --arg name "$PANEL_NODE_NAME" --arg address "$PANEL_NODE_ADDRESS" '[.response[]? | select(.name == $name or .address == $address) | .uuid] | unique | .[]')"
  count=0
  found_uuid=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    found_uuid="$line"
    count=$((count + 1))
  done <<< "$matches"

  if (( count > 1 )); then
    die "Panel contains multiple nodes with the same name or address; clean duplicates or change NODE_NAME/PANEL_NODE_ADDRESS"
  fi

  printf '%s' "$found_uuid"
}

save_registration_state() {
  set_env_key PANEL_DOMAIN "$PANEL_DOMAIN"
  set_env_key SECRET_KEY "$SECRET_KEY"
  set_env_key PANEL_NODE_UUID "$PANEL_NODE_UUID"
  set_env_key PANEL_NODE_ADDRESS "$PANEL_NODE_ADDRESS"
  set_env_key PANEL_NODE_COUNTRY_CODE "$PANEL_NODE_COUNTRY_CODE"
  set_env_key PANEL_CONFIG_PROFILE_UUID "$PANEL_CONFIG_PROFILE_UUID"
  set_env_key PANEL_CONFIG_PROFILE_NAME "$PANEL_CONFIG_PROFILE_NAME"
  set_env_key PANEL_ACTIVE_INBOUND_UUIDS "$PANEL_ACTIVE_INBOUND_UUIDS"

  cat > "$REGISTRATION_FILE" <<EOF
PANEL_NODE_UUID=${PANEL_NODE_UUID}
PANEL_NODE_NAME=${PANEL_NODE_NAME}
PANEL_NODE_ADDRESS=${PANEL_NODE_ADDRESS}
PANEL_NODE_COUNTRY_CODE=${PANEL_NODE_COUNTRY_CODE}
PANEL_CONFIG_PROFILE_UUID=${PANEL_CONFIG_PROFILE_UUID}
PANEL_CONFIG_PROFILE_NAME=${PANEL_CONFIG_PROFILE_NAME}
PANEL_ACTIVE_INBOUND_UUIDS=${PANEL_ACTIVE_INBOUND_UUIDS}
EOF
  chmod 600 "$REGISTRATION_FILE"
}

register_panel_node() {
  local nodes_json existing_uuid inbounds_json payload response

  nodes_json="$(panel_api_request GET '/api/nodes')"
  existing_uuid="$(panel_find_existing_node_uuid "$nodes_json")"
  inbounds_json="$(panel_inbounds_json)"

  if [[ -n "$existing_uuid" ]]; then
    payload="$(jq -cn \
      --arg uuid "$existing_uuid" \
      --arg name "$PANEL_NODE_NAME" \
      --arg address "$PANEL_NODE_ADDRESS" \
      --arg countryCode "$PANEL_NODE_COUNTRY_CODE" \
      --arg profileUuid "$PANEL_CONFIG_PROFILE_UUID" \
      --argjson port "$NODE_PORT" \
      --argjson inbounds "$inbounds_json" \
      --argjson isTrafficTrackingActive false \
      --argjson consumptionMultiplier 1 \
      '{
        uuid: $uuid,
        name: $name,
        address: $address,
        port: $port,
        countryCode: $countryCode,
        isTrafficTrackingActive: $isTrafficTrackingActive,
        consumptionMultiplier: $consumptionMultiplier,
        configProfile: {
          activeConfigProfileUuid: $profileUuid,
          activeInbounds: $inbounds
        }
      }'
    )"
    response="$(panel_api_request PATCH '/api/nodes' "$payload")"
    PANEL_NODE_UUID="$(printf '%s' "$response" | jq -r '.response.uuid // empty')"
    ok "Node updated in panel: ${PANEL_NODE_NAME} (${PANEL_NODE_UUID})"
  else
    payload="$(jq -cn \
      --arg name "$PANEL_NODE_NAME" \
      --arg address "$PANEL_NODE_ADDRESS" \
      --arg countryCode "$PANEL_NODE_COUNTRY_CODE" \
      --arg profileUuid "$PANEL_CONFIG_PROFILE_UUID" \
      --arg providerUuid "$PANEL_PROVIDER_UUID" \
      --argjson port "$NODE_PORT" \
      --argjson inbounds "$inbounds_json" \
      --argjson isTrafficTrackingActive false \
      --argjson consumptionMultiplier 1 \
      '{
        name: $name,
        address: $address,
        port: $port,
        countryCode: $countryCode,
        isTrafficTrackingActive: $isTrafficTrackingActive,
        consumptionMultiplier: $consumptionMultiplier,
        configProfile: {
          activeConfigProfileUuid: $profileUuid,
          activeInbounds: $inbounds
        }
      } + (if ($providerUuid | length) > 0 then { providerUuid: $providerUuid } else {} end)'
    )"
    response="$(panel_api_request POST '/api/nodes' "$payload")"
    PANEL_NODE_UUID="$(printf '%s' "$response" | jq -r '.response.uuid // empty')"
    ok "Node created in panel: ${PANEL_NODE_NAME} (${PANEL_NODE_UUID})"
  fi

  [[ -n "$PANEL_NODE_UUID" && "$PANEL_NODE_UUID" != "null" ]] || die "Panel did not return node UUID after registration"
  save_registration_state
  info "Panel registration state saved to ${ENV_FILE} and ${REGISTRATION_FILE}; secret values were not printed"
}

maybe_register_panel_node() {
  require_root
  load_env

  if ! is_truthy "$PANEL_AUTO_REGISTER_NODE"; then
    info "Panel auto-registration is disabled; skipping"
    return 0
  fi

  if [[ -z "$PANEL_DOMAIN" || -z "$PANEL_API_TOKEN" ]]; then
    warn "PANEL_DOMAIN or PANEL_API_TOKEN is empty; skipping panel registration"
    return 0
  fi

  if [[ -n "$PANEL_NODE_UUID" && -n "$SECRET_KEY" ]]; then
    info "PANEL_NODE_UUID and SECRET_KEY already exist; skipping panel registration"
    return 0
  fi

  install_panel_tools
  apply_panel_defaults
  prepare_panel_selection || return 0
  panel_fetch_keygen_secret
  register_panel_node
}

maybe_register_panel_node
