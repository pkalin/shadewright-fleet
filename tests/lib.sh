# Helpers for tests/*_test.sh. Sourced.
# shellcheck shell=bash

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0
PASSED=0

# Never reach a real cluster or the user's Git setup, whatever the stubs miss.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
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
mkdir -p "$STUBS"
export PATH="$STUBS:$PATH"
export STUB_LOG="$T/stub.log"
: >"$STUB_LOG"

ok() { PASSED=$((PASSED + 1)); echo "ok - $1"; }
not_ok() { FAILED=$((FAILED + 1)); echo "not ok - $1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/#   /'; }

# run <cmd...>: runs a command, keeps its exit code in RC and its output in OUT.
run() {
  RC=0
  OUT="$("$@" 2>&1)" || RC=$?
}

# expect_fail <name> <pattern>: the last run failed and printed the pattern.
expect_fail() {
  if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qE -- "$2"; then ok "$1"; else not_ok "$1" "rc=${RC}: ${OUT}"; fi
}

expect_ok() {
  if [ "$RC" -eq 0 ] && { [ -z "${2:-}" ] || printf '%s' "$OUT" | grep -qE -- "$2"; }; then ok "$1"; else not_ok "$1" "rc=${RC}: ${OUT}"; fi
}

# check <name> <command...>: passes when the command succeeds.
check() {
  local name="$1"
  shift
  if "$@"; then ok "$name"; else not_ok "$name"; fi
}

finish() {
  echo "# passed ${PASSED}, failed ${FAILED}"
  [ "$FAILED" -eq 0 ]
}
