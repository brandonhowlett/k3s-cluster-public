#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/lib/loader.sh"

log "=== Phase 03: Infra Smoke Test ==="

# -------------------------------------------------------------------
# Create temporary test secret with SOPS
# -------------------------------------------------------------------
TMP_NS="default"
TMP_SECRET="test-sopssecret"
TMP_FILE="$(mktemp /tmp/test-sopssecret.XXXX.yaml)"

cat > "$TMP_FILE" <<EOF
apiVersion: isindir.github.com/v1alpha3
kind: SopsSecret
metadata:
  name: $TMP_SECRET
  namespace: $TMP_NS
spec:
  suspend: false
  secretTemplates:
    - name: $TMP_SECRET
      stringData:
        password: test
EOF

ENC_FILE="${TMP_FILE}.sops.yaml"
sops -e "$TMP_FILE" > "$ENC_FILE"

kubectl apply -f "$ENC_FILE"

# -------------------------------------------------------------------
# Verify secret exists and decodes correctly
# -------------------------------------------------------------------
TIMEOUT=30
for i in $(seq 1 $TIMEOUT); do
  if kubectl get secret $TMP_SECRET -n $TMP_NS >/dev/null 2>&1; then break; fi
  sleep 1
done

log -n "Decoded secret: "
kubectl get secret $TMP_SECRET -n $TMP_NS -o jsonpath='{.data.password}' | base64 -d
log

# -------------------------------------------------------------------
# Cleanup
# -------------------------------------------------------------------
kubectl delete secret $TMP_SECRET -n $TMP_NS
kubectl delete sopssecret $TMP_SECRET -n $TMP_NS
rm -f "$TMP_FILE" "$ENC_FILE"

log "=== SOPS secret smoke test complete ==="
