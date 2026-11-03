#!/usr/bin/env bash
# Installs the pinned tools from scripts/tools.env into bin/ (git-ignored), each verified against its checksum
# before it is unpacked. Used by CI and by `make tools`; scripts/lib.sh puts bin/ first on PATH.
#
#   scripts/install-tools.sh                      # all tools
#   scripts/install-tools.sh kustomize kubeconform
#   TOOLS_BIN=/some/dir scripts/install-tools.sh  # another target directory
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

BIN="${TOOLS_BIN:-${REPO_ROOT}/bin}"
PLATFORM="$(platform)"
OS="${PLATFORM%_*}"
ARCH="${PLATFORM#*_}"

need curl
need tar
mkdir -p "$BIN"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fetch() { # fetch <url> <file> <sha256>
  curl -fsSL --proto '=https' --retry 3 -o "$2" "$1"
  verify_sha256 "$2" "$3"
}

install_kustomize() {
  local v sum tgz
  v="$(pinned KUSTOMIZE_VERSION)"
  sum="$(pinned "KUSTOMIZE_SHA256_${PLATFORM}")"
  tgz="kustomize_${v}_${OS}_${ARCH}.tar.gz"
  fetch "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${v}/${tgz}" "$work/$tgz" "$sum"
  tar -xzf "$work/$tgz" -C "$BIN" kustomize
}

install_kubeconform() {
  local v sum tgz
  v="$(pinned KUBECONFORM_VERSION)"
  sum="$(pinned "KUBECONFORM_SHA256_${PLATFORM}")"
  tgz="kubeconform-${OS}-${ARCH}.tar.gz"
  fetch "https://github.com/yannh/kubeconform/releases/download/${v}/${tgz}" "$work/$tgz" "$sum"
  tar -xzf "$work/$tgz" -C "$BIN" kubeconform
}

install_kind() {
  local v sum
  v="$(pinned KIND_VERSION)"
  sum="$(pinned "KIND_SHA256_${PLATFORM}")"
  fetch "https://github.com/kubernetes-sigs/kind/releases/download/${v}/kind-${OS}-${ARCH}" "$work/kind" "$sum"
  install -m 0755 "$work/kind" "$BIN/kind"
}

install_kubectl() {
  local v sum
  v="$(pinned KUBECTL_VERSION)"
  sum="$(pinned "KUBECTL_SHA256_${PLATFORM}")"
  fetch "https://dl.k8s.io/release/${v}/bin/${OS}/${ARCH}/kubectl" "$work/kubectl" "$sum"
  install -m 0755 "$work/kubectl" "$BIN/kubectl"
}

install_shellcheck() {
  local v sum a txz
  v="$(pinned SHELLCHECK_VERSION)"
  sum="$(pinned "SHELLCHECK_SHA256_${PLATFORM}")"
  case "$ARCH" in amd64) a=x86_64 ;; arm64) a=aarch64 ;; esac
  txz="shellcheck-${v}.${OS}.${a}.tar.xz"
  fetch "https://github.com/koalaman/shellcheck/releases/download/${v}/${txz}" "$work/$txz" "$sum"
  tar -xJf "$work/$txz" -C "$work"
  install -m 0755 "$work/shellcheck-${v}/shellcheck" "$BIN/shellcheck"
}

if [ "$#" -eq 0 ]; then
  set -- kustomize kubeconform kind kubectl shellcheck
fi
for tool in "$@"; do
  case "$tool" in
    kustomize | kubeconform | kind | kubectl | shellcheck) "install_${tool}" ;;
    *) die "unknown tool: ${tool}" ;;
  esac
  log "installed ${tool} into ${BIN}"
done
