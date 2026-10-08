# Makefile fragment for the connectbot option. The generator wraps this in
# ifeq ($(WITH_CONNECTBOT),true).
#
# Hands ConnectBot to F-Droid's Privileged Extension as update owner, so the Play Store cannot
# quietly replace an app installed from F-Droid. See the XML for why that is needed at all.
PRODUCT_COPY_FILES += \
    vendor/extra/update-owner/org.connectbot.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/sysconfig/org.connectbot.xml
