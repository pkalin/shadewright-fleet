# Helpers for tests/*_test.sh. Sourced.
# shellcheck shell=bash
# shellcheck source=tests/lib_core.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib_core.sh"

export HOME="$T/home"
mkdir -p "$HOME"
export KUBECONFIG="$T/no-kubeconfig"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=harness-test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=harness-test
unset CLUSTER SCENARIO_REF DRY_RUN RECONCILE FLEET_REMOTE KUSTOMIZE KUBECONFORM
unset KIND_CLUSTER_NAME FLEET_URL FLEET_BRANCH FLEET_COMMIT FLEET_REF_NAME EXPECT_COMMIT WAIT_TIMEOUT

# The real kubeconform validates expected.yaml against the local schema (no network).
REAL_KUBECONFORM="${REAL_KUBECONFORM:-}"
if [ -z "$REAL_KUBECONFORM" ]; then
  if [ -x "$SRC_ROOT/bin/kubeconform" ]; then REAL_KUBECONFORM="$SRC_ROOT/bin/kubeconform"; else REAL_KUBECONFORM="$(command -v kubeconform || true)"; fi
fi
[ -n "$REAL_KUBECONFORM" ] || { echo "kubeconform is needed for the tests (make tools)" >&2; exit 1; }
export REAL_KUBECONFORM

STUBS="$T/stubs"
mkdir -p "$STUBS" "$T/no-tools"
# scripts/lib.sh puts bin/ first on PATH; point it at an empty directory so the stubs win over the real tools there.
export FLEET_TOOLS_DIR="$T/no-tools"
export PATH="$STUBS:$PATH"
export STUB_LOG="$T/stub.log"
: >"$STUB_LOG"
