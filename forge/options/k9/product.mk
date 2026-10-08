# Makefile fragment for the k9 option. The generator wraps this in
# ifeq ($(WITH_K9),true).
#
# Hands K-9 Mail to F-Droid's Privileged Extension as update owner, so the Play Store cannot
# quietly replace an app installed from F-Droid. See the XML for why that is needed at all.
PRODUCT_COPY_FILES += \
    vendor/extra/update-owner/com.fsck.k9.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/sysconfig/com.fsck.k9.xml
