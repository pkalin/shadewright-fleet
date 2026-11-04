#!/usr/bin/env bash
# Renders every kustomization that Flux applies (clusters/, infrastructure/, apps/) and validates the output against the Kubernetes and
# Flux schemas. CI runs this script (.github/workflows/render.yaml); run it locally before a pull request.
#
#   scripts/render.sh                  # uses kustomize and kubeconform from bin/ (make tools), then PATH
#   KUSTOMIZE=/path/to/kustomize scripts/render.sh
#
# Versions, the Kubernetes schema version and the CRD catalog commit are pinned in scripts/tools.env; the scenario
# harness (scripts/scenario.sh) renders with the same check (render_dir in scripts/lib.sh).
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

cd "$REPO_ROOT"
require_render_tools

# Only what Flux applies: scenarios/ holds deliberately broken manifests and is rendered by its own harness.
dirs=()
while IFS= read -r file; do
  [ -f "$file" ] || continue # tracked but deleted locally
  dirs+=("$(dirname "$file")")
done < <(git ls-files --cached --others --exclude-standard -- \
  ':(glob)clusters/**/kustomization.yaml' ':(glob)infrastructure/**/kustomization.yaml' ':(glob)apps/**/kustomization.yaml' \
  ':(glob)clusters/kustomization.yaml' ':(glob)infrastructure/kustomization.yaml' ':(glob)apps/kustomization.yaml' | sort -u)

if [ "${#dirs[@]}" -eq 0 ]; then
  echo "no kustomizations found" >&2
  exit 1
fi

status=0
for dir in "${dirs[@]}"; do
  echo "== ${dir}"
  render_dir "$dir" "$dir" || status=1
done

# Every Flux Kustomization in clusters/ must point at a directory of this repository that has a kustomization.
while IFS= read -r path; do
  rel="${path#./}"
  if [ ! -f "${rel}/kustomization.yaml" ]; then
    echo "::error::a Flux Kustomization in clusters/ points at ${path}, which has no kustomization.yaml"
    status=1
  fi
done < <(grep -rhE '^[[:space:]]+path:[[:space:]]' clusters/ | awk '{gsub(/["'"'"']/, "", $2); print $2}' | sort -u)
exit "$status"
