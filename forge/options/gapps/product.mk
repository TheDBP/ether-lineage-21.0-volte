# Makefile fragment for the gapps option. The generator wraps this in ifeq ($(WITH_GAPPS),true).
#
# These two lines were previously written into each device's makefiles by hand, identically, and
# were the same on ether, bonito and vs995. They are not device facts; they are what this option is.

# Play Store and GMS, from the vendor/gapps project (MindTheGapps).
# IF_EXISTS so a tree without that project synced is a no-op rather than a hard failure -- the
# manifest that supplies it is opt-in per device.
$(call inherit-product-if-exists, vendor/gapps/arm64/arm64-vendor.mk)

# Google's versions of the stock apps, staged by forge/tools/extract-gapps-apps.sh. Each prebuilt
# carries LOCAL_OVERRIDES_PACKAGES naming the Lineage app it replaces, so the counterpart drops out
# of the build automatically -- and only when its Google replacement is actually present.
-include vendor/extra/gapps-extras/packages.mk

