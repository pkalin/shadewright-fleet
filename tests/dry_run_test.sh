#!/usr/bin/env bash
# Offline tests of `scripts/kind.sh dry-run-config`: the pinned chart is fetched by digest and verified, its CRDs lose
# their Helm directives, and the lab configuration goes to a server-side dry run that fails the job when refused.
# curl serves a fake chart from a local directory, kubectl and kustomize are stubs, tar and python3 are real.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

# shellcheck source=scripts/lib.sh
. "$SRC_ROOT/scripts/lib.sh"

# A copy of the files the command reads, in its own Git repository, so the pinned digest can be the fake chart's.
R="$T/repo"
mkdir -p "$R/infrastructure"
cp -R "$SRC_ROOT/scripts" "$R/scripts"
cp -R "$SRC_ROOT/infrastructure/shadewright" "$SRC_ROOT/infrastructure/shadewright-lab-config" "$R/infrastructure/"
git -C "$R" init -q

# The fake chart: one CRD template with the directives of the real ones.
SERVE="$T/serve"
mkdir -p "$T/chart/shadewright/templates/crd" "$SERVE"
cat >"$T/chart/shadewright/templates/crd/things.example.io.yaml" <<'YAML'
{{- if .Values.crd.enabled }}
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  annotations:
    {{- if .Values.crd.keep }}
    "helm.sh/resource-policy": keep
    {{- end }}
  labels:
    {{- include "shadewright.labels" (dict "component" "" "context" $) | nindent 4 }}
  name: things.example.io
{{- end }}
YAML
tar -czf "$SERVE/layer" -C "$T/chart" shadewright
LAYER="sha256:$(sha256_of "$SERVE/layer")"
cat >"$SERVE/manifest" <<JSON
{"schemaVersion":2,"layers":[{"mediaType":"application/vnd.cncf.helm.chart.content.v1.tar+gzip","digest":"${LAYER}","size":1}]}
JSON
MANIFEST="sha256:$(sha256_of "$SERVE/manifest")"
sed -i.bak "s/sha256:[0-9a-f]\{64\}/${MANIFEST}/" "$R/infrastructure/shadewright/ocirepository.yaml"

cat >"$STUBS/curl" <<'EOF2'
#!/usr/bin/env bash
echo "curl $*" >>"$STUB_LOG"
out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in -o) out="$2"; shift ;; https://*) url="$1" ;; esac
  shift
done
case "$url" in
  https://ghcr.io/token*) printf '{"token":"t"}'; exit 0 ;;
  */manifests/*) src="$SERVE/${STUB_MANIFEST:-manifest}" ;;
  */blobs/*) src="$SERVE/${STUB_LAYER:-layer}" ;;
  *) exit 22 ;;
esac
cp "$src" "$out"
EOF2
# kubectl records its input; a dry run fails when STUB_REFUSE is set, as the API server does for a CEL rule.
cat >"$STUBS/kubectl" <<'EOF2'
#!/usr/bin/env bash
echo "kubectl $*" >>"$STUB_LOG"
case " $* " in
  *" --dry-run=server "*)
    cat "${@: -1}" >"$T_APPLIED"
    if [ -n "${STUB_REFUSE:-}" ]; then echo 'The RemediationSettings "default" is invalid: spec.analysis.models: refused' >&2; exit 1; fi ;;
  *" --server-side "*) for f in "${@: -1}"/*.yaml; do cat "$f"; done >"$T_CRDS" ;;
esac
exit 0
EOF2
cat >"$STUBS/kustomize" <<'EOF2'
#!/usr/bin/env bash
[ "$1" = build ] || exit 2
for f in "$2"/remediation*.yaml; do echo "---"; cat "$f"; done
EOF2
chmod +x "$STUBS/curl" "$STUBS/kubectl" "$STUBS/kustomize"
export SERVE T_APPLIED="$T/applied.yaml" T_CRDS="$T/crds.yaml"

KIND="$R/scripts/kind.sh"

run "$KIND" dry-run-config
expect_ok "a chart that matches its digests passes" "accepts infrastructure/shadewright-lab-config"
# shellcheck disable=SC2016 # expanded by the inner bash
check "the CRDs are applied before the dry run" bash -c 'grep -E "server-side|dry-run=server" "$STUB_LOG" | head -1 | grep -q server-side'
# shellcheck disable=SC2016
check "the CRD is plain YAML (directives dropped)" bash -c '! grep -q "{{" "$T_CRDS" && grep -q "name: things.example.io" "$T_CRDS"'
check "the rendered configuration is what the dry run receives" grep -q 'endpoint: "https://ais-example' "$T_APPLIED"
# shellcheck disable=SC2016
check "no placeholder reaches the API server" bash -c '! grep -q "\${" "$T_APPLIED"'

run env STUB_REFUSE=1 "$KIND" dry-run-config
expect_fail "a refusal by the API server fails the job" "the API server refused infrastructure/shadewright-lab-config"

printf '{"schemaVersion":2,"layers":[]}' >"$SERVE/tampered"
run env STUB_MANIFEST=tampered "$KIND" dry-run-config
expect_fail "a manifest that does not match the pinned digest is refused" "checksum mismatch for manifest.json"

printf 'tampered' >"$SERVE/badlayer"
run env STUB_LAYER=badlayer "$KIND" dry-run-config
expect_fail "a chart layer that does not match its digest is refused" "checksum mismatch for chart.tgz"

sed -i.bak 's/{{- end }}/{{ .Values.other }}/' "$T/chart/shadewright/templates/crd/things.example.io.yaml"
sed -i.bak 's/{{- if .Values.crd.enabled }}/name: {{ .Values.crd.name }}/' "$T/chart/shadewright/templates/crd/things.example.io.yaml"
tar -czf "$SERVE/layer" -C "$T/chart" shadewright
LAYER="sha256:$(sha256_of "$SERVE/layer")"
printf '{"schemaVersion":2,"layers":[{"mediaType":"application/vnd.cncf.helm.chart.content.v1.tar+gzip","digest":"%s","size":1}]}' "$LAYER" >"$SERVE/manifest"
sed -i.bak "s/sha256:[0-9a-f]\{64\}/sha256:$(sha256_of "$SERVE/manifest")/" "$R/infrastructure/shadewright/ocirepository.yaml"
run "$KIND" dry-run-config
expect_fail "a CRD that uses Helm templating beyond directive lines is refused" "uses Helm templating"

finish
