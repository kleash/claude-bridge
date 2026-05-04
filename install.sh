#!/usr/bin/env bash
# claude-bridge installer.
# Copies the Stop-hook script into ~/.claude-bridge/, registers it in
# ~/.claude/settings.json, and prints next steps. Idempotent.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$REPO_DIR/bin/bridge-hook.sh"
DEST_DIR="$HOME/.claude-bridge"
DEST="$DEST_DIR/bridge-hook.sh"
SETTINGS="$HOME/.claude/settings.json"

if [ ! -f "$SRC" ]; then
  echo "ERROR: $SRC not found" >&2; exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required. Install it (e.g. 'brew install jq' / 'apt install jq') and re-run." >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
cp "$SRC" "$DEST"
chmod +x "$DEST"
echo "Installed hook to $DEST"

mkdir -p "$(dirname "$SETTINGS")"

# Build the hook entry pointing at the absolute installed path.
HOOK_ENTRY="$(jq -nc --arg cmd "$DEST" \
  '{Stop:[{matcher:"",hooks:[{type:"command",command:$cmd}]}]}')"

if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.pre-claude-bridge.bak"
  echo "Backed up existing settings to $SETTINGS.pre-claude-bridge.bak"
  TMP="$(mktemp)"
  jq --argjson new "$HOOK_ENTRY" '
    .hooks = ((.hooks // {}) * $new)
  ' "$SETTINGS" >"$TMP" && mv "$TMP" "$SETTINGS"
else
  jq -n --argjson new "$HOOK_ENTRY" '{hooks:$new}' >"$SETTINGS"
fi
echo "Registered Stop hook in $SETTINGS"

cat <<EOF

claude-bridge installed. The hook is currently DORMANT (no-op).
To activate it, pick a folder (ideally one synced by OneDrive / Dropbox /
iCloud / Google Drive) and create the kill-switch sentinel:

  BRIDGE="\$HOME/OneDrive/ClaudeBridge"            # or any path
  mkdir -p "\$BRIDGE"/{inbox,outbox,archive}
  touch "\$BRIDGE/.enabled"
  echo "export CLAUDE_BRIDGE_DIR=\"\$BRIDGE\"" >> ~/.zshrc   # or ~/.bashrc

If CLAUDE_BRIDGE_DIR is unset, the hook auto-detects the first synced cloud
folder it can find under \$HOME (OneDrive, Dropbox, iCloud Drive, GDrive).

To disable the hook instantly without uninstalling:
  rm "\$CLAUDE_BRIDGE_DIR/.enabled"

To uninstall completely: ./uninstall.sh
EOF
