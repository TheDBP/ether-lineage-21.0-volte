#!/usr/bin/env bash
# make-keys.sh — generate the signing keys for release builds, once, into a directory outside
# every repo.
#
#   ./forge/tools/make-keys.sh <keys-dir> '<subject>'
#   ./forge/tools/make-keys.sh ~/keys/rom '/C=US/O=MyName/OU=MyName/CN=MyName/emailAddress=me@example.org'
#
# Then, in device.conf.local (gitignored):
#
#   KEYS_DIR=/home/me/keys/rom
#
# and every build from that checkout is signed with these keys instead of AOSP's public test keys.
# The same directory can serve every device repo: keys identify the maintainer, not the phone.
#
# What it makes, and why:
#   releasekey platform shared media networkstack bluetooth sdk_sandbox testkey verity
#       RSA-2048 .pk8 + .x509.pem, the set build/make/target/product/security ships as test keys.
#       Every APK with certificate: "<name>" resolves to <keys-dir>/<name>, and OTA zips are signed
#       with releasekey (PRODUCT_DEFAULT_DEV_CERTIFICATE in keys.mk).
#   com.android.<module> ...
#       RSA-4096 .pem + .avbpubkey for every apex_key module in the source tree, plus the matching
#       .pk8/.x509.pem. Soong looks for APEX keys beside the default certificate first
#       (build/soong/android/config.go ApexKeyDir) and falls back to the tree's public ones.
#       Needs the synced tree for the list and for avbtool: pass --src or run from a device repo
#       that has built. Skipped with a warning otherwise; add them later by re-running.
#   keys.mk
#       What vendor/lineage/config/common.mk -includes.
#
# The subject is what ends up inside every certificate on the phone. It is required rather than
# defaulted from git config so a personal name or address cannot slip into a shipped image by
# accident.
#
# Never overwrites a key. Re-running against a newer tree only adds what that tree needs (a new
# branch brings new app certificates and apex_key modules) and reports each existing key as kept.
# Losing releasekey means every user has to wipe to take the next update, so back the directory up
# somewhere that is not this machine.
set -euo pipefail

SRC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --src) SRC="${2:?--src needs a path}"; shift 2;;
    -h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) break;;
  esac
done
DIR="${1:?usage: make-keys.sh [--src <aosp-tree>] <keys-dir> '<subject>'}"
SUBJECT="${2:?usage: make-keys.sh [--src <aosp-tree>] <keys-dir> '<subject>'}"
case "$SUBJECT" in /*=*) ;; *) echo "!! subject must look like /C=US/O=Name/CN=Name/emailAddress=..." >&2; exit 1;; esac

die() { echo "!! $*" >&2; exit 1; }

mkdir -p "$DIR"; DIR="$(cd "$DIR" && pwd)"
chmod 700 "$DIR"
# Outside every repo. A keys directory inside a work tree is one `git add -A` away from GitHub.
if git -C "$DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
  die "$DIR is inside the git work tree $(git -C "$DIR" rev-parse --show-toplevel) -- keep keys outside every repo"
fi
[ -e "$DIR/releasekey.pk8" ] && echo ">> $DIR already holds keys -- existing ones are kept, only missing ones are made"

[ -n "$SRC" ] || { _repo="$(cd "$(dirname "$0")/../.." && pwd)"; [ -d "$_repo/build_output/src/external/avb" ] && SRC="$_repo/build_output/src"; }
AVBTOOL=""
[ -n "$SRC" ] && [ -f "$SRC/external/avb/avbtool.py" ] && AVBTOOL="$SRC/external/avb/avbtool.py"

# <name> <bits>: RSA key -> <name>.pk8 (PKCS#8 DER, no password) + <name>.x509.pem (10000 days),
# and keep the PEM private key when asked (APEX signing takes PEM). Same shape as
# development/tools/make_key, minus the prompt.
gen() {
  local name="$1" bits="$2" keep_pem="${3:-}"
  local key="$DIR/$name.pem"
  if [ -e "$DIR/$name.pk8" ]; then echo "   $name (kept)"; return 1; fi
  (umask 077; openssl genrsa -f4 -out "$key" "$bits" 2>/dev/null)
  openssl req -new -x509 -sha256 -key "$key" -out "$DIR/$name.x509.pem" -days 10000 -subj "$SUBJECT"
  (umask 077; openssl pkcs8 -in "$key" -topk8 -outform DER -out "$DIR/$name.pk8" -nocrypt)
  [ -n "$keep_pem" ] || rm -f "$key"
}

echo ">> app and OTA keys -> $DIR"
# The base set is what build/make/target/product/security ships; a synced tree may add to it
# (nfc, cts_uicc_2021 from 14 on), and every name there is a certificate: "<name>" some APK resolves.
APP_KEYS="releasekey platform shared media networkstack bluetooth sdk_sandbox testkey verity"
[ -n "$SRC" ] && APP_KEYS="$APP_KEYS $(ls "$SRC"/build/make/target/product/security/*.pk8 2>/dev/null | xargs -rn1 basename | sed 's/\.pk8$//')"
for name in $(printf '%s\n' $APP_KEYS | sort -u); do
  gen "$name" 2048 && echo "   $name"
done

if [ -n "$AVBTOOL" ]; then
  echo ">> APEX keys (apex_key modules in $SRC)"
  # Every apex_key whose public_key is a plain path: that is the lookup ApexKeyDir overrides.
  # Test and example APEXes are excluded by where they are declared (tests/, testdata) and by
  # name; they are never in an image.
  grep -roE 'public_key: *"[^":]+\.avbpubkey"' --include=Android.bp \
      --exclude-dir=out --exclude-dir=prebuilts --exclude-dir=.repo "$SRC" 2>/dev/null \
    | grep -vE '/tests?/|testdata' \
    | sed -E 's/.*"(.*)\.avbpubkey"/\1/; s#.*/##' | sort -u \
    | grep -vE '\.test|example|^build\.bazel|_test|test_' \
    | while read -r apex; do
        [ -n "$apex" ] || continue
        gen "$apex" 4096 keep || continue
        python3 "$AVBTOOL" extract_public_key --key "$DIR/$apex.pem" --output "$DIR/$apex.avbpubkey"
        echo "   $apex"
      done
else
  echo "   !! no synced tree (external/avb/avbtool.py) -- APEX keys skipped; re-run with --src <tree> after the first sync"
fi

[ -e "$DIR/keys.mk" ] || cat > "$DIR/keys.mk" <<'EOF'
# Sourced by vendor/lineage/config/common.mk. Every APK signs with the key of the same name in this
# directory, the OTA zip with releasekey, and ro.build.tags becomes dev-keys (not test-keys).
PRODUCT_DEFAULT_DEV_CERTIFICATE := vendor/lineage-priv/keys/releasekey
EOF
chmod 600 "$DIR"/*.pk8 "$DIR"/*.pem 2>/dev/null || true

cat <<EOF

>> done: $(ls "$DIR" | wc -l) files in $DIR
   fingerprint: $(openssl x509 -in "$DIR/releasekey.x509.pem" -noout -fingerprint -sha256 | cut -d= -f2)

   1. device.conf.local:  KEYS_DIR=$DIR
   2. back the directory up off this machine. There is no recovering a lost releasekey.
   3. the first signed build installcleans by itself; users coming from a test-keys build must wipe.
EOF
