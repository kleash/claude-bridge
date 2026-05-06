#!/usr/bin/env bash
# claude-bridge: shared helpers sourced by hooks, router, dispatcher, doctor.
# This file is sourced, never executed directly. Functions are prefixed `lb_`
# to avoid colliding with anything in the caller's namespace.
#
# Why a tiny shared lib: bridge-hook.sh and bridge-router.sh already duplicate
# `default_log_path` / `detect_cloud_dir` / `log`, but they ship in v1 and we
# don't want to perturb those. The *new* primitives (INDEX rebuild, per-session
# status, permission-reply parsing) appear in 4+ scripts and would be much
# worse to duplicate than to share.

# ---- bridge-dir / cloud detection ------------------------------------------

lb_default_log_path() {
  case "$(uname -s)" in
    Darwin) printf '%s/Library/Logs/claude-bridge.log' "$HOME" ;;
    *)      printf '%s/.claude-bridge/claude-bridge.log' "$HOME" ;;
  esac
}

lb_detect_cloud_dir() {
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

lb_resolve_bridge_dir() {
  if [ -n "${CLAUDE_BRIDGE_DIR:-}" ]; then
    printf '%s' "$CLAUDE_BRIDGE_DIR"
    return
  fi
  local cloud
  cloud="$(lb_detect_cloud_dir || true)"
  if [ -n "$cloud" ]; then
    printf '%s/ClaudeBridge' "$cloud"
  else
    printf '%s/.claude-bridge/default' "$HOME"
  fi
}

# ---- per-session status ----------------------------------------------------
# A session's "status" lives at sessions/<sid>/status as a single token line:
#   waiting | idle | awaiting-approval
# An optional human-readable note lives at sessions/<sid>/note.

lb_set_status() {
  local bridge_dir="$1" sid="$2" status="$3" note="${4:-}"
  [ -n "$bridge_dir" ] && [ -n "$sid" ] || return 0
  local sdir="$bridge_dir/sessions/$sid"
  mkdir -p "$sdir"
  printf '%s\n' "$status" > "$sdir/.status.tmp.$$" \
    && mv "$sdir/.status.tmp.$$" "$sdir/status"
  if [ -n "$note" ]; then
    printf '%s\n' "$note" > "$sdir/.note.tmp.$$" \
      && mv "$sdir/.note.tmp.$$" "$sdir/note"
  else
    rm -f "$sdir/note"
  fi
}

lb_get_status() {
  local bridge_dir="$1" sid="$2"
  cat "$bridge_dir/sessions/$sid/status" 2>/dev/null || echo "idle"
}

# Reverse-lookup task name for a session id; prints empty string if none.
lb_task_for_sid() {
  local bridge_dir="$1" sid="$2" tfile
  [ -d "$bridge_dir/tasks" ] || return 0
  for tfile in "$bridge_dir"/tasks/*; do
    [ -f "$tfile" ] || continue
    if [ "$(cat "$tfile" 2>/dev/null)" = "$sid" ]; then
      basename "$tfile"
      return
    fi
  done
}

# ---- INDEX.md --------------------------------------------------------------
# Rebuild outbox/INDEX.md atomically. Source of truth is sessions/<sid>/status.

# Print one markdown table row per session, sorted by status mtime desc, plus
# a placeholder row if no sessions exist. Shared by lb_index_rebuild and the
# router's /list / /status all-tasks output.
#
# Portability: BSD find on macOS lacks `-printf '%T@ %p\n'`, so we enumerate
# matching files first and pair each with its mtime via stat (BSD `-f %m`
# falls back to GNU `-c %Y`). Verified on macOS Sonoma + Ubuntu 22.
lb_render_task_rows() {
  local bridge_dir="$1" sdir sid status note since task count=0
  if [ -d "$bridge_dir/sessions" ]; then
    while IFS= read -r sdir; do
      [ -n "$sdir" ] || continue
      sid="$(basename "$(dirname "$sdir")")"
      status="$(cat "$sdir" 2>/dev/null || echo idle)"
      note="$(cat "$(dirname "$sdir")/note" 2>/dev/null || true)"
      since="$(date -u -r "$sdir" +%FT%TZ 2>/dev/null \
               || date -u -d "@$(stat -c %Y "$sdir" 2>/dev/null)" +%FT%TZ 2>/dev/null \
               || true)"
      task="$(lb_task_for_sid "$bridge_dir" "$sid")"
      note="${note//|/\\|}"; note="${note//$'\n'/ }"
      printf '| %s | %s | `%s` | %s | %s |\n' \
        "$status" "${task:--}" "$sid" "${since:--}" "${note:--}"
      count=$((count+1))
    done < <(lb_status_files_recent "$bridge_dir")
  fi
  if [ "$count" -eq 0 ]; then
    printf '| _no tasks yet_ | — | — | — | — |\n'
  fi
}

# Emit each sessions/<sid>/status file path, newest mtime first.
# Portable replacement for `find … -printf '%T@ %p\n' | sort -rn`.
#
# Picking the mtime tool is fiddly:
#   - `stat -c %Y FILE`  → GNU only.
#   - `stat -f %m FILE`  → BSD-only intent, but GNU stat accepts `-f` as
#     "filesystem status" mode and emits a multi-line block, which then
#     poisons our pipeline (sort sees garbage paths). Avoided.
#   - `date -u -r FILE +%s` → epoch seconds on BSD AND GNU coreutils ≥ 8.21
#     (released 2013). Single-line output. This is what we use.
lb_status_files_recent() {
  local bridge_dir="$1" f m
  [ -d "$bridge_dir/sessions" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    m="$(date -u -r "$f" +%s 2>/dev/null \
         || stat -c %Y "$f" 2>/dev/null \
         || echo 0)"
    # Belt-and-braces: ensure m is a single integer, not multi-line garbage.
    m="$(printf '%s' "$m" | head -n1 | tr -dc '0-9')"
    printf '%s %s\n' "${m:-0}" "$f"
  done < <(find "$bridge_dir/sessions" -mindepth 2 -maxdepth 2 -name status -type f 2>/dev/null) \
    | sort -rn \
    | awk '{ $1=""; sub(/^ /,""); print }'
}

lb_index_rebuild() {
  local bridge_dir="$1"
  [ -n "$bridge_dir" ] || return 0
  mkdir -p "$bridge_dir/outbox"
  local index="$bridge_dir/outbox/INDEX.md"
  local tmp="$index.tmp.$$"
  {
    printf '%s\n\n' '# claude-bridge — task index'
    printf '_Updated: %s_\n\n' "$(date -u +%FT%TZ)"
    printf 'Drop a reply file in `inbox/` (or `sessions/<sid>/inbox/`) to resume a waiting session.\n\n'
    printf '| Status | Task | Session | Last update | Note |\n'
    printf '|---|---|---|---|---|\n'
    lb_render_task_rows "$bridge_dir"
  } > "$tmp" 2>/dev/null && mv "$tmp" "$index"
}

# ---- permission-reply parser ----------------------------------------------
# Input: $1 = full body of phone's reply file.
# Sets globals REPLY_DECISION ("approve"|"block") and REPLY_REASON (string).
#
# Recognized first-line tokens (case-insensitive):
#   approve | approved | yes | y | ok | allow            -> approve
#   deny | denied | no | n | reject | rejected | block   -> block, default reason
#   deny:<reason>   reject:<reason>   block:<reason>     -> block, custom reason
# Anything else: block with the entire body as the reason. That lets the
# phone user type free-form ("no, instead do X") and have Claude see it.

lb_parse_permission_reply() {
  local body="$1"
  body="${body//$'\r'/}"
  local first lower
  first="$(printf '%s' "$body" | awk 'NF{sub(/^[ \t]+/,""); sub(/[ \t]+$/,""); print; exit}')"
  lower="$(printf '%s' "$first" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    approve|approved|yes|y|ok|allow|approve.)
      REPLY_DECISION="approve"
      REPLY_REASON="approved by phone"
      return ;;
    deny|denied|no|n|reject|rejected|block|deny.)
      REPLY_DECISION="block"
      REPLY_REASON="denied by phone"
      return ;;
  esac
  case "$lower" in
    deny:*|reject:*|block:*|"deny "*|"reject "*)
      REPLY_DECISION="block"
      REPLY_REASON="$(printf '%s' "$first" | sed -E 's/^[Dd]eny[: ]+|^[Rr]eject[: ]+|^[Bb]lock[: ]+//')"
      [ -n "$REPLY_REASON" ] || REPLY_REASON="denied by phone"
      return ;;
  esac
  REPLY_DECISION="block"
  REPLY_REASON="$body"
}

# ---- misc helpers ----------------------------------------------------------

lb_sanitize_id() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | sed 's/^_*//; s/_*$//'
}

# Resolve a task token (title or raw session id) to a session id; empty if
# unknown. Mirrors the router's `resolve_task` logic.
lb_resolve_task() {
  local bridge_dir="$1" id="$2" safe
  safe="$(lb_sanitize_id "$id")"
  if [ -n "$safe" ] && [ -f "$bridge_dir/tasks/$safe" ]; then
    cat "$bridge_dir/tasks/$safe"
  elif printf '%s' "$id" | grep -Eq '^[0-9a-fA-F-]{8,}$'; then
    printf '%s' "$id"
  fi
}

# Drop the cancel sentinel for a task. Args: bridge_dir, task_or_sid.
# Prints the resolved session id on success, or "" on failure.
lb_cancel_task() {
  local bridge_dir="$1" id="$2" sid sdir
  sid="$(lb_resolve_task "$bridge_dir" "$id")"
  [ -n "$sid" ] || return 1
  sdir="$bridge_dir/sessions/$sid/inbox"
  mkdir -p "$sdir"
  : > "$sdir/.cancel"
  printf '%s' "$sid"
}

# ---- retention / log rotation ----------------------------------------------

# Delete archive entries older than N days. Args: bridge_dir, days.
lb_clean_archive() {
  local bridge_dir="$1" days="${2:-14}" archive
  archive="$bridge_dir/archive"
  [ -d "$archive" ] || return 0
  find "$archive" -type f -mtime "+${days}" -delete 2>/dev/null || true
  find "$archive" -type d -empty -mindepth 1 -delete 2>/dev/null || true
}

# Rotate the log file if it exceeds N bytes. Keeps last 3 generations.
# Args: log_path, max_bytes (default 10485760 = 10 MB).
lb_rotate_log() {
  local logf="$1" max="${2:-10485760}" size
  [ -f "$logf" ] || return 0
  size="$(wc -c < "$logf" 2>/dev/null | tr -d ' ' || echo 0)"
  [ "${size:-0}" -gt "$max" ] || return 0
  rm -f "$logf.3"
  for n in 2 1; do
    [ -f "$logf.$n" ] && mv "$logf.$n" "$logf.$((n+1))"
  done
  mv "$logf" "$logf.1"
  : > "$logf"
}
