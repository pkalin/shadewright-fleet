#!/usr/bin/env bash
# Renders every kustomization in the repository and validates the output against the Kubernetes and
# Flux schemas. CI runs this script (.github/workflows/render.yaml); run it locally before a pull request.
#
#   scripts/render.sh                  # uses kustomize and kubeconform from PATH
#   KUSTOMIZE=/path/to/kustomize scripts/render.sh
set -euo pipefail

KUSTOMIZE="${KUSTOMIZE:-kustomize}"
KUBECONFORM="${KUBECONFORM:-kubeconform}"

# CRD schemas (Flux and others) from the datree catalog, pinned to a commit so CI does not change under us.
CRDS_CATALOG_REF="27233a506de0085e71c7f9702597806a7f95eb24"
CRD_SCHEMAS="https://raw.githubusercontent.com/datreeio/CRDs-catalog/${CRDS_CATALOG_REF}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"

cd "$(git rev-parse --show-toplevel)"

dirs=()
while IFS= read -r file; do
  dirs+=("$(dirname "$file")")
done < <(git ls-files --cached --others --exclude-standard -- '*kustomization.yaml' '*kustomization.yml' '*Kustomization' | sort)

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
  if ! printf '%s\n' "$out" | "$KUBECONFORM" -strict -summary \
      -schema-location default -schema-location "$CRD_SCHEMAS"; then
    echo "::error::${dir} does not pass the schema check"
    status=1
  fi
done
exit "$status"
