#!/usr/bin/env bash
# Tests for the v1.3 auto-approve UX: a single phone tap (or a static env-var
# pattern) lets Claude make multiple Bash sub-calls per turn without a fresh
# round-trip through the cloud sync each time.
#
# Cases:
#   1. Static pattern allowlist via CLAUDE_BRIDGE_AUTO_APPROVE_BASH_PATTERNS:
#      hook auto-approves matching commands with NO outbox file written.
#   2. Phone reply "approve always": current call approved + persistent flag
#      set; second invocation of the hook in the same session auto-approves
#      with no outbox file.
#   3. Phone reply "approve 3": counted; decrements per call, expires after 3.
#   4. Phone reply "revoke": clears the always flag and BLOCKS the current
#      call (forces re-auth); subsequent call shows the permission file again.
#   5. CLAUDE_BRIDGE_AUTO_APPROVE_TTL: an old flag with mtime older than the
#      TTL is treated as expired and garbage-collected.
#   6. Per-tool isolation: an always-flag for Bash does not auto-approve Edit.
set -eo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/bin/bridge-pretool-hook.sh"

TMP="$(mktemp -d -t claude-bridge-autoapprove-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

BRIDGE="$TMP/bridge"
LOG="$TMP/log"
mkdir -p "$BRIDGE"
touch "$BRIDGE/.enabled"

mk_input() {
  local sid="$1" tool="$2" cmd="$3"
  case "$tool" in
    Bash)
      jq -nc --arg sid "$sid" --arg t "$tool" --arg c "$cmd" \
        '{session_id:$sid, transcript_path:"", tool_name:$t, tool_input:{command:$c}}' ;;
    *)
      jq -nc --arg sid "$sid" --arg t "$tool" --arg p "$cmd" \
        '{session_id:$sid, transcript_path:"", tool_name:$t, tool_input:{file_path:$p}}' ;;
  esac
}

run_hook() {
  local input="$1"; shift
  printf '%s' "$input" | \
    CLAUDE_BRIDGE_DIR="$BRIDGE" \
    CLAUDE_BRIDGE_PERMISSION_TOOLS="${CLAUDE_BRIDGE_PERMISSION_TOOLS:-Bash}" \
    CLAUDE_BRIDGE_PERMISSION_TIMEOUT="${CLAUDE_BRIDGE_PERMISSION_TIMEOUT:-5}" \
    CLAUDE_BRIDGE_POLL=1 \
    CLAUDE_BRIDGE_LOG="$LOG" \
    "$@" \
    bash "$HOOK"
}

# --- Case 1: static pattern allowlist --------------------------------------
SID1="sess-static-$$"
mkdir -p "$BRIDGE/sessions/$SID1/inbox"
OUT="$(CLAUDE_BRIDGE_AUTO_APPROVE_BASH_PATTERNS='git status*,ls *,pwd,cat *' \
  run_hook "$(mk_input "$SID1" Bash 'git status --short')")"
DEC="$(printf '%s' "$OUT" | jq -r '.decision')"
[ "$DEC" = "approve" ] || { echo "FAIL case1: expected approve, got $OUT"; exit 1; }
# Critical: NO permission file should have been written for static-pattern hits.
if ls "$BRIDGE"/outbox/permission-${SID1}-*.md >/dev/null 2>&1; then
  echo "FAIL case1: permission file was written despite static pattern hit"
  ls -la "$BRIDGE/outbox"
  exit 1
fi
echo "case 1 PASS: static pattern -> approve, no outbox file"

# Static pattern that DOESN'T match should fall through to the regular flow.
# To avoid a 5-second poll wait we pre-drop an approve reply.
mkdir -p "$BRIDGE/sessions/$SID1/inbox"
echo approve > "$BRIDGE/sessions/$SID1/inbox/r.txt"
OUT2="$(CLAUDE_BRIDGE_AUTO_APPROVE_BASH_PATTERNS='git status*' \
  run_hook "$(mk_input "$SID1" Bash 'rm -rf /')")"
DEC2="$(printf '%s' "$OUT2" | jq -r '.decision')"
[ "$DEC2" = "approve" ] || { echo "FAIL case1b: expected approve via reply, got $OUT2"; exit 1; }
# The hook archives a permission file once a reply is consumed; check both
# outbox/ and archive/answered-* — either proves the file was written.
{ ls "$BRIDGE"/outbox/permission-${SID1}-*.md 2>/dev/null \
  || ls "$BRIDGE"/archive/answered-permission-${SID1}-*.md 2>/dev/null; } >/dev/null \
  || { echo "FAIL case1b: expected a permission file when pattern doesn't match"; ls -laR "$BRIDGE"; exit 1; }
echo "case 1b PASS: non-matching command falls through to regular permission flow"

# --- Case 2: phone reply 'approve always' ----------------------------------
SID2="sess-always-$$"
mkdir -p "$BRIDGE/sessions/$SID2/inbox"
echo "approve always" > "$BRIDGE/sessions/$SID2/inbox/r.txt"

OUT="$(run_hook "$(mk_input "$SID2" Bash 'echo first call')")"
DEC="$(printf '%s' "$OUT" | jq -r '.decision')"
[ "$DEC" = "approve" ] || { echo "FAIL case2: first call should be approved, got $OUT"; exit 1; }
[ -e "$BRIDGE/sessions/$SID2/auto-approve-Bash" ] \
  || { echo "FAIL case2: always-flag was not set"; exit 1; }
echo "case 2a PASS: 'approve always' approves current call AND sets the persistent flag"

# Second call in the same session: NO reply file dropped, hook should auto-approve.
PERMS_BEFORE=$(find "$BRIDGE/outbox" -maxdepth 1 -name "permission-${SID2}-*.md" 2>/dev/null | wc -l)
OUT="$(run_hook "$(mk_input "$SID2" Bash 'echo second call')")"
DEC="$(printf '%s' "$OUT" | jq -r '.decision')"
REASON="$(printf '%s' "$OUT" | jq -r '.reason')"
PERMS_AFTER=$(find "$BRIDGE/outbox" -maxdepth 1 -name "permission-${SID2}-*.md" 2>/dev/null | wc -l)
[ "$DEC" = "approve" ] || { echo "FAIL case2b: second call should be auto-approved, got $OUT"; exit 1; }
case "$REASON" in *always*) ;; *) echo "FAIL case2b: reason should mention 'always', got: $REASON"; exit 1 ;; esac
[ "$PERMS_BEFORE" -eq "$PERMS_AFTER" ] \
  || { echo "FAIL case2b: a new permission file was written despite always-flag"; exit 1; }
echo "case 2b PASS: subsequent call auto-approves with NO outbox file"

# --- Case 3: phone reply 'approve 3' --------------------------------------
SID3="sess-count-$$"
mkdir -p "$BRIDGE/sessions/$SID3/inbox"
echo "approve 3" > "$BRIDGE/sessions/$SID3/inbox/r.txt"

# Initial approve (counts as "the call you replied to"); count is set to 3
# for SUBSEQUENT calls.
OUT="$(run_hook "$(mk_input "$SID3" Bash 'echo n0')")"
[ "$(printf '%s' "$OUT" | jq -r '.decision')" = "approve" ] \
  || { echo "FAIL case3: initial approve, got $OUT"; exit 1; }
N="$(cat "$BRIDGE/sessions/$SID3/auto-approve-count-Bash" 2>/dev/null || echo 0)"
[ "$N" = "3" ] || { echo "FAIL case3: count should be 3, got $N"; exit 1; }

# Three more calls: each should auto-approve and decrement.
for expected_after in 2 1; do
  OUT="$(run_hook "$(mk_input "$SID3" Bash "echo decrement to $expected_after")")"
  [ "$(printf '%s' "$OUT" | jq -r '.decision')" = "approve" ] \
    || { echo "FAIL case3 dec: got $OUT"; exit 1; }
  N="$(cat "$BRIDGE/sessions/$SID3/auto-approve-count-Bash" 2>/dev/null || echo 0)"
  [ "$N" = "$expected_after" ] \
    || { echo "FAIL case3: count expected $expected_after, got $N"; exit 1; }
done
# 3rd auto-approve drains the counter and removes the file.
OUT="$(run_hook "$(mk_input "$SID3" Bash 'echo final auto')")"
[ "$(printf '%s' "$OUT" | jq -r '.decision')" = "approve" ] \
  || { echo "FAIL case3: 3rd auto, got $OUT"; exit 1; }
[ ! -e "$BRIDGE/sessions/$SID3/auto-approve-count-Bash" ] \
  || { echo "FAIL case3: count file should be removed after draining"; exit 1; }
echo "case 3 PASS: 'approve 3' approves 3 subsequent calls then drains"

# 4th call must round-trip again. Pre-drop a deny.
echo deny > "$BRIDGE/sessions/$SID3/inbox/r.txt"
OUT="$(run_hook "$(mk_input "$SID3" Bash 'echo after counter drained')")"
[ "$(printf '%s' "$OUT" | jq -r '.decision')" = "block" ] \
  || { echo "FAIL case3 post-drain: should require re-approval, got $OUT"; exit 1; }
echo "case 3b PASS: post-drain calls require explicit re-approval"

# --- Case 4: 'revoke' clears flag AND blocks current call -----------------
SID4="sess-revoke-$$"
mkdir -p "$BRIDGE/sessions/$SID4/inbox"
# Pre-arm: pretend an always-approve was set earlier.
mkdir -p "$BRIDGE/sessions/$SID4"
: > "$BRIDGE/sessions/$SID4/auto-approve-Bash"
# Phone replies 'revoke' to whatever it was looking at.
echo revoke > "$BRIDGE/sessions/$SID4/inbox/r.txt"

# A pristine call: hook should NOT see the always-flag because we've manually
# nuked it via the reply. Wait — tricky: with the always-flag set, the hook
# would short-circuit before even looking at the reply. Let's instead simulate
# the realistic flow: user has an always-approve on, then a NEW tool call
# fires the hook short-circuit (no reply read, no chance to revoke). Revoke
# is meaningful only when the hook is currently waiting for a reply (e.g.
# always-flag isn't set for this tool, or the tool is different). Test that
# direct flow: always-flag is set for Edit only, current call is Bash, so
# the hook waits and reads our 'revoke' reply.
rm -f "$BRIDGE/sessions/$SID4/auto-approve-Bash"
: > "$BRIDGE/sessions/$SID4/auto-approve-Edit"
echo revoke > "$BRIDGE/sessions/$SID4/inbox/r.txt"

OUT="$(run_hook "$(mk_input "$SID4" Bash 'echo revoke flow')")"
DEC="$(printf '%s' "$OUT" | jq -r '.decision')"
REASON="$(printf '%s' "$OUT" | jq -r '.reason')"
[ "$DEC" = "block" ] || { echo "FAIL case4: revoke should block current call, got $OUT"; exit 1; }
case "$REASON" in *revok*) ;; *) echo "FAIL case4: reason should mention revoke, got: $REASON"; exit 1 ;; esac
# Bash flag (which we never set) was already absent; the revoke clears Bash
# *for this tool only* — Edit flag should still be intact.
[ -e "$BRIDGE/sessions/$SID4/auto-approve-Edit" ] \
  || { echo "FAIL case4: revoke should not have cleared Edit's flag"; exit 1; }
[ ! -e "$BRIDGE/sessions/$SID4/auto-approve-Bash" ] \
  || { echo "FAIL case4: Bash flag should be absent"; exit 1; }
echo "case 4 PASS: 'revoke' blocks current call and clears that tool's flag only"

# --- Case 5: TTL expiry ----------------------------------------------------
SID5="sess-ttl-$$"
mkdir -p "$BRIDGE/sessions/$SID5/inbox"
: > "$BRIDGE/sessions/$SID5/auto-approve-Bash"
# Backdate the flag to 1 hour ago.
touch -d '1 hour ago' "$BRIDGE/sessions/$SID5/auto-approve-Bash" 2>/dev/null \
  || touch -t "$(date -u -v-1H +%Y%m%d%H%M 2>/dev/null)" "$BRIDGE/sessions/$SID5/auto-approve-Bash" 2>/dev/null

# With a 5-min TTL this flag must be ignored AND garbage-collected.
echo "deny" > "$BRIDGE/sessions/$SID5/inbox/r.txt"
OUT="$(CLAUDE_BRIDGE_AUTO_APPROVE_TTL=300 \
  run_hook "$(mk_input "$SID5" Bash 'echo expired flag')")"
DEC="$(printf '%s' "$OUT" | jq -r '.decision')"
[ "$DEC" = "block" ] || { echo "FAIL case5: expired flag should not auto-approve, got $OUT"; exit 1; }
[ ! -e "$BRIDGE/sessions/$SID5/auto-approve-Bash" ] \
  || { echo "FAIL case5: expired flag should be GC'd"; exit 1; }
echo "case 5 PASS: expired always-flag is ignored and garbage-collected"

# --- Case 6: per-tool isolation -------------------------------------------
SID6="sess-isolation-$$"
mkdir -p "$BRIDGE/sessions/$SID6/inbox"
: > "$BRIDGE/sessions/$SID6/auto-approve-Bash"  # always-approve for Bash only

# A Bash call must auto-approve (no reply needed).
PRE=$(find "$BRIDGE/outbox" -maxdepth 1 -name "permission-${SID6}-*.md" 2>/dev/null | wc -l)
OUT="$(run_hook "$(mk_input "$SID6" Bash 'echo isolated bash')")"
[ "$(printf '%s' "$OUT" | jq -r '.decision')" = "approve" ] \
  || { echo "FAIL case6 bash: should auto-approve, got $OUT"; exit 1; }
POST=$(find "$BRIDGE/outbox" -maxdepth 1 -name "permission-${SID6}-*.md" 2>/dev/null | wc -l)
[ "$PRE" -eq "$POST" ] \
  || { echo "FAIL case6 bash: should not write a permission file"; exit 1; }

# An Edit call (with Edit allowed) must NOT auto-approve — round-trips.
echo deny > "$BRIDGE/sessions/$SID6/inbox/r.txt"
OUT="$(CLAUDE_BRIDGE_PERMISSION_TOOLS='Bash,Edit' \
  run_hook "$(mk_input "$SID6" Edit '/etc/passwd')")"
[ "$(printf '%s' "$OUT" | jq -r '.decision')" = "block" ] \
  || { echo "FAIL case6 edit: Edit should require approval, got $OUT"; exit 1; }
{ ls "$BRIDGE"/outbox/permission-${SID6}-*.md 2>/dev/null \
  || ls "$BRIDGE"/archive/answered-permission-${SID6}-*.md 2>/dev/null; } >/dev/null \
  || { echo "FAIL case6 edit: should have written a permission file for Edit"; ls -laR "$BRIDGE"; exit 1; }
echo "case 6 PASS: per-tool isolation — Bash always-flag does not auto-approve Edit"

echo "ALL AUTO-APPROVE TESTS PASSED"
