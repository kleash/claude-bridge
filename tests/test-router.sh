#!/usr/bin/env bash
# Router tests use a fake `claude` binary on PATH so we don't actually call
# the real CLI. Verifies parsing of /new and /task directives and outbox
# emission.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROUTER="$ROOT/bin/bridge-router.sh"

TMP="$(mktemp -d -t claude-bridge-router-test.XXXXXX)"
cleanup() {
  if [ -n "${ROUTER_PID:-}" ]; then
    kill "$ROUTER_PID" 2>/dev/null || true
    wait "$ROUTER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

BRIDGE="$TMP/bridge"
mkdir -p "$BRIDGE/inbox"
touch "$BRIDGE/.enabled"

# Fake `claude` binary: prints a JSON envelope mimicking
# `claude -p ... --output-format json`. Records every invocation to a log so
# the test can assert behavior.
FAKEBIN="$TMP/bin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/claude" <<'FAKE'
#!/usr/bin/env bash
# Log invocation for assertions
echo "INVOKE: $*" >> "$CLAUDE_FAKE_LOG"
prompt=""
resume=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) prompt="$2"; shift 2 ;;
    --resume) resume="$2"; shift 2 ;;
    --output-format|--append-system-prompt) shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "$resume" ]; then
  sid="$resume"
else
  sid="fake-$(date +%s)-$$"
fi
# Echo a reply that includes the prompt so tests can verify routing.
printf '{"session_id":"%s","result":"echo: %s"}\n' "$sid" "${prompt//\"/\\\"}"
FAKE
chmod +x "$FAKEBIN/claude"

export CLAUDE_FAKE_LOG="$TMP/claude-invocations.log"
: >"$CLAUDE_FAKE_LOG"

# Spawn the router with the fake claude on PATH and a tight poll.
PATH="$FAKEBIN:$PATH" \
CLAUDE_BRIDGE_DIR="$BRIDGE" \
CLAUDE_BRIDGE_POLL=1 \
CLAUDE_BRIDGE_LOG="$TMP/router.log" \
CLAUDE_BRIDGE_FLAGS="" \
bash "$ROUTER" &
ROUTER_PID=$!

# Helper: wait for an outbox file matching a glob, up to 6 seconds.
wait_for() {
  local glob="$1" i
  for i in $(seq 1 30); do
    # shellcheck disable=SC2086
    if compgen -G "$glob" > /dev/null; then return 0; fi
    sleep 0.2
  done
  echo "FAIL: timeout waiting for $glob"
  echo "--- router.log ---"; cat "$TMP/router.log" || true
  echo "--- bridge dir ---"; ls -laR "$BRIDGE" || true
  return 1
}

# --- Case 1: /new <title> ---------------------------------------------------
cat > "$BRIDGE/inbox/01.md" <<'MSG'
/new build-pipeline
please summarize the build pipeline status.
MSG

wait_for "$BRIDGE/outbox/*.md"
content="$(cat "$BRIDGE"/outbox/*.md)"
case "$content" in
  *"echo: please summarize the build pipeline status."*) ;;
  *) echo "FAIL: outbox missing /new prompt echo. Content:"; echo "$content"; exit 1 ;;
esac
case "$content" in
  *"task: \`build-pipeline\`"*) ;;
  *) echo "FAIL: outbox missing task label. Content:"; echo "$content"; exit 1 ;;
esac
[ -f "$BRIDGE/tasks/build-pipeline" ] || { echo "FAIL: tasks/build-pipeline not created"; exit 1; }
NEW_SID="$(cat "$BRIDGE/tasks/build-pipeline")"
[ -n "$NEW_SID" ] || { echo "FAIL: empty session id"; exit 1; }
[ ! -e "$BRIDGE/inbox/01.md" ] || { echo "FAIL: input file not archived"; exit 1; }
ls "$BRIDGE/archive"/*01.md >/dev/null 2>&1 || { echo "FAIL: archive missing"; exit 1; }
echo "case 1 PASS: /new spawns + writes outbox + records task mapping"

# --- Case 2: /task <title> resumes by id ------------------------------------
cat > "$BRIDGE/inbox/02.md" <<'MSG'
/task build-pipeline
any update?
MSG

# Wait until claude is invoked with --resume
for i in $(seq 1 30); do
  if grep -q -- "--resume $NEW_SID" "$CLAUDE_FAKE_LOG"; then break; fi
  sleep 0.2
done
grep -q -- "--resume $NEW_SID" "$CLAUDE_FAKE_LOG" \
  || { echo "FAIL: claude not invoked with --resume $NEW_SID"; cat "$CLAUDE_FAKE_LOG"; exit 1; }
echo "case 2 PASS: /task resumes the right session id"

# --- Case 3: bare file (no directive) is left alone -------------------------
cat > "$BRIDGE/inbox/03.md" <<'MSG'
just a plain message, no directive
MSG
sleep 2
[ -f "$BRIDGE/inbox/03.md" ] || { echo "FAIL: bare file should NOT be archived by router"; exit 1; }
echo "case 3 PASS: bare files left for the Stop hook"

# --- Case 4: /task with unknown id is reported, not crashed -----------------
cat > "$BRIDGE/inbox/04.md" <<'MSG'
/task does-not-exist
hi
MSG
# The router writes an error outbox for unknown tasks.
for i in $(seq 1 30); do
  if grep -q "unknown task id" "$BRIDGE"/outbox/*.md 2>/dev/null; then break; fi
  sleep 0.2
done
grep -q "unknown task id" "$BRIDGE"/outbox/*.md \
  || { echo "FAIL: expected 'unknown task id' outbox"; exit 1; }
echo "case 4 PASS: unknown /task id surfaces a helpful error"

echo "ALL ROUTER TESTS PASSED"
