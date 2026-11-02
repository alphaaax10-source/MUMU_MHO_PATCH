#!/system/bin/sh

# MHO MuMu Patcher 1.4.2
# KernelSU runs uninstall.sh during post-fs-data, where PackageManager/Binder
# may not exist yet. apply_patch.sh therefore uses its cached/direct-filesystem
# restore path first and does not depend on `pm` for this lifecycle operation.

MODDIR=${0%/*}
STATE_DIR="/data/adb/mho_mumu_patcher"

attempt=1
rc=1
while [ "$attempt" -le 5 ]; do
	"$MODDIR/apply_patch.sh" restore uninstall-post-fs-data
	rc=$?
	[ "$rc" -eq 0 ] && break
	/system/bin/log -t MHO_PATCH "Uninstall pristine restore attempt $attempt failed with code $rc" 2>/dev/null || true
	attempt=$((attempt + 1))
	[ "$attempt" -le 5 ] && sleep 2
done

if [ "$rc" -eq 0 ]; then
    /system/bin/log -t MHO_PATCH "All tracked game libraries and shared compatibility restored; recovery history kept at $STATE_DIR" 2>/dev/null || true
else
    /system/bin/log -t MHO_PATCH "CRITICAL: restore did not complete; state/logs kept at $STATE_DIR" 2>/dev/null || true
fi

exit "$rc"
