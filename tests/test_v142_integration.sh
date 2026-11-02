#!/bin/sh
# Integration tests for MHO MuMu Patcher v1.4.2 changes:
#  - gler apply/restore lifecycle + renderer snapshot interplay
#  - ueini on/off (Engine.ini marker block)
#  - gpu-cache-reset
#  - shared prefs (mandatory_gler_disabled) + status keys
# Runs on a normal Linux host with temp dirs; no Android needed.
set -u
MOD=${MOD:-/home/user/proton_probe/downloads/extract_1.4.1}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); echo "FAIL: $1"; }

# ---------- environment ----------
# engine.sh hard-codes STATE_DIR/MODDIR at source time; test against patched
# copies so the state lives in the temp dir. Only those assignments change.
LIBT="$T/lib"
mkdir -p "$LIBT" "$T/state"
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

# fake renderer + game data roots
RENDERER_SYSTEM_CONFIG="$T/system/renderer.config"
RENDERER_DATA_CONFIG="$T/data/renderer.config"
UEINI_DATA_ROOT="$T/datadata"
GPU_CACHE_DATA_ROOT="$T/datadata"
MUMU_DETECTED=1
pkg=com.garena.game.mho

migrate_state >/dev/null 2>&1 || { echo "migrate_state failed"; exit 1; }
if ! normalize_profiles >/dev/null 2>&1; then
	# Host fallback: pin the revision the same way normalize_profiles would.
	PROFILE_SET_REVISION=$(profile_set_revision) || { echo "profile_set_revision failed"; exit 1; }
fi

mkdir -p "$T/system" "$T/data"
orig="$T/orig.config"
cat > "$orig" <<'EOF'
# Configuration Begin
Name com.other.app
VkFlag 1
CustomizedRendererString Adreno (TM) 650
Name com\.garena\.game\.mho
VkFlag 1
CustomizedRendererString Mali-G610
# Configuration End
EOF
{ cat "$orig"; echo "# system template"; } > "$RENDERER_SYSTEM_CONFIG"
cp "$orig" "$RENDERER_DATA_CONFIG"
chmod 644 "$RENDERER_SYSTEM_CONFIG" "$RENDERER_DATA_CONFIG"

TARGET_PACKAGE=$pkg
R_TRACK="$SHARED_DIR/renderer/$pkg"
mkdir -p "$R_TRACK"

# ---------- 1. renderer apply + gler lifecycle ----------
inspect_renderer_target
[ "$RENDERER_STATE" = needs_patch ] && ok || bad "1a needs_patch (got $RENDERER_STATE)"
apply_renderer_config_patch || bad "1b apply_renderer_config_patch rc=$?"
inspect_renderer_target
[ "$RENDERER_STATE" = applied ] && ok || bad "1c applied after patch (got $RENDERER_STATE)"
grep -q 'Mali-G610' "$RENDERER_DATA_CONFIG" && bad "1d target spoof still present" || ok
gler_reconcile_pkg || bad "1e gler_reconcile rc=$?"
grep -qx 'IgnoreGLError 1' "$RENDERER_DATA_CONFIG" && ok || bad "1f gler line present"
awk '/^Name com\\\.garena/{getline; if($0=="IgnoreGLError 1") f=1} END{exit !f}' "$RENDERER_DATA_CONFIG" && ok || bad "1g gler right after Name"
[ "$(scalar_value "$R_TRACK/gler.conf" line_owned)" = 1 ] && ok || bad "1h gler record owned"
gler_inspect_pkg
[ "$GLER_STATE" = applied ] && ok || bad "1i gler inspect applied"

# gler idempotent re-apply keeps single line
gler_reconcile_pkg || bad "1j gler re-apply rc=$?"
[ "$(grep -c 'IgnoreGLError' "$RENDERER_DATA_CONFIG")" = 1 ] && ok || bad "1j2 single gler line"

# restore: strip gler first, then renderer exact restore
gler_restore_pkg || bad "1k gler_restore rc=$?"
grep -q 'IgnoreGLError' "$RENDERER_DATA_CONFIG" && bad "1l gler removed" || ok
[ ! -f "$R_TRACK/gler.conf" ] && ok || bad "1m gler record cleared"
restore_renderer_config || bad "1n restore rc=$?"
cmp -s "$orig" "$RENDERER_DATA_CONFIG" && ok || bad "1o byte-exact restore"
[ ! -f "$R_TRACK/active.conf" ] && ok || bad "1p active cleared"

# ---------- 2. renderer cleanup when data == system ----------
cp "$RENDERER_DATA_CONFIG" "$RENDERER_SYSTEM_CONFIG"   # pretend system base equals restored data
renderer_cleanup_override || bad "2a cleanup rc=$?"
[ ! -f "$RENDERER_DATA_CONFIG" ] && ok || bad "2b data override removed (identical to system)"

# ---------- 3. gler-only (no spoof present, no package block) ----------
orig3="$T/orig3.config"
cat > "$RENDERER_DATA_CONFIG" <<'EOF'
# Configuration Begin
Name com.other.app
VkFlag 1
# Configuration End
EOF
cp "$RENDERER_DATA_CONFIG" "$orig3"
gler_reconcile_pkg || bad "3a gler apply rc=$?"
grep -qx 'IgnoreGLError 1' "$RENDERER_DATA_CONFIG" && ok || bad "3b gler present"
[ "$(scalar_value "$R_TRACK/gler.conf" block_owned)" = 1 ] && ok || bad "3c block_owned=1"
gler_restore_pkg || bad "3d restore rc=$?"
cmp -s "$orig3" "$RENDERER_DATA_CONFIG" && ok || bad "3e back to orig"
[ ! -f "$R_TRACK/gler.conf" ] && ok || bad "3f record cleared"

# ---------- 4. foreign gler line is never removed ----------
cat > "$RENDERER_DATA_CONFIG" <<'EOF'
# Configuration Begin
Name com\.garena\.game\.mho
IgnoreGLError 1
VkFlag 1
CustomizedRendererString Mali-G610
# Configuration End
EOF
orig4="$T/orig4.config"
cp "$RENDERER_DATA_CONFIG" "$orig4"
rm -f "$R_TRACK/gler.conf"
gler_reconcile_pkg || bad "4a reconcile rc=$?"
cmp -s "$orig4" "$RENDERER_DATA_CONFIG" && ok || bad "4b untouched (already present)"
[ "$(scalar_value "$R_TRACK/gler.conf" line_owned)" = 0 ] && ok || bad "4c not owned"
gler_restore_pkg || bad "4d restore rc=$?"
cmp -s "$orig4" "$RENDERER_DATA_CONFIG" && ok || bad "4e foreign line kept"
[ ! -f "$R_TRACK/gler.conf" ] && ok || bad "4f record cleared"

# ---------- 5. owned gler survives re-apply with external change (merge path) ----------
rm -f "$R_TRACK/gler.conf" "$R_TRACK/active.conf" "$R_TRACK/created.conf"
rm -rf "$R_TRACK/generations" "$R_TRACK/generation"
orig5="$T/orig5.config"
cat > "$RENDERER_DATA_CONFIG" <<'EOF5'
# Configuration Begin
Name com.other.app
VkFlag 1
CustomizedRendererString Adreno (TM) 650
Name com\.garena\.game\.mho
VkFlag 1
CustomizedRendererString Mali-G610
# Configuration End
EOF5
cp "$RENDERER_DATA_CONFIG" "$orig5"
inspect_renderer_target
[ "$RENDERER_STATE" = needs_patch ] && ok || bad "5a needs_patch"
apply_renderer_config_patch || bad "5b apply rc=$?"
gler_reconcile_pkg || bad "5c gler rc=$?"
grep -qx 'IgnoreGLError 1' "$RENDERER_DATA_CONFIG" && ok || bad "5d gler applied"
# external change: append a foreign line inside the file
printf 'VkHighPrecision 1\n' >> "$RENDERER_DATA_CONFIG"
gler_restore_pkg || bad "5e gler restore w/ external rc=$?"
grep -q 'IgnoreGLError' "$RENDERER_DATA_CONFIG" && bad "5f gler stripped" || ok
grep -q 'VkHighPrecision 1' "$RENDERER_DATA_CONFIG" && ok || bad "5g foreign change kept"
restore_renderer_config || bad "5h renderer restore rc=$?"
grep -q 'CustomizedRendererString Mali-G610' "$RENDERER_DATA_CONFIG" && ok || bad "5i spoof restored (merge)"
grep -q 'VkHighPrecision 1' "$RENDERER_DATA_CONFIG" && ok || bad "5j foreign change kept after merge"
[ ! -f "$R_TRACK/active.conf" ] && ok || bad "5k active cleared"

# ---------- 6. ueini ----------
ue_data="$UEINI_DATA_ROOT/$pkg"
ue_dir="$ue_data/files/UnrealGame/MHOutlanders/Saved/Config/Android"
mkdir -p "$ue_dir"
printf '[Audio]\nUserSettings=keepme\n' > "$ue_dir/Engine.ini"
set_game "$pkg" || bad "6 set_game"
do_ueini on >/dev/null || bad "6a ueini on rc=$?"
grep -q '^; MHO_MU_MU_PATCHER_BEGIN$' "$ue_dir/Engine.ini" && ok || bad "6b marker present"
grep -q 'r.Streaming.PoolSize=1024' "$ue_dir/Engine.ini" && ok || bad "6c pool size"
grep -q 'UserSettings=keepme' "$ue_dir/Engine.ini" && ok || bad "6d user content kept"
[ -f "$GAME_DIR/Engine.ini.orig" ] && ok || bad "6e orig backup"
[ "$(ueini_inspect)" = applied ] && ok || bad "6f inspect applied"
# idempotent second on
do_ueini on >/dev/null || bad "6g ueini on again rc=$?"
[ "$(grep -c 'MHO_MU_MU_PATCHER_BEGIN' "$ue_dir/Engine.ini")" = 1 ] && ok || bad "6h single block"
# off
do_ueini off >/dev/null || bad "6i ueini off rc=$?"
grep -q 'MHO_MU_MU_PATCHER' "$ue_dir/Engine.ini" && bad "6j block removed" || ok
grep -q 'UserSettings=keepme' "$ue_dir/Engine.ini" && ok || bad "6k user content kept after off"
[ "$(ueini_inspect)" = disabled ] && ok || bad "6l inspect disabled"
[ ! -f "$GAME_DIR/ueini.conf" ] && ok || bad "6m record cleared"
# fresh dir without Engine.ini
rm -f "$ue_dir/Engine.ini"
do_ueini on >/dev/null || bad "6n on fresh rc=$?"
[ -f "$ue_dir/Engine.ini" ] && grep -q 'r.DynamicRes.OperationMode=0' "$ue_dir/Engine.ini" && ok || bad "6o created with block"
do_ueini off >/dev/null || bad "6p off fresh rc=$?"
[ ! -f "$ue_dir/Engine.ini" ] && ok || bad "6q our file removed when empty"
# on without config dir -> fails cleanly
rm -rf "$ue_data"
( do_ueini on >/dev/null 2>&1 ) && bad "6r should fail without UE dir" || ok
# unsafe stored path -> refuse
mkdir -p "$GAME_DIR"
printf 'enabled=1\ncreated=0\ndir=/etc\nfile=/etc/Engine.ini\n' > "$GAME_DIR/ueini.conf"
( do_ueini off >/dev/null 2>&1 ) && bad "6s refuses unsafe stored path" || ok
rm -f "$GAME_DIR/ueini.conf"

# ---------- 7. gpu-cache-reset ----------
sp="$UEINI_DATA_ROOT/$pkg/shared_prefs"
mkdir -p "$sp"
printf '<map><int name="gpu" value="1"/></map>\n' > "$sp/apm_cfg.xml"
out=$(do_gpu_cache_reset) || bad "7a reset rc=$?"
printf '%s\n' "$out" | grep -q '^gpu_cache_reset=removed$' && ok || bad "7b removed key"
[ ! -f "$sp/apm_cfg.xml" ] && ok || bad "7c cache deleted"
backup=$(printf '%s\n' "$out" | sed -n 's/^backup=//p')
[ -f "$backup" ] && ok || bad "7d backup exists"
out=$(do_gpu_cache_reset)
printf '%s\n' "$out" | grep -q '^gpu_cache_reset=missing$' && ok || bad "7e missing key"
# symlink refused
mkdir -p "$sp"; : > "$T/elsewhere"
ln -s "$T/elsewhere" "$sp/apm_cfg.xml"
( do_gpu_cache_reset >/dev/null 2>&1 ) && bad "7f symlink refused" || ok
rm -f "$sp/apm_cfg.xml"

# ---------- 8. shared prefs + shared-save/status (functions level) ----------
SHARED_PREF_FILE="$SHARED_DIR/preferences.conf"
rm -f "$SHARED_PREF_FILE"
load_shared_preferences
[ "${MANDATORY_GLER_DISABLED:-x}" = 0 ] && ok || bad "8a gler default enabled"
out=$(print_shared_status 2>/dev/null)
printf '%s\n' "$out" | grep -q '^mandatory_gler_saved_disabled=0$' && ok || bad "8b shared status gler pref"
printf '%s\n' "$out" | grep -q '^gler_state=' && ok || bad "8c shared status gler state"
printf '%s\n' "$out" | grep -q '^ueini_state=unavailable$' && ok || bad "8d shared status ueini"
( apply_shared_settings 0 0 0 0 1 ) >/dev/null 2>&1
out=$(print_shared_status 2>/dev/null)
printf '%s\n' "$out" | grep -q '^mandatory_gler_saved_disabled=1$' && ok || bad "8e gler disabled saved"
# per-game status keys
out=$(print_status_legacy 2>/dev/null)
printf '%s\n' "$out" | grep -q '^module_version=1.4.3$' && ok || bad "8f module_version"
printf '%s\n' "$out" | grep -q '^gler_state=' && ok || bad "8g per-game gler_state"
printf '%s\n' "$out" | grep -q '^ueini_state=' && ok || bad "8h per-game ueini_state"
printf '%s\n' "$out" | grep -q '^mandatory_gler_saved_disabled=1$' && ok || bad "8i per-game gler pref"

# ---------- 9. ueini presets (v1.4.3) ----------
ue_data="$UEINI_DATA_ROOT/$pkg"
ue_dir="$ue_data/files/UnrealGame/MHOutlanders/Saved/Config/Android"
mkdir -p "$ue_dir"
printf '[Audio]\nX=1\n' > "$ue_dir/Engine.ini"
set_game "$pkg"
out=$(do_ueini on) || bad "9a ueini on rc=$?"
printf '%s\n' "$out" | grep -q '^ueini_preset=balanced$' && ok || bad "9b default preset balanced"
grep -q 'r.ParticleLODBias=1' "$ue_dir/Engine.ini" && ok || bad "9c balanced particle lod"
grep -q 'sg.EffectsQuality' "$ue_dir/Engine.ini" && bad "9d balanced no sg" || ok
[ "$(ueini_preset_value)" = balanced ] && ok || bad "9e preset value balanced"
out=$(do_ueini on maxfps) || bad "9f ueini on maxfps rc=$?"
printf '%s\n' "$out" | grep -q '^ueini_preset=maxfps$' && ok || bad "9g maxfps echoed"
grep -q 'sg.EffectsQuality=0' "$ue_dir/Engine.ini" && ok || bad "9h maxfps sg block"
grep -q 'r.ParticleLODBias=2' "$ue_dir/Engine.ini" && ok || bad "9i maxfps particle lod2"
grep -q 'r.MotionBlurQuality=0' "$ue_dir/Engine.ini" && ok || bad "9j motion blur off"
[ "$(grep -c 'MHO_MU_MU_PATCHER_BEGIN' "$ue_dir/Engine.ini")" = 1 ] && ok || bad "9k single block after switch"
# `on` without preset keeps previous preset
out=$(do_ueini on) || bad "9l re-on rc=$?"
printf '%s\n' "$out" | grep -q '^ueini_preset=maxfps$' && ok || bad "9m keeps previous preset"
# invalid preset rejected
( do_ueini on ultra ) >/dev/null 2>&1 && bad "9n invalid preset rejected" || ok
# status carries the key
out=$(print_status_legacy 2>/dev/null)
printf '%s\n' "$out" | grep -q '^ueini_preset=maxfps$' && ok || bad "9o status ueini_preset"
do_ueini off >/dev/null || bad "9p off rc=$?"
printf '%s\n' "$out" >/dev/null
out=$(print_status_legacy 2>/dev/null)
printf '%s\n' "$out" | grep -q '^ueini_preset=balanced$' && ok || bad "9q preset value after off"
# shared-status carries an empty preset key
out=$(print_shared_status 2>/dev/null)
printf '%s\n' "$out" | grep -q '^ueini_preset=$' && ok || bad "9r shared ueini_preset key"
rm -rf "$ue_data"

echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
