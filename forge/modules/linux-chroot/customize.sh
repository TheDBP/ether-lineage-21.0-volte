# Magisk install-time hook.
SKIPUNZIP=0

# Magisk extracts everything 0644; the wrappers in system/bin exec these directly.
set_perm_recursive "$MODPATH/scripts" 0 0 0755 0755
ui_print ""
ui_print "  Linux chroot installed."
ui_print ""
ui_print "  The rootfs is NOT bundled (it is ~30 MB compressed and needs network)."
ui_print "  After rebooting, from a root shell:"
ui_print ""
ui_print "      linux-setup      # downloads + unpacks Ubuntu Base into /data/linux"
ui_print "      linux            # enter the chroot"
ui_print ""
ui_print "  Requires ~1.5 GB free in /data once you start installing packages."
ui_print ""
