#!/usr/bin/env bash
# claude-bridge uninstaller. Removes the Stop / PreToolUse / Notification
# hook entries from ~/.claude/settings.json and deletes the installed scripts
# under ~/.claude-bridge/. Leaves the bridge folder (inbox/outbox/archive)
# and logs alone.

set -euo pipefail

DEST_DIR="${CLAUDE_BRIDGE_INSTALL_DIR:-$HOME/.claude-bridge}"
SETTINGS="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
LINK_DIR="${CLAUDE_BRIDGE_BIN_DIR:-$HOME/.local/bin}"

HOOKS=(
  "$DEST_DIR/bridge-hook.sh"
  "$DEST_DIR/bridge-pretool-hook.sh"
  "$DEST_DIR/bridge-notify-hook.sh"
)
SLOTS=(Stop PreToolUse Notification)

if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
  cp "$SETTINGS" "$SETTINGS.pre-uninstall.bak"
  TMP="$(mktemp)"
  # Build a JSON array of commands to scrub from any slot.
  CMDS_JSON="$(printf '%s\n' "${HOOKS[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')"
  jq --argjson cmds "$CMDS_JSON" '
    if .hooks then
      .hooks = (
        .hooks
        | to_entries
        | map(
            .value = (
              .value
              | map(.hooks |= map(select(([.command] | inside($cmds)) | not)))
              | map(select((.hooks // []) | length > 0))
            )
          )
        | map(select((.value | length) > 0))
        | from_entries
      )
      | if (.hooks | length) == 0 then del(.hooks) else . end
    else . end
  ' "$SETTINGS" >"$TMP" && mv "$TMP" "$SETTINGS"
  echo "Removed Stop / PreToolUse / Notification entries from $SETTINGS"
fi

for f in \
  "$DEST_DIR/bridge-hook.sh" \
  "$DEST_DIR/bridge-pretool-hook.sh" \
  "$DEST_DIR/bridge-notify-hook.sh" \
  "$DEST_DIR/bridge-router.sh" \
  "$DEST_DIR/bridge-doctor.sh" \
  "$DEST_DIR/lib-bridge.sh" \
  "$DEST_DIR/claude-bridge"
do
  rm -f "$f"
done
echo "Removed installed scripts under $DEST_DIR"

# Best-effort: remove a previously-created symlink in the user's bin dir.
if [ -L "$LINK_DIR/claude-bridge" ]; then
  rm -f "$LINK_DIR/claude-bridge"
  echo "Removed symlink $LINK_DIR/claude-bridge"
fi

cat <<EOF

Bridge folders and logs were left in place. To purge them:
  rm -rf "\$HOME/.claude-bridge"
  rm -f  "\$HOME/Library/Logs/claude-bridge.log"   # macOS
  rm -f  "\$HOME/.claude-bridge/claude-bridge.log" # Linux/WSL
  rm -rf "\$CLAUDE_BRIDGE_DIR"                     # if you set one
EOF
