#!/usr/bin/env bash
# Runs every tests/*_test.sh. Offline: Git remotes are local bare repositories and kubectl, kind and the render tools
# are stubs (expected.yaml checks use the real, pinned kubeconform, which reads only the local schema).
set -euo pipefail

cd "$(dirname "$0")/.."
status=0
for t in tests/*_test.sh; do
  echo "# ${t}"
  bash "$t" || status=1
done
exit "$status"
