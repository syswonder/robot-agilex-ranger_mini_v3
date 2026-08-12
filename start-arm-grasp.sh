#!/usr/bin/env bash
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
ARM_GRASP_MANIFEST="$DEPLOY_DIR/robonix_manifest.arm-grasp.yaml"

if [[ ! -f "$ARM_GRASP_MANIFEST" ]]; then
  echo "missing arm-grasp manifest: $ARM_GRASP_MANIFEST" >&2
  exit 1
fi

# Do not inherit a caller-provided manifest: this entrypoint must always use
# the arm-only grasp debug profile (Piper arm + wrist camera + pick pipeline).
export ROBONIX_MANIFEST="$ARM_GRASP_MANIFEST"

exec "$DEPLOY_DIR/start.sh" "$@"
