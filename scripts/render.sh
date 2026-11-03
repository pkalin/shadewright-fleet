#!/usr/bin/env bash
# Renders every kustomization that Flux applies (clusters/, infrastructure/, apps/) and validates the output against the Kubernetes and
# Flux schemas. CI runs this script (.github/workflows/render.yaml); run it locally before a pull request.
#
#   scripts/render.sh                  # uses kustomize and kubeconform from PATH
#   KUSTOMIZE=/path/to/kustomize scripts/render.sh
set -euo pipefail

KUSTOMIZE="${KUSTOMIZE:-kustomize}"
KUBECONFORM="${KUBECONFORM:-kubeconform}"

# CRD schemas (Flux and others) from the datree catalog, pinned to a commit so CI does not change under us.
CRDS_CATALOG_REF="27233a506de0085e71c7f9702597806a7f95eb24"
# Kubernetes schemas for the lab's AKS version (the Sweden Central default, 2026-11-03). Bump it with the cluster.
KUBERNETES_VERSION="1.36.0"
CACHE_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/kubeconform-cache"
mkdir -p "$CACHE_DIR"
CRD_SCHEMAS="https://raw.githubusercontent.com/datreeio/CRDs-catalog/${CRDS_CATALOG_REF}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"

cd "$(git rev-parse --show-toplevel)"

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
  if ! out="$("$KUSTOMIZE" build "$dir")"; then
    echo "::error::kustomize build ${dir} failed"
    status=1
    continue
  fi
  if ! printf '%s\n' "$out" | "$KUBECONFORM" -strict -summary -kubernetes-version "$KUBERNETES_VERSION" \
      -cache "$CACHE_DIR" -schema-location default -schema-location "$CRD_SCHEMAS"; then
    echo "::error::${dir} does not pass the schema check"
    status=1
  fi
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
