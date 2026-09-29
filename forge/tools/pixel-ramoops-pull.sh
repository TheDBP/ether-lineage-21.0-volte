#!/usr/bin/env bash
# pixel-ramoops-pull.sh — decrypt the panic log a Pixel's bootloader saved, from recovery.
#
#   pixel-ramoops-pull.sh --genkey <keydir>          once: make a keypair, load its pubkey
#   pixel-ramoops-pull.sh <keydir> <out.txt>          after a panic: decrypt and read
#
# Pixel 3/3a-class bootloaders (sdm670/sdm845) save the console ring to the `klog` partition and
# the alt ramoops region ONLY on a kernel panic, AES-GCM encrypted to an RSA public key kept in the
# ramoops metadata carveout (/dev/access-metadata). The stock key is Google's. The vendor `ramoops`
# binary can generate a keypair (-g), load the pubkey into the carveout (-l -c), and decrypt in
# place (-D); `use_alt` then makes pstore expose the decrypted alt region as console-ramoops-0.
# The loaded pubkey persists across reboots and flashes.
#
# A clean reboot (init's reboot_on_failure, InitFatalReboot without androidboot.init_fatal_panic)
# saves nothing here — for those use dtbo-ramoops-alt.py instead.
#
# RAMOOPS_BIN: path to the vendor `ramoops` binary; default: first vendor/google/*/proprietary/
# vendor/bin/ramoops under $ANDROID_SRC or ./build_output/src. KEEP <keydir> OUT OF EVERY REPO —
# priv.pem unlocks every future panic log of that phone.
set -u
ADB=(adb); [ "${1:-}" = -s ] && { ADB=(adb -s "$2"); shift 2; }
[ $# -eq 2 ] || { sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
SRC="${ANDROID_SRC:-$PWD/build_output/src}"
BIN="${RAMOOPS_BIN:-$(ls "$SRC"/vendor/google/*/proprietary/vendor/bin/ramoops 2>/dev/null | head -1)}"
[ -f "$BIN" ] || { echo "!! no vendor ramoops binary (set RAMOOPS_BIN)" >&2; exit 1; }

"${ADB[@]}" root >/dev/null 2>&1; sleep 1; "${ADB[@]}" wait-for-recovery
"${ADB[@]}" push "$BIN" /tmp/ramoops >/dev/null
"${ADB[@]}" shell 'chmod 755 /tmp/ramoops; mkdir -p /tmp/rk'   # the PHONE's tmpfs, not the host's

if [ "$1" = --genkey ]; then
  K="$2"; mkdir -p "$K"; chmod 700 "$K"
  "${ADB[@]}" shell '/tmp/ramoops -g -f -k /tmp/rk -l -c'
  "${ADB[@]}" pull /tmp/rk/priv.pem /tmp/rk/pub.pem "$K/" >/dev/null; chmod 600 "$K"/*
  echo "keypair in $K (mode 600), pubkey loaded into the carveout. Never commit it."
  exit 0
fi

K="$1"; OUT="$2"
"${ADB[@]}" push "$K/priv.pem" "$K/pub.pem" /tmp/rk/ >/dev/null
"${ADB[@]}" shell '/tmp/ramoops -D -k /tmp/rk && echo 1 > /sys/devices/virtual/ramoops/pstore/use_alt;
  umount /sys/fs/pstore 2>/dev/null; mount -t pstore pstore /sys/fs/pstore; ls -la /sys/fs/pstore'
"${ADB[@]}" exec-out cat /sys/fs/pstore/console-ramoops-0 > "$OUT"
echo "$OUT: $(wc -l < "$OUT") lines"
