#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_PATH="$PROJECT_DIR/dist/Codex Usage Bar.app"
RELEASE_DIR="$PROJECT_DIR/release"
ARCHIVE_PATH="$RELEASE_DIR/Codex-Usage-Bar-1.0.1-macOS.zip"

"$SCRIPT_DIR/build.sh"
/bin/mkdir -p "$RELEASE_DIR"
/usr/bin/ditto -c -k --norsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
/usr/bin/shasum -a 256 "$ARCHIVE_PATH"

echo "$ARCHIVE_PATH"
