#!/bin/zsh
# Install the experimental FlowCue DSH approval bridge into a DSH profile.
# Usage: Scripts/install-dsh-bridge.sh [profile]   (default: desktop)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${1:-desktop}"
DSH="${DSH_CLI:-/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh}"
PATCH="$HOME/.dsh/profiles/$PROFILE/cordis.patch.yml"

if [[ ! -x "$DSH" ]]; then
  echo "DSH CLI not found at $DSH" >&2
  exit 1
fi
if [[ ! -f "$PATCH" ]]; then
  echo "DSH profile '$PROFILE' not found at $PATCH" >&2
  exit 1
fi

"$DSH" plugin --profile "$PROFILE" add "$ROOT/Integrations/DSHBridge"

python3 - "$PATCH" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text()
if "flowcue-dsh-bridge" not in text:
    if not text.endswith("\n"):
        text += "\n"
    text += """
- id: flowcue-dsh-bridge
  name: "flowcue-dsh-bridge"
"""
    path.write_text(text)
    print(f"added flowcue-dsh-bridge to {path}")
else:
    print(f"flowcue-dsh-bridge already present in {path}")
PY

echo
echo "Installed. Quit and reopen DeepSeek Harness to load the plugin."
echo "Bridge status file: ~/.flowcue/dsh-bridge.json"
echo "Uninstall: dsh plugin --profile $PROFILE remove flowcue-dsh-bridge"
