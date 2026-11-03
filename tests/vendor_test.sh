#!/usr/bin/env bash
# Offline tests of scripts/vendor-shadewright.sh against a fixture operator repository (a local Git repository, real
# pinned kustomize), and of the committed infrastructure/shadewright tree against its VENDOR header.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

REAL_KUSTOMIZE="${REAL_KUSTOMIZE:-}"
if [ -z "$REAL_KUSTOMIZE" ]; then
  if [ -x "$SRC_ROOT/bin/kustomize" ]; then REAL_KUSTOMIZE="$SRC_ROOT/bin/kustomize"; else REAL_KUSTOMIZE="$(command -v kustomize || true)"; fi
fi
[ -n "$REAL_KUSTOMIZE" ] || { echo "kustomize is needed for the tests (make tools)" >&2; exit 1; }
export KUSTOMIZE="$REAL_KUSTOMIZE"

A="sha256:$(printf 'a%.0s' $(seq 1 64))"
E="sha256:$(printf 'e%.0s' $(seq 1 64))"
B="sha256:$(printf 'b%.0s' $(seq 1 64))"

# --- fixture operator repository -------------------------------------------------------------------------------------

OP="$T/operator"
mkdir -p "$OP/config/default" "$OP/config/watch"
git init -q "$OP"
cat >"$OP/config/default/kustomization.yaml" <<'YAML'
namespace: shadewright-system
namePrefix: shadewright-
resources:
  - deployments.yaml
YAML
cat >"$OP/config/default/deployments.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: analyzer
  namespace: system
spec:
  template:
    spec:
      containers:
        - name: analyzer
          image: controller:latest
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: executor
  namespace: system
spec:
  template:
    spec:
      containers:
        - name: executor
          image: controller:latest
YAML
cat >"$OP/config/watch/kustomization.yaml" <<'YAML'
resources:
  - role_binding_demo.yaml
YAML
cat >"$OP/config/watch/role_binding_demo.yaml" <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: shadewright-analyzer-watch
  namespace: demo
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: shadewright-analyzer-watch-role
subjects:
  - kind: ServiceAccount
    name: shadewright-analyzer
    namespace: shadewright-system
YAML
git -C "$OP" add -A
git -C "$OP" commit -q -m fixture
COMMIT="$(git -C "$OP" rev-parse HEAD)"
export SHADEWRIGHT_REPO="$OP"

VENDOR="$SRC_ROOT/scripts/vendor-shadewright.sh"
OUT_DIR="$T/out"
export VENDOR_OUT="$OUT_DIR"

# --- the script ------------------------------------------------------------------------------------------------------

run "$VENDOR" "$COMMIT" --analyzer-digest "$A" --executor-digest "$E"
expect_ok "vendors a commit" "vendored ${COMMIT}"

check "sets the analyzer image to its digest" grep -q "image: ghcr.io/pkalin/shadewright-analyzer@${A}\$" "$OUT_DIR/install.yaml"
check "sets the executor image to its digest" grep -q "image: ghcr.io/pkalin/shadewright-executor@${E}\$" "$OUT_DIR/install.yaml"
check "leaves no placeholder image" bash -c "! grep -q 'controller:latest' '$OUT_DIR/install.yaml'"
check "records the commit and digests in VENDOR" bash -c \
  "grep -q '^commit=${COMMIT}\$' '$OUT_DIR/VENDOR' && grep -q '^analyzer_digest=${A}\$' '$OUT_DIR/VENDOR' && grep -q '^executor_digest=${E}\$' '$OUT_DIR/VENDOR'"
check "builds the RoleBinding for demo" grep -q 'namespace: demo$' "$OUT_DIR/watch-demo.yaml"

first="$(cd "$OUT_DIR" && cat install.yaml watch-demo.yaml VENDOR | cksum)"
run "$VENDOR" "$COMMIT"
expect_ok "reuses the digests in VENDOR for the same commit" "vendored"
second="$(cd "$OUT_DIR" && cat install.yaml watch-demo.yaml VENDOR | cksum)"
check "rerunning at the same commit changes nothing" test "$first" = "$second"

run "$VENDOR" "$COMMIT" --analyzer-digest "$B" --executor-digest "$E"
expect_ok "accepts new digests"
check "new digest replaces the old one" grep -q "shadewright-analyzer@${B}\$" "$OUT_DIR/install.yaml"

# --- refusals: nothing is written ------------------------------------------------------------------------------------

before="$(cd "$OUT_DIR" && cat install.yaml watch-demo.yaml VENDOR | cksum)"
run "$VENDOR" "$COMMIT" --analyzer-digest "sha-1234567" --executor-digest "$E"
expect_fail "refuses a tag for the analyzer" "not a tag"
run "$VENDOR" "$COMMIT" --analyzer-digest "$A" --executor-digest "main"
expect_fail "refuses a tag for the executor" "not a tag"
run "$VENDOR" "$COMMIT" --analyzer-digest "sha256:abc" --executor-digest "$E"
expect_fail "refuses a short digest" "not a tag"
run "$VENDOR" "$COMMIT" --analyzer-digest "sha256:$(printf 'A%.0s' $(seq 1 64))" --executor-digest "$E"
expect_fail "refuses an upper-case digest" "not a tag"
run "$VENDOR" "${COMMIT%????????}" --analyzer-digest "$A" --executor-digest "$E"
expect_fail "refuses a short commit" "full 40-character"
run "$VENDOR" main --analyzer-digest "$A" --executor-digest "$E"
expect_fail "refuses a branch name" "full 40-character"
run "$VENDOR" "$(printf '0%.0s' $(seq 1 40))" --analyzer-digest "$A" --executor-digest "$E"
expect_fail "refuses a commit that cannot be fetched" "cannot fetch"
run "$VENDOR" "$(printf '1%.0s' $(seq 1 40))"
expect_fail "needs digests for a commit that VENDOR does not name" "give --analyzer-digest"
after="$(cd "$OUT_DIR" && cat install.yaml watch-demo.yaml VENDOR | cksum)"
check "refused runs left the output alone" test "$before" = "$after"
run "$VENDOR" "$COMMIT" --analyzer-digest "$A"
expect_ok "a single new digest keeps the other from VENDOR" "vendored"
check "the other digest stays" grep -q "shadewright-executor@${E}\$" "$OUT_DIR/install.yaml"

# --- the committed tree ----------------------------------------------------------------------------------------------

V="$SRC_ROOT/infrastructure/shadewright"
vendor_value() { sed -n "s/^$1=//p" "$V/VENDOR" | head -n 1; }
check "committed VENDOR names a full commit" grep -Eq '^commit=[0-9a-f]{40}$' "$V/VENDOR"
check "committed analyzer image is the digest in VENDOR" \
  grep -q "image: ghcr.io/pkalin/shadewright-analyzer@$(vendor_value analyzer_digest)\$" "$V/install.yaml"
check "committed executor image is the digest in VENDOR" \
  grep -q "image: ghcr.io/pkalin/shadewright-executor@$(vendor_value executor_digest)\$" "$V/install.yaml"
check "every committed image is pinned by digest" \
  bash -c "! grep -E '^[[:space:]]*image:' '$V/install.yaml' | grep -vqE '@sha256:[0-9a-f]{64}\$'"

finish
