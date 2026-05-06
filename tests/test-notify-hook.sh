#!/usr/bin/env bash
# Verify the Notification hook writes a notification-*.md file and updates
# the per-session status without overwriting more-specific values.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/bin/bridge-notify-hook.sh"

TMP="$(mktemp -d -t claude-bridge-notify-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

BRIDGE="$TMP/bridge"
mkdir -p "$BRIDGE"
touch "$BRIDGE/.enabled"

SID="sess-$$-notify"
INPUT=$(jq -nc --arg sid "$SID" \
  '{session_id:$sid, transcript_path:"", message:"Claude is waiting for your input"}')

printf '%s' "$INPUT" | \
  CLAUDE_BRIDGE_DIR="$BRIDGE" \
  CLAUDE_BRIDGE_LOG="$TMP/log" \
  bash "$HOOK"

# A notification-<sid>-<ts>.md file should exist.
ls "$BRIDGE/outbox"/notification-${SID}-*.md >/dev/null 2>&1 \
  || { echo "FAIL: no notification file written"; ls -laR "$BRIDGE"; exit 1; }
grep -q "Claude is waiting for your input" "$BRIDGE"/outbox/notification-${SID}-*.md \
  || { echo "FAIL: message body missing"; exit 1; }
[ -f "$BRIDGE/sessions/$SID/status" ] || { echo "FAIL: status file not created"; exit 1; }
[ -f "$BRIDGE/outbox/INDEX.md" ]      || { echo "FAIL: INDEX.md not generated"; exit 1; }
echo "case 1 PASS: notification written + INDEX rebuilt"

# --- Case 2: notify must NOT clobber a more-specific status ----------------
SID2="sess-$$-notify-keepstatus"
mkdir -p "$BRIDGE/sessions/$SID2"
printf 'awaiting-approval\n' > "$BRIDGE/sessions/$SID2/status"

INPUT2=$(jq -nc --arg sid "$SID2" \
  '{session_id:$sid, transcript_path:"", message:"hello again"}')

printf '%s' "$INPUT2" | \
  CLAUDE_BRIDGE_DIR="$BRIDGE" \
  CLAUDE_BRIDGE_LOG="$TMP/log" \
  bash "$HOOK"

GOT="$(cat "$BRIDGE/sessions/$SID2/status")"
[ "$GOT" = "awaiting-approval" ] || { echo "FAIL: notify clobbered status; got '$GOT'"; exit 1; }
echo "case 2 PASS: existing 'awaiting-approval' preserved"

# --- Case 3: kill-switch -> noop --------------------------------------------
SID3="sess-$$-notify-disabled"
rm -f "$BRIDGE/.enabled"
INPUT3=$(jq -nc --arg sid "$SID3" \
  '{session_id:$sid, transcript_path:"", message:"shouldnt show"}')
printf '%s' "$INPUT3" | \
  CLAUDE_BRIDGE_DIR="$BRIDGE" \
  CLAUDE_BRIDGE_LOG="$TMP/log" \
  bash "$HOOK"
[ ! -e "$BRIDGE/outbox/notification-${SID3}"* ] 2>/dev/null \
  || { echo "FAIL: notification fired despite kill-switch"; exit 1; }
echo "case 3 PASS: kill-switch honored"

echo "ALL NOTIFY HOOK TESTS PASSED"
