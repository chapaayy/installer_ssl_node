#!/usr/bin/env bash
set -Eeuo pipefail
set +x

STACK_DIR="/opt/remnanode-stack"
ENV_FILE="${STACK_DIR}/.env"
DIAGNOSTICS_DIR="${STACK_DIR}/diagnostics"
REPORT_FILE="${DIAGNOSTICS_DIR}/$(date '+%Y%m%d-%H%M%S').txt"
PANEL_API_TOKEN_VALUE=""

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"; }
info() { log INFO "$*"; }
warn() { log WARN "$*" >&2; }
error() { log ERROR "$*" >&2; }
die() { error "$*"; exit 1; }

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
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

load_secret_redactions() {
  [[ -r "$ENV_FILE" ]] || return 0

  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -n "$line" && "${line:0:1}" != "#" ]] || continue
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue

    key="${BASH_REMATCH[1]}"
    [[ "$key" == "PANEL_API_TOKEN" ]] || continue
    value="$(strip_quotes "${BASH_REMATCH[2]}")"
    PANEL_API_TOKEN_VALUE="$value"
    return 0
  done < "$ENV_FILE"
}

escape_sed_pattern() {
  printf '%s' "$1" | sed 's/[][\\.^$*+?{}()|]/\\&/g'
}

redact_stream() {
  if [[ -n "$PANEL_API_TOKEN_VALUE" ]]; then
    sed -E \
      -e "s|$(escape_sed_pattern "$PANEL_API_TOKEN_VALUE")|[REDACTED_PANEL_API_TOKEN]|g" \
      -e 's|(PANEL_API_TOKEN[=:][[:space:]]*)[^[:space:]]+|\1[REDACTED_PANEL_API_TOKEN]|g'
  else
    sed -E 's|(PANEL_API_TOKEN[=:][[:space:]]*)[^[:space:]]+|\1[REDACTED_PANEL_API_TOKEN]|g'
  fi
}

write_report_header() {
  {
    printf 'Remnanode diagnostics report\n'
    printf 'Generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf 'Stack dir: %s\n' "$STACK_DIR"
    printf 'Report file: %s\n' "$REPORT_FILE"
    printf '\n'
    printf 'Runtime files:\n'
    [[ -d "$STACK_DIR" ]] && printf '[OK] %s exists\n' "$STACK_DIR" || printf '[--] %s missing\n' "$STACK_DIR"
    [[ -f "$ENV_FILE" ]] && printf '[OK] .env exists\n' || printf '[--] .env missing\n'
    [[ -f "${STACK_DIR}/docker-compose.yml" ]] && printf '[OK] docker-compose.yml exists\n' || printf '[--] docker-compose.yml missing\n'
    [[ -f "${STACK_DIR}/Caddyfile" ]] && printf '[OK] Caddyfile exists\n' || printf '[--] Caddyfile missing\n'
  } | redact_stream >> "$REPORT_FILE"
}

run_cmd() {
  local title="$1"
  local command="$2"
  local rc=0

  {
    printf '\n== %s ==\n' "$title"
    printf '+ %s\n' "$command"
  } | redact_stream | tee -a "$REPORT_FILE" >/dev/null || true

  set +e
  bash -lc "$command" 2>&1 | redact_stream | tee -a "$REPORT_FILE"
  rc=${PIPESTATUS[0]}
  set -e

  {
    printf '[exit_code=%s]\n' "$rc"
  } | tee -a "$REPORT_FILE" >/dev/null || true

  return 0
}

diagnose() {
  require_root
  mkdir -p "$DIAGNOSTICS_DIR"
  chmod 700 "$DIAGNOSTICS_DIR" 2>/dev/null || true
  : > "$REPORT_FILE"
  chmod 600 "$REPORT_FILE" 2>/dev/null || true

  load_secret_redactions
  write_report_header

  run_cmd "systemctl status docker" "systemctl status docker --no-pager"
  run_cmd "systemctl status containerd" "systemctl status containerd --no-pager"
  run_cmd "systemctl status remnanode-stack" "systemctl status remnanode-stack --no-pager"

  run_cmd "journalctl docker" "journalctl -u docker -b --no-pager -n 200"
  run_cmd "journalctl containerd" "journalctl -u containerd -b --no-pager -n 200"
  run_cmd "journalctl remnanode-stack" "journalctl -u remnanode-stack -b --no-pager -n 200"

  run_cmd "docker info" "timeout 10 docker info"
  run_cmd "docker ps" "timeout 10 docker ps"
  run_cmd "docker ps -a" "docker ps -a"
  run_cmd "docker system df" "docker system df"

  run_cmd "df -h" "df -h"
  run_cmd "du /var/lib/docker" "du -h --max-depth=1 /var/lib/docker"

  run_cmd "docker compose config" "cd /opt/remnanode-stack && docker compose config"
  run_cmd "docker compose ps" "cd /opt/remnanode-stack && docker compose ps"
  run_cmd "docker compose logs" "cd /opt/remnanode-stack && docker compose logs --tail=200"

  run_cmd "iptables DOCKER-USER" "iptables -S DOCKER-USER || true"
  run_cmd "nft ruleset head" "nft list ruleset | head -100 || true"

  info "Diagnostics saved to ${REPORT_FILE}"
}

diagnose
