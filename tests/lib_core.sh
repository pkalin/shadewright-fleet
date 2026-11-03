# Helpers shared by tests/*_test.sh that need nothing but bash. Sourced; tests/lib.sh builds on it.
# shellcheck shell=bash

# shellcheck disable=SC2034 # used by the tests that source this file
SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0
PASSED=0

# Never reach a real cluster or the user's Git setup, whatever the stubs miss.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

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
