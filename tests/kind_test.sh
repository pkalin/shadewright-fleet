#!/usr/bin/env bash
# Offline tests of scripts/kind.sh: input validation, the bootstrap objects, and that up, wait and down act on the
# named Kind cluster only. kind, kubectl and docker are stubs.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

cat >"$STUBS/kind" <<'EOF'
#!/usr/bin/env bash
echo "kind $*" >>"$STUB_LOG"
case "$1" in
  version) echo "kind ${STUB_KIND_VERSION:-v0.33.0} go1.25 linux/amd64" ;;
  get) printf '%s\n' ${STUB_KIND_CLUSTERS:-} ;;
  create | delete) ;;
  *) exit 1 ;;
esac
EOF
cat >"$STUBS/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$STUB_LOG"
case " $* " in
  *"{.status.artifact.revision}"*) printf '%s' "${STUB_REVISION:-}" ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$STUBS/docker"
chmod +x "$STUBS/kind" "$STUBS/kubectl" "$STUBS/docker"

KIND="$SRC_ROOT/scripts/kind.sh"
SHA=0123456789abcdef0123456789abcdef01234567

# --- bootstrap objects ------------------------------------------------------------------------------------------------

run "$KIND" bootstrap
expect_ok "the default bootstrap tracks cluster/kind" "branch: cluster/kind"
check "it reads the public fleet repository" sh -c "printf '%s' \"\$1\" | grep -q 'url: https://github.com/pkalin/shadewright-fleet$'" _ "$OUT"
check "its Kustomization applies ./clusters/kind" sh -c "printf '%s' \"\$1\" | grep -q 'path: ./clusters/kind$'" _ "$OUT"
check "no postBuild substitutions on Kind" sh -c "! printf '%s' \"\$1\" | grep -q postBuild" _ "$OUT"
check "the source is flux-system/fleet" sh -c "printf '%s' \"\$1\" | grep -A2 '^kind: GitRepository' | grep -q 'name: fleet'" _ "$OUT"

run env FLEET_REF_NAME=refs/pull/12/head "$KIND" bootstrap
expect_ok "CI on a pull request tracks its ref" "name: refs/pull/12/head"
check "a ref, not a branch, so the harness refuses there" sh -c "! printf '%s' \"\$1\" | grep -q 'branch:'" _ "$OUT"

run env FLEET_BRANCH=main FLEET_COMMIT="$SHA" "$KIND" bootstrap
expect_ok "CI on main pins the commit" "commit: ${SHA}"

for bad in "FLEET_URL=http://github.com/a/b" "FLEET_URL=git@github.com:a/b.git" "FLEET_URL=https://example.com/a/b" \
  "FLEET_URL=https://github.com/a/b/../c" "FLEET_BRANCH=a..b" "FLEET_COMMIT=abc" "FLEET_REF_NAME=main" \
  "FLEET_REF_NAME=refs/pull/1/head FLEET_COMMIT=${SHA}" "KIND_CLUSTER_NAME=a_b" "WAIT_TIMEOUT=10m"; do
  # shellcheck disable=SC2086 # one or two assignments on purpose
  run env $bad "$KIND" bootstrap
  expect_fail "bootstrap refuses ${bad}" "error:"
done

# --- up, wait and down act on the named cluster only -------------------------------------------------------------------

: >"$STUB_LOG"
run env STUB_KIND_VERSION=v0.20.0 "$KIND" up
expect_fail "up refuses another kind version" "kind must be v0.33.0"
check "nothing was created with the wrong kind" sh -c "! grep -q 'kind create' \"\$STUB_LOG\""

: >"$STUB_LOG"
run env STUB_KIND_CLUSTERS="other shadewright" "$KIND" down
expect_ok "down deletes the named cluster"
check "down names only that cluster" grep -qx 'kind delete cluster --name shadewright' "$STUB_LOG"
: >"$STUB_LOG"
run env STUB_KIND_CLUSTERS="other" "$KIND" down
expect_ok "down without the cluster is a no-op" "no Kind cluster shadewright"
check "nothing was deleted" sh -c "! grep -q 'kind delete' \"\$STUB_LOG\""

: >"$STUB_LOG"
run env STUB_REVISION="refs/pull/12/head@sha1:${SHA}" EXPECT_COMMIT="$SHA" WAIT_TIMEOUT=5 "$KIND" wait
expect_ok "wait accepts the expected revision" "baseline is Ready"
check "wait waits for the demo ScaledObject" grep -q 'wait --for=condition=Ready scaledobject/worker' "$STUB_LOG"
check "every kubectl call names the Kind context" sh -c "! grep '^kubectl' \"\$STUB_LOG\" | grep -vq -- '--context kind-shadewright '"
run env STUB_REVISION="refs/pull/12/head@sha1:ffffffffffffffffffffffffffffffffffffffff" EXPECT_COMMIT="$SHA" "$KIND" wait
expect_fail "wait refuses another revision" "expected ${SHA}"

finish
