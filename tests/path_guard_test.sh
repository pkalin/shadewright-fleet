#!/usr/bin/env bash
# Offline tests of scripts/path_guard.py: the allow list and the changed paths are files, nothing else is read.
# "Base" below means the allow list the workflow takes from the pull request's base commit.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

GUARD="$SRC_ROOT/scripts/path_guard.py"
BASE="$T/base-paths.txt"
cp "$SRC_ROOT/.github/shadewright-paths.txt" "$BASE"

# guard <allow-list> <json>: runs the guard.
guard() {
  local list="$1" json="$2"
  RC=0
  OUT="$(printf '%s' "$json" | python3 -I "$GUARD" "$list" 2>&1)" || RC=$?
}

guard "$BASE" '["apps/demo/web/deployment.yaml"]'
expect_ok "apps only passes" "all 1 changed paths"

guard "$BASE" '["apps/demo/web/deployment.yaml","apps/demo/worker/scaledobject.yaml","apps/kustomization.yaml"]'
expect_ok "several apps files pass" "all 3 changed paths"

guard "$BASE" '[]'
expect_ok "no changed paths passes" "all 0 changed paths"

guard "$BASE" '[".github/workflows/render.yaml"]'
expect_fail ".github/ fails" "protected path"

guard "$BASE" '[".github/shadewright-paths.txt"]'
expect_fail "the allow list itself fails" "protected path"

guard "$BASE" '[".github/CODEOWNERS"]'
expect_fail "CODEOWNERS fails" "protected path"

guard "$BASE" '["clusters/lab/apps.yaml"]'
expect_fail "clusters/ fails" "protected path"

guard "$BASE" '["infrastructure/keda/helmrelease.yaml"]'
expect_fail "infrastructure/ fails" "protected path"

guard "$BASE" '["README.md"]'
expect_fail "a root file fails" "not on the allow list"

guard "$BASE" '["scenarios/oom/README.md"]'
expect_fail "scenarios/ is not allowed" "not on the allow list"

guard "$BASE" '["apps/demo/web/deployment.yaml","clusters/lab/apps.yaml"]'
expect_fail "one bad path among good ones fails" '"clusters/lab/apps.yaml"'

guard "$BASE" '["myapps/x.yaml","apps"]'
expect_fail "prefix lookalikes fail" "2 of 2"

# A pull request that adds apps/** and a file under a new path: the base copy is used, so the new path fails.
HEAD_LIST="$T/head-paths.txt"
printf 'apps/**\nsecrets/**\n' >"$HEAD_LIST"
guard "$BASE" '[".github/shadewright-paths.txt","secrets/key.yaml"]'
expect_fail "editing the allow list and a newly allowed file fails (base copy)" '"secrets/key.yaml": not on the allow list'
guard "$HEAD_LIST" '["secrets/key.yaml"]'
expect_ok "control: the head copy would have passed it" "all 1 changed paths"
guard "$BASE" '[".github/shadewright-paths.txt"]'
expect_fail "editing only the allow list fails" "protected path"

# Renames list both paths.
guard "$BASE" '["apps/demo/web/deployment.yaml","clusters/lab/deployment.yaml"]'
expect_fail "rename into a protected path fails" "clusters/lab/deployment.yaml"
guard "$BASE" '["clusters/lab/apps.yaml","apps/demo/apps.yaml"]'
expect_fail "rename out of a protected path fails" "clusters/lab/apps.yaml"
guard "$BASE" '["apps/demo/a.yaml","apps/demo/b.yaml"]'
expect_ok "rename inside apps passes" "all 2 changed paths"

# Path forms.
guard "$BASE" '["apps/../clusters/lab/apps.yaml"]'
expect_fail "dot-dot fails" "unexpected path form"
guard "$BASE" '["/apps/x.yaml"]'
expect_fail "absolute path fails" "unexpected path form"
guard "$BASE" '["apps/x\n.github/y"]'
expect_fail "control character fails" "control character"
guard "$BASE" '["Apps/x.yaml"]'
expect_fail "matching is case sensitive" "not on the allow list"
guard "$BASE" '[""]'
expect_fail "empty path fails" "not a path"
guard "$BASE" '[1]'
expect_fail "non-string fails" "not a path"

# Hard denials hold even if the allow list is too wide.
WIDE="$T/wide.txt"
printf '**\n' >"$WIDE"
guard "$WIDE" '[".github/workflows/x.yml","clusters/a.yaml","infrastructure/b.yaml"]'
expect_fail "a ** allow list still cannot open protected paths" "3 of 3"
guard "$WIDE" '["README.md"]'
expect_ok "a ** allow list otherwise matches everything" "all 1 changed paths"

# Glob semantics.
GLOBS="$T/globs.txt"
printf '# comment\n\n  docs/*.md  \nweb/**/x.yaml\nexact?.txt\n' >"$GLOBS"
guard "$GLOBS" '["docs/a.md","web/x.yaml","web/a/b/x.yaml","exact1.txt"]'
expect_ok "globs: *, **/ (also zero directories) and ?" "all 4 changed paths"
guard "$GLOBS" '["docs/sub/a.md"]'
expect_fail "globs: * does not cross /" "not on the allow list"
guard "$GLOBS" '["exact/.txt"]'
expect_fail "globs: ? does not match /" "not on the allow list"
guard "$GLOBS" '["docsXa.md"]'
expect_fail "globs: other characters are literal" "not on the allow list"

# Fail closed on the allow list.
guard "$T/missing.txt" '["apps/x.yaml"]'
expect_fail "missing allow list fails closed" "cannot use the allow list"
: >"$T/empty.txt"
guard "$T/empty.txt" '["apps/x.yaml"]'
expect_fail "empty allow list fails closed" "no patterns"
printf '# only a comment\n\n' >"$T/comments.txt"
guard "$T/comments.txt" '["apps/x.yaml"]'
expect_fail "comment-only allow list fails closed" "no patterns"
printf '/apps/**\n' >"$T/abs.txt"
guard "$T/abs.txt" '["apps/x.yaml"]'
expect_fail "absolute pattern is refused" "unsupported pattern"
printf '../**\n' >"$T/dd.txt"
guard "$T/dd.txt" '["apps/x.yaml"]'
expect_fail "dot-dot pattern is refused" "unsupported pattern"

# Fail closed on the input.
guard "$BASE" 'not json'
expect_fail "invalid JSON fails" "not JSON"
guard "$BASE" '{"a":1}'
expect_fail "non-array JSON fails" "not a JSON array"
RC=0
OUT="$(python3 -I "$GUARD" 2>&1 </dev/null)" || RC=$?
check "no argument is a usage error (exit 2)" test "$RC" -eq 2

finish
