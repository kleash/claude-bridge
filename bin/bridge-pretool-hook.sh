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

# ---- short summary used for static pattern matching + outbox display -----

case "$TOOL_NAME" in
  Bash)
    TOOL_SUMMARY="$(printf '%s' "$TOOL_INPUT_JSON" | jq -r '.command // ""')" ;;
  Write|Edit|NotebookEdit)
    TOOL_SUMMARY="$(printf '%s' "$TOOL_INPUT_JSON" | jq -r '.file_path // .path // ""')" ;;
  *)
    TOOL_SUMMARY="$(printf '%s' "$TOOL_INPUT_JSON" | jq -c .)" ;;
esac

# ---- skip-the-roundtrip checks: static patterns + per-session flags ------
# This is the whole point of v1.3: don't make the user re-tap "approve" for
# every Bash sub-call in a multi-call turn. Three layers, each opt-in:
#   1. CLAUDE_BRIDGE_AUTO_APPROVE_BASH_PATTERNS — static, never round-trips.
#   2. sessions/<sid>/auto-approve-<Tool>       — phone said "approve always".
#   3. sessions/<sid>/auto-approve-count-<Tool> — phone said "approve N".
# Each hit short-circuits the hook with `decision=approve` and emits NO
# permission file (so the phone is silent for known-safe stuff).

AUTO_APPROVE_HIT=""
AUTO_APPROVE_REASON=""
if lb_check_auto_approve "$BRIDGE_DIR" "$SESSION_ID" "$TOOL_NAME" "$TOOL_SUMMARY"; then
  log "session=$SESSION_ID tool=$TOOL_NAME auto-approve(${AUTO_APPROVE_HIT}): ${AUTO_APPROVE_REASON}"
  # Refresh INDEX so phone-side users see the still-active autopilot state
  # (count decremented, TTL clock visible).
  AUTO_NOTE="$(lb_auto_approve_summary "$BRIDGE_DIR" "$SESSION_ID")"
  lb_set_status "$BRIDGE_DIR" "$SESSION_ID" "idle" "$AUTO_NOTE"
  lb_index_rebuild "$BRIDGE_DIR" 2>/dev/null || true
  jq -nc --arg r "auto-approved (${AUTO_APPROVE_HIT}): ${AUTO_APPROVE_REASON}" \
    '{decision:"approve", reason:$r}'
  exit 0
fi

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

# If the user previously asked for auto-approve and we're still here, it's
# either expired or doesn't apply to this tool. Show the current state so
# they don't get confused about why they're being asked again.
AUTO_NOTE_DISPLAY="$(lb_auto_approve_summary "$BRIDGE_DIR" "$SESSION_ID")"

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
  printf '%s\n' '- `approve` — let this one call run'
  printf '%s\n' "- \`approve always\` — auto-approve all $TOOL_NAME calls in this session (TTL ${CLAUDE_BRIDGE_AUTO_APPROVE_TTL:-1800}s)"
  printf '%s\n' "- \`approve N\` — auto-approve the next N $TOOL_NAME calls"
  printf '%s\n' '- `deny` — block and tell Claude why'
  printf '%s\n' '- `deny: <reason>` — block with a custom reason'
  printf '%s\n' '- `revoke` — clear any active auto-approve and block this call'
  printf '%s\n' '- _(any other text)_ — block; Claude reads your text as the reason'
  if [ -n "$AUTO_NOTE_DISPLAY" ]; then
    printf '\n_Currently active autopilot: %s_\n' "$AUTO_NOTE_DISPLAY"
  fi
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
RACED_IN=0
while :; do
  if [ -e "$INBOX_SESSION/.cancel" ]; then
    log "session=$SESSION_ID cancel sentinel found; passthrough"
    rm -f "$INBOX_SESSION/.cancel"
    CANCELLED=1
    break
  fi
  # Race-against-sibling check: when Claude fires multiple Bash calls in
  # parallel, each one starts its own hook and each one writes a permission
  # file. If the user replies "approve always" to the first, the OTHER
  # waiters need to notice the flag and short-circuit — otherwise they sit
  # polling forever (their own reply never arrives because the user only
  # tapped once). Same for counted-approve.
  if lb_check_auto_approve "$BRIDGE_DIR" "$SESSION_ID" "$TOOL_NAME" "$TOOL_SUMMARY"; then
    log "session=$SESSION_ID tool=$TOOL_NAME auto-approve(${AUTO_APPROVE_HIT}) raced in during poll: ${AUTO_APPROVE_REASON}"
    RACED_IN=1
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

# Auto-approve raced in mid-poll (a sibling hook for the same session got the
# user's "approve always" reply). Move our orphan permission file to archive
# so the phone doesn't see a ghost "tap me!" request.
if [ "$RACED_IN" -eq 1 ]; then
  if [ -f "$OUT_FILE" ]; then
    mv "$OUT_FILE" "$ARCHIVE/raced-$(basename "$OUT_FILE")" 2>/dev/null || true
  fi
  AUTO_NOTE="$(lb_auto_approve_summary "$BRIDGE_DIR" "$SESSION_ID")"
  lb_set_status "$BRIDGE_DIR" "$SESSION_ID" "idle" "$AUTO_NOTE"
  lb_index_rebuild "$BRIDGE_DIR" 2>/dev/null || true
  jq -nc --arg r "auto-approved (${AUTO_APPROVE_HIT}, raced during poll): ${AUTO_APPROVE_REASON}" \
    '{decision:"approve", reason:$r}'
  exit 0
fi

REPLY_TEXT="$(cat "$REPLY_FILE")"
ARCHIVED="$ARCHIVE/permission-${SESSION_ID}-${TS}-$(basename "$REPLY_FILE")"
mv "$REPLY_FILE" "$ARCHIVED" 2>/dev/null || true
log "session=$SESSION_ID tool=$TOOL_NAME consumed $REPLY_FILE -> $ARCHIVED"

# The question has been answered — move our own permission request file out
# of outbox/ so the phone user doesn't keep seeing a "tap me!" prompt for an
# already-resolved call.
if [ -f "$OUT_FILE" ]; then
  mv "$OUT_FILE" "$ARCHIVE/answered-$(basename "$OUT_FILE")" 2>/dev/null || true
fi

REPLY_DECISION=""
REPLY_REASON=""
REPLY_PERSIST=""
lb_parse_permission_reply "$REPLY_TEXT"

# Apply any persistent state change requested by the reply. This is what
# turns a single phone tap into "auto-approve all subsequent calls" so the
# user doesn't have to round-trip through OneDrive sync for every Bash
# sub-call in a multi-call turn.
case "$REPLY_PERSIST" in
  always)
    lb_set_auto_approve_always "$BRIDGE_DIR" "$SESSION_ID" "$TOOL_NAME"
    log "session=$SESSION_ID tool=$TOOL_NAME persist: always" ;;
  count:*)
    N="${REPLY_PERSIST#count:}"
    lb_set_auto_approve_count "$BRIDGE_DIR" "$SESSION_ID" "$TOOL_NAME" "$N"
    log "session=$SESSION_ID tool=$TOOL_NAME persist: count=$N" ;;
  revoke)
    lb_clear_auto_approve "$BRIDGE_DIR" "$SESSION_ID" "$TOOL_NAME"
    log "session=$SESSION_ID tool=$TOOL_NAME persist: revoke" ;;
esac

# Surface the (possibly new) auto-approve state in the INDEX note so the
# phone user can always see whether they're on autopilot for this session.
NOTE="$REPLY_DECISION ($TOOL_NAME)"
SUM="$(lb_auto_approve_summary "$BRIDGE_DIR" "$SESSION_ID")"
[ -n "$SUM" ] && NOTE="$NOTE — $SUM"
lb_set_status "$BRIDGE_DIR" "$SESSION_ID" "idle" "$NOTE"
lb_index_rebuild "$BRIDGE_DIR" 2>/dev/null || true

log "session=$SESSION_ID tool=$TOOL_NAME decision=$REPLY_DECISION persist=${REPLY_PERSIST:-none}"
jq -nc --arg d "$REPLY_DECISION" --arg r "$REPLY_REASON" \
  '{decision:$d, reason:$r}'
exit 0
