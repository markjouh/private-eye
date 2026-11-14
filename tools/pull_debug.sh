#!/bin/bash
# Copies the app's debug capture off the phone (console log, and a frame + JSON for every turn) and
# draws what was detected onto each frame.
#
#   tools/pull_debug.sh <device udid or name> [bundle id] [--last N]
#
# The frames show whoever was in front of the camera, so they go to ~/Library/Caches (not the
# project folder, which may be synced). Override with EYES_DEBUG_DIR.
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE=${1:?usage: tools/pull_debug.sh <device udid or name> [bundle id]}
BUNDLE=${2:-dev.eyeshack.eyes}
DEST=${EYES_DEBUG_DIR:-$HOME/Library/Caches/private-eye-debug}
# devicectl puts the contents of the source folder straight into the destination.
mkdir -p "$DEST"
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
  --source Library/Caches/debug --destination "$DEST" > /dev/null
shift $(( $# > 2 ? 2 : $# ))
tools/.venv/bin/python tools/render_turns.py "$DEST" "$@"
echo "console log: $DEST/console.log"
