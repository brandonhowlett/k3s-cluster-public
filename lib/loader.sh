#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Logging (must be first)
# -------------------------------------------------------------------

readonly LOG_LEVEL_DEBUG=10
readonly LOG_LEVEL_INFO=20
readonly LOG_LEVEL_WARN=30
readonly LOG_LEVEL_ERROR=40

: "${LOG_LEVEL:=${LOG_LEVEL_INFO}}"

_log_ts() {
  date +"%Y-%m-%dT%H:%M:%S%z"
}

_log_emit() {
  local level="$1"
  local label="$2"
  shift 2

  (( LOG_LEVEL <= level )) || return 0

  printf '[%s] %-5s %s\n' \
    "$(_log_ts)" \
    "$label" \
    "$*" >&2
}

# Left for testing purposes only >>> REMOVE LATER <<<
log() { 
  printf '[%s] %s\n' \
    "$(_log_ts)" \
    "$*" >&2
}

log_debug() { _log_emit "${LOG_LEVEL_DEBUG}" "DEBUG" "$@"; }
log_info()  { _log_emit "${LOG_LEVEL_INFO}"  "INFO " "$@"; }
log_warn()  { _log_emit "${LOG_LEVEL_WARN}"  "WARN " "$@"; }
log_error() { _log_emit "${LOG_LEVEL_ERROR}" "ERROR" "$@"; }

die() {
  log_error "$@"
  exit 1
}

# -------------------------------------------------------------------
# Prevent double-load
# -------------------------------------------------------------------
[[ -n "${__BOOTSTRAP_LIB_LOADED:-}" ]] && return
__BOOTSTRAP_LIB_LOADED=1

# -------------------------------------------------------------------
# Base script dir
# -------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -------------------------------------------------------------------
# Load paths
# -------------------------------------------------------------------
if [[ -z "${__PATHS_LOADED:-}" ]]; then
    source "$SCRIPT_DIR/paths.sh"
    __PATHS_LOADED=1
fi

# -------------------------------------------------------------------
# Load bootstrap.env
# -------------------------------------------------------------------
if [[ -z "${__VERSIONS_ENV_LOADED:-}" ]]; then
    source "${BOOTSTRAP_ENV}"
    __VERSIONS_ENV_LOADED=1
fi

# -------------------------------------------------------------------
# Source all library scripts in lib/
# -------------------------------------------------------------------
shopt -s nullglob
for libfile in "$LIB_DIR"/*.sh; do
    [[ "$(basename "$libfile")" == "loader.sh" ]] && continue
    [[ "$(basename "$libfile")" == "paths.sh" ]] && continue

    safe_name="${libfile##*/}"
    safe_name="${safe_name%.sh}"
    safe_name="${safe_name//-/_}"
    guard_var="__LIB_${safe_name}_LOADED"

    if [[ -z "${!guard_var:-}" ]]; then
        source "$libfile"
        declare -g "$guard_var"=1
    fi
done
shopt -u nullglob
