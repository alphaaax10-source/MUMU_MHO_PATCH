#!/system/bin/sh

# Start the lifecycle watcher as early as KernelSU permits for a module that was
# considered active when this stage was scheduled. Launch unconditionally: if a
# disable/remove marker raced in after KernelSU enumerated active modules, the
# watcher must see it and perform the restore rather than silently skipping it.
MODDIR=${0%/*}
"$MODDIR/apply_patch.sh" hp15-boot </dev/null >/dev/null 2>&1 || true
"$MODDIR/service.sh" early </dev/null >/dev/null 2>&1 &
exit 0
