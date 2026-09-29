# pong-notification

Default notification sound: **Pong** instead of LineageOS's Argon.

Pong is a LineageOS sound, not an OEM one -- `vendor/lineage/prebuilt/common/media/audio/
notifications/Pong.ogg`, copied to every device by `vendor/lineage/config/lineage_audio.mk`.

## Why this is a patch and not a property

It was a property first, and that version broke the build. The reasoning was: `RingtoneManager`
resolves the default notification from `ro.config.notification_sound`, `ro.*` properties are
immutable so the first value into `build.prop` wins, and `vendor/extra/product.mk` is inherited
before `common.mk` -- therefore setting it from the option should simply win.

Every step of that is true and the conclusion is still wrong. First-value-wins is a **runtime**
rule. At build time, `vendor/lineage/config/common_mobile.mk` already puts
`ro.config.notification_sound` in `PRODUCT_PRODUCT_PROPERTIES`, so setting the same name into the
same partition is a duplicate sysprop assignment -- and `post_process_props.py` rejects duplicates
outright. The build dies before runtime immutability ever gets a chance to apply.

Worth remembering in general: an `ro.*` property that "wins because it is written first" only wins if
nothing else in the same partition declares it. Two assignments is a build failure, not a precedence
question. `?=` does not save you either -- an optional assignment is deleted outright when a plain
`=` for the same name exists.

So the option changes the value at its one source instead, which is a one-line patch to
`common_mobile.mk`.

## Scope

Only the notification sound. The ringtone (`ro.config.ringtone`) and the alarm
(`ro.config.alarm_alert`, Hassium) are left alone -- they sit on the same two lines if wanted.

Does not affect a device that has already booted: the property seeds the *default*, and a user who
has chosen a sound keeps it.

## Branches

Patched for lineage-20.0, 22.2 and 24.0, each generated from that branch's own tree and verified with
`git apply --check`. The line sits at 12 on 20.0 and 13 on 22.2/24.0. Add another branch by
regenerating against its tree rather than reusing a patch by context.
