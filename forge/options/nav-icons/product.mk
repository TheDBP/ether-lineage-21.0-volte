# Makefile fragment for the nav-icons option.
#
# The generator wraps this in `ifeq ($(WITH_NAV_ICONS),true)` -- do not add the conditional here,
# or the option would have two places to disagree about whether it is on.
#
# DEVICE_PACKAGE_OVERLAYS is a product list variable: product config accumulates each makefile's
# contribution and unions them, so appending here is not undone by a device.mk that assigns with
# `:=`. Verified on ether, whose device.mk does exactly that and which still receives 19 resources
# from vendor/lineage/overlay/common.
DEVICE_PACKAGE_OVERLAYS += vendor/extra/overlay/nav-icons

# On branches that enforce RRO (22.2 does, 20.0 does not) a vendor-path overlay is turned into a
# separate auto_generated_rro_vendor APK instead of being compiled into SystemUI. These drawables
# use ?attr/singleToneColor, which is SystemUI's own attr -- AOSP's stock ic_sysbar_* use it too --
# and inside a separate package that reference resolves against the RRO rather than the target, so
# aapt2 fails to link:
#
#   ic_sysbar_back.xml:19: error: resource attr/singleToneColor
#     (aka com.android.systemui.auto_generated_rro_vendor__:attr/singleToneColor) not found.
#
# Excluding the overlay keeps it a static overlay, which is what it already is on the branches that
# do not enforce RRO, so every branch now compiles these the same way. Harmless where RRO is not
# enforced: build/make/core/package_internal.mk only consults this when enforce_rro_enabled is set.
PRODUCT_ENFORCE_RRO_EXCLUDED_OVERLAYS += vendor/extra/overlay/nav-icons
