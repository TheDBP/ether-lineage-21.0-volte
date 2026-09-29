# vendored/

Trees recovered from Software Heritage because their upstreams are **deleted**.

## sepolicy-legacy

`gitlab.com/TipzTeam/android_device_qcom_sepolicy-legacy` @ `lineage-19.0`
(SWH snapshot `19ca6f9498d896be9c80d258e8013b04efef9b0f`, captured 2022-02-19).

This is the pre-rename qcom legacy policy: lowercase `sepolicy.mk`, `common/`, `legacy-common/`
and per-SoC dirs **including `msm8992` and `msm8994`**. LineageOS's own
`android_device_qcom_sepolicy` dropped that layout — every branch now ships `SEPolicy.mk` with
`generic/legacy/qva`, and none of them carry msm8992.

Pinning the wrong repo at `device/qcom/sepolicy-legacy` is what caused this port to spend days
restoring ~30 SELinux types, six domains, four te_macros and their labels by hand. All of it is here
already, correct and complete.

Copied in rather than fetched: the GitLab group is gone, and SWH is the only remaining source.

## device_nextbit_ether

`gitlab.com/TipzTeam/android_device_nextbit_ether` @ `lineage-19.1`
(SWH revision `7c668c96`).

Byte-identical to `device_nextbit_ether/` on the `main` branch of
[TheDBP/ether-trees](https://github.com/TheDBP/ether-trees). Do not edit it here — every change
lives in `overlay/patches/device/nextbit/ether/`, so the diff against the recovered upstream is
always the patch series.
