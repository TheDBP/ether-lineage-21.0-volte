#!/usr/bin/env bash
# make-apex-key.sh — create the signing key an EROFS-repacked APEX is re-signed with.
#
#   make-apex-key.sh <apex-name> <keys-dir>
#   make-apex-key.sh com.google.android.gmssystem /home/me/keys/rom
#
# Run this on the HOST, not in the build container: KEYS_DIR is mounted read-only there, which is
# deliberate -- a build must not be able to mint signing keys.
#
# Makes four files, the same shape as the platform apex keys:
#   <name>.pem        AVB private key, signs the payload vbmeta
#   <name>.avbpubkey  the matching public key, bundled inside the apex
#   <name>.pk8        container signing key (APK signature)
#   <name>.x509.pem   the matching certificate
#
# KEEP THEM. apexd accepts a pre-installed apex signed with any self-consistent key, but an OTA
# carrying a newer version of the same apex must be signed with the SAME key or it is rejected.
set -u
NAME="${1:?usage: make-apex-key.sh <apex-name> <keys-dir>}"
KEYS="${2:?usage: make-apex-key.sh <apex-name> <keys-dir>}"
mkdir -p "$KEYS" || exit 1

AVBTOOL="${AVBTOOL:-}"
if [ -z "$AVBTOOL" ]; then
  for c in out/host/linux-x86/bin/avbtool build_output/src/out/host/linux-x86/bin/avbtool "$(command -v avbtool 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && AVBTOOL="$c" && break
  done
fi
[ -n "$AVBTOOL" ] && [ -x "$AVBTOOL" ] || { echo "!! avbtool not found; set AVBTOOL=" >&2; exit 1; }

if [ -f "$KEYS/$NAME.pem" ]; then
  echo ">> $NAME already has a key in $KEYS -- refusing to overwrite."
  echo "   Replacing it would make every already-shipped OTA for this apex unupdatable."
  exit 0
fi

umask 077
openssl genrsa -out "$KEYS/$NAME.pem" 4096 2>/dev/null           || { echo "!! genrsa failed" >&2; exit 1; }
"$AVBTOOL" extract_public_key --key "$KEYS/$NAME.pem" --output "$KEYS/$NAME.avbpubkey" || { echo "!! avbtool failed" >&2; exit 1; }
_tmp="$(mktemp -u "${TMPDIR:-.}/apexkey.XXXXXX.pem")"
openssl req -new -x509 -newkey rsa:4096 -nodes -sha256 -days 10950 \
  -subj "/C=US/ST=CA/L=MV/O=Android/OU=Android/CN=$NAME" \
  -keyout "$_tmp" -out "$KEYS/$NAME.x509.pem" 2>/dev/null       || { echo "!! req failed" >&2; rm -f "$_tmp"; exit 1; }
openssl pkcs8 -topk8 -inform PEM -outform DER -in "$_tmp" -out "$KEYS/$NAME.pk8" -nocrypt 2>/dev/null || { echo "!! pkcs8 failed" >&2; rm -f "$_tmp"; exit 1; }
rm -f "$_tmp"
echo ">> made $NAME.{pem,avbpubkey,pk8,x509.pem} in $KEYS"
