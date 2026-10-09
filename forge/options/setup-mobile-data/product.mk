# Makefile fragment for the setup-mobile-data option. The generator wraps this in
# ifeq ($(WITH_SETUP_MOBILE_DATA),true).
#
# DataSettingsManager.isProvisioningDataEnabled() gates mobile data on this property for as long as
# Settings.Global.DEVICE_PROVISIONED is 0, and it defaults to "false". So a freshly wiped phone
# reaches the setup wizard with the radio down and no page offering to turn it on: on a GApps build
# the wizard asks you to sign in with no way online but Wi-Fi, and on any build mobile data has to
# be switched on by hand after first reaching the home screen.
#
# Unlike the patch half of this option, this applies to every branch: the property is read the same
# way on 20.0 and on 24.0.
#
# That only covers setup. The moment DEVICE_PROVISIONED flips to 1, isUserDataEnabled() stops
# consulting isProvisioningDataEnabled() and reads the stored setting instead, defaulting to
# TelephonyProperties.mobile_data() -- which is ro.com.android.mobiledata, and which
# vendor/lineage/config/telephony.mk sets to false under the comment "Disable mobile data by
# default". So without the second property the phone gets through the wizard online and then drops
# off the network the instant setup finishes, which is the symptom this option exists to prevent.
#
# PRODUCT_PRODUCT_PROPERTIES, matching how telephony.mk sets it: both land in
# /product/etc/build.prop, and the later assignment wins. Setting it through
# PRODUCT_PROPERTY_OVERRIDES instead would write /system/build.prop and leave the product copy
# saying false.
PRODUCT_PROPERTY_OVERRIDES += \
    ro.com.android.prov_mobiledata=true

PRODUCT_PRODUCT_PROPERTIES += \
    ro.com.android.mobiledata=true
