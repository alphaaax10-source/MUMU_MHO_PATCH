#!/system/bin/sh
# MHO MuMu Patcher 1.4.3 — explicit targets and isolated state.
umask 077
MODDIR=${0%/*}
. "$MODDIR/lib/engine.sh"
. "$MODDIR/lib/multi.sh"
. "$MODDIR/lib/renderer.sh"
main "$@"
