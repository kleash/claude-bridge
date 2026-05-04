#!/usr/bin/env bash
# claude-bridge uninstaller. Removes the Stop hook entry from
# ~/.claude/settings.json and deletes ~/.claude-bridge/bridge-hook.sh.
# Leaves the bridge folder (inbox/outbox/archive) and logs alone.

set -euo pipefail

DEST="$HOME/.claude-bridge/bridge-hook.sh"
SETTINGS="$HOME/.claude/settings.json"

if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
  cp "$SETTINGS" "$SETTINGS.pre-uninstall.bak"
  TMP="$(mktemp)"
  jq --arg cmd "$DEST" '
    if .hooks.Stop then
      .hooks.Stop = (
        .hooks.Stop
        | map(.hooks |= map(select(.command != $cmd)))
        | map(select((.hooks // []) | length > 0))
      )
      | if (.hooks.Stop | length) == 0 then del(.hooks.Stop) else . end
      | if (.hooks // {} | length) == 0 then del(.hooks) else . end
    else . end
  ' "$SETTINGS" >"$TMP" && mv "$TMP" "$SETTINGS"
  echo "Removed Stop hook entry from $SETTINGS"
fi

rm -f "$DEST"
echo "Removed $DEST"
echo
echo "Bridge folders and logs were left in place. To purge them:"
echo "  rm -rf \"\$HOME/.claude-bridge\""
echo "  rm -f \"\$HOME/Library/Logs/claude-bridge.log\"   # macOS"
