#!/usr/bin/env bash
# claude-bridge: a Stop hook for Claude Code that pauses every session at end
# of turn, writes the assistant's last message to a folder, and waits for a
# reply file before continuing. Designed to round-trip through a cloud-synced
# folder (OneDrive, Dropbox, iCloud Drive, Syncthing, …) so you can converse
# with a Claude session from your phone.
#
# Stdin (from Claude Code) is JSON containing at least:
#   { "session_id": "...", "transcript_path": "...", "stop_hook_active": bool }
#
# Env (all optional):
#   CLAUDE_BRIDGE_DIR     base dir holding inbox/ outbox/ archive/
#                         default: auto-detect OneDrive/Dropbox/iCloud, else
#                                  $HOME/.claude-bridge/default
#   CLAUDE_BRIDGE_TIMEOUT seconds to wait for a reply (default 1800)
#   CLAUDE_BRIDGE_POLL    poll interval in seconds (default 2)
#   CLAUDE_BRIDGE_LOG     log file path (default: platform state dir)
#
# Project: https://github.com/<your-org>/claude-bridge
# License: MIT

set -u

# ---- platform-aware defaults ------------------------------------------------

default_log_path() {
  case "$(uname -s)" in
    Darwin) printf '%s/Library/Logs/claude-bridge.log' "$HOME" ;;
    *)      printf '%s/.claude-bridge/claude-bridge.log' "$HOME" ;;
  esac
}

# Auto-detect a likely cloud-synced folder. First match wins.
detect_cloud_dir() {
  local candidates=(
    # macOS modern OneDrive sync paths (personal and tenant)
    "$HOME"/Library/CloudStorage/OneDrive*
    # Linux/Windows-via-WSL/legacy OneDrive
    "$HOME"/OneDrive*
    # Dropbox (macOS modern + classic)
    "$HOME"/Library/CloudStorage/Dropbox*
    "$HOME"/Dropbox
    # iCloud Drive on macOS
    "$HOME"/Library/Mobile\ Documents/com~apple~CloudDocs
    # Google Drive desktop
    "$HOME"/Library/CloudStorage/GoogleDrive*
    "$HOME"/Google\ Drive
  )
  local p
  for p in "${candidates[@]}"; do
    [ -d "$p" ] && { printf '%s' "$p"; return; }
  done
}

LOG="${CLAUDE_BRIDGE_LOG:-$(default_log_path)}"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"; }

# shellcheck source=lib-bridge.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-bridge.sh"

# ---- read hook input --------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
  log "ERROR: jq not found in PATH; install jq and retry"
  exit 0
fi

INPUT="$(cat)"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"')"
TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""')"
STOP_ACTIVE="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')"

# Loop-prevention: if we already injected a continuation, let Claude actually
# stop next time around. Without this, every "continue" would itself be
# intercepted and we'd never exit.
if [ "$STOP_ACTIVE" = "true" ]; then
  log "session=$SESSION_ID stop_hook_active=true; releasing"
  exit 0
fi

# ---- resolve bridge dir -----------------------------------------------------

if [ -n "${CLAUDE_BRIDGE_DIR:-}" ]; then
  BRIDGE_DIR="$CLAUDE_BRIDGE_DIR"
else
  CLOUD="$(detect_cloud_dir || true)"
  if [ -n "$CLOUD" ]; then
    BRIDGE_DIR="$CLOUD/ClaudeBridge"
  else
    BRIDGE_DIR="$HOME/.claude-bridge/default"
  fi
fi

# Kill-switch: hook is a no-op unless explicitly enabled by creating
# $BRIDGE_DIR/.enabled. Lets a global install stay dormant until opted in.
if [ ! -f "$BRIDGE_DIR/.enabled" ]; then
  log "session=$SESSION_ID disabled (no $BRIDGE_DIR/.enabled); releasing"
  exit 0
fi

INBOX_TOP="$BRIDGE_DIR/inbox"
INBOX_SESSION="$BRIDGE_DIR/sessions/$SESSION_ID/inbox"
OUTBOX="$BRIDGE_DIR/outbox"
ARCHIVE="$BRIDGE_DIR/archive"
mkdir -p "$INBOX_TOP" "$INBOX_SESSION" "$OUTBOX" "$ARCHIVE"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_FILE="$OUTBOX/${SESSION_ID}-${TS}.md"

log "session=$SESSION_ID transcript=$TRANSCRIPT"

# ---- extract last assistant message from transcript ------------------------

extract_last_assistant() {
  jq -rs '
    [.[] | select(.type=="assistant") |
      ((.message.content // []) | if type=="array" then . else [] end) |
      map(select(.type=="text") | .text) | join("\n")
    ] | map(select(. != "")) | last // ""
  ' "$1" 2>/dev/null || true
}

LAST_ASSISTANT=""
if [ -n "$TRANSCRIPT" ]; then
  # Poll up to ~6s for the assistant turn to flush. The Stop hook can fire
  # microseconds before Claude finishes appending the final message.
  for _ in $(seq 1 30); do
    if [ -f "$TRANSCRIPT" ]; then
      LAST_ASSISTANT="$(extract_last_assistant "$TRANSCRIPT")"
      [ -n "$LAST_ASSISTANT" ] && break
    fi
    sleep 0.2
  done
fi
[ -z "$LAST_ASSISTANT" ] && LAST_ASSISTANT="(no assistant text captured)"
log "session=$SESSION_ID assistant_len=${#LAST_ASSISTANT}"

# ---- write outbox atomically ------------------------------------------------

TMP="$OUT_FILE.tmp"
{
  printf '%s\n\n' '# Claude turn output'
  printf '%s\n' "- session: \`$SESSION_ID\`"
  printf '%s\n' "- timestamp: \`$TS\`"
  printf '%s\n\n' "- bridge: \`$BRIDGE_DIR\`"
  printf '%s\n\n' '---'
  printf '%s\n\n' "$LAST_ASSISTANT"
  printf '%s\n' '---'
  printf '\n%s\n' "Reply by creating any \`.md\` or \`.txt\` file in either:"
  printf '%s\n' "- \`$INBOX_SESSION\` (this session only)"
  printf '%s\n' "- \`$INBOX_TOP\` (any session — single-session mode)"
} >"$TMP"
mv "$TMP" "$OUT_FILE"
log "session=$SESSION_ID wrote $OUT_FILE"

# ---- mark session waiting + refresh INDEX.md -------------------------------

lb_set_status "$BRIDGE_DIR" "$SESSION_ID" "waiting" "Stop hook"
lb_index_rebuild "$BRIDGE_DIR" 2>/dev/null || true

# ---- poll inbox for reply ---------------------------------------------------

START_EPOCH="$(date +%s)"
TIMEOUT="${CLAUDE_BRIDGE_TIMEOUT:-1800}"
POLL="${CLAUDE_BRIDGE_POLL:-2}"
log "session=$SESSION_ID polling session=$INBOX_SESSION top=$INBOX_TOP timeout=${TIMEOUT}s"

REPLY_FILE=""
CANCELLED=0
while :; do
  # Cancel sentinel (dropped by `claude-bridge cancel <task>` or `/cancel`).
  # Honors the same exit-fast pattern as `stop_hook_active`.
  if [ -e "$INBOX_SESSION/.cancel" ]; then
    log "session=$SESSION_ID cancel sentinel found; releasing"
    rm -f "$INBOX_SESSION/.cancel"
    CANCELLED=1
    break
  fi
  # Per-session subfolder wins unconditionally — that is the whole point of
  # routing by session id. Top-level inbox is the fallback for single-session
  # / unrouted use.
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
    log "session=$SESSION_ID timeout reached, releasing"
    lb_set_status "$BRIDGE_DIR" "$SESSION_ID" "idle" "timed out"
    lb_index_rebuild "$BRIDGE_DIR" 2>/dev/null || true
    exit 0
  fi
  sleep "$POLL"
done

if [ "$CANCELLED" -eq 1 ]; then
  lb_set_status "$BRIDGE_DIR" "$SESSION_ID" "idle" "cancelled"
  lb_index_rebuild "$BRIDGE_DIR" 2>/dev/null || true
  exit 0
fi

REPLY_TEXT="$(cat "$REPLY_FILE")"
ARCHIVED="$ARCHIVE/${SESSION_ID}-${TS}-$(basename "$REPLY_FILE")"
mv "$REPLY_FILE" "$ARCHIVED" 2>/dev/null || true
log "session=$SESSION_ID consumed $REPLY_FILE -> $ARCHIVED"

lb_set_status "$BRIDGE_DIR" "$SESSION_ID" "idle"
lb_index_rebuild "$BRIDGE_DIR" 2>/dev/null || true

# Emit the JSON decision: tell Claude to continue with the reply as next turn.
jq -nc --arg r "$REPLY_TEXT" '{decision:"block", reason:$r}'
exit 0
