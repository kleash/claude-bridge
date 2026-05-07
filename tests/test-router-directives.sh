#!/usr/bin/env bash
# Verify the new phone-side directives in bridge-router.sh:
#   /list, /status, /cancel, /help, /clean
# Existing /new and /task coverage lives in tests/test-router.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROUTER="$ROOT/bin/bridge-router.sh"

TMP="$(mktemp -d -t claude-bridge-router-dir-test.XXXXXX)"
cleanup() {
  if [ -n "${ROUTER_PID:-}" ]; then
    kill "$ROUTER_PID" 2>/dev/null || true
    wait "$ROUTER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

BRIDGE="$TMP/bridge"
mkdir -p "$BRIDGE/inbox" "$BRIDGE/sessions/sid-A/inbox" "$BRIDGE/tasks"
touch "$BRIDGE/.enabled"
printf 'waiting\n' > "$BRIDGE/sessions/sid-A/status"
printf 'sid-A' > "$BRIDGE/tasks/build-pipeline"

CLAUDE_BRIDGE_DIR="$BRIDGE" \
CLAUDE_BRIDGE_POLL=1 \
CLAUDE_BRIDGE_LOG="$TMP/router.log" \
CLAUDE_BRIDGE_FLAGS="" \
bash "$ROUTER" &
ROUTER_PID=$!

wait_for_match() {
  local pattern="$1" i
  for i in $(seq 1 30); do
    if grep -lq "$pattern" "$BRIDGE"/outbox/*.md 2>/dev/null; then return 0; fi
    sleep 0.2
  done
  echo "FAIL: timeout waiting for outbox file matching: $pattern"
  echo "--- router.log ---"; cat "$TMP/router.log" 2>/dev/null || true
  echo "--- bridge dir ---"; ls -laR "$BRIDGE"
  return 1
}

# /list
printf '/list\n' > "$BRIDGE/inbox/01.md"
wait_for_match "build-pipeline.*sid-A"
echo "case 1 PASS: /list emits a task table"

# /help
printf '/help\n' > "$BRIDGE/inbox/02.md"
wait_for_match "claude-bridge directives"
echo "case 2 PASS: /help emits cheatsheet"

# /status build-pipeline
printf '/status build-pipeline\n' > "$BRIDGE/inbox/03.md"
wait_for_match "Status — build-pipeline"
echo "case 3 PASS: /status <task> emits per-task status"

# /cancel build-pipeline
printf '/cancel build-pipeline\n' > "$BRIDGE/inbox/04.md"
for i in $(seq 1 30); do
  [ -e "$BRIDGE/sessions/sid-A/inbox/.cancel" ] && break
  sleep 0.2
done
[ -e "$BRIDGE/sessions/sid-A/inbox/.cancel" ] \
  || { echo "FAIL: /cancel did not drop sentinel"; exit 1; }
echo "case 4 PASS: /cancel drops sentinel into per-session inbox"

# /clean — should run quietly and write a confirmation
mkdir -p "$BRIDGE/archive"
old="$BRIDGE/archive/old.md"; : > "$old"
touch -d "30 days ago" "$old" 2>/dev/null || touch -t "$(date -u -v-30d +%Y%m%d0000 2>/dev/null)" "$old" 2>/dev/null
printf '/clean --days 14\n' > "$BRIDGE/inbox/05.md"
wait_for_match "Pruned archive entries"
[ ! -e "$old" ] || { echo "FAIL: /clean did not prune old entry"; ls -la "$BRIDGE/archive"; exit 1; }
echo "case 5 PASS: /clean prunes archive and emits confirmation"

# Unknown directive is left alone (bare-file fall-through)
printf 'just a plain message\n' > "$BRIDGE/inbox/99.md"
sleep 2
[ -f "$BRIDGE/inbox/99.md" ] \
  || { echo "FAIL: bare file should not be archived by router"; exit 1; }
echo "case 6 PASS: bare files left for the Stop hook"

echo "ALL ROUTER DIRECTIVE TESTS PASSED"
