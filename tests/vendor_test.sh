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

# --- fixture operator repositories -----------------------------------------------------------------------------------

SIDECAR="busybox@sha256:$(printf 'c%.0s' $(seq 1 64))"

# make_fixture <dir> <extra pod spec lines for the analyzer, indented 6 spaces> <analyzer container name>: a repository whose
# analyzer Deployment has a pinned sidecar BEFORE the analyzer container, so setting images by position would be wrong.
make_fixture() {
  local dir="$1" extra="$2" name="$3"
  mkdir -p "$dir/config/default" "$dir/config/watch"
  git init -q "$dir"
  cat >"$dir/config/default/kustomization.yaml" <<'YAML'
namespace: shadewright-system
namePrefix: shadewright-
resources:
  - deployments.yaml
YAML
  {
    cat <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: analyzer
  namespace: system
spec:
  template:
    spec:
${extra}
      containers:
        - name: sidecar
          image: ${SIDECAR}
        - name: ${name}
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
  } >"$dir/config/default/deployments.yaml"
  cat >"$dir/config/watch/kustomization.yaml" <<'YAML'
resources:
  - role_binding_demo.yaml
YAML
  cat >"$dir/config/watch/role_binding_demo.yaml" <<'YAML'
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
  git -C "$dir" add -A
  git -C "$dir" commit -q -m fixture
}

OP="$T/operator"
make_fixture "$OP" "      serviceAccountName: analyzer" analyzer
COMMIT="$(git -C "$OP" rev-parse HEAD)"
OP_INIT="$T/operator-init"
make_fixture "$OP_INIT" "      initContainers:
        - name: init
          image: busybox:1.36" analyzer
COMMIT_INIT="$(git -C "$OP_INIT" rev-parse HEAD)"
OP_NAME="$T/operator-name"
make_fixture "$OP_NAME" "      serviceAccountName: analyzer" manager
COMMIT_NAME="$(git -C "$OP_NAME" rev-parse HEAD)"
PUBLIC="https://github.com/pkalin/shadewright"
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
check "sets images by container name: the sidecar before the analyzer stays" grep -q "image: ${SIDECAR}\$" "$OUT_DIR/install.yaml"
check "records only the public repository" grep -qx "repository=${PUBLIC}" "$OUT_DIR/VENDOR"
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

# A moving tag on an init container (a list item with only image and name) is refused, and nothing is written.
run env SHADEWRIGHT_REPO="$OP_INIT" "$VENDOR" "$COMMIT_INIT" --analyzer-digest "$A" --executor-digest "$E"
expect_fail "refuses an init container with a moving tag" "not pinned by digest"
# A container the script was told to set but that does not exist is refused (the patch would add it).
run env SHADEWRIGHT_REPO="$OP_NAME" "$VENDOR" "$COMMIT_NAME" --analyzer-digest "$A" --executor-digest "$E"
expect_fail "refuses a missing container" "no container analyzer"
# Only the public repository may build the committed install.
run env -u VENDOR_OUT "$VENDOR" "$COMMIT" --analyzer-digest "$A" --executor-digest "$E"
expect_fail "refuses another repository when writing the committed directory" "needs VENDOR_OUT"
# Digests recorded for another repository are not reused.
sed -i.bak 's#^repository=.*#repository=https://example.org/fork#' "$OUT_DIR/VENDOR" && rm "$OUT_DIR/VENDOR.bak"
run "$VENDOR" "$COMMIT"
expect_fail "does not reuse digests recorded for another repository" "give --analyzer-digest"

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
