#!/system/bin/sh

# MHO MuMu Patcher 1.4.2
# Persistent-in-this-boot lifecycle watcher. It is launched once while the
# module is enabled, remains alive after a Disable marker appears, restores the
# pristine library with retries, and can re-apply the configured state if the
# module is re-enabled before reboot.

MODDIR=${0%/*}
STATE_DIR="/data/adb/mho_mumu_patcher"
WATCH_DIR="$STATE_DIR/disable_watcher.lock"
STATUS_FILE="$STATE_DIR/status.log"
PREF_FILE="$STATE_DIR/shared/preferences.conf"
RENDERER_DATA_CONFIG="/data/system/etc/mumu-configs/renderer.config"

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
chmod 0700 "$STATE_DIR" 2>/dev/null || true

current_boot_id() {
	cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf 'unknown\n'
}

proc_start_ticks() {
	pid=$1
	[ -r "/proc/$pid/stat" ] || return 1
	awk '{print $22}' "/proc/$pid/stat" 2>/dev/null | head -n 1
}

watch_owner_is_live() {
	owner=$(cat "$WATCH_DIR/pid" 2>/dev/null || true)
	owner_boot=$(cat "$WATCH_DIR/boot_id" 2>/dev/null || true)
	owner_ticks=$(cat "$WATCH_DIR/start_ticks" 2>/dev/null || true)
	[ -n "$owner" ] && [ -n "$owner_boot" ] && [ -n "$owner_ticks" ] || return 1
	[ "$owner_boot" = "$(current_boot_id)" ] || return 1
	kill -0 "$owner" 2>/dev/null || return 1
	now_ticks=$(proc_start_ticks "$owner" 2>/dev/null || true)
	[ -n "$now_ticks" ] && [ "$now_ticks" = "$owner_ticks" ]
}

watch_is_mine() {
	owner=$(cat "$WATCH_DIR/pid" 2>/dev/null || true)
	owner_boot=$(cat "$WATCH_DIR/boot_id" 2>/dev/null || true)
	owner_ticks=$(cat "$WATCH_DIR/start_ticks" 2>/dev/null || true)
	my_ticks=$(proc_start_ticks "$$" 2>/dev/null || true)
	[ "$owner" = "$$" ] \
		&& [ "$owner_boot" = "$(current_boot_id)" ] \
		&& [ -n "$my_ticks" ] && [ "$owner_ticks" = "$my_ticks" ]
}

claim_watch() {
	tries=0
	while ! mkdir "$WATCH_DIR" 2>/dev/null; do
		if watch_owner_is_live; then
			return 1
		fi

		# Complete metadata that fails boot-id/PID/start-time validation is
		# definitively stale and can be removed immediately. Only an incomplete
		# lock gets a short publication grace period.
		if [ -s "$WATCH_DIR/pid" ] && [ -s "$WATCH_DIR/boot_id" ] && [ -s "$WATCH_DIR/start_ticks" ]; then
			rm -rf -- "$WATCH_DIR" 2>/dev/null || return 1
			tries=0
			continue
		fi

		tries=$((tries + 1))
		if [ "$tries" -lt 3 ]; then
			sleep 1
			continue
		fi
		rm -rf -- "$WATCH_DIR" 2>/dev/null || return 1
		tries=0
	done

	my_ticks=$(proc_start_ticks "$$" 2>/dev/null || true)
	[ -n "$my_ticks" ] || { rm -rf -- "$WATCH_DIR" 2>/dev/null || true; return 1; }
	{
		printf '%s\n' "$$" > "$WATCH_DIR/pid" &&
		printf '%s\n' "$(current_boot_id)" > "$WATCH_DIR/boot_id" &&
		printf '%s\n' "$my_ticks" > "$WATCH_DIR/start_ticks"
	} 2>/dev/null || {
		rm -rf -- "$WATCH_DIR" 2>/dev/null || true
		return 1
	}
	chmod 0700 "$WATCH_DIR" 2>/dev/null || true
	chmod 0600 "$WATCH_DIR/pid" "$WATCH_DIR/boot_id" "$WATCH_DIR/start_ticks" 2>/dev/null || true
	return 0
}

release_watch() {
	owner=$(cat "$WATCH_DIR/pid" 2>/dev/null || true)
	owner_boot=$(cat "$WATCH_DIR/boot_id" 2>/dev/null || true)
	owner_ticks=$(cat "$WATCH_DIR/start_ticks" 2>/dev/null || true)
	my_ticks=$(proc_start_ticks "$$" 2>/dev/null || true)
	if [ "$owner" = "$$" ] \
		&& [ "$owner_boot" = "$(current_boot_id)" ] \
		&& [ -n "$my_ticks" ] && [ "$owner_ticks" = "$my_ticks" ]; then
		rm -rf -- "$WATCH_DIR" 2>/dev/null || true
	fi
}

log_watch() {
	msg=$*
	stamp=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)
	printf '%s | WATCHER: %s\n' "$stamp" "$msg" >> "$STATUS_FILE" 2>/dev/null || true
	/system/bin/log -t MHO_PATCH "$msg" 2>/dev/null || true
}

refresh_watcher_defaults() {
	# Read-only backend resolution; never source data as shell code.
	WATCHER_DEFAULTS=$("$MODDIR/apply_patch.sh" advanced-defaults 2>/dev/null) || WATCHER_DEFAULTS=""
}

watcher_disabled() {
	local key value
	key=$1
	value=""
	[ ! -f "$PREF_FILE" ] || value=$(sed -n 's/^'"$key"'=\([01]\)$/\1/p' "$PREF_FILE" | head -n 1)
	[ -n "$value" ] || value=$(printf '%s\n' "$WATCHER_DEFAULTS" | sed -n 's/^'"$key"'=\([01]\)$/\1/p' | head -n 1)
	# A failed query is retried at the next tick without inspecting either path.
	[ "${value:-1}" = "1" ]
}

renderer_fingerprint() {
	if [ -L "$RENDERER_DATA_CONFIG" ]; then
		printf 'symlink\n'
	elif [ -f "$RENDERER_DATA_CONFIG" ]; then
		stat -c '%i:%s:%Y:%Z' "$RENDERER_DATA_CONFIG" 2>/dev/null || printf 'unreadable\n'
	elif [ -e "$RENDERER_DATA_CONFIG" ]; then
		printf 'other\n'
	else
		printf 'missing\n'
	fi
}

on_term() {
	release_watch
	trap - EXIT HUP INT TERM
	exit "$1"
}

claim_watch || exit 0
trap release_watch EXIT
trap 'on_term 129' HUP
trap 'on_term 130' INT
trap 'on_term 143' TERM

restore_verified=0
reapply_needed=0
retry_delay=2
mumu_tick=0
renderer_watch_ready=0
renderer_last_fp=""
refresh_watcher_defaults

"$MODDIR/apply_patch.sh" hp15-watch >/dev/null 2>&1 || log_watch "Initial MuMu libhp15 check failed"

while [ -d "$MODDIR" ]; do
	# If state cleanup/replacement removed our ownership record, this process
	# must not continue as an untracked second watcher.
	watch_is_mine || exit 0

	disabled=0
	removing=0
	[ -f "$MODDIR/disable" ] && disabled=1
	[ -f "$MODDIR/remove" ] && removing=1

	if [ "$disabled" -eq 1 ] || [ "$removing" -eq 1 ]; then
		if [ "$restore_verified" -eq 0 ]; then
			if [ "$removing" -eq 1 ]; then
				reason="remove-marker"
			else
				reason="disable-marker"
			fi
			log_watch "$reason detected; restoring libUnreal.so, renderer.config and MuMu libhp15"
			# A partial restore also requires reapplication if the module is re-enabled.
			reapply_needed=1
			"$MODDIR/apply_patch.sh" restore "$reason"
			rc=$?
			if [ "$rc" -eq 0 ]; then
				restore_verified=1
				reapply_needed=1
				retry_delay=2
				log_watch "Pristine game library and MuMu compatibility state verified while module is inactive"
			else
				log_watch "Pristine restore failed with code $rc; retrying in ${retry_delay}s"
				sleep "$retry_delay"
				[ "$retry_delay" -ge 15 ] || retry_delay=$((retry_delay + 2))
				continue
			fi
		fi

		# Do not exit here. Keeping the already-running watcher alive lets us
		# detect Disable -> Enable in the same boot even though KernelSU will no
		# longer launch new scripts for the disabled module.
		sleep 1
		continue
	fi

	# No disable/remove marker means the module is active. If we restored it
	# earlier in this boot, re-apply the saved configuration before returning to
	# normal monitoring. Retry rather than leaving an enabled-but-pristine state.
	if [ "$reapply_needed" -eq 1 ]; then
		log_watch "Module re-enabled; re-applying configured patches"
		"$MODDIR/apply_patch.sh" boot
		rc=$?
		if [ "$rc" -eq 0 ]; then
			reapply_needed=0
			restore_verified=0
			retry_delay=2
			renderer_watch_ready=0
			log_watch "Configured patches verified after re-enable"
		else
			log_watch "Re-apply after re-enable failed with code $rc; retrying in ${retry_delay}s"
			sleep "$retry_delay"
			[ "$retry_delay" -ge 15 ] || retry_delay=$((retry_delay + 2))
			continue
		fi
	else
		restore_verified=0
	fi

	# Monitor renderer.config cheaply once per second only while its watcher is enabled.
	# A metadata change reconciles only the renderer path; it never wakes libhp15.
	if watcher_disabled renderer_watcher_disabled; then
		renderer_watch_ready=0
		renderer_last_fp=""
	elif [ "$(/system/bin/getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
		if [ "$renderer_watch_ready" -eq 0 ]; then
			renderer_last_fp=$(renderer_fingerprint)
			renderer_watch_ready=1
		else
			renderer_current_fp=$(renderer_fingerprint)
			if [ "$renderer_current_fp" != "$renderer_last_fp" ]; then
				log_watch "renderer.config changed; reconciling MuMu Shader Compatibility"
				"$MODDIR/apply_patch.sh" renderer-watch >/dev/null 2>&1 \
					|| log_watch "MuMu Shader Compatibility check failed after renderer.config change"
				renderer_last_fp=$(renderer_fingerprint)
			fi
		fi
	fi

	# Periodic checks are independently gated. Disabled watchers perform no
	# automatic compatibility inspection; Save and Repair still reconcile both.
	mumu_tick=$((mumu_tick + 1))
	if [ "$mumu_tick" -ge 15 ]; then
		refresh_watcher_defaults
		hp15_disabled=0
		renderer_disabled=0
		watcher_disabled hp15_watcher_disabled && hp15_disabled=1
		watcher_disabled renderer_watcher_disabled && renderer_disabled=1
		if [ "$hp15_disabled" -eq 0 ] && [ "$renderer_disabled" -eq 0 ]; then
			"$MODDIR/apply_patch.sh" mumu-watch >/dev/null 2>&1 \
				|| log_watch "Periodic MuMu compatibility check failed"
		elif [ "$hp15_disabled" -eq 0 ]; then
			"$MODDIR/apply_patch.sh" hp15-watch >/dev/null 2>&1 \
				|| log_watch "MuMu libhp15 check failed"
		elif [ "$renderer_disabled" -eq 0 ]; then
			"$MODDIR/apply_patch.sh" renderer-watch >/dev/null 2>&1 \
				|| log_watch "MuMu Shader Compatibility check failed"
		fi
		[ "$renderer_watch_ready" -eq 1 ] && renderer_last_fp=$(renderer_fingerprint)
		mumu_tick=0
	fi

	sleep 1
done

exit 0
