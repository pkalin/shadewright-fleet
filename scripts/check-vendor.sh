#!/usr/bin/env bash
# Staleness check for infrastructure/shadewright/: reruns scripts/vendor-shadewright.sh at the full commit recorded in
# its VENDOR file (fetched from the public operator repository, with the recorded digests) and fails on any difference
# from what is committed, so an edit by hand of the vendored RBAC, CRDs or Deployments cannot land. Needs network and the
# pinned kustomize (make tools). CI runs it (.github/workflows/harness.yaml); it is not part of make test, which is offline.
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

cd "$REPO_ROOT"
dir=infrastructure/shadewright
commit="$(sed -n 's/^commit=//p' "$dir/VENDOR" | head -n 1)"
printf '%s' "$commit" | grep -Eq '^[0-9a-f]{40}$' || die "$dir/VENDOR does not name a full commit"

"$REPO_ROOT/scripts/vendor-shadewright.sh" "$commit"
if ! git diff --exit-code -- "$dir"; then
  die "$dir differs from a fresh build at ${commit}: change it with scripts/vendor-shadewright.sh, never by hand"
fi
# A file the script now writes but git does not know yet.
[ -z "$(git ls-files --others --exclude-standard -- "$dir")" ] || die "$dir has untracked files"
log "$dir is current at ${commit}"
