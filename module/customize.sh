#!/system/bin/sh

ui_print "*******************************"
ui_print "      MHO MuMu Patcher"
ui_print "           v1.4.2"
ui_print "*******************************"
ui_print "- Europe and Asia support with exact-build profiles"
ui_print "- Game selector with profile status; isolated settings and recovery"
ui_print "- Save and Repair also apply shared MuMu settings"
ui_print "- MuMu renderer shader compatibility fix"
ui_print "- IgnoreGLError renderer.config compatibility (required for GPM Level 7)"
ui_print "- Game GPU cache reset helper (after changing MuMu GPU model)"
ui_print "- Optional experimental UE Engine.ini streaming fix"
ui_print "- MuMu libhp15 crash compatibility override"
ui_print "- Device/system patches are mandatory on MuMu"
ui_print "- Advanced settings can override mandatory patches and compatibility watchers"
ui_print "- Device-check Force remains available outside MuMu"
ui_print "- Optional Resolution Scale patch (10-200%)"
ui_print "- Optional experimental FPS Override (20-240)"
ui_print "- Optional PixelFlow frame interpolation control (Low risk)"
ui_print "- Profile-controlled Advanced defaults; missing values are enabled"
ui_print "- Optional max GPM Device Level patch (Level 7)"
ui_print "- Optional Force Graphic Library patch (OpenGL/Vulkan)"
ui_print "- Optional Force Cross Platform patch (PC/Mobile/Console, High risk)"
ui_print "- Optional GPU Model display patch"
ui_print "- Optional Extended Watermark Info patch (Graphic API / Platform)"
ui_print "- SHA-256 verified pristine Repair path"
ui_print "- Optional features are hidden when a profile marks them not ready"
ui_print "- WARNING: binary modification may result in a game ban"
ui_print "- Use entirely at your own risk"

HP15_EXPECTED="f6f7ea74adff2f22b91e2c9feea9ec57134748eb38d8404faef4cae9c1aabdbb"
HP15_ACTUAL=$(sha256sum "$MODPATH/payload/libhp15_x86_64.so" 2>/dev/null | awk '{print $1}' | tr 'A-F' 'a-f')
[ "$HP15_ACTUAL" = "$HP15_EXPECTED" ] || abort "! Invalid libhp15 payload"

# One-time upgrade safety: retire the independent boot hook left by older releases.
# Only the exact hook carrying our marker is moved out of post-fs-data.d.
# This never reads, changes or restores Android's package database. Previously
# created recovery files remain untouched in the persistent state directory.
legacy_hook=/data/adb/post-fs-data.d/mho_mumu_installer_restore.sh
legacy_archive=/data/adb/mho_mumu_patcher/installer/paused-hooks
if [ -f "$legacy_hook" ] && [ ! -L "$legacy_hook" ] && \
   [ "$(sed -n '2p' "$legacy_hook")" = '# MHO_INSTALL_SOURCE_ROLLBACK_V1' ]; then
    (
        umask 077
        mkdir -p "$legacy_archive" || exit 1
        retired=$(mktemp -d "$legacy_archive/restore.XXXXXX") || exit 1
        mv "$legacy_hook" "$retired/restore.sh" || exit 1
        chmod 0600 "$retired/restore.sh" || exit 1
    ) || abort "! Could not retire a legacy boot hook safely"
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/payload/libhp15_x86_64.so" 0 0 0444
set_perm "$MODPATH/apply_patch.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/boot-completed.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755

