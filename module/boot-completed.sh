#!/system/bin/sh

MODDIR=${0%/*}

# Defensive race guard: normally KernelSU does not execute this script for a
# disabled module, but do not patch if a disable/remove marker appeared after
# boot scheduling.
if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
	"$MODDIR/apply_patch.sh" restore boot-disabled
	exit $?
fi

"$MODDIR/apply_patch.sh" boot
exit $?
