#!/usr/bin/env bash
# Real-world end-to-end test: invoke `claude -p` with our PreToolUse hook
# registered via --settings, then auto-reply to every permission request and
# verify Claude honors the decisions emitted by the hook.
#
# The watchdog mimics a phone user who keeps replying to every permission
# request that lands in outbox/. This is necessary because Claude often makes
# multiple Bash calls per turn (e.g. a context-gathering `git status` in
# addition to the command you asked for); each one fires the hook and needs
# its own reply.
#
# This does NOT touch the user's real ~/.claude/settings.json — the hook is
# registered via a settings JSON passed to `claude --settings`. Only the
# bridge folder under $WORKDIR is touched.

set -eo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/bin/bridge-pretool-hook.sh"

if ! command -v claude >/dev/null 2>&1; then
  echo "SKIP: claude CLI not on PATH"; exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq required"; exit 1
fi

WORKDIR="$(mktemp -d -t claude-bridge-e2e.XXXXXX)"
WATCHDOG_PIDS=()
cleanup() {
  for pid in "${WATCHDOG_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

BRIDGE="$WORKDIR/bridge"
LOG="$WORKDIR/claude-bridge.log"
mkdir -p "$BRIDGE"/{inbox,outbox,archive,sessions}
touch "$BRIDGE/.enabled"

# Register only the PreToolUse hook for this test. Stop hook would also fire
# at end of session and block waiting for input — out of scope here.
SETTINGS_JSON="$(jq -nc --arg cmd "$HOOK" \
  '{hooks:{PreToolUse:[{matcher:"",hooks:[{type:"command",command:$cmd}]}]}}')"

export CLAUDE_BRIDGE_DIR="$BRIDGE"
export CLAUDE_BRIDGE_PERMISSION_TOOLS="Bash"
export CLAUDE_BRIDGE_PERMISSION_TIMEOUT=20
export CLAUDE_BRIDGE_POLL=1
export CLAUDE_BRIDGE_LOG="$LOG"

# A watchdog that simulates the phone user. Whenever it sees a permission file
# in outbox that hasn't been answered yet, it drops the configured reply.
start_watchdog() {
  local reply_body="$1" stamp_dir="$WORKDIR/answered"
  mkdir -p "$stamp_dir"
  (
    while sleep 0.5; do
      for f in "$BRIDGE"/outbox/permission-*.md; do
        [ -f "$f" ] || continue
        stamp="$stamp_dir/$(basename "$f").done"
        [ -e "$stamp" ] && continue
        # Dropping into top-level inbox is enough — the hook polls both.
        printf '%s\n' "$reply_body" > "$BRIDGE/inbox/reply-$(date +%s%N).txt"
        : > "$stamp"
      done
    done
  ) &
  WATCHDOG_PIDS+=("$!")
}

run_case() {
  local name="$1" reply_body="$2" prompt="$3"
  local result_file="$WORKDIR/claude-${name}.json"
  local err_file="$WORKDIR/claude-${name}.err"

  printf '\n========== CASE: %s ==========\n' "$name"
  printf 'Watchdog reply: %s\n'  "$reply_body"
  printf 'Prompt:         %s\n' "$prompt"

  # Reset per-case state.
  rm -f "$BRIDGE"/outbox/* "$BRIDGE"/inbox/*  "$BRIDGE"/archive/*
  rm -rf "$BRIDGE"/sessions "$WORKDIR/answered"
  mkdir -p "$BRIDGE/sessions" "$WORKDIR/answered"

  start_watchdog "$reply_body"

  # Launch claude.
  (
    claude -p \
      --settings "$SETTINGS_JSON" \
      --permission-mode default \
      --output-format json \
      "$prompt" \
      > "$result_file" 2> "$err_file"
  ) &
  local pid=$!
  printf 'Claude pid: %s\n' "$pid"

  # Wait for the first permission file (proves the hook fires at all).
  local perm_file=""
  for i in $(seq 1 60); do
    perm_file="$(ls -1t "$BRIDGE"/outbox/permission-*.md 2>/dev/null | head -n1 || true)"
    if [ -n "$perm_file" ]; then break; fi
    sleep 1
  done
  if [ -z "$perm_file" ]; then
    echo "FAIL: no permission file appeared after 60s"
    echo "--- stderr ---"; cat "$err_file"
    kill "$pid" 2>/dev/null || true
    return 1
  fi

  printf '\n--- first permission file the hook wrote ---\n'
  cat "$perm_file"

  # Wait for claude to finish.
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$((waited+1))
    if [ "$waited" -gt 180 ]; then
      echo "FAIL: claude still running after 180s, killing"
      kill "$pid" 2>/dev/null || true
      return 1
    fi
  done
  wait "$pid" 2>/dev/null || true

  # Stop the watchdog before the next case.
  for w in "${WATCHDOG_PIDS[@]:-}"; do kill "$w" 2>/dev/null || true; done
  WATCHDOG_PIDS=()

  printf '\n--- claude result JSON ---\n'
  if [ -s "$result_file" ]; then
    jq '{is_error, num_turns, result, stop_reason, permission_denials}' "$result_file" 2>/dev/null \
      || cat "$result_file"
  else
    echo "(empty)"
  fi
  if [ -s "$err_file" ]; then
    printf '\n--- claude stderr ---\n'
    cat "$err_file"
  fi

  printf '\n--- bridge log decisions for this case ---\n'
  grep -E "decision=|tool=" "$LOG" | tail -n 20 || true

  printf '\n--- archive contents ---\n'
  ls -la "$BRIDGE/archive" 2>/dev/null || true
  return 0
}

# --- decision parsing helpers ---------------------------------------------
extract_text() {
  jq -r '.result // ""' "$1" 2>/dev/null || cat "$1"
}
denials_count() {
  jq -r '(.permission_denials // []) | length' "$1" 2>/dev/null || echo 0
}

# === APPROVE ==============================================================
run_case "approve" "approve" \
  "Use the Bash tool to run exactly this command and report its output verbatim: echo HELLO_FROM_APPROVED_BASH"

APPROVE="$WORKDIR/claude-approve.json"
APPROVE_TEXT="$(extract_text "$APPROVE")"
APPROVE_DENIALS="$(denials_count "$APPROVE")"

echo
echo "Approve denials count: $APPROVE_DENIALS"
case "$APPROVE_TEXT" in
  *HELLO_FROM_APPROVED_BASH*)
    echo ">>> APPROVE PASS: Claude's response contains the bash output (echo ran)" ;;
  *)
    echo ">>> APPROVE FAIL: response did not contain HELLO_FROM_APPROVED_BASH"
    echo "Result text was:"
    echo "$APPROVE_TEXT"
    exit 1 ;;
esac
# Confirm the bridge log shows at least one decision=approve for this case.
if grep -q 'decision=approve' "$LOG"; then
  echo ">>> APPROVE PASS: bridge log shows decision=approve"
else
  echo ">>> APPROVE FAIL: no decision=approve line in bridge log"
  exit 1
fi

# === DENY =================================================================
run_case "deny" "deny: this is a sandboxed test, do not run shell commands" \
  "Use the Bash tool to run exactly this command and report its output verbatim: echo SHOULD_NOT_RUN_DENIED"

DENY="$WORKDIR/claude-deny.json"
DENY_TEXT="$(extract_text "$DENY")"
DENY_DENIALS="$(denials_count "$DENY")"

echo
echo "Deny denials count: $DENY_DENIALS"
# The model should have at least one recorded denial.
if [ "$DENY_DENIALS" -lt 1 ]; then
  echo ">>> DENY FAIL: result.permission_denials was empty — block did not register"
  exit 1
fi
echo ">>> DENY PASS: $DENY_DENIALS permission denial(s) recorded by Claude"
# Bridge log should show decision=block.
if grep -q 'decision=block' "$LOG"; then
  echo ">>> DENY PASS: bridge log shows decision=block"
else
  echo ">>> DENY FAIL: no decision=block line in bridge log"
  exit 1
fi
# Optional sanity: the human-readable reply text should be reflected somewhere
# in Claude's response. We only require it for non-trivial reasons.
if printf '%s' "$DENY_TEXT" | grep -qiE 'sandbox|test|deni|block|approval'; then
  echo ">>> DENY PASS: Claude's response references the block/deny context"
else
  echo "(soft) Claude's reply didn't reference sandbox/deny context, but that's okay."
fi

echo
echo "============================================================"
echo "ALL E2E CASES PASSED (real Claude CLI, real PreToolUse hook)"
echo "============================================================"
