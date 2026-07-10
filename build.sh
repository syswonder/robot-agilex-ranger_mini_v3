#!/usr/bin/env bash
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
export ROBONIX_DEPLOY_DIR="$DEPLOY_DIR"

set +u
source /opt/ros/humble/setup.bash
set -u

exec rbnx build -f "$DEPLOY_DIR/robonix_manifest.yaml" "$@"
