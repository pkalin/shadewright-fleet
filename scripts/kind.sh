#!/usr/bin/env bash
# A Kind cluster with Flux pointed at this repository, as on the lab (ADR-0022): a GitRepository "fleet" and a
# Kustomization "kind" that applies ./clusters/kind, both in flux-system. Kind, its node image and Flux are pinned in
# scripts/tools.env. Every kubectl call names the Kind context, so no other cluster is touched.
#
#   scripts/kind.sh up          # make kind-up: create the cluster (if missing), install Flux, point it at the fleet
#   scripts/kind.sh wait        # make kind-wait: wait until the healthy baseline is Ready
#   scripts/kind.sh down        # make kind-down: delete the cluster
#   scripts/kind.sh debug       # print Flux and workload state (CI, on failure)
#   scripts/kind.sh bootstrap   # print the GitRepository and Kustomization that `up` applies
#
# Environment:
#   KIND_CLUSTER_NAME  default shadewright (context kind-shadewright)
#   FLEET_URL          default https://github.com/pkalin/shadewright-fleet (public, read over HTTPS, no credentials)
#   FLEET_BRANCH       the branch Flux tracks, default cluster/kind (the harness's branch for CLUSTER=kind)
#   FLEET_COMMIT       optional commit to pin together with FLEET_BRANCH (CI on main)
#   FLEET_REF_NAME     a ref instead of a branch, such as refs/pull/12/head (CI on a pull request; read-only, and the
#                      harness refuses to run because Flux then tracks no branch)
#   EXPECT_COMMIT      for wait: the commit the GitRepository must have fetched
#   WAIT_TIMEOUT       for wait: seconds per step (the revision poll included), default 900
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"

NAME="${KIND_CLUSTER_NAME:-shadewright}"
FLEET_URL="${FLEET_URL:-https://github.com/pkalin/shadewright-fleet}"
FLEET_BRANCH="${FLEET_BRANCH:-cluster/kind}"
FLEET_COMMIT="${FLEET_COMMIT:-}"
FLEET_REF_NAME="${FLEET_REF_NAME:-}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-900}"
CTX="kind-${NAME}"
FLUX_IMAGES="helm_controller image_automation_controller image_reflector_controller kustomize_controller notification_controller source_controller source_watcher"

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}

k() { kubectl --context "$CTX" "$@"; }

validate_inputs() {
  [[ "$NAME" =~ ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ ]] || die "invalid KIND_CLUSTER_NAME '${NAME}'"
  [[ "$FLEET_URL" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    die "FLEET_URL must be https://github.com/<owner>/<repo>, got '${FLEET_URL}'"
  [[ "$WAIT_TIMEOUT" =~ ^[0-9]+$ ]] || die "WAIT_TIMEOUT must be a number of seconds"
  if [ -n "$FLEET_REF_NAME" ]; then
    [ -z "$FLEET_COMMIT" ] || die "FLEET_COMMIT goes with FLEET_BRANCH, not FLEET_REF_NAME"
    case "$FLEET_REF_NAME" in
      refs/*) ;;
      *) die "FLEET_REF_NAME must be a full ref name (refs/...), got '${FLEET_REF_NAME}'" ;;
    esac
    git check-ref-format "$FLEET_REF_NAME" || die "invalid FLEET_REF_NAME '${FLEET_REF_NAME}'"
  else
    git check-ref-format --branch "$FLEET_BRANCH" >/dev/null 2>&1 || die "invalid FLEET_BRANCH '${FLEET_BRANCH}'"
    if [ -n "$FLEET_COMMIT" ]; then
      [[ "$FLEET_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "FLEET_COMMIT must be a full commit SHA"
    fi
  fi
}

# The objects shadewright-azure's scripts/lab.sh creates on the lab after installing Flux, for Kind: the same
# GitRepository, and a root Kustomization with the same settings, named "kind" here and "lab" there, without
# postBuild substitutions.
cmd_bootstrap() {
  validate_inputs
  cat <<EOF
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: fleet
  namespace: flux-system
spec:
  interval: 1m
  timeout: 60s
  url: ${FLEET_URL}
  ref:
EOF
  if [ -n "$FLEET_REF_NAME" ]; then
    printf '    name: %s\n' "$FLEET_REF_NAME"
  else
    printf '    branch: %s\n' "$FLEET_BRANCH"
    if [ -n "$FLEET_COMMIT" ]; then printf '    commit: %s\n' "$FLEET_COMMIT"; fi
  fi
  cat <<EOF
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: kind
  namespace: flux-system
spec:
  interval: 2m
  retryInterval: 1m
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: fleet
  path: ./clusters/kind
  prune: true
  wait: false
EOF
}

# flux_manifest <out>: the release's install.yaml, checksum verified, with every controller image pinned by digest.
flux_manifest() {
  local out="$1" cache file work img var pin got
  cache="${REPO_ROOT}/.cache"
  file="${cache}/flux-${FLUX_VERSION}-install.yaml"
  mkdir -p "$cache"
  # Only a verified file is cached: the download is checked before it takes the cache name, and a cached file that
  # no longer matches (an older pin, a corrupted disk) is removed, so the next run downloads it again.
  if [ -f "$file" ] && [ "$(sha256_of "$file")" != "$FLUX_INSTALL_SHA256" ]; then
    rm -f "$file"
    log "removed a cached Flux manifest that does not match FLUX_INSTALL_SHA256"
  fi
  if [ ! -f "$file" ]; then
    need curl
    rm -f "${file}.tmp"
    curl -fsSL --proto '=https' --retry 3 -o "${file}.tmp" \
      "https://github.com/fluxcd/flux2/releases/download/${FLUX_VERSION}/install.yaml"
    got="$(sha256_of "${file}.tmp")"
    if [ "$got" != "$FLUX_INSTALL_SHA256" ]; then
      rm -f "${file}.tmp"
      die "checksum mismatch for the Flux ${FLUX_VERSION} install.yaml: expected ${FLUX_INSTALL_SHA256}, got ${got}"
    fi
    mv "${file}.tmp" "$file"
  fi

  work="$(mktemp -d)"
  cp "$file" "$work/install.yaml"
  {
    printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n  - install.yaml\nimages:\n'
    for var in $FLUX_IMAGES; do
      pin="$(pinned "FLUX_IMAGE_${var}")"
      img="ghcr.io/fluxcd/$(printf '%s' "$var" | tr '_' '-')"
      grep -qE "^[[:space:]]*image: ${img}:${pin%@*}\$" "$file" ||
        die "the Flux ${FLUX_VERSION} manifest does not use ${img}:${pin%@*} (scripts/tools.env)"
      printf '  - name: %s\n    newTag: %s\n    digest: %s\n' "$img" "${pin%@*}" "${pin#*@}"
    done
  } >"$work/kustomization.yaml"
  "$KUSTOMIZE" build "$work" >"$out"
  rm -rf "$work"
  if grep -E '^[[:space:]]*image:[[:space:]]*[^[:space:]]' "$out" | grep -vqE '@sha256:[0-9a-f]{64}$'; then
    die "an image in the Flux ${FLUX_VERSION} manifest is not pinned by digest (scripts/tools.env)"
  fi
}

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "$NAME"
}

cmd_up() {
  local out manifest
  validate_inputs
  need docker
  need kind
  need kubectl
  need "$KUSTOMIZE"
  out="$(kind version 2>/dev/null)" || true
  require_version kind "$KIND_VERSION" "$out"

  if cluster_exists; then
    log "Kind cluster ${NAME} exists; reusing it"
  else
    kind create cluster --name "$NAME" --image "$KIND_NODE_IMAGE" --wait 120s
  fi
  k cluster-info >/dev/null || die "context ${CTX} does not reach the Kind cluster"

  manifest="$(mktemp)"
  flux_manifest "$manifest"
  log "installing Flux ${FLUX_VERSION}"
  k apply --server-side --force-conflicts -f "$manifest" >/dev/null
  rm -f "$manifest"
  k wait --for=condition=Established crd -l app.kubernetes.io/part-of=flux --timeout=120s >/dev/null
  k -n flux-system wait --for=condition=Available deployment --all --timeout=300s >/dev/null

  cmd_bootstrap | k apply -f -
  log "Flux on ${CTX} syncs ./clusters/kind from ${FLEET_URL} (${FLEET_REF_NAME:-$FLEET_BRANCH}); make kind-wait waits for the baseline"
}

wait_exists() { # wait_exists <namespace> <resource>
  local i=0
  until k -n "$1" get "$2" >/dev/null 2>&1; do
    i=$((i + 5))
    [ "$i" -le "$WAIT_TIMEOUT" ] || die "$2 in $1 did not appear within ${WAIT_TIMEOUT}s"
    sleep 5
  done
}

wait_ready() { # wait_ready <namespace> <resource> [condition]
  wait_exists "$1" "$2"
  log "waiting for $2 in $1"
  k -n "$1" wait --for="condition=${3:-Ready}" "$2" --timeout="${WAIT_TIMEOUT}s" >/dev/null
}

cmd_wait() {
  local rev ks i
  validate_inputs
  if [ -n "${EXPECT_COMMIT:-}" ]; then
    [[ "$EXPECT_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "EXPECT_COMMIT must be a full commit SHA"
  fi
  need kubectl
  wait_ready flux-system gitrepository/fleet
  if [ -n "${EXPECT_COMMIT:-}" ]; then
    # Ready may still describe an earlier fetch: poll until the artifact is the expected commit.
    i=0
    while :; do
      rev="$(k -n flux-system get gitrepository fleet -o 'jsonpath={.status.artifact.revision}' 2>/dev/null)" || rev=""
      case "$rev" in
        *"sha1:${EXPECT_COMMIT}") log "Flux fetched ${rev}"; break ;;
      esac
      [ "$i" -lt "$WAIT_TIMEOUT" ] || die "Flux fetched ${rev:-nothing} after ${WAIT_TIMEOUT}s, expected ${EXPECT_COMMIT}"
      i=$((i + 5))
      sleep 5
    done
  fi
  for ks in kind infrastructure apps; do
    wait_ready flux-system "kustomization/${ks}"
  done
  wait_ready demo deployment/web Available
  wait_ready demo deployment/worker Available
  wait_ready demo scaledobject/worker
  log "the healthy baseline is Ready on ${CTX}"
}

cmd_down() {
  need kind
  [[ "$NAME" =~ ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ ]] || die "invalid KIND_CLUSTER_NAME '${NAME}'"
  if cluster_exists; then
    kind delete cluster --name "$NAME"
  else
    log "no Kind cluster ${NAME}"
  fi
}

cmd_debug() {
  k get nodes -o wide || true
  k get gitrepositories,kustomizations,helmrepositories,helmreleases -A || true
  k -n flux-system describe gitrepository fleet || true
  k -n flux-system describe kustomizations || true
  k -n flux-system describe helmreleases || true
  k get pods -A -o wide || true
  k -n demo describe scaledobject worker || true
  k get events -A --sort-by=.lastTimestamp | tail -n 80 || true
}

case "${1:-}" in
  up) cmd_up ;;
  wait) cmd_wait ;;
  down) cmd_down ;;
  debug) cmd_debug ;;
  bootstrap) cmd_bootstrap ;;
  *) usage ;;
esac
