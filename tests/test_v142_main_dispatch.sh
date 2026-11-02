#!/bin/sh
# main() dispatch tests for v1.4.2: ueini, gpu-cache-reset, shared-save
# (4-arg backward compat + 5-arg), shared-status, status.
set -u
MOD=${MOD:-/home/user/proton_probe/downloads/extract_1.4.1}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); echo "FAIL: $1"; }

LIBT="$T/lib"; mkdir -p "$LIBT" "$T/state"
for f in engine multi renderer; do
	sed -e 's|^STATE_DIR="/data/adb/mho_mumu_patcher"|STATE_DIR="$TEST_STATE_DIR"|' \
	    -e 's|^MODDIR=${0%/\*}|MODDIR="$TEST_MODDIR"|' \
	    -e 's|^RUN_MODE=${1:-manual}|RUN_MODE=${TEST_RUN_MODE}|' \
	    "$MOD/lib/$f.sh" > "$LIBT/$f.sh"
done
export TEST_STATE_DIR="$T/state"
TEST_MODDIR=$MOD
TEST_RUN_MODE=status
MODDIR=$MOD
STATUS_FILE="$T/status.log"; : > "$STATUS_FILE"

. "$LIBT/engine.sh"
. "$LIBT/multi.sh"
. "$LIBT/renderer.sh"
QUIET=1
TEMP_FILES=""

UEINI_DATA_ROOT="$T/datadata"
GPU_CACHE_DATA_ROOT="$T/datadata"
RENDERER_SYSTEM_CONFIG="$T/system/renderer.config"
RENDERER_DATA_CONFIG="$T/data/renderer.config"
mkdir -p "$T/system" "$T/data"
printf '# template\n' > "$RENDERER_SYSTEM_CONFIG"
printf '# data\n' > "$RENDERER_DATA_CONFIG"
MUMU_DETECTED=0
pkg=com.garena.game.mho

migrate_state >/dev/null 2>&1 || { echo "migrate_state failed"; exit 1; }
# NOTE: do not call normalize_profiles in the harness shell. main() normalizes
# per invocation (fresh process in production); a second call with the same $$
# would truncate .profiles.$$ onto itself.

# Production invokes apply_patch.sh as a fresh process per call (EXIT trap
# releases the lock). In this harness every main() runs in a subshell, so the
# wrapper clears the lock afterwards.
run_main() {
	( main "$@" )
	rc=$?
	rm -rf "$LOCK_DIR"
	return $rc
}

# --- shared-save: 4 args (old WebUI) must still work ---
( run_main shared-save 0 0 0 0 ) >/dev/null 2>&1 && ok || bad "1a old 4-arg shared-save"
grep -q '^mandatory_gler_disabled=0$' "$SHARED_DIR/preferences.conf" && ok || bad "1b gler default saved as 0"

# --- shared-save: 5 args disables gler ---
( run_main shared-save 0 0 0 0 1 ) >/dev/null 2>&1 && ok || bad "1c new 5-arg shared-save"
grep -q '^mandatory_gler_disabled=1$' "$SHARED_DIR/preferences.conf" && ok || bad "1d gler saved as 1"
grep -q '^renderer_policy=all_profiles$' "$SHARED_DIR/preferences.conf" && ok || bad "1e renderer_policy kept"

# --- shared-status keys ---
out=$(run_main shared-status 2>/dev/null)
printf '%s\n' "$out" | grep -q '^mandatory_gler_saved_disabled=1$' && ok || bad "2a gler pref key"
printf '%s\n' "$out" | grep -q '^gler_state=' && ok || bad "2b gler_state key"
printf '%s\n' "$out" | grep -q '^ueini_state=unavailable$' && ok || bad "2c ueini key"
printf '%s\n' "$out" | grep -q '^renderer_scope=all_profiles$' && ok || bad "2d legacy keys intact"

# --- ueini dispatch ---
ue_dir="$UEINI_DATA_ROOT/$pkg/files/UnrealGame/MHOutlanders/Saved/Config/Android"
mkdir -p "$ue_dir"
printf '[Audio]\nX=1\n' > "$ue_dir/Engine.ini"
out=$(run_main ueini "$pkg" on 2>/dev/null)
printf '%s\n' "$out" | grep -q '^ueini_state=applied$' && ok || bad "3a ueini on output"
grep -q 'r.Streaming.PoolSize=1024' "$ue_dir/Engine.ini" && ok || bad "3b block written"
out=$(run_main status "$pkg" 2>/dev/null)
printf '%s\n' "$out" | grep -q '^ueini_state=applied$' && ok || bad "3c status sees ueini"
out=$(run_main ueini "$pkg" off 2>/dev/null)
printf '%s\n' "$out" | grep -q '^ueini_state=disabled$' && ok || bad "3d ueini off output"
grep -q 'MHO_MU_MU_PATCHER' "$ue_dir/Engine.ini" && bad "3e block removed" || ok
grep -q 'X=1' "$ue_dir/Engine.ini" && ok || bad "3f user content kept"
( run_main ueini "$pkg" bogus ) >/dev/null 2>&1 && bad "3g invalid action rejected" || ok
( run_main ueini not.a.package on ) >/dev/null 2>&1 && bad "3h unknown package rejected" || ok

# --- gpu-cache-reset dispatch ---
sp="$UEINI_DATA_ROOT/$pkg/shared_prefs"
mkdir -p "$sp"
printf '<map/>\n' > "$sp/apm_cfg.xml"
out=$(run_main gpu-cache-reset "$pkg" 2>/dev/null)
printf '%s\n' "$out" | grep -q '^gpu_cache_reset=removed$' && ok || bad "4a reset output"
[ ! -f "$sp/apm_cfg.xml" ] && ok || bad "4b cache gone"
out=$(run_main gpu-cache-reset "$pkg" 2>/dev/null)
printf '%s\n' "$out" | grep -q '^gpu_cache_reset=missing$' && ok || bad "4c missing output"

# --- status for known game includes new keys ---
out=$(run_main status "$pkg" 2>/dev/null)
printf '%s\n' "$out" | grep -q '^module_version=1.4.2$' && ok || bad "5a module_version"
printf '%s\n' "$out" | grep -q '^gler_state=' && ok || bad "5b gler_state"
printf '%s\n' "$out" | grep -q '^ueini_state=' && ok || bad "5c ueini_state"
printf '%s\n' "$out" | grep -q '^mandatory_gler_saved_disabled=1$' && ok || bad "5d gler pref visible per game"
printf '%s\n' "$out" | grep -q '^renderer_config_state=' && ok || bad "5e legacy renderer key intact"

# --- save --shared with 5th arg flips pref back ---
out=$(run_main save --shared 0 0 0 0 0 2>/dev/null)
printf '%s\n' "$out" >/dev/null
grep -q '^mandatory_gler_disabled=0$' "$SHARED_DIR/preferences.conf" && ok || bad "6a save --shared 5-arg"

echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
