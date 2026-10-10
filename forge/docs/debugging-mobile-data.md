# Debugging mobile data that never comes up

For the case where the phone registers on LTE, SMS and even IMS work, APN/profile/DSD look right,
but every data call fails in the RIL with an error that explains nothing (`SETUP_DATA_CALL`
error 47 / `RADIO_NOT_AVAILABLE`-class codes, `DcTracker` retrying forever). Same result on the
official nightly means it is not your ROM; same result on a different modem image means it is not
the firmware either. What is left is state the modem reads from somewhere else.

## Peel the RIL off first

`setupDataCall` passes through telephony, qcril and the RIL HAL before it becomes one QMI
`WDS_START_NETWORK_INTERFACE` message. Every layer rewrites the error. Ask the modem yourself with
[`qmi-sni.sh`](../tools/qmi-sni.sh) (a static QMI WDS client, no RIL):

    qmi-sni.sh 0 <apn> <profile> v4 epc          # node 0 = the modem on the IPC router

`CONNECTED` plus an `rmnet_dataN` address means the modem is fine and the fault is above it.
A failure with a bare error code and **no call-end-reason TLV** means the modem refused before it
ever tried the network -- a policy gate, not a network reject. Stop reading logcat at that point;
nothing above the modem knows why.

Cleanup trap: a call the tool brings up and the RIL did not know about leaves qcril in
`CLOSE_IN_PROGRESS`; an airplane-mode cycle clears it.

## Make the modem say why

The modem has its own printf log (F3 messages) on `/dev/diag`. [`diag-f3.sh`](../tools/diag-f3.sh)
captures N seconds and decodes them to text; trigger the data call during the window and grep
the result for `wds`, `block`, `reject`, `cable`, `factory`. The line that explains the refusal is
usually one of a handful in the whole capture; the OEM's own stack (`[LG_DATA]`, `[SS_DATA]`,
`ds_qmi_wds.c`) is where to look, not the Qualcomm core.

Decoder trap: F3 extended messages carry their printf arguments **after** the fixed header plus
the `num_args` count -- arguments start at byte 20 of the payload, not 16. An off-by-one here
yields plausible-looking lines with wrong numbers, which is worse than no lines.

## Find the state the modem is reading

An OEM gate like "factory cable", "test mode", "QEM" or "boot mode" is set by the bootloader for
the modem, and the handoff is **SMEM** (shared memory): the vendor items are
`SMEM_ID_VENDOR0/1/2` (134/135/136), each a small struct the bootloader fills in. An engineering
or third-party bootloader (DirtySanta-class unlocks replace aboot) leaves fields it does not know
about as `0xffffffff`, and a modem that tests `!= 0` reads that as "flag set".

Dump the items with [`smem-poke`](../tools/smem-poke) built against the running kernel with
[`kmod-build.sh`](../tools/kmod-build.sh):

    ./forge/tools/kmod-build.sh forge/tools/smem-poke     # run from the device repo; the path
                                                         # must be inside it, because the container
                                                         # reaches it as /repo/<relpath>
    insmod smem-poke.ko ids=134,135,136 ; dmesg | tail

Anything that is all-ones on your phone and zero on a stock-bootloader phone of the same model
(or in the upstream `dirtysanta_fixup` struct for your SoC) is a candidate.

## Prove it live before you patch anything

The modem keeps a pointer into SMEM, so the word can be changed on a running phone and the next
call tried without a reboot:

    insmod smem-poke.ko do_poke=1 poke_id=135 poke_off=12 poke_val=0
    qmi-sni.sh 0 <apn> <profile> v4 epc        # connects?
    insmod smem-poke.ko do_poke=1 poke_id=135 poke_off=12 poke_val=1   # blocked again?

A fix that toggles both ways on one word is proven; everything else (APN edits, EFS files, modem
swaps) stops being a suspect. Then clear the word in the kernel at `subsys_initcall`, before the
modem subsystem starts, the way the existing `drivers/soc/qcom/dirtysanta_fixup*.c` files do.

## Testing on the stock kernel too

To rule the ROM out you will want the same module on the official build's kernel, which rejects
it (`disagrees about version of symbol module_layout`) because a different clang changes a few
MODVERSIONS CRCs. [`kmod-rebase-crcs.py`](../tools/kmod-rebase-crcs.py) rewrites the module's
`__versions` table from the target `Image` plus its kallsyms:

    kmod-rebase-crcs.py smem-poke.ko offk/Image offk/kallsyms.txt smem-poke-off.ko

The kernel is tainted (`F`) afterwards; that is fine for a diagnostic module.

## Things that were not it, and how they were ruled out

| Suspect | Test that cleared it |
|---|---|
| APN / 3GPP profile | `qmi-sni.sh` with each profile id, same bare error, no call-end reason |
| This ROM | official nightly from the same bootloader: same error |
| Modem firmware | full modem image swap to another carrier variant: same error |
| EFS policy files (APM, DSD) | edited and verified after `rmt_storage` sync (wait 60-90 s before rebooting or the write is lost): same error |
| RTRE / subscription source | changed and restored via QMI: same error |

Do not touch `modemst1/2` or `fsg` for this; they are not involved and they hold the IMEI.
