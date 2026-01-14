#!/usr/bin/env bash
set -euo pipefail

# ./..
readonly AGE_DIR="${HOME}/.config/sops/age"
readonly KUBECONFIG_FILE="${HOME}/.kube/config"

# ./
readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly BOOTSTRAP_ENV="${ROOT_DIR}/bootstrap.env"

## ./lib/
readonly LIB_DIR="${ROOT_DIR}/lib"

## ./scripts/
readonly SCRIPTS_DIR="${ROOT_DIR}/scripts"

## ./bootstrap/
readonly BOOTSTRAP_DIR="${ROOT_DIR}/bootstrap"

### ./helm/infra/
readonly OPERATORS_DIR="${ROOT_DIR}/helm/infra/operators"
readonly STATIC_DIR="${ROOT_DIR}/helm/infra/static"

### ./helm/platform/
readonly PLATFORM_DIR="${ROOT_DIR}/helm/platform"
