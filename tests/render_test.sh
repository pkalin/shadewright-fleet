#!/usr/bin/env bash
# Offline tests of render_dir (scripts/lib.sh) on the agent's lab configuration: the samples in render-sample.env are
# substituted before the schema check, and the Shadewright schemas in schemas/ are strict. kustomize is a stub that
# concatenates the directory's manifests; kubeconform is the real, pinned one, given only the local schemas.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

cat >"$STUBS/kustomize" <<'STUB'
#!/usr/bin/env bash
[ "$1" = build ] || exit 2
for f in "$2"/remediation*.yaml; do echo "---"; cat "$f"; done
STUB
# Keeps the rendered input for the checks below and validates it against the repository's schemas only (no network).
cat >"$STUBS/kubeconform" <<'STUB'
#!/usr/bin/env bash
tee "$T_RENDERED" | exec "$REAL_KUBECONFORM" -strict -summary -schema-location "$SRC_ROOT/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
STUB
chmod +x "$STUBS/kustomize" "$STUBS/kubeconform"
export T_RENDERED="$T/rendered.yaml" SRC_ROOT

# shellcheck source=scripts/lib.sh
. "$SRC_ROOT/scripts/lib.sh"
KUSTOMIZE=kustomize KUBECONFORM=kubeconform

cfg="$SRC_ROOT/infrastructure/shadewright-lab-config"

run render_dir "$cfg"
expect_ok "the lab configuration passes with its samples" "Valid: 2, Invalid: 0"
# shellcheck disable=SC2016 # expanded by the inner bash
check "every substitution is replaced by its sample" bash -c '! grep -q "\${" "$T_RENDERED"'
check "a number is substituted unquoted" grep -q 'installationID: 12345678$' "$T_RENDERED"

cp -R "$cfg" "$T/nosample" && rm "$T/nosample/render-sample.env"
run render_dir "$T/nosample"
expect_fail "without samples the placeholders fail the patterns" "does not pass the schema check"

cp -R "$cfg" "$T/typo" && sed -i.bak 's/maxAnalysesPerDay:/maxAnalysisPerDay:/' "$T/typo/remediationsettings.yaml"
run render_dir "$T/typo"
expect_fail "a misspelled field fails (strict schema)" "maxAnalysisPerDay"

cp -R "$cfg" "$T/range" && sed -i.bak 's/max: 128Mi/max: lots/' "$T/range/remediationpolicy-demo-memory.yaml"
run render_dir "$T/range"
expect_fail "a policy bound that is not a quantity fails" "does not pass the schema check"

# The parent Kustomization "lab" substitutes the forwarded values into clusters/lab/shadewright-config.yaml after
# kustomize has dropped their quotes, and Flux refuses a substitute value that YAML reads as anything but a string.
# Emulate that step with a numeric installation ID: every forwarded value must stay a string.
fwd=$(sed -E 's/^( +[A-Z_]+: )"(.*)"$/\1\2/; s/\$\{GITHUB_APP_INSTALLATION_ID\}/87654321/' "$SRC_ROOT/clusters/lab/shadewright-config.yaml")
check "a numeric installation ID is forwarded as a string" bash -c "! grep -qE '^ +GITHUB_APP_INSTALLATION_ID: [0-9]+\$' <<<\"\$1\"" _ "$fwd"
check "the forwarded installation ID is the number with the prefix id" grep -q 'GITHUB_APP_INSTALLATION_ID: id87654321$' <<<"$fwd"

finish
