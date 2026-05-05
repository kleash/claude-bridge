#!/usr/bin/env bash
# Verify the Stop hook prefers a per-session inbox subfolder, and falls
# back to the top-level inbox when no per-session reply exists.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/bin/bridge-hook.sh"

TMP="$(mktemp -d -t claude-bridge-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

BRIDGE="$TMP/bridge"
mkdir -p "$BRIDGE"
touch "$BRIDGE/.enabled"

SID="sess-$$-A"
mkdir -p "$BRIDGE/sessions/$SID/inbox" "$BRIDGE/inbox"

# Build a fake transcript JSONL with one assistant text message.
TRANSCRIPT="$TMP/transcript.jsonl"
cat > "$TRANSCRIPT" <<'EOF'
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hello from test"}]}}
EOF

# --- Case 1: per-session reply present; top-level reply also present ---------
# The session-scoped one must win.
printf 'session-reply\n' > "$BRIDGE/sessions/$SID/inbox/r.md"
sleep 0.05
printf 'top-level-reply\n' > "$BRIDGE/inbox/r.md"

INPUT=$(jq -nc --arg sid "$SID" --arg t "$TRANSCRIPT" \
  '{session_id:$sid, transcript_path:$t, stop_hook_active:false}')

OUT="$(printf '%s' "$INPUT" | \
  CLAUDE_BRIDGE_DIR="$BRIDGE" \
  CLAUDE_BRIDGE_TIMEOUT=5 \
  CLAUDE_BRIDGE_POLL=1 \
  bash "$HOOK")"

REASON="$(printf '%s' "$OUT" | jq -r '.reason')"
DECISION="$(printf '%s' "$OUT" | jq -r '.decision')"

[ "$DECISION" = "block" ] || { echo "FAIL: decision=$DECISION"; exit 1; }
case "$REASON" in
  *session-reply*) ;;
  *) echo "FAIL: expected session-reply, got: $REASON"; exit 1 ;;
esac

# Per-session file must have been archived (moved out of subfolder).
[ ! -e "$BRIDGE/sessions/$SID/inbox/r.md" ] || { echo "FAIL: per-session reply not archived"; exit 1; }
# Top-level file should still be present (untouched).
[ -e "$BRIDGE/inbox/r.md" ] || { echo "FAIL: top-level reply was unexpectedly consumed"; exit 1; }

echo "case 1 PASS: per-session subfolder takes priority"

# --- Case 2: only top-level reply present; hook should fall back -------------
SID2="sess-$$-B"
mkdir -p "$BRIDGE/sessions/$SID2/inbox"
# (top-level still has the file from case 1)

INPUT2=$(jq -nc --arg sid "$SID2" --arg t "$TRANSCRIPT" \
  '{session_id:$sid, transcript_path:$t, stop_hook_active:false}')

OUT2="$(printf '%s' "$INPUT2" | \
  CLAUDE_BRIDGE_DIR="$BRIDGE" \
  CLAUDE_BRIDGE_TIMEOUT=5 \
  CLAUDE_BRIDGE_POLL=1 \
  bash "$HOOK")"

REASON2="$(printf '%s' "$OUT2" | jq -r '.reason')"
case "$REASON2" in
  *top-level-reply*) ;;
  *) echo "FAIL: expected top-level fallback, got: $REASON2"; exit 1 ;;
esac

[ ! -e "$BRIDGE/inbox/r.md" ] || { echo "FAIL: top-level reply not archived after consume"; exit 1; }
echo "case 2 PASS: falls back to top-level inbox when session subfolder empty"

# --- Case 3: stop_hook_active=true must short-circuit ------------------------
INPUT3=$(jq -nc --arg sid "$SID" --arg t "$TRANSCRIPT" \
  '{session_id:$sid, transcript_path:$t, stop_hook_active:true}')

OUT3="$(printf '%s' "$INPUT3" | \
  CLAUDE_BRIDGE_DIR="$BRIDGE" \
  CLAUDE_BRIDGE_TIMEOUT=5 \
  bash "$HOOK")"

[ -z "$OUT3" ] || { echo "FAIL: hook should be silent when stop_hook_active; got: $OUT3"; exit 1; }
echo "case 3 PASS: loop-prevention honored"

echo "ALL HOOK TESTS PASSED"
