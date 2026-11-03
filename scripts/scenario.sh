#!/usr/bin/env bash
# The scenario harness (ADR-0022). A scenario is one commit on the branch the cluster's Flux tracks, cluster/<CLUSTER>:
# main's tree with the scenario's files copied over apps/demo/. A reset is one commit of main's tree. Both are pushed
# as fast-forwards; nothing here ever writes main, force-pushes, or creates a branch.
#
#   scripts/scenario.sh list                       # scenarios on origin/main (or SCENARIO_REF)
#   CLUSTER=kind scripts/scenario.sh apply <name>  # make scenario-<name> CLUSTER=kind
#   CLUSTER=kind scripts/scenario.sh reset         # make scenario-reset CLUSTER=kind
#   scripts/scenario.sh check [--render]           # offline checks of the scenarios of HEAD, rendered on its apps/ (CI)
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

# top_value <file> <key>: the scalar of a top-level key of a block-style YAML mapping. This is not a YAML parser, so it
# reads only the forms it can read exactly and fails (status 3) on anything else, never guessing: every top-level line
# must be a plain `key:`, the key must appear at most once, and its value must be a plain scalar on one line (an
# optional ` #` comment after it) or a single- or double-quoted one without escapes. Block scalars, flow collections,
# anchors, aliases, tags and values continued on the next lines are refused. Prints nothing when the key is absent.
top_value() {
  awk -v key="$2" -v sq="'" '
    function fail() { bad = 1; exit }
    /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
    /^[[:space:]]/ { if (in_key) fail(); next }
    { in_key = 0 }
    /^(---|\.\.\.)[[:space:]]*$/ { next }
    !/^[A-Za-z][A-Za-z0-9_-]*:([[:space:]]|$)/ { fail() }
    index($0, key ":") != 1 { next }
    seen { fail() }
    {
      seen = 1
      in_key = 1
      v = substr($0, length(key) + 2)
      sub(/^[[:space:]]+/, "", v)
      c = substr(v, 1, 1)
      if (c == "\"" || c == sq) {
        rest = substr(v, 2)
        i = index(rest, c)
        if (i == 0) fail()
        out = substr(rest, 1, i - 1)
        if (c == "\"" && index(out, "\\") > 0) fail()
        # Anything after the closing quote but a comment (a doubled quote included) is refused.
        if (substr(rest, i + 1) !~ /^([[:space:]]+#.*)?[[:space:]]*$/) fail()
      } else {
        if (c == "#") v = ""
        if (c != "" && index("|>&*!{}[]%@`", c) > 0) fail()
        sub(/[[:space:]]+#.*$/, "", v)
        sub(/[[:space:]]+$/, "", v)
        out = v
      }
    }
    END {
      if (bad) exit 3
      if (seen) print out
    }' "$1"
}

# lists_resource <kustomization.yaml> <entry>: the file has a list item that is exactly <entry> (optionally quoted,
# optionally with a trailing comment). Conservative: an entry it cannot read counts as not listed.
lists_resource() {
  awk -v want="$2" -v sq="'" '
    /^[[:space:]]*-[[:space:]]+/ {
      v = $0
      sub(/^[[:space:]]*-[[:space:]]+/, "", v)
      sub(/[[:space:]]+#.*$/, "", v)
      sub(/[[:space:]]+$/, "", v)
      c = substr(v, 1, 1)
      if ((c == "\"" || c == sq) && length(v) >= 2 && substr(v, length(v), 1) == c) v = substr(v, 2, length(v) - 2)
      if (v == want) { found = 1; exit }
    }
    END { exit !found }' "$1"
}

# prepare_scenario <base> <source> <name>: checks scenarios/<name> of commit <source> and sets SCENARIO_TREE to the tree
# of commit <base> with the scenario's files over apps/demo/, and SCENARIO_RENDER to the render its expected.yaml
# declares. The one validator of the layout, for both check and apply:
#   - scenarios/<name> holds README.md, expected.yaml and otherwise only regular files under apps/demo/;
#   - each file under apps/demo/ replaces a file of <base>, or is new in an existing directory whose kustomization.yaml
#     the scenario also replaces and lists it in, so a scenario file can never be silently left out of the build;
#   - expected.yaml is valid against <source>'s scenarios/schema and names the folder.
prepare_scenario() {
  local base="$1" src="$2" name="$3" entry meta path mode_bits type sha rel dir out v
  local entries="$WORK/entries" index="$WORK/index" kfile="$WORK/kustomization.yaml" paths="$WORK/paths" exp="$WORK/src/scenarios/$3"
  valid_name "$name" || die "invalid scenario name '${name}': lower case letters, digits and hyphens; not schema, list, reset or check"

  # 1. The layout, from Git objects only: no symlink, submodule or other non-regular file.
  : >"$entries"
  while IFS= read -r -d '' entry; do
    meta="${entry%%$'\t'*}"
    path="${entry#*$'\t'}"
    read -r mode_bits type sha <<EOF
$meta
EOF
    rel="${path#scenarios/"${name}"/}"
    case "$rel" in
      *$'\n'*) die "scenarios/${name} holds a path with a line break" ;;
    esac
    if [ "$type" != blob ] || { [ "$mode_bits" != 100644 ] && [ "$mode_bits" != 100755 ]; }; then
      die "scenarios/${name}/${rel} is not a regular file"
    fi
    case "$rel" in
      README.md | expected.yaml) ;;
      apps/demo/?*) printf '%s %s\n' "$sha" "$rel" >>"$entries" ;;
      *) die "scenarios/${name}/${rel} is outside apps/demo/: a scenario replaces files under apps/demo/ only" ;;
    esac
  done < <(git ls-tree -r -z "$src" -- "scenarios/${name}/")
  git cat-file -e "${src}:scenarios/${name}/README.md" 2>/dev/null || die "scenarios/${name}/README.md is missing"
  git cat-file -e "${src}:scenarios/${name}/expected.yaml" 2>/dev/null || die "scenarios/${name}/expected.yaml is missing"

  # 2. expected.yaml against the schema.
  rm -rf "$WORK/src"
  mkdir -p "$WORK/src"
  git archive "$src" -- scenarios/schema "scenarios/${name}/expected.yaml" | tar -x -C "$WORK/src"
  if ! out="$("$KUBECONFORM" -strict -summary \
      -schema-location "$WORK/src/scenarios/schema/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
      "$exp/expected.yaml" 2>&1)"; then
    log "$out"
    die "scenarios/${name}/expected.yaml does not match scenarios/schema/scenario_v1alpha1.json"
  fi
  case "$out" in
    *"1 resource found in 1 file - Valid: 1, Invalid: 0, Errors: 0, Skipped: 0"*) ;;
    *) log "$out"; die "scenarios/${name}/expected.yaml must hold exactly one Scenario document" ;;
  esac
  v="$(top_value "$exp/expected.yaml" name)" ||
    die "scenarios/${name}/expected.yaml: write top-level keys as plain one-line scalars (no block scalars, anchors or escapes)"
  [ "$v" = "$name" ] || die "scenarios/${name}/expected.yaml: name must be ${name}"
  v="$(top_value "$exp/expected.yaml" render)" || die "scenarios/${name}/expected.yaml: cannot read render"
  SCENARIO_RENDER="${v:-passes}"

  # 3. The tree: <base> with the scenario's files over it.
  cut -d' ' -f2- "$entries" >"$paths"
  rm -f "$index"
  GIT_INDEX_FILE="$index" git read-tree "$base"
  while read -r sha rel; do
    if [ "$(git cat-file -t "${base}:${rel}" 2>/dev/null)" != blob ]; then
      dir="${rel%/*}"
      [ "$(git cat-file -t "${base}:${dir}" 2>/dev/null)" = tree ] ||
        die "scenarios/${name}/${rel}: ${dir}/ does not exist on the base commit; a scenario adds no directories"
      grep -Fqx "${dir}/kustomization.yaml" "$paths" ||
        die "scenarios/${name}/${rel} is new: the scenario must also replace ${dir}/kustomization.yaml and list it there"
      git show "${src}:scenarios/${name}/${dir}/kustomization.yaml" >"$kfile"
      lists_resource "$kfile" "${rel##*/}" ||
        die "scenarios/${name}/${rel} is new, but the scenario's ${dir}/kustomization.yaml does not list ${rel##*/}"
    fi
    GIT_INDEX_FILE="$index" git update-index --add --cacheinfo "100644,${sha},${rel}"
  done <"$entries"
  SCENARIO_TREE="$(GIT_INDEX_FILE="$index" git write-tree)"
}

# render_tree <tree> <label>: renders apps/ of a Git tree with the pinned tools; prints passes or fails (the render
# output goes to stderr).
render_tree() {
  rm -rf "$WORK/tree"
  mkdir -p "$WORK/tree"
  git archive "$1" -- apps | tar -x -C "$WORK/tree" || die "cannot extract apps/ of tree ${1}"
  if render_dir "$WORK/tree/apps" "$2" >&2; then echo passes; else echo fails; fi
}

require_cluster() {
  case "${CLUSTER:-}" in
    kind | lab) ;;
    '') die "set the cluster explicitly: CLUSTER=kind or CLUSTER=lab" ;;
    *) die "unknown cluster '${CLUSTER}': kind or lab" ;;
  esac
}

# check_branch <branch> <cluster>: the branch Flux tracks must be exactly cluster/<cluster> (ADR-0022, decision 2), and
# <cluster> is kind or lab (require_cluster). Anything else, main included, is refused before Git is touched.
check_branch() {
  [ -n "$1" ] || die "GitRepository ${FLUX_NAMESPACE}/${FLUX_SOURCE} tracks no branch (a commit or another ref, as in the CI baseline): refusing"
  [ "$1" = "cluster/${2}" ] || die "GitRepository ${FLUX_NAMESPACE}/${FLUX_SOURCE} tracks '${1}', not cluster/${2}: refusing"
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
    summary="$(top_value "$WORK/expected.yaml" summary)" || summary="(expected.yaml unreadable: make check-scenarios)"
    printf '  %-24s %s\n' "$n" "$summary"
    found=1
  done < <(git ls-tree -d --name-only "$src" -- scenarios/)
  [ "$found" -eq 1 ] || echo "  (none yet)"
}

# cmd_check [--render]: every scenario of the HEAD commit, checked and rendered on HEAD's own apps/, exactly as apply
# builds and renders it once HEAD is on main. Uncommitted changes are not checked.
cmd_check() {
  local do_render=0 names=() n got head rc status=0
  case "${1:-}" in
    --render) do_render=1 ;;
    '') ;;
    *) usage ;;
  esac
  if [ "$do_render" -eq 1 ]; then require_render_tools; else need "$KUBECONFORM"; fi
  head="$(git rev-parse --verify "HEAD^{commit}")"
  if [ -n "$(git status --porcelain -- scenarios apps)" ]; then
    log "warning: uncommitted changes under scenarios/ or apps/ are not checked; commit them first"
  fi
  while IFS= read -r n; do
    n="${n#scenarios/}"
    [ "$n" = schema ] && continue
    names+=("$n")
  done < <(git ls-tree -d --name-only "$head" -- scenarios/)
  if [ "${#names[@]}" -eq 0 ]; then
    echo "no scenarios to check"
    return 0
  fi
  echo "checking the scenarios of ${head}"
  for n in "${names[@]}"; do
    echo "== scenarios/${n}"
    # A subshell with its own errexit, so one invalid scenario does not hide the others.
    set +e
    (
      set -e
      prepare_scenario "$head" "$head" "$n"
      [ "$do_render" -eq 1 ] || exit 0
      got="$(render_tree "$SCENARIO_TREE" "apps/ with scenario ${n}")"
      if [ "$got" != "$SCENARIO_RENDER" ]; then
        echo "::error::scenario ${n}: render ${got}, but expected.yaml says render: ${SCENARIO_RENDER}"
        exit 1
      fi
    )
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || status=1
  done
  return "$status"
}

# cmd_switch <apply|reset> [name]
cmd_switch() {
  local mode="$1" name="${2:-}" cluster ctx spec branch other url remote_url rc main tip src tree expect rendered
  local subject commit
  require_cluster
  cluster="$CLUSTER"
  if [ "$mode" = apply ]; then
    [ -n "$name" ] || usage
    valid_name "$name" || die "invalid scenario name '${name}'"
  fi
  need git
  need kubectl
  require_render_tools

  # 1. The cluster: the branch its Flux tracks, from the GitRepository in the current context, in one read.
  ctx="$(kubectl config current-context 2>/dev/null)" || die "no current kube context"
  [ -n "$ctx" ] || die "no current kube context"
  spec="$(kubectl --context "$ctx" -n "$FLUX_NAMESPACE" get gitrepository "$FLUX_SOURCE" \
    -o 'jsonpath={.spec.ref.branch}{"\n"}{.spec.ref.tag}{.spec.ref.semver}{.spec.ref.name}{.spec.ref.commit}{"\n"}{.spec.url}')" ||
    die "cannot read GitRepository ${FLUX_NAMESPACE}/${FLUX_SOURCE} in context ${ctx}"
  { IFS= read -r branch || true; IFS= read -r other || true; IFS= read -r url || true; } <<EOF
$spec
EOF
  check_branch "$branch" "$cluster"
  [ -z "$other" ] || die "GitRepository ${FLUX_NAMESPACE}/${FLUX_SOURCE} pins a tag, semver, ref name or commit besides the branch: refusing"
  remote_url="$(git remote get-url "$REMOTE" 2>/dev/null)" || die "no Git remote ${REMOTE} (FLEET_REMOTE)"
  # Only normalized URLs are printed: a remote URL may carry credentials.
  [ "$(normalize_git_url "$url")" = "$(normalize_git_url "$remote_url")" ] ||
    die "the cluster syncs $(normalize_git_url "$url"), but remote ${REMOTE} is $(normalize_git_url "$remote_url"): refusing"
  log "context ${ctx}: Flux tracks ${branch} of $(normalize_git_url "$url")"

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
    prepare_scenario "$main" "$src" "$name"
    tree="$SCENARIO_TREE"
    expect="$SCENARIO_RENDER"
    subject="chore(scenarios): switch on ${name} on ${branch}"
  fi

  # 4. Render apps/ of exactly that tree with the pinned tools.
  rendered="$(render_tree "$tree" "apps/ of the ${mode} commit")"
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
