# Makefile fragment for the setup-mobile-data option. The generator wraps this in
# ifeq ($(WITH_SETUP_MOBILE_DATA),true).
#
# DataSettingsManager.isProvisioningDataEnabled() gates mobile data on this property for as long as
# Settings.Global.DEVICE_PROVISIONED is 0, and it defaults to "false". So a freshly wiped phone
# reaches the setup wizard with the radio down and no page offering to turn it on: on a GApps build
# the wizard asks you to sign in with no way online but Wi-Fi.
#
# Unlike the patch half of this option, this applies to every branch: the property is read the same
# way on 20.0 and on 24.0.
#
# This only covers setup. Once DEVICE_PROVISIONED flips to 1, isUserDataEnabled() stops consulting
# isProvisioningDataEnabled() and falls back to ro.com.android.mobiledata, which LineageOS sets to
# false in vendor/lineage/config/telephony.mk. That half is fixed by this option's vendor/lineage
# patch rather than from here, because it cannot be overridden: gen_build_prop fails the build on
# duplicate sysprop assignments, both copies would land in /product/etc/build.prop (the partition
# init loads last, so /system would lose anyway), and vendor/extra/product.mk is inherited at line 2
# of common.mk -- before telephony.mk -- so a filter-out from here runs too early to see it.
PRODUCT_PROPERTY_OVERRIDES += \
    ro.com.android.prov_mobiledata=true
