# Makefile fragment for the bringup option. The generator wraps this in ifeq ($(WITH_BRINGUP),true).
#
# A boot loop kills system_server, and system_server is what draws the adb authorisation prompt and
# what normally turns USB adb on. Everything here is reachable without it: adbd and logd start from
# init.

# WITH_ADB_INSECURE=true comes from build-env, not from here: common.mk tests it with ifdef before
# this file is read (inherit-product is deferred). With it, ro.adb.secure=0 and ro.debuggable=1;
# post_process_props.py then appends adb to persist.sys.usb.config on any debuggable build, and
# init.usb.rc's "on boot && property:persist.sys.usb.config=*" starts adbd from that alone.
# PRODUCT_ADB_KEYS is deliberately not used: it would put a personal adbkey.pub (user@host inside)
# in the repo, and it is redundant once adb.secure is 0.

# Stated explicitly as well, so the option does not depend on the post-processing step.
# logcatd (logpersist.start, a PRODUCT_PACKAGES_DEBUG member, so present only when debuggable)
# writes every buffer to /data/misc/logd/ once /data is mounted; read it back with
# "adb shell logpersist.cat" or pull the directory, and it survives the reboot the loop causes.
PRODUCT_SYSTEM_EXT_PROPERTIES += \
    persist.sys.usb.config=adb \
    persist.logd.logpersistd=logcatd
