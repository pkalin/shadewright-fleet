#!/usr/bin/env bash
# Regenerates infrastructure/shadewright/ (the vendored Shadewright install) from a commit of the operator repository.
#
#   scripts/vendor-shadewright.sh <commit> [--analyzer-digest sha256:<hex>] [--executor-digest sha256:<hex>]
#
# <commit> is a full 40-character SHA. The script fetches that commit, runs `kustomize build` on config/default (the
# operator, its CRDs, RBAC and NetworkPolicies) and on config/watch (the RoleBinding for the namespace demo), and
# sets the two images to ghcr.io/pkalin/shadewright-{analyzer,executor}@sha256:<digest>. A tag is refused: only a
# digest is accepted, so what runs on the lab is exactly what was reviewed. The commit and the digests are recorded in
# infrastructure/shadewright/VENDOR. Without the digest options the script reuses the ones in VENDOR, but only when
# VENDOR names the same commit, so `scripts/vendor-shadewright.sh <commit> && git diff --exit-code` checks the tree.
#
# Digests of the images built from a commit (the tag is sha-<first 7 characters of the commit>; use the digest of the
# version that carries that tag, which is the multi-architecture index):
#   gh api /user/packages/container/shadewright-analyzer/versions \
#     --jq '.[] | select(.metadata.container.tags | index("sha-1234567")) | .name'
#
# The source is always the public repository below, and VENDOR records only that URL. Tests may point SHADEWRIGHT_REPO
# at a fixture, but only together with VENDOR_OUT (a directory outside the repository's tree): the script refuses a
# different repository when it would write infrastructure/shadewright. The kustomize version must be the one pinned in
# scripts/tools.env. CI reruns this script at the commit in VENDOR and fails on any diff (make check-vendor).
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

PUBLIC_REPO="https://github.com/pkalin/shadewright"
REPO_URL="${SHADEWRIGHT_REPO:-$PUBLIC_REPO}"
OUT="${VENDOR_OUT:-${REPO_ROOT}/infrastructure/shadewright}"
if [ "$REPO_URL" != "$PUBLIC_REPO" ] && [ -z "${VENDOR_OUT:-}" ]; then
  die "SHADEWRIGHT_REPO other than ${PUBLIC_REPO} needs VENDOR_OUT: the committed install is built from the public repository only"
fi
IMAGE_REPO="ghcr.io/pkalin/shadewright"

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}

commit=""
analyzer_digest=""
executor_digest=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --analyzer-digest) [ "$#" -ge 2 ] || usage; analyzer_digest="$2"; shift 2 ;;
    --executor-digest) [ "$#" -ge 2 ] || usage; executor_digest="$2"; shift 2 ;;
    -h | --help) usage ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "$commit" ] || die "only one commit is accepted"; commit="$1"; shift ;;
  esac
done
[ -n "$commit" ] || usage

# vendor_value <key>: the value of key in VENDOR, empty if there is no such line.
vendor_value() {
  [ -f "$OUT/VENDOR" ] || return 0
  sed -n "s/^$1=//p" "$OUT/VENDOR" | head -n 1
}

# containers_of <file>: one line per container of every Deployment in a kustomize build, "<deployment> <containers|
# initContainers> <container> <image>". Relies on the layout kustomize prints (sorted keys, pod spec at 6 spaces).
containers_of() {
  awk '
    function flush() { if (inside && cname != "") print dep, section, cname, image; cname = ""; image = ""; inside = 0 }
    /^---/ { flush(); dep = ""; kind = ""; section = ""; next }
    /^kind: / { kind = $2; next }
    /^  name: / && dep == "" && kind == "Deployment" { dep = $2; next }
    kind != "Deployment" { next }
    /^      (initContainers|containers):/ { flush(); section = $1; sub(/:$/, "", section); next }
    /^      [A-Za-z]/ { flush(); section = ""; next }
    section == "" { next }
    /^      - / { flush(); inside = 1; line = substr($0, 9) }
    /^        [A-Za-z]/ { line = substr($0, 9) }
    inside && /^      - |^        [A-Za-z]/ {
      if (line ~ /^name: /) cname = substr(line, 7)
      if (line ~ /^image: /) image = substr(line, 8)
    }
    END { flush() }
  ' "$1"
}

is_digest() { printf '%s' "$1" | grep -Eq '^sha256:[0-9a-f]{64}$'; }

printf '%s' "$commit" | grep -Eq '^[0-9a-f]{40}$' || die "the commit must be a full 40-character lower-case SHA, got: ${commit}"

if [ "$(vendor_value commit)" = "$commit" ] && [ "$(vendor_value repository)" = "$PUBLIC_REPO" ]; then
  [ -n "$analyzer_digest" ] || analyzer_digest="$(vendor_value analyzer_digest)"
  [ -n "$executor_digest" ] || executor_digest="$(vendor_value executor_digest)"
fi
[ -n "$analyzer_digest" ] && [ -n "$executor_digest" ] ||
  die "give --analyzer-digest and --executor-digest (VENDOR does not name this commit of the public repository); see the header of this script"
is_digest "$analyzer_digest" || die "the analyzer image must be a sha256 digest, not a tag: ${analyzer_digest}"
is_digest "$executor_digest" || die "the executor image must be a sha256 digest, not a tag: ${executor_digest}"

need git
need tar
need "$KUSTOMIZE"
out="$("$KUSTOMIZE" version 2>/dev/null | tr '\n' ' ')" || true
require_version kustomize "$KUSTOMIZE_VERSION" "$out"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git init -q "$work/src"
git -C "$work/src" fetch -q --depth 1 "$REPO_URL" "$commit" || die "cannot fetch ${commit} from ${REPO_URL}"
[ "$(git -C "$work/src" rev-parse FETCH_HEAD)" = "$commit" ] || die "fetched a different commit than ${commit}"
mkdir "$work/tree"
git -C "$work/src" archive --format=tar FETCH_HEAD | tar -x -C "$work/tree"
[ -f "$work/tree/config/default/kustomization.yaml" ] || die "config/default is missing at ${commit}"
[ -f "$work/tree/config/watch/kustomization.yaml" ] || die "config/watch is missing at ${commit}"

# The images are set by container name (a strategic merge patch), not by position. A container that is missing would be
# added by the patch, so the build without the patch must already have it.
build_base() { "$KUSTOMIZE" build "$work/tree/config/default"; }
build_base >"$work/base.yaml" || die "kustomize build of config/default failed"
containers_of "$work/base.yaml" >"$work/base.containers"
grep -q '^shadewright-analyzer containers analyzer ' "$work/base.containers" ||
  die "config/default has no container analyzer in the Deployment shadewright-analyzer at ${commit}"
grep -q '^shadewright-executor containers executor ' "$work/base.containers" ||
  die "config/default has no container executor in the Deployment shadewright-executor at ${commit}"

mkdir "$work/tree/config/fleet-vendor"
cat >"$work/tree/config/fleet-vendor/kustomization.yaml" <<YAML
resources:
  - ../default
patches:
  - target:
      kind: Deployment
      name: shadewright-analyzer
    patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: shadewright-analyzer
      spec:
        template:
          spec:
            containers:
              - name: analyzer
                image: ${IMAGE_REPO}-analyzer@${analyzer_digest}
  - target:
      kind: Deployment
      name: shadewright-executor
    patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: shadewright-executor
      spec:
        template:
          spec:
            containers:
              - name: executor
                image: ${IMAGE_REPO}-executor@${executor_digest}
YAML

"$KUSTOMIZE" build "$work/tree/config/fleet-vendor" >"$work/install.yaml" || die "kustomize build of config/default failed"
"$KUSTOMIZE" build "$work/tree/config/watch" >"$work/watch-demo.yaml" || die "kustomize build of config/watch failed"

containers_of "$work/install.yaml" >"$work/containers"
[ "$(wc -l <"$work/containers")" -eq "$(wc -l <"$work/base.containers")" ] || die "the patch changed the number of containers"

# What must hold for the output to be installable: every container and init container of every Deployment, and any
# other "image:" line, is pinned by digest, and the two images are the ones asked for.
if grep -Eq '^[[:space:]]*(- )?image:' "$work/install.yaml" &&
  grep -E '^[[:space:]]*(- )?image:' "$work/install.yaml" | grep -vqE "@sha256:[0-9a-f]{64}\$"; then
  die "an image in the build output is not pinned by digest"
fi
grep -qx "shadewright-analyzer containers analyzer ${IMAGE_REPO}-analyzer@${analyzer_digest}" "$work/containers" || die "the analyzer image was not set"
grep -qx "shadewright-executor containers executor ${IMAGE_REPO}-executor@${executor_digest}" "$work/containers" || die "the executor image was not set"
grep -q 'namespace: demo$' "$work/watch-demo.yaml" || die "config/watch does not build a RoleBinding in demo"

mkdir -p "$OUT"
{
  echo "# Generated by scripts/vendor-shadewright.sh. Do not edit: run the script with another commit instead."
  echo "# Source: kustomize build of config/default (install.yaml) and config/watch (watch-demo.yaml) at this commit."
  echo "repository=${PUBLIC_REPO}"
  echo "commit=${commit}"
  echo "analyzer_digest=${analyzer_digest}"
  echo "executor_digest=${executor_digest}"
  echo "kustomize=${KUSTOMIZE_VERSION}"
} >"$work/VENDOR"

for f in install.yaml watch-demo.yaml VENDOR; do
  cp "$work/$f" "$OUT/$f"
done
log "vendored ${commit} into ${OUT}"
