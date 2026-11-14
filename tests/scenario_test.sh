#!/usr/bin/env bash
# Offline tests of scripts/scenario.sh against a fixture repository with a local bare remote and stubbed kubectl and
# render tools. Each test checks what reached the remote: main and the other cluster's branch must never move.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

# --- stubs -----------------------------------------------------------------------------------------------------------

cat >"$STUBS/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$STUB_LOG"
args=" $* "
case "$args" in
  *" config current-context "*) echo "${STUB_CONTEXT-kind-test}"; exit 0 ;;
  *" annotate "*) exit 0 ;;
  *" get gitrepository fleet "*)
    [ "${STUB_NO_GITREPO:-0}" = 0 ] || { echo 'Error from server (NotFound)' >&2; exit 1; }
    case "$args" in
      *'{.spec.ref.branch}{"\n"}{.spec.ref.tag}{.spec.ref.semver}{.spec.ref.name}{.spec.ref.commit}{"\n"}{.spec.url}'*)
        printf '%s\n%s\n%s' "${STUB_BRANCH-cluster/kind}" "${STUB_OTHER-}" "${STUB_URL}" ;;
      *) exit 1 ;;
    esac
    exit 0 ;;
esac
echo "unexpected kubectl call: $*" >&2
exit 1
EOF

cat >"$STUBS/kustomize" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  version) echo "${STUB_KUSTOMIZE_VERSION:-v5.8.1}"; exit 0 ;;
  build)
    if grep -rqs 'shadewright-test: unbuildable' "$2"; then echo "build failed" >&2; exit 1; fi
    find "$2" -name '*.yaml' ! -name kustomization.yaml | sort | while IFS= read -r f; do cat "$f"; echo '---'; done
    exit 0 ;;
esac
exit 1
EOF

# Validates expected.yaml with the real kubeconform (local schema); a render passes unless it holds the marker.
cat >"$STUBS/kubeconform" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" -v "*) echo "${STUB_KUBECONFORM_VERSION:-v0.8.0}"; exit 0 ;;
  *"scenarios/schema/"*) exec "$REAL_KUBECONFORM" "$@" ;;
esac
in="$(cat)"
if printf '%s' "$in" | grep -q 'shadewright-test: invalid'; then echo "invalid resource" >&2; exit 1; fi
echo "Summary: stub - Valid"
EOF
chmod +x "$STUBS/kubectl" "$STUBS/kustomize" "$STUBS/kubeconform"

# --- fixture ---------------------------------------------------------------------------------------------------------

REMOTE_DIR="$T/remote.git"
WORK="$T/work"
export STUB_URL="file://${REMOTE_DIR}"

expected() { # expected <name> [render] [extra top-level line]
  cat <<EOF
apiVersion: scenarios.shadewright.io/v1alpha1
kind: Scenario
name: $1
summary: test scenario $1
EOF
  [ -z "${2:-}" ] || echo "render: $2"
  cat <<EOF
incident:
  reason: OOMKilled
  status: planned
  source: test
  object:
    apiVersion: apps/v1
    kind: Deployment
    namespace: demo
    name: web
diagnosis:
  status: planned
  evidence:
    - fact: OOMKilled
      source: test
outcome:
  type: refusal
  status: planned
  reason: test
EOF
  [ -z "${3:-}" ] || echo "$3"
}

scenario() { # scenario <name> [render] [extra]: README and expected.yaml
  mkdir -p "scenarios/$1"
  echo "# $1" >"scenarios/$1/README.md"
  expected "$@" >"scenarios/$1/expected.yaml"
}

git init -q --bare "$REMOTE_DIR"
git init -q "$WORK"
cd "$WORK"
mkdir -p scripts apps/demo scenarios
cp "$SRC_ROOT"/scripts/*.sh "$SRC_ROOT/scripts/tools.env" scripts/
cp -R "$SRC_ROOT/scenarios/schema" scenarios/schema
printf 'resources:\n  - demo\n' >apps/kustomization.yaml
printf 'resources:\n  - web.yaml\n  - worker.yaml\n' >apps/demo/kustomization.yaml
printf 'kind: Deployment\nmetadata:\n  name: web\n# healthy\n' >apps/demo/web.yaml
printf 'kind: Deployment\nmetadata:\n  name: worker\n# healthy\n' >apps/demo/worker.yaml
echo 'outside' >README.md

scenario good
mkdir -p scenarios/good/apps/demo
printf 'kind: Deployment\nmetadata:\n  name: web\n# broken by good\n' >scenarios/good/apps/demo/web.yaml
scenario other
mkdir -p scenarios/other/apps/demo
printf 'kind: Deployment\nmetadata:\n  name: worker\n# broken by other\n' >scenarios/other/apps/demo/worker.yaml
scenario invalid fails
mkdir -p scenarios/invalid/apps/demo
printf 'kind: Deployment\nshadewright-test: invalid\n' >scenarios/invalid/apps/demo/web.yaml
scenario undeclared
mkdir -p scenarios/undeclared/apps/demo
printf 'kind: Deployment\nshadewright-test: invalid\n' >scenarios/undeclared/apps/demo/web.yaml
scenario says-fails fails
scenario outside
mkdir -p scenarios/outside/infrastructure
echo 'kind: Namespace' >scenarios/outside/infrastructure/x.yaml
scenario linked
mkdir -p scenarios/linked/apps/demo
ln -s ../../../../README.md scenarios/linked/apps/demo/web.yaml
scenario extra-field '' 'unexpected: true'
scenario unmarked
# An expectation without observed or planned, and evidence without a source, is refused.
sed -e '/^  status: /d' -e '/^  source: test$/d' -e '/^      source: test$/d' scenarios/unmarked/expected.yaml >"$T/x" && mv "$T/x" scenarios/unmarked/expected.yaml
scenario misnamed
sed 's/^name: misnamed$/name: someone-else/' scenarios/misnamed/expected.yaml >"$T/x" && mv "$T/x" scenarios/misnamed/expected.yaml
mkdir -p scenarios/no-readme
expected no-readme >scenarios/no-readme/expected.yaml
# New files under apps/demo/: only with the scenario's own kustomization.yaml that lists them.
scenario new-file
mkdir -p scenarios/new-file/apps/demo
printf 'kind: ConfigMap\n' >scenarios/new-file/apps/demo/extra.yaml
scenario new-unlisted
mkdir -p scenarios/new-unlisted/apps/demo
printf 'kind: ConfigMap\n' >scenarios/new-unlisted/apps/demo/extra.yaml
printf 'resources:\n  - web.yaml\n  - worker.yaml\n  # - extra.yaml\n' >scenarios/new-unlisted/apps/demo/kustomization.yaml
scenario new-dir
mkdir -p scenarios/new-dir/apps/demo/sub
printf 'kind: ConfigMap\n' >scenarios/new-dir/apps/demo/sub/extra.yaml
printf 'resources:\n  - web.yaml\n  - worker.yaml\n  - sub\n' >scenarios/new-dir/apps/demo/kustomization.yaml
scenario new-listed
mkdir -p scenarios/new-listed/apps/demo
printf 'kind: ConfigMap\n' >scenarios/new-listed/apps/demo/extra.yaml
printf 'resources:\n  - web.yaml\n  - worker.yaml\n  - "extra.yaml" # added\n' >scenarios/new-listed/apps/demo/kustomization.yaml
# A scenario's kustomization.yaml must keep everything the base lists, or Flux prunes the omitted workload.
scenario drops-base
mkdir -p scenarios/drops-base/apps/demo
printf 'kind: Deployment\nmetadata:\n  name: web\n# broken by drops-base\n' >scenarios/drops-base/apps/demo/web.yaml
printf 'resources:\n  - web.yaml\n' >scenarios/drops-base/apps/demo/kustomization.yaml
# expected.yaml forms the harness cannot read exactly are refused, never guessed.
scenario block-render '' "$(printf 'render: >-\n  fails')"
scenario quoted
sed -e "s/^name: quoted$/name: 'quoted' # the folder/" -e 's/^summary: .*/summary: "a value # with a hash"/' \
  scenarios/quoted/expected.yaml >"$T/x" && mv "$T/x" scenarios/quoted/expected.yaml

git add -A
git commit -q -m init
git branch -M main
git remote add origin "$REMOTE_DIR"
git push -q origin main main:cluster/kind main:cluster/lab
MAIN0="$(git rev-parse main)"

remote_ref() { git --git-dir "$REMOTE_DIR" rev-parse --verify --quiet "refs/heads/$1" || echo none; }
harness() { scripts/scenario.sh "$@"; }

untouched() { # main and cluster/lab never move in any test
  [ "$(remote_ref main)" = "$MAIN0" ] && [ "$(remote_ref cluster/lab)" = "$MAIN0" ]
}

# --- refusals before Git is touched -----------------------------------------------------------------------------------

run harness apply good
expect_fail "apply without CLUSTER is refused" "set the cluster explicitly"
run env CLUSTER=main scripts/scenario.sh apply good
expect_fail "CLUSTER=main is refused" "unknown cluster 'main'"
run env CLUSTER=prod scripts/scenario.sh reset
expect_fail "an unknown cluster is refused" "unknown cluster 'prod'"

KIND0="$(remote_ref cluster/kind)"
run env CLUSTER=kind STUB_BRANCH=main scripts/scenario.sh apply good
expect_fail "Flux tracking main is refused" "tracks 'main', not cluster/kind"
run env CLUSTER=kind STUB_BRANCH=cluster/lab scripts/scenario.sh reset
expect_fail "Flux tracking another cluster's branch is refused" "tracks 'cluster/lab', not cluster/kind"
run env CLUSTER=lab STUB_BRANCH=cluster/kind scripts/scenario.sh apply good
expect_fail "CLUSTER=lab on the Kind context is refused" "tracks 'cluster/kind', not cluster/lab"
run env CLUSTER=kind STUB_BRANCH= STUB_OTHER=refs/pull/7/head scripts/scenario.sh apply good
expect_fail "a GitRepository on a ref, not a branch (CI baseline), is refused" "tracks no branch"
run env CLUSTER=kind STUB_OTHER=0123456789012345678901234567890123456789 scripts/scenario.sh apply good
expect_fail "a branch pinned to a commit is refused" "pins a tag, semver, ref name or commit"
run env CLUSTER=kind STUB_URL=https://github.com/someone/else scripts/scenario.sh apply good
expect_fail "a cluster syncing another repository is refused" "the cluster syncs github.com/someone/else"
git remote set-url origin "https://user:s3cret-token@github.com/pkalin/shadewright-fleet.git"
run env CLUSTER=kind STUB_URL=https://github.com/someone/else scripts/scenario.sh apply good
expect_fail "a remote URL mismatch is refused" "but remote origin is github.com/pkalin/shadewright-fleet: refusing"
check "the refusal never prints the remote's credentials" sh -c "! printf '%s' \"\$1\" | grep -q 's3cret-token'" _ "$OUT"
git remote set-url origin "$REMOTE_DIR"
run env CLUSTER=kind STUB_NO_GITREPO=1 scripts/scenario.sh reset
expect_fail "a context without the fleet GitRepository is refused" "cannot read GitRepository"
run env CLUSTER=kind STUB_CONTEXT= scripts/scenario.sh reset
expect_fail "no current context is refused" "no current kube context"
run env CLUSTER=kind STUB_KUSTOMIZE_VERSION=v5.0.0 scripts/scenario.sh apply good
expect_fail "another kustomize version is refused" "kustomize must be v5.8.1"
run env CLUSTER=kind STUB_KUBECONFORM_VERSION=v0.6.0 scripts/scenario.sh apply good
expect_fail "another kubeconform version is refused" "kubeconform must be v0.8.0"
for bad in ../good list schema Good 'a b' -x; do
  run env CLUSTER=kind scripts/scenario.sh apply "$bad"
  expect_fail "scenario name '${bad}' is refused" "invalid scenario name"
done
check "refusals pushed nothing" test "$(remote_ref cluster/kind)" = "$KIND0"
check "refusals left main and cluster/lab alone" untouched

# --- scenario contents ------------------------------------------------------------------------------------------------

for case_ in "outside:is outside apps/demo/" "linked:is not a regular file" "extra-field:does not match" \
  "unmarked:does not match" \
  "misnamed:name must be misnamed" "no-readme:README.md is missing" \
  "undeclared:render fails, but its expected.yaml says render: passes" \
  "says-fails:render passes, but its expected.yaml says render: fails" \
  "new-file:apps/demo/extra.yaml is new: the scenario must also replace apps/demo/kustomization.yaml" \
  "new-unlisted:kustomization.yaml does not list extra.yaml" \
  "new-dir:apps/demo/sub/ does not exist on the base commit" \
  "drops-base:does not list worker.yaml, which apps/demo/kustomization.yaml on the base commit lists" \
  "block-render:cannot read render"; do
  name="${case_%%:*}"
  run env CLUSTER=kind scripts/scenario.sh apply "$name"
  expect_fail "scenario ${name} is refused" "${case_#*:}"
done
run env CLUSTER=kind scripts/scenario.sh apply missing
expect_fail "an unknown scenario is refused" "no scenario missing on origin/main"
check "refused scenarios pushed nothing" test "$(remote_ref cluster/kind)" = "$KIND0"

run env CLUSTER=kind DRY_RUN=1 scripts/scenario.sh apply new-listed
expect_ok "a new file listed in the scenario's kustomization.yaml is accepted" "not pushed"
run env CLUSTER=kind DRY_RUN=1 scripts/scenario.sh apply quoted
expect_ok "quoted values with a comment are read exactly" "nothing to push"

# --- a missing cluster branch is never created ------------------------------------------------------------------------

git --git-dir "$REMOTE_DIR" update-ref -d refs/heads/cluster/kind
run env CLUSTER=kind scripts/scenario.sh reset
expect_fail "a missing cluster branch is refused" "cluster/kind does not exist on origin"
check "the missing branch was not created" test "$(remote_ref cluster/kind)" = none
git --git-dir "$REMOTE_DIR" update-ref refs/heads/cluster/kind "$MAIN0"

# --- switching on and resetting ---------------------------------------------------------------------------------------

run env CLUSTER=kind DRY_RUN=1 scripts/scenario.sh apply good
expect_ok "DRY_RUN builds the commit" "not pushed"
check "DRY_RUN pushed nothing" test "$(remote_ref cluster/kind)" = "$MAIN0"

: >"$STUB_LOG"
run env CLUSTER=kind scripts/scenario.sh apply good
expect_ok "scenario good is switched on" "pushed"
K1="$(remote_ref cluster/kind)"
git fetch -q origin
check "the scenario commit is a child of the old branch head" test "$(git rev-parse "${K1}^")" = "$MAIN0"
check "the scenario commit has one parent" test "$(git rev-list --parents -n 1 "$K1" | wc -w | tr -d ' ')" = 2
check "the scenario's file replaces apps/demo/web.yaml" \
  test "$(git show "${K1}:apps/demo/web.yaml")" = "$(git show "${MAIN0}:scenarios/good/apps/demo/web.yaml")"
check "everything else equals main" test -z "$(git diff --name-only "$MAIN0" "$K1" -- . ':!apps/demo/web.yaml')"
check "the commit records the scenario" sh -c "git log -1 --format=%B '$K1' | grep -q '^Scenario: good$'"
check "Flux is asked to fetch, on the same context" grep -q 'kubectl --context kind-test -n flux-system annotate --overwrite gitrepository fleet' "$STUB_LOG"

run env CLUSTER=kind scripts/scenario.sh apply good
expect_ok "switching on the same scenario again is a no-op" "nothing to push"
check "the no-op pushed nothing" test "$(remote_ref cluster/kind)" = "$K1"

run env CLUSTER=kind RECONCILE=0 scripts/scenario.sh apply other
expect_ok "another scenario replaces the first" "pushed"
K2="$(remote_ref cluster/kind)"
git fetch -q origin
check "only the second scenario differs from main" test "$(git diff --name-only "$MAIN0" "$K2")" = "apps/demo/worker.yaml"
check "the second commit is a child of the first" test "$(git rev-parse "${K2}^")" = "$K1"

run env CLUSTER=kind scripts/scenario.sh apply invalid
expect_ok "a scenario that declares render: fails is switched on" "pushed"
K3="$(remote_ref cluster/kind)"

run env CLUSTER=kind scripts/scenario.sh reset
expect_ok "reset pushes main's tree" "pushed"
K4="$(remote_ref cluster/kind)"
git fetch -q origin
check "the reset commit is a child of the scenario commit" test "$(git rev-parse "${K4}^")" = "$K3"
check "the reset commit holds main's tree" test "$(git rev-parse "${K4}^{tree}")" = "$(git rev-parse "${MAIN0}^{tree}")"
run env CLUSTER=kind scripts/scenario.sh reset
expect_ok "a second reset is a no-op" "nothing to push"
check "the second reset pushed nothing" test "$(remote_ref cluster/kind)" = "$K4"
check "cluster/kind only moved forward" git --git-dir "$REMOTE_DIR" merge-base --is-ancestor "$MAIN0" "$K4"

# --- the lab's branch, and an SSH remote URL against Flux's HTTPS URL --------------------------------------------------

run env CLUSTER=lab STUB_BRANCH=cluster/lab STUB_CONTEXT=lab-admin scripts/scenario.sh apply good
expect_ok "CLUSTER=lab writes cluster/lab" "pushed"
check "CLUSTER=lab left cluster/kind alone" test "$(remote_ref cluster/kind)" = "$K4"
check "CLUSTER=lab left main alone" test "$(remote_ref main)" = "$MAIN0"
run env CLUSTER=lab STUB_BRANCH=cluster/lab scripts/scenario.sh reset
expect_ok "reset on the lab" "pushed"
check "the lab is back on main's tree" test "$(git --git-dir "$REMOTE_DIR" rev-parse "cluster/lab^{tree}")" = "$(git rev-parse "${MAIN0}^{tree}")"

# --- SCENARIO_REF: a scenario that is not on main yet ------------------------------------------------------------------

git checkout -q -b wip
scenario wip-only
mkdir -p scenarios/wip-only/apps/demo
printf 'kind: Deployment\nmetadata:\n  name: web\n# broken by wip\n' >scenarios/wip-only/apps/demo/web.yaml
printf 'not on main\n' >apps/demo/web.yaml
git add -A
git commit -q -m wip
run env CLUSTER=kind scripts/scenario.sh apply wip-only
expect_fail "a scenario only on a local branch needs SCENARIO_REF" "no scenario wip-only on origin/main"
K4B="$(remote_ref cluster/kind)"
refused() { # refused <label> <env...>: apply wip-only is refused, nothing pushed, no kubectl call made
  local label="$1"
  shift
  : >"$STUB_LOG"
  run env CLUSTER=kind "$@" scripts/scenario.sh apply wip-only
  expect_fail "$label" "SCENARIO_REF is only for DRY_RUN=1"
  check "${label}: nothing pushed" test "$(remote_ref cluster/kind)" = "$K4B"
  check "${label}: refused before any kubectl call" test ! -s "$STUB_LOG"
}
refused "a push with SCENARIO_REF is refused" SCENARIO_REF=wip
refused "DRY_RUN=0 with SCENARIO_REF is refused" SCENARIO_REF=wip DRY_RUN=0
refused "DRY_RUN=true with SCENARIO_REF is refused" SCENARIO_REF=wip DRY_RUN=true
run env CLUSTER=kind SCENARIO_REF= scripts/scenario.sh apply wip-only
expect_fail "an empty SCENARIO_REF acts as unset" "no scenario wip-only on origin/main"
run env CLUSTER=kind SCENARIO_REF= scripts/scenario.sh apply good
expect_ok "an empty SCENARIO_REF still pushes from origin/main" "pushed"
K4C="$(remote_ref cluster/kind)"
check "the push moved cluster/kind" test "$K4C" != "$K4B"
run env CLUSTER=kind SCENARIO_REF=wip scripts/scenario.sh reset
expect_ok "reset works with SCENARIO_REF set" "pushed"
git fetch -q origin
check "reset with SCENARIO_REF still commits main's tree" test "$(git rev-parse "$(remote_ref cluster/kind)^{tree}")" = "$(git rev-parse "${MAIN0}^{tree}")"
K4B="$(remote_ref cluster/kind)"
run env SCENARIO_REF=wip scripts/scenario.sh list
expect_ok "list works with SCENARIO_REF" "wip-only"
run env CLUSTER=kind SCENARIO_REF=wip DRY_RUN=1 scripts/scenario.sh apply wip-only
expect_ok "DRY_RUN=1 with SCENARIO_REF reads the scenario from a local commit" "not pushed"
check "the dry run pushed nothing" test "$(remote_ref cluster/kind)" = "$K4B"
K5="$(printf '%s' "$OUT" | sed -n 's/.*DRY_RUN=1: built \([0-9a-f]*\) on.*/\1/p')"
check "the dry run reported its commit" test -n "$K5"
check "apps/ still comes from origin/main" test "$(git show "${K5}:apps/demo/worker.yaml")" = "$(git show "${MAIN0}:apps/demo/worker.yaml")"
check "only the scenario's file differs from main" test "$(git diff --name-only "$MAIN0" "$K5")" = "apps/demo/web.yaml"
git checkout -q main

# --- list and check ---------------------------------------------------------------------------------------------------

run scripts/scenario.sh list
expect_ok "list shows scenarios with their summary" "good +test scenario good"
check "list reads a quoted summary with ' #' whole" sh -c "printf '%s' \"\$1\" | grep -q 'quoted  *a value # with a hash$'" _ "$OUT"
check "list skips the schema folder" sh -c "! printf '%s' \"\$1\" | grep -q '^  schema'" _ "$OUT"

run scripts/scenario.sh check
expect_fail "check reports every broken fixture, not only the first" "scenarios/outside/infrastructure/x.yaml is outside apps/demo/"
check "check reports the later ones too" sh -c "printf '%s' \"\$1\" | grep -q 'new-dir/apps/demo/sub/extra.yaml'" _ "$OUT"
git rm -rq scenarios/outside scenarios/linked scenarios/extra-field scenarios/unmarked scenarios/misnamed scenarios/no-readme \
  scenarios/new-file scenarios/new-unlisted scenarios/new-dir scenarios/block-render scenarios/drops-base
git commit -q -m "drop the invalid fixtures"
run scripts/scenario.sh check
expect_ok "check passes on valid scenarios" "== scenarios/good"
run scripts/scenario.sh check --render
expect_fail "check --render finds render mismatches" "scenario says-fails: render passes"
git rm -rq scenarios/says-fails scenarios/undeclared
git commit -q -m "drop the render mismatches"
run scripts/scenario.sh check --render
expect_ok "check --render passes when every render matches its declaration"
# A cluster branch with a scenario on already holds that scenario's added file. Checked over its own tree, a scenario
# that does not list the file fails; over main's tree (CHECK_BASE) it passes.
git checkout -q -b oom-on
printf 'kind: Deployment\nmetadata:\n  name: load\n' >apps/demo/load.yaml
printf 'resources:\n  - web.yaml\n  - worker.yaml\n  - load.yaml\n' >apps/demo/kustomization.yaml
git add -A && git commit -q -m "scenario on"
run scripts/scenario.sh check --render
expect_fail "check over a tree with another scenario on fails" "does not list load.yaml, which apps/demo/kustomization.yaml on the base commit lists"
run env CHECK_BASE="$MAIN0" scripts/scenario.sh check --render
expect_ok "CHECK_BASE lays the scenarios over main's tree, not the scenario branch's" "== scenarios/new-listed"
run env CHECK_BASE=no-such-ref scripts/scenario.sh check
expect_fail "an unknown CHECK_BASE is an error" "CHECK_BASE no-such-ref is not a commit"
git checkout -q main
git branch -q -D oom-on
printf 'kind: Deployment\nshadewright-test: invalid\n' >apps/demo/web.yaml
run scripts/scenario.sh check --render
expect_ok "check renders the committed tree, not the working tree" "uncommitted changes under scenarios/ or apps/ are not checked"
git reset -q --hard "$MAIN0"

# --- the scripts never force-push and push in one place only ----------------------------------------------------------

pushes="$(grep -nE '(^|[^-])git[[:space:]]+push' "$SRC_ROOT"/scripts/*.sh | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true)"
check "one git push in scripts/" test "$(printf '%s\n' "$pushes" | grep -c .)" = 1
check "no force push" sh -c "! printf '%s' \"\$1\" | grep -qE -- '--force|-f[[:space:]]|[[:space:]]\"?\+'" _ "$pushes"
check "main ends where it started" test "$(remote_ref main)" = "$MAIN0"

finish
