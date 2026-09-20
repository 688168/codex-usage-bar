#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
SOURCE_APP="$PROJECT_DIR/dist/Codex Usage Bar.app"
DESTINATION_APP="/Applications/Codex Usage Bar.app"

"$SCRIPT_DIR/build.sh"

if [[ -w /Applications ]]; then
  /usr/bin/ditto "$SOURCE_APP" "$DESTINATION_APP"
else
  echo "Administrator permission is required to install in /Applications."
  /usr/bin/sudo /usr/bin/ditto "$SOURCE_APP" "$DESTINATION_APP"
fi

/usr/bin/open "$DESTINATION_APP"

echo "Installed: $DESTINATION_APP"
echo "Use the app menu to enable Show After Startup if desired."
