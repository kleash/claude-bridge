#!/usr/bin/env bash
# Verify bridge-doctor.sh exits 0 on a healthy install and non-zero when
# something obvious is missing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCTOR="$ROOT/bin/bridge-doctor.sh"

TMP="$(mktemp -d -t claude-bridge-doctor-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Simulate an installed environment.
INSTALL_DIR="$TMP/install"
SETTINGS="$TMP/settings.json"
BRIDGE="$TMP/bridge"
mkdir -p "$INSTALL_DIR" "$BRIDGE"/{inbox,outbox,archive}
touch "$BRIDGE/.enabled"

cp "$ROOT/bin/bridge-hook.sh"          "$INSTALL_DIR/"
cp "$ROOT/bin/bridge-pretool-hook.sh"  "$INSTALL_DIR/"
cp "$ROOT/bin/bridge-notify-hook.sh"   "$INSTALL_DIR/"
cp "$ROOT/bin/lib-bridge.sh"           "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR"/*.sh

cat > "$SETTINGS" <<JSON
{
  "hooks": {
    "Stop":         [{"matcher":"","hooks":[{"type":"command","command":"$INSTALL_DIR/bridge-hook.sh"}]}],
    "PreToolUse":   [{"matcher":"","hooks":[{"type":"command","command":"$INSTALL_DIR/bridge-pretool-hook.sh"}]}],
    "Notification": [{"matcher":"","hooks":[{"type":"command","command":"$INSTALL_DIR/bridge-notify-hook.sh"}]}]
  }
}
JSON

CLAUDE_BRIDGE_DIR="$BRIDGE" \
CLAUDE_BRIDGE_INSTALL_DIR="$INSTALL_DIR" \
CLAUDE_SETTINGS_FILE="$SETTINGS" \
CLAUDE_BRIDGE_LOG="$TMP/log" \
bash "$DOCTOR" > "$TMP/healthy.out" 2>&1
case "$(tail -n1 "$TMP/healthy.out")" in
  *"all checks PASS"*) ;;
  *) echo "FAIL: doctor on a healthy setup did not report success:"
     cat "$TMP/healthy.out"; exit 1 ;;
esac
echo "case 1 PASS: doctor exits 0 on healthy setup"

# --- Case 2: missing hook -> non-zero exit ---------------------------------
rm "$INSTALL_DIR/bridge-hook.sh"
RC=0
CLAUDE_BRIDGE_DIR="$BRIDGE" \
CLAUDE_BRIDGE_INSTALL_DIR="$INSTALL_DIR" \
CLAUDE_SETTINGS_FILE="$SETTINGS" \
CLAUDE_BRIDGE_LOG="$TMP/log" \
bash "$DOCTOR" > "$TMP/sick.out" 2>&1 || RC=$?
[ "$RC" -ne 0 ] || { echo "FAIL: doctor exit code 0 with missing hook"; cat "$TMP/sick.out"; exit 1; }
grep -q "FAIL" "$TMP/sick.out" \
  || { echo "FAIL: doctor output missing FAIL line"; cat "$TMP/sick.out"; exit 1; }
echo "case 2 PASS: doctor exits non-zero when bridge-hook.sh is missing"

# --- Case 3: missing .enabled is a WARN, not a FAIL -----------------------
cp "$ROOT/bin/bridge-hook.sh" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/bridge-hook.sh"
rm -f "$BRIDGE/.enabled"
RC=0
CLAUDE_BRIDGE_DIR="$BRIDGE" \
CLAUDE_BRIDGE_INSTALL_DIR="$INSTALL_DIR" \
CLAUDE_SETTINGS_FILE="$SETTINGS" \
CLAUDE_BRIDGE_LOG="$TMP/log" \
bash "$DOCTOR" > "$TMP/dormant.out" 2>&1 || RC=$?
[ "$RC" -eq 0 ] || { echo "FAIL: missing .enabled should warn, not fail"; cat "$TMP/dormant.out"; exit 1; }
grep -q "WARN" "$TMP/dormant.out" \
  || { echo "FAIL: doctor output missing WARN for missing .enabled"; cat "$TMP/dormant.out"; exit 1; }
echo "case 3 PASS: missing .enabled -> WARN, exit 0"

echo "ALL DOCTOR TESTS PASSED"
