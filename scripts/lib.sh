# Shared helpers for scripts/*.sh. Sourced, never run. Works with bash 3.2 (macOS) and later.
# shellcheck shell=bash

# The repository root; every script works from there.
REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

# shellcheck source=scripts/tools.env
. "${REPO_ROOT}/scripts/tools.env"

# Tools installed by scripts/install-tools.sh come first, so the pinned versions win over others on PATH.
# FLEET_TOOLS_DIR replaces that directory; only the tests set it, to an empty one, so that their stubs on PATH win
# over whatever make tools has put in bin/.
PATH="${FLEET_TOOLS_DIR:-${REPO_ROOT}/bin}:${PATH}"
export PATH

KUSTOMIZE="${KUSTOMIZE:-kustomize}"
KUBECONFORM="${KUBECONFORM:-kubeconform}"

CRD_SCHEMAS="https://raw.githubusercontent.com/datreeio/CRDs-catalog/${CRDS_CATALOG_REF}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"

log() { printf '%s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is not on PATH (make tools installs the pinned version into bin/)"
}

# require_version <name> <expected> <actual output>: the output must contain the expected version as a word.
require_version() {
  case " $3 " in
    *[[:space:]]"$2"[[:space:]]*) ;;
    *) die "$1 must be ${2} (pinned in scripts/tools.env), found: ${3:-nothing} (make tools installs it into bin/)" ;;
  esac
}

# Checks that kustomize and kubeconform are the versions scripts/render.sh runs with in CI.
require_render_tools() {
  local out
  need "$KUSTOMIZE"
  need "$KUBECONFORM"
  out="$("$KUSTOMIZE" version 2>/dev/null | tr '\n' ' ')" || true
  require_version kustomize "$KUSTOMIZE_VERSION" "$out"
  out="$("$KUBECONFORM" -v 2>/dev/null | tr '\n' ' ')" || true
  require_version kubeconform "$KUBECONFORM_VERSION" "$out"
}

# render_dir <dir>: kustomize build of one directory and kubeconform -strict on the output, against the Kubernetes
# schemas of the lab's version and the pinned CRD catalog. The same check as scripts/render.sh.
render_dir() {
  local dir="$1" out cache
  cache="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/kubeconform-cache"
  mkdir -p "$cache"
  if ! out="$("$KUSTOMIZE" build "$dir")"; then
    echo "::error::kustomize build ${2:-$dir} failed"
    return 1
  fi
  # CustomResourceDefinition has no schema in the CRD catalog (the vendored Shadewright CRDs are generated and
  # validated in the operator repository), so it is skipped; every other kind, Flux and Shadewright included, is checked.
  if ! printf '%s\n' "$out" | "$KUBECONFORM" -strict -summary -kubernetes-version "$KUBERNETES_VERSION" \
      -skip CustomResourceDefinition -cache "$cache" -schema-location default -schema-location "$CRD_SCHEMAS"; then
    echo "::error::${2:-$dir} does not pass the schema check"
    return 1
  fi
}

# sha256_of <file>: prints the file's SHA-256 (sha256sum on Linux, shasum on macOS).
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# verify_sha256 <file> <expected>
verify_sha256() {
  local got
  got="$(sha256_of "$1")"
  [ "$got" = "$2" ] || die "checksum mismatch for $(basename "$1"): expected ${2}, got ${got}"
}

# platform: prints os_arch as used in scripts/tools.env (darwin_arm64, linux_amd64, ...).
platform() {
  local os arch
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux) os=linux ;;
    *) die "unsupported OS: $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) arch=amd64 ;;
    arm64 | aarch64) arch=arm64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
  printf '%s_%s\n' "$os" "$arch"
}

# pinned <name>: prints the value of a variable from scripts/tools.env, or fails if it is not set.
pinned() {
  local value
  case "$1" in
    '' | *[!A-Za-z0-9_]*) die "invalid variable name: $1" ;;
  esac
  value="${!1:-}"
  [ -n "$value" ] || die "$1 is not pinned in scripts/tools.env"
  printf '%s\n' "$value"
}

# normalize_git_url <url>: host/owner/repo, lower case, for comparing a Flux URL with a Git remote, and the only form
# of a URL the scripts print. https://github.com/o/r(.git), ssh://git@github.com/o/r and git@github.com:o/r.git all
# give github.com/o/r. Userinfo (a user name, a token or a password) is dropped from the host part.
normalize_git_url() {
  local u="$1" host
  case "$u" in
    *://*) u="${u#*://}" ;;
    *@*:*) u="${u#*@}"; u="${u%%:*}/${u#*:}" ;;
  esac
  host="${u%%/*}"
  u="${host##*@}${u#"$host"}"
  u="${u%/}"
  u="${u%.git}"
  printf '%s\n' "$u" | tr '[:upper:]' '[:lower:]'
}
