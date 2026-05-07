#!/usr/bin/env bash
# Verify the PreToolUse hook gates tool calls correctly:
#  - tool not in CLAUDE_BRIDGE_PERMISSION_TOOLS -> passthrough (no JSON, exit 0)
#  - reply "approve"            -> {"decision":"approve",...}
#  - reply "deny: looks risky"  -> {"decision":"block","reason":"looks risky"}
#  - timeout                    -> {"decision":"block","reason":"timed out..."}
#  - .cancel sentinel           -> passthrough (no JSON, exit 0)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/bin/bridge-pretool-hook.sh"

TMP="$(mktemp -d -t claude-bridge-pretool-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

BRIDGE="$TMP/bridge"
mkdir -p "$BRIDGE"
touch "$BRIDGE/.enabled"

LOG="$TMP/log"
SID="sess-$$-pre"

# Helper that builds the standard PreToolUse stdin shape.
make_input() {
  local tool="$1" cmd="$2"
  jq -nc --arg sid "$SID" --arg tn "$tool" --arg c "$cmd" \
    '{session_id:$sid, transcript_path:"", tool_name:$tn, tool_input:{command:$c}}'
}

# --- Case 1: tool not in allowlist -> passthrough ---------------------------
OUT="$(make_input Bash "echo hi" | \
  CLAUDE_BRIDGE_DIR="$BRIDGE" \
  CLAUDE_BRIDGE_PERMISSION_TOOLS="" \
  CLAUDE_BRIDGE_PERMISSION_TIMEOUT=2 \
  CLAUDE_BRIDGE_POLL=1 \
  CLAUDE_BRIDGE_LOG="$LOG" \
  bash "$HOOK" 2>&1)"
[ -z "$OUT" ] || { echo "FAIL: empty allowlist should be silent; got: $OUT"; exit 1; }
echo "case 1 PASS: empty allowlist -> passthrough"

OUT="$(make_input Read "/etc/passwd" | \
  CLAUDE_BRIDGE_DIR="$BRIDGE" \
  CLAUDE_BRIDGE_PERMISSION_TOOLS="Bash,Write" \
  CLAUDE_BRIDGE_PERMISSION_TIMEOUT=2 \
  CLAUDE_BRIDGE_POLL=1 \
  CLAUDE_BRIDGE_LOG="$LOG" \
  bash "$HOOK" 2>&1)"
[ -z "$OUT" ] || { echo "FAIL: tool not in allowlist should be silent; got: $OUT"; exit 1; }
echo "case 2 PASS: tool outside allowlist -> passthrough"

# --- Case 3: approve --------------------------------------------------------
mkdir -p "$BRIDGE/sessions/$SID/inbox"
printf 'approve\n' > "$BRIDGE/sessions/$SID/inbox/r.txt"

OUT="$(make_input Bash "rm -rf build/" | \
  CLAUDE_BRIDGE_DIR="$BRIDGE" \
  CLAUDE_BRIDGE_PERMISSION_TOOLS="Bash" \
  CLAUDE_BRIDGE_PERMISSION_TIMEOUT=5 \
  CLAUDE_BRIDGE_POLL=1 \
  CLAUDE_BRIDGE_LOG="$LOG" \
  bash "$HOOK")"
DEC="$(printf '%s' "$OUT" | jq -r '.decision')"
[ "$DEC" = "approve" ] || { echo "FAIL: expected approve, got: $OUT"; exit 1; }
# The hook archives the permission file once a reply comes in (so the phone
# doesn't keep seeing a "tap me!" prompt for a call that's already been
# resolved). So accept the file in EITHER outbox/ (in-flight) or
# archive/answered-* (after-reply).
{ ls "$BRIDGE/outbox"/permission-${SID}-*.md 2>/dev/null \
  || ls "$BRIDGE/archive"/answered-permission-${SID}-*.md 2>/dev/null; } >/dev/null \
  || { echo "FAIL: no permission file written or archived"; ls -laR "$BRIDGE"; exit 1; }
[ -f "$BRIDGE/sessions/$SID/status" ] || { echo "FAIL: status file missing"; exit 1; }
[ -f "$BRIDGE/outbox/INDEX.md" ]      || { echo "FAIL: INDEX.md not generated"; exit 1; }
echo "case 3 PASS: 'approve' -> {decision:approve}, outbox + INDEX written"

# --- Case 4: deny with custom reason ----------------------------------------
SID2="sess-$$-pre-deny"
mkdir -p "$BRIDGE/sessions/$SID2/inbox"
printf 'deny: looks risky\n' > "$BRIDGE/sessions/$SID2/inbox/r.txt"

OUT="$(jq -nc --arg sid "$SID2" \
    '{session_id:$sid, transcript_path:"", tool_name:"Bash", tool_input:{command:"sudo dd if=/dev/zero of=/dev/sda"}}' | \
  CLAUDE_BRIDGE_DIR="$BRIDGE" \
  CLAUDE_BRIDGE_PERMISSION_TOOLS="Bash" \
  CLAUDE_BRIDGE_PERMISSION_TIMEOUT=5 \
  CLAUDE_BRIDGE_POLL=1 \
  CLAUDE_BRIDGE_LOG="$LOG" \
  bash "$HOOK")"
DEC="$(printf '%s' "$OUT" | jq -r '.decision')"
REASON="$(printf '%s' "$OUT" | jq -r '.reason')"
[ "$DEC" = "block" ] || { echo "FAIL: expected block, got: $OUT"; exit 1; }
case "$REASON" in
  *"looks risky"*) ;;
  *) echo "FAIL: expected 'looks risky' reason, got: $REASON"; exit 1 ;;
esac
echo "case 4 PASS: 'deny: looks risky' -> {decision:block, reason:looks risky}"

# --- Case 5: free-form text -> block with text as reason --------------------
SID3="sess-$$-pre-free"
mkdir -p "$BRIDGE/sessions/$SID3/inbox"
printf "no, instead delete only build/tmp\n" > "$BRIDGE/sessions/$SID3/inbox/r.txt"

OUT="$(jq -nc --arg sid "$SID3" \
    '{session_id:$sid, transcript_path:"", tool_name:"Bash", tool_input:{command:"rm -rf build/"}}' | \
  CLAUDE_BRIDGE_DIR="$BRIDGE" \
  CLAUDE_BRIDGE_PERMISSION_TOOLS="Bash" \
  CLAUDE_BRIDGE_PERMISSION_TIMEOUT=5 \
  CLAUDE_BRIDGE_POLL=1 \
  CLAUDE_BRIDGE_LOG="$LOG" \
  bash "$HOOK")"
DEC="$(printf '%s' "$OUT" | jq -r '.decision')"
REASON="$(printf '%s' "$OUT" | jq -r '.reason')"
[ "$DEC" = "block" ] || { echo "FAIL: expected block, got: $OUT"; exit 1; }
case "$REASON" in
  *"instead delete only build/tmp"*) ;;
  *) echo "FAIL: expected free-form text in reason, got: $REASON"; exit 1 ;;
esac
echo "case 5 PASS: free-form reply -> block with that text as reason"

# --- Case 6: timeout -> block with timeout reason ---------------------------
SID4="sess-$$-pre-timeout"
mkdir -p "$BRIDGE/sessions/$SID4/inbox"

OUT="$(jq -nc --arg sid "$SID4" \
    '{session_id:$sid, transcript_path:"", tool_name:"Bash", tool_input:{command:"echo lonely"}}' | \
  CLAUDE_BRIDGE_DIR="$BRIDGE" \
  CLAUDE_BRIDGE_PERMISSION_TOOLS="Bash" \
  CLAUDE_BRIDGE_PERMISSION_TIMEOUT=2 \
  CLAUDE_BRIDGE_POLL=1 \
  CLAUDE_BRIDGE_LOG="$LOG" \
  bash "$HOOK")"
DEC="$(printf '%s' "$OUT" | jq -r '.decision')"
REASON="$(printf '%s' "$OUT" | jq -r '.reason')"
[ "$DEC" = "block" ] || { echo "FAIL: expected block on timeout, got: $OUT"; exit 1; }
case "$REASON" in
  *"timed out"*) ;;
  *) echo "FAIL: expected 'timed out' reason, got: $REASON"; exit 1 ;;
esac
echo "case 6 PASS: no reply -> default-deny with timeout reason"

# --- Case 7: timeout with passthrough -> exit silently ---------------------
SID5="sess-$$-pre-pass"
mkdir -p "$BRIDGE/sessions/$SID5/inbox"

OUT="$(jq -nc --arg sid "$SID5" \
    '{session_id:$sid, transcript_path:"", tool_name:"Bash", tool_input:{command:"echo also lonely"}}' | \
  CLAUDE_BRIDGE_DIR="$BRIDGE" \
  CLAUDE_BRIDGE_PERMISSION_TOOLS="Bash" \
  CLAUDE_BRIDGE_PERMISSION_TIMEOUT=2 \
  CLAUDE_BRIDGE_POLL=1 \
  CLAUDE_BRIDGE_PERMISSION_DEFAULT="passthrough" \
  CLAUDE_BRIDGE_LOG="$LOG" \
  bash "$HOOK")"
[ -z "$OUT" ] || { echo "FAIL: passthrough mode should be silent on timeout; got: $OUT"; exit 1; }
echo "case 7 PASS: timeout + DEFAULT=passthrough -> silent passthrough"

# --- Case 8: cancel sentinel -> passthrough ---------------------------------
SID6="sess-$$-pre-cancel"
mkdir -p "$BRIDGE/sessions/$SID6/inbox"
# Drop the cancel sentinel before the hook starts polling
: > "$BRIDGE/sessions/$SID6/inbox/.cancel"

OUT="$(jq -nc --arg sid "$SID6" \
    '{session_id:$sid, transcript_path:"", tool_name:"Bash", tool_input:{command:"echo go"}}' | \
  CLAUDE_BRIDGE_DIR="$BRIDGE" \
  CLAUDE_BRIDGE_PERMISSION_TOOLS="Bash" \
  CLAUDE_BRIDGE_PERMISSION_TIMEOUT=5 \
  CLAUDE_BRIDGE_POLL=1 \
  CLAUDE_BRIDGE_LOG="$LOG" \
  bash "$HOOK")"
[ -z "$OUT" ] || { echo "FAIL: .cancel should silence the hook; got: $OUT"; exit 1; }
[ ! -e "$BRIDGE/sessions/$SID6/inbox/.cancel" ] || { echo "FAIL: .cancel should be consumed"; exit 1; }
echo "case 8 PASS: .cancel sentinel -> passthrough"

echo "ALL PRETOOL HOOK TESTS PASSED"
