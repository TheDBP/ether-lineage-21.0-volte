# patches/<branch>/<project>/ — engine patches

Applied by `tools/apply-overlay.sh` step 0, before every option and device patch, to **every device
and every preset** on that branch. Put a patch here only when the branch itself broke something that
any device with the same shape hits; device-specific fixes go in the device repo's
`overlay/patches/`, option-specific ones in `options/<name>/patches/<branch>/`.

Rules: generate from a pristine clone (`git clone --no-local`, GOTCHAS §14), `--zero-commit
--no-signature`, strip `Change-Id:`, verify with `git apply --check` against the synced project.
Don't stack a patch on top of another one's output; one problem, one patch.

| Branch | Project | Patch | Why |
|---|---|---|---|
| lineage-24.0 | `build/soong` | 0001 forward GOMEMLIMIT/GOGC | `soong_ui` starts `soong_build` with `env -i`, so `SOONG_MEM_LIMIT` never reached it; a 24.0 tree with a 32-bit second arch needs it or analysis OOMs on 30 GB + 38 GB swap. |
| lineage-24.0 | `vendor/lineage` | 0001 Revert "kernel: Rip out GCC support" | 24.0 builds every kernel with `LLVM=1` only. Kernels < 5.7 ignore it: `HOSTCC=gcc` (absent in the container, header genrule yields nothing, every UAPI-including HAL fails) and no binutils behind `CROSS_COMPILE`. Restores the pre-5.10 path behind `KERNEL_NO_GCC`; ≥ 5.10 unchanged. **Devices using it must add** `prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9` and `.../arm/arm-linux-androideabi-4.9` (LineageOS, `lineage-19.1`) to their local manifest — 24.0 dropped them. |
