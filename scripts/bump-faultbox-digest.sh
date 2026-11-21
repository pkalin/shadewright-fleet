#!/usr/bin/env bash
# Moves every manifest that references ghcr.io/pkalin/faultbox to a new image digest (the index digest the faultbox-image
# workflow prints in its job summary). Only a reference of the form ghcr.io/pkalin/faultbox[:tag]@sha256:<64 hex> that
# starts a line or follows a space or a quote (as after `image: `) is changed, so another registry's path that ends
# in the same name is left alone. It looks in YAML files under apps/, infrastructure/, clusters/ and scenarios/; the
# tag is kept (use --tag to set it).
# Prints each file it changed and fails if there is none, so a typo does not pass as a bump.
#   scripts/bump-faultbox-digest.sh sha256:<digest> [--tag X.Y.Z]
set -euo pipefail

usage() {
  echo "usage: $0 sha256:<64 hex> [--tag X.Y.Z]" >&2
  exit 2
}

[ "$#" -eq 1 ] || [ "$#" -eq 3 ] || usage
digest="$1"
tag=""
if [ "$#" -eq 3 ]; then
  [ "$2" = "--tag" ] || usage
  tag="$3"
  printf '%s' "${tag}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' || { echo "not a version: ${tag}" >&2; exit 2; }
fi
printf '%s' "${digest}" | grep -Eq '^sha256:[a-f0-9]{64}$' || { echo "not a digest: ${digest}" >&2; exit 2; }

root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "${root}"

ref='ghcr\.io/pkalin/faultbox'
# What may come right before the reference: the start of the line, a space (as in `image: `) or a quote.
lead="(^|[[:space:]\"'])"
changed=0
while IFS= read -r file; do
  grep -Eq "${lead}${ref}(:[A-Za-z0-9._-]+)?@sha256:[a-f0-9]{64}" "${file}" || continue
  tmp="$(mktemp)"
  if [ -n "${tag}" ]; then
    sed -E "s#${lead}(${ref})(:[A-Za-z0-9._-]+)?@sha256:[a-f0-9]{64}#\\1\\2:${tag}@${digest}#g" "${file}" >"${tmp}"
  else
    sed -E "s#${lead}(${ref}(:[A-Za-z0-9._-]+)?)@sha256:[a-f0-9]{64}#\\1\\2@${digest}#g" "${file}" >"${tmp}"
  fi
  cat "${tmp}" >"${file}"
  rm -f "${tmp}"
  echo "${file}"
  changed=$((changed + 1))
done < <(git ls-files --cached --others --exclude-standard -- ':(glob)apps/**/*.yaml' ':(glob)infrastructure/**/*.yaml' ':(glob)clusters/**/*.yaml' ':(glob)scenarios/**/*.yaml' | sort -u)

if [ "${changed}" -eq 0 ]; then
  echo "no manifest references ${ref//\\/} by digest" >&2
  exit 1
fi
