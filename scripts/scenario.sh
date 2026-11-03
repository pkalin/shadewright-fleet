#!/usr/bin/env bash
# The scenario harness (ADR-0022). A scenario is one commit on the branch the cluster's Flux tracks, cluster/<CLUSTER>:
# main's tree with the scenario's files copied over apps/demo/. A reset is one commit of main's tree. Both are pushed
# as fast-forwards; nothing here ever writes main, force-pushes, or creates a branch.
#
#   scripts/scenario.sh list                       # scenarios on origin/main (or SCENARIO_REF)
#   CLUSTER=kind scripts/scenario.sh apply <name>  # make scenario-<name> CLUSTER=kind
#   CLUSTER=kind scripts/scenario.sh reset         # make scenario-reset CLUSTER=kind
#   scripts/scenario.sh check [--render]           # offline layout and expected.yaml checks of scenarios/ (CI)
#
# Environment:
#   CLUSTER       kind or lab. Required by apply and reset; must match the branch Flux tracks in the current context.
#   SCENARIO_REF  where the scenario's files are read from (default: origin/main). apps/ always comes from origin/main.
#   DRY_RUN=1     build, render and show the commit, but do not push.
#   RECONCILE=0   do not ask Flux to fetch at once after the push (it polls anyway).
#   FLEET_REMOTE  the Git remote of this repository (default: origin).
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"

REMOTE="${FLEET_REMOTE:-origin}"
FLUX_NAMESPACE="flux-system"
FLUX_SOURCE="fleet"
NAME_RE='^[a-z0-9]([a-z0-9-]{0,48}[a-z0-9])?$'
BRANCH_RE='^cluster/[a-z0-9]([a-z0-9-]*[a-z0-9])?$'

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}

valid_name() {
  case "$1" in
    schema | list | reset | check) return 1 ;;
  esac
  [[ "$1" =~ $NAME_RE ]]
}

# top_value <file> <key>: the plain scalar of a top-level key, without quotes or a trailing comment. Read only after
# the file passed the schema check; any other layout gives an empty value, which callers treat as a mismatch.
top_value() {
  awk -v key="$2" '
    index($0, key ":") == 1 {
      v = substr($0, length(key) + 2)
      sub(/[[:space:]]+#.*$/, "", v)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^["'"'"']|["'"'"']$/, "", v)
      print v
      exit
    }' "$1"
}

# validate_scenario <root> <name>: <root>/scenarios/<name> holds README.md, expected.yaml (valid against the schema in
# <root>/scenarios/schema, with the folder's name) and otherwise only regular files under apps/demo/.
validate_scenario() {
  local root="$1" name="$2" dir="$1/scenarios/$2" f rel out
  valid_name "$name" || die "invalid scenario name '${name}': lower case letters, digits and hyphens; not schema, list, reset or check"
  [ -d "$dir" ] || die "no scenario ${name}"
  [ -f "$dir/README.md" ] || die "scenarios/${name}/README.md is missing"
  [ -f "$dir/expected.yaml" ] || die "scenarios/${name}/expected.yaml is missing"
  while IFS= read -r f; do
    rel="${f#"$dir"/}"
    if [ -L "$f" ] || [ ! -f "$f" ]; then
      die "scenarios/${name}/${rel} is not a regular file"
    fi
    case "$rel" in
      README.md | expected.yaml | apps/demo/?*) ;;
      *) die "scenarios/${name}/${rel} is outside apps/demo/: a scenario replaces files under apps/demo/ only" ;;
    esac
  done < <(find "$dir" ! -type d)

  if ! out="$("$KUBECONFORM" -strict -summary \
      -schema-location "$root/scenarios/schema/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
      "$dir/expected.yaml" 2>&1)"; then
    log "$out"
    die "scenarios/${name}/expected.yaml does not match scenarios/schema/scenario_v1alpha1.json"
  fi
  case "$out" in
    *"1 resource found in 1 file - Valid: 1, Invalid: 0, Errors: 0, Skipped: 0"*) ;;
    *) log "$out"; die "scenarios/${name}/expected.yaml must hold exactly one Scenario document" ;;
  esac
  [ "$(top_value "$dir/expected.yaml" name)" = "$name" ] || die "scenarios/${name}/expected.yaml: name must be ${name}"
}

# expected_render <expected.yaml>: passes (the default) or fails.
expected_render() {
  local v
  v="$(top_value "$1" render)"
  printf '%s\n' "${v:-passes}"
}

# render_apps <apps dir> <label>: prints passes or fails; the render output goes to stderr.
render_apps() {
  if render_dir "$1" "$2" >&2; then echo passes; else echo fails; fi
}

require_cluster() {
  case "${CLUSTER:-}" in
    kind | lab) ;;
    '') die "set the cluster explicitly: CLUSTER=kind or CLUSTER=lab" ;;
    *) die "unknown cluster '${CLUSTER}': kind or lab" ;;
  esac
}

# check_branch <branch> <cluster>: the branch Flux tracks must be exactly cluster/<cluster>, a valid branch name and
# under cluster/ (ADR-0022, decision 2). Anything else, main included, is refused before Git is touched.
check_branch() {
  local branch="$1" cluster="$2"
  [ -n "$branch" ] || die "GitRepository ${FLUX_NAMESPACE}/${FLUX_SOURCE} tracks no branch (a commit or another ref, as in the CI baseline): refusing"
  [ "$branch" = "cluster/${cluster}" ] || die "GitRepository ${FLUX_NAMESPACE}/${FLUX_SOURCE} tracks '${branch}', not cluster/${cluster}: refusing"
  git check-ref-format --branch "$branch" >/dev/null 2>&1 || die "'${branch}' is not a valid branch name: refusing"
  case "$branch" in
    cluster/?*) ;;
    *) die "'${branch}' is not under cluster/: refusing" ;;
  esac
  [[ "$branch" =~ $BRANCH_RE ]] || die "'${branch}' is not a cluster branch name: refusing"
}

# push_cluster_branch <commit> <branch> <cluster>: the only push in this repository's scripts. A plain push of a
# commit whose parent is the fetched head: Git refuses anything but a fast-forward, and the ruleset on cluster/*
# refuses non-fast-forwards for everyone.
push_cluster_branch() {
  check_branch "$2" "$3"
  git push --quiet "$REMOTE" "${1}:refs/heads/${2}"
}

cmd_list() {
  local src ref n summary found=0
  git fetch --quiet --no-tags "$REMOTE" "+refs/heads/main:refs/remotes/${REMOTE}/main" 2>/dev/null ||
    log "warning: could not fetch ${REMOTE}/main, listing the last fetched state"
  ref="${SCENARIO_REF:-refs/remotes/${REMOTE}/main}"
  src="$(git rev-parse --verify --quiet "${ref}^{commit}")" || die "${ref} is not a commit"
  echo "Scenarios on ${ref} (make scenario-<name> CLUSTER=kind|lab, make scenario-reset CLUSTER=kind|lab):"
  while IFS= read -r n; do
    n="${n#scenarios/}"
    valid_name "$n" || continue
    git cat-file -e "${src}:scenarios/${n}/expected.yaml" 2>/dev/null || continue
    git show "${src}:scenarios/${n}/expected.yaml" >"$WORK/expected.yaml"
    summary="$(top_value "$WORK/expected.yaml" summary)"
    printf '  %-24s %s\n' "$n" "$summary"
    found=1
  done < <(git ls-tree -d --name-only "$src" -- scenarios/)
  [ "$found" -eq 1 ] || echo "  (none yet)"
}

cmd_check() {
  local do_render=0 names=() d n expect got status=0
  case "${1:-}" in
    --render) do_render=1 ;;
    '') ;;
    *) usage ;;
  esac
  if [ "$do_render" -eq 1 ]; then require_render_tools; else need "$KUBECONFORM"; fi
  for d in scenarios/*/; do
    [ -d "$d" ] || continue
    n="$(basename "$d")"
    [ "$n" = schema ] && continue
    names+=("$n")
  done
  if [ "${#names[@]}" -eq 0 ]; then
    echo "no scenarios to check"
    return 0
  fi
  for n in "${names[@]}"; do
    echo "== scenarios/${n}"
    # A subshell, so one invalid scenario does not hide the others.
    if ! (validate_scenario "$REPO_ROOT" "$n"); then
      status=1
      continue
    fi
    [ "$do_render" -eq 1 ] || continue
    rm -rf "$WORK/check"
    mkdir -p "$WORK/check"
    cp -R apps "$WORK/check/apps"
    if [ -d "scenarios/${n}/apps/demo" ]; then
      cp -R "scenarios/${n}/apps/demo/." "$WORK/check/apps/demo/"
    fi
    expect="$(expected_render "scenarios/${n}/expected.yaml")"
    got="$(render_apps "$WORK/check/apps" "apps/ with scenario ${n}")"
    if [ "$got" != "$expect" ]; then
      echo "::error::scenario ${n}: render ${got}, but expected.yaml says render: ${expect}"
      status=1
    fi
  done
  return "$status"
}

# cmd_switch <apply|reset> [name]
cmd_switch() {
  local mode="$1" name="${2:-}" cluster ctx branch other url remote_url rc main tip src tree index entry meta path
  local mode_bits type sha rel expect rendered subject commit
  require_cluster
  cluster="$CLUSTER"
  if [ "$mode" = apply ]; then
    [ -n "$name" ] || usage
    valid_name "$name" || die "invalid scenario name '${name}'"
  fi
  need git
  need kubectl
  require_render_tools

  # 1. The cluster: the branch its Flux tracks, from the GitRepository in the current context.
  ctx="$(kubectl config current-context 2>/dev/null)" || die "no current kube context"
  [ -n "$ctx" ] || die "no current kube context"
  if ! branch="$(kubectl --context "$ctx" -n "$FLUX_NAMESPACE" get gitrepository "$FLUX_SOURCE" -o 'jsonpath={.spec.ref.branch}')"; then
    die "cannot read GitRepository ${FLUX_NAMESPACE}/${FLUX_SOURCE} in context ${ctx}"
  fi
  other="$(kubectl --context "$ctx" -n "$FLUX_NAMESPACE" get gitrepository "$FLUX_SOURCE" \
    -o 'jsonpath={.spec.ref.tag}{.spec.ref.semver}{.spec.ref.name}{.spec.ref.commit}')" || die "cannot read GitRepository ${FLUX_NAMESPACE}/${FLUX_SOURCE}"
  url="$(kubectl --context "$ctx" -n "$FLUX_NAMESPACE" get gitrepository "$FLUX_SOURCE" -o 'jsonpath={.spec.url}')" ||
    die "cannot read GitRepository ${FLUX_NAMESPACE}/${FLUX_SOURCE}"
  check_branch "$branch" "$cluster"
  [ -z "$other" ] || die "GitRepository ${FLUX_NAMESPACE}/${FLUX_SOURCE} pins a tag, semver, ref name or commit besides the branch: refusing"
  remote_url="$(git remote get-url "$REMOTE" 2>/dev/null)" || die "no Git remote ${REMOTE} (FLEET_REMOTE)"
  [ "$(normalize_git_url "$url")" = "$(normalize_git_url "$remote_url")" ] ||
    die "the cluster syncs ${url}, but remote ${REMOTE} is ${remote_url}: refusing"
  log "context ${ctx}: Flux tracks ${branch} of ${url}"

  # 2. The branch must already exist; creating cluster branches is the maintainer's decision.
  rc=0
  git ls-remote --exit-code --heads "$REMOTE" "refs/heads/${branch}" >/dev/null || rc=$?
  case "$rc" in
    0) ;;
    2) die "${branch} does not exist on ${REMOTE}; the maintainer creates it (from main) with its rulesets (ADR-0022)" ;;
    *) die "cannot reach ${REMOTE}" ;;
  esac
  git fetch --quiet --no-tags "$REMOTE" "+refs/heads/main:refs/remotes/${REMOTE}/main" \
    "+refs/heads/${branch}:refs/remotes/${REMOTE}/${branch}"
  main="$(git rev-parse --verify "refs/remotes/${REMOTE}/main^{commit}")"
  tip="$(git rev-parse --verify "refs/remotes/${REMOTE}/${branch}^{commit}")"

  # 3. The tree: main's, with the scenario's files over apps/demo/.
  if [ "$mode" = reset ]; then
    tree="$(git rev-parse --verify "${main}^{tree}")"
    expect=passes
    subject="chore(scenarios): reset ${branch} to main"
  else
    src="$(git rev-parse --verify --quiet "${SCENARIO_REF:-refs/remotes/${REMOTE}/main}^{commit}")" ||
      die "SCENARIO_REF ${SCENARIO_REF:-} is not a commit"
    git cat-file -e "${src}:scenarios/${name}/expected.yaml" 2>/dev/null ||
      die "no scenario ${name} on ${SCENARIO_REF:-${REMOTE}/main} (make scenario-list)"
    mkdir -p "$WORK/src"
    git archive "$src" -- scenarios/schema "scenarios/${name}" | tar -x -C "$WORK/src"
    validate_scenario "$WORK/src" "$name"
    expect="$(expected_render "$WORK/src/scenarios/${name}/expected.yaml")"

    index="$WORK/index"
    GIT_INDEX_FILE="$index" git read-tree "$main"
    while IFS= read -r -d '' entry; do
      meta="${entry%%$'\t'*}"
      path="${entry#*$'\t'}"
      read -r mode_bits type sha <<EOF
$meta
EOF
      rel="${path#scenarios/"${name}"/}"
      case "$rel" in
        README.md | expected.yaml) continue ;;
        apps/demo/?*) ;;
        *) die "scenarios/${name}/${rel} is outside apps/demo/" ;;
      esac
      if [ "$type" != blob ] || { [ "$mode_bits" != 100644 ] && [ "$mode_bits" != 100755 ]; }; then
        die "scenarios/${name}/${rel} is not a regular file"
      fi
      GIT_INDEX_FILE="$index" git update-index --add --cacheinfo "100644,${sha},${rel}"
    done < <(git ls-tree -r -z "$src" -- "scenarios/${name}/")
    tree="$(GIT_INDEX_FILE="$index" git write-tree)"
    subject="chore(scenarios): switch on ${name} on ${branch}"
  fi

  # 4. Render apps/ of exactly that tree with the pinned tools.
  mkdir -p "$WORK/tree"
  git archive "$tree" -- apps | tar -x -C "$WORK/tree"
  rendered="$(render_apps "$WORK/tree/apps" "apps/ of the ${mode} commit")"
  if [ "$rendered" != "$expect" ]; then
    if [ "$mode" = reset ]; then
      die "apps/ on main does not render: refusing to reset"
    fi
    die "apps/ with scenario ${name}: render ${rendered}, but its expected.yaml says render: ${expect}"
  fi

  # 5. Nothing to do when the branch already holds that tree (a reset is idempotent).
  if [ "$tree" = "$(git rev-parse --verify "${tip}^{tree}")" ]; then
    log "${branch} already holds this tree; nothing to push"
    return 0
  fi

  {
    printf '%s\n\n' "$subject"
    printf 'Commit made by scripts/scenario.sh (ADR-0022) on top of %s.\n\n' "$tip"
    printf 'Cluster: %s\nMain: %s\n' "$cluster" "$main"
    if [ "$mode" = apply ]; then printf 'Scenario: %s\nScenario-Source: %s\n' "$name" "$src"; fi
    printf 'Render: %s\n' "$rendered"
  } >"$WORK/message"
  commit="$(git commit-tree "$tree" -p "$tip" -F "$WORK/message")"
  git --no-pager diff --stat "$tip" "$commit" >&2

  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "DRY_RUN=1: built ${commit} on ${branch}, not pushed"
    return 0
  fi
  push_cluster_branch "$commit" "$branch" "$cluster"
  log "pushed ${commit} to ${branch}"

  if [ "${RECONCILE:-1}" != 0 ]; then
    # The same annotation `flux reconcile source git` sets; Flux would otherwise fetch at its next poll.
    kubectl --context "$ctx" -n "$FLUX_NAMESPACE" annotate --overwrite gitrepository "$FLUX_SOURCE" \
      "reconcile.fluxcd.io/requestedAt=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null ||
      log "warning: could not ask Flux to fetch now; it fetches at its next poll"
  fi
}

case "${1:-}" in
  list) cmd_list ;;
  check) shift; cmd_check "$@" ;;
  apply) [ "$#" -eq 2 ] || usage; cmd_switch apply "$2" ;;
  reset) [ "$#" -eq 1 ] || usage; cmd_switch reset ;;
  *) usage ;;
esac
