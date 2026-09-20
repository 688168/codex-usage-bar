#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="$PROJECT_DIR/dist/Codex Usage Bar.app"
CONTENTS_DIR="$APP_DIR/Contents"
BUILD_DIR="$PROJECT_DIR/.native-build"
EXECUTABLE="$BUILD_DIR/CodexUsageBar"

mkdir -p "$BUILD_DIR/ModuleCache"

xcrun clang \
  -fobjc-arc \
  -fmodules \
  -fmodules-cache-path="$BUILD_DIR/ModuleCache" \
  -mmacosx-version-min=13.0 \
  -framework Cocoa \
  -framework ServiceManagement \
  -Wall -Wextra \
  "$PROJECT_DIR/Sources/main.m" \
  -o "$EXECUTABLE"

"$EXECUTABLE" --self-test

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$EXECUTABLE" "$CONTENTS_DIR/MacOS/CodexUsageBar"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/codex-menubar.svg" \
  "$CONTENTS_DIR/Resources/codex-menubar.svg"
cp "$PROJECT_DIR/Resources/resetcd-menubar.svg" \
  "$CONTENTS_DIR/Resources/resetcd-menubar.svg"
cp "$PROJECT_DIR/Resources/ResetCDAppIcon.icns" \
  "$CONTENTS_DIR/Resources/ResetCDAppIcon.icns"

codesign --force --sign - --timestamp=none "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
plutil -lint "$CONTENTS_DIR/Info.plist"

echo "$APP_DIR"
