#!/usr/bin/env bash
# claude-bridge router (v1.1): watches the top-level inbox/ for files starting
# with `/new <title>` or `/task <id>` directives and either spawns a new
# headless `claude -p` session or resumes an existing one with `--resume`.
# Output is written to outbox/ as the Stop hook would, so phone consumers see
# a uniform stream regardless of who produced the turn.
#
# Bare files (no directive) are routed to the per-session inbox of the only
# active task if there is exactly one; otherwise they are flagged in outbox.
#
# This is a long-running process. Start it from a launchd / systemd unit, a
# tmux pane, or just `nohup ./bin/bridge-router.sh &`.
#
# Env (all optional):
#   CLAUDE_BRIDGE_DIR       same dir as the Stop hook
#   CLAUDE_BRIDGE_POLL      poll interval in seconds (default 2)
#   CLAUDE_BRIDGE_LOG       log path (default: same as hook)
#   CLAUDE_BRIDGE_WORKDIR   cwd for spawned `claude` (default: $HOME)
#   CLAUDE_BRIDGE_CLAUDE    path to claude binary (default: claude on PATH)
#   CLAUDE_BRIDGE_FLAGS     extra flags passed to claude -p (default:
#                           --dangerously-skip-permissions)
#
# License: MIT

set -u

default_log_path() {
  case "$(uname -s)" in
    Darwin) printf '%s/Library/Logs/claude-bridge.log' "$HOME" ;;
    *)      printf '%s/.claude-bridge/claude-bridge.log' "$HOME" ;;
  esac
}

detect_cloud_dir() {
  local candidates=(
    "$HOME"/Library/CloudStorage/OneDrive*
    "$HOME"/OneDrive*
    "$HOME"/Library/CloudStorage/Dropbox*
    "$HOME"/Dropbox
    "$HOME"/Library/Mobile\ Documents/com~apple~CloudDocs
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
log() { printf '[%s] router: %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"; }

if ! command -v jq >/dev/null 2>&1; then
  printf 'router: jq is required\n' >&2
  exit 1
fi

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

if [ ! -f "$BRIDGE_DIR/.enabled" ]; then
  log "disabled (no $BRIDGE_DIR/.enabled); exiting"
  exit 0
fi

POLL="${CLAUDE_BRIDGE_POLL:-2}"
WORKDIR="${CLAUDE_BRIDGE_WORKDIR:-$HOME}"
CLAUDE_BIN="${CLAUDE_BRIDGE_CLAUDE:-claude}"
EXTRA_FLAGS="${CLAUDE_BRIDGE_FLAGS:---dangerously-skip-permissions}"

INBOX="$BRIDGE_DIR/inbox"
OUTBOX="$BRIDGE_DIR/outbox"
ARCHIVE="$BRIDGE_DIR/archive"
TASKS="$BRIDGE_DIR/tasks"
SESSIONS="$BRIDGE_DIR/sessions"
mkdir -p "$INBOX" "$OUTBOX" "$ARCHIVE" "$TASKS" "$SESSIONS"

log "starting; bridge=$BRIDGE_DIR workdir=$WORKDIR poll=${POLL}s"

# ---- helpers ----------------------------------------------------------------

# Sanitize a free-form title into a safe filesystem token.
sanitize_id() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | sed 's/^_*//; s/_*$//'
}

# Resolve a task id (title or raw session id) to a session id; empty if unknown.
resolve_task() {
  local id="$1" safe
  safe="$(sanitize_id "$id")"
  if [ -n "$safe" ] && [ -f "$TASKS/$safe" ]; then
    cat "$TASKS/$safe"
  elif printf '%s' "$id" | grep -Eq '^[0-9a-f-]{8,}$'; then
    printf '%s' "$id"
  fi
}

write_outbox() {
  local sid="$1" label="$2" body="$3"
  local ts file tmp
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  file="$OUTBOX/${sid:-router}-${ts}.md"
  tmp="$file.tmp"
  {
    printf '%s\n\n' '# Claude turn output (router)'
    printf '%s\n' "- session: \`${sid:-?}\`"
    printf '%s\n' "- task: \`$label\`"
    printf '%s\n\n' "- timestamp: \`$ts\`"
    printf '%s\n\n' '---'
    printf '%s\n\n' "$body"
    printf '%s\n' '---'
    printf '\n%s\n' "Reply with a file in \`$INBOX\` starting with:"
    printf '%s\n' "\`/task $label\`"
  } >"$tmp"
  mv "$tmp" "$file"
  log "wrote $file"
}

# Run claude -p; stdout = JSON. Returns 0 on success.
run_claude() {
  local prompt="$1" resume_sid="${2:-}" out
  out="$(mktemp -t claude-bridge-router.XXXXXX)"
  if [ -n "$resume_sid" ]; then
    # shellcheck disable=SC2086
    ( cd "$WORKDIR" && "$CLAUDE_BIN" -p "$prompt" \
        --resume "$resume_sid" \
        --output-format json \
        $EXTRA_FLAGS ) > "$out" 2>>"$LOG"
  else
    # shellcheck disable=SC2086
    ( cd "$WORKDIR" && "$CLAUDE_BIN" -p "$prompt" \
        --output-format json \
        $EXTRA_FLAGS ) > "$out" 2>>"$LOG"
  fi
  local rc=$?
  if [ $rc -ne 0 ]; then
    log "claude -p failed rc=$rc"
    rm -f "$out"
    return $rc
  fi
  printf '%s' "$out"
}

handle_new() {
  local title="$1" body="$2" safe out sid result
  safe="$(sanitize_id "$title")"
  [ -n "$safe" ] || safe="task-$(date +%s)"
  log "/new title='$title' -> id=$safe"
  out="$(run_claude "$body" "")" || {
    write_outbox "" "$safe" "claude -p failed; see log"
    return
  }
  sid="$(jq -r '.session_id // empty' "$out")"
  result="$(jq -r '.result // empty' "$out")"
  rm -f "$out"
  if [ -z "$sid" ]; then
    write_outbox "" "$safe" "claude returned no session_id; see log"
    return
  fi
  printf '%s' "$sid" > "$TASKS/$safe"
  mkdir -p "$SESSIONS/$sid/inbox"
  write_outbox "$sid" "$safe" "$result"
}

handle_task() {
  local id="$1" body="$2" sid out new_sid result safe
  safe="$(sanitize_id "$id")"
  sid="$(resolve_task "$id")"
  if [ -z "$sid" ]; then
    log "/task '$id' unknown; ignoring"
    write_outbox "" "$safe" "unknown task id: $id"
    return
  fi
  log "/task '$id' -> $sid"
  out="$(run_claude "$body" "$sid")" || {
    write_outbox "$sid" "$safe" "claude -p --resume failed; see log"
    return
  }
  new_sid="$(jq -r '.session_id // empty' "$out")"
  result="$(jq -r '.result // empty' "$out")"
  rm -f "$out"
  # The Claude SDK may rotate session_id on resume; keep the mapping fresh.
  if [ -n "$new_sid" ] && [ -n "$safe" ]; then
    printf '%s' "$new_sid" > "$TASKS/$safe"
  fi
  write_outbox "${new_sid:-$sid}" "$safe" "$result"
}

# parse one inbox file (already established to exist)
process_file() {
  local f="$1" first body ts
  first="$(head -n1 "$f" 2>/dev/null || true)"
  body="$(tail -n +2 "$f" 2>/dev/null || true)"
  # Strip trailing CR (Windows-edited files via OneDrive) for safety.
  first="${first%$'\r'}"
  case "$first" in
    /new\ *)   handle_new "${first#/new }" "$body" ;;
    /new)      handle_new "untitled" "$body" ;;
    /task\ *)  handle_task "${first#/task }" "$body" ;;
    /task)     log "malformed /task line in $f"
               write_outbox "" "router" "/task without an id in $(basename "$f")" ;;
    *)         log "no directive in $(basename "$f"); leaving for hook"
               # Don't archive — let any active Stop hook on top-level inbox
               # consume it as before.
               return 1 ;;
  esac
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  mv "$f" "$ARCHIVE/router-$ts-$(basename "$f")" 2>/dev/null || true
}

# ---- main loop --------------------------------------------------------------

trap 'log "shutting down"; exit 0' INT TERM

while :; do
  if [ ! -f "$BRIDGE_DIR/.enabled" ]; then
    log "kill-switch removed; exiting"
    exit 0
  fi
  for f in "$INBOX"/*.md "$INBOX"/*.txt; do
    [ -f "$f" ] || continue
    process_file "$f" || true
  done
  sleep "$POLL"
done
