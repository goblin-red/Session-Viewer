#!/bin/zsh
# Готовая сборка для GitHub Releases: build/goblin-session-viewer-macos.zip
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="GOBL(in) Session Viewer"
ZIP="$ROOT/build/goblin-session-viewer-macos.zip"

"$ROOT/build_app.sh" > /dev/null

rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --keepParent "$ROOT/build/$NAME.app" "$ZIP"
echo "$ZIP"
