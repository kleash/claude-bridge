#!/usr/bin/env bash
# claude-bridge installer.
# Copies all hook scripts and the shared lib into ~/.claude-bridge/, registers
# the Stop / PreToolUse / Notification hooks in ~/.claude/settings.json, and
# symlinks the `claude-bridge` CLI into ~/.local/bin (if that dir exists). All
# steps are idempotent — re-running upgrades in place.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="${CLAUDE_BRIDGE_INSTALL_DIR:-$HOME/.claude-bridge}"
SETTINGS="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"

# Files to install. Each entry: src_basename:exec_bit
FILES=(
  "lib-bridge.sh:0"
  "bridge-hook.sh:1"
  "bridge-pretool-hook.sh:1"
  "bridge-notify-hook.sh:1"
  "bridge-router.sh:1"
  "bridge-doctor.sh:1"
  "claude-bridge:1"
)

for entry in "${FILES[@]}"; do
  name="${entry%:*}"
  if [ ! -f "$REPO_DIR/bin/$name" ]; then
    echo "ERROR: $REPO_DIR/bin/$name not found" >&2; exit 1
  fi
done

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required. Install it (e.g. 'brew install jq' / 'apt install jq') and re-run." >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
for entry in "${FILES[@]}"; do
  name="${entry%:*}"
  exe="${entry#*:}"
  cp "$REPO_DIR/bin/$name" "$DEST_DIR/$name"
  if [ "$exe" = "1" ]; then chmod +x "$DEST_DIR/$name"; fi
done
echo "Installed claude-bridge files into $DEST_DIR"

mkdir -p "$(dirname "$SETTINGS")"

STOP_HOOK="$DEST_DIR/bridge-hook.sh"
PRETOOL_HOOK="$DEST_DIR/bridge-pretool-hook.sh"
NOTIFY_HOOK="$DEST_DIR/bridge-notify-hook.sh"

# Register all three hooks in one merged JSON object.
HOOK_ENTRY="$(jq -nc \
  --arg stop "$STOP_HOOK" \
  --arg pre  "$PRETOOL_HOOK" \
  --arg note "$NOTIFY_HOOK" \
  '{
    Stop:         [{matcher:"",hooks:[{type:"command",command:$stop}]}],
    PreToolUse:   [{matcher:"",hooks:[{type:"command",command:$pre}]}],
    Notification: [{matcher:"",hooks:[{type:"command",command:$note}]}]
  }')"

if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.pre-claude-bridge.bak"
  echo "Backed up existing settings to $SETTINGS.pre-claude-bridge.bak"
  TMP="$(mktemp)"
  # Merge each slot, deduplicating by .hooks[].command so re-running install
  # doesn't pile up duplicate registrations.
  jq --argjson new "$HOOK_ENTRY" '
    .hooks = (
      (.hooks // {}) as $cur |
      reduce ($new | to_entries[]) as $kv (
        $cur;
        .[$kv.key] = (
          ((.[$kv.key] // []) + $kv.value)
          | (map(.hooks // []) | add) as $all
          | (
              [ $all | unique_by(.command)[] ]
            ) as $deduped
          | [{matcher:"", hooks:$deduped}]
        )
      )
    )
  ' "$SETTINGS" >"$TMP" && mv "$TMP" "$SETTINGS"
else
  jq -n --argjson new "$HOOK_ENTRY" '{hooks:$new}' >"$SETTINGS"
fi
echo "Registered Stop / PreToolUse / Notification hooks in $SETTINGS"

# Optional: symlink the CLI somewhere on PATH.
LINK_DIR="${CLAUDE_BRIDGE_BIN_DIR:-$HOME/.local/bin}"
LINKED=0
if [ -d "$LINK_DIR" ] && [ -w "$LINK_DIR" ]; then
  ln -sf "$DEST_DIR/claude-bridge" "$LINK_DIR/claude-bridge"
  echo "Symlinked $LINK_DIR/claude-bridge -> $DEST_DIR/claude-bridge"
  LINKED=1
fi

cat <<EOF

claude-bridge installed. The hooks are currently DORMANT (no-op).
To activate them, pick a folder (ideally one synced by OneDrive / Dropbox /
iCloud / Google Drive) and create the kill-switch sentinel:

  BRIDGE="\$HOME/OneDrive/ClaudeBridge"            # or any path
  mkdir -p "\$BRIDGE"/{inbox,outbox,archive}
  touch "\$BRIDGE/.enabled"
  echo "export CLAUDE_BRIDGE_DIR=\"\$BRIDGE\"" >> ~/.zshrc   # or ~/.bashrc

If CLAUDE_BRIDGE_DIR is unset, the hooks auto-detect the first synced cloud
folder they can find under \$HOME (OneDrive, Dropbox, iCloud Drive, GDrive).

Tool-call approval from your phone is opt-in. Set:

  export CLAUDE_BRIDGE_PERMISSION_TOOLS="Bash,Write,Edit"

…and the PreToolUse hook will route those tools' permission prompts through
the same inbox/outbox folder. Reply 'approve' or 'deny: <reason>'.

Disable everything instantly without uninstalling:
  rm "\$BRIDGE/.enabled"

Health check:
  $DEST_DIR/claude-bridge doctor

EOF

if [ "$LINKED" -eq 0 ]; then
  cat <<EOF
The 'claude-bridge' CLI was installed at $DEST_DIR/claude-bridge but no
writable directory was found on PATH. Add one of these to your shell rc:

  export PATH="$DEST_DIR:\$PATH"
  # or
  ln -s "$DEST_DIR/claude-bridge" /some/dir/on/your/PATH/claude-bridge

To uninstall completely: ./uninstall.sh
EOF
else
  echo "To uninstall completely: ./uninstall.sh"
fi
