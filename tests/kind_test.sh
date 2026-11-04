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
  *"{.status.artifact.revision}"*)
    # STUB_STALE_READS reads of an earlier revision first, as right after Ready on an old fetch.
    n="$(grep -c 'artifact.revision' "$STUB_LOG")"
    if [ "$n" -le "${STUB_STALE_READS:-0}" ]; then printf 'main@sha1:%040d' 0; else printf '%s' "${STUB_REVISION:-}"; fi ;;
esac
exit 0
EOF
# Downloads give whatever STUB_DOWNLOAD holds, never the real release.
cat >"$STUBS/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >>"$STUB_LOG"
while [ "$#" -gt 0 ]; do
  case "$1" in -o) printf '%s' "${STUB_DOWNLOAD:-tampered}" >"$2"; shift ;; esac
  shift
done
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$STUBS/docker"
printf '#!/usr/bin/env bash\nexit 0\n' >"$STUBS/kustomize"
# No real waiting in the polling loops.
printf '#!/usr/bin/env bash\nexit 0\n' >"$STUBS/sleep"
chmod +x "$STUBS/kind" "$STUBS/kubectl" "$STUBS/docker" "$STUBS/kustomize" "$STUBS/curl" "$STUBS/sleep"

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
: >"$STUB_LOG"
run env STUB_REVISION="refs/pull/12/head@sha1:${SHA}" STUB_STALE_READS=2 EXPECT_COMMIT="$SHA" WAIT_TIMEOUT=60 "$KIND" wait
expect_ok "wait polls until Flux has fetched the expected commit" "Flux fetched refs/pull/12/head@sha1:${SHA}"
check "it read the revision three times" test "$(grep -c 'artifact.revision' "$STUB_LOG")" = 3
: >"$STUB_LOG"
run env STUB_REVISION="refs/pull/12/head@sha1:ffffffffffffffffffffffffffffffffffffffff" EXPECT_COMMIT="$SHA" WAIT_TIMEOUT=20 "$KIND" wait
expect_fail "wait refuses another revision once WAIT_TIMEOUT runs out" "after 20s, expected ${SHA}"
check "it polled until then" test "$(grep -c 'artifact.revision' "$STUB_LOG")" = 5
run env EXPECT_COMMIT=abc "$KIND" wait
expect_fail "wait refuses a short EXPECT_COMMIT" "EXPECT_COMMIT must be a full commit SHA"

# --- the Flux manifest is cached only after its checksum matches ---------------------------------------------------------

# A copy of the scripts in a scratch repository, so .cache/ of the real checkout is never touched.
KREPO="$T/kindrepo"
mkdir -p "$KREPO/scripts"
cp "$SRC_ROOT"/scripts/*.sh "$SRC_ROOT/scripts/tools.env" "$KREPO/scripts/"
printf '#!/usr/bin/env bash\nexit 0\n' >"$STUBS/kustomize"
chmod +x "$STUBS/kustomize"
git init -q "$KREPO"
. "$SRC_ROOT/scripts/tools.env"
CACHED="$KREPO/.cache/flux-${FLUX_VERSION}-install.yaml"
: >"$STUB_LOG"
run "$KREPO/scripts/kind.sh" up
expect_fail "up refuses a Flux manifest with the wrong checksum" "checksum mismatch for the Flux ${FLUX_VERSION} install.yaml"
check "the bad download is not cached" test ! -e "$CACHED"
check "nor left behind as a temporary file" test ! -e "${CACHED}.tmp"
check "nothing was applied" sh -c "! grep -q 'kubectl .* apply' \"\$STUB_LOG\""
mkdir -p "${CACHED%/*}"
printf 'tampered\n' >"$CACHED"
: >"$STUB_LOG"
run "$KREPO/scripts/kind.sh" up
expect_fail "a cached manifest that does not match is not used" "removed a cached Flux manifest"
check "it was downloaded again" grep -q '^curl ' "$STUB_LOG"
check "and the bad copy is gone" test ! -e "$CACHED"

finish
