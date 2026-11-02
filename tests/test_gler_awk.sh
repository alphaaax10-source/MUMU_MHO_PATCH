#!/bin/sh
# Unit tests for lib/renderer.awk gler modes (mawk/busybox-awk compatible).
AWK=/home/user/proton_probe/downloads/extract_1.4.1/lib/renderer.awk
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); echo "FAIL: $1"; }
check() { # desc expected_rc expected_out actual_rc actual_out
  if [ "$2" = "$4" ] && [ "$3" = "$5" ]; then ok; else bad "$1 (rc: want=$2 got=$4; out: want=[$3] got=[$5])"; fi
}
pkg=com.garena.game.mho

# Fixture: two app blocks; target has spoof, no gler.
cat > "$T/c1.config" <<'EOF'
# Configuration Begin
Name com.other.app
VkFlag 1
CustomizedRendererString Adreno (TM) 650
Name com\.garena\.game\.mho
VkFlag 1
CustomizedRendererString Mali-G610
Name org.example.third
CustomizedRendererString Adreno (TM) 740
# Configuration End
EOF

# gler-state: absent (block exists)
rc=0; out=$(awk -v package="$pkg" -v mode=gler-state -f "$AWK" "$T/c1.config" 2>&1) || rc=$?
check "gler-state absent" 11 "" "$rc" "$out"

# gler-add: insert after Name of target block
rc=0; out=$(awk -v package="$pkg" -v mode=gler-add -f "$AWK" "$T/c1.config" 2>"$T/e1") || rc=$?
check "gler-add inserts into block (rc)" 0 "" "$rc" ""
printf '%s\n' "$out" > "$T/c2.config"
if grep -q '^Name com\\\.garena\\\.game\\\.mho$' "$T/c2.config" \
   && awk '/^Name com\\\.garena/{getline; if($0=="IgnoreGLError 1") found=1} END{exit !found}' "$T/c2.config"; then ok; else bad "gler-add position/value"; fi
# other blocks untouched
grep -c 'IgnoreGLError' "$T/c2.config" | grep -qx 1 && ok || bad "gler-add single insertion"

# gler-state: applied on c2
rc=0; out=$(awk -v package="$pkg" -v mode=gler-state -f "$AWK" "$T/c2.config") || rc=$?
check "gler-state applied" 0 "IgnoreGLError 1" "$rc" "$out"

# gler-add idempotent: already present
rc=0; out=$(awk -v package="$pkg" -v mode=gler-add -f "$AWK" "$T/c2.config") || rc=$?
check "gler-add already present" 10 "" "$rc" "$out"

# gler-remove without drop_block
rc=0; out=$(awk -v package="$pkg" -v mode=gler-remove -v drop_block=0 -f "$AWK" "$T/c2.config") || rc=$?
check "gler-remove rc" 0 "" "$rc" ""
printf '%s\n' "$out" > "$T/c3.config"
grep -q 'IgnoreGLError' "$T/c3.config" && bad "gler-remove removed line" || ok
grep -q 'Name com\\\.garena\\\.game\\\.mho' "$T/c3.config" && ok || bad "gler-remove kept Name"

# gler-remove with drop_block but other keys present -> keep Name
rc=0; out=$(awk -v package="$pkg" -v mode=gler-remove -v drop_block=1 -f "$AWK" "$T/c2.config") || rc=$?
printf '%s\n' "$out" > "$T/c4.config"
grep -q 'Name com\\\.garena' "$T/c4.config" && ok || bad "gler-remove keeps Name when other keys"
grep -q 'IgnoreGLError' "$T/c4.config" && bad "gler-remove strips gler" || ok

# gler-remove nothing to remove
rc=0; out=$(awk -v package="$pkg" -v mode=gler-remove -f "$AWK" "$T/c1.config") || rc=$?
check "gler-remove nothing" 10 "" "$rc" "$out"

# no target block: state=4, add creates block at end, remove=4
cat > "$T/cnb.config" <<'EOF'
# Configuration Begin
Name com.other.app
VkFlag 1
# Configuration End
EOF
rc=0; out=$(awk -v package="$pkg" -v mode=gler-state -f "$AWK" "$T/cnb.config") || rc=$?
check "gler-state no block" 4 "" "$rc" "$out"
rc=0; out=$(awk -v package="$pkg" -v mode=gler-add -f "$AWK" "$T/cnb.config") || rc=$?
check "gler-add creates block" 1 "" "$rc" ""
printf '%s\n' "$out" > "$T/c5.config"
printf '%s\n' "$out" > "$T/c5.config"
tail -n 2 "$T/c5.config" > "$T/tail"
cat > "$T/want" <<'EOF'
Name com\.garena\.game\.mho
IgnoreGLError 1
EOF
if cmp -s "$T/tail" "$T/want"; then ok; else bad "created block content: [$(cat "$T/tail")]"; fi
rc=0; awk -v package="$pkg" -v mode=gler-state -f "$AWK" "$T/c5.config" >/dev/null || rc=$?
check "gler-state after create" 0 "" "$rc" ""
rc=0; out=$(awk -v package="$pkg" -v mode=gler-remove -v drop_block=1 -f "$AWK" "$T/c5.config") || rc=$?
printf '%s\n' "$out" > "$T/c6.config"
if ! grep -q 'IgnoreGLError' "$T/c6.config" && ! grep -q 'Name com\\\.garena' "$T/c6.config"; then ok; else bad "drop_block removes created block"; fi

# drop_block with other keys -> block stays (Name + others), gler gone
cat > "$T/c7.config" <<'EOF'
Name com\.garena\.game\.mho
IgnoreGLError 1
VkFlag 1
EOF
rc=0; out=$(awk -v package="$pkg" -v mode=gler-remove -v drop_block=1 -f "$AWK" "$T/c7.config") || rc=$?
printf '%s\n' "$out" > "$T/c8.config"
grep -q 'Name com\\\.garena' "$T/c8.config" && ok || bad "drop_block keeps block with keys"
grep -q 'IgnoreGLError' "$T/c8.config" && bad "drop_block removes gler" || ok
grep -q 'VkFlag 1' "$T/c8.config" && ok || bad "drop_block keeps other keys"

# duplicate Name blocks for target: state/add/remove -> 3
cat > "$T/c9.config" <<'EOF'
Name com\.garena\.game\.mho
VkFlag 1
Name com\.garena\.game\.mho
VkFlag 2
EOF
for m in gler-state gler-add gler-remove; do
  rc=0; awk -v package="$pkg" -v mode=$m -f "$AWK" "$T/c9.config" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 3 ] && ok || bad "$m multi-block rc=$rc"
done

# CRLF file: name() unescape still matches; insertion works
cat > "$T/c10.config" <<'EOF'
# Configuration Begin
Name com\.garena\.game\.mho
VkFlag 1
EOF
sed 's/$/\r/' "$T/c10.config" > "$T/c10b.config"
mv "$T/c10b.config" "$T/c10.config"
rc=0; out=$(awk -v package="$pkg" -v mode=gler-add -f "$AWK" "$T/c10.config") || rc=$?
check "gler-add CRLF rc" 0 "" "$rc" ""
printf '%s\n' "$out" > "$T/c11.config"
grep -q '^IgnoreGLError 1$' "$T/c11.config" && ok || bad "gler-add CRLF insert"

# unescaped Name form (community style) also matches
cat > "$T/c12.config" <<'EOF'
Name com.garena.game.mho
IgnoreGLError 1
EOF
rc=0; awk -v package="$pkg" -v mode=gler-state -f "$AWK" "$T/c12.config" >/dev/null || rc=$?
check "gler-state unescaped name" 0 "" "$rc" ""

# existing modes still pass quick sanity: fields/remove/merge
rc=0; out=$(awk -v package="$pkg" -v mode=fields -f "$AWK" "$T/c1.config") || rc=$?
check "fields still works" 0 "CustomizedRendererString Mali-G610" "$rc" "$out"
rc=0; awk -v package="$pkg" -v mode=remove -f "$AWK" "$T/c1.config" > "$T/c13" || rc=$?
check "remove still works" 0 "" "$rc" ""
grep -q 'CustomizedRendererString Mali-G610' "$T/c13" && bad "remove strips" || ok
grep -q 'Name com\\\.garena' "$T/c13" && ok || bad "remove keeps Name"

echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
