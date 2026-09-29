#!/usr/bin/env bash
# repack-erofs-apex.sh — rebuild an APEX whose payload is EROFS so the payload is ext4 instead.
#
#   repack-erofs-apex.sh <dir-to-scan> [--aosp /aosp] [--keys DIR] [--dry-run]
#
# WHY: Android 15+ builds APEX payloads as EROFS. A kernel without CONFIG_EROFS_FS cannot mount
# them -- mount(2) returns ENODEV -- and apexd reports:
#
#   apexd: Mounting failed for package /product/apex/<name>.apex: No such device
#
# The APEX then never activates and everything inside it is simply absent at runtime, with no
# other symptom. Measured on a Pixel 3a XL (4.9 kernel) with MindTheGapps for Android 17: GmsCore
# ships only inside com.google.android.gmssystem.prodvic.apex, so Play Services never existed and
# SetupWizard hung forever on "Just a sec" while four Google processes crash-looped on
# "Failed to find provider com.google.android.gsf.gservices".
#
# Only PREBUILT apexes need this. Apexes this tree builds itself already follow the platform
# payload type, which is ext4 on such a device -- that is why 90 platform apexes mount and only the
# prebuilt one fails. Tell them apart by reading the payload magic, never by the filename.
#
# The rebuilt apex is signed with a per-apex key under KEYS_DIR, generated on first use. That is
# fine for a pre-installed apex: apexd checks the container signature against the public key
# bundled in the apex, so any self-consistent key works. It does mean an OTA carrying a NEWER
# version of the same apex must be signed with the same key -- keep KEYS_DIR.
set -u

DIR="${1:?usage: repack-erofs-apex.sh <dir-to-scan> [--aosp /aosp] [--keys DIR] [--dry-run]}"; shift
AOSP="${AOSP:-/aosp}"; KEYS="${KEYS_DIR:-}"; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --aosp) AOSP="$2"; shift 2 ;;
    --keys) KEYS="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "!! unknown argument: $1" >&2; exit 1 ;;
  esac
done
[ -d "$DIR" ] || { echo "!! no such directory: $DIR" >&2; exit 1; }

H="$AOSP/out/host/linux-x86/bin"
for t in deapexer apexer signapk avbtool debugfs_static fsck.erofs; do
  [ -x "$H/$t" ] || { echo "!! missing host tool $t -- build the tree first (it comes from out/host)" >&2; exit 1; }
done
[ -n "$KEYS" ] || { echo "!! KEYS_DIR unset: the rebuilt apex has to be signed" >&2; exit 1; }
mkdir -p "$KEYS" || exit 1

# EROFS superblock magic is 0xE0F5E1E2 little-endian at offset 1024.
is_erofs() { [ "$(dd if="$1" bs=1 skip=1024 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "e2e1f5e0" ]; }

TMP="${TMPDIR:-$AOSP/out/tmp}/repack-erofs-apex.$$"; mkdir -p "$TMP" || exit 1
trap 'rm -rf "$TMP"' EXIT
rc=0; found=0; done_n=0

while IFS= read -r -d '' apex; do
  unzip -q -o "$apex" apex_payload.img -d "$TMP/probe" 2>/dev/null || continue
  is_erofs "$TMP/probe/apex_payload.img" || { rm -rf "$TMP/probe"; continue; }
  rm -rf "$TMP/probe"
  found=$((found+1))
  name="$(basename "$apex" .apex)"
  echo ">> $name: EROFS payload, repacking as ext4"
  [ "$DRY" -eq 1 ] && continue

  W="$TMP/$name"; mkdir -p "$W/meta" "$W/payload"
  unzip -q -o "$apex" apex_manifest.pb apex_build_info.pb -d "$W/meta" 2>/dev/null
  [ -s "$W/meta/apex_manifest.pb" ] || { echo "   !! no apex_manifest.pb" >&2; rc=1; continue; }
  [ -s "$W/meta/apex_build_info.pb" ] || { echo "   !! no apex_build_info.pb -- apexer needs it for the fs config" >&2; rc=1; continue; }

  ANDROID_HOST_OUT="$AOSP/out/host/linux-x86" \
  "$H/deapexer" --debugfs_path "$H/debugfs_static" --fsckerofs_path "$H/fsck.erofs" \
      extract "$apex" "$W/payload" >/dev/null 2>&1 \
    || { echo "   !! extract failed" >&2; rc=1; continue; }
  # apexer writes its own; leaving the extracted copy makes e2fsdroid fail with
  # "Ext2 file already exists while writing file apex_manifest.pb".
  rm -f "$W/payload/apex_manifest.pb"

  # A pre-installed apex's payload is all system_file; the app inside is labelled by the platform
  # when it is installed from the mounted apex, not by this table.
  cat > "$W/file_contexts" <<EOF
(/.*)?                     u:object_r:system_file:s0
/apex_manifest\.pb         u:object_r:system_file:s0
/apex_manifest\.json       u:object_r:system_file:s0
/etc(/.*)?                 u:object_r:system_file:s0
/priv-app(/.*)?            u:object_r:system_file:s0
/app(/.*)?                 u:object_r:system_file:s0
/lib(64)?(/.*)?            u:object_r:system_lib_file:s0
EOF

  apexname="$(strings "$W/meta/apex_manifest.pb" | head -1)"
  [ -n "$apexname" ] || apexname="$name"
  # KEYS_DIR is mounted READ-ONLY into the build container, so the key cannot be made here. Make it
  # once on the host with tools/make-apex-key.sh and it is reused by every later build.
  for _k in pem avbpubkey pk8 x509.pem; do
    [ -f "$KEYS/$apexname.$_k" ] || {
      echo "   !! no signing key for $apexname ($KEYS/$apexname.$_k missing)." >&2
      echo "   !! Make it on the HOST, once:  forge/tools/make-apex-key.sh $apexname \"$KEYS\"" >&2
      rc=1; continue 2
    }
  done

  # apexer resolves prebuilts/sdk/... relative to the CWD, so it has to run from the tree root.
  ( cd "$AOSP" && PATH="$H:$PATH" ANDROID_HOST_OUT="$AOSP/out/host/linux-x86" TMPDIR="$TMP" \
      "$H/apexer" --force \
        --manifest "$W/meta/apex_manifest.pb" --build_info "$W/meta/apex_build_info.pb" \
        --file_contexts "$W/file_contexts" \
        --key "$KEYS/$apexname.pem" --pubkey "$KEYS/$apexname.avbpubkey" \
        --payload_fs_type ext4 --apexer_tool_path "$H" \
        "$W/payload" "$W/unsigned.apex" ) >"$W/apexer.log" 2>&1 \
    || { echo "   !! apexer failed -- see $W/apexer.log" >&2; tail -3 "$W/apexer.log" >&2; rc=1; continue; }

  # signapk, NOT apksigner: apexd loop-mounts apex_payload.img straight out of the zip, so its data
  # must start on a 4096-byte boundary. Only signapk --align-file-size does that. apksigner rewrites
  # the zip and leaves the payload at an arbitrary offset -- the apex then signs and verifies
  # perfectly and still fails to mount, with the kernel reporting
  #   blk_update_request: I/O error, dev loopN, sector 2
  #   EXT4-fs (loopN): unable to read superblock
  # and apexd reporting only "Invalid argument". zipalign afterwards does not help: signing undoes
  # it. LD_LIBRARY_PATH is needed or signapk dies loading its conscrypt native library.
  LD_LIBRARY_PATH="$AOSP/out/host/linux-x86/lib64:$AOSP/out/host/linux-x86/lib" \
  "$H/signapk" -a 4096 --align-file-size "$KEYS/$apexname.x509.pem" "$KEYS/$apexname.pk8" \
      "$W/unsigned.apex" "$W/signed.apex" >/dev/null 2>&1 \
    || { echo "   !! signapk failed" >&2; rc=1; continue; }

  unzip -q -o "$W/signed.apex" apex_payload.img -d "$W/check" 2>/dev/null
  if is_erofs "$W/check/apex_payload.img"; then echo "   !! still EROFS after repack" >&2; rc=1; continue; fi
  # An unaligned payload produces an apex that verifies and will not mount. Refuse to ship it.
  if ! python3 - "$W/signed.apex" <<'PYEOF'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1]); i = z.getinfo('apex_payload.img')
off = i.header_offset + len(i.FileHeader())
sys.exit(0 if off % 4096 == 0 else 1)
PYEOF
  then echo "   !! apex_payload.img is not 4096-aligned -- it would fail to mount" >&2; rc=1; continue; fi
  cp -f "$W/signed.apex" "$apex" || { rc=1; continue; }
  done_n=$((done_n+1))
  echo "   ok: $(du -h "$apex" | cut -f1), payload now ext4, signed as $apexname"
done < <(find "$DIR" -name '*.apex' -type f -print0 2>/dev/null)

if [ "$found" -eq 0 ]; then echo ">> no EROFS-payload apexes under $DIR (nothing to do)"; fi
[ "$DRY" -eq 1 ] || echo ">> repacked $done_n of $found"
exit $rc
