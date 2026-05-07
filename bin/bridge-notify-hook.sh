#!/usr/bin/env bash
# claude-bridge: a Notification hook for Claude Code. Informational only —
# this hook does not gate anything. It exists so the phone user gets a
# heads-up when Claude wants attention for any reason that ISN'T already
# covered by the Stop hook (idle prompt, generic reminder).
#
# Stdin (from Claude Code) is JSON containing at least:
#   { "session_id": "...", "transcript_path": "...", "message": "..." }
#
# This hook writes outbox/notification-<sid>-<ts>.md and updates the INDEX.
# It does NOT poll for a reply — phone replies, when relevant, are handled
# by the Stop hook (for end-of-turn) or PreToolUse hook (for tool gates).
#
# License: MIT

set -u

default_log_path() {
  case "$(uname -s)" in
    Darwin) printf '%s/Library/Logs/claude-bridge.log' "$HOME" ;;
    *)      printf '%s/.claude-bridge/claude-bridge.log' "$HOME" ;;
  esac
}

LOG="${CLAUDE_BRIDGE_LOG:-$(default_log_path)}"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
log() { printf '[%s] notify: %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"; }

# shellcheck source=lib-bridge.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-bridge.sh"

if ! command -v jq >/dev/null 2>&1; then
  log "ERROR: jq not found in PATH"
  exit 0
fi

INPUT="$(cat)"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"')"
MESSAGE="$(printf '%s' "$INPUT"    | jq -r '.message    // ""')"

BRIDGE_DIR="$(lb_resolve_bridge_dir)"
if [ ! -f "$BRIDGE_DIR/.enabled" ]; then
  log "session=$SESSION_ID disabled (no $BRIDGE_DIR/.enabled)"
  exit 0
fi

OUTBOX="$BRIDGE_DIR/outbox"
mkdir -p "$OUTBOX" "$BRIDGE_DIR/sessions/$SESSION_ID"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_FILE="$OUTBOX/notification-${SESSION_ID}-${TS}.md"
HOST="$(hostname 2>/dev/null || echo laptop)"

TMP="$OUT_FILE.tmp"
{
  printf '%s\n\n' "# Notification — $HOST"
  printf '%s\n' "- session: \`$SESSION_ID\`"
  printf '%s\n\n' "- timestamp: \`$TS\`"
  printf '%s\n\n' '---'
  printf '%s\n' "${MESSAGE:-Claude is waiting for your input.}"
} >"$TMP"
mv "$TMP" "$OUT_FILE"
log "session=$SESSION_ID wrote $OUT_FILE"

# Don't overwrite a more-specific status (waiting / awaiting-approval). Only
# nudge a fresh session out of "idle" so it appears in the INDEX.
CUR="$(lb_get_status "$BRIDGE_DIR" "$SESSION_ID")"
if [ "$CUR" = "idle" ] || [ -z "$CUR" ]; then
  lb_set_status "$BRIDGE_DIR" "$SESSION_ID" "waiting" "${MESSAGE:-notification}"
fi
lb_index_rebuild "$BRIDGE_DIR" 2>/dev/null || true
exit 0
