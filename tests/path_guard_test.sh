#!/usr/bin/env bash
# Offline tests of scripts/path_guard.py: the allow list and the changed paths are files, nothing else is read.
# "Base" below means the allow list the workflow takes from the pull request's base commit.
set -euo pipefail

# Python only: lib_core.sh, not lib.sh, so no kubeconform or other tool is needed.
# shellcheck source=tests/lib_core.sh
. "$(dirname "$0")/lib_core.sh"

GUARD="$SRC_ROOT/scripts/path_guard.py"
BASE="$T/base-paths.txt"
cp "$SRC_ROOT/.github/shadewright-paths.txt" "$BASE"

# guard <allow-list> <json>: runs the guard.
guard() {
  local list="$1" json="$2"
  shift 2
  RC=0
  OUT="$(printf '%s' "$json" | python3 -I "$GUARD" "$list" "$@" 2>&1)" || RC=$?
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
expect_fail "a root file fails" "protected path"

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

# The matcher itself, its tests, the Makefile and root files can never be opened.
guard "$BASE" '["scripts/path_guard.py"]'
expect_fail "scripts/ fails" "protected path"
guard "$BASE" '["tests/path_guard_test.sh"]'
expect_fail "tests/ fails" "protected path"
guard "$BASE" '["Makefile"]'
expect_fail "Makefile fails" "protected path"
guard "$BASE" '["AGENTS.md","README.md",".gitignore"]'
expect_fail "root files fail" "3 of 3"

# Hard denials hold even if the allow list is too wide.
WIDE="$T/wide.txt"
printf '**\n' >"$WIDE"
guard "$WIDE" '[".github/workflows/x.yml","clusters/a.yaml","infrastructure/b.yaml"]'
expect_fail "a ** allow list still cannot open protected paths" "3 of 3"
guard "$WIDE" '["scripts/path_guard.py","tests/lib.sh","Makefile","README.md","LICENSE"]'
expect_fail "a ** allow list still cannot open the matcher, tests, Makefile or root files" "5 of 5"
guard "$WIDE" '["docs/a.md","apps/x.yaml"]'
expect_ok "a ** allow list otherwise matches everything" "all 2 changed paths"

# Glob semantics.
GLOBS="$T/globs.txt"
printf '# comment\n\n  docs/*.md  \nweb/**/x.yaml\nd/exact?.txt\n' >"$GLOBS"
guard "$GLOBS" '["docs/a.md","web/x.yaml","web/a/b/x.yaml","d/exact1.txt"]'
expect_ok "globs: *, **/ (also zero directories) and ?" "all 4 changed paths"
guard "$GLOBS" '["docs/sub/a.md"]'
expect_fail "globs: * does not cross /" "not on the allow list"
guard "$GLOBS" '["d/exact/.txt"]'
expect_fail "globs: ? does not match /" "not on the allow list"
guard "$GLOBS" '["docsXa/a.md"]'
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

# Symlinks and submodules, from the head tree (the raw git/trees API response).
tree() { printf '%s' "$1" >"$T/tree.json"; }
tree '{"truncated":false,"tree":[{"path":"apps/a.yaml","mode":"100644","type":"blob"},{"path":"apps/link","mode":"120000","type":"blob"},{"path":"apps/sub","mode":"160000","type":"commit"},{"path":"apps","mode":"040000","type":"tree"}]}'
guard "$BASE" '["apps/a.yaml"]' "$T/tree.json"
expect_ok "tree: a regular file passes" "all 1 changed paths"
guard "$BASE" '["apps/link"]' "$T/tree.json"
expect_fail "tree: a symlink fails" "symlink is not allowed"
guard "$BASE" '["apps/sub"]' "$T/tree.json"
expect_fail "tree: a submodule fails" "submodule is not allowed"
guard "$BASE" '["apps/deleted.yaml"]' "$T/tree.json"
expect_ok "tree: a deleted path (absent from the tree) passes" "all 1 changed paths"
tree '{"truncated":true,"tree":[]}'
guard "$BASE" '["apps/a.yaml"]' "$T/tree.json"
expect_fail "tree: truncated fails closed" "truncated"
tree '{"tree":[]}'
guard "$BASE" '["apps/a.yaml"]' "$T/tree.json"
expect_fail "tree: missing truncated flag fails closed" "truncated"
tree 'not json'
guard "$BASE" '["apps/a.yaml"]' "$T/tree.json"
expect_fail "tree: invalid JSON fails closed" "cannot read the tree"
tree '{"truncated":false,"tree":[{"path":"apps/a.yaml"}]}'
guard "$BASE" '["apps/a.yaml"]' "$T/tree.json"
expect_fail "tree: malformed entry fails closed" "malformed tree entry"
guard "$BASE" '["apps/a.yaml"]' "$T/no-such-tree.json"
expect_fail "tree: missing file fails closed" "cannot read the tree"

# Fail closed on the input.
guard "$BASE" 'not json'
expect_fail "invalid JSON fails" "not JSON"
guard "$BASE" '{"a":1}'
expect_fail "non-array JSON fails" "not a JSON array"
RC=0
OUT="$(python3 -I "$GUARD" 2>&1 </dev/null)" || RC=$?
check "no argument is a usage error (exit 2)" test "$RC" -eq 2

finish
