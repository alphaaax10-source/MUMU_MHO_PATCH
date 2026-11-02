#!/system/bin/sh

# MHO MuMu Patcher 1.4.2
# KernelSU executes module scripts with BusyBox ash in standalone mode.

MODDIR=${0%/*}
TARGET_PACKAGE="com.tencent.mhadv"
PROFILE_DIR="$MODDIR/profiles"
STATE_DIR="/data/adb/mho_mumu_patcher"
PREF_FILE="$STATE_DIR/preferences.conf"
STATUS_FILE="$STATE_DIR/status.log"
RESTORE_CONTEXT_FILE="$STATE_DIR/restore_context.conf"
RENDERER_STATE_FILE="$STATE_DIR/renderer_patch.conf"
RENDERER_LEGACY_BACKUP_FILE="$STATE_DIR/renderer.config.backup"
HP15_STATE_FILE="$STATE_DIR/hp15_override.conf"
RUN_MODE=${1:-manual}

HP15_DATA_SYSTEM_DIR="/data/system"
HP15_DATA_ETC_DIR="$HP15_DATA_SYSTEM_DIR/etc"
HP15_DATA_CONFIG_DIR="$HP15_DATA_ETC_DIR/mumu-configs"
HP15_DATA_DIR="$HP15_DATA_CONFIG_DIR/shared_libs"
HP15_DATA_LIBRARY="$HP15_DATA_DIR/libhp15_x86_64.so"
HP15_BACKUP_FILE="${HP15_DATA_LIBRARY}.old"
HP15_CREATED_MARKER="$HP15_DATA_DIR/createdbymodule"
HP15_PAYLOAD="$MODDIR/payload/libhp15_x86_64.so"
HP15_PAYLOAD_SHA256="f6f7ea74adff2f22b91e2c9feea9ec57134748eb38d8404faef4cae9c1aabdbb"
# Keep previous module payload SHA-256 values here when the bundled libhp15 changes.
# createdbymodule stays empty; ownership requires the marker plus a known payload SHA.
HP15_KNOWN_PAYLOAD_SHA256S="$HP15_PAYLOAD_SHA256"
# MuMu libhp15 builds at or after this inclusive cutoff are crash-prone.
# 2026-08-20 10:03:14 +0200 (2026-08-20 08:03:14 UTC).
HP15_BAD_CUTOFF_EPOCH=1787212994
RENDERER_SYSTEM_CONFIG="/system/etc/mumu-configs/renderer.config"
RENDERER_DATA_CONFIG="/data/system/etc/mumu-configs/renderer.config"
RENDERER_BACKUP_FILE="${RENDERER_DATA_CONFIG}.old"
# Game-side data roots (overridable for tests).
: "${UEINI_DATA_ROOT:=/data/data}"
: "${GPU_CACHE_DATA_ROOT:=/data/data}"
UEINI_MARKER_BEGIN="; MHO_MU_MU_PATCHER_BEGIN"
UEINI_MARKER_END="; MHO_MU_MU_PATCHER_END"

FPS_MIN=20
FPS_MAX=240
# SAFETY LIMIT: Do not raise FPS_MAX above 240 without redesigning the
# legacy UFPSAnalyzer float-immediate patch. Its single MOVZ encoding cannot
# represent every integer float above 240 (for example, some odd values above
# 256 would be silently rounded/truncated). Backend validation deliberately
# rejects anything outside FPS_MIN..FPS_MAX even if the WebUI is modified.

QUIET=0
case "$RUN_MODE" in
	status|advanced-defaults|hp15-watch|renderer-watch|mumu-watch) QUIET=1 ;;
esac

mkdir -p "$STATE_DIR" || exit 10
chmod 0700 "$STATE_DIR" 2>/dev/null || true

TEMP_FILES=""
LOCK_DIR="$STATE_DIR/operation.lock"
LOCK_HELD=0

current_boot_id() {
	cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf 'unknown\n'
}

proc_start_ticks() {
	local pid
	pid=$1
	[ -r "/proc/$pid/stat" ] || return 1
	awk '{sub(/^.*\) /, ""); print $20}' "/proc/$pid/stat" 2>/dev/null | head -n 1
}

lock_owner_is_live() {
	local owner owner_boot owner_ticks now_boot now_ticks
	owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
	owner_boot=$(cat "$LOCK_DIR/boot_id" 2>/dev/null || true)
	owner_ticks=$(cat "$LOCK_DIR/start_ticks" 2>/dev/null || true)
	[ -n "$owner" ] && [ -n "$owner_boot" ] && [ -n "$owner_ticks" ] || return 1
	now_boot=$(current_boot_id)
	[ "$owner_boot" = "$now_boot" ] || return 1
	kill -0 "$owner" 2>/dev/null || return 1
	now_ticks=$(proc_start_ticks "$owner" 2>/dev/null || true)
	[ -n "$now_ticks" ] && [ "$now_ticks" = "$owner_ticks" ]
}

release_lock() {
	local owner owner_boot owner_ticks my_boot my_ticks
	[ "$LOCK_HELD" -eq 1 ] || return 0
	owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
	owner_boot=$(cat "$LOCK_DIR/boot_id" 2>/dev/null || true)
	owner_ticks=$(cat "$LOCK_DIR/start_ticks" 2>/dev/null || true)
	my_boot=$(current_boot_id)
	my_ticks=$(proc_start_ticks "$$" 2>/dev/null || true)
	if [ "$owner" = "$$" ] && [ "$owner_boot" = "$my_boot" ] && [ -n "$my_ticks" ] && [ "$owner_ticks" = "$my_ticks" ]; then
		rm -rf -- "$LOCK_DIR" 2>/dev/null || true
	fi
	LOCK_HELD=0
}

acquire_lock() {
	local waits incomplete_waits my_boot my_ticks
	waits=0
	incomplete_waits=0
	my_boot=$(current_boot_id)
	my_ticks=$(proc_start_ticks "$$" 2>/dev/null || true)
	[ -n "$my_ticks" ] || return 1

	while ! mkdir "$LOCK_DIR" 2>/dev/null; do
		if lock_owner_is_live; then
			incomplete_waits=0
		else
			# A creator can briefly own the directory before publishing all
			# metadata. Give it two seconds; otherwise the lock is stale. The
			# boot-id + /proc start-time pair also makes PID reuse harmless.
			if [ ! -s "$LOCK_DIR/pid" ] || [ ! -s "$LOCK_DIR/boot_id" ] || [ ! -s "$LOCK_DIR/start_ticks" ]; then
				incomplete_waits=$((incomplete_waits + 1))
				if [ "$incomplete_waits" -lt 3 ]; then
					sleep 1
					waits=$((waits + 1))
					[ "$waits" -lt 60 ] || return 1
					continue
				fi
			fi
			rm -rf -- "$LOCK_DIR" 2>/dev/null || true
			incomplete_waits=0
			continue
		fi

		[ "$waits" -lt 60 ] || return 1
		waits=$((waits + 1))
		sleep 1
	done

	{
		printf '%s\n' "$$" > "$LOCK_DIR/pid" &&
		printf '%s\n' "$my_boot" > "$LOCK_DIR/boot_id" &&
		printf '%s\n' "$my_ticks" > "$LOCK_DIR/start_ticks"
	} 2>/dev/null || {
		rm -rf -- "$LOCK_DIR" 2>/dev/null || true
		return 1
	}
	chmod 0700 "$LOCK_DIR" 2>/dev/null || true
	chmod 0600 "$LOCK_DIR/pid" "$LOCK_DIR/boot_id" "$LOCK_DIR/start_ticks" 2>/dev/null || true
	LOCK_HELD=1
	return 0
}

cleanup() {
	for f in $TEMP_FILES; do
		rm -f -- "$f" 2>/dev/null || true
	done
	release_lock
}

on_signal() {
	code=$1
	trap - EXIT HUP INT TERM
	cleanup
	exit "$code"
}

trap cleanup EXIT
trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

reset_status_log() {
	[ "$QUIET" -eq 1 ] && return 0
	: > "$STATUS_FILE" || return 1
}

log_line() {
	message=$*
	stamp=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)
	printf '%s | %s\n' "$stamp" "$message" >> "$STATUS_FILE" 2>/dev/null || true
	/system/bin/log -t MHO_PATCH "$message" 2>/dev/null || true
	[ "$QUIET" -eq 1 ] || printf '%s\n' "$message"
}

fail() {
	printf '%s\n' "ERROR: $*" >&2
	log_line "ERROR: $*"
	exit 1
}

json_string() {
    # Input has been normalized and validated by profile_json.awk.
    awk -v key="$2" '
      $0 ~ "^[[:space:]]*\"" key "\"[[:space:]]*:" {
        v=$0; sub(/^[^:]*:[[:space:]]*/, "", v)
        if(substr(v,1,1)!="\"")exit
        out=""; for(i=2;i<=length(v);i++) {
          c=substr(v,i,1)
          if(c=="\""){print out;exit}
          if(c=="\\")c=substr(v,++i,1)
          out=out c
        }
      }' "$1"
}

json_number() {
	local file key
	file=$1
	key=$2
	sed -n 's/^[[:space:]]*"'"$key"'"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p' "$file" | head -n 1
}

json_bool() {
	local file key value
	file=$1
	key=$2
	# POSIX/BRE-friendly parser for Android/toybox sed.
	# Avoid GNU-style BRE alternation (\|), which is not portable here.
	value=$(sed -n 's/^[[:space:]]*"'"$key"'"[[:space:]]*:[[:space:]]*\([^,[:space:]]*\)[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p' "$file" | head -n 1)
	case "$value" in
		true) printf '1\n' ;;
		false) printf '0\n' ;;
		*) return 1 ;;
	esac
}

is_safe_id() {
	case "$1" in
		""|*[!A-Za-z0-9._-]*) return 1 ;;
		*) return 0 ;;
	esac
}

is_hex() {
	local value
	value=$1
	case "$value" in
		""|*[!0-9A-Fa-f]*) return 1 ;;
	esac
	[ $(( ${#value} % 2 )) -eq 0 ]
}

is_sha256() {
	local value
	value=$(printf '%s' "$1" | tr 'A-F' 'a-f')
	[ "${#value}" -eq 64 ] || return 1
	is_hex "$value"
}

hex_to_file() {
	local work_hex output pair decimal octal
	work_hex=$1
	output=$2
	is_hex "$work_hex" || return 1
	: > "$output" || return 1

	while [ -n "$work_hex" ]; do
		pair=${work_hex%"${work_hex#??}"}
		work_hex=${work_hex#??}
		decimal=$((0x$pair))
		octal=$(printf '%03o' "$decimal")
		printf '%b' "\\0$octal" >> "$output" || return 1
	done
}

read_hex() {
	library=$1
	offset=$2
	length=$3
	dd if="$library" bs=1 skip="$offset" count="$length" 2>/dev/null \
		| od -v -An -tx1 | tr -d '[:space:]' | tr 'A-F' 'a-f'
}

sha256_file() {
	sha256sum "$1" 2>/dev/null | awk '{print $1}' | tr 'A-F' 'a-f'
}

renderer_atomic_install() {
	local source expected_sha mode uid gid target_dir tmp actual_sha
	source=$1
	expected_sha=$2
	mode=$3
	uid=$4
	gid=$5
	target_dir=${RENDERER_DATA_CONFIG%/*}
	tmp="$target_dir/.mho_renderer_install.$$.tmp"
	TEMP_FILES="$TEMP_FILES $tmp"

	cp "$source" "$tmp" 2>/dev/null || return 1
	actual_sha=$(sha256_file "$tmp")
	[ "$actual_sha" = "$expected_sha" ] || return 1
	chmod "$mode" "$tmp" 2>/dev/null || return 1
	chown "$uid:$gid" "$tmp" 2>/dev/null || return 1
	/system/bin/restorecon "$tmp" 2>/dev/null || true
	sync
	mv -f "$tmp" "$RENDERER_DATA_CONFIG" || return 1
	/system/bin/restorecon "$RENDERER_DATA_CONFIG" 2>/dev/null || true
	sync
	actual_sha=$(sha256_file "$RENDERER_DATA_CONFIG")
	[ "$actual_sha" = "$expected_sha" ]
}


context_value() {
	local key
	key=$1
	[ -f "$RESTORE_CONTEXT_FILE" ] || return 1
	sed -n 's/^'"$key"'=//p' "$RESTORE_CONTEXT_FILE" | head -n 1
}

is_safe_data_path() {
	case "$1" in
		/data/app/*) ;;
		*) return 1 ;;
	esac
	case "$1" in
		*..*|*'\n'*|*'\r'*) return 1 ;;
	esac
	return 0
}

cache_restore_context_legacy() {
	local tmp count apk
	[ -n "${VERSION:-}" ] && [ -n "${PROFILE_ID:-}" ] && [ -n "${INSTALL_ROOT:-}" ] \
		&& [ -n "${LIBRARY:-}" ] && [ -n "${RELATIVE_LIBRARY:-}" ] \
		&& [ -n "${APK_LIBRARY:-}" ] && [ -n "${ORIGINAL_SHA256:-}" ] || return 1
	is_safe_data_path "$INSTALL_ROOT" || return 1
	is_safe_data_path "$LIBRARY" || return 1
	[ "$LIBRARY" = "$INSTALL_ROOT/$RELATIVE_LIBRARY" ] || return 1
	is_sha256 "$ORIGINAL_SHA256" || return 1

	tmp="$STATE_DIR/.restore_context.$$.tmp"
	TEMP_FILES="$TEMP_FILES $tmp"
	count=0
	{
		printf 'schema=2\n'
		printf 'package=%s\n' "$TARGET_PACKAGE"
		printf 'version=%s\n' "$VERSION"
		printf 'profile_id=%s\n' "$PROFILE_ID"
		printf 'install_root=%s\n' "$INSTALL_ROOT"
		printf 'library=%s\n' "$LIBRARY"
		printf 'relative_library=%s\n' "$RELATIVE_LIBRARY"
		printf 'apk_library=%s\n' "$APK_LIBRARY"
		printf 'original_sha256=%s\n' "$ORIGINAL_SHA256"
		printf 'library_dev=%s\n' "$(stat -c %d "$LIBRARY" 2>/dev/null || printf '0')"
		printf 'library_inode=%s\n' "$(stat -c %i "$LIBRARY" 2>/dev/null || printf '0')"
		printf 'library_size=%s\n' "$(stat -c %s "$LIBRARY" 2>/dev/null || printf '0')"
		for apk in $APK_PATHS; do
			is_safe_data_path "$apk" || continue
			[ -f "$apk" ] || continue
			count=$((count + 1))
			printf 'apk_%s=%s\n' "$count" "$apk"
		done
		printf 'apk_count=%s\n' "$count"
		printf 'boot_id=%s\n' "$(current_boot_id)"
	} > "$tmp" || return 1
	[ "$count" -gt 0 ] || { rm -f "$tmp" 2>/dev/null || true; return 1; }
	chmod 0600 "$tmp" 2>/dev/null || true
	mv -f "$tmp" "$RESTORE_CONTEXT_FILE" || return 1
	chmod 0600 "$RESTORE_CONTEXT_FILE" 2>/dev/null || true
	return 0
}

load_cached_restore_context() {
	C_SCHEMA=$(context_value schema 2>/dev/null || true)
	C_PACKAGE=$(context_value package 2>/dev/null || true)
	C_VERSION=$(context_value version 2>/dev/null || true)
	C_PROFILE_ID=$(context_value profile_id 2>/dev/null || true)
	C_INSTALL_ROOT=$(context_value install_root 2>/dev/null || true)
	C_LIBRARY=$(context_value library 2>/dev/null || true)
	C_RELATIVE_LIBRARY=$(context_value relative_library 2>/dev/null || true)
	C_APK_LIBRARY=$(context_value apk_library 2>/dev/null || true)
	C_ORIGINAL_SHA256=$(context_value original_sha256 2>/dev/null | tr 'A-F' 'a-f' || true)
	C_LIBRARY_DEV=$(context_value library_dev 2>/dev/null || true)
	C_LIBRARY_INODE=$(context_value library_inode 2>/dev/null || true)
	C_LIBRARY_SIZE=$(context_value library_size 2>/dev/null || true)
	C_APK_COUNT=$(context_value apk_count 2>/dev/null || true)

	[ "$C_SCHEMA" = "2" ] || return 1
	[ "$C_PACKAGE" = "$TARGET_PACKAGE" ] || return 1
	[ -n "$C_VERSION" ] || return 1
	is_safe_id "$C_PROFILE_ID" || return 1
	case "$C_RELATIVE_LIBRARY" in lib/*) ;; *) return 1 ;; esac
	case "$C_RELATIVE_LIBRARY" in *..*) return 1 ;; esac
	case "$C_APK_LIBRARY" in lib/*) ;; *) return 1 ;; esac
	case "$C_APK_LIBRARY" in *..*) return 1 ;; esac
	is_sha256 "$C_ORIGINAL_SHA256" || return 1
	case "$C_LIBRARY_DEV" in ''|*[!0-9]*) return 1 ;; esac
	case "$C_LIBRARY_INODE" in ''|*[!0-9]*) return 1 ;; esac
	case "$C_LIBRARY_SIZE" in ''|*[!0-9]*) return 1 ;; esac
	[ "$C_LIBRARY_DEV" -gt 0 ] 2>/dev/null || return 1
	[ "$C_LIBRARY_INODE" -gt 0 ] 2>/dev/null || return 1
	[ "$C_LIBRARY_SIZE" -gt 0 ] 2>/dev/null || return 1
	is_safe_data_path "$C_INSTALL_ROOT" || return 1
	is_safe_data_path "$C_LIBRARY" || return 1
	[ "$C_LIBRARY" = "$C_INSTALL_ROOT/$C_RELATIVE_LIBRARY" ] || return 1
	case "$C_APK_COUNT" in ''|*[!0-9]*) return 1 ;; esac
	[ "$C_APK_COUNT" -ge 1 ] 2>/dev/null && [ "$C_APK_COUNT" -le 64 ] 2>/dev/null || return 1
	return 0
}

atomic_install_library_legacy() {
	local source target expected_sha source_sha target_dir target_mode target_uid target_gid tmp tmp_sha final_sha
	source=$1
	target=$2
	expected_sha=$(printf '%s' "$3" | tr 'A-F' 'a-f')
	[ -f "$source" ] && [ -f "$target" ] || return 1
	is_sha256 "$expected_sha" || return 1
	source_sha=$(sha256_file "$source")
	[ "$source_sha" = "$expected_sha" ] || return 1

	target_dir=${target%/*}
	target_mode=$(stat -c %a "$target" 2>/dev/null) || return 1
	target_uid=$(stat -c %u "$target" 2>/dev/null) || return 1
	target_gid=$(stat -c %g "$target" 2>/dev/null) || return 1
	tmp="$target_dir/.mho_install.$$.tmp"
	TEMP_FILES="$TEMP_FILES $tmp"
	rm -f -- "$tmp" 2>/dev/null || true

	cat "$source" > "$tmp" || { rm -f -- "$tmp" 2>/dev/null || true; return 1; }
	chmod "$target_mode" "$tmp" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null || true; return 1; }
	chown "$target_uid:$target_gid" "$tmp" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null || true; return 1; }
	/system/bin/restorecon "$tmp" 2>/dev/null || true
	tmp_sha=$(sha256_file "$tmp")
	[ "$tmp_sha" = "$expected_sha" ] || { rm -f -- "$tmp" 2>/dev/null || true; return 1; }

	# Same-directory rename publishes a fully prepared image in one operation.
	# sync before and after narrows the power-loss window; the final checksum
	# remains the authority.
	sync
	prepublish_library_guard "$target" || return 1
	mv -f "$tmp" "$target" || { rm -f -- "$tmp" 2>/dev/null || true; return 1; }
	/system/bin/restorecon "$target" 2>/dev/null || true
	sync
	final_sha=$(sha256_file "$target")
	[ "$final_sha" = "$expected_sha" ] || return 1
	return 0
}

extract_pristine_from_apk_list() {
	local destination expected_sha apk_list apk actual_sha
	destination=$1
	expected_sha=$2
	apk_list=$3
	for apk in $apk_list; do
		[ -f "$apk" ] || continue
		rm -f "$destination" 2>/dev/null || true
		if unzip -p "$apk" "$APK_LIBRARY" > "$destination" 2>/dev/null && [ -s "$destination" ]; then
			actual_sha=$(sha256_file "$destination")
			if [ "$actual_sha" = "$expected_sha" ]; then
				PRISTINE_APK=$apk
				PRISTINE_SHA=$actual_sha
				return 0
			fi
		fi
	done
	rm -f "$destination" 2>/dev/null || true
	return 1
}

restore_pristine_from_cache() {
	local pristine installed_sha apk_list i apk
	load_cached_restore_context || return 2

	# If Android replaced/uninstalled the exact install instance we modified,
	# there is no stale target left to restore. Never chase a stale path into a
	# different package instance.
	if [ ! -f "$C_LIBRARY" ]; then
		log_line "Cached modified install instance no longer exists; nothing remains to restore at $C_LIBRARY"
		return 0
	fi

	installed_sha=$(sha256_file "$C_LIBRARY")
	if [ "$installed_sha" = "$C_ORIGINAL_SHA256" ]; then
		log_line "Cached target library is already pristine and SHA-256 verified"
		return 0
	fi

	current_dev=$(stat -c %d "$C_LIBRARY" 2>/dev/null || true)
	current_inode=$(stat -c %i "$C_LIBRARY" 2>/dev/null || true)
	current_size=$(stat -c %s "$C_LIBRARY" 2>/dev/null || true)
	if [ "$current_dev" != "$C_LIBRARY_DEV" ] || [ "$current_inode" != "$C_LIBRARY_INODE" ] || [ "$current_size" != "$C_LIBRARY_SIZE" ]; then
		log_line "Cached target identity changed; refusing cached write and requiring filesystem/profile SHA discovery"
		return 2
	fi

	APK_LIBRARY=$C_APK_LIBRARY
	apk_list=""
	i=1
	while [ "$i" -le "$C_APK_COUNT" ]; do
		apk=$(context_value "apk_$i" 2>/dev/null || true)
		if is_safe_data_path "$apk" && [ -f "$apk" ]; then
			apk_list="$apk_list $apk"
		fi
		i=$((i + 1))
	done
	[ -n "$apk_list" ] || return 2

	pristine="/data/local/tmp/mho_mumu_cached_restore.$$.so"
	TEMP_FILES="$TEMP_FILES $pristine"
	extract_pristine_from_apk_list "$pristine" "$C_ORIGINAL_SHA256" "$apk_list" || return 2
	log_line "Cached pristine APK library verified: $PRISTINE_SHA"
	atomic_install_library "$pristine" "$C_LIBRARY" "$C_ORIGINAL_SHA256" || return 1
	log_line "Cached pristine restore completed atomically and SHA-256 verified"
	return 0
}

restore_pristine_from_filesystem() {
	local base root profile profile_package profile_id relative_library apk_library original_sha target pristine installed_sha apk_list found_target
	found_target=0
	# PackageManager is not available during KernelSU's post-fs-data uninstall.
	# Scan only directories whose package component belongs to our exact target.
	for base in /data/app/"$TARGET_PACKAGE"-*/base.apk /data/app/*/"$TARGET_PACKAGE"-*/base.apk; do
		[ -f "$base" ] || continue
		root=${base%/*}
		for profile in "$PROFILE_DIR"/*.json; do
			[ -f "$profile" ] || continue
			profile_package=$(json_string "$profile" package)
			[ "$profile_package" = "$TARGET_PACKAGE" ] || continue
			profile_id=$(json_string "$profile" profile_id)
			is_safe_id "$profile_id" || continue
			relative_library=$(json_string "$profile" library)
			apk_library=$(json_string "$profile" apk_library)
			original_sha=$(json_string "$profile" original_sha256 | tr 'A-F' 'a-f')
			case "$relative_library" in lib/*) ;; *) continue ;; esac
			case "$relative_library" in *..*) continue ;; esac
			case "$apk_library" in lib/*) ;; *) continue ;; esac
			case "$apk_library" in *..*) continue ;; esac
			is_sha256 "$original_sha" || continue
			target="$root/$relative_library"
			[ -f "$target" ] || continue
			found_target=1
			installed_sha=$(sha256_file "$target")
			if [ "$installed_sha" = "$original_sha" ]; then
				log_line "Filesystem fallback found an already-pristine target for profile $profile_id"
				return 0
			fi
			pristine="/data/local/tmp/mho_mumu_fs_restore.$$.so"
			TEMP_FILES="$TEMP_FILES $pristine"
			APK_LIBRARY=$apk_library
			apk_list=""
			for apk in "$root"/*.apk; do
				[ -f "$apk" ] && apk_list="$apk_list $apk"
			done
			extract_pristine_from_apk_list "$pristine" "$original_sha" "$apk_list" || continue
			log_line "Filesystem fallback matched profile $profile_id by pristine SHA-256"
			atomic_install_library "$pristine" "$target" "$original_sha" || return 1
			log_line "Filesystem fallback pristine restore completed and SHA-256 verified"
			return 0
		done
	done
	# 2 means there is no managed target to restore. 3 means a candidate was
	# found but no checksum-verified pristine APK entry could be recovered.
	[ "$found_target" -eq 0 ] && return 2
	return 3
}

# Encode an integer as IEEE-754 single precision (little endian).
# Integer targets through 240 are exactly representable and fit the current Analyzer MOVZ encoding.
integer_to_float_hex() {
	n=$1
	min=$2
	max=$3
	[ "$n" -ge "$min" ] 2>/dev/null && [ "$n" -le "$max" ] 2>/dev/null || return 1

	t=$n
	e=0
	while [ "$t" -ge 2 ]; do
		t=$((t / 2))
		e=$((e + 1))
	done

	shift=$((23 - e))
	scaled=$((n << shift))
	mantissa=$((scaled - (1 << 23)))
	bits=$((((e + 127) << 23) | mantissa))

	printf '%02x%02x%02x%02x\n' \
		$(( bits        & 0xff )) \
		$(((bits >> 8)  & 0xff )) \
		$(((bits >> 16) & 0xff )) \
		$(((bits >> 24) & 0xff ))
}

# MOVZ W8, #<upper 16 bits of float>, LSL #16.
integer_float_movz_w8_hex() {
	n=$1
	min=$2
	max=$3
	float_hex=$(integer_to_float_hex "$n" "$min" "$max") || return 1
	# Reconstruct the upper 16 bits from the little-endian float bytes.
	b2=${float_hex#????}; b2=${b2%??}
	b3=${float_hex#??????}
	imm16=$((0x$b3$b2))
	instruction=$((0x52a00008 | (imm16 << 5)))
	printf '%02x%02x%02x%02x\n' \
		$(( instruction        & 0xff )) \
		$(((instruction >> 8)  & 0xff )) \
		$(((instruction >> 16) & 0xff )) \
		$(((instruction >> 24) & 0xff ))
}

# MOVZ W8, #integer.
integer_mov_w8_hex() {
	n=$1
	min=$2
	max=$3
	[ "$n" -ge "$min" ] 2>/dev/null && [ "$n" -le "$max" ] 2>/dev/null || return 1
	instruction=$((0x52800008 | (n << 5)))
	printf '%02x%02x%02x%02x\n' \
		$(( instruction        & 0xff )) \
		$(((instruction >> 8)  & 0xff )) \
		$(((instruction >> 16) & 0xff )) \
		$(((instruction >> 24) & 0xff ))
}

percent_to_instruction_hex() {
	integer_float_movz_w8_hex "$1" 10 200
}

resolution_scale_from_hex() {
	wanted=$(printf '%s' "$1" | tr 'A-F' 'a-f')
	p=10
	while [ "$p" -le 200 ]; do
		candidate=$(percent_to_instruction_hex "$p") || return 1
		if [ "$candidate" = "$wanted" ]; then
			printf '%s\n' "$p"
			return 0
		fi
		p=$((p + 1))
	done
	return 1
}

fps_from_float_hex() {
	wanted=$(printf '%s' "$1" | tr 'A-F' 'a-f')
	p=$FPS_MIN
	while [ "$p" -le "$FPS_MAX" ]; do
		candidate=$(integer_to_float_hex "$p" "$FPS_MIN" "$FPS_MAX") || return 1
		if [ "$candidate" = "$wanted" ]; then
			printf '%s\n' "$p"
			return 0
		fi
		p=$((p + 1))
	done
	return 1
}

fps_from_float_movz_hex() {
	wanted=$(printf '%s' "$1" | tr 'A-F' 'a-f')
	p=$FPS_MIN
	while [ "$p" -le "$FPS_MAX" ]; do
		candidate=$(integer_float_movz_w8_hex "$p" "$FPS_MIN" "$FPS_MAX") || return 1
		if [ "$candidate" = "$wanted" ]; then
			printf '%s\n' "$p"
			return 0
		fi
		p=$((p + 1))
	done
	return 1
}

fps_from_mov_w8_hex() {
	wanted=$(printf '%s' "$1" | tr 'A-F' 'a-f')
	p=$FPS_MIN
	while [ "$p" -le "$FPS_MAX" ]; do
		candidate=$(integer_mov_w8_hex "$p" "$FPS_MIN" "$FPS_MAX") || return 1
		if [ "$candidate" = "$wanted" ]; then
			printf '%s\n' "$p"
			return 0
		fi
		p=$((p + 1))
	done
	return 1
}


# Resolve defaults without touching renderer.config, libhp15 or libUnreal.
# A still-existing cached install is usable before PackageManager starts.
advanced_defaults_profile() {
	local package_dump VERSION cached_root profile selected
	package_dump=$(/system/bin/dumpsys package "$TARGET_PACKAGE" 2>/dev/null || true)
	VERSION=$(printf '%s\n' "$package_dump" | sed -n 's/^[[:space:]]*versionName=\([^[:space:]]*\).*/\1/p' | head -n 1)
	if [ -z "$VERSION" ]; then
		case "$package_dump" in
			*"Unable to find package"*|*"Package [$TARGET_PACKAGE] was not found"*) return 1 ;;
		esac
		cached_root=$(context_value install_root 2>/dev/null || true)
		if [ "$(context_value package 2>/dev/null)" = "$TARGET_PACKAGE" ] \
			&& is_safe_data_path "$cached_root" && [ -d "$cached_root" ]; then
			VERSION=$(context_value version 2>/dev/null || true)
		fi
		# Unknown early-boot state: defer automatic compatibility changes until
		# we can distinguish an explicit false in the profile from a missing key.
		[ -n "$VERSION" ] || return 2
	fi
	selected=""
	for profile in "$PROFILE_DIR"/*.json; do
		[ -f "$profile" ] || continue
		[ "$(json_string "$profile" version)" = "$VERSION" ] || continue
		validate_profile_metadata "$profile" || continue
		[ -z "$selected" ] || return 1
		selected=$profile
	done
	[ -n "$selected" ] || return 1
	printf '%s\n' "$selected"
}

load_advanced_defaults() {
	local profile rc key upper value
	ADVANCED_DEFAULTS_RESOLVED=1
	if [ "$#" -gt 0 ]; then
		profile=$1
	else
		rc=0
		profile=$(advanced_defaults_profile) || rc=$?
		[ "$rc" -ne 2 ] || ADVANCED_DEFAULTS_RESOLVED=0
	fi
	for key in hp15 patch_1 patch_2 renderer hp15_watcher renderer_watcher; do
		value=1
		if [ -n "$profile" ]; then
			value=$(json_bool "$profile" "advanced_${key}_default_enabled" 2>/dev/null || printf '1\n')
		fi
		upper=$(printf '%s' "$key" | tr 'a-z' 'A-Z')
		eval "ADVANCED_${upper}_DEFAULT_ENABLED=$value"
	done
}

load_advanced_preferences_legacy() {
	local key upper preference value default_enabled
	for key in hp15 patch_1 patch_2 renderer hp15_watcher renderer_watcher; do
		upper=$(printf '%s' "$key" | tr 'a-z' 'A-Z')
		eval default_enabled='${ADVANCED_'"$upper"'_DEFAULT_ENABLED:-1}'
		case "$key" in
			*_watcher) preference="${key}_disabled" ;;
			*) preference="mandatory_${key}_disabled" ;;
		esac
		value=""
		[ ! -f "$PREF_FILE" ] || value=$(sed -n 's/^'"$preference"'=\([01]\)$/\1/p' "$PREF_FILE" | head -n 1)
		# Keep the negative legacy storage/CLI keys: upgrades preserve choices.
		[ -n "$value" ] || value=$((1 - default_enabled))
		upper=$(printf '%s' "$preference" | tr 'a-z' 'A-Z')
		eval "$upper=$value"
	done
}

print_advanced_defaults() {
	local key upper value
	for key in hp15 patch_1 patch_2 renderer hp15_watcher renderer_watcher; do
		upper=$(printf '%s' "$key" | tr 'a-z' 'A-Z')
		eval value='${ADVANCED_'"$upper"'_DEFAULT_ENABLED:-1}'
		printf 'advanced_%s_default_enabled=%s\n' "$key" "$value"
	done
}

load_preferences_legacy() {
	local controller_mode_enabled hide_uuid_enabled pixelflow_choice pixelflow_mode enabled scale fps_enabled fps_target gpm_device_level_enabled gpu_display_enabled graphic_api_display_enabled platform_display_enabled graphic_library_enabled graphic_library cross_platform_enabled cross_platform device_checks_forced mandatory_hp15_disabled mandatory_patch_1_disabled mandatory_patch_2_disabled mandatory_renderer_disabled hp15_watcher_disabled renderer_watcher_disabled
	load_advanced_defaults
	load_advanced_preferences
	ADVANCED_SETTINGS_LOADED=1
	PIXELFLOW_MODE=original
	PIXELFLOW_CHOICE=enabled
	RESOLUTION_ENABLED=0
	RESOLUTION_SCALE=100
	FPS_ENABLED=0
	FPS_TARGET=60
	GPM_DEVICE_LEVEL_ENABLED=1
	GPU_DISPLAY_ENABLED=0
	HIDE_UUID_ENABLED=0
	CONTROLLER_MODE_ENABLED=0
	GRAPHIC_API_DISPLAY_ENABLED=0
	PLATFORM_DISPLAY_ENABLED=0
	GRAPHIC_LIBRARY_ENABLED=0
	GRAPHIC_LIBRARY="opengl"
	CROSS_PLATFORM_ENABLED=0
	CROSS_PLATFORM="mobile"
	DEVICE_CHECKS_FORCED=0

	if [ -f "$PREF_FILE" ]; then
		pixelflow_mode=$(sed -n 's/^pixelflow_mode=//p' "$PREF_FILE" | head -n 1)
		case "$pixelflow_mode" in original|enabled|disabled) PIXELFLOW_MODE=$pixelflow_mode ;; esac
		pixelflow_choice=$(sed -n 's/^pixelflow_choice=//p' "$PREF_FILE" | head -n 1)
		case "$PIXELFLOW_MODE" in enabled|disabled) PIXELFLOW_CHOICE=$PIXELFLOW_MODE ;;
			*) case "$pixelflow_choice" in enabled|disabled) PIXELFLOW_CHOICE=$pixelflow_choice ;; esac ;;
		esac
		enabled=$(sed -n 's/^resolution_enabled=\([01]\)$/\1/p' "$PREF_FILE" | head -n 1)
		scale=$(sed -n 's/^resolution_scale=\([0-9][0-9]*\)$/\1/p' "$PREF_FILE" | head -n 1)
		fps_enabled=$(sed -n 's/^fps_enabled=\([01]\)$/\1/p' "$PREF_FILE" | head -n 1)
		fps_target=$(sed -n 's/^fps_target=\([0-9][0-9]*\)$/\1/p' "$PREF_FILE" | head -n 1)
		gpm_device_level_enabled=$(sed -n 's/^gpm_device_level_enabled=\([01]\)$/\1/p' "$PREF_FILE" | head -n 1)
		gpu_display_enabled=$(sed -n 's/^gpu_display_enabled=\([01]\)$/\1/p' "$PREF_FILE" | head -n 1)
		hide_uuid_enabled=$(sed -n 's/^hide_uuid_enabled=\([01]\)$/\1/p' "$PREF_FILE" | head -n 1)
		controller_mode_enabled=$(sed -n 's/^controller_mode_enabled=\([01]\)$/\1/p' "$PREF_FILE" | head -n 1)
		graphic_api_display_enabled=$(sed -n 's/^graphic_api_display_enabled=\([01]\)$/\1/p' "$PREF_FILE" | head -n 1)
		platform_display_enabled=$(sed -n 's/^platform_display_enabled=\([01]\)$/\1/p' "$PREF_FILE" | head -n 1)
		graphic_library_enabled=$(sed -n 's/^graphic_library_enabled=\([01]\)$/\1/p' "$PREF_FILE" | head -n 1)
		graphic_library=$(sed -n 's/^graphic_library=//p' "$PREF_FILE" | head -n 1)
		case "$graphic_library" in opengl|vulkan) ;; *) graphic_library= ;; esac
		cross_platform_enabled=$(sed -n 's/^cross_platform_enabled=\([01]\)$/\1/p' "$PREF_FILE" | head -n 1)
		cross_platform=$(sed -n 's/^cross_platform=//p' "$PREF_FILE" | head -n 1)
		case "$cross_platform" in pc|mobile|console) ;; *) cross_platform= ;; esac
		device_checks_forced=$(sed -n 's/^device_checks_forced=\([01]\)$/\1/p' "$PREF_FILE" | head -n 1)
		[ -n "$enabled" ] && RESOLUTION_ENABLED=$enabled
		[ -n "$fps_enabled" ] && FPS_ENABLED=$fps_enabled
		[ -n "$gpm_device_level_enabled" ] && GPM_DEVICE_LEVEL_ENABLED=$gpm_device_level_enabled
		[ -n "$gpu_display_enabled" ] && GPU_DISPLAY_ENABLED=$gpu_display_enabled
		[ -n "$hide_uuid_enabled" ] && HIDE_UUID_ENABLED=$hide_uuid_enabled
		[ -n "$controller_mode_enabled" ] && CONTROLLER_MODE_ENABLED=$controller_mode_enabled
		[ -n "$graphic_api_display_enabled" ] && GRAPHIC_API_DISPLAY_ENABLED=$graphic_api_display_enabled
		[ -n "$platform_display_enabled" ] && PLATFORM_DISPLAY_ENABLED=$platform_display_enabled
		[ -n "$graphic_library_enabled" ] && GRAPHIC_LIBRARY_ENABLED=$graphic_library_enabled
		[ -n "$graphic_library" ] && GRAPHIC_LIBRARY=$graphic_library
		[ -n "$cross_platform_enabled" ] && CROSS_PLATFORM_ENABLED=$cross_platform_enabled
		[ -n "$cross_platform" ] && CROSS_PLATFORM=$cross_platform
		[ -n "$device_checks_forced" ] && DEVICE_CHECKS_FORCED=$device_checks_forced
		if [ -n "$scale" ] && [ "$scale" -ge 10 ] 2>/dev/null && [ "$scale" -le 200 ] 2>/dev/null; then
			RESOLUTION_SCALE=$scale
		fi
		if [ -n "$fps_target" ] && [ "$fps_target" -ge "$FPS_MIN" ] 2>/dev/null && [ "$fps_target" -le "$FPS_MAX" ] 2>/dev/null; then
			FPS_TARGET=$fps_target
		fi
	fi
}


save_preferences_legacy() {
	local tmp enabled scale fps_enabled fps_target gpm_device_level_enabled gpu_display_enabled graphic_library_enabled graphic_library device_checks_forced mandatory_hp15_disabled mandatory_patch_1_disabled mandatory_patch_2_disabled mandatory_renderer_disabled graphic_api_display_enabled cross_platform_enabled cross_platform hp15_watcher_disabled renderer_watcher_disabled platform_display_enabled pixelflow_mode pixelflow_choice hide_uuid_enabled controller_mode_enabled
	enabled=$1
	scale=$2
	fps_enabled=$3
	fps_target=$4
	gpm_device_level_enabled=$5
	gpu_display_enabled=$6
	graphic_library_enabled=$7
	graphic_library=$8
	device_checks_forced=$9
	mandatory_hp15_disabled=${10}
	mandatory_patch_1_disabled=${11}
	mandatory_patch_2_disabled=${12}
	mandatory_renderer_disabled=${13}
	graphic_api_display_enabled=${14}
	cross_platform_enabled=${15}
	cross_platform=${16}
	hp15_watcher_disabled=${17}
	renderer_watcher_disabled=${18}
	platform_display_enabled=${19}
	pixelflow_mode=${20:-original}
	pixelflow_choice=${21:-enabled}
	hide_uuid_enabled=${22:-${HIDE_UUID_ENABLED:-0}}
	controller_mode_enabled=${23:-${CONTROLLER_MODE_ENABLED:-0}}
	case "$pixelflow_mode" in enabled|disabled) pixelflow_choice=$pixelflow_mode ;; esac
	[ "$enabled" = "0" ] || [ "$enabled" = "1" ] || return 1
	[ "$scale" -ge 10 ] 2>/dev/null && [ "$scale" -le 200 ] 2>/dev/null || return 1
	[ "$fps_enabled" = "0" ] || [ "$fps_enabled" = "1" ] || return 1
	[ "$fps_target" -ge "$FPS_MIN" ] 2>/dev/null && [ "$fps_target" -le "$FPS_MAX" ] 2>/dev/null || return 1
	[ "$gpm_device_level_enabled" = "0" ] || [ "$gpm_device_level_enabled" = "1" ] || return 1
	[ "$gpu_display_enabled" = "0" ] || [ "$gpu_display_enabled" = "1" ] || return 1
	[ "$hide_uuid_enabled" = "0" ] || [ "$hide_uuid_enabled" = "1" ] || return 1
	[ "$controller_mode_enabled" = "0" ] || [ "$controller_mode_enabled" = "1" ] || return 1
	[ "$graphic_library_enabled" = "0" ] || [ "$graphic_library_enabled" = "1" ] || return 1
	case "$graphic_library" in opengl|vulkan) ;; *) return 1 ;; esac
	[ "$device_checks_forced" = "0" ] || [ "$device_checks_forced" = "1" ] || return 1
	[ "$mandatory_hp15_disabled" = "0" ] || [ "$mandatory_hp15_disabled" = "1" ] || return 1
	[ "$mandatory_patch_1_disabled" = "0" ] || [ "$mandatory_patch_1_disabled" = "1" ] || return 1
	[ "$mandatory_patch_2_disabled" = "0" ] || [ "$mandatory_patch_2_disabled" = "1" ] || return 1
	[ "$mandatory_renderer_disabled" = "0" ] || [ "$mandatory_renderer_disabled" = "1" ] || return 1
	[ "$graphic_api_display_enabled" = "0" ] || [ "$graphic_api_display_enabled" = "1" ] || return 1
	[ "$cross_platform_enabled" = "0" ] || [ "$cross_platform_enabled" = "1" ] || return 1
	case "$cross_platform" in pc|mobile|console) ;; *) return 1 ;; esac
	[ "$hp15_watcher_disabled" = "0" ] || [ "$hp15_watcher_disabled" = "1" ] || return 1
	[ "$renderer_watcher_disabled" = "0" ] || [ "$renderer_watcher_disabled" = "1" ] || return 1
	[ "$platform_display_enabled" = "0" ] || [ "$platform_display_enabled" = "1" ] || return 1
	case "$pixelflow_mode" in original|enabled|disabled) ;; *) return 1 ;; esac
	case "$pixelflow_choice" in enabled|disabled) ;; *) return 1 ;; esac

	tmp="$STATE_DIR/.preferences.$$.tmp"
	TEMP_FILES="$TEMP_FILES $tmp"
	{
		printf 'resolution_enabled=%s\n' "$enabled"
		printf 'resolution_scale=%s\n' "$scale"
		printf 'fps_enabled=%s\n' "$fps_enabled"
		printf 'fps_target=%s\n' "$fps_target"
		printf 'gpm_device_level_enabled=%s\n' "$gpm_device_level_enabled"
		printf 'gpu_display_enabled=%s\n' "$gpu_display_enabled"
		printf 'hide_uuid_enabled=%s\n' "$hide_uuid_enabled"
		printf 'controller_mode_enabled=%s\n' "$controller_mode_enabled"
		printf 'graphic_api_display_enabled=%s\n' "$graphic_api_display_enabled"
		printf 'graphic_library_enabled=%s\n' "$graphic_library_enabled"
		printf 'graphic_library=%s\n' "$graphic_library"
		printf 'cross_platform_enabled=%s\n' "$cross_platform_enabled"
		printf 'cross_platform=%s\n' "$cross_platform"
		printf 'device_checks_forced=%s\n' "$device_checks_forced"
		printf 'mandatory_hp15_disabled=%s\n' "$mandatory_hp15_disabled"
		printf 'mandatory_patch_1_disabled=%s\n' "$mandatory_patch_1_disabled"
		printf 'mandatory_patch_2_disabled=%s\n' "$mandatory_patch_2_disabled"
		printf 'mandatory_renderer_disabled=%s\n' "$mandatory_renderer_disabled"
		printf 'hp15_watcher_disabled=%s\n' "$hp15_watcher_disabled"
		printf 'renderer_watcher_disabled=%s\n' "$renderer_watcher_disabled"
		printf 'platform_display_enabled=%s\n' "$platform_display_enabled"
		printf 'pixelflow_mode=%s\n' "$pixelflow_mode"
		printf 'pixelflow_choice=%s\n' "$pixelflow_choice"
	} > "$tmp" || return 1
	chmod 0600 "$tmp" 2>/dev/null || true
	mv -f "$tmp" "$PREF_FILE" || return 1
	chmod 0600 "$PREF_FILE" 2>/dev/null || true
	RESOLUTION_ENABLED=$enabled
	RESOLUTION_SCALE=$scale
	FPS_ENABLED=$fps_enabled
	FPS_TARGET=$fps_target
	GPM_DEVICE_LEVEL_ENABLED=$gpm_device_level_enabled
	GPU_DISPLAY_ENABLED=$gpu_display_enabled
	HIDE_UUID_ENABLED=$hide_uuid_enabled
	CONTROLLER_MODE_ENABLED=$controller_mode_enabled
	GRAPHIC_API_DISPLAY_ENABLED=$graphic_api_display_enabled
	GRAPHIC_LIBRARY_ENABLED=$graphic_library_enabled
	GRAPHIC_LIBRARY=$graphic_library
	CROSS_PLATFORM_ENABLED=$cross_platform_enabled
	CROSS_PLATFORM=$cross_platform
	DEVICE_CHECKS_FORCED=$device_checks_forced
	MANDATORY_HP15_DISABLED=$mandatory_hp15_disabled
	MANDATORY_PATCH_1_DISABLED=$mandatory_patch_1_disabled
	MANDATORY_PATCH_2_DISABLED=$mandatory_patch_2_disabled
	MANDATORY_RENDERER_DISABLED=$mandatory_renderer_disabled
	HP15_WATCHER_DISABLED=$hp15_watcher_disabled
	RENDERER_WATCHER_DISABLED=$renderer_watcher_disabled
	PLATFORM_DISPLAY_ENABLED=$platform_display_enabled
	PIXELFLOW_MODE=$pixelflow_mode
	PIXELFLOW_CHOICE=$pixelflow_choice
	return 0
}


detect_environment() {
	local wait_for_pm pm_attempt
	wait_for_pm=${1:-0}
	pm_attempt=0
	APK_PATHS=""

	while :; do
		APK_PATHS=$(/system/bin/pm path "$TARGET_PACKAGE" 2>/dev/null | sed -n 's/^package://p')
		[ -n "$APK_PATHS" ] && break
		[ "$wait_for_pm" -eq 1 ] || return 1
		[ "$pm_attempt" -lt 59 ] || return 1
		pm_attempt=$((pm_attempt + 1))
		sleep 2
	done

	BASE_APK=$(printf '%s\n' "$APK_PATHS" | grep '/base.apk$' | head -n 1)
	[ -n "$BASE_APK" ] || BASE_APK=$(printf '%s\n' "$APK_PATHS" | head -n 1)
	[ -n "$BASE_APK" ] || return 1

	INSTALL_ROOT=${BASE_APK%/*}
	PACKAGE_DUMP=$(/system/bin/dumpsys package "$TARGET_PACKAGE" 2>/dev/null)
	VERSION=$(printf '%s\n' "$PACKAGE_DUMP" \
		| sed -n 's/^[[:space:]]*versionName=//p' | head -n 1 | tr -d '\r')
	[ -n "$VERSION" ] || VERSION="unknown"
	return 0
}

hp15_created_marker_valid() {
	[ -f "$HP15_CREATED_MARKER" ] && [ ! -L "$HP15_CREATED_MARKER" ] || return 1
	[ "$(stat -c %s "$HP15_CREATED_MARKER" 2>/dev/null || printf '1\n')" = "0" ]
}

hp15_sha_is_known_module_payload() {
	local candidate known
	candidate=$(printf '%s' "$1" | tr 'A-F' 'a-f')
	is_sha256 "$candidate" || return 1
	for known in $HP15_KNOWN_PAYLOAD_SHA256S; do
		[ "$candidate" = "$known" ] && return 0
	done
	return 1
}

ensure_hp15_created_marker() {
	local tmp
	if hp15_created_marker_valid; then
		return 0
	fi
	if [ -e "$HP15_CREATED_MARKER" ] || [ -L "$HP15_CREATED_MARKER" ]; then
		log_line "createdbymodule exists but is not a safe empty marker; ownership was not changed"
		return 1
	fi
	ensure_hp15_data_dir || return 1
	tmp="$HP15_DATA_DIR/.createdbymodule.$$.tmp"
	TEMP_FILES="$TEMP_FILES $tmp"
	rm -f -- "$tmp" 2>/dev/null || true
	: > "$tmp" || return 1
	chmod 0644 "$tmp" 2>/dev/null || return 1
	chown 0:0 "$tmp" 2>/dev/null || true
	/system/bin/restorecon "$tmp" 2>/dev/null || true
	[ "$(stat -c %s "$tmp" 2>/dev/null || printf '1\n')" = "0" ] || return 1
	sync
	mv -f "$tmp" "$HP15_CREATED_MARKER" || return 1
	/system/bin/restorecon "$HP15_CREATED_MARKER" 2>/dev/null || true
	sync
	hp15_created_marker_valid
}

clear_hp15_created_marker() {
	if hp15_created_marker_valid; then
		rm -f -- "$HP15_CREATED_MARKER" 2>/dev/null || return 1
		sync
	fi
	return 0
}

hp15_state_value() {
	local key
	key=$1
	[ -f "$HP15_STATE_FILE" ] && [ ! -L "$HP15_STATE_FILE" ] || return 1
	sed -n 's/^'"$key"'=//p' "$HP15_STATE_FILE" | head -n 1
}

hp15_payload_valid() {
	[ -f "$HP15_PAYLOAD" ] && [ ! -L "$HP15_PAYLOAD" ] || return 1
	[ "$(sha256_file "$HP15_PAYLOAD")" = "$HP15_PAYLOAD_SHA256" ]
}

cleanup_legacy_hp15_staging() {
	# Version 1.2.0.2 left a temporary staging file here. It is stale after the
	# required reboot and is never used by the physical-override design.
	rm -f -- /data/local/tmp/mho_mumu_patcher_libhp15_x86_64.so 2>/dev/null || true
}

load_hp15_marker() {
	[ -f "$HP15_STATE_FILE" ] && [ ! -L "$HP15_STATE_FILE" ] || return 1
	H_MARKER_SCHEMA=$(hp15_state_value schema 2>/dev/null || true)
	H_MARKER_TARGET=$(hp15_state_value target 2>/dev/null || true)
	H_MARKER_BACKUP=$(hp15_state_value backup 2>/dev/null || true)
	H_MARKER_SOURCE=$(hp15_state_value source 2>/dev/null || true)
	H_MARKER_CREATED=$(hp15_state_value created 2>/dev/null || true)
	H_MARKER_ORIGINAL_SHA=$(hp15_state_value original_sha256 2>/dev/null | tr 'A-F' 'a-f' || true)
	H_MARKER_APPLIED_SHA=$(hp15_state_value applied_sha256 2>/dev/null | tr 'A-F' 'a-f' || true)
	H_MARKER_MODE=$(hp15_state_value original_mode 2>/dev/null || true)
	H_MARKER_UID=$(hp15_state_value original_uid 2>/dev/null || true)
	H_MARKER_GID=$(hp15_state_value original_gid 2>/dev/null || true)

	[ "$H_MARKER_SCHEMA" = "3" ] || return 1
	[ "$H_MARKER_TARGET" = "$HP15_DATA_LIBRARY" ] || return 1
	[ "$H_MARKER_BACKUP" = "$HP15_BACKUP_FILE" ] || return 1
	case "$H_MARKER_SOURCE" in system|data) ;; *) return 1 ;; esac
	[ "$H_MARKER_CREATED" = "0" ] || [ "$H_MARKER_CREATED" = "1" ] || return 1
	case "$H_MARKER_SOURCE:$H_MARKER_CREATED" in
		system:1|data:0) ;;
		*) return 1 ;;
	esac
	is_sha256 "$H_MARKER_ORIGINAL_SHA" || return 1
	[ "$H_MARKER_APPLIED_SHA" = "$HP15_PAYLOAD_SHA256" ] || return 1
	case "$H_MARKER_MODE" in ""|*[!0-9]*) return 1 ;; esac
	case "$H_MARKER_UID" in ""|*[!0-9]*) return 1 ;; esac
	case "$H_MARKER_GID" in ""|*[!0-9]*) return 1 ;; esac
	return 0
}

write_hp15_marker() {
	local source created original_sha mode uid gid tmp
	source=$1
	created=$2
	original_sha=$3
	mode=$4
	uid=$5
	gid=$6
	tmp="$STATE_DIR/.hp15_override.$$.tmp"
	TEMP_FILES="$TEMP_FILES $tmp"
	{
		printf 'schema=3\n'
		printf 'target=%s\n' "$HP15_DATA_LIBRARY"
		printf 'backup=%s\n' "$HP15_BACKUP_FILE"
		printf 'source=%s\n' "$source"
		printf 'created=%s\n' "$created"
		printf 'original_sha256=%s\n' "$original_sha"
		printf 'applied_sha256=%s\n' "$HP15_PAYLOAD_SHA256"
		printf 'original_mode=%s\n' "$mode"
		printf 'original_uid=%s\n' "$uid"
		printf 'original_gid=%s\n' "$gid"
	} > "$tmp" || return 1
	chmod 0600 "$tmp" 2>/dev/null || true
	mv -f "$tmp" "$HP15_STATE_FILE" || return 1
	chmod 0600 "$HP15_STATE_FILE" 2>/dev/null || true
	return 0
}

clear_hp15_marker() {
	rm -f -- "$HP15_STATE_FILE" 2>/dev/null || true
}

clear_hp15_tracking() {
	clear_hp15_marker
	rm -f -- "$HP15_BACKUP_FILE" 2>/dev/null || true
	clear_hp15_created_marker || true
	cleanup_legacy_hp15_staging
}

hp15_backup_is_regular() {
	[ -f "$HP15_BACKUP_FILE" ] && [ ! -L "$HP15_BACKUP_FILE" ]
}

hp15_tracking_valid() {
	local backup_sha
	load_hp15_marker || return 1
	hp15_backup_is_regular || return 1
	backup_sha=$(sha256_file "$HP15_BACKUP_FILE")
	[ "$backup_sha" = "$H_MARKER_ORIGINAL_SHA" ]
}

hp15_atomic_copy_legacy() {
	local source target expected_sha mode uid gid label target_dir tmp actual_sha
	source=$1
	target=$2
	expected_sha=$(printf '%s' "$3" | tr 'A-F' 'a-f')
	mode=$4
	uid=$5
	gid=$6
	label=$7
	[ -f "$source" ] && [ ! -L "$source" ] || return 1
	is_sha256 "$expected_sha" || return 1
	[ "$(sha256_file "$source")" = "$expected_sha" ] || return 1
	case "$mode" in ""|*[!0-9]*) return 1 ;; esac
	case "$uid" in ""|*[!0-9]*) return 1 ;; esac
	case "$gid" in ""|*[!0-9]*) return 1 ;; esac
	case "$label" in ""|*[!A-Za-z0-9_-]*) return 1 ;; esac

	target_dir=${target%/*}
	[ -d "$target_dir" ] && [ ! -L "$target_dir" ] || return 1
	tmp="$target_dir/.mho_hp15_${label}.$$.tmp"
	TEMP_FILES="$TEMP_FILES $tmp"
	rm -f -- "$tmp" 2>/dev/null || true
	cp -p "$source" "$tmp" 2>/dev/null || return 1
	chmod "$mode" "$tmp" 2>/dev/null || return 1
	chown "$uid:$gid" "$tmp" 2>/dev/null || return 1
	/system/bin/chcon u:object_r:system_file:s0 "$tmp" 2>/dev/null \
		|| /system/bin/restorecon "$tmp" 2>/dev/null || true
	actual_sha=$(sha256_file "$tmp")
	[ "$actual_sha" = "$expected_sha" ] || return 1
	sync
	if [ "$label" = payload ]; then
		[ ! -f "$MODDIR/disable" ] && [ ! -f "$MODDIR/remove" ] || return 1
	fi
	mv -f "$tmp" "$target" || return 1
	/system/bin/chcon u:object_r:system_file:s0 "$target" 2>/dev/null \
		|| /system/bin/restorecon "$target" 2>/dev/null || true
	sync
	[ "$(sha256_file "$target")" = "$expected_sha" ]
}

ensure_hp15_data_dir() {
	local dir
	[ -d "$HP15_DATA_SYSTEM_DIR" ] && [ ! -L "$HP15_DATA_SYSTEM_DIR" ] || return 1
	for dir in "$HP15_DATA_ETC_DIR" "$HP15_DATA_CONFIG_DIR" "$HP15_DATA_DIR"; do
		if [ -L "$dir" ] || { [ -e "$dir" ] && [ ! -d "$dir" ]; }; then
			return 1
		fi
		if [ ! -d "$dir" ]; then
			mkdir "$dir" 2>/dev/null || return 1
			chmod 0755 "$dir" 2>/dev/null || true
			chown 1000:1000 "$dir" 2>/dev/null || true
			/system/bin/restorecon "$dir" 2>/dev/null || true
		fi
	done
	return 0
}

detect_mumu_environment() {
	local nemu_vulkan
	nemu_vulkan=$(/system/bin/getprop nemud.vulkan_version 2>/dev/null || true)
	[ -n "$nemu_vulkan" ] && return 0
	/system/bin/getprop 2>/dev/null | grep -q '^\[nemu' && return 0
	return 1
}

inspect_mumu_policy_only() {
	MUMU_DETECTED=0
	DEVICE_CHECKS_REQUIRED=0
	HP15_EFFECTIVE_PATH="$HP15_DATA_LIBRARY"
	HP15_SOURCE="not_checked"
	HP15_STATE="not_checked"
	HP15_OVERRIDE_REQUIRED=0
	HP15_OVERRIDE_ACTIVE=0
	HP15_MTIME_EPOCH=""
	HP15_MODIFY="Not checked"
	detect_mumu_environment || return 0
	MUMU_DETECTED=1
	DEVICE_CHECKS_REQUIRED=1
	return 0
}

inspect_hp15() {
	local effective_sha
	MUMU_DETECTED=0
	DEVICE_CHECKS_REQUIRED=0
	HP15_EFFECTIVE_PATH="$HP15_DATA_LIBRARY"
	HP15_SOURCE="unavailable"
	HP15_STATE="not_present"
	HP15_OVERRIDE_REQUIRED=0
	HP15_OVERRIDE_ACTIVE=0
	HP15_MTIME_EPOCH=""
	HP15_MODIFY="Unavailable"

	# MuMu detection is property-based. libhp15 handling is deliberately limited
	# to the writable /data override; /system/etc is never inspected for this .so.
	detect_mumu_environment || return 0
	MUMU_DETECTED=1
	DEVICE_CHECKS_REQUIRED=1
	HP15_SOURCE="fallback"

	if [ -L "$HP15_DATA_LIBRARY" ] || { [ -e "$HP15_DATA_LIBRARY" ] && [ ! -f "$HP15_DATA_LIBRARY" ]; }; then
		HP15_SOURCE="data"
		HP15_STATE="invalid_payload"
		HP15_OVERRIDE_REQUIRED=1
		return 0
	fi

	if [ ! -f "$HP15_DATA_LIBRARY" ]; then
		HP15_OVERRIDE_REQUIRED=1
		if [ "${MANDATORY_HP15_DISABLED:-0}" = "1" ]; then
			HP15_STATE="not_present"
		elif hp15_payload_valid; then
			HP15_STATE="needs_override"
		else
			HP15_STATE="invalid_payload"
		fi
		return 0
	fi

	HP15_SOURCE="data"
	HP15_MTIME_EPOCH=$(stat -c %Y "$HP15_DATA_LIBRARY" 2>/dev/null || true)
	HP15_MODIFY=$(stat -c %y "$HP15_DATA_LIBRARY" 2>/dev/null | cut -c 1-19)
	[ -n "$HP15_MODIFY" ] || HP15_MODIFY="Unavailable"
	effective_sha=$(sha256_file "$HP15_DATA_LIBRARY")

	if [ "$effective_sha" = "$HP15_PAYLOAD_SHA256" ]; then
		HP15_SOURCE="override"
		HP15_STATE="override"
		HP15_OVERRIDE_ACTIVE=1
		return 0
	fi

	if hp15_created_marker_valid && ! hp15_backup_is_regular \
		&& hp15_sha_is_known_module_payload "$effective_sha"; then
		# Ownership proof is marker + known module payload SHA. This supports a
		# future payload update without turning an older module payload into .old.
		HP15_SOURCE="override"
		HP15_OVERRIDE_REQUIRED=1
		HP15_STATE="needs_override"
		return 0
	fi

	case "$HP15_MTIME_EPOCH" in
		""|*[!0-9]*) HP15_OVERRIDE_REQUIRED=1 ;;
		*) [ "$HP15_MTIME_EPOCH" -ge "$HP15_BAD_CUTOFF_EPOCH" ] 2>/dev/null && HP15_OVERRIDE_REQUIRED=1 ;;
	esac

	if [ "$HP15_OVERRIDE_REQUIRED" -eq 1 ]; then
		if [ "${MANDATORY_HP15_DISABLED:-0}" = "1" ]; then
			HP15_STATE="needs_override"
		elif hp15_payload_valid; then
			HP15_STATE="needs_override"
		else
			HP15_STATE="invalid_payload"
		fi
	else
		HP15_STATE="compatible"
	fi
	return 0
}

apply_hp15_physical_override() {
	local source_sha source_identity mode uid gid rc module_created
	inspect_hp15
	[ "$MUMU_DETECTED" -eq 1 ] || return 0
	[ "$HP15_STATE" = "needs_override" ] || return 0
	hp15_payload_valid || { log_line "MuMu libhp15 payload failed SHA-256 verification"; return 1; }

	if [ ! -e "$HP15_DATA_LIBRARY" ] && hp15_backup_is_regular; then
		restore_hp15_override || return 1
		inspect_hp15
		[ "$HP15_STATE" = "needs_override" ] || return 0
	fi

	ensure_hp15_data_dir || return 1
	if [ -e "$HP15_CREATED_MARKER" ] || [ -L "$HP15_CREATED_MARKER" ]; then
		hp15_created_marker_valid || { log_line "createdbymodule is unsafe or malformed; libhp15 publication was refused"; return 1; }
	fi
	module_created=0
	if [ -f "$HP15_DATA_LIBRARY" ] && [ ! -L "$HP15_DATA_LIBRARY" ]; then
		source_sha=$(sha256_file "$HP15_DATA_LIBRARY")
		if hp15_created_marker_valid && ! hp15_backup_is_regular \
			&& hp15_sha_is_known_module_payload "$source_sha"; then
			# This writable override is still one of the module's known payloads.
			# Never turn an older module payload into .old when a future payload changes.
			module_created=1
			mode=$(stat -c %a "$HP15_DATA_LIBRARY" 2>/dev/null || printf '644\n')
			uid=$(stat -c %u "$HP15_DATA_LIBRARY" 2>/dev/null || printf '0\n')
			gid=$(stat -c %g "$HP15_DATA_LIBRARY" 2>/dev/null || printf '0\n')
		else
			if hp15_created_marker_valid && ! hp15_backup_is_regular; then
				# MuMu or another actor replaced a module-created override. The empty
				# marker is now stale and must not claim ownership of this new file.
				clear_hp15_created_marker || return 1
				log_line "MuMu replaced the module-created libhp15; stale createdbymodule ownership was cleared"
			fi
			# No createdbymodule ownership proof: this is a writable library that
			# existed independently of the module. Refresh .old from the exact
			# current file before applying the payload, preserving prior behavior
			# if MuMu replaced the writable library while the module was active.
			source_identity=$(stat -c '%d:%i' "$HP15_DATA_LIBRARY" 2>/dev/null || true)
			mode=$(stat -c %a "$HP15_DATA_LIBRARY" 2>/dev/null || true)
			uid=$(stat -c %u "$HP15_DATA_LIBRARY" 2>/dev/null || true)
			gid=$(stat -c %g "$HP15_DATA_LIBRARY" 2>/dev/null || true)
			is_sha256 "$source_sha" && [ -n "$source_identity" ] || return 1
			archive_hp15_generation || return 1
			clear_hp15_tracking
			hp15_atomic_copy "$HP15_DATA_LIBRARY" "$HP15_BACKUP_FILE" "$source_sha" "$mode" "$uid" "$gid" backup || return 1
			if [ "$(stat -c '%d:%i' "$HP15_DATA_LIBRARY" 2>/dev/null || true)" != "$source_identity" ] \
				|| [ "$(sha256_file "$HP15_DATA_LIBRARY")" != "$source_sha" ]; then
				clear_hp15_tracking
				log_line "Writable MuMu libhp15 changed while its .old backup was prepared"
				return 2
			fi
			write_hp15_marker data 0 "$source_sha" "$mode" "$uid" "$gid" || { clear_hp15_tracking; return 1; }
		fi
	else
		if [ -e "$HP15_DATA_LIBRARY" ] || [ -L "$HP15_DATA_LIBRARY" ]; then
			log_line "Physical libhp15 override target is unsafe; publication was refused"
			return 1
		fi
		if [ -e "$HP15_BACKUP_FILE" ] || [ -L "$HP15_BACKUP_FILE" ]; then
			log_line "libhp15_x86_64.so.old is stale or unsafe while no data library exists; publication was refused"
			return 1
		fi
		clear_hp15_marker
		ensure_hp15_created_marker || return 1
		module_created=1
		mode=$(stat -c %a "$HP15_PAYLOAD" 2>/dev/null || printf '644\n')
		uid=$(stat -c %u "$HP15_PAYLOAD" 2>/dev/null || printf '0\n')
		gid=$(stat -c %g "$HP15_PAYLOAD" 2>/dev/null || printf '0\n')
	fi

	hp15_atomic_copy "$HP15_PAYLOAD" "$HP15_DATA_LIBRARY" "$HP15_PAYLOAD_SHA256" "$mode" "$uid" "$gid" payload
	rc=$?
	if [ "$rc" -ne 0 ]; then
		log_line "Physical MuMu libhp15 override publication failed; restoring writable state"
		restore_hp15_override 2>/dev/null || true
		return 1
	fi
	if [ "$module_created" -eq 1 ]; then
		ensure_hp15_created_marker || { log_line "libhp15 payload was published but createdbymodule could not be verified"; restore_hp15_override 2>/dev/null || true; return 1; }
	fi
	inspect_hp15
	if [ "$HP15_STATE" != "override" ]; then
		log_line "Published physical libhp15 override failed final verification; restoring writable state"
		restore_hp15_override 2>/dev/null || true
		return 1
	fi
	log_line "Applied physical MuMu libhp15 override at $HP15_DATA_LIBRARY"
	return 0
}

reconcile_hp15_legacy() {
	local attempt rc raw_schema
	cleanup_legacy_hp15_staging
	if [ "${MANDATORY_HP15_DISABLED:-0}" = "1" ]; then
		inspect_hp15
		[ "$MUMU_DETECTED" -eq 1 ] || return 0
		restore_hp15_override || return 1
		inspect_hp15
		case "$HP15_STATE" in
			compatible|needs_override|not_present)
				log_line "Mandatory Effective libhp15 patch is force-disabled; no module payload is effective in /data"
				return 0 ;;
			*) log_line "Mandatory Effective libhp15 patch is force-disabled, but a safe writable state could not be restored"; return 1 ;;
		esac
	fi
	attempt=1
	while [ "$attempt" -le 3 ]; do
		inspect_hp15
		[ "$MUMU_DETECTED" -eq 1 ] || return 0
		case "$HP15_STATE" in
			override)
				if ! hp15_backup_is_regular && ! hp15_created_marker_valid; then
					if [ -e "$HP15_CREATED_MARKER" ] || [ -L "$HP15_CREATED_MARKER" ]; then
						log_line "createdbymodule exists but is not a safe empty marker; libhp15 ownership migration was refused"
						return 1
					fi
					ensure_hp15_created_marker || return 1
					log_line "Recorded createdbymodule ownership for the existing module libhp15 override"
				fi
				return 0 ;;
			compatible)
				raw_schema=$(hp15_state_value schema 2>/dev/null || true)
				if [ "$raw_schema" = "3" ] || hp15_backup_is_regular || hp15_created_marker_valid; then clear_hp15_tracking; log_line "MuMu replaced the physical libhp15 override with a compatible writable library; stale tracking and ownership were cleared"; fi
				return 0 ;;
			needs_override)
				apply_hp15_physical_override; rc=$?; [ "$rc" -eq 0 ] && return 0; [ "$rc" -eq 2 ] || return "$rc"; attempt=$((attempt + 1)) ;;
			*) log_line "MuMu libhp15 writable override or module payload is unsafe or unreadable; no replacement was attempted"; return 1 ;;
		esac
	done
	log_line "MuMu writable libhp15 kept changing during physical override preparation"
	return 1
}

restore_hp15_override_legacy() {
	local backup_sha mode uid gid current_sha marker_valid created_valid
	cleanup_legacy_hp15_staging
	marker_valid=0
	created_valid=0
	load_hp15_marker && marker_valid=1
	hp15_created_marker_valid && created_valid=1
	if hp15_backup_is_regular; then
		backup_sha=$(sha256_file "$HP15_BACKUP_FILE"); is_sha256 "$backup_sha" || return 1
		if [ "$marker_valid" -eq 1 ]; then
			[ "$backup_sha" = "$H_MARKER_ORIGINAL_SHA" ] || { log_line "libhp15_x86_64.so.old failed tracked SHA-256 verification"; return 1; }
			mode=$H_MARKER_MODE; uid=$H_MARKER_UID; gid=$H_MARKER_GID
		else
			mode=$(stat -c %a "$HP15_BACKUP_FILE" 2>/dev/null || true); uid=$(stat -c %u "$HP15_BACKUP_FILE" 2>/dev/null || true); gid=$(stat -c %g "$HP15_BACKUP_FILE" 2>/dev/null || true)
		fi
		ensure_hp15_data_dir || return 1
		hp15_atomic_copy "$HP15_BACKUP_FILE" "$HP15_DATA_LIBRARY" "$backup_sha" "$mode" "$uid" "$gid" restore || return 1
		log_line "Restored the original writable libhp15 from libhp15_x86_64.so.old"
		clear_hp15_tracking
		return 0
	fi
	if [ -e "$HP15_BACKUP_FILE" ] || [ -L "$HP15_BACKUP_FILE" ]; then log_line "libhp15_x86_64.so.old is unsafe or unreadable; restoration was refused"; return 1; fi
	if [ -L "$HP15_DATA_LIBRARY" ] || { [ -e "$HP15_DATA_LIBRARY" ] && [ ! -f "$HP15_DATA_LIBRARY" ]; }; then log_line "Writable libhp15 target is unsafe; removal was refused"; return 1; fi

	if [ "$created_valid" -eq 1 ]; then
		# createdbymodule proves only that the module once created the writable
		# override. The current .so is removable only while its SHA is a known
		# module payload; MuMu may have replaced it after the marker was created.
		if [ -f "$HP15_DATA_LIBRARY" ]; then
			current_sha=$(sha256_file "$HP15_DATA_LIBRARY")
			if hp15_sha_is_known_module_payload "$current_sha"; then
				rm -f -- "$HP15_DATA_LIBRARY" 2>/dev/null || return 1
				sync
				[ ! -e "$HP15_DATA_LIBRARY" ] && [ ! -L "$HP15_DATA_LIBRARY" ] || return 1
				log_line "Removed the module-created libhp15 data override using createdbymodule plus known payload SHA"
			else
				log_line "createdbymodule is stale because the writable libhp15 no longer matches a known module payload; the external file was preserved"
			fi
		fi
		clear_hp15_marker
		clear_hp15_created_marker || return 1
		rmdir "$HP15_DATA_DIR" 2>/dev/null || true
		rmdir "${HP15_DATA_DIR%/*}" 2>/dev/null || true
		return 0
	fi
	if [ -e "$HP15_CREATED_MARKER" ] || [ -L "$HP15_CREATED_MARKER" ]; then
		log_line "createdbymodule is unsafe or malformed; libhp15 removal was refused"
		return 1
	fi

	# Migration fallback for 1.2.3 installations created before createdbymodule:
	# only the exact known payload may be removed when no .old/ownership marker exists.
	if [ -f "$HP15_DATA_LIBRARY" ]; then
		current_sha=$(sha256_file "$HP15_DATA_LIBRARY")
		if [ "$current_sha" = "$HP15_PAYLOAD_SHA256" ]; then
			rm -f -- "$HP15_DATA_LIBRARY" 2>/dev/null || return 1; sync
			[ ! -e "$HP15_DATA_LIBRARY" ] && [ ! -L "$HP15_DATA_LIBRARY" ] || return 1
			log_line "Removed the legacy module libhp15 data override; fallback resolution is left to the OS"
		fi
	fi
	clear_hp15_marker
	rmdir "$HP15_DATA_DIR" 2>/dev/null || true
	rmdir "${HP15_DATA_DIR%/*}" 2>/dev/null || true
	return 0
}

reconcile_mumu_compatibility() {
	local hp15_rc renderer_rc
	hp15_rc=0
	renderer_rc=0
	reconcile_hp15 || hp15_rc=$?
	reconcile_renderer_config || renderer_rc=$?
	[ "$hp15_rc" -eq 0 ] || log_line "MuMu libhp15 compatibility reconciliation failed"
	[ "$renderer_rc" -eq 0 ] || log_line "MuMu renderer compatibility reconciliation failed"
	[ "$hp15_rc" -eq 0 ] && [ "$renderer_rc" -eq 0 ]
}

reconcile_mumu_compatibility_automatic() {
	local hp15_rc renderer_rc
	[ "${ADVANCED_DEFAULTS_RESOLVED:-1}" = "1" ] || return 0
	hp15_rc=0
	renderer_rc=0
	if [ "${HP15_WATCHER_DISABLED:-0}" = "1" ]; then
		log_line "MuMu libhp15 watcher disabled; automatic reconciliation skipped"
	else
		reconcile_hp15 || hp15_rc=$?
	fi
	if [ "${RENDERER_WATCHER_DISABLED:-0}" = "1" ]; then
		log_line "MuMu Shader Compatibility watcher disabled; automatic reconciliation skipped"
	else
		reconcile_renderer_config || renderer_rc=$?
	fi
	[ "$hp15_rc" -eq 0 ] || log_line "Automatic MuMu libhp15 reconciliation failed"
	[ "$renderer_rc" -eq 0 ] || log_line "Automatic MuMu renderer reconciliation failed"
	[ "$hp15_rc" -eq 0 ] && [ "$renderer_rc" -eq 0 ]
}


mandatory_should_patch() {
	# MuMu always needs these patches. Outside MuMu they remain opt-in through
	# the saved Force checkbox; the mandatory-disable controls intentionally do
	# not affect non-MuMu devices.
	[ "${DEVICE_CHECKS_REQUIRED:-0}" -eq 1 ] || [ "${DEVICE_CHECKS_FORCED:-0}" -eq 1 ]
}

mandatory_patch_should_patch() {
	local index disabled
	index=$1
	mandatory_should_patch || return 1
	[ "${MUMU_DETECTED:-0}" -eq 1 ] || return 0
	case "$index" in
		1) disabled=${MANDATORY_PATCH_1_DISABLED:-0} ;;
		2) disabled=${MANDATORY_PATCH_2_DISABLED:-0} ;;
		*) return 1 ;;
	esac
	[ "$disabled" != "1" ]
}

validate_profile_metadata_legacy() {
	file=$1
	profile_schema=$(json_number "$file" schema)
	profile_package=$(json_string "$file" package)
	profile_id=$(json_string "$file" profile_id)
	profile_version=$(json_string "$file" version)
	relative_library=$(json_string "$file" library)
	apk_library=$(json_string "$file" apk_library)
	original_sha=$(json_string "$file" original_sha256 | tr 'A-F' 'a-f')
	patch_count=$(json_number "$file" patch_count)

	case "$profile_schema" in 3|4) ;; *) return 1 ;; esac
	[ "$profile_package" = "$TARGET_PACKAGE" ] || return 1
	[ "$profile_version" = "$VERSION" ] || return 1
	is_safe_id "$profile_id" || return 1

	case "$relative_library" in lib/*) ;; *) return 1 ;; esac
	case "$relative_library" in *..*) return 1 ;; esac
	case "$apk_library" in lib/*) ;; *) return 1 ;; esac
	case "$apk_library" in *..*) return 1 ;; esac

	is_sha256 "$original_sha" || return 1
	[ -n "$patch_count" ] || return 1
	[ "$patch_count" -ge 0 ] && [ "$patch_count" -le 16 ] || return 1

	seen_patch_offsets=" "
	seen_patch_names=" "
	index=1
	while [ "$index" -le "$patch_count" ]; do
		name=$(json_string "$file" "patch_${index}_name")
		offset=$(json_number "$file" "patch_${index}_offset")
		before=$(json_string "$file" "patch_${index}_before" | tr 'A-F' 'a-f')
		after=$(json_string "$file" "patch_${index}_after" | tr 'A-F' 'a-f')
		is_safe_id "$name" || return 1
		[ -n "$offset" ] || return 1
		[ "$offset" -gt 0 ] 2>/dev/null || return 1
		[ $((offset % 4)) -eq 0 ] 2>/dev/null || return 1
		is_hex "$before" || return 1
		is_hex "$after" || return 1
		[ "${#before}" -eq 8 ] && [ "${#after}" -eq 8 ] || return 1
		[ "$before" != "$after" ] || return 1
		case "$seen_patch_offsets" in *" $offset "*) return 1 ;; esac
		case "$seen_patch_names" in *" $name "*) return 1 ;; esac
		seen_patch_offsets="$seen_patch_offsets$offset "
		seen_patch_names="$seen_patch_names$name "
		index=$((index + 1))
	done

	return 0
}

validate_resolution_metadata() {
	file=$1

	for prefix in resolution_native resolution_logic; do
		offset=$(json_number "$file" "${prefix}_offset")
		before=$(json_string "$file" "${prefix}_before" | tr 'A-F' 'a-f')
		after=$(json_string "$file" "${prefix}_after" | tr 'A-F' 'a-f')
		[ -n "$offset" ] || return 1
		[ "$offset" -gt 0 ] 2>/dev/null || return 1
		[ $((offset % 4)) -eq 0 ] 2>/dev/null || return 1
		is_hex "$before" || return 1
		is_hex "$after" || return 1
		[ "${#before}" -eq 8 ] && [ "${#after}" -eq 8 ] || return 1
		[ "$before" != "$after" ] || return 1
	done

	resolution_scale_offset=$(json_number "$file" resolution_scale_offset)
	resolution_scale_before=$(json_string "$file" resolution_scale_before | tr 'A-F' 'a-f')
	[ -n "$resolution_scale_offset" ] || return 1
	[ "$resolution_scale_offset" -gt 0 ] 2>/dev/null || return 1
	[ $((resolution_scale_offset % 4)) -eq 0 ] 2>/dev/null || return 1
	is_hex "$resolution_scale_before" || return 1
	[ "${#resolution_scale_before}" -eq 8 ] || return 1
	return 0
}


# Schema 3 defaults to the original FPS implementation for existing profiles.
validate_fps_cvar_metadata() {
	local file hook prefix before value_offset length part offset after first
	file=$1
	hook=$(json_number "$file" fps_hook_offset)
	value_offset=$(json_number "$file" fps_value_offset)
	before=$(json_string "$file" fps_hook_before | tr 'A-F' 'a-f')
	prefix=$(json_string "$file" fps_hook_after_prefix | tr 'A-F' 'a-f')
	[ -n "$hook" ] && [ "$hook" -gt 0 ] 2>/dev/null || return 1
	[ $((hook % 4)) -eq 0 ] || return 1
	is_hex "$before" && is_hex "$prefix" || return 1
	length=${#prefix}
	[ "$length" -ge 16 ] && [ "$length" -le 1024 ] && [ $((length % 8)) -eq 0 ] || return 1
	[ "${#before}" -eq $((length + 8)) ] || return 1
	[ -n "$value_offset" ] && [ "$value_offset" -eq $((hook + length / 2)) ] 2>/dev/null || return 1
	first=""
	for part in registration change; do
		offset=$(json_number "$file" "fps_cvar_${part}_offset")
		before=$(json_string "$file" "fps_cvar_${part}_before" | tr 'A-F' 'a-f')
		after=$(json_string "$file" "fps_cvar_${part}_after" | tr 'A-F' 'a-f')
		[ -n "$offset" ] && [ "$offset" -gt 0 ] 2>/dev/null || return 1
		[ $((offset % 4)) -eq 0 ] || return 1
		is_hex "$before" && is_hex "$after" || return 1
		[ "${#before}" -eq 8 ] && [ "${#after}" -eq 8 ] && [ "$before" != "$after" ] || return 1
		[ "$offset" -lt "$hook" ] || [ "$offset" -gt "$value_offset" ] || return 1
		[ "$offset" != "$first" ] || return 1
		first=$offset
	done
	return 0
}

inspect_fps_cvar() {
	local hook before prefix value current prefix_current target part offset original patched actual all_original all_patched
	FPS_STATE=unknown
	FPS_ACTUAL_TARGET=""
	hook=$(json_number "$SELECTED_PROFILE" fps_hook_offset)
	before=$(json_string "$SELECTED_PROFILE" fps_hook_before | tr 'A-F' 'a-f')
	prefix=$(json_string "$SELECTED_PROFILE" fps_hook_after_prefix | tr 'A-F' 'a-f')
	value=$(json_number "$SELECTED_PROFILE" fps_value_offset)
	current=$(read_hex "$LIBRARY" "$hook" "$((${#before} / 2))")
	prefix_current=$(read_hex "$LIBRARY" "$hook" "$((${#prefix} / 2))")
	all_original=1
	all_patched=1
	[ "$current" = "$before" ] || all_original=0
	[ "$prefix_current" = "$prefix" ] || all_patched=0
	for part in registration change; do
		offset=$(json_number "$SELECTED_PROFILE" "fps_cvar_${part}_offset")
		original=$(json_string "$SELECTED_PROFILE" "fps_cvar_${part}_before" | tr 'A-F' 'a-f')
		patched=$(json_string "$SELECTED_PROFILE" "fps_cvar_${part}_after" | tr 'A-F' 'a-f')
		actual=$(read_hex "$LIBRARY" "$offset" 4)
		[ "$actual" = "$original" ] || all_original=0
		[ "$actual" = "$patched" ] || all_patched=0
	done
	if [ "$all_original" -eq 1 ]; then FPS_STATE=original; return 0; fi
	if [ "$all_patched" -eq 1 ]; then
		target=$(fps_from_float_hex "$(read_hex "$LIBRARY" "$value" 4)" 2>/dev/null || true)
		if [ -n "$target" ]; then FPS_STATE=applied; FPS_ACTUAL_TARGET=$target; fi
	fi
	return 0
}

build_fps_cvar_patch_plan() {
	local plan hook desired part offset field
	plan=$1
	hook=$(json_number "$SELECTED_PROFILE" fps_hook_offset)
	if [ "$FPS_ENABLED" = "1" ]; then
		desired=$(json_string "$SELECTED_PROFILE" fps_hook_after_prefix)
		desired="$desired$(integer_to_float_hex "$FPS_TARGET" "$FPS_MIN" "$FPS_MAX")" || return 1
		field=after
	else
		desired=$(json_string "$SELECTED_PROFILE" fps_hook_before)
		field=before
	fi
	patch_plan_add "$plan" "$hook" "$desired" "FPS/CVar-lock" || return 1
	for part in registration change; do
		offset=$(json_number "$SELECTED_PROFILE" "fps_cvar_${part}_offset")
		desired=$(json_string "$SELECTED_PROFILE" "fps_cvar_${part}_${field}")
		patch_plan_add "$plan" "$offset" "$desired" "FPS/CVar-$part" || return 1
	done
	return 0
}

validate_fps_metadata() {
	case "$(json_string "$1" fps_patch_kind)" in
		cvar_lock) validate_fps_cvar_metadata "$1"; return $? ;;
		""|legacy) ;;
		*) return 1 ;;
	esac
	file=$1

	hook_offset=$(json_number "$file" fps_hook_offset)
	hook_before=$(json_string "$file" fps_hook_before | tr 'A-F' 'a-f')
	hook_prefix=$(json_string "$file" fps_hook_after_prefix | tr 'A-F' 'a-f')
	value_offset=$(json_number "$file" fps_value_offset)
	[ -n "$hook_offset" ] && [ -n "$value_offset" ] || return 1
	[ "$hook_offset" -gt 0 ] 2>/dev/null && [ "$value_offset" -gt 0 ] 2>/dev/null || return 1
	[ $((hook_offset % 4)) -eq 0 ] 2>/dev/null && [ $((value_offset % 4)) -eq 0 ] 2>/dev/null || return 1
	is_hex "$hook_before" || return 1
	is_hex "$hook_prefix" || return 1
	[ "${#hook_before}" -eq 64 ] || return 1
	[ "${#hook_prefix}" -eq 56 ] || return 1
	[ "$value_offset" -eq $((hook_offset + 28)) ] 2>/dev/null || return 1

	for prefix in fps_setter fps_registration_1 fps_registration_2; do
		offset=$(json_number "$file" "${prefix}_offset")
		before=$(json_string "$file" "${prefix}_before" | tr 'A-F' 'a-f')
		after=$(json_string "$file" "${prefix}_after" | tr 'A-F' 'a-f')
		[ -n "$offset" ] || return 1
		[ "$offset" -gt 0 ] 2>/dev/null || return 1
		[ $((offset % 4)) -eq 0 ] 2>/dev/null || return 1
		is_hex "$before" || return 1
		is_hex "$after" || return 1
		[ "${#before}" -eq 8 ] && [ "${#after}" -eq 8 ] || return 1
		[ "$before" != "$after" ] || return 1
	done

	for prefix in fps_analyzer_float fps_analyzer_pacer; do
		offset=$(json_number "$file" "${prefix}_offset")
		before=$(json_string "$file" "${prefix}_before" | tr 'A-F' 'a-f')
		[ -n "$offset" ] || return 1
		[ "$offset" -gt 0 ] 2>/dev/null || return 1
		[ $((offset % 4)) -eq 0 ] 2>/dev/null || return 1
		is_hex "$before" || return 1
		[ "${#before}" -eq 8 ] || return 1
	done

	return 0
}

validate_gpm_device_level_metadata() {
	file=$1

	for prefix in gpm_get_local_native gpm_should_use_native; do
		offset=$(json_number "$file" "${prefix}_offset")
		before=$(json_string "$file" "${prefix}_before" | tr 'A-F' 'a-f')
		after=$(json_string "$file" "${prefix}_after" | tr 'A-F' 'a-f')
		[ -n "$offset" ] || return 1
		[ "$offset" -gt 0 ] 2>/dev/null || return 1
		[ $((offset % 4)) -eq 0 ] 2>/dev/null || return 1
		is_hex "$before" || return 1
		is_hex "$after" || return 1
		[ "${#before}" -eq 16 ] && [ "${#after}" -eq 16 ] || return 1
		[ "$before" != "$after" ] || return 1
	done

	# Blueprint native thunks must preserve FFrame::Code advancement (P_FINISH)
	# before returning the forced value. The validated blocks are therefore the
	# complete 7-instruction, 28-byte wrappers rather than a bare mov/store/ret.
	for prefix in gpm_get_local_blueprint gpm_should_use_blueprint; do
		offset=$(json_number "$file" "${prefix}_offset")
		before=$(json_string "$file" "${prefix}_before" | tr 'A-F' 'a-f')
		after=$(json_string "$file" "${prefix}_after" | tr 'A-F' 'a-f')
		[ -n "$offset" ] || return 1
		[ "$offset" -gt 0 ] 2>/dev/null || return 1
		[ $((offset % 4)) -eq 0 ] 2>/dev/null || return 1
		is_hex "$before" || return 1
		is_hex "$after" || return 1
		[ "${#before}" -eq 56 ] && [ "${#after}" -eq 56 ] || return 1
		[ "$before" != "$after" ] || return 1
	done

	return 0
}

validate_graphic_library_metadata() {
	file=$1
	offset=$(json_number "$file" graphic_library_offset)
	before=$(json_string "$file" graphic_library_before | tr 'A-F' 'a-f')
	opengl=$(json_string "$file" graphic_library_opengl | tr 'A-F' 'a-f')
	vulkan=$(json_string "$file" graphic_library_vulkan | tr 'A-F' 'a-f')
	[ -n "$offset" ] || return 1
	[ "$offset" -gt 0 ] 2>/dev/null || return 1
	[ $((offset % 4)) -eq 0 ] 2>/dev/null || return 1
	is_hex "$before" || return 1
	is_hex "$opengl" || return 1
	is_hex "$vulkan" || return 1
	[ "${#before}" -eq 16 ] && [ "${#opengl}" -eq 16 ] && [ "${#vulkan}" -eq 16 ] || return 1
	[ "$before" != "$opengl" ] && [ "$before" != "$vulkan" ] && [ "$opengl" != "$vulkan" ] || return 1
	return 0
}

validate_hide_uuid_metadata() {
	local hu_file hu_count hu_index hu_offset hu_before hu_after hu_size
	local hu_other hu_other_offset hu_other_before hu_other_end
	hu_file=$1
	hu_count=$(json_number "$hu_file" hide_uuid_patch_count)
	[ "$hu_count" = "5" ] || return 1
	hu_index=1
	while [ "$hu_index" -le "$hu_count" ]; do
		hu_offset=$(json_number "$hu_file" "hide_uuid_patch_${hu_index}_offset")
		hu_before=$(json_string "$hu_file" "hide_uuid_patch_${hu_index}_before" | tr 'A-F' 'a-f')
		hu_after=$(json_string "$hu_file" "hide_uuid_patch_${hu_index}_after" | tr 'A-F' 'a-f')
		[ "$hu_offset" -gt 0 ] 2>/dev/null || return 1
		[ $((hu_offset % 4)) -eq 0 ] || return 1
		is_hex "$hu_before" && is_hex "$hu_after" || return 1
		[ "${#hu_before}" -eq "${#hu_after}" ] && [ "$hu_before" != "$hu_after" ] || return 1
		hu_size=$((${#hu_before} / 2))
		if [ "$hu_index" -lt 5 ]; then
			[ "$hu_size" -eq 4 ] || return 1
		else
			[ "$hu_size" -ge 4 ] && [ "$hu_size" -le 1024 ] && [ $((hu_size % 4)) -eq 0 ] || return 1
		fi
		hu_other=1
		while [ "$hu_other" -lt "$hu_index" ]; do
			hu_other_offset=$(json_number "$hu_file" "hide_uuid_patch_${hu_other}_offset")
			hu_other_before=$(json_string "$hu_file" "hide_uuid_patch_${hu_other}_before")
			hu_other_end=$((hu_other_offset + ${#hu_other_before} / 2))
			[ "$hu_offset" -ge "$hu_other_end" ] || [ $((hu_offset + hu_size)) -le "$hu_other_offset" ] || return 1
			hu_other=$((hu_other + 1))
		done
		hu_index=$((hu_index + 1))
	done
	return 0
}

validate_controller_mode_metadata() {
	local cm_file cm_count cm_index cm_offset cm_before cm_after cm_legacy cm_size
	local cm_other cm_other_offset cm_other_before cm_other_end
	cm_file=$1
	cm_count=$(json_number "$cm_file" controller_mode_patch_count)
	[ "$cm_count" = "12" ] || return 1
	cm_index=1
	while [ "$cm_index" -le "$cm_count" ]; do
		cm_offset=$(json_number "$cm_file" "controller_mode_patch_${cm_index}_offset")
		cm_before=$(json_string "$cm_file" "controller_mode_patch_${cm_index}_before" | tr 'A-F' 'a-f')
		cm_after=$(json_string "$cm_file" "controller_mode_patch_${cm_index}_after" | tr 'A-F' 'a-f')
		[ "$cm_offset" -gt 0 ] 2>/dev/null || return 1
		[ $((cm_offset % 4)) -eq 0 ] || return 1
		is_hex "$cm_before" && is_hex "$cm_after" || return 1
		[ "${#cm_before}" -eq "${#cm_after}" ] || return 1
		cm_legacy=$(json_string "$cm_file" "controller_mode_patch_${cm_index}_legacy_after" | tr 'A-F' 'a-f')
		if [ -n "$cm_legacy" ]; then
			is_hex "$cm_legacy" && [ "${#cm_legacy}" -eq "${#cm_before}" ] && [ "$cm_legacy" != "$cm_before" ] || return 1
		fi
		if [ "$cm_before" = "$cm_after" ]; then
			# Only these retired physical-tracking overrides may be no-ops.
			# Keep their ranges managed to undo the complete previous revision.
			case "$cm_index" in 6|7|8) [ -n "$cm_legacy" ] || return 1 ;; *) return 1 ;; esac
		fi
		cm_size=$((${#cm_before} / 2))
		case "$cm_index" in
			4) [ "$cm_size" -eq 12 ] || return 1 ;;
			12) [ "$cm_size" -eq 72 ] || return 1 ;;
			*) [ "$cm_size" -eq 4 ] || return 1 ;;
		esac
		cm_other=1
		while [ "$cm_other" -lt "$cm_index" ]; do
			cm_other_offset=$(json_number "$cm_file" "controller_mode_patch_${cm_other}_offset")
			cm_other_before=$(json_string "$cm_file" "controller_mode_patch_${cm_other}_before")
			cm_other_end=$((cm_other_offset + ${#cm_other_before} / 2))
			[ "$cm_offset" -ge "$cm_other_end" ] || [ $((cm_offset + cm_size)) -le "$cm_other_offset" ] || return 1
			cm_other=$((cm_other + 1))
		done
		cm_index=$((cm_index + 1))
	done
	return 0
}

validate_gpu_display_metadata() {
	file=$1
	offset=$(json_number "$file" gpu_display_offset)
	before=$(json_string "$file" gpu_display_before | tr 'A-F' 'a-f')
	after=$(json_string "$file" gpu_display_after | tr 'A-F' 'a-f')
	[ -n "$offset" ] || return 1
	[ "$offset" -gt 0 ] 2>/dev/null || return 1
	[ $((offset % 4)) -eq 0 ] 2>/dev/null || return 1
	is_hex "$before" || return 1
	is_hex "$after" || return 1
	[ "${#before}" -eq 8 ] && [ "${#after}" -eq 8 ] || return 1
	[ "$before" != "$after" ] || return 1
	return 0
}

validate_extended_watermark_metadata() {
	file=$1
	hook_offset=$(json_number "$file" extended_watermark_hook_offset)
	hook_before=$(json_string "$file" extended_watermark_hook_before | tr 'A-F' 'a-f')
	hook_after=$(json_string "$file" extended_watermark_hook_after | tr 'A-F' 'a-f')
	cave_offset=$(json_number "$file" extended_watermark_cave_offset)
	cave_before=$(json_string "$file" extended_watermark_cave_before | tr 'A-F' 'a-f')
	cave_api=$(json_string "$file" extended_watermark_cave_api | tr 'A-F' 'a-f')
	cave_platform=$(json_string "$file" extended_watermark_cave_platform | tr 'A-F' 'a-f')
	cave_both=$(json_string "$file" extended_watermark_cave_both | tr 'A-F' 'a-f')
	legacy_hook_after=$(json_string "$file" extended_watermark_legacy_hook_after | tr 'A-F' 'a-f')
	legacy_cave_offset=$(json_number "$file" extended_watermark_legacy_cave_offset)
	legacy_cave_before=$(json_string "$file" extended_watermark_legacy_cave_before | tr 'A-F' 'a-f')
	legacy_cave_api=$(json_string "$file" extended_watermark_legacy_cave_api | tr 'A-F' 'a-f')
	[ -n "$hook_offset" ] && [ -n "$cave_offset" ] && [ -n "$legacy_cave_offset" ] || return 1
	[ "$hook_offset" -gt 0 ] 2>/dev/null && [ "$cave_offset" -gt 0 ] 2>/dev/null && [ "$legacy_cave_offset" -gt 0 ] 2>/dev/null || return 1
	[ $((hook_offset % 4)) -eq 0 ] 2>/dev/null && [ $((cave_offset % 4)) -eq 0 ] 2>/dev/null && [ $((legacy_cave_offset % 4)) -eq 0 ] 2>/dev/null || return 1
	for value in "$hook_before" "$hook_after" "$legacy_hook_after" "$cave_before" "$cave_api" "$cave_platform" "$cave_both" "$legacy_cave_before" "$legacy_cave_api"; do
		is_hex "$value" || return 1
	done
	[ "${#hook_before}" -eq 8 ] && [ "${#hook_after}" -eq 8 ] && [ "${#legacy_hook_after}" -eq 8 ] || return 1
	[ "${#cave_before}" -eq 536 ] && [ "${#cave_api}" -eq 536 ] && [ "${#cave_platform}" -eq 536 ] && [ "${#cave_both}" -eq 536 ] || return 1
	[ "${#legacy_cave_before}" -eq 96 ] && [ "${#legacy_cave_api}" -eq 96 ] || return 1
	[ "$hook_before" != "$hook_after" ] && [ "$hook_before" != "$legacy_hook_after" ] && [ "$hook_after" != "$legacy_hook_after" ] || return 1
	[ "$cave_before" != "$cave_api" ] && [ "$cave_before" != "$cave_platform" ] && [ "$cave_before" != "$cave_both" ] || return 1
	[ "$cave_api" != "$cave_platform" ] && [ "$cave_api" != "$cave_both" ] && [ "$cave_platform" != "$cave_both" ] || return 1
	[ "$legacy_cave_before" != "$legacy_cave_api" ] || return 1
	[ "$hook_offset" -ne "$cave_offset" ] 2>/dev/null && [ "$hook_offset" -ne "$legacy_cave_offset" ] 2>/dev/null && [ "$cave_offset" -ne "$legacy_cave_offset" ] 2>/dev/null || return 1
	return 0
}

validate_cross_platform_metadata() {
	file=$1
	offset=$(json_number "$file" cross_platform_offset)
	before=$(json_string "$file" cross_platform_before | tr 'A-F' 'a-f')
	pc=$(json_string "$file" cross_platform_pc | tr 'A-F' 'a-f')
	mobile=$(json_string "$file" cross_platform_mobile | tr 'A-F' 'a-f')
	console=$(json_string "$file" cross_platform_console | tr 'A-F' 'a-f')
	[ -n "$offset" ] && [ "$offset" -gt 0 ] 2>/dev/null || return 1
	[ $((offset % 4)) -eq 0 ] 2>/dev/null || return 1
	is_hex "$before" || return 1
	is_hex "$pc" || return 1
	is_hex "$mobile" || return 1
	is_hex "$console" || return 1
	[ "${#before}" -eq 72 ] && [ "${#pc}" -eq 72 ] && [ "${#mobile}" -eq 72 ] && [ "${#console}" -eq 72 ] || return 1
	[ "$before" != "$pc" ] && [ "$before" != "$mobile" ] && [ "$before" != "$console" ] || return 1
	[ "$pc" != "$mobile" ] && [ "$pc" != "$console" ] && [ "$mobile" != "$console" ] || return 1
	return 0
}


validate_pixelflow_metadata() {
	local file part offset before enabled disabled length
	file=$1
	for part in registration change cave; do
		offset=$(json_number "$file" "pixelflow_${part}_offset")
		[ -n "$offset" ] && [ "$offset" -gt 0 ] 2>/dev/null || return 1
		[ $((offset % 4)) -eq 0 ] || return 1
		before=$(json_string "$file" "pixelflow_${part}_before" | tr 'A-F' 'a-f')
		enabled=$(json_string "$file" "pixelflow_${part}_enabled" | tr 'A-F' 'a-f')
		disabled=$(json_string "$file" "pixelflow_${part}_disabled" | tr 'A-F' 'a-f')
		is_hex "$before" && is_hex "$enabled" && is_hex "$disabled" || return 1
		length=${#before}
		[ "$length" -eq "${#enabled}" ] && [ "$length" -eq "${#disabled}" ] || return 1
		[ "$before" != "$enabled" ] && [ "$before" != "$disabled" ] || return 1
		if [ "$part" = cave ]; then
			[ "$length" -ge 16 ] && [ "$length" -le 1024 ] && [ $((length % 8)) -eq 0 ] || return 1
			[ "$enabled" != "$disabled" ] || return 1
		else
			[ "$length" -eq 8 ] || return 1
		fi
	done
	return 0
}

select_profile() {
	OPTIONAL_METADATA_INVALID=0
	SELECTED_PROFILE=""
	AMBIGUOUS=0

	for profile in "$PROFILE_DIR"/*.json; do
		[ -f "$profile" ] || continue
		[ "$(json_string "$profile" package)" = "$TARGET_PACKAGE" ] || continue
		wanted_version=$(json_string "$profile" version)
		[ "$wanted_version" = "$VERSION" ] || continue

		# Only mandatory/base metadata decides whether this is an exact profile.
		# Optional capabilities are validated independently after selection.
		if ! validate_profile_metadata "$profile"; then
			log_line "Ignoring $(basename "$profile"): invalid mandatory profile metadata"
			continue
		fi

		if [ -z "$SELECTED_PROFILE" ]; then
			SELECTED_PROFILE=$profile
		else
			AMBIGUOUS=1
		fi
	done

	[ "$AMBIGUOUS" -eq 0 ] || return 2
	[ -n "$SELECTED_PROFILE" ] || return 1

	load_advanced_defaults "$SELECTED_PROFILE"
	if [ "${ADVANCED_SETTINGS_LOADED:-0}" = "1" ] && [ "${ADVANCED_REQUEST_EXPLICIT:-0}" != "1" ]; then
		load_advanced_preferences
	fi
	PROFILE_ID=$(json_string "$SELECTED_PROFILE" profile_id)
	RELATIVE_LIBRARY=$(json_string "$SELECTED_PROFILE" library)
	APK_LIBRARY=$(json_string "$SELECTED_PROFILE" apk_library)
	ORIGINAL_SHA256=$(json_string "$SELECTED_PROFILE" original_sha256 | tr 'A-F' 'a-f')
	PATCH_COUNT=$(json_number "$SELECTED_PROFILE" patch_count)

	RESOLUTION_PATCH_READY=0
	resolution_declared=$(json_bool "$SELECTED_PROFILE" resolution_patch_ready 2>/dev/null || printf '0\n')
	if [ "$resolution_declared" -eq 1 ] 2>/dev/null; then
		if validate_resolution_metadata "$SELECTED_PROFILE"; then
			RESOLUTION_PATCH_READY=1
		else
			OPTIONAL_METADATA_INVALID=1
			log_line "Resolution capability disabled for $PROFILE_ID: invalid optional metadata"
		fi
	fi

	FPS_PATCH_READY=0
	FPS_PATCH_KIND=$(json_string "$SELECTED_PROFILE" fps_patch_kind)
	FPS_PATCH_KIND=${FPS_PATCH_KIND:-legacy}
	fps_declared=$(json_bool "$SELECTED_PROFILE" fps_patch_ready 2>/dev/null || printf '0\n')
	if [ "$fps_declared" -eq 1 ] 2>/dev/null; then
		if validate_fps_metadata "$SELECTED_PROFILE"; then
			FPS_PATCH_READY=1
		else
			OPTIONAL_METADATA_INVALID=1
			log_line "FPS capability disabled for $PROFILE_ID: invalid optional metadata"
		fi
	fi

	GPM_DEVICE_LEVEL_PATCH_READY=0
	gpm_declared=$(json_bool "$SELECTED_PROFILE" gpm_device_level_patch_ready 2>/dev/null || printf '0\n')
	if [ "$gpm_declared" -eq 1 ] 2>/dev/null; then
		if validate_gpm_device_level_metadata "$SELECTED_PROFILE"; then
			GPM_DEVICE_LEVEL_PATCH_READY=1
		else
			OPTIONAL_METADATA_INVALID=1
			log_line "GPM Device Level capability disabled for $PROFILE_ID: invalid optional metadata"
		fi
	fi

	GRAPHIC_LIBRARY_PATCH_READY=0
	graphic_library_declared=$(json_bool "$SELECTED_PROFILE" graphic_library_patch_ready 2>/dev/null || printf '0\n')
	if [ "$graphic_library_declared" -eq 1 ] 2>/dev/null; then
		if validate_graphic_library_metadata "$SELECTED_PROFILE"; then
			GRAPHIC_LIBRARY_PATCH_READY=1
		else
			OPTIONAL_METADATA_INVALID=1
			log_line "Graphic Library capability disabled for $PROFILE_ID: invalid optional metadata"
		fi
	fi


	CROSS_PLATFORM_PATCH_READY=0
	cross_platform_declared=$(json_bool "$SELECTED_PROFILE" cross_platform_patch_ready 2>/dev/null || printf '0\n')
	if [ "$cross_platform_declared" -eq 1 ] 2>/dev/null; then
		if validate_cross_platform_metadata "$SELECTED_PROFILE"; then
			CROSS_PLATFORM_PATCH_READY=1
		else
			OPTIONAL_METADATA_INVALID=1
			log_line "Cross Platform capability disabled for $PROFILE_ID: invalid optional metadata"
		fi
	fi

	GPU_DISPLAY_PATCH_READY=0
	gpu_display_declared=$(json_bool "$SELECTED_PROFILE" gpu_display_patch_ready 2>/dev/null || printf '0\n')
	if [ "$gpu_display_declared" -eq 1 ] 2>/dev/null; then
		if validate_gpu_display_metadata "$SELECTED_PROFILE"; then
			GPU_DISPLAY_PATCH_READY=1
		else
			OPTIONAL_METADATA_INVALID=1
			log_line "GPU Display capability disabled for $PROFILE_ID: invalid optional metadata"
		fi
	fi

	HIDE_UUID_PATCH_READY=0
	hide_uuid_declared=$(json_bool "$SELECTED_PROFILE" hide_uuid_patch_ready 2>/dev/null || printf '0\n')
	if [ "$hide_uuid_declared" -eq 1 ] 2>/dev/null; then
		if validate_hide_uuid_metadata "$SELECTED_PROFILE"; then
			HIDE_UUID_PATCH_READY=1
		else
			OPTIONAL_METADATA_INVALID=1
			log_line "Hide UUID capability disabled for $PROFILE_ID: invalid optional metadata"
		fi
	fi

	CONTROLLER_MODE_PATCH_READY=0
	controller_mode_declared=$(json_bool "$SELECTED_PROFILE" controller_mode_patch_ready 2>/dev/null || printf '0\n')
	if [ "$controller_mode_declared" -eq 1 ] 2>/dev/null; then
		if validate_controller_mode_metadata "$SELECTED_PROFILE"; then
			CONTROLLER_MODE_PATCH_READY=1
		else
			OPTIONAL_METADATA_INVALID=1
			log_line "Controller Mode capability disabled for $PROFILE_ID: invalid optional metadata"
		fi
	fi

	EXTENDED_WATERMARK_PATCH_READY=0
	extended_watermark_declared=$(json_bool "$SELECTED_PROFILE" extended_watermark_patch_ready 2>/dev/null || printf '0\n')
	if [ "$extended_watermark_declared" -eq 1 ] 2>/dev/null; then
		if validate_extended_watermark_metadata "$SELECTED_PROFILE"; then
			EXTENDED_WATERMARK_PATCH_READY=1
		else
			OPTIONAL_METADATA_INVALID=1
			log_line "Extended Watermark Info capability disabled for $PROFILE_ID: invalid optional metadata"
		fi
	fi

	PIXELFLOW_PATCH_READY=0
	if [ "$(json_bool "$SELECTED_PROFILE" pixelflow_patch_ready 2>/dev/null || printf '0\n')" = "1" ]; then
		if validate_pixelflow_metadata "$SELECTED_PROFILE"; then
			PIXELFLOW_PATCH_READY=1
		else
			OPTIONAL_METADATA_INVALID=1
			log_line "PixelFlow capability disabled for $PROFILE_ID: invalid optional metadata"
		fi
	fi
	LIBRARY="$INSTALL_ROOT/$RELATIVE_LIBRARY"
	[ -f "$LIBRARY" ] || return 3
	check_selected_context || return 4
	return 0
}

refresh_context() {
	wait_for_pm=${1:-0}
	detect_environment "$wait_for_pm" || return 1
	select_profile
	return $?
}

inspect_mandatory() {
	MANDATORY_UNKNOWN=0
	MANDATORY_NEEDS_PATCH=0
	MANDATORY_NEEDS_RESTORE=0
	MANDATORY_ALL_DESIRED=1
	MANDATORY_SUMMARY=""

	index=1
	while [ "$index" -le "$PATCH_COUNT" ]; do
		name=$(json_string "$SELECTED_PROFILE" "patch_${index}_name")
		offset=$(json_number "$SELECTED_PROFILE" "patch_${index}_offset")
		before=$(json_string "$SELECTED_PROFILE" "patch_${index}_before" | tr 'A-F' 'a-f')
		after=$(json_string "$SELECTED_PROFILE" "patch_${index}_after" | tr 'A-F' 'a-f')
		length=$(( ${#before} / 2 ))
		current=$(read_hex "$LIBRARY" "$offset" "$length")

		if [ "$current" = "$before" ]; then
			state="original"
			if mandatory_patch_should_patch "$index"; then
				MANDATORY_NEEDS_PATCH=1
				MANDATORY_ALL_DESIRED=0
			fi
		elif [ "$current" = "$after" ]; then
			state="applied"
			if ! mandatory_patch_should_patch "$index"; then
				MANDATORY_NEEDS_RESTORE=1
				MANDATORY_ALL_DESIRED=0
			fi
		else
			state="unknown"
			MANDATORY_UNKNOWN=1
			MANDATORY_ALL_DESIRED=0
		fi

		eval "MANDATORY_${index}_NAME=\$name"
		eval "MANDATORY_${index}_STATE=\$state"
		eval "MANDATORY_${index}_CURRENT=\$current"
		MANDATORY_SUMMARY="$MANDATORY_SUMMARY $name=$state"
		index=$((index + 1))
	done
}

inspect_resolution() {
	RESOLUTION_ACTUAL_SCALE=""
	if [ "${RESOLUTION_PATCH_READY:-0}" -ne 1 ]; then
		RESOLUTION_STATE="unavailable"
		return 0
	fi

	native_offset=$(json_number "$SELECTED_PROFILE" resolution_native_offset)
	native_before=$(json_string "$SELECTED_PROFILE" resolution_native_before | tr 'A-F' 'a-f')
	native_after=$(json_string "$SELECTED_PROFILE" resolution_native_after | tr 'A-F' 'a-f')
	scale_offset=$(json_number "$SELECTED_PROFILE" resolution_scale_offset)
	scale_before=$(json_string "$SELECTED_PROFILE" resolution_scale_before | tr 'A-F' 'a-f')
	logic_offset=$(json_number "$SELECTED_PROFILE" resolution_logic_offset)
	logic_before=$(json_string "$SELECTED_PROFILE" resolution_logic_before | tr 'A-F' 'a-f')
	logic_after=$(json_string "$SELECTED_PROFILE" resolution_logic_after | tr 'A-F' 'a-f')

	RES_NATIVE_CURRENT=$(read_hex "$LIBRARY" "$native_offset" $(( ${#native_before} / 2 )))
	RES_SCALE_CURRENT=$(read_hex "$LIBRARY" "$scale_offset" $(( ${#scale_before} / 2 )))
	RES_LOGIC_CURRENT=$(read_hex "$LIBRARY" "$logic_offset" $(( ${#logic_before} / 2 )))

	if [ "$RES_NATIVE_CURRENT" = "$native_before" ] \
		&& [ "$RES_SCALE_CURRENT" = "$scale_before" ] \
		&& [ "$RES_LOGIC_CURRENT" = "$logic_before" ]; then
		RESOLUTION_STATE="original"
		RESOLUTION_ACTUAL_SCALE=100
		return 0
	fi

	if [ "$RES_NATIVE_CURRENT" = "$native_after" ] && [ "$RES_LOGIC_CURRENT" = "$logic_after" ]; then
		actual=$(resolution_scale_from_hex "$RES_SCALE_CURRENT" 2>/dev/null || true)
		if [ -n "$actual" ]; then
			RESOLUTION_STATE="applied"
			RESOLUTION_ACTUAL_SCALE=$actual
			return 0
		fi
	fi

	RESOLUTION_STATE="unknown"
	return 0
}

inspect_fps() {
	FPS_ACTUAL_TARGET=""
	if [ "${FPS_PATCH_READY:-0}" -ne 1 ]; then
		FPS_STATE="unavailable"
		return 0
	fi

	case "$(json_string "$SELECTED_PROFILE" fps_patch_kind)" in
		cvar_lock) inspect_fps_cvar; return $? ;;
		""|legacy) ;;
		*) FPS_STATE=unknown; return 0 ;;
	esac

	hook_offset=$(json_number "$SELECTED_PROFILE" fps_hook_offset)
	hook_before=$(json_string "$SELECTED_PROFILE" fps_hook_before | tr 'A-F' 'a-f')
	hook_prefix=$(json_string "$SELECTED_PROFILE" fps_hook_after_prefix | tr 'A-F' 'a-f')
	value_offset=$(json_number "$SELECTED_PROFILE" fps_value_offset)
	setter_offset=$(json_number "$SELECTED_PROFILE" fps_setter_offset)
	setter_before=$(json_string "$SELECTED_PROFILE" fps_setter_before | tr 'A-F' 'a-f')
	setter_after=$(json_string "$SELECTED_PROFILE" fps_setter_after | tr 'A-F' 'a-f')
	reg1_offset=$(json_number "$SELECTED_PROFILE" fps_registration_1_offset)
	reg1_before=$(json_string "$SELECTED_PROFILE" fps_registration_1_before | tr 'A-F' 'a-f')
	reg1_after=$(json_string "$SELECTED_PROFILE" fps_registration_1_after | tr 'A-F' 'a-f')
	reg2_offset=$(json_number "$SELECTED_PROFILE" fps_registration_2_offset)
	reg2_before=$(json_string "$SELECTED_PROFILE" fps_registration_2_before | tr 'A-F' 'a-f')
	reg2_after=$(json_string "$SELECTED_PROFILE" fps_registration_2_after | tr 'A-F' 'a-f')
	analyzer_float_offset=$(json_number "$SELECTED_PROFILE" fps_analyzer_float_offset)
	analyzer_float_before=$(json_string "$SELECTED_PROFILE" fps_analyzer_float_before | tr 'A-F' 'a-f')
	analyzer_pacer_offset=$(json_number "$SELECTED_PROFILE" fps_analyzer_pacer_offset)
	analyzer_pacer_before=$(json_string "$SELECTED_PROFILE" fps_analyzer_pacer_before | tr 'A-F' 'a-f')

	hook_current=$(read_hex "$LIBRARY" "$hook_offset" 32)
	setter_current=$(read_hex "$LIBRARY" "$setter_offset" 4)
	reg1_current=$(read_hex "$LIBRARY" "$reg1_offset" 4)
	reg2_current=$(read_hex "$LIBRARY" "$reg2_offset" 4)
	analyzer_float_current=$(read_hex "$LIBRARY" "$analyzer_float_offset" 4)
	analyzer_pacer_current=$(read_hex "$LIBRARY" "$analyzer_pacer_offset" 4)

	if [ "$hook_current" = "$hook_before" ] \
		&& [ "$setter_current" = "$setter_before" ] \
		&& [ "$reg1_current" = "$reg1_before" ] \
		&& [ "$reg2_current" = "$reg2_before" ] \
		&& [ "$analyzer_float_current" = "$analyzer_float_before" ] \
		&& [ "$analyzer_pacer_current" = "$analyzer_pacer_before" ]; then
		FPS_STATE="original"
		FPS_ACTUAL_TARGET=60
		return 0
	fi

	hook_prefix_current=$(read_hex "$LIBRARY" "$hook_offset" 28)
	hook_value_current=$(read_hex "$LIBRARY" "$value_offset" 4)
	if [ "$hook_prefix_current" = "$hook_prefix" ] \
		&& [ "$setter_current" = "$setter_after" ] \
		&& [ "$reg1_current" = "$reg1_after" ] \
		&& [ "$reg2_current" = "$reg2_after" ]; then
		hook_target=$(fps_from_float_hex "$hook_value_current" 2>/dev/null || true)
		float_target=$(fps_from_float_movz_hex "$analyzer_float_current" 2>/dev/null || true)
		pacer_target=$(fps_from_mov_w8_hex "$analyzer_pacer_current" 2>/dev/null || true)
		if [ -n "$hook_target" ] && [ "$hook_target" = "$float_target" ] && [ "$hook_target" = "$pacer_target" ]; then
			FPS_STATE="applied"
			FPS_ACTUAL_TARGET=$hook_target
			return 0
		fi
	fi

	FPS_STATE="unknown"
	return 0
}

inspect_gpm_device_level() {
	if [ "${GPM_DEVICE_LEVEL_PATCH_READY:-0}" -ne 1 ]; then
		GPM_DEVICE_LEVEL_STATE="unavailable"
		return 0
	fi

	all_original=1
	all_applied=1
	for prefix in gpm_get_local_native gpm_get_local_blueprint gpm_should_use_native gpm_should_use_blueprint; do
		offset=$(json_number "$SELECTED_PROFILE" "${prefix}_offset")
		before=$(json_string "$SELECTED_PROFILE" "${prefix}_before" | tr 'A-F' 'a-f')
		after=$(json_string "$SELECTED_PROFILE" "${prefix}_after" | tr 'A-F' 'a-f')
		current=$(read_hex "$LIBRARY" "$offset" $(( ${#before} / 2 )))
		[ "$current" = "$before" ] || all_original=0
		[ "$current" = "$after" ] || all_applied=0
	done

	if [ "$all_original" -eq 1 ]; then
		GPM_DEVICE_LEVEL_STATE="original"
	elif [ "$all_applied" -eq 1 ]; then
		GPM_DEVICE_LEVEL_STATE="applied"
	else
		GPM_DEVICE_LEVEL_STATE="unknown"
	fi
	return 0
}

inspect_graphic_library() {
	if [ "${GRAPHIC_LIBRARY_PATCH_READY:-0}" -ne 1 ]; then
		GRAPHIC_LIBRARY_STATE="unavailable"
		return 0
	fi

	offset=$(json_number "$SELECTED_PROFILE" graphic_library_offset)
	before=$(json_string "$SELECTED_PROFILE" graphic_library_before | tr 'A-F' 'a-f')
	opengl=$(json_string "$SELECTED_PROFILE" graphic_library_opengl | tr 'A-F' 'a-f')
	vulkan=$(json_string "$SELECTED_PROFILE" graphic_library_vulkan | tr 'A-F' 'a-f')
	current=$(read_hex "$LIBRARY" "$offset" 8)

	if [ "$current" = "$before" ]; then
		GRAPHIC_LIBRARY_STATE="original"
	elif [ "$current" = "$opengl" ]; then
		GRAPHIC_LIBRARY_STATE="opengl"
	elif [ "$current" = "$vulkan" ]; then
		GRAPHIC_LIBRARY_STATE="vulkan"
	else
		GRAPHIC_LIBRARY_STATE="unknown"
	fi
	return 0
}

inspect_cross_platform() {
	if [ "${CROSS_PLATFORM_PATCH_READY:-0}" -ne 1 ]; then
		CROSS_PLATFORM_STATE="unavailable"
		return 0
	fi

	offset=$(json_number "$SELECTED_PROFILE" cross_platform_offset)
	before=$(json_string "$SELECTED_PROFILE" cross_platform_before | tr 'A-F' 'a-f')
	pc=$(json_string "$SELECTED_PROFILE" cross_platform_pc | tr 'A-F' 'a-f')
	mobile=$(json_string "$SELECTED_PROFILE" cross_platform_mobile | tr 'A-F' 'a-f')
	console=$(json_string "$SELECTED_PROFILE" cross_platform_console | tr 'A-F' 'a-f')
	current=$(read_hex "$LIBRARY" "$offset" 36)

	if [ "$current" = "$before" ]; then
		CROSS_PLATFORM_STATE="original"
	elif [ "$current" = "$pc" ]; then
		CROSS_PLATFORM_STATE="pc"
	elif [ "$current" = "$mobile" ]; then
		CROSS_PLATFORM_STATE="mobile"
	elif [ "$current" = "$console" ]; then
		CROSS_PLATFORM_STATE="console"
	else
		CROSS_PLATFORM_STATE="unknown"
	fi
	return 0
}

inspect_hide_uuid() {
	local hu_index hu_offset hu_before hu_after hu_current hu_original hu_applied
	HIDE_UUID_STATE=unavailable
	[ "${HIDE_UUID_PATCH_READY:-0}" -eq 1 ] || return 0
	hu_index=1
	hu_original=0
	hu_applied=0
	while [ "$hu_index" -le 5 ]; do
		hu_offset=$(json_number "$SELECTED_PROFILE" "hide_uuid_patch_${hu_index}_offset")
		hu_before=$(json_string "$SELECTED_PROFILE" "hide_uuid_patch_${hu_index}_before" | tr 'A-F' 'a-f')
		hu_after=$(json_string "$SELECTED_PROFILE" "hide_uuid_patch_${hu_index}_after" | tr 'A-F' 'a-f')
		hu_current=$(read_hex "$LIBRARY" "$hu_offset" "$((${#hu_before} / 2))")
		if [ "$hu_current" = "$hu_before" ]; then hu_original=$((hu_original + 1));
		elif [ "$hu_current" = "$hu_after" ]; then hu_applied=$((hu_applied + 1)); fi
		hu_index=$((hu_index + 1))
	done
	HIDE_UUID_STATE=unknown
	[ "$hu_original" -eq 5 ] && HIDE_UUID_STATE=original
	[ "$hu_applied" -eq 5 ] && HIDE_UUID_STATE=applied
	return 0
}

inspect_controller_mode() {
	local cm_index cm_offset cm_before cm_after cm_current cm_original cm_applied cm_legacy cm_legacy_applied
	CONTROLLER_MODE_STATE=unavailable
	[ "${CONTROLLER_MODE_PATCH_READY:-0}" -eq 1 ] || return 0
	cm_index=1
	cm_original=0
	cm_applied=0
	cm_legacy_applied=0
	while [ "$cm_index" -le 12 ]; do
		cm_offset=$(json_number "$SELECTED_PROFILE" "controller_mode_patch_${cm_index}_offset")
		cm_before=$(json_string "$SELECTED_PROFILE" "controller_mode_patch_${cm_index}_before" | tr 'A-F' 'a-f')
		cm_after=$(json_string "$SELECTED_PROFILE" "controller_mode_patch_${cm_index}_after" | tr 'A-F' 'a-f')
		cm_current=$(read_hex "$LIBRARY" "$cm_offset" "$((${#cm_before} / 2))")
		cm_legacy=$(json_string "$SELECTED_PROFILE" "controller_mode_patch_${cm_index}_legacy_after" | tr 'A-F' 'a-f')
		# A retired range can match both original and current-patch states.
		[ "$cm_current" != "$cm_before" ] || cm_original=$((cm_original + 1))
		[ "$cm_current" != "$cm_after" ] || cm_applied=$((cm_applied + 1))
		[ -z "$cm_legacy" ] || [ "$cm_current" != "$cm_legacy" ] || cm_legacy_applied=$((cm_legacy_applied + 1))
		cm_index=$((cm_index + 1))
	done
	CONTROLLER_MODE_STATE=unknown
	[ "$cm_legacy_applied" -eq 12 ] && CONTROLLER_MODE_STATE=legacy_applied
	[ "$cm_original" -eq 12 ] && CONTROLLER_MODE_STATE=original
	[ "$cm_applied" -eq 12 ] && CONTROLLER_MODE_STATE=applied
	return 0
}

inspect_gpu_display() {
	if [ "${GPU_DISPLAY_PATCH_READY:-0}" -ne 1 ]; then
		GPU_DISPLAY_STATE="unavailable"
		return 0
	fi

	offset=$(json_number "$SELECTED_PROFILE" gpu_display_offset)
	before=$(json_string "$SELECTED_PROFILE" gpu_display_before | tr 'A-F' 'a-f')
	after=$(json_string "$SELECTED_PROFILE" gpu_display_after | tr 'A-F' 'a-f')
	current=$(read_hex "$LIBRARY" "$offset" 4)

	if [ "$current" = "$before" ]; then
		GPU_DISPLAY_STATE="original"
	elif [ "$current" = "$after" ]; then
		GPU_DISPLAY_STATE="applied"
	else
		GPU_DISPLAY_STATE="unknown"
	fi
	return 0
}

inspect_extended_watermark() {
	if [ "${EXTENDED_WATERMARK_PATCH_READY:-0}" -ne 1 ]; then
		EXTENDED_WATERMARK_STATE="unavailable"
		return 0
	fi

	hook_offset=$(json_number "$SELECTED_PROFILE" extended_watermark_hook_offset)
	hook_before=$(json_string "$SELECTED_PROFILE" extended_watermark_hook_before | tr 'A-F' 'a-f')
	hook_after=$(json_string "$SELECTED_PROFILE" extended_watermark_hook_after | tr 'A-F' 'a-f')
	cave_offset=$(json_number "$SELECTED_PROFILE" extended_watermark_cave_offset)
	cave_before=$(json_string "$SELECTED_PROFILE" extended_watermark_cave_before | tr 'A-F' 'a-f')
	cave_api=$(json_string "$SELECTED_PROFILE" extended_watermark_cave_api | tr 'A-F' 'a-f')
	cave_platform=$(json_string "$SELECTED_PROFILE" extended_watermark_cave_platform | tr 'A-F' 'a-f')
	cave_both=$(json_string "$SELECTED_PROFILE" extended_watermark_cave_both | tr 'A-F' 'a-f')
	legacy_hook_after=$(json_string "$SELECTED_PROFILE" extended_watermark_legacy_hook_after | tr 'A-F' 'a-f')
	legacy_cave_offset=$(json_number "$SELECTED_PROFILE" extended_watermark_legacy_cave_offset)
	legacy_cave_before=$(json_string "$SELECTED_PROFILE" extended_watermark_legacy_cave_before | tr 'A-F' 'a-f')
	legacy_cave_api=$(json_string "$SELECTED_PROFILE" extended_watermark_legacy_cave_api | tr 'A-F' 'a-f')
	hook_current=$(read_hex "$LIBRARY" "$hook_offset" 4)
	cave_current=$(read_hex "$LIBRARY" "$cave_offset" 268)
	legacy_cave_current=$(read_hex "$LIBRARY" "$legacy_cave_offset" 48)

	if [ "$hook_current" = "$hook_before" ] && [ "$cave_current" = "$cave_before" ] && [ "$legacy_cave_current" = "$legacy_cave_before" ]; then
		EXTENDED_WATERMARK_STATE="original"
	elif [ "$hook_current" = "$legacy_hook_after" ] && [ "$cave_current" = "$cave_before" ] && [ "$legacy_cave_current" = "$legacy_cave_api" ]; then
		# Recognize the 1.2.3 Graphic API hook so an upgrade can migrate it
		# transactionally instead of classifying known managed bytes as corrupt.
		EXTENDED_WATERMARK_STATE="legacy_api"
	elif [ "$hook_current" = "$hook_after" ] && [ "$legacy_cave_current" = "$legacy_cave_before" ]; then
		if [ "$cave_current" = "$cave_api" ]; then
			EXTENDED_WATERMARK_STATE="api"
		elif [ "$cave_current" = "$cave_platform" ]; then
			EXTENDED_WATERMARK_STATE="platform"
		elif [ "$cave_current" = "$cave_both" ]; then
			EXTENDED_WATERMARK_STATE="both"
		else
			EXTENDED_WATERMARK_STATE="unknown"
		fi
	else
		EXTENDED_WATERMARK_STATE="unknown"
	fi
	return 0
}

extended_watermark_desired_state() {
	if [ "$GRAPHIC_API_DISPLAY_ENABLED" = "1" ] && [ "$PLATFORM_DISPLAY_ENABLED" = "1" ]; then
		printf 'both\n'
	elif [ "$GRAPHIC_API_DISPLAY_ENABLED" = "1" ]; then
		printf 'api\n'
	elif [ "$PLATFORM_DISPLAY_ENABLED" = "1" ]; then
		printf 'platform\n'
	else
		printf 'original\n'
	fi
}


inspect_pixelflow() {
	local mode part field offset expected actual matched
	PIXELFLOW_STATE=unavailable
	[ "${PIXELFLOW_PATCH_READY:-0}" -eq 1 ] || return 0
	PIXELFLOW_STATE=unknown
	for mode in original enabled disabled; do
		field=$mode
		[ "$mode" != original ] || field=before
		matched=1
		for part in registration change cave; do
			offset=$(json_number "$SELECTED_PROFILE" "pixelflow_${part}_offset")
			expected=$(json_string "$SELECTED_PROFILE" "pixelflow_${part}_${field}" | tr 'A-F' 'a-f')
			actual=$(read_hex "$LIBRARY" "$offset" "$((${#expected} / 2))")
			[ "$actual" = "$expected" ] || { matched=0; break; }
		done
		if [ "$matched" -eq 1 ]; then PIXELFLOW_STATE=$mode; return 0; fi
	done
}

needs_reconcile_write() {
	[ "$MANDATORY_NEEDS_PATCH" -eq 1 ] && return 0
	[ "$MANDATORY_NEEDS_RESTORE" -eq 1 ] && return 0

	if [ "${RESOLUTION_PATCH_READY:-0}" -eq 1 ]; then
		if [ "$RESOLUTION_ENABLED" = "1" ]; then
			[ "$RESOLUTION_STATE" = "original" ] && return 0
			[ "$RESOLUTION_STATE" = "applied" ] && [ "$RESOLUTION_ACTUAL_SCALE" != "$RESOLUTION_SCALE" ] && return 0
		else
			[ "$RESOLUTION_STATE" = "applied" ] && return 0
		fi
	fi

	if [ "${FPS_PATCH_READY:-0}" -eq 1 ]; then
		if [ "$FPS_ENABLED" = "1" ]; then
			[ "$FPS_STATE" = "original" ] && return 0
			[ "$FPS_STATE" = "applied" ] && [ "$FPS_ACTUAL_TARGET" != "$FPS_TARGET" ] && return 0
		else
			[ "$FPS_STATE" = "applied" ] && return 0
		fi
	fi

	if [ "${GPM_DEVICE_LEVEL_PATCH_READY:-0}" -eq 1 ]; then
		if [ "$GPM_DEVICE_LEVEL_ENABLED" = "1" ]; then
			[ "$GPM_DEVICE_LEVEL_STATE" = "original" ] && return 0
		else
			[ "$GPM_DEVICE_LEVEL_STATE" = "applied" ] && return 0
		fi
	fi

	if [ "${GRAPHIC_LIBRARY_PATCH_READY:-0}" -eq 1 ]; then
		if [ "$GRAPHIC_LIBRARY_ENABLED" = "1" ]; then
			case "$GRAPHIC_LIBRARY" in
				opengl) [ "$GRAPHIC_LIBRARY_STATE" != "opengl" ] && return 0 ;;
				vulkan) [ "$GRAPHIC_LIBRARY_STATE" != "vulkan" ] && return 0 ;;
			esac
		else
			[ "$GRAPHIC_LIBRARY_STATE" != "original" ] && return 0
		fi
	fi

	if [ "${CROSS_PLATFORM_PATCH_READY:-0}" -eq 1 ]; then
		if [ "$CROSS_PLATFORM_ENABLED" = "1" ]; then
			[ "$CROSS_PLATFORM_STATE" != "$CROSS_PLATFORM" ] && return 0
		else
			[ "$CROSS_PLATFORM_STATE" != "original" ] && return 0
		fi
	fi

	if [ "${GPU_DISPLAY_PATCH_READY:-0}" -eq 1 ]; then
		if [ "$GPU_DISPLAY_ENABLED" = "1" ]; then
			[ "$GPU_DISPLAY_STATE" = "original" ] && return 0
		else
			[ "$GPU_DISPLAY_STATE" = "applied" ] && return 0
		fi
	fi

	if [ "${HIDE_UUID_PATCH_READY:-0}" -eq 1 ]; then
		if [ "$HIDE_UUID_ENABLED" = "1" ]; then
			[ "$HIDE_UUID_STATE" = "original" ] && return 0
		else
			[ "$HIDE_UUID_STATE" = "applied" ] && return 0
		fi
	fi

	if [ "${CONTROLLER_MODE_PATCH_READY:-0}" -eq 1 ]; then
		[ "$CONTROLLER_MODE_STATE" = "legacy_applied" ] && return 0
		if [ "$CONTROLLER_MODE_ENABLED" = "1" ]; then
			[ "$CONTROLLER_MODE_STATE" = "original" ] && return 0
		else
			[ "$CONTROLLER_MODE_STATE" = "applied" ] && return 0
		fi
	fi

	if [ "${EXTENDED_WATERMARK_PATCH_READY:-0}" -eq 1 ]; then
		extended_watermark_wanted=$(extended_watermark_desired_state)
		[ "$EXTENDED_WATERMARK_STATE" != "$extended_watermark_wanted" ] && return 0
	fi

	if [ "${PIXELFLOW_PATCH_READY:-0}" -eq 1 ]; then
		[ "$PIXELFLOW_STATE" != "$PIXELFLOW_MODE" ] && return 0
	fi
	return 1
}

inspect_all_binary_patches() {
	inspect_mandatory
	inspect_resolution
	inspect_fps
	inspect_gpm_device_level
	inspect_graphic_library
	inspect_cross_platform
	inspect_gpu_display
	inspect_hide_uuid
	inspect_controller_mode
	inspect_extended_watermark
	inspect_pixelflow
}

managed_binary_has_unknown_state() {
	[ "${MANDATORY_UNKNOWN:-1}" -eq 1 ] && return 0
	[ "${RESOLUTION_PATCH_READY:-0}" -eq 1 ] && [ "$RESOLUTION_STATE" = "unknown" ] && return 0
	[ "${FPS_PATCH_READY:-0}" -eq 1 ] && [ "$FPS_STATE" = "unknown" ] && return 0
	[ "${GPM_DEVICE_LEVEL_PATCH_READY:-0}" -eq 1 ] && [ "$GPM_DEVICE_LEVEL_STATE" = "unknown" ] && return 0
	[ "${GRAPHIC_LIBRARY_PATCH_READY:-0}" -eq 1 ] && [ "$GRAPHIC_LIBRARY_STATE" = "unknown" ] && return 0
	[ "${CROSS_PLATFORM_PATCH_READY:-0}" -eq 1 ] && [ "$CROSS_PLATFORM_STATE" = "unknown" ] && return 0
	[ "${GPU_DISPLAY_PATCH_READY:-0}" -eq 1 ] && [ "$GPU_DISPLAY_STATE" = "unknown" ] && return 0
	[ "${HIDE_UUID_PATCH_READY:-0}" -eq 1 ] && [ "$HIDE_UUID_STATE" = "unknown" ] && return 0
	[ "${CONTROLLER_MODE_PATCH_READY:-0}" -eq 1 ] && [ "$CONTROLLER_MODE_STATE" = "unknown" ] && return 0
	[ "${EXTENDED_WATERMARK_PATCH_READY:-0}" -eq 1 ] && [ "$EXTENDED_WATERMARK_STATE" = "unknown" ] && return 0
	[ "${PIXELFLOW_PATCH_READY:-0}" -eq 1 ] && [ "$PIXELFLOW_STATE" = "unknown" ] && return 0
	return 1
}

binary_profile_matches_desired() {
	managed_binary_has_unknown_state && return 1
	needs_reconcile_write && return 1
	return 0
}

patch_plan_add() {
	local plan offset data label
	plan=$1
	offset=$2
	data=$(printf '%s' "$3" | tr 'A-F' 'a-f')
	label=$4
	case "$offset" in ""|*[!0-9]*) return 1 ;; esac
	[ "$offset" -ge 0 ] 2>/dev/null || return 1
	is_hex "$data" || return 1
	case "$label" in *'|'*|*'\n'*|*'\r'*) return 1 ;; esac
	printf '%s|%s|%s\n' "$offset" "$data" "$label" >> "$plan"
}

build_patch_plan() {
	local plan index name offset before after desired native_offset native_before native_after
	local scale_offset scale_before logic_offset logic_before logic_after desired_scale_hex
	local hook_offset hook_before hook_prefix value_offset hook_value setter_offset setter_before setter_after
	local reg1_offset reg1_before reg1_after reg2_offset reg2_before reg2_after
	local analyzer_float_offset analyzer_float_before analyzer_float analyzer_pacer_offset analyzer_pacer_before analyzer_pacer
	local cave_offset cave_value legacy_cave_offset legacy_cave_before watermark_desired
	local prefix
	plan=$1
	: > "$plan" || return 1

	index=1
	while [ "$index" -le "$PATCH_COUNT" ]; do
		name=$(json_string "$SELECTED_PROFILE" "patch_${index}_name")
		offset=$(json_number "$SELECTED_PROFILE" "patch_${index}_offset")
		before=$(json_string "$SELECTED_PROFILE" "patch_${index}_before" | tr 'A-F' 'a-f')
		after=$(json_string "$SELECTED_PROFILE" "patch_${index}_after" | tr 'A-F' 'a-f')
		if mandatory_patch_should_patch "$index"; then desired=$after; else desired=$before; fi
		patch_plan_add "$plan" "$offset" "$desired" "$name" || return 1
		index=$((index + 1))
	done

	if [ "${RESOLUTION_PATCH_READY:-0}" -eq 1 ]; then
		native_offset=$(json_number "$SELECTED_PROFILE" resolution_native_offset)
		native_before=$(json_string "$SELECTED_PROFILE" resolution_native_before | tr 'A-F' 'a-f')
		native_after=$(json_string "$SELECTED_PROFILE" resolution_native_after | tr 'A-F' 'a-f')
		scale_offset=$(json_number "$SELECTED_PROFILE" resolution_scale_offset)
		scale_before=$(json_string "$SELECTED_PROFILE" resolution_scale_before | tr 'A-F' 'a-f')
		logic_offset=$(json_number "$SELECTED_PROFILE" resolution_logic_offset)
		logic_before=$(json_string "$SELECTED_PROFILE" resolution_logic_before | tr 'A-F' 'a-f')
		logic_after=$(json_string "$SELECTED_PROFILE" resolution_logic_after | tr 'A-F' 'a-f')
		if [ "$RESOLUTION_ENABLED" = "1" ]; then
			desired_scale_hex=$(percent_to_instruction_hex "$RESOLUTION_SCALE") || return 1
			patch_plan_add "$plan" "$native_offset" "$native_after" "Resolution/native" || return 1
			patch_plan_add "$plan" "$scale_offset" "$desired_scale_hex" "Resolution/scale" || return 1
			patch_plan_add "$plan" "$logic_offset" "$logic_after" "Resolution/logic" || return 1
		else
			patch_plan_add "$plan" "$native_offset" "$native_before" "Resolution/native" || return 1
			patch_plan_add "$plan" "$scale_offset" "$scale_before" "Resolution/scale" || return 1
			patch_plan_add "$plan" "$logic_offset" "$logic_before" "Resolution/logic" || return 1
		fi
	fi

	if [ "${FPS_PATCH_READY:-0}" -eq 1 ]; then
		case "$(json_string "$SELECTED_PROFILE" fps_patch_kind)" in
			cvar_lock) build_fps_cvar_patch_plan "$plan" || return 1 ;;
			""|legacy)
				hook_offset=$(json_number "$SELECTED_PROFILE" fps_hook_offset)
				hook_before=$(json_string "$SELECTED_PROFILE" fps_hook_before | tr 'A-F' 'a-f')
				hook_prefix=$(json_string "$SELECTED_PROFILE" fps_hook_after_prefix | tr 'A-F' 'a-f')
				value_offset=$(json_number "$SELECTED_PROFILE" fps_value_offset)
				setter_offset=$(json_number "$SELECTED_PROFILE" fps_setter_offset)
				setter_before=$(json_string "$SELECTED_PROFILE" fps_setter_before | tr 'A-F' 'a-f')
				setter_after=$(json_string "$SELECTED_PROFILE" fps_setter_after | tr 'A-F' 'a-f')
				reg1_offset=$(json_number "$SELECTED_PROFILE" fps_registration_1_offset)
				reg1_before=$(json_string "$SELECTED_PROFILE" fps_registration_1_before | tr 'A-F' 'a-f')
				reg1_after=$(json_string "$SELECTED_PROFILE" fps_registration_1_after | tr 'A-F' 'a-f')
				reg2_offset=$(json_number "$SELECTED_PROFILE" fps_registration_2_offset)
				reg2_before=$(json_string "$SELECTED_PROFILE" fps_registration_2_before | tr 'A-F' 'a-f')
				reg2_after=$(json_string "$SELECTED_PROFILE" fps_registration_2_after | tr 'A-F' 'a-f')
				analyzer_float_offset=$(json_number "$SELECTED_PROFILE" fps_analyzer_float_offset)
				analyzer_float_before=$(json_string "$SELECTED_PROFILE" fps_analyzer_float_before | tr 'A-F' 'a-f')
				analyzer_pacer_offset=$(json_number "$SELECTED_PROFILE" fps_analyzer_pacer_offset)
				analyzer_pacer_before=$(json_string "$SELECTED_PROFILE" fps_analyzer_pacer_before | tr 'A-F' 'a-f')
				if [ "$FPS_ENABLED" = "1" ]; then
					hook_value=$(integer_to_float_hex "$FPS_TARGET" "$FPS_MIN" "$FPS_MAX") || return 1
					analyzer_float=$(integer_float_movz_w8_hex "$FPS_TARGET" "$FPS_MIN" "$FPS_MAX") || return 1
					analyzer_pacer=$(integer_mov_w8_hex "$FPS_TARGET" "$FPS_MIN" "$FPS_MAX") || return 1
					patch_plan_add "$plan" "$hook_offset" "$hook_prefix" "FPS/hook" || return 1
					patch_plan_add "$plan" "$value_offset" "$hook_value" "FPS/value" || return 1
					patch_plan_add "$plan" "$setter_offset" "$setter_after" "FPS/setter" || return 1
					patch_plan_add "$plan" "$reg1_offset" "$reg1_after" "FPS/registration-1" || return 1
					patch_plan_add "$plan" "$reg2_offset" "$reg2_after" "FPS/registration-2" || return 1
					patch_plan_add "$plan" "$analyzer_float_offset" "$analyzer_float" "FPS/analyzer-float" || return 1
					patch_plan_add "$plan" "$analyzer_pacer_offset" "$analyzer_pacer" "FPS/analyzer-pacer" || return 1
				else
					patch_plan_add "$plan" "$hook_offset" "$hook_before" "FPS/hook" || return 1
					patch_plan_add "$plan" "$setter_offset" "$setter_before" "FPS/setter" || return 1
					patch_plan_add "$plan" "$reg1_offset" "$reg1_before" "FPS/registration-1" || return 1
					patch_plan_add "$plan" "$reg2_offset" "$reg2_before" "FPS/registration-2" || return 1
					patch_plan_add "$plan" "$analyzer_float_offset" "$analyzer_float_before" "FPS/analyzer-float" || return 1
					patch_plan_add "$plan" "$analyzer_pacer_offset" "$analyzer_pacer_before" "FPS/analyzer-pacer" || return 1
				fi
				;;
			*) return 1 ;;
		esac
	fi

	if [ "${GPM_DEVICE_LEVEL_PATCH_READY:-0}" -eq 1 ]; then
		for prefix in gpm_get_local_native gpm_get_local_blueprint gpm_should_use_native gpm_should_use_blueprint; do
			offset=$(json_number "$SELECTED_PROFILE" "${prefix}_offset")
			if [ "$GPM_DEVICE_LEVEL_ENABLED" = "1" ]; then
				desired=$(json_string "$SELECTED_PROFILE" "${prefix}_after" | tr 'A-F' 'a-f')
			else
				desired=$(json_string "$SELECTED_PROFILE" "${prefix}_before" | tr 'A-F' 'a-f')
			fi
			patch_plan_add "$plan" "$offset" "$desired" "GPM/$prefix" || return 1
		done
	fi

	if [ "${GRAPHIC_LIBRARY_PATCH_READY:-0}" -eq 1 ]; then
		offset=$(json_number "$SELECTED_PROFILE" graphic_library_offset)
		if [ "$GRAPHIC_LIBRARY_ENABLED" = "1" ]; then
			case "$GRAPHIC_LIBRARY" in
				opengl) desired=$(json_string "$SELECTED_PROFILE" graphic_library_opengl | tr 'A-F' 'a-f') ;;
				vulkan) desired=$(json_string "$SELECTED_PROFILE" graphic_library_vulkan | tr 'A-F' 'a-f') ;;
				*) return 1 ;;
			esac
		else
			desired=$(json_string "$SELECTED_PROFILE" graphic_library_before | tr 'A-F' 'a-f')
		fi
		patch_plan_add "$plan" "$offset" "$desired" "Graphics/library" || return 1
	fi

	if [ "${CROSS_PLATFORM_PATCH_READY:-0}" -eq 1 ]; then
		offset=$(json_number "$SELECTED_PROFILE" cross_platform_offset)
		if [ "$CROSS_PLATFORM_ENABLED" = "1" ]; then
			case "$CROSS_PLATFORM" in
				pc) desired=$(json_string "$SELECTED_PROFILE" cross_platform_pc | tr 'A-F' 'a-f') ;;
				mobile) desired=$(json_string "$SELECTED_PROFILE" cross_platform_mobile | tr 'A-F' 'a-f') ;;
				console) desired=$(json_string "$SELECTED_PROFILE" cross_platform_console | tr 'A-F' 'a-f') ;;
				*) return 1 ;;
			esac
		else
			desired=$(json_string "$SELECTED_PROFILE" cross_platform_before | tr 'A-F' 'a-f')
		fi
		patch_plan_add "$plan" "$offset" "$desired" "CrossPlatform/runtime" || return 1
	fi

	if [ "${GPU_DISPLAY_PATCH_READY:-0}" -eq 1 ]; then
		offset=$(json_number "$SELECTED_PROFILE" gpu_display_offset)
		if [ "$GPU_DISPLAY_ENABLED" = "1" ]; then
			desired=$(json_string "$SELECTED_PROFILE" gpu_display_after | tr 'A-F' 'a-f')
		else
			desired=$(json_string "$SELECTED_PROFILE" gpu_display_before | tr 'A-F' 'a-f')
		fi
		patch_plan_add "$plan" "$offset" "$desired" "GPU/display" || return 1
	fi

	if [ "${EXTENDED_WATERMARK_PATCH_READY:-0}" -eq 1 ]; then
		hook_offset=$(json_number "$SELECTED_PROFILE" extended_watermark_hook_offset)
		cave_offset=$(json_number "$SELECTED_PROFILE" extended_watermark_cave_offset)
		legacy_cave_offset=$(json_number "$SELECTED_PROFILE" extended_watermark_legacy_cave_offset)
		legacy_cave_before=$(json_string "$SELECTED_PROFILE" extended_watermark_legacy_cave_before | tr 'A-F' 'a-f')
		watermark_desired=$(extended_watermark_desired_state)
		case "$watermark_desired" in
			original)
				hook_value=$(json_string "$SELECTED_PROFILE" extended_watermark_hook_before | tr 'A-F' 'a-f')
				cave_value=$(json_string "$SELECTED_PROFILE" extended_watermark_cave_before | tr 'A-F' 'a-f')
				;;
			api)
				hook_value=$(json_string "$SELECTED_PROFILE" extended_watermark_hook_after | tr 'A-F' 'a-f')
				cave_value=$(json_string "$SELECTED_PROFILE" extended_watermark_cave_api | tr 'A-F' 'a-f')
				;;
			platform)
				hook_value=$(json_string "$SELECTED_PROFILE" extended_watermark_hook_after | tr 'A-F' 'a-f')
				cave_value=$(json_string "$SELECTED_PROFILE" extended_watermark_cave_platform | tr 'A-F' 'a-f')
				;;
			both)
				hook_value=$(json_string "$SELECTED_PROFILE" extended_watermark_hook_after | tr 'A-F' 'a-f')
				cave_value=$(json_string "$SELECTED_PROFILE" extended_watermark_cave_both | tr 'A-F' 'a-f')
				;;
			*) return 1 ;;
		esac
		# Always clear the 1.2.3 cave. This makes upgrades deterministic and
		# prevents the old API hook payload from becoming orphaned executable data.
		patch_plan_add "$plan" "$legacy_cave_offset" "$legacy_cave_before" "Watermark/legacy-cave" || return 1
		patch_plan_add "$plan" "$cave_offset" "$cave_value" "Watermark/extended-cave" || return 1
		patch_plan_add "$plan" "$hook_offset" "$hook_value" "Watermark/hook" || return 1
	fi

	if [ "${PIXELFLOW_PATCH_READY:-0}" -eq 1 ]; then
		case "$PIXELFLOW_MODE" in original) desired=before ;; enabled|disabled) desired=$PIXELFLOW_MODE ;; *) return 1 ;; esac
		for prefix in registration change cave; do
			offset=$(json_number "$SELECTED_PROFILE" "pixelflow_${prefix}_offset")
			cave_value=$(json_string "$SELECTED_PROFILE" "pixelflow_${prefix}_${desired}")
			patch_plan_add "$plan" "$offset" "$cave_value" "PixelFlow/$prefix" || return 1
		done
	fi

	if [ "${HIDE_UUID_PATCH_READY:-0}" -eq 1 ]; then
		if [ "${HIDE_UUID_ENABLED:-0}" = "1" ]; then prefix=after; else prefix=before; fi
		index=1
		while [ "$index" -le 5 ]; do
			offset=$(json_number "$SELECTED_PROFILE" "hide_uuid_patch_${index}_offset")
			desired=$(json_string "$SELECTED_PROFILE" "hide_uuid_patch_${index}_${prefix}" | tr 'A-F' 'a-f')
			patch_plan_add "$plan" "$offset" "$desired" "HideUUID/$index" || return 1
			index=$((index + 1))
		done
	fi

	if [ "${CONTROLLER_MODE_PATCH_READY:-0}" -eq 1 ]; then
		if [ "${CONTROLLER_MODE_ENABLED:-0}" = "1" ]; then prefix=after; else prefix=before; fi
		index=1
		while [ "$index" -le 12 ]; do
			offset=$(json_number "$SELECTED_PROFILE" "controller_mode_patch_${index}_offset")
			desired=$(json_string "$SELECTED_PROFILE" "controller_mode_patch_${index}_${prefix}" | tr 'A-F' 'a-f')
			patch_plan_add "$plan" "$offset" "$desired" "ControllerMode/$index" || return 1
			index=$((index + 1))
		done
	fi

	PATCH_PLAN_COUNT=$(awk 'END { print NR + 0 }' "$plan" 2>/dev/null)
	[ "$PATCH_PLAN_COUNT" -gt 0 ] 2>/dev/null
}

write_hex_at_file() {
	local file offset data payload length file_size
	file=$1
	offset=$2
	data=$(printf '%s' "$3" | tr 'A-F' 'a-f')
	[ -f "$file" ] && [ ! -L "$file" ] || return 1
	case "$offset" in ""|*[!0-9]*) return 1 ;; esac
	is_hex "$data" || return 1
	length=$(( ${#data} / 2 ))
	file_size=$(stat -c %s "$file" 2>/dev/null) || return 1
	[ $((offset + length)) -le "$file_size" ] 2>/dev/null || return 1
	payload="/data/local/tmp/mho_mumu_plan_payload.$$.${offset}.bin"
	TEMP_FILES="$TEMP_FILES $payload"
	hex_to_file "$data" "$payload" || return 1
	dd if="$payload" of="$file" bs=1 seek="$offset" count="$length" conv=notrunc 2>/dev/null || return 1
	rm -f "$payload" 2>/dev/null || true
	return 0
}

apply_patch_plan() {
	local file plan offset data label applied
	file=$1
	plan=$2
	applied=0
	while IFS='|' read -r offset data label; do
		[ -n "$offset" ] || continue
		write_hex_at_file "$file" "$offset" "$data" || return 1
		applied=$((applied + 1))
	done < "$plan"
	[ "$applied" -eq "$PATCH_PLAN_COUNT" ] 2>/dev/null || return 1
	sync
	return 0
}

prepare_profiled_library() {
	local source output plan source_sha copy_sha source_size output_size saved_library rc
	source=$1
	output=$2
	plan=$3
	[ -f "$source" ] && [ ! -L "$source" ] || return 1
	source_sha=$(sha256_file "$source")
	is_sha256 "$source_sha" || return 1
	PREPARED_BASE_SHA=$source_sha
	source_size=$(stat -c %s "$source" 2>/dev/null) || return 1
	rm -f -- "$output" "$plan" 2>/dev/null || true
	cp -p "$source" "$output" 2>/dev/null || return 1
	chmod u+w "$output" 2>/dev/null || return 1
	copy_sha=$(sha256_file "$output")
	output_size=$(stat -c %s "$output" 2>/dev/null) || return 1
	[ "$copy_sha" = "$source_sha" ] && [ "$output_size" = "$source_size" ] || return 1

	saved_library=$LIBRARY
	LIBRARY=$output
	inspect_all_binary_patches
	if managed_binary_has_unknown_state; then
		LIBRARY=$saved_library
		return 2
	fi
	build_patch_plan "$plan" || {
		rc=$?
		LIBRARY=$saved_library
		return "$rc"
	}
	log_line "Prepared complete patch plan with $PATCH_PLAN_COUNT managed writes"
	apply_patch_plan "$output" "$plan" || {
		LIBRARY=$saved_library
		return 1
	}
	inspect_all_binary_patches
	if ! binary_profile_matches_desired; then
		LIBRARY=$saved_library
		return 1
	fi
	PREPARED_LIBRARY_SHA=$(sha256_file "$output")
	output_size=$(stat -c %s "$output" 2>/dev/null) || {
		LIBRARY=$saved_library
		return 1
	}
	LIBRARY=$saved_library
	is_sha256 "$PREPARED_LIBRARY_SHA" && [ "$output_size" = "$source_size" ]
}

extract_pristine_library() {
	destination=$1
	expected_sha=$2
	found_entry=0
	mismatch_hash=""

	for apk in $APK_PATHS; do
		rm -f "$destination" 2>/dev/null || true
		if unzip -p "$apk" "$APK_LIBRARY" > "$destination" 2>/dev/null && [ -s "$destination" ]; then
			found_entry=1
			actual_sha=$(sha256_file "$destination")
			if [ "$actual_sha" = "$expected_sha" ]; then
				PRISTINE_APK=$apk
				PRISTINE_SHA=$actual_sha
				return 0
			fi
			mismatch_hash=$actual_sha
		fi
	done

	rm -f "$destination" 2>/dev/null || true
	if [ "$found_entry" -eq 0 ]; then
		log_line "Pristine library entry not found in installed APKs: $APK_LIBRARY"
	else
		log_line "Pristine library checksum mismatch: got ${mismatch_hash:-unknown}, expected $expected_sha"
	fi
	return 1
}

repair_and_apply_profile() {
	local reason repair_attempt rc repair_version repair_root repair_profile repair_sha
	local repair_library repair_identity repair_live_sha repair_required pristine prepared plan
	reason=$1
	log_line "Transactional Repair requested: $reason"
	repair_attempt=1
	while [ "$repair_attempt" -le 3 ]; do
		refresh_context 0
		rc=$?
		if [ "$rc" -ne 0 ]; then
			[ "$rc" -ne 2 ] || log_line "Multiple profiles match installed version $VERSION"
			log_line "Cannot Repair: no valid exact profile for installed version ${VERSION:-unknown}"
			return 3
		fi
		reconcile_hp15 || { log_line "MuMu libhp15 compatibility could not be reconciled before Repair"; return 1; }
		inspect_hp15

		repair_version=$VERSION
		repair_root=$INSTALL_ROOT
		repair_profile=$PROFILE_ID
		repair_sha=$ORIGINAL_SHA256
		repair_library=$LIBRARY
		repair_identity=$(stat -c '%d:%i' "$repair_library" 2>/dev/null || true)
		repair_live_sha=$(sha256_file "$repair_library")
		repair_required=$DEVICE_CHECKS_REQUIRED
		[ -n "$repair_identity" ] && is_sha256 "$repair_live_sha" || return 1

		pristine="/data/local/tmp/mho_mumu_pristine.$$.${repair_attempt}.so"
		prepared="/data/local/tmp/mho_mumu_repair.$$.${repair_attempt}.so"
		plan="/data/local/tmp/mho_mumu_repair_plan.$$.${repair_attempt}.conf"
		TEMP_FILES="$TEMP_FILES $pristine $prepared $plan"
		log_line "Repair context: version=$repair_version profile=$repair_profile"
		extract_pristine_library "$pristine" "$repair_sha" || return 1
		log_line "Pristine APK library verified: $PRISTINE_SHA"

		# Extraction and complete profile preparation can take time. Recheck the
		# exact install before and after both operations so an app update can never
		# receive offsets prepared for the previous build.
		if ! detect_environment 0; then
			return 1
		fi
		if [ "$VERSION" != "$repair_version" ] || [ "$INSTALL_ROOT" != "$repair_root" ]; then
			log_line "Package changed during Repair ($repair_version -> $VERSION); restarting discovery"
			repair_attempt=$((repair_attempt + 1))
			continue
		fi
		select_profile || return 3
		if [ "$PROFILE_ID" != "$repair_profile" ] || [ "$LIBRARY" != "$repair_library" ]; then
			log_line "Profile or target changed during Repair; restarting discovery"
			repair_attempt=$((repair_attempt + 1))
			continue
		fi

		prepare_profiled_library "$pristine" "$prepared" "$plan"
		rc=$?
		if [ "$rc" -ne 0 ]; then
			[ "$rc" -ne 2 ] || log_line "Verified pristine library does not match the managed-byte profile"
			log_line "Repair profile preparation failed before any live library replacement"
			return 1
		fi

		refresh_context 0 || {
			log_line "Installed build changed or became unsupported before Repair publication"
			return 3
		}
		if [ "$VERSION" != "$repair_version" ] || [ "$INSTALL_ROOT" != "$repair_root" ] \
			|| [ "$PROFILE_ID" != "$repair_profile" ] || [ "$LIBRARY" != "$repair_library" ]; then
			log_line "Package changed while the Repair image was prepared; restarting discovery"
			repair_attempt=$((repair_attempt + 1))
			continue
		fi
		reconcile_hp15 || { log_line "MuMu libhp15 compatibility changed during Repair"; return 1; }
		inspect_hp15
		if [ "$DEVICE_CHECKS_REQUIRED" != "$repair_required" ]; then
			log_line "Device-check policy changed while the Repair image was prepared; restarting discovery"
			repair_attempt=$((repair_attempt + 1))
			continue
		fi
		if [ "$(stat -c '%d:%i' "$LIBRARY" 2>/dev/null || true)" != "$repair_identity" ] \
			|| [ "$(sha256_file "$LIBRARY")" != "$repair_live_sha" ]; then
			log_line "Live libUnreal.so changed while Repair was prepared; restarting from the current install"
			repair_attempt=$((repair_attempt + 1))
			continue
		fi

		atomic_install_library "$prepared" "$LIBRARY" "$PREPARED_LIBRARY_SHA" || {
			log_line "Atomic Repair publication failed"
			return 1
		}
		inspect_all_binary_patches
		binary_profile_matches_desired || {
			log_line "Published Repair image failed final managed-byte verification"
			return 1
		}
		cache_restore_context || return 1
		log_line "Repair completed: pristine base and complete configured profile published atomically"
		return 0
	done

	log_line "Package kept changing during Repair; no stale library image was published"
	return 1
}

restore_pristine_live() {
	local restore_attempt rc restore_version restore_root restore_profile restore_sha pristine installed_sha
	restore_attempt=1
	while [ "$restore_attempt" -le 3 ]; do
		refresh_context 0
		rc=$?
		if [ "$rc" -ne 0 ]; then
			[ "$rc" -ne 2 ] || log_line "Multiple profiles match installed version $VERSION"
			return 3
		fi

		restore_version=$VERSION
		restore_root=$INSTALL_ROOT
		restore_profile=$PROFILE_ID
		restore_sha=$ORIGINAL_SHA256
		pristine="/data/local/tmp/mho_mumu_restore.$$.so"
		TEMP_FILES="$TEMP_FILES $pristine"

		log_line "Restore context: version=$restore_version profile=$restore_profile"
		extract_pristine_library "$pristine" "$restore_sha" || return 1
		log_line "Pristine APK library verified: $PRISTINE_SHA"

		if ! detect_environment 0; then
			return 1
		fi
		if [ "$VERSION" != "$restore_version" ] || [ "$INSTALL_ROOT" != "$restore_root" ]; then
			log_line "Package changed during pristine restore ($restore_version -> $VERSION); restarting discovery"
			rm -f "$pristine" 2>/dev/null || true
			restore_attempt=$((restore_attempt + 1))
			continue
		fi

		select_profile || return 3
		[ "$PROFILE_ID" = "$restore_profile" ] || {
			log_line "Profile changed during pristine restore; restarting discovery"
			rm -f "$pristine" 2>/dev/null || true
			restore_attempt=$((restore_attempt + 1))
			continue
		}

		installed_sha=$(sha256_file "$LIBRARY")
		if [ "$installed_sha" = "$restore_sha" ]; then
			log_line "Installed libUnreal.so is already pristine and SHA-256 verified"
			return 0
		fi

		atomic_install_library "$pristine" "$LIBRARY" "$restore_sha" || return 1
		installed_sha=$(sha256_file "$LIBRARY")
		[ "$installed_sha" = "$restore_sha" ] || {
			log_line "Pristine restore checksum mismatch: got $installed_sha expected $restore_sha"
			return 1
		}

		cache_restore_context || return 1
		log_line "Original libUnreal.so restored atomically and SHA-256 verified; no patches reapplied"
		return 0
	done

	log_line "Package kept changing during pristine restore; no stale library was written"
	return 1
}

restore_pristine_offline() {
	local rc
	restore_pristine_from_cache
	rc=$?
	[ "$rc" -eq 0 ] && return 0
	[ "$rc" -eq 1 ] && log_line "Cached restore encountered an I/O/write failure; trying filesystem profile discovery"
	[ "$rc" -eq 2 ] && log_line "Cached restore context unavailable/stale; trying filesystem profile discovery"

	restore_pristine_from_filesystem
	rc=$?
	[ "$rc" -eq 0 ] && return 0
	[ "$rc" -eq 3 ] && log_line "A possible game-library target exists, but no checksum-verified pristine profile source could be recovered"
	return "$rc"
}

restore_pristine_only() {
	local reason rc compatibility_rc
	reason=${1:-requested}
	log_line "Pristine restore requested: $reason"
	compatibility_rc=0
	restore_hp15_override || {
		log_line "MuMu libhp15 override restore failed"
		compatibility_rc=1
	}
	restore_renderer_config || {
		log_line "Renderer configuration restore failed"
		compatibility_rc=1
	}
	[ "$compatibility_rc" -eq 0 ] || return 1

	case "$reason" in
		uninstall*|post-fs-data*|early-*)
			# KernelSU invokes uninstall.sh during post-fs-data, before Binder's
			# PackageManager is dependable. Use only direct filesystem state first.
			restore_pristine_offline
			rc=$?
			[ "$rc" -eq 0 ] && return 0
			log_line "Offline restore did not complete (code $rc); attempting live PackageManager discovery as fallback"
			;;
	esac

	/system/bin/am force-stop "$TARGET_PACKAGE" 2>/dev/null || true
	restore_pristine_live
	rc=$?
	[ "$rc" -eq 0 ] && return 0

	# Disable can be detected by the early watcher before PackageManager is up.
	# The cached/filesystem path is safe here as well and avoids a one-shot loss.
	log_line "Live restore unavailable/failed (code $rc); trying offline verified restore"
	restore_pristine_offline
	rc=$?
	if [ "$rc" -eq 2 ]; then
		log_line "No managed game-library target exists; pristine restore is not required"
		return 0
	fi
	return "$rc"
}

reconcile() {
	local wait_for_pm automatic_compat rc first_version first_root source_version source_root source_profile
	local source_library source_identity source_sha source_required prepared plan
	wait_for_pm=${1:-0}
	automatic_compat=${2:-0}

	if [ "$automatic_compat" -eq 1 ]; then
		reconcile_mumu_compatibility_automatic || return 1
	else
		reconcile_mumu_compatibility || return 1
	fi
	refresh_context "$wait_for_pm"
	rc=$?
	if [ "$rc" -ne 0 ]; then
		if [ "$rc" -eq 1 ]; then
			log_line "No supported exact profile for installed version ${VERSION:-unknown}; no binary changes made"
			return 3
		fi
		log_line "Could not select a safe profile for installed version ${VERSION:-unknown}; no binary changes made"
		return 3
	fi

	log_line "Installed package: $TARGET_PACKAGE"
	log_line "Detected version=$VERSION"
	log_line "Selected profile: $PROFILE_ID"
	log_line "Target library: $LIBRARY"
	if [ "$automatic_compat" -eq 1 ] && [ "$HP15_WATCHER_DISABLED" = "1" ]; then inspect_mumu_policy_only; else inspect_hp15; fi
	inspect_all_binary_patches
	log_line "Mandatory states:$MANDATORY_SUMMARY"
	log_line "Effective libhp15 state=$HP15_STATE source=$HP15_SOURCE path=$HP15_EFFECTIVE_PATH modify=$HP15_MODIFY required=$DEVICE_CHECKS_REQUIRED forced=$DEVICE_CHECKS_FORCED"
	log_line "Resolution ready=$RESOLUTION_PATCH_READY state=$RESOLUTION_STATE actual=${RESOLUTION_ACTUAL_SCALE:-unknown}% desired_enabled=$RESOLUTION_ENABLED desired_scale=$RESOLUTION_SCALE%"
	log_line "FPS ready=$FPS_PATCH_READY state=$FPS_STATE actual=${FPS_ACTUAL_TARGET:-unknown} desired_enabled=$FPS_ENABLED desired_target=$FPS_TARGET"
	log_line "PixelFlow ready=$PIXELFLOW_PATCH_READY state=$PIXELFLOW_STATE desired=$PIXELFLOW_MODE"
	log_line "GPM Device Level ready=$GPM_DEVICE_LEVEL_PATCH_READY state=$GPM_DEVICE_LEVEL_STATE desired_enabled=$GPM_DEVICE_LEVEL_ENABLED"
	log_line "Graphic Library ready=$GRAPHIC_LIBRARY_PATCH_READY state=$GRAPHIC_LIBRARY_STATE desired_enabled=$GRAPHIC_LIBRARY_ENABLED desired=$GRAPHIC_LIBRARY"
	log_line "Cross Platform ready=$CROSS_PLATFORM_PATCH_READY state=$CROSS_PLATFORM_STATE desired_enabled=$CROSS_PLATFORM_ENABLED desired=$CROSS_PLATFORM"
	log_line "GPU Display ready=$GPU_DISPLAY_PATCH_READY state=$GPU_DISPLAY_STATE desired_enabled=$GPU_DISPLAY_ENABLED"
	log_line "Hide UUID ready=$HIDE_UUID_PATCH_READY state=$HIDE_UUID_STATE desired_enabled=$HIDE_UUID_ENABLED"
	log_line "Controller Mode ready=$CONTROLLER_MODE_PATCH_READY state=$CONTROLLER_MODE_STATE desired_enabled=$CONTROLLER_MODE_ENABLED"
	log_line "Extended Watermark ready=$EXTENDED_WATERMARK_PATCH_READY state=$EXTENDED_WATERMARK_STATE desired_api=$GRAPHIC_API_DISPLAY_ENABLED desired_platform=$PLATFORM_DISPLAY_ENABLED"

	# Save and boot always trust the installed libUnreal.so as the base. Unknown
	# managed bytes are not silently replaced from the APK; explicit Repair is
	# the only operation authorized to start from the verified pristine image.
	if managed_binary_has_unknown_state; then
		log_line "Installed libUnreal.so contains unknown managed bytes; use Repair to rebuild it from the verified APK library"
		return 2
	fi
	if ! needs_reconcile_write; then
		log_line "All configured patches are already in the expected state"
		return 0
	fi

	first_version=$VERSION
	first_root=$INSTALL_ROOT
	refresh_context 0 || {
		log_line "Installed build changed or became unsupported before profile preparation"
		return 3
	}
	if [ "$VERSION" != "$first_version" ] || [ "$INSTALL_ROOT" != "$first_root" ]; then
		log_line "Package changed before profile preparation ($first_version -> $VERSION); using the newly detected exact profile"
	fi
	if [ "$automatic_compat" -eq 1 ] && [ "$HP15_WATCHER_DISABLED" = "1" ]; then inspect_mumu_policy_only; else inspect_hp15; fi
	inspect_all_binary_patches
	if managed_binary_has_unknown_state; then
		log_line "Installed libUnreal.so changed to an unknown managed state before preparation; use Repair"
		return 2
	fi
	if ! needs_reconcile_write; then
		log_line "Configured patch state became current before publication; no library replacement is needed"
		return 0
	fi

	source_version=$VERSION
	source_root=$INSTALL_ROOT
	source_profile=$PROFILE_ID
	source_library=$LIBRARY
	source_identity=$(stat -c '%d:%i' "$source_library" 2>/dev/null || true)
	source_sha=$(sha256_file "$source_library")
	source_required=$DEVICE_CHECKS_REQUIRED
	[ -n "$source_identity" ] && is_sha256 "$source_sha" || return 1
	prepared="/data/local/tmp/mho_mumu_save.$$.so"
	plan="/data/local/tmp/mho_mumu_save_plan.$$.conf"
	TEMP_FILES="$TEMP_FILES $prepared $plan"

	prepare_profiled_library "$source_library" "$prepared" "$plan"
	rc=$?
	if [ "$rc" -ne 0 ]; then
		if [ "$rc" -eq 2 ]; then
			log_line "The Save source developed unknown managed bytes during preparation; use Repair"
		else
			log_line "Complete Save profile preparation or validation failed; live libUnreal.so was not replaced"
		fi
		return "$rc"
	fi
	[ "$PREPARED_BASE_SHA" = "$source_sha" ] || {
		log_line "Save source changed while its complete profile was copied"
		return 1
	}

	refresh_context 0 || {
		log_line "Installed build changed or became unsupported before atomic Save publication"
		return 3
	}
	if [ "$VERSION" != "$source_version" ] || [ "$INSTALL_ROOT" != "$source_root" ] \
		|| [ "$PROFILE_ID" != "$source_profile" ] || [ "$LIBRARY" != "$source_library" ]; then
		log_line "Package or exact profile changed while the Save image was prepared; nothing was published"
		return 3
	fi
	if [ "$automatic_compat" -eq 1 ] && [ "$HP15_WATCHER_DISABLED" = "1" ]; then
		inspect_mumu_policy_only
	else
		reconcile_hp15 || { log_line "MuMu libhp15 compatibility changed before publication"; return 1; }
		inspect_hp15
	fi
	if [ "$DEVICE_CHECKS_REQUIRED" != "$source_required" ]; then
		log_line "Device-check policy changed while the Save image was prepared; nothing was published"
		return 1
	fi
	if [ "$(stat -c '%d:%i' "$LIBRARY" 2>/dev/null || true)" != "$source_identity" ] \
		|| [ "$(sha256_file "$LIBRARY")" != "$source_sha" ]; then
		log_line "Live libUnreal.so changed while the Save image was prepared; nothing was published"
		return 1
	fi

	atomic_install_library "$prepared" "$LIBRARY" "$PREPARED_LIBRARY_SHA" || {
		log_line "Atomic Save publication failed"
		return 1
	}
	inspect_all_binary_patches
	binary_profile_matches_desired || {
		log_line "Published Save image failed final managed-byte verification"
		return 1
	}
	cache_restore_context || return 1
	log_line "Complete configured patch profile published atomically and verified"
	return 0
}


print_status_legacy() {
	load_preferences
	if [ "$RENDERER_WATCHER_DISABLED" = "1" ]; then
		RENDERER_STATE="not_checked"
		RENDERER_SOURCE="watcher_disabled"
		RENDERER_EFFECTIVE_PATH="$RENDERER_DATA_CONFIG"
	else
		inspect_renderer_config
	fi
	if [ "$HP15_WATCHER_DISABLED" = "1" ]; then
		inspect_mumu_policy_only
	else
		inspect_hp15
	fi
	detected=0
	supported=0
	RESOLUTION_PATCH_READY=0
	FPS_PATCH_READY=0
	PIXELFLOW_PATCH_READY=0
	GPM_DEVICE_LEVEL_PATCH_READY=0
	GRAPHIC_LIBRARY_PATCH_READY=0
	CROSS_PLATFORM_PATCH_READY=0
	GPU_DISPLAY_PATCH_READY=0
	HIDE_UUID_PATCH_READY=0
	CONTROLLER_MODE_PATCH_READY=0
	EXTENDED_WATERMARK_PATCH_READY=0

	if detect_environment 0; then
		detected=1
		if select_profile; then
			supported=1
			inspect_mandatory
			inspect_resolution
			inspect_fps
			inspect_gpm_device_level
			inspect_graphic_library
			inspect_cross_platform
			inspect_gpu_display
			inspect_hide_uuid
			inspect_controller_mode
			inspect_extended_watermark
			inspect_pixelflow
		else
			PATCH_COUNT=0; CONTEXT_TOKEN=""; LIBRARY=""; SELECTED_PROFILE=""; PROFILE_ID=""
		fi
	else
		VERSION="not-installed"
	fi

	if [ "$RENDERER_WATCHER_DISABLED" != 1 ]; then
		inspect_renderer_config
	fi
	print_advanced_defaults
	printf 'pixelflow_patch_ready=%s\n' "$PIXELFLOW_PATCH_READY"
	printf 'pixelflow_saved_mode=%s\n' "$PIXELFLOW_MODE"
	printf 'pixelflow_saved_choice=%s\n' "$PIXELFLOW_CHOICE"
	printf 'pixelflow_state=%s\n' "${PIXELFLOW_STATE:-unavailable}"
	print_multi_status
	printf 'module_version=1.4.2\n'
	printf 'package_detected=%s\n' "$detected"
	printf 'game_version=%s\n' "${VERSION:-unknown}"
	printf 'profile_supported=%s\n' "$supported"
	printf 'profile_id=%s\n' "${PROFILE_ID:-}"
	printf 'resolution_patch_ready=%s\n' "${RESOLUTION_PATCH_READY:-0}"
	printf 'fps_patch_ready=%s\n' "${FPS_PATCH_READY:-0}"
	printf 'fps_patch_kind=%s\n' "${FPS_PATCH_KIND:-legacy}"
	printf 'gpm_device_level_patch_ready=%s\n' "${GPM_DEVICE_LEVEL_PATCH_READY:-0}"
	printf 'graphic_library_patch_ready=%s\n' "${GRAPHIC_LIBRARY_PATCH_READY:-0}"
	printf 'cross_platform_patch_ready=%s\n' "${CROSS_PLATFORM_PATCH_READY:-0}"
	printf 'gpu_display_patch_ready=%s\n' "${GPU_DISPLAY_PATCH_READY:-0}"
	printf 'hide_uuid_patch_ready=%s\n' "${HIDE_UUID_PATCH_READY:-0}"
	printf 'controller_mode_patch_ready=%s\n' "${CONTROLLER_MODE_PATCH_READY:-0}"
	printf 'extended_watermark_patch_ready=%s\n' "${EXTENDED_WATERMARK_PATCH_READY:-0}"
	# Backward-compatible alias for cached 1.2.3/early-1.2.4 WebUI code.
	printf 'graphic_api_display_patch_ready=%s\n' "${EXTENDED_WATERMARK_PATCH_READY:-0}"
	printf 'resolution_saved_enabled=%s\n' "$RESOLUTION_ENABLED"
	printf 'resolution_saved_scale=%s\n' "$RESOLUTION_SCALE"
	printf 'fps_saved_enabled=%s\n' "$FPS_ENABLED"
	printf 'fps_saved_target=%s\n' "$FPS_TARGET"
	printf 'gpm_device_level_saved_enabled=%s\n' "$GPM_DEVICE_LEVEL_ENABLED"
	printf 'graphic_library_saved_enabled=%s\n' "$GRAPHIC_LIBRARY_ENABLED"
	printf 'graphic_library_saved=%s\n' "$GRAPHIC_LIBRARY"
	printf 'cross_platform_saved_enabled=%s\n' "$CROSS_PLATFORM_ENABLED"
	printf 'cross_platform_saved=%s\n' "$CROSS_PLATFORM"
	printf 'gpu_display_saved_enabled=%s\n' "$GPU_DISPLAY_ENABLED"
	printf 'hide_uuid_saved_enabled=%s\n' "$HIDE_UUID_ENABLED"
	printf 'controller_mode_saved_enabled=%s\n' "$CONTROLLER_MODE_ENABLED"
	printf 'graphic_api_display_saved_enabled=%s\n' "$GRAPHIC_API_DISPLAY_ENABLED"
	printf 'platform_display_saved_enabled=%s\n' "$PLATFORM_DISPLAY_ENABLED"
	printf 'device_checks_saved_forced=%s\n' "$DEVICE_CHECKS_FORCED"
	printf 'mandatory_hp15_saved_disabled=%s\n' "$MANDATORY_HP15_DISABLED"
	printf 'mandatory_patch_1_saved_disabled=%s\n' "$MANDATORY_PATCH_1_DISABLED"
	printf 'mandatory_patch_2_saved_disabled=%s\n' "$MANDATORY_PATCH_2_DISABLED"
	printf 'mandatory_renderer_saved_disabled=%s\n' "$MANDATORY_RENDERER_DISABLED"
	printf 'hp15_watcher_saved_disabled=%s\n' "$HP15_WATCHER_DISABLED"
	printf 'renderer_watcher_saved_disabled=%s\n' "$RENDERER_WATCHER_DISABLED"
	printf 'device_checks_required=%s\n' "$DEVICE_CHECKS_REQUIRED"
	printf 'mumu_detected=%s\n' "$MUMU_DETECTED"
	printf 'hp15_state=%s\n' "$HP15_STATE"
	printf 'hp15_override_active=%s\n' "$HP15_OVERRIDE_ACTIVE"
	printf 'hp15_override_required=%s\n' "$HP15_OVERRIDE_REQUIRED"
	printf 'hp15_source=%s\n' "$HP15_SOURCE"
	printf 'hp15_effective_path=%s\n' "$HP15_EFFECTIVE_PATH"
	printf 'hp15_modify=%s\n' "$HP15_MODIFY"
	printf 'hp15_mtime_epoch=%s\n' "$HP15_MTIME_EPOCH"
	printf 'renderer_config_state=%s\n' "$RENDERER_STATE"
	printf 'renderer_config_source=%s\n' "$RENDERER_SOURCE"
	printf 'renderer_config_path=%s\n' "$RENDERER_EFFECTIVE_PATH"

	if [ "$supported" -eq 1 ]; then
		printf 'library=%s\n' "$LIBRARY"
		printf 'mandatory_unknown=%s\n' "$MANDATORY_UNKNOWN"
		index=1
		while [ "$index" -le "$PATCH_COUNT" ]; do
			eval name='${MANDATORY_'"$index"'_NAME}'
			eval state='${MANDATORY_'"$index"'_STATE}'
			display_state=$state
			if [ "$DEVICE_CHECKS_REQUIRED" -eq 0 ] && [ "$DEVICE_CHECKS_FORCED" -eq 0 ] && [ "$state" = "original" ]; then
				display_state="not_required"
			fi
			printf 'patch_%s_name=%s\n' "$index" "$name"
			printf 'patch_%s_state=%s\n' "$index" "$display_state"
			printf 'patch_%s_raw_state=%s\n' "$index" "$state"
			index=$((index + 1))
		done
		printf 'resolution_state=%s\n' "$RESOLUTION_STATE"
		printf 'resolution_actual_scale=%s\n' "${RESOLUTION_ACTUAL_SCALE:-}"
		printf 'fps_state=%s\n' "$FPS_STATE"
		printf 'fps_actual_target=%s\n' "${FPS_ACTUAL_TARGET:-}"
		printf 'gpm_device_level_state=%s\n' "$GPM_DEVICE_LEVEL_STATE"
		printf 'graphic_library_state=%s\n' "$GRAPHIC_LIBRARY_STATE"
		printf 'cross_platform_state=%s\n' "$CROSS_PLATFORM_STATE"
		printf 'gpu_display_state=%s\n' "$GPU_DISPLAY_STATE"
		printf 'hide_uuid_state=%s\n' "$HIDE_UUID_STATE"
		printf 'controller_mode_state=%s\n' "$CONTROLLER_MODE_STATE"
		printf 'extended_watermark_state=%s\n' "$EXTENDED_WATERMARK_STATE"
		case "$EXTENDED_WATERMARK_STATE" in
			api|both|legacy_api) legacy_api_state=applied ;;
			platform|original) legacy_api_state=original ;;
			*) legacy_api_state="$EXTENDED_WATERMARK_STATE" ;;
		esac
		printf 'graphic_api_display_state=%s\n' "$legacy_api_state"
	else
		printf 'mandatory_unknown=0\n'
		printf 'patch_1_name=OnCheckDeviceLevel\n'
		printf 'patch_1_state=unsupported\n'
		printf 'patch_1_raw_state=unsupported\n'
		printf 'patch_2_name=OnCheckSystemInfo\n'
		printf 'patch_2_state=unsupported\n'
		printf 'patch_2_raw_state=unsupported\n'
		printf 'resolution_state=unavailable\n'
		printf 'resolution_actual_scale=\n'
		printf 'fps_state=unavailable\n'
		printf 'fps_actual_target=\n'
		printf 'gpm_device_level_state=unavailable\n'
		printf 'graphic_library_state=unavailable\n'
		printf 'cross_platform_state=unavailable\n'
		printf 'gpu_display_state=unavailable\n'
		printf 'hide_uuid_state=unavailable\n'
		printf 'controller_mode_state=unavailable\n'
		printf 'extended_watermark_state=unavailable\n'
		printf 'graphic_api_display_state=unavailable\n'
	fi
	# IgnoreGLError + UE streaming status (independent of profile support).
	gler_inspect_pkg
	printf 'mandatory_gler_saved_disabled=%s\n' "${MANDATORY_GLER_DISABLED:-0}"
	printf 'gler_state=%s\n' "$GLER_STATE"
	printf 'ueini_state=%s\n' "$(ueini_inspect)"
}

# ---------------------------------------------------------------------------
# UE Engine.ini streaming fix (experimental, per game).
# Adds/removes a marker-delimited [SystemSettings] block in the game's
# Android Engine.ini. Never touches anything outside the package's data dir.
ueini_record_file() { printf '%s/ueini.conf' "$GAME_DIR"; }

ueini_inspect() {
	local record dir file
	record=$(ueini_record_file)
	[ -f "$record" ] || { printf 'disabled'; return 0; }
	dir=$(scalar_value "$record" dir)
	file=$(scalar_value "$record" file)
	case "$dir" in
		"$UEINI_DATA_ROOT/$TARGET_PACKAGE"/*) ;;
		*) printf 'stale'; return 0 ;;
	esac
	[ "$file" = "$dir/Engine.ini" ] || { printf 'stale'; return 0; }
	if [ -f "$file" ] && grep -q "^$UEINI_MARKER_BEGIN\$" "$file" 2>/dev/null; then
		printf 'applied'
	else
		printf 'stale'
	fi
}

ueini_config_dir() {
	local base dir
	base="$UEINI_DATA_ROOT/$TARGET_PACKAGE/files"
	[ -d "$base/UnrealGame" ] || return 1
	for dir in "$base/UnrealGame"/*/Saved/Config/Android "$base/UnrealGame"/*/*/Saved/Config/Android; do
		[ -d "$dir" ] || continue
		printf '%s\n' "$dir"
		return 0
	done
	return 1
}

ueini_write_block() {
	printf '%s\n' "$UEINI_MARKER_BEGIN" "[/SystemSettings]" \
		"r.Streaming.PoolSize=1024" "r.DynamicRes.OperationMode=0" "$UEINI_MARKER_END"
}

ueini_strip_block() {
	sed "/^$UEINI_MARKER_BEGIN\$/,/^$UEINI_MARKER_END\$/d" "$1"
}

ueini_install_file() {
	local tmp=$1 dest=$2 dir mode uid gid stage
	dir=${dest%/*}
	if [ -f "$dest" ]; then
		mode=$(stat -c %a "$dest") || return 1
		uid=$(stat -c %u "$dest") || return 1
		gid=$(stat -c %g "$dest") || return 1
	else
		mode=600
		uid=$(stat -c %u "$dir") || return 1
		gid=$(stat -c %g "$dir") || return 1
	fi
	stage="$dest.mhottmp"
	cp "$tmp" "$stage" || return 1
	chmod "$mode" "$stage" && chown "$uid:$gid" "$stage" || { rm -f "$stage"; return 1; }
	mv -f "$stage" "$dest" || { rm -f "$stage"; return 1; }
	return 0
}

do_ueini() {
	local action=${1:-} record dir file tmp created
	case "$action" in on|off) ;; *) fail "UE streaming fix action must be on or off" ;; esac
	[ ! -f "$MODDIR/disable" ] && [ ! -f "$MODDIR/remove" ] || fail "Module is disabled"
	record=$(ueini_record_file)
	if [ "$action" = off ]; then
		[ -f "$record" ] || { log_line "UE streaming fix is not enabled for $TARGET_PACKAGE"; printf 'ueini_state=disabled\n'; return 0; }
		dir=$(scalar_value "$record" dir)
		file=$(scalar_value "$record" file)
		case "$dir" in
			"$UEINI_DATA_ROOT/$TARGET_PACKAGE"/*) ;;
			*) fail "Stored UE config path is invalid; refusing to modify anything" ;;
		esac
		[ "$file" = "$dir/Engine.ini" ] || fail "Stored UE config path is invalid; refusing to modify anything"
		if [ -f "$file" ]; then
			tmp="$GAME_DIR/.ueini.$$.tmp"; TEMP_FILES="$TEMP_FILES $tmp"
			ueini_strip_block "$file" > "$tmp" || fail "Could not read Engine.ini"
			if [ -s "$tmp" ]; then
				ueini_install_file "$tmp" "$file" || fail "Could not write Engine.ini"
			else
				rm -f "$file"
			fi
			rm -f "$tmp"
		fi
		rm -f "$record"
		log_line "UE streaming fix disabled for $TARGET_PACKAGE"
		printf 'ueini_state=disabled\n'
		return 0
	fi
	dir=$(ueini_config_dir) || fail "UE Android config directory not found for $TARGET_PACKAGE; launch the game once and retry"
	file="$dir/Engine.ini"
	created=0
	[ -f "$file" ] || created=1
	if [ -f "$record" ] && [ "$(scalar_value "$record" created)" = 1 ]; then created=1; fi
	if [ "$created" = 0 ] && [ ! -f "$GAME_DIR/Engine.ini.orig" ]; then
		cp -p "$file" "$GAME_DIR/Engine.ini.orig" || fail "Could not back up Engine.ini"
	fi
	tmp="$GAME_DIR/.ueini.$$.tmp"; TEMP_FILES="$TEMP_FILES $tmp"
	if [ -f "$file" ]; then
		ueini_strip_block "$file" > "$tmp" || fail "Could not read Engine.ini"
	else
		: > "$tmp"
	fi
	if [ -s "$tmp" ]; then printf '\n' >> "$tmp"; fi
	ueini_write_block >> "$tmp" || fail "Could not build Engine.ini"
	ueini_install_file "$tmp" "$file" || fail "Could not write Engine.ini"
	rm -f "$tmp"
	tmp="$record.$$.tmp"; TEMP_FILES="$TEMP_FILES $tmp"
	printf 'enabled=1\ncreated=%s\ndir=%s\nfile=%s\n' "$created" "$dir" "$file" > "$tmp" \
		&& chmod 0600 "$tmp" && mv -f "$tmp" "$record" || fail "Could not save UE streaming state"
	log_line "UE streaming fix enabled for $TARGET_PACKAGE"
	printf 'ueini_state=applied\n'
	return 0
}

# Reset the game's cached GPU identity (shared_prefs/apm_cfg.xml) after the
# MuMu GPU model changes. One backup copy is kept under the game's state dir.
do_gpu_cache_reset() {
	local target backup_root backup_dir now n
	target="$GPU_CACHE_DATA_ROOT/$TARGET_PACKAGE/shared_prefs/apm_cfg.xml"
	[ ! -L "$target" ] || fail "Refusing to modify a symlink: $target"
	if [ ! -f "$target" ]; then
		log_line "No cached GPU identity found for $TARGET_PACKAGE"
		printf 'gpu_cache_reset=missing\npath=%s\n' "$target"
		return 0
	fi
	backup_root="$GAME_DIR/apm_cache"
	now=$(date +%Y%m%d_%H%M%S)
	backup_dir="$backup_root/$now"
	n=0
	while [ -d "$backup_dir" ]; do n=$((n + 1)); backup_dir="$backup_root/${now}_$n"; done
	mkdir -p "$backup_root" "$backup_dir" || fail "Could not create backup directory"
	chmod 0700 "$backup_root" "$backup_dir" || fail "Could not secure backup directory"
	cp -p "$target" "$backup_dir/apm_cfg.xml" || fail "Could not back up the GPU cache"
	rm -f "$target" || fail "Could not remove the GPU cache"
	/system/bin/am force-stop "$TARGET_PACKAGE" 2>/dev/null || true
	log_line "Reset cached GPU identity for $TARGET_PACKAGE (backup kept in $backup_dir)"
	printf 'gpu_cache_reset=removed\nbackup=%s\npath=%s\n' "$backup_dir/apm_cfg.xml" "$target"
	return 0
}

validate_requested_settings() {
	enabled=$1
	scale=$2
	fps_enabled=$3
	fps_target=$4
	gpm_device_level_enabled=$5
	gpu_display_enabled=$6
	graphic_library_enabled=$7
	graphic_library=$8
	device_checks_forced=$9
	mandatory_hp15_disabled=${10}
	mandatory_patch_1_disabled=${11}
	mandatory_patch_2_disabled=${12}
	mandatory_renderer_disabled=${13}
	graphic_api_display_enabled=${14}
	cross_platform_enabled=${15}
	cross_platform=${16}
	hp15_watcher_disabled=${17}
	renderer_watcher_disabled=${18}
	platform_display_enabled=${19}
	pixelflow_mode=${20:-original}
	pixelflow_choice=${21:-enabled}
	hide_uuid_enabled=${22:-${HIDE_UUID_ENABLED:-0}}
	controller_mode_enabled=${23:-${CONTROLLER_MODE_ENABLED:-0}}
	case "$pixelflow_mode" in enabled|disabled) pixelflow_choice=$pixelflow_mode ;; esac
	[ "$enabled" = "0" ] || [ "$enabled" = "1" ] || fail "Resolution enabled must be 0 or 1"
	case "$scale" in ""|*[!0-9]*) fail "Resolution scale must be an integer from 10 to 200" ;; esac
	[ "$scale" -ge 10 ] 2>/dev/null && [ "$scale" -le 200 ] 2>/dev/null || fail "Resolution scale must be from 10 to 200"
	[ "$fps_enabled" = "0" ] || [ "$fps_enabled" = "1" ] || fail "FPS enabled must be 0 or 1"
	case "$fps_target" in ""|*[!0-9]*) fail "FPS target must be an integer from 20 to 240" ;; esac
	[ "$fps_target" -ge "$FPS_MIN" ] 2>/dev/null && [ "$fps_target" -le "$FPS_MAX" ] 2>/dev/null || fail "FPS target must be from 20 to 240; values above 240 are intentionally blocked by the backend safety limit"
	[ "$gpm_device_level_enabled" = "0" ] || [ "$gpm_device_level_enabled" = "1" ] || fail "GPM Device Level enabled must be 0 or 1"
	[ "$gpu_display_enabled" = "0" ] || [ "$gpu_display_enabled" = "1" ] || fail "GPU Display enabled must be 0 or 1"
	[ "$hide_uuid_enabled" = "0" ] || [ "$hide_uuid_enabled" = "1" ] || fail "Hide UUID enabled must be 0 or 1"
	[ "$controller_mode_enabled" = "0" ] || [ "$controller_mode_enabled" = "1" ] || fail "Controller Mode enabled must be 0 or 1"
	[ "$graphic_library_enabled" = "0" ] || [ "$graphic_library_enabled" = "1" ] || fail "Graphic Library enabled must be 0 or 1"
	case "$graphic_library" in opengl|vulkan) ;; *) fail "Graphic Library must be opengl or vulkan" ;; esac
	[ "$device_checks_forced" = "0" ] || [ "$device_checks_forced" = "1" ] || fail "Device-check Force must be 0 or 1"
	[ "$mandatory_hp15_disabled" = "0" ] || [ "$mandatory_hp15_disabled" = "1" ] || fail "Mandatory libhp15 disable must be 0 or 1"
	[ "$mandatory_patch_1_disabled" = "0" ] || [ "$mandatory_patch_1_disabled" = "1" ] || fail "OnCheckDeviceLevel disable must be 0 or 1"
	[ "$mandatory_patch_2_disabled" = "0" ] || [ "$mandatory_patch_2_disabled" = "1" ] || fail "OnCheckSystemInfo disable must be 0 or 1"
	[ "$mandatory_renderer_disabled" = "0" ] || [ "$mandatory_renderer_disabled" = "1" ] || fail "MuMu Shader Compatibility disable must be 0 or 1"
	[ "$graphic_api_display_enabled" = "0" ] || [ "$graphic_api_display_enabled" = "1" ] || fail "Graphic API Display enabled must be 0 or 1"
	[ "$cross_platform_enabled" = "0" ] || [ "$cross_platform_enabled" = "1" ] || fail "Cross Platform enabled must be 0 or 1"
	case "$cross_platform" in pc|mobile|console) ;; *) fail "Cross Platform must be PC, Mobile or Console" ;; esac
	[ "$hp15_watcher_disabled" = "0" ] || [ "$hp15_watcher_disabled" = "1" ] || fail "libhp15 watcher disable must be 0 or 1"
	[ "$renderer_watcher_disabled" = "0" ] || [ "$renderer_watcher_disabled" = "1" ] || fail "MuMu Shader Compatibility watcher disable must be 0 or 1"
	[ "$platform_display_enabled" = "0" ] || [ "$platform_display_enabled" = "1" ] || fail "Platform watermark display enabled must be 0 or 1"
	case "$pixelflow_mode" in original|enabled|disabled) ;; *) fail "PixelFlow must be original, enabled or disabled" ;; esac
	case "$pixelflow_choice" in enabled|disabled) ;; *) fail "PixelFlow choice must be enabled or disabled" ;; esac
}


save_mumu_compatibility_preferences_only() {
	local hp15_disabled renderer_disabled hp15_watcher_disabled renderer_watcher_disabled
	hp15_disabled=$1
	renderer_disabled=$2
	hp15_watcher_disabled=$3
	renderer_watcher_disabled=$4
	load_preferences
	save_preferences "$RESOLUTION_ENABLED" "$RESOLUTION_SCALE" "$FPS_ENABLED" "$FPS_TARGET" \
		"$GPM_DEVICE_LEVEL_ENABLED" "$GPU_DISPLAY_ENABLED" "$GRAPHIC_LIBRARY_ENABLED" "$GRAPHIC_LIBRARY" \
		"$DEVICE_CHECKS_FORCED" "$hp15_disabled" "$MANDATORY_PATCH_1_DISABLED" "$MANDATORY_PATCH_2_DISABLED" "$renderer_disabled" "$GRAPHIC_API_DISPLAY_ENABLED" \
		"$CROSS_PLATFORM_ENABLED" "$CROSS_PLATFORM" "$hp15_watcher_disabled" "$renderer_watcher_disabled" "$PLATFORM_DISPLAY_ENABLED" "$PIXELFLOW_MODE" "$PIXELFLOW_CHOICE" "$HIDE_UUID_ENABLED" "$CONTROLLER_MODE_ENABLED"
}


set_desired_runtime() {
	RESOLUTION_ENABLED=$1
	RESOLUTION_SCALE=$2
	FPS_ENABLED=$3
	FPS_TARGET=$4
	GPM_DEVICE_LEVEL_ENABLED=$5
	GPU_DISPLAY_ENABLED=$6
	GRAPHIC_LIBRARY_ENABLED=$7
	GRAPHIC_LIBRARY=$8
	DEVICE_CHECKS_FORCED=$9
	MANDATORY_HP15_DISABLED=${10}
	MANDATORY_PATCH_1_DISABLED=${11}
	MANDATORY_PATCH_2_DISABLED=${12}
	MANDATORY_RENDERER_DISABLED=${13}
	GRAPHIC_API_DISPLAY_ENABLED=${14}
	CROSS_PLATFORM_ENABLED=${15}
	CROSS_PLATFORM=${16}
	HP15_WATCHER_DISABLED=${17}
	RENDERER_WATCHER_DISABLED=${18}
	PLATFORM_DISPLAY_ENABLED=${19}
	PIXELFLOW_MODE=${20:-original}
	PIXELFLOW_CHOICE=${21:-enabled}
	HIDE_UUID_ENABLED=${22:-${HIDE_UUID_ENABLED:-0}}
	CONTROLLER_MODE_ENABLED=${23:-${CONTROLLER_MODE_ENABLED:-0}}
	case "$PIXELFLOW_MODE" in enabled|disabled) PIXELFLOW_CHOICE=$PIXELFLOW_MODE ;; esac
	ADVANCED_REQUEST_EXPLICIT=1
}

