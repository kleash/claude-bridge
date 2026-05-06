#!/usr/bin/env bash
# claude-bridge: a PreToolUse hook for Claude Code that lets you APPROVE or
# DENY tool calls from your phone. Same cloud-folder transport as the Stop
# hook — no API key, no inbound port, no third-party push service.
#
# Stdin (from Claude Code) is JSON containing at least:
#   { "session_id": "...", "transcript_path": "...",
#     "tool_name": "Bash", "tool_input": { "command": "..." } }
#
# This hook is OPT-IN. Set CLAUDE_BRIDGE_PERMISSION_TOOLS to a comma-separated
# list of tool names to gate (e.g. "Bash,Write,Edit"). Tools NOT in that list
# pass through silently — Claude Code's normal in-terminal permission flow
# applies, exactly as before.
#
# When a gated tool fires, this hook:
#   1. writes outbox/permission-<sid>-<ts>.md describing the call
#   2. sets sessions/<sid>/status = "awaiting-approval"
#   3. polls inbox/ and sessions/<sid>/inbox/ for a reply file
#   4. parses the reply and emits a JSON gate decision on stdout:
#        approve              -> {"decision":"approve",...}
#        deny / deny:<reason> -> {"decision":"block",   "reason":...}
#        timeout              -> {"decision":"block",   "reason":"timed out..."}
#        free-form text       -> {"decision":"block",   "reason":<your text>}
#
# Env (all optional):
#   CLAUDE_BRIDGE_DIR                    same as Stop hook
#   CLAUDE_BRIDGE_PERMISSION_TOOLS       CSV of tool names to gate (default: "")
#   CLAUDE_BRIDGE_PERMISSION_TIMEOUT     seconds to wait (default 1800)
#   CLAUDE_BRIDGE_PERMISSION_DEFAULT     "block" (default) or "passthrough"
#   CLAUDE_BRIDGE_POLL                   poll interval (default 2)
#   CLAUDE_BRIDGE_LOG                    log path (default: hook's path)
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
log() { printf '[%s] pretool: %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"; }

# shellcheck source=lib-bridge.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-bridge.sh"

# ---- read input -------------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
  log "ERROR: jq not found in PATH; passthrough"
  exit 0
fi

INPUT="$(cat)"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"')"
TOOL_NAME="$(printf '%s' "$INPUT"  | jq -r '.tool_name  // ""')"
TOOL_INPUT_JSON="$(printf '%s' "$INPUT" | jq -c '.tool_input // {}')"

# ---- opt-in filter ----------------------------------------------------------

GATE_LIST="${CLAUDE_BRIDGE_PERMISSION_TOOLS:-}"
if [ -z "$GATE_LIST" ] || [ -z "$TOOL_NAME" ]; then
  exit 0
fi

# Comma-separated, trimmed, case-sensitive match.
matched=0
IFS=',' read -ra _gates <<<"$GATE_LIST"
for _t in "${_gates[@]}"; do
  _t="${_t# }"; _t="${_t% }"
  if [ "$_t" = "$TOOL_NAME" ]; then matched=1; break; fi
done
if [ "$matched" -eq 0 ]; then
  exit 0
fi

# ---- bridge dir + kill switch -----------------------------------------------

BRIDGE_DIR="$(lb_resolve_bridge_dir)"
if [ ! -f "$BRIDGE_DIR/.enabled" ]; then
  log "session=$SESSION_ID disabled (no $BRIDGE_DIR/.enabled); passthrough"
  exit 0
fi

INBOX_TOP="$BRIDGE_DIR/inbox"
INBOX_SESSION="$BRIDGE_DIR/sessions/$SESSION_ID/inbox"
OUTBOX="$BRIDGE_DIR/outbox"
ARCHIVE="$BRIDGE_DIR/archive"
mkdir -p "$INBOX_TOP" "$INBOX_SESSION" "$OUTBOX" "$ARCHIVE"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_FILE="$OUTBOX/permission-${SESSION_ID}-${TS}.md"
HOST="$(hostname 2>/dev/null || echo laptop)"

# ---- pretty-print the tool call --------------------------------------------

# A tiny helper: render the tool input as a fenced code block. Bash commands
# get a `bash` fence; everything else gets the JSON.
render_tool_call() {
  case "$TOOL_NAME" in
    Bash)
      local cmd
      cmd="$(printf '%s' "$TOOL_INPUT_JSON" | jq -r '.command // ""')"
      printf '```bash\n%s\n```\n' "$cmd"
      ;;
    Write|Edit|NotebookEdit)
      local path
      path="$(printf '%s' "$TOOL_INPUT_JSON" | jq -r '.file_path // .path // ""')"
      printf '**Target:** `%s`\n\n' "$path"
      printf '```json\n%s\n```\n' "$(printf '%s' "$TOOL_INPUT_JSON" | jq .)"
      ;;
    *)
      printf '```json\n%s\n```\n' "$(printf '%s' "$TOOL_INPUT_JSON" | jq .)"
      ;;
  esac
}

# ---- write the permission request ------------------------------------------

TMP="$OUT_FILE.tmp"
{
  printf '%s\n\n' "# Permission request — $TOOL_NAME on $HOST"
  printf '%s\n' "- session: \`$SESSION_ID\`"
  printf '%s\n' "- tool: \`$TOOL_NAME\`"
  printf '%s\n' "- timestamp: \`$TS\`"
  printf '%s\n\n' "- bridge: \`$BRIDGE_DIR\`"
  printf '%s\n\n' '---'
  render_tool_call
  printf '\n%s\n' '---'
  printf '\n%s\n\n' '## Reply with one of:'
  printf '%s\n' '- `approve` — let it run as-is'
  printf '%s\n' '- `deny` — block and tell Claude why'
  printf '%s\n' '- `deny: <reason>` — block with a custom reason'
  printf '%s\n' '- _(any other text)_ — block; Claude reads your text as the reason'
  printf '\n%s\n' "Drop the file in either:"
  printf '%s\n' "- \`$INBOX_SESSION\` (this session only — recommended)"
  printf '%s\n' "- \`$INBOX_TOP\` (any session)"
} >"$TMP"
mv "$TMP" "$OUT_FILE"

lb_set_status "$BRIDGE_DIR" "$SESSION_ID" "awaiting-approval" "$TOOL_NAME"
lb_index_rebuild "$BRIDGE_DIR" 2>/dev/null || true
log "session=$SESSION_ID tool=$TOOL_NAME wrote $OUT_FILE"

# ---- poll for reply ---------------------------------------------------------

START_EPOCH="$(date +%s)"
TIMEOUT="${CLAUDE_BRIDGE_PERMISSION_TIMEOUT:-${CLAUDE_BRIDGE_TIMEOUT:-1800}}"
POLL="${CLAUDE_BRIDGE_POLL:-2}"
DEFAULT_ON_TIMEOUT="${CLAUDE_BRIDGE_PERMISSION_DEFAULT:-block}"

REPLY_FILE=""
CANCELLED=0
while :; do
  if [ -e "$INBOX_SESSION/.cancel" ]; then
    log "session=$SESSION_ID cancel sentinel found; passthrough"
    rm -f "$INBOX_SESSION/.cancel"
    CANCELLED=1
    break
  fi
  CAND="$(ls -1t "$INBOX_SESSION"/*.md "$INBOX_SESSION"/*.txt 2>/dev/null | head -n1 || true)"
  if [ -z "$CAND" ] || [ ! -f "$CAND" ]; then
    CAND="$(ls -1t "$INBOX_TOP"/*.md "$INBOX_TOP"/*.txt 2>/dev/null | head -n1 || true)"
  fi
  if [ -n "$CAND" ] && [ -f "$CAND" ]; then
    REPLY_FILE="$CAND"
    break
  fi
  NOW="$(date +%s)"
  if [ $((NOW - START_EPOCH)) -ge "$TIMEOUT" ]; then
    log "session=$SESSION_ID tool=$TOOL_NAME timeout; default=$DEFAULT_ON_TIMEOUT"
    lb_set_status "$BRIDGE_DIR" "$SESSION_ID" "idle" "approval timed out"
    lb_index_rebuild "$BRIDGE_DIR" 2>/dev/null || true
    if [ "$DEFAULT_ON_TIMEOUT" = "passthrough" ]; then
      exit 0
    fi
    jq -nc --arg r "timed out waiting for phone approval (${TIMEOUT}s)" \
      '{decision:"block", reason:$r}'
    exit 0
  fi
  sleep "$POLL"
done

# Cancel sentinel = passthrough (let Claude Code's terminal prompt handle it).
if [ "$CANCELLED" -eq 1 ]; then
  lb_set_status "$BRIDGE_DIR" "$SESSION_ID" "idle" "cancelled"
  lb_index_rebuild "$BRIDGE_DIR" 2>/dev/null || true
  exit 0
fi

REPLY_TEXT="$(cat "$REPLY_FILE")"
ARCHIVED="$ARCHIVE/permission-${SESSION_ID}-${TS}-$(basename "$REPLY_FILE")"
mv "$REPLY_FILE" "$ARCHIVED" 2>/dev/null || true
log "session=$SESSION_ID tool=$TOOL_NAME consumed $REPLY_FILE -> $ARCHIVED"

REPLY_DECISION=""
REPLY_REASON=""
lb_parse_permission_reply "$REPLY_TEXT"

lb_set_status "$BRIDGE_DIR" "$SESSION_ID" "idle" "$REPLY_DECISION ($TOOL_NAME)"
lb_index_rebuild "$BRIDGE_DIR" 2>/dev/null || true

log "session=$SESSION_ID tool=$TOOL_NAME decision=$REPLY_DECISION"
jq -nc --arg d "$REPLY_DECISION" --arg r "$REPLY_REASON" \
  '{decision:$d, reason:$r}'
exit 0
