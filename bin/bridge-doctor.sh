#!/usr/bin/env bash
# claude-bridge doctor: a setup-health checker. Each check prints PASS/FAIL
# with a one-line remediation. Exits non-zero on any FAIL so it's CI-friendly.
#
# Usage: bridge-doctor.sh
#        claude-bridge doctor    (preferred)
#
# License: MIT

set -u

# shellcheck source=lib-bridge.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-bridge.sh"

SETTINGS="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
DEST_DIR="${CLAUDE_BRIDGE_INSTALL_DIR:-$HOME/.claude-bridge}"
HOOK="$DEST_DIR/bridge-hook.sh"
PRETOOL="$DEST_DIR/bridge-pretool-hook.sh"
NOTIFY="$DEST_DIR/bridge-notify-hook.sh"

# ANSI colors only when stdout is a TTY.
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_FAIL=$'\033[31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_OK=""; C_FAIL=""; C_DIM=""; C_RST=""
fi

FAILED=0

pass() { printf '  %sPASS%s  %s\n'              "$C_OK"   "$C_RST" "$1"; }
warn() { printf '  %sWARN%s  %s\n               %s%s%s\n' "$C_DIM" "$C_RST" "$1" "$C_DIM" "$2" "$C_RST"; }
fail() { printf '  %sFAIL%s  %s\n               %s%s%s\n' "$C_FAIL" "$C_RST" "$1" "$C_DIM" "$2" "$C_RST"; FAILED=$((FAILED+1)); }

section() { printf '\n%s\n' "$1"; }

# 1. Dependencies
section "Dependencies"

if command -v jq >/dev/null 2>&1; then
  pass "jq: $(jq --version 2>/dev/null)"
else
  fail "jq is not on PATH" "Install jq: 'brew install jq' / 'apt install jq' and re-run."
fi

if command -v claude >/dev/null 2>&1; then
  pass "claude CLI: $(command -v claude)"
else
  warn "claude CLI not on PATH" \
       "Required for the optional router (bridge-router.sh). Stop hook still works."
fi

if [ -n "${BASH_VERSION:-}" ]; then
  pass "bash: $BASH_VERSION"
else
  warn "bash version unknown" "claude-bridge expects bash; behavior on other shells is untested."
fi

# Some sandboxed environments (corporate CI runners, locked-down containers)
# export BASH_ENV pointing at an init script that can fail under `set -u`. All
# claude-bridge hooks use `set -u`, so a broken BASH_ENV will silently abort
# every hook before it can write to outbox. Surface this so it's diagnosable.
if [ -n "${BASH_ENV:-}" ]; then
  warn "BASH_ENV is set: $BASH_ENV" \
       "If hooks silently exit with no outbox file, the BASH_ENV script may be aborting under set -u. Try unsetting it before launching claude."
fi

# 2. Hook installation
section "Hook installation ($DEST_DIR)"

[ -d "$DEST_DIR" ] && pass "$DEST_DIR exists" \
  || fail "$DEST_DIR is missing" "Run ./install.sh from the repo root."

for f in "$HOOK" "$PRETOOL" "$NOTIFY"; do
  if [ -x "$f" ]; then
    pass "$(basename "$f") installed and executable"
  elif [ -f "$f" ]; then
    fail "$(basename "$f") exists but is not executable" "chmod +x \"$f\""
  else
    fail "$(basename "$f") is missing" "Re-run ./install.sh"
  fi
done

# 3. Hook registration in settings.json
section "Claude Code settings ($SETTINGS)"

if [ -f "$SETTINGS" ]; then
  pass "settings.json present"
  if command -v jq >/dev/null 2>&1; then
    for slot in Stop PreToolUse Notification; do
      cmd_var="$HOOK"
      [ "$slot" = "PreToolUse"   ] && cmd_var="$PRETOOL"
      [ "$slot" = "Notification" ] && cmd_var="$NOTIFY"
      if jq -e --arg s "$slot" --arg c "$cmd_var" \
          '(.hooks // {})[$s] // [] | map(.hooks // []) | add // [] | map(.command) | index($c)' \
          "$SETTINGS" >/dev/null 2>&1; then
        pass "hooks.$slot registered"
      else
        if [ "$slot" = "Stop" ]; then
          fail "hooks.$slot not registered" "Re-run ./install.sh to register."
        else
          warn "hooks.$slot not registered" "Optional: re-run ./install.sh to enable phone-side ${slot,,} flow."
        fi
      fi
    done
  fi
else
  fail "settings.json missing" "Run 'claude --version' once or ./install.sh to create it."
fi

# 4. Bridge directory
section "Bridge directory"

BRIDGE_DIR="$(lb_resolve_bridge_dir)"
printf '  %s%s%s\n' "$C_DIM" "Resolved: $BRIDGE_DIR" "$C_RST"

if [ -d "$BRIDGE_DIR" ]; then
  pass "bridge dir exists"
else
  fail "bridge dir does not exist" "mkdir -p \"$BRIDGE_DIR\"/{inbox,outbox,archive} && touch \"$BRIDGE_DIR/.enabled\""
fi

if [ -w "$BRIDGE_DIR" ] 2>/dev/null; then
  pass "bridge dir writable"
else
  [ -d "$BRIDGE_DIR" ] && fail "bridge dir not writable" "Check permissions on $BRIDGE_DIR"
fi

for sub in inbox outbox archive; do
  if [ -d "$BRIDGE_DIR/$sub" ]; then
    pass "$sub/ present"
  else
    fail "$sub/ missing" "mkdir -p \"$BRIDGE_DIR/$sub\""
  fi
done

if [ -f "$BRIDGE_DIR/.enabled" ]; then
  pass ".enabled sentinel present (hook is ARMED)"
else
  warn ".enabled sentinel missing (hook is DORMANT)" \
       "touch \"$BRIDGE_DIR/.enabled\" to activate."
fi

# 5. Sync provider hint
section "Cloud sync provider"

CLOUD="$(lb_detect_cloud_dir 2>/dev/null || true)"
if [ -n "$CLOUD" ]; then
  pass "detected: $CLOUD"
else
  warn "no cloud-synced folder auto-detected" \
       "claude-bridge still works locally; set CLAUDE_BRIDGE_DIR explicitly if needed."
fi

# 6. Free space (just a heads-up if < 100 MB)
section "Free space"
if [ -d "$BRIDGE_DIR" ]; then
  free_mb=$(df -Pm "$BRIDGE_DIR" 2>/dev/null | awk 'NR==2{print $4}')
  if [ -n "${free_mb:-}" ]; then
    if [ "${free_mb}" -gt 100 ] 2>/dev/null; then
      pass "${free_mb} MB free on bridge volume"
    else
      warn "only ${free_mb} MB free on bridge volume" \
           "claude-bridge clean --days 7 will trim the archive."
    fi
  fi
fi

# 7. Log status
section "Log file"
LOGF="${CLAUDE_BRIDGE_LOG:-$(lb_default_log_path)}"
if [ -f "$LOGF" ]; then
  size_kb=$(($(wc -c < "$LOGF" 2>/dev/null || echo 0) / 1024))
  pass "log present at $LOGF (${size_kb} KB)"
  if [ "$size_kb" -gt 10240 ]; then
    warn "log > 10 MB" "claude-bridge clean rotates the log."
  fi
else
  warn "no log yet at $LOGF" "Will be created on first hook run."
fi

# Summary
printf '\n'
if [ "$FAILED" -eq 0 ]; then
  printf '%sclaude-bridge doctor: all checks PASS%s\n' "$C_OK" "$C_RST"
  exit 0
else
  printf '%sclaude-bridge doctor: %d check(s) FAILED%s\n' "$C_FAIL" "$FAILED" "$C_RST"
  exit 1
fi
