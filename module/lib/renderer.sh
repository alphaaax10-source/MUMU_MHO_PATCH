# Renderer tracking is per package. Snapshots are immutable generations; restore
# merges only CustomizedRendererString into the current effective document.
renderer_effective() {
    R_EFFECTIVE=""; R_SOURCE=none
    if [ -L "$RENDERER_DATA_CONFIG" ]; then return 1; fi
    if [ -f "$RENDERER_DATA_CONFIG" ]; then R_EFFECTIVE=$RENDERER_DATA_CONFIG; R_SOURCE=data
    elif [ -e "$RENDERER_DATA_CONFIG" ]; then return 1
    elif [ -L "$RENDERER_SYSTEM_CONFIG" ]; then return 1
    elif [ -f "$RENDERER_SYSTEM_CONFIG" ]; then R_EFFECTIVE=$RENDERER_SYSTEM_CONFIG; R_SOURCE=system
    elif [ -e "$RENDERER_SYSTEM_CONFIG" ]; then return 1
    fi
}
renderer_fields() {
    awk -v package="$TARGET_PACKAGE" -v mode=fields -f "$MODDIR/lib/renderer.awk" "$1"
}
renderer_without_target_spoof() {
    awk -v package="$TARGET_PACKAGE" -v mode=remove -f "$MODDIR/lib/renderer.awk" "$1" > "$2"
}
renderer_has_target_spoof() {
    local fields
    fields=$(renderer_fields "$1") || return 2
    [ -n "$fields" ]
}
renderer_record() {
    local generation
    generation=$(scalar_value "$R_TRACK/active.conf" generation)
    is_sha256 "$generation" || return 1
    R_GENERATION="$R_TRACK/generations/$generation"
    [ -d "$R_GENERATION" ] && [ ! -L "$R_GENERATION" ] || return 1
    [ "$(sha256_file "$R_GENERATION/before.config")" = "$generation" ] || return 1
    [ "$(sha256_file "$R_GENERATION/fields.txt")" = "$(scalar_value "$R_GENERATION/meta.conf" fields_sha256)" ] || return 1
    [ "$(sha256_file "$R_GENERATION/after.config")" = "$(scalar_value "$R_GENERATION/meta.conf" after_sha256)" ] || return 1
    [ "$(scalar_value "$R_GENERATION/meta.conf" package)" = "$TARGET_PACKAGE" ]
}
renderer_track_snapshot() {
    local before after source created generation dir tmp
    before=$1; after=$2; source=$3; created=$4
    generation=$(sha256_file "$before"); is_sha256 "$generation" || return 1
    dir="$R_TRACK/generations/$generation"
    safe_dir "$dir" || return 1
    # An existing complete generation must match; incomplete copies may be resumed.
    if [ -f "$dir/meta.conf" ]; then
        [ "$(sha256_file "$dir/before.config")" = "$generation" ] || return 1
        [ "$(sha256_file "$dir/after.config")" = "$(sha256_file "$after")" ] || return 1
    else
        copy_atomic "$before" "$dir/before.config" && copy_atomic "$after" "$dir/after.config" || return 1
        renderer_fields "$before" > "$dir/fields.txt" || return 1
        [ -s "$dir/fields.txt" ] || return 1
        {
          printf 'package=%s\nsource=%s\ncreated=%s\n' "$TARGET_PACKAGE" "$source" "$created"
          printf 'after_sha256=%s\nfields_sha256=%s\n' "$(sha256_file "$after")" "$(sha256_file "$dir/fields.txt")"
        } > "$dir/meta.conf.tmp" && mv "$dir/meta.conf.tmp" "$dir/meta.conf" || return 1
    fi
    tmp="$R_TRACK/.active.$$.tmp"; TEMP_FILES="$TEMP_FILES $tmp"
    printf 'generation=%s\n' "$generation" > "$tmp" && mv "$tmp" "$R_TRACK/active.conf" || return 1
    if [ "$created" = 1 ] && [ ! -f "$SHARED_DIR/renderer/created.conf" ]; then
        tmp="$SHARED_DIR/renderer/.created.$$.tmp"; TEMP_FILES="$TEMP_FILES $tmp"
        printf 'system_sha256=%s\n' "$generation" > "$tmp" && mv "$tmp" "$SHARED_DIR/renderer/created.conf" || return 1
    fi
}
renderer_migrate_legacy() {
    local before probe oldsha appliedsha created source
    [ "$TARGET_PACKAGE" = "$LEGACY_PACKAGE" ] || return 0
    [ ! -f "$R_TRACK/migrated" ] || return 0
    safe_dir "$R_TRACK" || return 1
    before=""
    for source in "$RENDERER_BACKUP_FILE" "$RENDERER_LEGACY_BACKUP_FILE"; do
        [ ! -L "$source" ] || return 1
        if [ -f "$source" ]; then before=$source; break; fi
    done
    if [ -z "$before" ]; then
        # No historical backup => no renderer migration to invent.
        [ ! -f "$ROOT_STATE/renderer_patch.conf" ] || return 1
        : > "$R_TRACK/migrated"; return 0
    fi
    renderer_effective || return 1
    [ -n "$R_EFFECTIVE" ] || return 1
    probe="$ROOT_STATE/.renderer_migration.$$.tmp"; TEMP_FILES="$TEMP_FILES $probe"
    renderer_without_target_spoof "$before" "$probe" || return 1
    oldsha=$(sha256_file "$before"); appliedsha=$(sha256_file "$probe")
    # Exact transformation is the only automatic migration proof.
    if [ "$(sha256_file "$R_EFFECTIVE")" = "$appliedsha" ]; then
        created=0; source=$RENDERER_DATA_CONFIG
        if [ "$(sha256_file "$RENDERER_SYSTEM_CONFIG")" = "$oldsha" ]; then created=1; source=$RENDERER_SYSTEM_CONFIG; fi
        renderer_track_snapshot "$before" "$probe" "$source" "$created" || return 1
    elif [ "$(sha256_file "$R_EFFECTIVE")" != "$oldsha" ]; then
        log_line "Legacy renderer backup differs from effective configuration; migration refused"
        return 1
    fi
    : > "$R_TRACK/migrated"
    # Historical .old remains intact and is never used as another game's baseline.
}
inspect_renderer_target() {
    local fields rc before_fields
    RENDERER_STATE=not_required; RENDERER_SOURCE=none; RENDERER_EFFECTIVE_PATH=""
    if ! renderer_effective; then RENDERER_STATE=unknown; return 0; fi
    RENDERER_SOURCE=$R_SOURCE; RENDERER_EFFECTIVE_PATH=$R_EFFECTIVE
    [ -n "$R_EFFECTIVE" ] || return 0
    fields=$(renderer_fields "$R_EFFECTIVE"); rc=$?
    if [ "$rc" = 4 ]; then
        [ ! -f "$R_TRACK/active.conf" ] || RENDERER_STATE=unknown
        return 0
    fi
    if [ "$rc" != 0 ]; then RENDERER_STATE=unknown; return 0; fi
    if [ -f "$R_TRACK/active.conf" ]; then
        if ! renderer_record; then RENDERER_STATE=unknown
        elif [ -z "$fields" ]; then RENDERER_STATE=applied
        else RENDERER_STATE=needs_patch
        fi
    elif renderer_has_target_spoof "$R_EFFECTIVE"; then RENDERER_STATE=needs_patch
    fi
}
apply_renderer_config_patch() {
    local source content sha output normalized rc created mode uid gid target_dir
    inspect_renderer_target
    [ "$RENDERER_STATE" = needs_patch ] || return 0
    source=$R_EFFECTIVE
    sha=$(sha256_file "$source")
    content=$R_EFFECTIVE
    # A module-owned IgnoreGLError line is stripped from the content used for
    # snapshots so before/after stay gler-free; gler_reconcile_pkg re-applies
    # it right after the renderer install.
    if [ "$(scalar_value "$(gler_record)" line_owned)" = 1 ] \
        && awk -v package="$TARGET_PACKAGE" -v mode=gler-state -f "$MODDIR/lib/renderer.awk" "$content" >/dev/null 2>&1; then
        normalized="$ROOT_STATE/.renderer_norm.$$.tmp"; TEMP_FILES="$TEMP_FILES $normalized"
        rc=0
        awk -v package="$TARGET_PACKAGE" -v mode=gler-remove -f "$MODDIR/lib/renderer.awk" "$content" > "$normalized" || rc=$?
        [ "$rc" = 0 ] || rm -f "$normalized"
        [ "$rc" != 0 ] || content=$normalized
    fi
    output="$ROOT_STATE/.renderer.$$.tmp"; TEMP_FILES="$TEMP_FILES $output"
    renderer_without_target_spoof "$content" "$output" || return 1
    created=0; [ "$R_SOURCE" != system ] || created=1
    mode=$(stat -c %a "$source") || return 1
    uid=$(stat -c %u "$source") || return 1
    gid=$(stat -c %g "$source") || return 1
    if [ "$created" = 1 ]; then uid=1000; gid=1000; fi
    target_dir=${RENDERER_DATA_CONFIG%/*}
    [ ! -L "$target_dir" ] || return 1
    if [ ! -d "$target_dir" ]; then mkdir -p "$target_dir" && chmod 0755 "$target_dir" && chown 1000:1000 "$target_dir" || return 1; fi
    renderer_track_snapshot "$content" "$output" "$content" "$created" || return 1
    renderer_effective || return 1
    [ "$R_EFFECTIVE" = "$source" ] && [ "$(sha256_file "$source")" = "$sha" ] || return 2
    [ ! -f "$MODDIR/disable" ] && [ ! -f "$MODDIR/remove" ] || return 1
    [ "$(profile_set_revision)" = "$PROFILE_SET_REVISION" ] || return 1
    renderer_atomic_install "$output" "$(sha256_file "$output")" "$mode" "$uid" "$gid" || return 1
    inspect_renderer_target
    [ "$RENDERER_STATE" = applied ]
}
restore_renderer_config() {
    local fields source sha output mode uid gid
    [ -f "$R_TRACK/active.conf" ] || return 0
    renderer_record || return 1
    renderer_effective || return 1
    [ -n "$R_EFFECTIVE" ] || return 1
    source=$R_EFFECTIVE; sha=$(sha256_file "$source")
    fields=$(renderer_fields "$source") || return 1
    if [ "$fields" = "$(cat "$R_GENERATION/fields.txt")" ]; then
        rm -f "$R_TRACK/active.conf"; return 0
    fi
    [ -z "$fields" ] || { log_line "Renderer field changed externally for $TARGET_PACKAGE; retaining recovery data"; return 1; }
    output="$ROOT_STATE/.renderer_restore.$$.tmp"; TEMP_FILES="$TEMP_FILES $output"
    # When no other change exists, retain the exact original ordering/bytes.
    if [ "$sha" = "$(sha256_file "$R_GENERATION/after.config")" ]; then
        cp "$R_GENERATION/before.config" "$output" || return 1
    else
        awk -v package="$TARGET_PACKAGE" -v mode=merge -v field_file="$R_GENERATION/fields.txt" -v before_file="$R_GENERATION/before.config" -f "$MODDIR/lib/renderer.awk" "$source" > "$output" || return 1
    fi
    mode=$(stat -c %a "$source"); uid=$(stat -c %u "$source"); gid=$(stat -c %g "$source")
    renderer_effective || return 1
    [ "$R_EFFECTIVE" = "$source" ] && [ "$(sha256_file "$source")" = "$sha" ] || return 1
    renderer_atomic_install "$output" "$(sha256_file "$output")" "$mode" "$uid" "$gid" || return 1
    [ "$(renderer_fields "$RENDERER_DATA_CONFIG")" = "$(cat "$R_GENERATION/fields.txt")" ] || return 1
    rm -f "$R_TRACK/active.conf"
    renderer_cleanup_override
}
renderer_cleanup_override() {
    local f original any_active=0
    for f in "$SHARED_DIR/renderer"/*/active.conf; do [ ! -f "$f" ] || any_active=1; done
    [ "$any_active" = 0 ] || return 0
    [ -f "$RENDERER_DATA_CONFIG" ] || return 0
    [ ! -L "$RENDERER_DATA_CONFIG" ] || return 0
    if [ -f "$SHARED_DIR/renderer/created.conf" ]; then
        original=$(scalar_value "$SHARED_DIR/renderer/created.conf" system_sha256)
        # Remove a module-created override only if identical to today's system base.
        # A merge with external changes remains in place, even on final uninstall.
        if is_sha256 "$original" && [ "$(sha256_file "$RENDERER_SYSTEM_CONFIG")" = "$original" ] \
          && [ "$(sha256_file "$RENDERER_DATA_CONFIG")" = "$original" ]; then
            rm -f "$RENDERER_DATA_CONFIG" "$SHARED_DIR/renderer/created.conf" || return 1
            log_line "Removed renderer.config override matching the system base"
        fi
        return 0
    fi
    # No creation record (e.g. an IgnoreGLError-only override): drop the file
    # only when it is byte-identical to today's system base.
    if [ -f "$RENDERER_SYSTEM_CONFIG" ] && [ ! -L "$RENDERER_SYSTEM_CONFIG" ] \
      && [ "$(sha256_file "$RENDERER_DATA_CONFIG")" = "$(sha256_file "$RENDERER_SYSTEM_CONFIG")" ]; then
        rm -f "$RENDERER_DATA_CONFIG" || return 1
        log_line "Removed renderer.config override matching the system base"
    fi
    return 0
}
reconcile_renderer_config() {
    # The shared phase applies all packages once; selected-game reconciliation
    # must not repeat a single-package renderer operation.
    [ "${SHARED_RENDERER_ACTION:-0}" = 1 ] || return 0
    inspect_mumu_policy_only
    inspect_renderer_target
    [ "$RENDERER_STATE" != unavailable ] || return 0
    if [ "${MANDATORY_RENDERER_DISABLED:-0}" = 1 ]; then
        gler_restore_pkg || return 1
        restore_renderer_config || return $?
        gler_reconcile_pkg || return 1
    else
        case "$RENDERER_STATE" in
          applied|not_required) : ;;
          needs_patch) apply_renderer_config_patch || return $? ;;
          *) log_line "Renderer state is unsafe for $TARGET_PACKAGE"; return 1 ;;
        esac
        # IgnoreGLError runs after the spoof transform so before/after snapshots
        # stay gler-free and byte-exact restores keep working.
        gler_reconcile_pkg || return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# IgnoreGLError compatibility (the community fix GPM Device Level 7 needs).
# Ownership lives in $R_TRACK/gler.conf so a manually-added line is never
# removed by this module.
gler_record() { printf '%s/gler.conf' "$R_TRACK"; }

# Sets GLER_STATE: applied | absent | unknown | unavailable
gler_inspect_pkg() {
    GLER_STATE=unavailable
    renderer_effective || return 0
    local rc=0
    awk -v package="$TARGET_PACKAGE" -v mode=gler-state -f "$MODDIR/lib/renderer.awk" "$R_EFFECTIVE" >/dev/null 2>&1 || rc=$?
    case "$rc" in
        0) GLER_STATE=applied ;;
        4|11) GLER_STATE=absent ;;
        *) GLER_STATE=unknown ;;
    esac
    return 0
}

gler_apply_pkg() {
    renderer_effective || return 0
    gler_inspect_pkg
    local record tmp rc block_owned created mode uid gid target_dir target_mode
    record=$(gler_record)
    case "$GLER_STATE" in
        applied)
            [ -f "$record" ] || printf 'line_owned=0\nblock_owned=0\nfile_created=0\n' > "$record"
            return 0 ;;
        unknown)
            log_line "IgnoreGLError inspection failed for $TARGET_PACKAGE"
            return 1 ;;
    esac
    [ -d "$R_TRACK" ] || safe_dir "$R_TRACK" || return 1
    tmp="$ROOT_STATE/.gler.$$.tmp"; TEMP_FILES="$TEMP_FILES $tmp"
    rc=0
    awk -v package="$TARGET_PACKAGE" -v mode=gler-add -f "$MODDIR/lib/renderer.awk" "$R_EFFECTIVE" > "$tmp" || rc=$?
    case "$rc" in
        0) block_owned=0 ;;
        1) block_owned=1 ;;
        *) log_line "Could not add IgnoreGLError for $TARGET_PACKAGE"; return 1 ;;
    esac
    created=0; [ "$R_SOURCE" != system ] || created=1
    mode=$(stat -c %a "$R_EFFECTIVE") || return 1
    uid=$(stat -c %u "$R_EFFECTIVE") || return 1
    gid=$(stat -c %g "$R_EFFECTIVE") || return 1
    if [ "$created" = 1 ]; then uid=1000; gid=1000; fi
    target_dir=${RENDERER_DATA_CONFIG%/*}
    [ ! -L "$target_dir" ] || return 1
    if [ ! -d "$target_dir" ]; then
        mkdir -p "$target_dir" || return 1
        target_mode=$(stat -c %a "${R_EFFECTIVE%/*}") || return 1
        chmod "$target_mode" "$target_dir" || return 1
        if [ "$created" = 1 ]; then chown 1000:1000 "$target_dir" || return 1; fi
    fi
    renderer_atomic_install "$tmp" "$(sha256_file "$tmp")" "$mode" "$uid" "$gid" || return 1
    rm -f "$tmp"
    tmp="$R_TRACK/gler.conf.$$.tmp"; TEMP_FILES="$TEMP_FILES $tmp"
    printf 'line_owned=1\nblock_owned=%s\nfile_created=%s\n' "$block_owned" "$created" > "$tmp" \
        && chmod 0600 "$tmp" && mv -f "$tmp" "$(gler_record)" || return 1
    log_line "IgnoreGLError compatibility applied for $TARGET_PACKAGE"
    return 0
}

gler_restore_pkg() {
    local record line_owned block_owned tmp rc created mode uid gid target_dir target_mode
    record=$(gler_record)
    line_owned=$(scalar_value "$record" line_owned)
    if [ "$line_owned" != 1 ]; then
        [ ! -f "$record" ] || rm -f "$record"
        return 0
    fi
    if ! renderer_effective; then rm -f "$record"; return 0; fi
    gler_inspect_pkg
    if [ "$GLER_STATE" != applied ]; then rm -f "$record"; return 0; fi
    block_owned=$(scalar_value "$record" block_owned)
    tmp="$ROOT_STATE/.gler.$$.tmp"; TEMP_FILES="$TEMP_FILES $tmp"
    rc=0
    awk -v package="$TARGET_PACKAGE" -v mode=gler-remove -v drop_block="$block_owned" -f "$MODDIR/lib/renderer.awk" "$R_EFFECTIVE" > "$tmp" || rc=$?
    case "$rc" in
        0) ;;
        10) rm -f "$tmp" "$record"; return 0 ;;
        *) log_line "Could not remove IgnoreGLError for $TARGET_PACKAGE"; return 1 ;;
    esac
    created=0; [ "$R_SOURCE" != system ] || created=1
    mode=$(stat -c %a "$R_EFFECTIVE") || return 1
    uid=$(stat -c %u "$R_EFFECTIVE") || return 1
    gid=$(stat -c %g "$R_EFFECTIVE") || return 1
    if [ "$created" = 1 ]; then uid=1000; gid=1000; fi
    target_dir=${RENDERER_DATA_CONFIG%/*}
    [ ! -L "$target_dir" ] || return 1
    renderer_atomic_install "$tmp" "$(sha256_file "$tmp")" "$mode" "$uid" "$gid" || return 1
    rm -f "$tmp"
    rm -f "$record"
    log_line "IgnoreGLError compatibility restored for $TARGET_PACKAGE"
    return 0
}

gler_reconcile_pkg() {
    if [ "${MANDATORY_GLER_DISABLED:-0}" = 1 ]; then gler_restore_pkg; else gler_apply_pkg; fi
}

gler_reconcile_all() {
    local p result rc
    result=0
    for p in $(renderer_tracked_packages); do
        (
            TARGET_PACKAGE=$p; R_TRACK="$SHARED_DIR/renderer/$p"
            gler_reconcile_pkg
        )
        rc=$?
        [ "$rc" = 0 ] || { log_line "IgnoreGLError reconciliation failed for $p"; result=1; }
    done
    return "$result"
}

# Aggregate state for shared status: unknown > applied > absent > none
gler_inspect_all() {
    local p state
    GLER_ALL_STATE=none
    for p in $(renderer_tracked_packages); do
        state=$(
            TARGET_PACKAGE=$p; R_TRACK="$SHARED_DIR/renderer/$p"
            gler_inspect_pkg
            printf '%s' "$GLER_STATE"
        )
        case "$state:$GLER_ALL_STATE" in
            unknown:*) GLER_ALL_STATE=unknown ;;
            applied:none|applied:absent) GLER_ALL_STATE=applied ;;
            absent:none) GLER_ALL_STATE=absent ;;
            unavailable:none) GLER_ALL_STATE=absent ;;
        esac
    done
    return 0
}

# Renderer scope comes from every distinct package in the normalized catalogue,
# independently of installed games, build matching and binary feature readiness.
renderer_packages() { catalog_packages; }
renderer_tracked_packages() {
    local d p
    { renderer_packages
      for d in "$SHARED_DIR/renderer"/*; do
        [ -d "$d" ] && [ ! -L "$d" ] || continue
        p=${d##*/}; safe_package "$p" && printf '%s\n' "$p"
      done
    } | LC_ALL=C sort -u
}
renderer_reconcile_all() {
    local p result rc
    result=0
    for p in $(renderer_tracked_packages); do
        (
            TARGET_PACKAGE=$p; R_TRACK="$SHARED_DIR/renderer/$p"
            SHARED_RENDERER_ACTION=1
            renderer_migrate_legacy || exit 1
            if [ "$MANDATORY_RENDERER_DISABLED" = 1 ]; then
                # Strip the owned IgnoreGLError line first so the renderer
                # restore sees an exact snapshot match, then re-apply gler if
                # it is still enabled.
                gler_restore_pkg || exit 1
                restore_renderer_config || exit 1
                gler_reconcile_pkg || exit 1
            elif renderer_packages | grep -Fxq "$p"; then reconcile_renderer_config
            else
                gler_restore_pkg || exit 1
                restore_renderer_config || exit 1
                gler_reconcile_pkg || exit 1
            fi
        )
        rc=$?
        [ "$rc" = 0 ] || { log_line "Shared renderer reconciliation failed for $p"; result=1; }
    done
    renderer_cleanup_override || result=1
    return "$result"
}
inspect_renderer_config() {
    local p state states
    states=""
    for p in $(renderer_tracked_packages); do
        state=$(
            TARGET_PACKAGE=$p; R_TRACK="$SHARED_DIR/renderer/$p"
            inspect_renderer_target
            printf '%s\n' "$RENDERER_STATE"
        )
        states="$states $state"
    done
    RENDERER_STATE=not_required
    case " $states " in *' applied '*) RENDERER_STATE=applied ;; esac
    case " $states " in *' needs_patch '*) RENDERER_STATE=needs_patch ;; esac
    case " $states " in *' unknown '*) RENDERER_STATE=unknown ;; esac
    renderer_effective || RENDERER_STATE=unknown
    RENDERER_SOURCE=$R_SOURCE; RENDERER_EFFECTIVE_PATH=$R_EFFECTIVE
}
