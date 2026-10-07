# Makefile fragment for the setup-mobile-data option. The generator wraps this in
# ifeq ($(WITH_SETUP_MOBILE_DATA),true).
#
# DataSettingsManager.isProvisioningDataEnabled() gates mobile data on this property for as long as
# Settings.Global.DEVICE_PROVISIONED is 0, and it defaults to "false". So a freshly wiped phone
# reaches the setup wizard with the radio down and no page offering to turn it on: on a GApps build
# the wizard asks you to sign in with no way online but Wi-Fi, and on any build mobile data has to
# be switched on by hand after first reaching the home screen.
#
# Unlike the patch half of this option, this applies to every branch -- the property is read the
# same way on 20.0 and on 24.0. ro.com.android.mobiledata, the old post-setup switch, was removed
# and is not a substitute.
PRODUCT_PROPERTY_OVERRIDES += \
    ro.com.android.prov_mobiledata=true
