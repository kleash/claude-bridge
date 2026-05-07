#!/usr/bin/env bash
# Real-world end-to-end proof that a single phone tap of "approve always"
# covers an entire multi-Bash turn — the v1.3 fix for "OneDrive sync makes
# replying N times per turn miserable".
#
# Setup: register only PreToolUse, gate Bash, ask Claude to do something
# that requires *multiple* Bash sub-calls (a tiny multi-step shell pipeline).
# A one-shot phone-replier drops "approve always" exactly ONCE and never
# replies again. We then assert:
#   - Claude finished the turn successfully (no permission_denials).
#   - The bridge log shows exactly ONE permission file written, but
#     MULTIPLE auto-approve(always) entries — one per subsequent Bash call.
set -eo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/bin/bridge-pretool-hook.sh"

if ! command -v claude >/dev/null 2>&1; then
  echo "SKIP: claude CLI not on PATH"; exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq required"; exit 1
fi

WORKDIR="$(mktemp -d -t claude-bridge-e2e-autopilot.XXXXXX)"
WATCHDOG_PIDS=()
cleanup() {
  for pid in "${WATCHDOG_PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

BRIDGE="$WORKDIR/bridge"
LOG="$WORKDIR/claude-bridge.log"
mkdir -p "$BRIDGE"/{inbox,outbox,archive,sessions}
touch "$BRIDGE/.enabled"

SETTINGS_JSON="$(jq -nc --arg cmd "$HOOK" \
  '{hooks:{PreToolUse:[{matcher:"",hooks:[{type:"command",command:$cmd}]}]}}')"

export CLAUDE_BRIDGE_DIR="$BRIDGE"
export CLAUDE_BRIDGE_PERMISSION_TOOLS="Bash"
export CLAUDE_BRIDGE_PERMISSION_TIMEOUT=20
export CLAUDE_BRIDGE_POLL=1
export CLAUDE_BRIDGE_LOG="$LOG"
# Generous TTL so the always-flag stays valid for the whole turn.
export CLAUDE_BRIDGE_AUTO_APPROVE_TTL=600

# One-shot phone-replier: drops "approve always" the FIRST time it sees a
# permission file and then exits. If the autopilot works, the rest of the
# turn proceeds without any further permission files appearing.
(
  while sleep 0.5; do
    f="$(ls -1 "$BRIDGE"/outbox/permission-*.md 2>/dev/null | head -n1 || true)"
    if [ -n "$f" ]; then
      printf 'approve always\n' > "$BRIDGE/inbox/reply-once.txt"
      break
    fi
  done
) &
WATCHDOG_PIDS+=("$!")

# Force Claude into a multi-Bash turn. cd into a clean dir so it doesn't
# absorb our project's CLAUDE.md / git history.
RUNDIR="$WORKDIR/runwd"
mkdir -p "$RUNDIR"
PROMPT='Use the Bash tool to do the following, calling Bash as many times as needed: 1) print the current date in ISO 8601, 2) print the current uname, 3) print pwd. Report all three outputs verbatim.'

(
  cd "$RUNDIR" && \
  claude -p \
    --settings "$SETTINGS_JSON" \
    --permission-mode default \
    --output-format json \
    --append-system-prompt "You are in a sandboxed test. Do exactly what the user asks. There is no git repo here." \
    "$PROMPT" \
    > "$WORKDIR/result.json" 2> "$WORKDIR/err"
) &
CLAUDE_PID=$!

# Bound the wait — autopilot should make this fast.
waited=0
while kill -0 "$CLAUDE_PID" 2>/dev/null; do
  sleep 1
  waited=$((waited+1))
  if [ "$waited" -gt 240 ]; then
    echo "FAIL: claude still running after 240s"
    kill "$CLAUDE_PID" 2>/dev/null || true
    cat "$LOG" 2>/dev/null | tail -n 40
    exit 1
  fi
done
wait "$CLAUDE_PID" 2>/dev/null || true

echo "============================================================"
echo "Claude finished after ${waited}s"
echo "============================================================"

echo
echo "--- claude result (trimmed) ---"
jq '{is_error, num_turns, stop_reason, permission_denials_count: (.permission_denials // []) | length, result}' \
  "$WORKDIR/result.json"

echo
echo "--- bridge log ---"
cat "$LOG"

# Assertions — measure user-visible state, not just log history.
#
# When Claude fires N Bash calls in PARALLEL, all N hook invocations write a
# permission file before any of them can set the always-flag. That's a
# transient up to a sync round-trip; the user only sees one of them in
# practice (whichever syncs to phone first), taps approve always, and the
# others get archived as `raced-*.md` once their poll loop notices the flag.
# So the right invariants are:
#   - 0 permission_denials in claude's result          (one tap → no blocks)
#   - is_error=false                                    (turn completed)
#   - the result mentions all three outputs            (every Bash actually ran)
#   - outbox/permission-*.md is empty after run        (orphans got archived)
#   - bridge log shows >=1 auto-approve(always) hit    (autopilot engaged)
AUTO_APPROVES=$(grep -c "auto-approve(always)" "$LOG" || true)
RACED_ARCHIVES=$(find "$BRIDGE/archive" -name "raced-permission-*.md" 2>/dev/null | wc -l)
LEFTOVER_PERMS=$(find "$BRIDGE/outbox" -maxdepth 1 -name "permission-*.md" 2>/dev/null | wc -l)
DENIALS=$(jq -r '(.permission_denials // []) | length' "$WORKDIR/result.json")
IS_ERROR=$(jq -r '.is_error' "$WORKDIR/result.json")
RESULT_TEXT=$(jq -r '.result' "$WORKDIR/result.json")

echo
echo "auto-approve(always) hits      : $AUTO_APPROVES   (expect >=1)"
echo "raced-orphan files archived    : $RACED_ARCHIVES (expect >=0; tracks parallelism)"
echo "leftover unanswered perms      : $LEFTOVER_PERMS (expect 0)"
echo "permission_denials count       : $DENIALS        (expect 0)"
echo "is_error                       : $IS_ERROR       (expect false)"

[ "$IS_ERROR" = "false" ]   || { echo "FAIL: claude reported is_error"; exit 1; }
[ "$DENIALS" = "0" ]         || { echo "FAIL: there were permission denials despite always-flag"; exit 1; }
[ "$AUTO_APPROVES" -ge 1 ]   || { echo "FAIL: expected at least 1 auto-approve(always) hit"; exit 1; }
[ "$LEFTOVER_PERMS" -eq 0 ]  || { echo "FAIL: orphan permission files were not archived"; exit 1; }

case "$RESULT_TEXT" in
  *2026*Linux*runwd*) ;; # all three outputs (date, uname, pwd) appear
  *)
    echo "FAIL: result is missing one of {date, uname, pwd} outputs"
    echo "$RESULT_TEXT"
    exit 1 ;;
esac

echo
echo "============================================================"
echo "AUTOPILOT PASS: 1 phone tap (\"approve always\") covered the whole"
echo "                multi-Bash turn; $AUTO_APPROVES auto-approve hit(s) recorded,"
echo "                $RACED_ARCHIVES sibling permission file(s) auto-archived,"
echo "                0 permission denials, 0 leftover prompts."
echo "============================================================"
