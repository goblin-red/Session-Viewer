#!/bin/bash
# Установка GOBL(in) Session Viewer: скачивает готовую сборку из GitHub Releases.
#   curl -fsSL https://raw.githubusercontent.com/goblin-red/session-viewer/main/install.sh | bash
# Свой путь установки: GOBLIN_INSTALL_DIR=~/Apps; не открывать после установки: bash -s -- --no-open
set -euo pipefail

REPO="goblin-red/session-viewer"
ASSET="goblin-session-viewer-macos.zip"
NAME="GOBL(in) Session Viewer"
URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"

# Куда ставить: /Applications, а если туда нельзя писать — ~/Applications
DEST_ROOT="${GOBLIN_INSTALL_DIR:-/Applications}"
mkdir -p "${DEST_ROOT}" 2>/dev/null || true
if [ ! -w "${DEST_ROOT}" ]; then
    DEST_ROOT="${HOME}/Applications"
    mkdir -p "${DEST_ROOT}"
fi
DEST="${DEST_ROOT}/${NAME}.app"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "==> Downloading ${NAME} ..."
curl -fL --progress-bar "${URL}" -o "${TMP}/app.zip"
ditto -x -k "${TMP}/app.zip" "${TMP}/unpacked"

# Закрываем работающую копию и заменяем приложение
pkill -x SessionViewer 2>/dev/null || true
rm -rf "${DEST}"
ditto "${TMP}/unpacked/${NAME}.app" "${DEST}"
xattr -dr com.apple.quarantine "${DEST}" 2>/dev/null || true

echo "==> Installed: ${DEST}"
if [ "${1:-}" != "--no-open" ]; then
    open "${DEST}"
fi
