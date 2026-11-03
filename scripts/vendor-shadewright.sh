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
# Environment (for tests): SHADEWRIGHT_REPO (default https://github.com/pkalin/shadewright), VENDOR_OUT (output
# directory, default infrastructure/shadewright). The kustomize version must be the one pinned in scripts/tools.env.
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

REPO_URL="${SHADEWRIGHT_REPO:-https://github.com/pkalin/shadewright}"
OUT="${VENDOR_OUT:-${REPO_ROOT}/infrastructure/shadewright}"
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

is_digest() { printf '%s' "$1" | grep -Eq '^sha256:[0-9a-f]{64}$'; }

printf '%s' "$commit" | grep -Eq '^[0-9a-f]{40}$' || die "the commit must be a full 40-character lower-case SHA, got: ${commit}"

if [ "$(vendor_value commit)" = "$commit" ]; then
  [ -n "$analyzer_digest" ] || analyzer_digest="$(vendor_value analyzer_digest)"
  [ -n "$executor_digest" ] || executor_digest="$(vendor_value executor_digest)"
fi
[ -n "$analyzer_digest" ] && [ -n "$executor_digest" ] ||
  die "give --analyzer-digest and --executor-digest (VENDOR does not name this commit); see the header of this script"
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

# Both images are built from the same placeholder ("controller:latest"), so they are set by Deployment name. The wrapper
# lives inside the fetched tree, so its relative path to config/default needs no load restrictor.
mkdir "$work/tree/config/fleet-vendor"
cat >"$work/tree/config/fleet-vendor/kustomization.yaml" <<YAML
resources:
  - ../default
patches:
  - target:
      kind: Deployment
      name: shadewright-analyzer
    patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/image
        value: ${IMAGE_REPO}-analyzer@${analyzer_digest}
  - target:
      kind: Deployment
      name: shadewright-executor
    patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/image
        value: ${IMAGE_REPO}-executor@${executor_digest}
YAML

"$KUSTOMIZE" build "$work/tree/config/fleet-vendor" >"$work/install.yaml" || die "kustomize build of config/default failed"
"$KUSTOMIZE" build "$work/tree/config/watch" >"$work/watch-demo.yaml" || die "kustomize build of config/watch failed"

# What must hold for the output to be installable: no moving or placeholder image, both digests in place.
if grep -E '^[[:space:]]*image:' "$work/install.yaml" | grep -vqE "@sha256:[0-9a-f]{64}\$"; then
  die "an image in the build output is not pinned by digest"
fi
grep -q "image: ${IMAGE_REPO}-analyzer@${analyzer_digest}\$" "$work/install.yaml" || die "the analyzer image was not set"
grep -q "image: ${IMAGE_REPO}-executor@${executor_digest}\$" "$work/install.yaml" || die "the executor image was not set"
grep -q 'namespace: demo$' "$work/watch-demo.yaml" || die "config/watch does not build a RoleBinding in demo"

mkdir -p "$OUT"
{
  echo "# Generated by scripts/vendor-shadewright.sh. Do not edit: run the script with another commit instead."
  echo "# Source: kustomize build of config/default (install.yaml) and config/watch (watch-demo.yaml) at this commit."
  echo "repository=${REPO_URL}"
  echo "commit=${commit}"
  echo "analyzer_digest=${analyzer_digest}"
  echo "executor_digest=${executor_digest}"
  echo "kustomize=${KUSTOMIZE_VERSION}"
} >"$work/VENDOR"

for f in install.yaml watch-demo.yaml VENDOR; do
  cp "$work/$f" "$OUT/$f"
done
log "vendored ${commit} into ${OUT}"
