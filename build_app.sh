#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="GOBL(in) Session Viewer"
APP="$ROOT/build/$APP_NAME.app"
BIN="$APP/Contents/MacOS/SessionViewer"
TMP="$ROOT/build/tmp"

rm -rf "$APP" "$TMP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$TMP"

# Универсальная сборка: Apple Silicon (arm64) + Intel (x86_64)
swiftc "$ROOT/Sources/main.swift" -o "$TMP/arm64" -target arm64-apple-macos11.0 -framework Cocoa -lsqlite3
swiftc "$ROOT/Sources/main.swift" -o "$TMP/x86_64" -target x86_64-apple-macos10.15 -framework Cocoa -lsqlite3
lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$BIN"
chmod +x "$BIN"
rm -rf "$TMP"

# Логотип для окна и иконка приложения
cp "$ROOT/logo.svg" "$ROOT/AppIcon.icns" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>SessionViewer</string>
  <key>CFBundleIdentifier</key>
  <string>local.goblin.session-viewer</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>10.15</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

# Локальная подпись приложения
codesign --force --sign - "$APP"

echo "$APP"
