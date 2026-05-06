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

# shellcheck source=lib-bridge.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-bridge.sh"

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
  lb_set_status "$BRIDGE_DIR" "$sid" "idle" "$safe"
  write_outbox "$sid" "$safe" "$result"
  lb_index_rebuild "$BRIDGE_DIR" 2>/dev/null || true
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
  lb_set_status "$BRIDGE_DIR" "${new_sid:-$sid}" "idle" "$safe"
  lb_index_rebuild "$BRIDGE_DIR" 2>/dev/null || true
}

# Build a markdown table of all known sessions, for /list and /status.
render_task_table() {
  local sdir sid status note since task count=0
  printf '| Status | Task | Session | Last update | Note |\n'
  printf '|---|---|---|---|---|\n'
  if [ -d "$BRIDGE_DIR/sessions" ]; then
    while IFS= read -r sdir; do
      [ -n "$sdir" ] || continue
      sid="$(basename "$(dirname "$sdir")")"
      status="$(cat "$sdir" 2>/dev/null || echo idle)"
      note="$(cat "$(dirname "$sdir")/note" 2>/dev/null || true)"
      since="$(date -u -r "$sdir" +%FT%TZ 2>/dev/null \
               || date -u -d "@$(stat -c %Y "$sdir" 2>/dev/null)" +%FT%TZ 2>/dev/null \
               || true)"
      task="$(lb_task_for_sid "$BRIDGE_DIR" "$sid")"
      note="${note//|/\\|}"; note="${note//$'\n'/ }"
      printf '| %s | %s | `%s` | %s | %s |\n' \
        "$status" "${task:--}" "$sid" "${since:--}" "${note:--}"
      count=$((count+1))
    done < <(find "$BRIDGE_DIR/sessions" -mindepth 2 -maxdepth 2 -name status -type f -printf '%T@ %p\n' 2>/dev/null \
              | sort -rn \
              | awk '{ $1=""; sub(/^ /,""); print }')
  fi
  if [ "$count" -eq 0 ]; then
    printf '| _no tasks yet_ | — | — | — | — |\n'
  fi
}

handle_list() {
  log "/list"
  local body
  body="$(printf '## All tasks\n\n%s\n' "$(render_task_table)")"
  write_outbox "" "list" "$body"
}

handle_status() {
  local id="${1:-}" sid task body
  if [ -z "$id" ]; then
    log "/status (all)"
    body="$(printf '## Status\n\n%s\n' "$(render_task_table)")"
    write_outbox "" "status" "$body"
    return
  fi
  log "/status $id"
  sid="$(lb_resolve_task "$BRIDGE_DIR" "$id")"
  if [ -z "$sid" ]; then
    write_outbox "" "status" "unknown task id: $id"
    return
  fi
  task="$(lb_task_for_sid "$BRIDGE_DIR" "$sid")"
  body="$(printf '## Status — %s\n\n- session: `%s`\n- status: `%s`\n- note: %s\n' \
    "${task:-$id}" "$sid" \
    "$(lb_get_status "$BRIDGE_DIR" "$sid")" \
    "$(cat "$BRIDGE_DIR/sessions/$sid/note" 2>/dev/null || echo '—')")"
  write_outbox "$sid" "${task:-$id}" "$body"
}

handle_cancel() {
  local id="${1:-}" sid task
  if [ -z "$id" ]; then
    write_outbox "" "router" "/cancel needs a task id or session id"
    return
  fi
  log "/cancel $id"
  sid="$(lb_cancel_task "$BRIDGE_DIR" "$id" || true)"
  if [ -z "$sid" ]; then
    write_outbox "" "router" "unknown task id: $id"
    return
  fi
  task="$(lb_task_for_sid "$BRIDGE_DIR" "$sid")"
  write_outbox "$sid" "${task:-$id}" \
    "Cancel sentinel dropped for \`${task:-$sid}\`. The waiting hook will release within one poll cycle."
  lb_index_rebuild "$BRIDGE_DIR" 2>/dev/null || true
}

handle_help() {
  log "/help"
  local body
  body=$'## claude-bridge directives\n\n'
  body+=$'| First line of inbox file | Effect |\n'
  body+=$'|---|---|\n'
  body+=$'| `/new <title>` | Spawn a new headless `claude -p` session; rest of file is the prompt. |\n'
  body+=$'| `/task <id>` | Resume the recorded session via `claude --resume`; rest of file is the prompt. |\n'
  body+=$'| `/list` | Write a table of all known tasks to outbox. |\n'
  body+=$'| `/status [task]` | Status of one task, or all if omitted. |\n'
  body+=$'| `/cancel <task>` | Drop a `.cancel` sentinel; any waiting hook for that task releases. |\n'
  body+=$'| `/clean [--days N]` | Delete archive entries older than N days (default 14). |\n'
  body+=$'| `/help` | Print this cheatsheet. |\n'
  body+=$'\nReplies to a Stop or PreToolUse hook are *bare* files (no directive) — those are routed to the per-session inbox and consumed by the waiting hook.\n'
  write_outbox "" "help" "$body"
}

handle_clean() {
  local days=14 arg
  for arg in "$@"; do
    case "$arg" in
      --days=*) days="${arg#--days=}" ;;
      --days)   : ;; # next loop iter handles value below
      *) [[ "$arg" =~ ^[0-9]+$ ]] && days="$arg" ;;
    esac
  done
  log "/clean days=$days"
  lb_clean_archive "$BRIDGE_DIR" "$days"
  lb_rotate_log    "$LOG"
  write_outbox "" "clean" \
    "Pruned archive entries older than ${days} days; rotated log if needed."
}

# parse one inbox file (already established to exist)
process_file() {
  local f="$1" first body ts
  first="$(head -n1 "$f" 2>/dev/null || true)"
  body="$(tail -n +2 "$f" 2>/dev/null || true)"
  # Strip trailing CR (Windows-edited files via OneDrive) for safety.
  first="${first%$'\r'}"
  parse_directive "$first" "$body" || return 1
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  mv "$f" "$ARCHIVE/router-$ts-$(basename "$f")" 2>/dev/null || true
}

# Centralized directive switch. Args: first_line, body. Returns non-zero if
# the file is bare (no directive) so the caller leaves it for the Stop hook.
parse_directive() {
  local first="$1" body="$2"
  case "$first" in
    /new\ *)     handle_new "${first#/new }" "$body" ;;
    /new)        handle_new "untitled" "$body" ;;
    /task\ *)    handle_task "${first#/task }" "$body" ;;
    /task)       log "malformed /task"
                 write_outbox "" "router" "/task without an id" ;;
    /list|/list\ *)         handle_list ;;
    /status)                handle_status "" ;;
    /status\ *)             handle_status "${first#/status }" ;;
    /cancel)                handle_cancel "" ;;
    /cancel\ *)             handle_cancel "${first#/cancel }" ;;
    /help|/help\ *)         handle_help ;;
    /clean)                 handle_clean ;;
    /clean\ *)              # shellcheck disable=SC2086
                            handle_clean ${first#/clean } ;;
    *)           # No directive — leave it for the Stop hook on top-level inbox.
                 log "no directive in inbox file; leaving for hook"
                 return 1 ;;
  esac
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
