#!/usr/bin/env bash
set -euo pipefail

compare_versions() {
  # returns 0 if $1 >= $2, else 1
  # naive numeric compare, suitable for major.minor.patch
  local ver1="$1"
  local ver2="$2"

  IFS=. read -r -a v1 <<< "${ver1//[!0-9.]/}"
  IFS=. read -r -a v2 <<< "${ver2//[!0-9.]/}"

  for i in 0 1 2; do
    local n1="${v1[i]:-0}"
    local n2="${v2[i]:-0}"
    (( n1 > n2 )) && return 0
    (( n1 < n2 )) && return 1
  done
  return 0
}

parse_duration_seconds() {
  local input="$1"

  [[ -n "$input" ]] || {
    log_error "Empty duration provided"
    return 1
  }

  if [[ "$input" =~ ^[0-9]+$ ]]; then
    echo "$input"
    return 0
  fi

  if [[ "$input" =~ ^([0-9]+)([smh])$ ]]; then
    local value="${BASH_REMATCH[1]}"
    local unit="${BASH_REMATCH[2]}"

    case "$unit" in
      s) echo "$value" ;;
      m) echo $((value * 60)) ;;
      h) echo $((value * 3600)) ;;
    esac
    return 0
  fi

  log_error "Invalid duration format: '$input' (expected: Ns | Nm | Nh | N)"
  return 1
}

is_label_selector() {
  # Matches: key=value[,key=value...]
  [[ "$1" =~ ^[a-zA-Z0-9_.-]+=[^=,]+(,[a-zA-Z0-9_.-]+=[^=,]+)*$ ]]
}

retry() {
  local n=${RETRY_ATTEMPTS:-5}
  local delay=${RETRY_DELAY:-5}
  local i=1

  log_debug "Retry wrapper invoked: attempts=$n delay=${delay}s command=$*"

  until "$@"; do
    if (( i >= n )); then
      log_error "Command failed after $n attempts: $*"
      return 1
    fi

    log_warn "Retry $i/$n failed; retrying in ${delay}s: $*"
    ((i++))
    sleep "$delay"
  done

  log_debug "Command succeeded after $i attempt(s)"
}

check_required_env_vars() {
  local missing=0 var
  [[ $# -gt 0 ]] || { log_error "No environment variables specified"; exit 1; }

  for var in "$@"; do
    if [[ -n "${!var:-}" ]]; then
      printf -v "$var" '%s' "${!var}"
    fi
  done

  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      log_error "Required environment variable not set: $var"
      ((missing++))
    else
      log_debug "Env OK: $var=${!var}"
    fi
  done

  (( missing == 0 )) || exit 1
}

check_required_cmds() {
  local missing=0 cmd
  [[ $# -gt 0 ]] || { log_error "No commands specified"; exit 1; }

  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log_warn "Command missing: $cmd"
      ((missing++))
    else
      log_debug "Command available: $cmd"
    fi
  done

  (( missing == 0 )) || {
    log_info "Some commands are missing and may need to be installed"
    exit 1
  }
}

### Kubectl Helpers ### MOVE LATER

validate_workload_kind() {
  case "$WORKLOAD_KIND" in
    deployment|statefulset|daemonset|none) ;;
    *)
      log_error "Invalid workload kind '${WORKLOAD_KIND}'"
      return 1
      ;;
  esac
}

load_workload_metadata() {
  local dir="$1"
  local file="${dir}/workload.yaml"

  [[ -f "$file" ]] || return 1

  WORKLOAD_KIND="$(yq -r '.kind' "$file")"
  WORKLOAD_NAME="$(yq -r '.name // ""' "$file")"
  WORKLOAD_NAMESPACE="$(yq -r '.namespace // "default"' "$file")"
  WORKLOAD_TIMEOUT="$(yq -r '.rollout.timeout // "120s"' "$file")"
  WORKLOAD_ROLLOUT_ENABLED="$(yq -r '.rollout.enabled // true' "$file")"
}

wait_for_workload_exist() {
  local kind="$1"     # deployment | statefulset | daemonset
  local name="$2"
  local namespace="$3"
  local timeout="$4"

  local timeout_s
  timeout_s="$(parse_duration_seconds "$timeout")"

  local start=$SECONDS
  local poll=3

  log_info "Waiting for ${kind} '${name}' in namespace '${namespace}' (timeout=${timeout_s}s)"

  until kubectl get "$kind" "$name" -n "$namespace" >/dev/null 2>&1; do
    (( SECONDS - start >= timeout_s )) && {
      log_error "Timed out waiting for ${kind} '${name}'"
      return 1
    }
    sleep "$poll"
  done

  log_debug "${kind} '${name}' exists"
}

wait_for_workload() {
  [[ "$WORKLOAD_ROLLOUT_ENABLED" != "true" ]] && return 0

  wait_for_workload_exist \
    "$WORKLOAD_KIND" \
    "$WORKLOAD_NAME" \
    "$WORKLOAD_NAMESPACE" \
    "$WORKLOAD_TIMEOUT"

  case "$WORKLOAD_KIND" in
    deployment|daemonset|statefulset)
      wait_for_rollout \
        "${WORKLOAD_KIND}/${WORKLOAD_NAME}" \
        "$WORKLOAD_NAMESPACE" \
        "$WORKLOAD_TIMEOUT"
      ;;
    none) ;;
    *)
      log_error "Unsupported workload kind: $WORKLOAD_KIND"
      return 1
      ;;
  esac
}

wait_for_deployment_by_name() {
  local name="$1"
  local namespace="${2:-default}"
  local timeout_input="${3:-120}"

  [[ -z "$name" ]] && {
    log_error "wait_for_deployment_by_name: deployment name is required"
    return 2
  }

  local timeout_s
  timeout_s="$(parse_duration_seconds "$timeout_input")"

  local start=$SECONDS
  local elapsed=0
  local poll_interval=3

  log_info "Waiting for Deployment '${name}' in namespace '${namespace}' (timeout=${timeout_s}s)"

  until kubectl get deployment "${name}" -n "${namespace}" >/dev/null 2>&1; do
    sleep "$poll_interval"
    elapsed=$((SECONDS - start))

    if (( elapsed >= timeout_s )); then
      log_error "Timed out waiting for Deployment '${name}' in namespace '${namespace}'"
      return 1
    fi

    log_debug "Deployment '${name}' not present yet (${elapsed}/${timeout_s}s)"
  done

  log_debug "Deployment '${name}' exists (API object present)"
}

wait_for_deployment_by_label() {
  local selector="$1"
  local namespace="${2:-default}"
  local timeout_input="${3:-120}"

  [[ -z "$selector" ]] && {
    log_error "wait_for_deployment_by_label: label selector is required"
    return 2
  }

  is_label_selector "$selector" || {
    log_error "Invalid label selector '${selector}'"
    return 2
  }

  local timeout_s
  timeout_s="$(parse_duration_seconds "$timeout_input")"

  local start=$SECONDS
  local poll_interval=3

  log_info "Waiting for Deployment with selector '${selector}' in namespace '${namespace}' (timeout=${timeout_s}s)"

  until kubectl get deployment \
      -n "${namespace}" \
      -l "${selector}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | grep -q .; do

    (( SECONDS - start >= timeout_s )) && {
      log_error "Timed out waiting for Deployment with selector '${selector}' in namespace '${namespace}'"
      return 1
    }

    sleep "$poll_interval"
  done

  local count
  count=$(kubectl get deployment -n "${namespace}" -l "${selector}" --no-headers 2>/dev/null | wc -l)

  (( count > 1 )) && \
    log_debug "Selector '${selector}' matched ${count} Deployments"

  log_debug "Deployment detected for selector '${selector}'"
}

wait_for_deployment() {
  local target="$1"
  local namespace="${2:-default}"
  local timeout="${3:-120}"

  [[ -z "$target" ]] && {
    log_error "wait_for_deployment: target is required"
    return 2
  }

  if is_label_selector "$target"; then
    wait_for_deployment_by_label "$target" "$namespace" "$timeout" || return $?
  else
    wait_for_deployment_by_name "$target" "$namespace" "$timeout" || return $?
  fi
}

wait_for_rollout() {
  local resource="$1"
  local namespace="${2:-default}"
  local timeout_input="${3:-120}"

  local kind name
  if [[ "$resource" == */* ]]; then
    kind="${resource%%/*}"
    name="${resource##*/}"
  else
    kind="deployment"
    name="$resource"
  fi

  case "$kind" in
    deployment|daemonset|statefulset) ;;
    *)
      log_error "Unsupported rollout kind '${kind}' (resource='${resource}')"
      return 1
      ;;
  esac

  local timeout_s
  timeout_s="$(parse_duration_seconds "$timeout_input")"

  log_info "Waiting for rollout of ${kind}/${name} in namespace '${namespace}' (timeout=${timeout_s}s)"

  if ! kubectl rollout status \
      "${kind}/${name}" \
      -n "${namespace}" \
      --timeout="${timeout_s}s"; then
    log_error "Rollout failed for ${kind}/${name} in namespace '${namespace}'"
    return 1
  fi

  log_info "Rollout complete: ${kind}/${name}"
}

wait_for_deployment_rollout() {
  local resource="$1"
  local namespace="${2:-default}"
  local exist_timeout_input="${3:-120}"
  local rollout_timeout_input="${4:-$exist_timeout_input}"

  local name
  if [[ "$resource" == */* ]]; then
    name="${resource##*/}"
  else
    name="$resource"
  fi

  log_info "Ensuring Deployment '${name}' is present and rolled out"

  wait_for_deployment \
    "${name}" \
    "${namespace}" \
    "${exist_timeout_input}"

  wait_for_rollout \
    "${resource}" \
    "${namespace}" \
    "${rollout_timeout_input}"

  log_info "Deployment '${name}' is ready"
}
