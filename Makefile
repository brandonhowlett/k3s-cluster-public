# =============================================================================
# k3s-smarthome Makefile
# =============================================================================

# Absolute path to the directory containing this Makefile
ROOT_DIR := $(realpath $(dir $(lastword $(MAKEFILE_LIST))))
SCRIPTS_DIR := $(ROOT_DIR)/scripts

SOPS_CONFIG := .sops.yaml

# Directory where operators live
OPERATORS_DIR := $(ROOT_DIR)/helm/infra/operators

# -------------------------------------------------------------------
# Detect SOPS binary
# -------------------------------------------------------------------
SOPS_BIN := $(shell command -v sops)

ifeq ($(SOPS_BIN),)
$(error "sops not found in PATH")
endif

# -------------------------------------------------------------------
# List all operators (directories under helm/infra/operators)
# -------------------------------------------------------------------
OPERATORS := $(shell find $(OPERATORS_DIR) -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)

# -------------------------------------------------------------------
# Phony targets
# -------------------------------------------------------------------
.PHONY: encrypt encrypt-all check-op check-versions

# -------------------------------------------------------------------
# Validate operator
# -------------------------------------------------------------------
check-op:
	@if [ -n "$(OP)" ] && [ ! -d "$(OPERATORS_DIR)/$(OP)" ]; then \
		echo "[ERROR] Operator '$(OP)' does not exist under $(OPERATORS_DIR)"; \
		exit 1; \
	fi

# -------------------------------------------------------------------
# Encrypt single operator
# -------------------------------------------------------------------
encrypt: check-op
	@set -e; \
	if [ -n "$(OP)" ]; then \
		OP_LIST="$(OP)"; \
	else \
		OP_LIST="$(OPERATORS)"; \
	fi; \
	for op_name in $$OP_LIST; do \
		K8S_DIR="$(OPERATORS_DIR)/$$op_name/k8s"; \
		for f in $$K8S_DIR/*secret.yaml; do \
			[ -f "$$f" ] || continue; \
			out="$${f%.yaml}.sops.yaml"; \
			echo "[INFO] Encrypting $$f → $$out"; \
			$(SOPS_BIN) -e "$$f" > "$$out"; \
		done; \
	done

# -------------------------------------------------------------------
# Encrypt all secrets in the repo, commit, and push
# -------------------------------------------------------------------
encrypt-all: encrypt
	@echo "[INFO] Updating git index for all encrypted files"; \
	updated_files=$$(git -C $(ROOT_DIR) ls-files '*.sops.yaml'); \
	if [ -n "$$updated_files" ]; then \
		git -C $(ROOT_DIR) add $$updated_files; \
		if git -C $(ROOT_DIR) diff --cached --quiet; then \
			echo "[INFO] No changes to commit"; \
		else \
			git -C $(ROOT_DIR) commit -m "Update SOPS-encrypted secrets (*.sops.yaml)"; \
			current_branch=$$(git -C $(ROOT_DIR) rev-parse --abbrev-ref HEAD); \
			echo "[INFO] Pushing committed changes to $$current_branch"; \
			git -C $(ROOT_DIR) push origin $$current_branch; \
		fi; \
	else \
		echo "[INFO] No encrypted files to add"; \
	fi

# -------------------------------------------------------------------
# Check versions (host tooling / calico / operators)
# -------------------------------------------------------------------
check-versions:
	@$(SCRIPTS_DIR)/check-versions.sh
