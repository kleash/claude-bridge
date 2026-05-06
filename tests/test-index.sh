#!/usr/bin/env bash
# Verify INDEX.md generation directly: seed two sessions, call lb_index_rebuild,
# assert both sessions appear, ordered by status mtime descending, and that
# the placeholder row is gone. This test would have caught the GNU-only
# `find -printf` regression we shipped in v1.2 (which yielded an empty row
# set on macOS, where BSD find lacks `-printf`).
#
# We force the BSD-find code path even on Linux by stubbing `find` so it
# rejects `-printf`, proving the implementation doesn't rely on it.
set -eo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/bin/lib-bridge.sh"

TMP="$(mktemp -d -t claude-bridge-index-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

BRIDGE="$TMP/bridge"
mkdir -p "$BRIDGE"/outbox \
         "$BRIDGE"/sessions/sid-A "$BRIDGE"/sessions/sid-A/inbox \
         "$BRIDGE"/sessions/sid-B "$BRIDGE"/sessions/sid-B/inbox \
         "$BRIDGE"/tasks

printf 'waiting\n'           > "$BRIDGE/sessions/sid-A/status"
printf 'Stop hook\n'         > "$BRIDGE/sessions/sid-A/note"
printf 'awaiting-approval\n' > "$BRIDGE/sessions/sid-B/status"
printf 'Bash\n'              > "$BRIDGE/sessions/sid-B/note"

# Map only sid-B to a friendly task name so we can assert the reverse-lookup.
printf 'sid-B' > "$BRIDGE/tasks/refactor-auth"

# Make sid-B the more recently-touched session so it should sort first.
sleep 1
touch "$BRIDGE/sessions/sid-B/status"

# --- Case 1: native run on whatever find is installed ----------------------
# shellcheck source=../bin/lib-bridge.sh
. "$LIB"
lb_index_rebuild "$BRIDGE"

INDEX="$BRIDGE/outbox/INDEX.md"
[ -f "$INDEX" ] || { echo "FAIL: INDEX.md not created"; exit 1; }

grep -q "sid-A" "$INDEX" || { echo "FAIL: sid-A missing from INDEX"; cat "$INDEX"; exit 1; }
grep -q "sid-B" "$INDEX" || { echo "FAIL: sid-B missing from INDEX"; cat "$INDEX"; exit 1; }
grep -q "refactor-auth" "$INDEX" || { echo "FAIL: task name missing"; cat "$INDEX"; exit 1; }
grep -q "awaiting-approval" "$INDEX" || { echo "FAIL: status missing"; cat "$INDEX"; exit 1; }
grep -q "no tasks yet" "$INDEX" && { echo "FAIL: placeholder row present despite seeded sessions"; cat "$INDEX"; exit 1; }
# Exactly two data rows expected. Lines starting with "| " that are NOT the
# header / separator / placeholder. This catches junk rows like the
# "Namelen: 255 Type: ext2" garbage we shipped briefly when stat -f %m got
# misinterpreted as filesystem-status mode by GNU stat.
data_rows="$(grep -c '^| [a-z]' "$INDEX" || true)"
[ "$data_rows" -eq 2 ] \
  || { echo "FAIL: expected 2 data rows, got $data_rows"; cat "$INDEX"; exit 1; }
# No session id should contain shell metacharacters or filesystem-stat words.
grep -E "Namelen|Type:|Block size|^\| .* \\\`\\.\\\`" "$INDEX" \
  && { echo "FAIL: garbage rows present in INDEX"; cat "$INDEX"; exit 1; }
true

# Verify ordering: sid-B (more recently touched) must appear before sid-A.
rowB="$(grep -n 'sid-B' "$INDEX" | head -n1 | cut -d: -f1)"
rowA="$(grep -n 'sid-A' "$INDEX" | head -n1 | cut -d: -f1)"
[ -n "$rowA" ] && [ -n "$rowB" ] || { echo "FAIL: couldn't locate session rows"; exit 1; }
[ "$rowB" -lt "$rowA" ] || {
  echo "FAIL: expected sid-B (newer) before sid-A (older); got rows B=$rowB A=$rowA"
  cat "$INDEX"; exit 1
}
echo "case 1 PASS: INDEX includes both sessions, sorted newest-first"

# --- Case 2: BSD-find shim (no -printf support) -----------------------------
# Make a fake `find` that rejects -printf so the codepath proves it doesn't
# depend on the GNU extension. This is the regression guard.
SHIMDIR="$TMP/shim"
mkdir -p "$SHIMDIR"
cat > "$SHIMDIR/find" <<'SHIM'
#!/usr/bin/env bash
# Reject -printf to mimic BSD find on macOS.
for a in "$@"; do
  if [ "$a" = "-printf" ]; then
    echo "find: -printf: unknown primary or operator" >&2
    exit 1
  fi
done
exec /usr/bin/find "$@"
SHIM
chmod +x "$SHIMDIR/find"
# Confirm /usr/bin/find exists on the test box; otherwise fall through.
if [ ! -x /usr/bin/find ]; then
  REAL_FIND="$(command -v find)"
  sed -i "s|/usr/bin/find|$REAL_FIND|" "$SHIMDIR/find"
fi

# Re-source lib in a subshell so PATH override takes effect.
rm -f "$INDEX"
( PATH="$SHIMDIR:$PATH" bash -c '
    set -e
    ROOT="'"$ROOT"'"
    BRIDGE="'"$BRIDGE"'"
    . "$ROOT/bin/lib-bridge.sh"
    lb_index_rebuild "$BRIDGE"
  '
)

[ -f "$INDEX" ] || { echo "FAIL: INDEX.md not created under BSD-find shim"; exit 1; }
grep -q "sid-A" "$INDEX" \
  || { echo "FAIL: sid-A missing under BSD-find shim (find -printf regression?)"; cat "$INDEX"; exit 1; }
grep -q "sid-B" "$INDEX" \
  || { echo "FAIL: sid-B missing under BSD-find shim"; cat "$INDEX"; exit 1; }
grep -q "no tasks yet" "$INDEX" \
  && { echo "FAIL: placeholder shown under BSD-find shim — codepath still depends on -printf"; cat "$INDEX"; exit 1; }
true
echo "case 2 PASS: lb_index_rebuild works without GNU find -printf"

# --- Case 3: empty bridge yields placeholder row ---------------------------
EMPTY="$TMP/empty"
mkdir -p "$EMPTY"
lb_index_rebuild "$EMPTY"
grep -q "no tasks yet" "$EMPTY/outbox/INDEX.md" \
  || { echo "FAIL: empty bridge should show 'no tasks yet'"; cat "$EMPTY/outbox/INDEX.md"; exit 1; }
echo "case 3 PASS: empty bridge -> placeholder row"

echo "ALL INDEX TESTS PASSED"
