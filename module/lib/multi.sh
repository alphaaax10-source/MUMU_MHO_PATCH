# Multi-edition orchestration. Data files are parsed; none are sourced or eval'd.
ROOT_STATE=$STATE_DIR
GAMES_DIR="$ROOT_STATE/games"
SHARED_DIR="$ROOT_STATE/shared"
LEGACY_PACKAGE=com.tencent.mhadv
EXPECTED_CONTEXT=""
SHARED_ACTION=0
PROFILE_ERRORS=0

safe_package() {
    printf '%s\n' "$1" | LC_ALL=C awk '
      /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$/ { ok=1 }
      END { exit !ok }'
}
safe_component() {
    case "$1" in ""|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
}
safe_relative_library() {
    case "$1" in lib/*) ;; *) return 1 ;; esac
    case "$1" in *..*|*//*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
    [ "${1##*/}" = libUnreal.so ]
}
scalar_value() {
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    sed -n 's/^'"$2"'=//p' "$1" | head -n 1
}
safe_dir() {
    # Refuse symlinks in every state path component, including existing parents.
    local path parent
    path=$1
    case "$path" in "$ROOT_STATE"|"$ROOT_STATE"/*) ;; *) return 1 ;; esac
    parent=$path
    while [ "$parent" != / ]; do
        [ ! -L "$parent" ] || return 1
        parent=${parent%/*}; [ -n "$parent" ] || parent=/
    done
    mkdir -p "$path" && chmod 0700 "$path"
}
copy_atomic() {
    local src dst tmp
    src=$1; dst=$2; tmp="$dst.$$.tmp"
    [ -f "$src" ] && [ ! -L "$src" ] && [ ! -L "$dst" ] || return 1
    TEMP_FILES="$TEMP_FILES $tmp"
    cp "$src" "$tmp" && chmod 0600 "$tmp" && cmp -s "$src" "$tmp" && mv -f "$tmp" "$dst"
}

# Strict flat JSON is normalized once per process. All legacy field readers can
# then operate on canonical lines, independent of source indentation/minification.
profile_set_revision() {
    local source
    for source in "$RAW_PROFILE_DIR"/*.json; do
        [ -f "$source" ] && [ ! -L "$source" ] || continue
        sha256sum "$source" || return 1
    done | sha256sum | awk '{print $1}'
}

normalize_profiles() {
    local source dest n
    RAW_PROFILE_DIR=$PROFILE_DIR
    PROFILE_SET_REVISION=$(profile_set_revision) || return 1
    NORMALIZED_DIR="$ROOT_STATE/.profiles.$$"
    safe_dir "$NORMALIZED_DIR" || return 1
    n=0
    for source in "$RAW_PROFILE_DIR"/*.json; do
        [ -f "$source" ] && [ ! -L "$source" ] || continue
        n=$((n + 1)); dest="$NORMALIZED_DIR/$n.json"
        if ! LC_ALL=C awk -f "$MODDIR/lib/profile_json.awk" "$source" > "$dest"; then
            rm -f "$dest"; PROFILE_ERRORS=$((PROFILE_ERRORS + 1))
            continue
        fi
    done
    PROFILE_DIR=$NORMALIZED_DIR
}
cleanup() {
    local f
    for f in $TEMP_FILES; do rm -f -- "$f" 2>/dev/null || true; done
    [ -z "${NORMALIZED_DIR:-}" ] || rm -rf -- "$NORMALIZED_DIR"
    release_lock
}

catalog_packages() {
    local f p
    for f in "$PROFILE_DIR"/*.json; do
        [ -f "$f" ] || continue
        p=$(json_string "$f" package)
        safe_package "$p" && printf '%s\n' "$p"
    done | LC_ALL=C sort -u
}
tracked_packages() {
    local d p
    { renderer_tracked_packages
      for d in "$GAMES_DIR"/*; do
        [ -d "$d" ] && [ ! -L "$d" ] || continue
        p=${d##*/}; safe_package "$p" && printf '%s\n' "$p"
      done
    } | LC_ALL=C sort -u
}
known_package() {
    local p
    safe_package "$1" || return 1
    for p in $(tracked_packages); do [ "$p" != "$1" ] || return 0; done
    return 1
}
set_game() {
    safe_package "$1" || return 1
    TARGET_PACKAGE=$1
    GAME_DIR="$GAMES_DIR/$TARGET_PACKAGE"
    safe_dir "$GAME_DIR" || return 1
    PREF_FILE="$GAME_DIR/preferences.conf"
    STATUS_FILE="$GAME_DIR/status.log"
    RESTORE_CONTEXT_FILE="$GAME_DIR/restore_context.conf"
    R_TRACK="$SHARED_DIR/renderer/$TARGET_PACKAGE"
    SELECTED_PROFILE=""; PROFILE_ID=""; VERSION=""; VERSION_CODE=""
    INSTALL_ROOT=""; APK_PATHS=""; LIBRARY=""; PATCH_COUNT=0
    CONTEXT_TOKEN=""; INSTALLATION_ID=""; INSTALLATION_DIR=""
}

migrate_state() {
    local source f dest tmp hp wh
    safe_dir "$GAMES_DIR" && safe_dir "$SHARED_DIR" && safe_dir "$SHARED_DIR/hp15" \
        && safe_dir "$SHARED_DIR/renderer" || return 1
    HP15_STATE_FILE="$SHARED_DIR/hp15/hp15_override.conf"
    SHARED_PREF_FILE="$SHARED_DIR/preferences.conf"
    [ "$(scalar_value "$ROOT_STATE/state_schema.conf" schema)" != 4 ] || return 0
    safe_dir "$ROOT_STATE/legacy/1.3.x" && safe_dir "$GAMES_DIR/$LEGACY_PACKAGE" || return 1
    # Originals remain where they were. Copies are made before publishing schema=4.
    for f in preferences.conf restore_context.conf status.log hp15_override.conf renderer_patch.conf renderer.config.backup; do
        source="$ROOT_STATE/$f"
        [ ! -L "$source" ] || return 1
        if [ -f "$source" ]; then
            dest="$ROOT_STATE/legacy/1.3.x/$f"
            [ -f "$dest" ] || copy_atomic "$source" "$dest" || return 1
        fi
    done
    for f in preferences.conf restore_context.conf; do
        source="$ROOT_STATE/$f"; dest="$GAMES_DIR/$LEGACY_PACKAGE/$f"
        if [ -f "$source" ] && [ ! -f "$dest" ]; then copy_atomic "$source" "$dest" || return 1; fi
    done
    if [ -f "$ROOT_STATE/hp15_override.conf" ] && [ ! -f "$HP15_STATE_FILE" ]; then
        copy_atomic "$ROOT_STATE/hp15_override.conf" "$HP15_STATE_FILE" || return 1
    fi
    if [ ! -f "$SHARED_PREF_FILE" ]; then
        hp=$(scalar_value "$ROOT_STATE/preferences.conf" mandatory_hp15_disabled)
        wh=$(scalar_value "$ROOT_STATE/preferences.conf" hp15_watcher_disabled)
        # Both shipped historical profiles default to enabled. Preserve explicit choices.
        case "$hp" in 0|1) ;; *) hp=0 ;; esac
        case "$wh" in 0|1) ;; *) wh=0 ;; esac
        tmp="$SHARED_PREF_FILE.$$.tmp"; TEMP_FILES="$TEMP_FILES $tmp"
        printf 'mandatory_hp15_disabled=%s\nhp15_watcher_disabled=%s\n' "$hp" "$wh" > "$tmp" \
            && mv "$tmp" "$SHARED_PREF_FILE" || return 1
    fi
    # Renderer migration is lazy per package, with exact before/after verification.
    tmp="$ROOT_STATE/.schema.$$.tmp"; TEMP_FILES="$TEMP_FILES $tmp"
    printf 'schema=4\nfrom=1.3.x\n' > "$tmp" && mv "$tmp" "$ROOT_STATE/state_schema.conf"
}
load_shared_preferences() {
    MANDATORY_HP15_DISABLED=$(scalar_value "$SHARED_PREF_FILE" mandatory_hp15_disabled)
    HP15_WATCHER_DISABLED=$(scalar_value "$SHARED_PREF_FILE" hp15_watcher_disabled)
    MANDATORY_RENDERER_DISABLED=$(scalar_value "$SHARED_PREF_FILE" mandatory_renderer_disabled)
    RENDERER_WATCHER_DISABLED=$(scalar_value "$SHARED_PREF_FILE" renderer_watcher_disabled)
    MANDATORY_GLER_DISABLED=$(scalar_value "$SHARED_PREF_FILE" mandatory_gler_disabled)
    case "$MANDATORY_HP15_DISABLED" in 0|1) ;; *) MANDATORY_HP15_DISABLED=0 ;; esac
    case "$HP15_WATCHER_DISABLED" in 0|1) ;; *) HP15_WATCHER_DISABLED=0 ;; esac
    case "$MANDATORY_RENDERER_DISABLED" in 0|1) ;; *) MANDATORY_RENDERER_DISABLED=0 ;; esac
    case "$RENDERER_WATCHER_DISABLED" in 0|1) ;; *) RENDERER_WATCHER_DISABLED=0 ;; esac
    # IgnoreGLError compatibility defaults to enabled (the GPM Level 7 fix).
    case "$MANDATORY_GLER_DISABLED" in 0|1) ;; *) MANDATORY_GLER_DISABLED=0 ;; esac
}

# One-time migration from per-game renderer choices. An explicit opt-out in any
# historical game wins; it is never silently converted into a shared opt-in.
migrate_renderer_policy() {
    local f disabled watcher tmp
    [ "$(scalar_value "$SHARED_PREF_FILE" renderer_policy)" != all_profiles ] || return 0
    disabled=0; watcher=0
    for f in "$ROOT_STATE/preferences.conf" "$GAMES_DIR"/*/preferences.conf; do
        [ "$(scalar_value "$f" mandatory_renderer_disabled)" != 1 ] || disabled=1
        [ "$(scalar_value "$f" renderer_watcher_disabled)" != 1 ] || watcher=1
    done
    tmp="$SHARED_PREF_FILE.$$.tmp"; TEMP_FILES="$TEMP_FILES $tmp"
    sed '/^mandatory_renderer_disabled=/d; /^renderer_watcher_disabled=/d; /^renderer_policy=/d' "$SHARED_PREF_FILE" > "$tmp" || return 1
    printf 'mandatory_renderer_disabled=%s\nrenderer_watcher_disabled=%s\nrenderer_policy=all_profiles\n' "$disabled" "$watcher" >> "$tmp"
    mv "$tmp" "$SHARED_PREF_FILE"
}

validate_profile_metadata() {
    local pcode pstatus label abi count i pid seen required_hp15
    validate_profile_metadata_legacy "$1" || return 1
    safe_package "$profile_package" && safe_component "$profile_id" || return 1
    safe_relative_library "$relative_library" && safe_relative_library "$apk_library" || return 1
    required_hp15=$(json_string "$1" hp15_payload_sha256)
    if [ -n "$required_hp15" ]; then
        [ "$required_hp15" = "$HP15_PAYLOAD_SHA256" ] || return 1
    fi
    pcode=$(json_number "$1" version_code)
    [ -z "$pcode" ] || [ -z "${VERSION_CODE:-}" ] || [ "$pcode" = "$VERSION_CODE" ] || return 1
    abi=$(json_string "$1" abi)
    case "$abi" in ""|arm64-v8a) ;; *) return 1 ;; esac
    pstatus=$(json_string "$1" profile_status)
    label=$(json_string "$1" game_label)
    [ "${#pstatus}" -le 80 ] && [ "${#label}" -le 120 ] || return 1
    [ "$profile_schema" != 4 ] || [ -n "$pstatus" ] || return 1
    # Strings are already strictly decoded by profile_json.awk; no control bytes.
    count=$patch_count; seen=" "
    i=1
    while [ "$i" -le "$count" ]; do
        pid=$(json_string "$1" "patch_${i}_id")
        [ -n "$pid" ] || pid=$(json_string "$1" "patch_${i}_name")
        safe_component "$pid" || return 1
        case "$seen" in *" $pid "*) return 1 ;; esac
        seen="$seen$pid "; i=$((i + 1))
    done
}

# Capture the installed versionCode as well as versionName and APK identities.
detect_environment() {
    APK_PATHS=$(/system/bin/pm path "$TARGET_PACKAGE" 2>/dev/null | sed -n 's/^package://p' | LC_ALL=C sort)
    [ -n "$APK_PATHS" ] || return 1
    local apk resolved root_resolved
    BASE_APK=$(printf '%s\n' "$APK_PATHS" | grep '/base.apk$' | head -n 1)
    [ -n "$BASE_APK" ] || BASE_APK=$(printf '%s\n' "$APK_PATHS" | head -n 1)
    INSTALL_ROOT=${BASE_APK%/*}
    is_safe_data_path "$INSTALL_ROOT" || return 1
    root_resolved=$(readlink -f "$INSTALL_ROOT") || return 1
    [ "$root_resolved" = "$INSTALL_ROOT" ] || return 1
    for apk in $APK_PATHS; do
        is_safe_data_path "$apk" && [ -f "$apk" ] && [ ! -L "$apk" ] || return 1
        [ "${apk%/*}" = "$INSTALL_ROOT" ] || return 1
    done
    PACKAGE_DUMP=$(/system/bin/dumpsys package "$TARGET_PACKAGE" 2>/dev/null)
    VERSION=$(printf '%s\n' "$PACKAGE_DUMP" | sed -n 's/^[[:space:]]*versionName=\([^[:space:]]*\).*/\1/p' | head -n 1)
    VERSION_CODE=$(printf '%s\n' "$PACKAGE_DUMP" | sed -n 's/^[[:space:]]*versionCode=\([0-9][0-9]*\).*/\1/p' | head -n 1)
    [ -n "$VERSION" ] || VERSION=unknown
}
is_safe_data_path() {
    case "$1" in /data/app/*) ;; *) return 1 ;; esac
    case "$1" in *..*|*//*|*[!A-Za-z0-9_/+=.~\-]*) return 1 ;; esac
    return 0
}
apk_identity() {
    local apk
    printf '%s\n%s\n%s\n' "$TARGET_PACKAGE" "$INSTALL_ROOT" "$VERSION_CODE"
    for apk in $APK_PATHS; do
        printf '%s\n' "$apk"
        stat -c '%d:%i:%s:%Y:%Z' "$apk" || return 1
    done
}
apk_files_fingerprint() {
    local apk contents
    contents=$(
        for apk in $1; do
            printf '%s\n' "$apk"
            stat -c '%d:%i:%s:%Y:%Z' "$apk" || exit 1
        done
    ) || return 1
    printf '%s\n' "$contents" | sha256sum | awk '{print $1}'
}

record_source_identity() {
    # Append to the temporary context before its final atomic publication.
    printf 'source_apk_fingerprint=%s\napplied_sha256=%s\n' "$(apk_files_fingerprint "$APK_PATHS")" "$(sha256_file "$LIBRARY")" >> "$1"
}

check_selected_context() {
    local identity catalogue_profile catalogue_label candidate_label
    catalogue_label=""
    for catalogue_profile in "$PROFILE_DIR"/*.json; do
        [ "$(json_string "$catalogue_profile" package)" = "$TARGET_PACKAGE" ] || continue
        candidate_label=$(json_string "$catalogue_profile" game_label); candidate_label=${candidate_label:-$TARGET_PACKAGE}
        [ -z "$catalogue_label" ] || [ "$catalogue_label" = "$candidate_label" ] || { log_line "Conflicting game labels for $TARGET_PACKAGE"; return 1; }
        catalogue_label=$candidate_label
    done
    [ "$(profile_set_revision)" = "$PROFILE_SET_REVISION" ] || { log_line "Profiles changed while the operation was running"; return 1; }
    # Never allow a profile to target another install through a library symlink.
    [ ! -L "$LIBRARY" ] || return 1
    [ "$(readlink -f "$LIBRARY")" = "$LIBRARY" ] || return 1
    identity=$(apk_identity) || return 1
    INSTALLATION_ID=$(printf '%s\n%s\n' "$identity" "$ORIGINAL_SHA256" | sha256sum | awk '{print $1}')
    INSTALLATION_DIR="$GAME_DIR/installations/$INSTALLATION_ID"
    CONTEXT_TOKEN=$(printf '%s\n%s\n%s\n' "$identity" "$VERSION" "$(sha256_file "$SELECTED_PROFILE")" | sha256sum | awk '{print $1}')
    if [ -n "$EXPECTED_CONTEXT" ] && [ "$EXPECTED_CONTEXT" != "$CONTEXT_TOKEN" ]; then
        log_line "The selected installation/profile changed. Reload this game before saving."
        return 1
    fi
    return 0
}

load_advanced_preferences() {
    load_advanced_preferences_legacy
    load_shared_preferences
    [ -z "${SELECTED_PROFILE:-}" ] || load_profile_defaults "$SELECTED_PROFILE"
}
# Default values are resolved once by the backend and used by boot and WebUI.
load_profile_defaults() {
    local profile key upper value count i pid default_enabled
    profile=${1:-}
    [ -n "$profile" ] || profile=$(advanced_defaults_profile 2>/dev/null || true)
    for key in resolution_enabled resolution_scale fps_enabled fps_target gpm_device_level_enabled gpu_display_enabled hide_uuid_enabled controller_mode_enabled graphic_api_display_enabled platform_display_enabled graphic_library_enabled graphic_library cross_platform_enabled cross_platform device_checks_forced pixelflow_mode pixelflow_choice; do
        case "$key" in
          resolution_scale) value=100 ;; fps_target) value=60 ;;
          gpm_device_level_enabled) value=1 ;;
          graphic_library) value=opengl ;; cross_platform) value=mobile ;;
          pixelflow_mode) value=original ;; pixelflow_choice) value=disabled ;;
          *) value=0 ;;
        esac
        if [ -n "$profile" ]; then
            case "$key" in
              *_enabled|device_checks_forced) value=$(json_bool "$profile" "default_$key" 2>/dev/null || printf '%s\n' "$value") ;;
              resolution_scale|fps_target) value=$(json_number "$profile" "default_$key" | head -n 1); case "$key:$value" in resolution_scale:) value=100 ;; fps_target:) value=60 ;; esac ;;
              *) value=$(json_string "$profile" "default_$key" | head -n 1); case "$key:$value" in graphic_library:) value=opengl ;; cross_platform:) value=mobile ;; pixelflow_mode:) value=original ;; pixelflow_choice:) value=disabled ;; esac ;;
            esac
        fi
        case "$key" in
          resolution_scale) [ "$value" -ge 10 ] && [ "$value" -le 200 ] || value=100 ;;
          fps_target) [ "$value" -ge 20 ] && [ "$value" -le 240 ] || value=60 ;;
          graphic_library) case "$value" in opengl|vulkan) ;; *) value=opengl ;; esac ;;
          cross_platform) case "$value" in pc|mobile|console) ;; *) value=mobile ;; esac ;;
          pixelflow_mode) case "$value" in original|enabled|disabled) ;; *) value=original ;; esac ;;
          pixelflow_choice) case "$value" in enabled|disabled) ;; *) value=disabled ;; esac ;;
        esac
        upper=$(printf '%s' "$key" | tr 'a-z' 'A-Z')
        # key is from the fixed list and value is a validated enum/integer.
        eval "DEFAULT_$upper=\$value"
        if ! [ -f "$PREF_FILE" ] || ! grep -q "^$key=" "$PREF_FILE"; then eval "$upper=\$value"; fi
    done
    PATCH_SETTINGS=""
    count=$(json_number "$profile" patch_count 2>/dev/null); count=${count:-0}
    i=1
    while [ "$i" -le "$count" ]; do
        pid=$(json_string "$profile" "patch_${i}_id")
        [ -n "$pid" ] || pid=$(json_string "$profile" "patch_${i}_name")
        safe_component "$pid" || return 1
        default_enabled=$(json_bool "$profile" "advanced_patch_${i}_default_enabled" 2>/dev/null || printf '1\n')
        value=$(scalar_value "$PREF_FILE" "patch_disabled_$pid")
        if [ -z "$value" ] && [ "$i" -le 2 ]; then value=$(scalar_value "$PREF_FILE" "mandatory_patch_${i}_disabled"); fi
        case "$value" in 0|1) ;; *) value=$((1 - default_enabled)) ;; esac
        eval "MANDATORY_PATCH_${i}_DISABLED=$value"
        eval "ADVANCED_PATCH_${i}_DEFAULT_ENABLED=$default_enabled"
        PATCH_SETTINGS="$PATCH_SETTINGS$pid:$value,"
        i=$((i + 1))
    done
}
load_preferences() {
    load_preferences_legacy
    load_profile_defaults
    load_shared_preferences
}
mandatory_patch_should_patch() {
    local index disabled
    index=$1
    mandatory_should_patch || return 1
    [ "${MUMU_DETECTED:-0}" = 1 ] || return 0
    case "$index" in ''|*[!0-9]*) return 1 ;; esac
    [ "$index" -ge 1 ] && [ "$index" -le 16 ] || return 1
    eval disabled='${MANDATORY_PATCH_'"$index"'_DISABLED:-0}'
    [ "$disabled" != 1 ]
}
apply_patch_choices() {
    local choices i pid choice extra
    choices=$1; i=1
    while [ "$i" -le "$PATCH_COUNT" ]; do
        pid=$(json_string "$SELECTED_PROFILE" "patch_${i}_id")
        [ -n "$pid" ] || pid=$(json_string "$SELECTED_PROFILE" "patch_${i}_name")
        choice=$(printf '%s\n' "$choices" | tr ',' '\n' | awk -F: -v key="$pid" '$1==key {n++;v=$2} END {if(n==1 && (v=="0" || v=="1")) print v; else exit 1}') || return 1
        eval "MANDATORY_PATCH_${i}_DISABLED=$choice"
        i=$((i + 1))
    done
    # Require exactly the active IDs, with no duplicate or extra entries.
    extra=$(printf '%s\n' "$choices" | tr ',' '\n' | awk 'NF {n++} END {print n+0}')
    [ "$extra" -eq "$PATCH_COUNT" ]
}
save_game_preferences() {
    local tmp legacy_pref i pid value
    # Existing preference serializer already checks every scalar value.
    # Keep its output temporary until stable patch IDs have been added.
    legacy_pref=$PREF_FILE; tmp="$PREF_FILE.$$.staged"; TEMP_FILES="$TEMP_FILES $tmp"
    PREF_FILE=$tmp
    save_preferences_legacy "$RESOLUTION_ENABLED" "$RESOLUTION_SCALE" "$FPS_ENABLED" "$FPS_TARGET" \
      "$GPM_DEVICE_LEVEL_ENABLED" "$GPU_DISPLAY_ENABLED" "$GRAPHIC_LIBRARY_ENABLED" "$GRAPHIC_LIBRARY" \
      "$DEVICE_CHECKS_FORCED" "$MANDATORY_HP15_DISABLED" "${MANDATORY_PATCH_1_DISABLED:-0}" "${MANDATORY_PATCH_2_DISABLED:-0}" \
      "$MANDATORY_RENDERER_DISABLED" "$GRAPHIC_API_DISPLAY_ENABLED" "$CROSS_PLATFORM_ENABLED" "$CROSS_PLATFORM" \
      "$HP15_WATCHER_DISABLED" "$RENDERER_WATCHER_DISABLED" "$PLATFORM_DISPLAY_ENABLED" "$PIXELFLOW_MODE" "$PIXELFLOW_CHOICE" "$HIDE_UUID_ENABLED" "$CONTROLLER_MODE_ENABLED" || { PREF_FILE=$legacy_pref; return 1; }
    PREF_FILE=$legacy_pref
    # Shared values are never written to a game's preferences in schema 4.
    sed '/^mandatory_hp15_disabled=/d; /^hp15_watcher_disabled=/d; /^mandatory_renderer_disabled=/d; /^renderer_watcher_disabled=/d; /^mandatory_patch_[12]_disabled=/d' "$tmp" > "$tmp.clean" || return 1
    TEMP_FILES="$TEMP_FILES $tmp.clean"
    # Preserve dormant IDs across builds, then replace only current IDs.
    [ ! -f "$PREF_FILE" ] || sed -n '/^patch_disabled_[A-Za-z0-9_.-]*=[01]$/p' "$PREF_FILE" >> "$tmp.clean"
    i=1
    while [ "$i" -le "$PATCH_COUNT" ]; do
        pid=$(json_string "$SELECTED_PROFILE" "patch_${i}_id")
        [ -n "$pid" ] || pid=$(json_string "$SELECTED_PROFILE" "patch_${i}_name")
        eval value='${MANDATORY_PATCH_'"$i"'_DISABLED:-0}'
        printf 'patch_disabled_%s=%s\n' "$pid" "$value" >> "$tmp.clean"
        i=$((i + 1))
    done
    awk -F= '{if(!($1 in seen)) order[++n]=$1; seen[$1]=$0} END {for(i=1;i<=n;i++) print seen[order[i]]}' "$tmp.clean" > "$tmp" || return 1
    chmod 0600 "$tmp" && mv "$tmp" "$PREF_FILE"
}

print_multi_status() {
    local i pid key upper value
    printf 'optional_metadata_invalid=%s\n' "${OPTIONAL_METADATA_INVALID:-0}"
    printf 'target_package=%s\ncontext_token=%s\nversion_code=%s\npatch_count=%s\n' "$TARGET_PACKAGE" "${CONTEXT_TOKEN:-}" "${VERSION_CODE:-}" "${PATCH_COUNT:-0}"
    printf 'renderer_patch_ready=1\nrenderer_scope=all_profiles\n'
    printf 'profile_status=%s\n' "$(json_string "${SELECTED_PROFILE:-/dev/null}" profile_status 2>/dev/null)"
    printf 'game_label=%s\n' "$(json_string "${SELECTED_PROFILE:-/dev/null}" game_label 2>/dev/null)"
    for key in resolution_enabled resolution_scale fps_enabled fps_target gpm_device_level_enabled gpu_display_enabled hide_uuid_enabled controller_mode_enabled graphic_api_display_enabled platform_display_enabled graphic_library_enabled graphic_library cross_platform_enabled cross_platform device_checks_forced pixelflow_mode pixelflow_choice; do
        upper=$(printf '%s' "$key" | tr 'a-z' 'A-Z'); eval value='${DEFAULT_'"$upper"':-}'
        printf 'default_%s=%s\n' "$key" "$value"
    done
    i=1
    while [ "$i" -le "${PATCH_COUNT:-0}" ]; do
        pid=$(json_string "$SELECTED_PROFILE" "patch_${i}_id")
        [ -n "$pid" ] || pid=$(json_string "$SELECTED_PROFILE" "patch_${i}_name")
        eval value='${MANDATORY_PATCH_'"$i"'_DISABLED:-0}'
        printf 'patch_%s_id=%s\nmandatory_patch_%s_saved_disabled=%s\n' "$i" "$pid" "$i" "$value"
        eval value='${ADVANCED_PATCH_'"$i"'_DEFAULT_ENABLED:-1}'
        printf 'advanced_patch_%s_default_enabled=%s\n' "$i" "$value"
        i=$((i + 1))
    done
}

# Preserve a history per install/build. An observation never overwrites this file.
write_restore_context() {
    local final_context staged_context
    final_context=$RESTORE_CONTEXT_FILE
    staged_context="$GAME_DIR/.restore.$$.tmp"
    TEMP_FILES="$TEMP_FILES $staged_context"
    RESTORE_CONTEXT_FILE=$staged_context
    cache_restore_context_legacy || { RESTORE_CONTEXT_FILE=$final_context; return 1; }
    RESTORE_CONTEXT_FILE=$final_context
    record_source_identity "$staged_context" && mv "$staged_context" "$RESTORE_CONTEXT_FILE"
}

cache_restore_context() {
    [ -n "${INSTALLATION_DIR:-}" ] || return 1
    safe_dir "$INSTALLATION_DIR" || return 1
    write_restore_context || return 1
    copy_atomic "$RESTORE_CONTEXT_FILE" "$INSTALLATION_DIR/restore_context.conf" || return 1
    printf 'applied_sha256=%s\ncontext_token=%s\n' "$(sha256_file "$LIBRARY")" "$CONTEXT_TOKEN" > "$INSTALLATION_DIR/applied.conf.tmp" || return 1
    mv "$INSTALLATION_DIR/applied.conf.tmp" "$INSTALLATION_DIR/applied.conf" || return 1
    rm -f "$INSTALLATION_DIR/pending.conf"
}
verify_original_identity() {
    local pristine stamp
    safe_dir "$INSTALLATION_DIR" || return 1
    stamp="$INSTALLATION_DIR/verified_original.conf"
    [ "$(scalar_value "$stamp" context_token)" != "$CONTEXT_TOKEN" ] || return 0
    pristine="$ROOT_STATE/.verify_original.$$.so"; TEMP_FILES="$TEMP_FILES $pristine"
    extract_pristine_library "$pristine" "$ORIGINAL_SHA256" || return 1
    [ "$(read_hex "$pristine" 0 4)" = 7f454c46 ] && [ "$(read_hex "$pristine" 4 2)" = 0201 ] \
      && [ "$(read_hex "$pristine" 18 2)" = b700 ] || { log_line "Original library is not little-endian ARM64 ELF"; return 1; }
    printf 'context_token=%s\noriginal_sha256=%s\n' "$CONTEXT_TOKEN" "$ORIGINAL_SHA256" > "$stamp.$$.tmp" || return 1
    TEMP_FILES="$TEMP_FILES $stamp.$$.tmp"
    mv "$stamp.$$.tmp" "$stamp"
}
atomic_install_library() {
    local source target expected pending
    source=$1; target=$2; expected=$3
    PUBLICATION_ID=$(stat -c '%d:%i:%s:%Y:%Z' "$target") || return 1
    PUBLICATION_SHA=$(sha256_file "$target")
    if [ "$RUN_MODE" = save ] || [ "$RUN_MODE" = repair ] || [ "$RUN_MODE" = boot ]; then
        check_selected_context || return 1
        verify_original_identity || return 1
        write_restore_context || return 1
        copy_atomic "$RESTORE_CONTEXT_FILE" "$INSTALLATION_DIR/restore_context.conf" || return 1
        pending="$INSTALLATION_DIR/pending.conf"
        printf 'before_sha256=%s\nafter_sha256=%s\ncontext_token=%s\n' "$(sha256_file "$target")" "$expected" "$CONTEXT_TOKEN" > "$pending.$$.tmp" || return 1
        TEMP_FILES="$TEMP_FILES $pending.$$.tmp"
        mv "$pending.$$.tmp" "$pending" || return 1
        sync
    fi
    atomic_install_library_legacy "$source" "$target" "$expected" || return 1
}

prepublish_library_guard() {
    local target
    target=$1
    [ "$(stat -c '%d:%i:%s:%Y:%Z' "$target")" = "$PUBLICATION_ID" ]       && [ "$(sha256_file "$target")" = "$PUBLICATION_SHA" ] || return 1
    case "$RUN_MODE" in
      save|repair|boot) [ ! -f "$MODDIR/disable" ] && [ ! -f "$MODDIR/remove" ] || return 1; refresh_context 0 || return 1; [ "$LIBRARY" = "$target" ] || return 1 ;;
    esac
    return 0
}

# Shared resources are applied once per explicit action; game reconciliation
# only inspects their state after that common phase completes.
reconcile_hp15() {
    if [ "$SHARED_ACTION" = 1 ]; then reconcile_hp15_legacy; else inspect_hp15; fi
}
restore_hp15_override() {
    [ "$SHARED_ACTION" = 1 ] || return 0
    archive_hp15_generation || return 1
    restore_hp15_override_legacy
}
archive_hp15_generation() {
    local archive sha
    if [ -f "$HP15_BACKUP_FILE" ] && [ ! -L "$HP15_BACKUP_FILE" ]; then
        sha=$(sha256_file "$HP15_BACKUP_FILE")
        archive="$SHARED_DIR/hp15/history/$sha"
        safe_dir "$archive" || return 1
        [ -f "$archive/libhp15.so" ] || copy_atomic "$HP15_BACKUP_FILE" "$archive/libhp15.so" || return 1
        [ ! -f "$HP15_STATE_FILE" ] || copy_atomic "$HP15_STATE_FILE" "$archive/marker.conf" || return 1
    fi
    return 0
}

hp15_atomic_copy() {
    local archive sha
    if [ "$7" = backup ] && [ -f "$HP15_BACKUP_FILE" ] && [ ! -L "$HP15_BACKUP_FILE" ]; then
        sha=$(sha256_file "$HP15_BACKUP_FILE")
        archive="$SHARED_DIR/hp15/history/$sha"
        safe_dir "$archive" || return 1
        [ -f "$archive/libhp15.so" ] || copy_atomic "$HP15_BACKUP_FILE" "$archive/libhp15.so" || return 1
        [ ! -f "$HP15_STATE_FILE" ] || copy_atomic "$HP15_STATE_FILE" "$archive/marker.conf" || return 1
    fi
    hp15_atomic_copy_legacy "$@"
}

print_catalog() {
    local p i saved label labels f found rc state version status token
    i=0
    saved=$(scalar_value "$ROOT_STATE/ui.conf" selected_package)
    for p in $(catalog_packages); do
        i=$((i + 1))
        (
          set_game "$p" || exit 1
          label=""; labels=""; state=not_installed; status=""; version=""; rc=0
          for f in "$PROFILE_DIR"/*.json; do
            [ "$(json_string "$f" package)" = "$p" ] || continue
            found=$(json_string "$f" game_label)
            [ -n "$found" ] || found=$p
            if [ -n "$label" ] && [ "$label" != "$found" ]; then labels=conflict; fi
            label=$found
          done
          if detect_environment 0; then
            version=$VERSION; select_profile >/dev/null || rc=$?
            case "$rc" in 0) state=supported; status=$(json_string "$SELECTED_PROFILE" profile_status); status=${status:-Unspecified} ;;
              2) state=profile_conflict ;; *) state=unsupported ;; esac
          fi
          [ "$labels" != conflict ] || state=label_conflict
          printf 'game_%s_package=%s\ngame_%s_label=%s\ngame_%s_version=%s\ngame_%s_state=%s\ngame_%s_profile_status=%s\n' "$i" "$p" "$i" "${label:-$p}" "$i" "$version" "$i" "$state" "$i" "$status"
        ) || return 1
    done
    printf 'game_count=%s\nselected_package=%s\ncatalog_errors=%s\n' "$i" "$saved" "$PROFILE_ERRORS"
}
remember_selection() {
    local tmp
    known_package "$1" || return 1
    tmp="$ROOT_STATE/.ui.$$.tmp"; TEMP_FILES="$TEMP_FILES $tmp"
    printf 'selected_package=%s\n' "$1" > "$tmp" && mv "$tmp" "$ROOT_STATE/ui.conf"
}

restore_game() {
    local file rc result restored pending after before live
    result=0; restored=0
    /system/bin/am force-stop "$TARGET_PACKAGE" 2>/dev/null || true
    renderer_migrate_legacy || result=1
    # Strip the module-owned IgnoreGLError line first so the renderer restore
    # sees an exact snapshot match.
    gler_restore_pkg || result=1
    restore_renderer_config || result=1
    # Restore every tracked installation even when its profile was removed.
    for file in "$GAME_DIR"/installations/*/restore_context.conf "$GAME_DIR/restore_context.conf"; do
        [ -f "$file" ] && [ ! -L "$file" ] || continue
        (
          RESTORE_CONTEXT_FILE=$file
          load_cached_restore_context || exit 1
          apk_list=""; i=1
          while [ "$i" -le "$C_APK_COUNT" ]; do
            apk=$(context_value "apk_$i"); is_safe_data_path "$apk" || exit 1
            apk_list="$apk_list $apk"; i=$((i + 1))
          done
          recorded_source=$(context_value source_apk_fingerprint)
          applied=$(context_value applied_sha256)
          current_source=$(apk_files_fingerprint "$apk_list" 2>/dev/null)
          live=$(sha256_file "$C_LIBRARY")
          if is_sha256 "$recorded_source" && is_sha256 "$current_source" && [ "$current_source" != "$recorded_source" ]; then
            pending_after=$(scalar_value "${file%/*}/pending.conf" after_sha256)
            if [ "$live" != "$applied" ] && [ "$live" != "$pending_after" ]; then
              log_line "Tracked APK installation was replaced; old restore context left in history"
              exit 0
            fi
          fi
          # Journal recognizes a rename completed before the updated inode was saved.
          pending="${file%/*}/pending.conf"
          if [ -f "$C_LIBRARY" ] && [ -f "$pending" ]; then
            after=$(scalar_value "$pending" after_sha256); before=$(scalar_value "$pending" before_sha256)
            live=$(sha256_file "$C_LIBRARY")
            if [ "$live" = "$after" ] || [ "$live" = "$before" ]; then
              # Original extraction/SHA are still checked by the restore routine.
              tmp="$ROOT_STATE/.recover.$$.conf"; TEMP_FILES="$TEMP_FILES $tmp"
              sed '/^library_dev=/d; /^library_inode=/d; /^library_size=/d' "$file" > "$tmp" || exit 1
              printf 'library_dev=%s\nlibrary_inode=%s\nlibrary_size=%s\n' "$(stat -c %d "$C_LIBRARY")" "$(stat -c %i "$C_LIBRARY")" "$(stat -c %s "$C_LIBRARY")" >> "$tmp"
              RESTORE_CONTEXT_FILE=$tmp
            fi
          fi
          restore_pristine_from_cache
        )
        rc=$?
        if [ "$rc" = 0 ]; then restored=1; else result=1; fi
    done
    # Legacy migration may have no tracked state. Exact APK hashes are mandatory.
    if [ "$restored" = 0 ]; then
        restore_pristine_from_filesystem; rc=$?
        case "$rc" in 0|2) ;; *) result=1 ;; esac
    fi
    return "$result"
}

run_all() {
    local mode p result rc
    mode=$1; result=0
    for p in $(tracked_packages); do
        (
          # A subshell gives every game fresh globals and preferences.
          set_game "$p" && load_preferences || exit 1
          case "$mode" in
            restore) restore_game ;;
            boot)
              detect_environment 0 || exit 0
              refresh_context 0; rc=$?
              case "$rc" in 0) ;; 1) exit 0 ;; *) exit 1 ;; esac
              EXPECTED_CONTEXT=$CONTEXT_TOKEN
              /system/bin/am force-stop "$TARGET_PACKAGE" 2>/dev/null || exit 1
              renderer_migrate_legacy || exit 1
              reconcile 0 1 && cache_restore_context ;;
          esac
        )
        rc=$?
        [ "$rc" = 0 ] || { log_line "$mode failed for $p (exit $rc)"; result=1; }
    done
    return "$result"
}

print_shared_status() {
    load_shared_preferences
    inspect_hp15
    inspect_renderer_config
    printf 'target_package=\nprofile_supported=0\npatch_count=0\nrenderer_patch_ready=1\nrenderer_scope=all_profiles\n'
    printf 'mandatory_hp15_saved_disabled=%s\nhp15_watcher_saved_disabled=%s\n' "$MANDATORY_HP15_DISABLED" "$HP15_WATCHER_DISABLED"
    printf 'mandatory_renderer_saved_disabled=%s\nrenderer_watcher_saved_disabled=%s\n' "$MANDATORY_RENDERER_DISABLED" "$RENDERER_WATCHER_DISABLED"
    printf 'hp15_state=%s\nhp15_effective_path=%s\n' "$HP15_STATE" "$HP15_EFFECTIVE_PATH"
    printf 'renderer_config_state=%s\nrenderer_config_path=%s\n' "$RENDERER_STATE" "$RENDERER_EFFECTIVE_PATH"
    printf 'mandatory_gler_saved_disabled=%s\n' "$MANDATORY_GLER_DISABLED"
    gler_inspect_all
    printf 'gler_state=%s\n' "$GLER_ALL_STATE"
    printf 'ueini_state=unavailable\n'
}

# Run common handlers in a subshell: their legacy globals must not overwrite the
# selected game's profile, requested settings or preparation state.
apply_shared_settings() (
    local hp watcher renderer renderer_watcher gler tmp f
    hp=$1; watcher=$2; renderer=$3; renderer_watcher=$4
    gler=${5:-}
    case "$hp:$watcher" in 0:0|0:1|1:0|1:1) ;; *) log_line "Invalid shared settings"; return 1 ;; esac
    case "$renderer:$renderer_watcher" in 0:0|0:1|1:0|1:1) ;; *) log_line "Invalid shared renderer settings"; return 1 ;; esac
    if [ -z "$gler" ]; then
        gler=$(scalar_value "$SHARED_PREF_FILE" mandatory_gler_disabled)
        case "$gler" in 0|1) ;; *) gler=0 ;; esac
    fi
    case "$gler" in 0|1) ;; *) log_line "Invalid shared IgnoreGLError setting"; return 1 ;; esac
    [ ! -f "$MODDIR/disable" ] && [ ! -f "$MODDIR/remove" ] || { log_line "Module is disabled"; return 1; }
    TEMP_FILES=""
    trap 'for f in $TEMP_FILES; do rm -f -- "$f" 2>/dev/null || true; done' EXIT
    SHARED_ACTION=1; MANDATORY_HP15_DISABLED=$hp; HP15_WATCHER_DISABLED=$watcher
    reconcile_hp15 || { log_line "Shared MuMu compatibility could not be applied"; return 1; }
    MANDATORY_RENDERER_DISABLED=$renderer; RENDERER_WATCHER_DISABLED=$renderer_watcher
    MANDATORY_GLER_DISABLED=$gler
    renderer_reconcile_all || { log_line "Shared shader compatibility could not be applied; recovery data retained"; return 1; }
    tmp="$SHARED_PREF_FILE.$$.tmp"; TEMP_FILES="$TEMP_FILES $tmp"
    printf 'mandatory_hp15_disabled=%s\nhp15_watcher_disabled=%s\nmandatory_renderer_disabled=%s\nrenderer_watcher_disabled=%s\nmandatory_gler_disabled=%s\nrenderer_policy=all_profiles\n' "$hp" "$watcher" "$renderer" "$renderer_watcher" "$gler" > "$tmp" \
        && mv "$tmp" "$SHARED_PREF_FILE" || { log_line "Shared preferences could not be saved"; return 1; }
    log_line "Shared MuMu settings applied and saved"
)

main() {
    local mode package token choices i enabled scale hp watcher renderer renderer_watcher tmp result
    mode=${1:-status}; [ "$#" -eq 0 ] || shift; RUN_MODE=$mode
    QUIET=0
    case "$mode" in catalog|status|shared-status|advanced-defaults|hp15-watch|renderer-watch|mumu-watch|ueini|gpu-cache-reset) QUIET=1 ;; esac
    safe_dir "$ROOT_STATE" || exit 10
    acquire_lock || fail "Another operation is running; wait for it to finish"
    migrate_state || fail "State migration failed; historical files were retained"
    migrate_renderer_policy || fail "Shared renderer policy migration failed"
    normalize_profiles || fail "Profile catalogue could not be read"
    case "$mode" in
      shared-status) print_shared_status; return $? ;;
      catalog) print_catalog; return $? ;;
      select) remember_selection "${1:-}"; return $? ;;
      shared-save)
        hp=${1:-}; watcher=${2:-}
        load_shared_preferences
        renderer=${3:-$MANDATORY_RENDERER_DISABLED}; renderer_watcher=${4:-$RENDERER_WATCHER_DISABLED}
        apply_shared_settings "$hp" "$watcher" "$renderer" "$renderer_watcher" "${5:-$MANDATORY_GLER_DISABLED}"
        return $? ;;
      save|repair)
        # Explicit common-only request for the same UI buttons when no binary
        # profile is available. Never downgrade a failed game request to this path.
        if [ "${1:-}" = --shared ]; then
          shift
          # 4 = pre-1.4.2 WebUI, 5 = IgnoreGLError argument added in 1.4.2.
          case "$#" in 4|5) ;; *) fail "Incomplete shared settings" ;; esac
          apply_shared_settings "$1" "$2" "$3" "$4" "${5:-}"
          return $?
        fi ;;
      hp15-boot|hp15-watch|mumu-watch|boot|restore|renderer-watch|advanced-defaults)
        load_shared_preferences
        if [ "$mode" = advanced-defaults ]; then
          printf 'hp15_watcher_disabled=%s\nrenderer_watcher_disabled=%s\n' "$HP15_WATCHER_DISABLED" "$RENDERER_WATCHER_DISABLED"; return 0
        fi
        if [ "$mode" = restore ]; then
          result=0; run_all restore || result=1
          SHARED_ACTION=1; restore_hp15_override || result=1
          renderer_cleanup_override || result=1
          return "$result"
        fi
        [ ! -f "$MODDIR/disable" ] && [ ! -f "$MODDIR/remove" ] || return 0
        result=0
        case "$mode" in
          hp15-boot|hp15-watch|mumu-watch|boot)
            if [ "$HP15_WATCHER_DISABLED" != 1 ]; then
              SHARED_ACTION=1; reconcile_hp15 || result=1; SHARED_ACTION=0
            fi ;;
        esac
        case "$mode" in
          boot|renderer-watch|mumu-watch)
            if [ "$RENDERER_WATCHER_DISABLED" != 1 ]; then renderer_reconcile_all || result=1; fi ;;
        esac
        [ "$mode" != boot ] || run_all boot || result=1
        return "$result" ;;
    esac
    # No implicit selected-game fallback for any game operation.
    package=${1:-}; [ "$#" -eq 0 ] || shift
    known_package "$package" || fail "An explicit known Android package is required"
    set_game "$package" || fail "Unsafe target state directory"
    load_preferences
    case "$mode" in
      status)
        renderer_migrate_legacy || log_line "Renderer migration needs attention; historical files retained"
        print_status_legacy
        return 0 ;;
      ueini)
        do_ueini "${1:-}"
        return $? ;;
      gpu-cache-reset)
        do_gpu_cache_reset
        return $? ;;
      save|repair)
        token=${1:-}; shift
        is_sha256 "$token" || fail "Reload this game's status before saving"
        EXPECTED_CONTEXT=$token
        [ ! -f "$MODDIR/disable" ] && [ ! -f "$MODDIR/remove" ] || fail "Module is disabled"
        refresh_context 0 || fail "Installation/profile changed or unsupported; reload this game"
        [ "$#" -eq 24 ] || fail "Incomplete game settings"
        choices=${24}
        validate_requested_settings "$@"
        set_desired_runtime "$@"
        apply_patch_choices "$choices" || fail "Mandatory patch selection does not match this profile"
        verify_original_identity || fail "Could not verify this build's original APK library"
        refresh_context 0 || fail "Installation/profile changed before applying settings; reload this game"
        if [ "$mode" = save ]; then
          ( inspect_mumu_policy_only; inspect_all_binary_patches; ! managed_binary_has_unknown_state ) \
            || fail "Installed libUnreal.so contains unknown managed bytes; use Repair before applying settings"
        fi
        /system/bin/am force-stop "$TARGET_PACKAGE" 2>/dev/null || fail "Could not stop $TARGET_PACKAGE"
        reset_status_log || fail "Could not reset this game's log"
        apply_shared_settings "${10}" "${17}" "${13}" "${18}" || return $?
        load_shared_preferences
        if [ "$mode" = repair ]; then
          repair_and_apply_profile 'user requested Repair'; result=$?
        else
          reconcile 0 0; result=$?
        fi
        if [ "$result" != 0 ]; then
          log_line "Shared MuMu settings were saved; $mode did not complete for $TARGET_PACKAGE"
          return "$result"
        fi
        cache_restore_context || fail "Patches verified but restore metadata could not be committed"
        save_game_preferences || fail "Patches applied but preferences could not be committed"
        log_line "Configuration saved for $TARGET_PACKAGE"
        return 0 ;;
      *) fail "Unknown mode: $mode" ;;
    esac
}
