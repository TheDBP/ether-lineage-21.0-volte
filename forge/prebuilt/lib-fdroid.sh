#!/usr/bin/env bash
# lib-fdroid.sh — fetch the build F-Droid currently suggests for a package, trusting the signer,
# not a file hash. Source it; then:
#
#   fdroid_fetch_latest PKG OUT SIGNER_SHA256 [LABEL]
#
# Resolves PKG's suggestedVersionCode from the F-Droid API, downloads that APK to OUT unless OUT
# already is that version, and accepts it only if
#   - aapt2 reports the package name PKG,
#   - if it carries native code at all, some of it is arm64-v8a (an armeabi-only build would
#     install and then crash; a pure-Java build is fine),
#   - apksigner verifies it and the first signer certificate's sha256 is SIGNER_SHA256.
# The signer pin is what makes "latest" safe: the key is the one thing that does not change between
# releases, and it is checked over the whole file (v2/v3 signature), so a tampered or truncated
# download fails here. To get a new signing key accepted, change the pin on purpose.
#
# FDROID_PINS="pkg=versionCode pkg=versionCode" pins packages to one exact build instead (to
# reproduce a release, or to hold back a known-bad update). Anything not listed stays on latest.
#
# Offline: if the API cannot be reached but OUT exists and verifies, it is used with a warning; a
# missing or bad OUT is an error. Runs in-container: needs curl, unzip, and the tree's aapt2, JDK
# and apksigner.jar (AOSP in $AOSP, default /aosp).
#
# The fetchers build on it with:
#
#   fdroid_stage PKG APK SIGNER_SHA256 LABEL LIBDIR
#       fetch_latest, then classify the APK (fdroid_apk_libs_loadable) and, if its native libraries
#       cannot be loaded out of the archive, unpack lib/arm64-v8a/*.so to LIBDIR/lib/arm64-v8a/ for
#       the module to install beside the APK. Sets FDROID_UNPACKED=yes|no.
#   fdroid_bp_wanted DIR
#       true when DIR/.gitignore lists /Android.bp: the branch's patch ships no module file and the
#       fetcher writes it. (20.0 patches ship Android.mk and no such line; a branch with no patch
#       for the option has no .gitignore, so nothing is written where nothing is built.)
#   fdroid_bp_begin FILE WRITER; fdroid_bp_module FILE NAME APK PKG UNPACKED [EXTRA_PROPERTY...]
#       write the Soong module file: header, then one android_app_import per call.
#       skip_preprocessed_apk_checks is set exactly when UNPACKED=yes, which is what Soong's check
#       demands (it fails the build if the flag is set on an APK that passes, or missing on one that
#       does not).
set -o pipefail

FDROID_API="${FDROID_API:-https://f-droid.org/api/v1/packages}"
FDROID_REPO="${FDROID_REPO:-https://f-droid.org/repo}"
FDROID_ARCHIVE="${FDROID_ARCHIVE:-https://f-droid.org/archive}"
# Official mirrors (f-droid.org/docs/Running-a-Mirror), tried after the primary. Safe to use: every
# download is accepted only on the pinned signer, so a mirror can at most fail to have the file.
FDROID_MIRRORS="${FDROID_MIRRORS:-https://mirror.cyberbits.eu/fdroid https://ftp.lysator.liu.se/pub/fdroid https://fdroid.tetaneutral.net/fdroid https://mirror.fcix.net/fdroid https://ftp.fau.de/fdroid}"

_fdroid_aapt2() {
  command -v aapt2 2>/dev/null || echo "${AOSP:-/aosp}/prebuilts/sdk/tools/linux/bin/aapt2"
}
_fdroid_java() {
  local j
  j="$(ls -d "${AOSP:-/aosp}"/prebuilts/jdk/jdk*/linux-x86/bin/java 2>/dev/null | sort -V | tail -1)"
  [ -x "$j" ] && { echo "$j"; return; }
  command -v java
}
# True when this tree's Soong understands skip_preprocessed_apk_checks. Checked against the source
# rather than inferred from the branch name, so a backport or a new branch is picked up for free.
_fdroid_soong_has_skip_checks() {
  grep -rqs 'SkipPreprocessedApkChecks\|skip_preprocessed_apk_checks' \
    "${AOSP:-/aosp}/build/soong" 2>/dev/null
}

_fdroid_apksigner_jar() { echo "${AOSP:-/aosp}/prebuilts/sdk/tools/linux/lib/apksigner.jar"; }
_fdroid_zipalign() { echo "${AOSP:-/aosp}/prebuilts/build-tools/linux-x86/bin/zipalign"; }

# apk -> versionCode as aapt2 reads it, or empty
fdroid_apk_version_code() {
  "$(_fdroid_aapt2)" dump badging "$1" 2>/dev/null | sed -n "s/^package:.*versionCode='\([0-9]*\)'.*/\1/p" | head -1
}
fdroid_apk_version_name() {
  "$(_fdroid_aapt2)" dump badging "$1" 2>/dev/null | sed -n "s/^package:.*versionName='\([^']*\)'.*/\1/p" | head -1
}
# apk -> sha256 of the first signer certificate, only if the signature verifies; empty otherwise
fdroid_apk_signer() {
  local java jar
  java="$(_fdroid_java)"; jar="$(_fdroid_apksigner_jar)"
  [ -x "$java" ] && [ -f "$jar" ] || { echo "!! no JDK or apksigner.jar in the tree — cannot verify signatures" >&2; return 1; }
  "$java" -jar "$jar" verify --print-certs "$1" 2>/dev/null | sed -n 's/^Signer #1 certificate SHA-256 digest: *\([0-9a-f]*\).*/\1/p' | head -1
}

# apk -> "yes" if its native libraries can be loaded straight out of the archive (every lib/**/*.so
# stored, archive page-aligned), "no" otherwise; nonzero if it cannot tell. This is exactly Soong's
# check_prebuilt_presigned_apk.py test for a preprocessed APK: skip_preprocessed_apk_checks must be
# set on a "no" APK and must NOT be set on a "yes" one, or the build fails either way. A "no" APK
# shipped byte for byte also needs its arm64 libraries unpacked beside it: PackageManager does not
# extract native libraries for a bundled app, and the linker cannot dlopen a compressed entry.
fdroid_apk_libs_loadable() {
  local za n
  za="$(_fdroid_zipalign)"
  [ -x "$za" ] || { echo "!! zipalign not found in the tree — cannot classify $1" >&2; return 1; }
  if ! "$za" -c -p 4 "$1" >/dev/null 2>&1; then echo no; return 0; fi
  n="$(unzip -v "$1" 'lib/*.so' 2>/dev/null | awk '$NF ~ /^lib\/.*\.so$/ && $2 != "Stored" {c++} END {print c+0}')"
  [ "$n" -gt 0 ] && echo no || echo yes
}

# apk -> "yes" if any classes*.dex entry is compressed. Soong's check also refuses that on a
# preprocessed PRIVILEGED app (--uncompress-priv-app-dex, on unless the device sets
# DONT_UNCOMPRESS_PRIV_APPS_DEXS), so skip_preprocessed_apk_checks must be set on one. Compressed
# dex in a priv-app is a performance policy, not a runtime requirement: it runs.
fdroid_apk_dex_compressed() {
  local n
  n="$(unzip -v "$1" 'classes*.dex' 2>/dev/null | awk '$NF ~ /^classes[0-9]*\.dex$/ && $2 != "Stored" {c++} END {print c+0}')"
  [ "$n" -gt 0 ] && echo yes || echo no
}

# pkg -> suggestedVersionCode, or nonzero (offline, unknown package)
fdroid_latest_version_code() {
  local json
  json="$(curl -fsS --max-time 30 "$FDROID_API/$1")" || return 1
  printf '%s' "$json" | sed -n 's/.*"suggestedVersionCode":\([0-9]*\).*/\1/p' | head -1 | grep -E '^[0-9]+$'
}

# _fdroid_verify APK PKG SIGNER -> 0 if the apk is PKG, arm64, and signed by SIGNER
_fdroid_verify() {
  local apk="$1" pkg="$2" signer="$3" aapt2 got
  aapt2="$(_fdroid_aapt2)"
  [ -x "$aapt2" ] || { echo "!! aapt2 not found — cannot verify $apk" >&2; return 1; }
  [ "$("$aapt2" dump packagename "$apk" 2>/dev/null)" = "$pkg" ] || { echo "!! $apk: wrong package (want $pkg)" >&2; return 1; }
  # capture-then-count: `grep -q` exits early -> unzip SIGPIPEs -> pipefail fails a VALID apk.
  if [ "$(unzip -l "$apk" 2>/dev/null | grep -c ' lib/' || true)" -gt 0 ]; then
    [ "$(unzip -l "$apk" 2>/dev/null | grep -c 'lib/arm64-v8a/' || true)" -gt 0 ] || { echo "!! $apk: not an arm64 build" >&2; return 1; }
  fi
  got="$(fdroid_apk_signer "$apk")" || return 1
  [ "$got" = "$signer" ] || { echo "!! $apk: signer $got is not the pinned $signer" >&2; return 1; }
}

# _fdroid_download FILE DEST: primary repo, primary archive, each mirror's repo and archive
_fdroid_download() {
  local base
  for base in "$FDROID_REPO" "$FDROID_ARCHIVE" $(for m in $FDROID_MIRRORS; do echo "$m/repo $m/archive"; done); do
    curl -fsL --retry 2 --max-time 1800 -o "$2" "$base/$1" && return 0
  done
  return 1
}

fdroid_fetch_latest() {
  local pkg="$1" out="$2" signer="$3" label="${4:-$1}" want have pin tmp
  mkdir -p "$(dirname "$out")"

  pin="$(printf '%s\n' ${FDROID_PINS:-} | sed -n "s/^$pkg=\([0-9]*\)$/\1/p" | head -1)"
  if [ -n "$pin" ]; then
    want="$pin"; echo "   $label: pinned to versionCode $want (FDROID_PINS)"
  elif ! want="$(fdroid_latest_version_code "$pkg")"; then
    if [ -f "$out" ] && _fdroid_verify "$out" "$pkg" "$signer"; then
      echo "   $label: F-Droid unreachable; using the cached $(fdroid_apk_version_name "$out") (verified)"
      return 0
    fi
    echo "!! $label: cannot resolve the current F-Droid build of $pkg and no verified copy is cached" >&2
    return 1
  fi

  if [ -f "$out" ]; then
    have="$(fdroid_apk_version_code "$out")"
    if [ "$have" = "$want" ] && _fdroid_verify "$out" "$pkg" "$signer" 2>/dev/null; then
      echo "   ok (cached): $label $(fdroid_apk_version_name "$out") ($want)"
      return 0
    fi
  fi

  # Primary repo/ and archive/, then the mirrors: the primary has been seen 404 a file the API
  # still suggests while every mirror served it. If nothing has it, a verified cached copy of any
  # version beats no app.
  tmp="$out.download"
  echo ">> downloading $label ${pkg}_$want.apk (F-Droid)"
  if ! _fdroid_download "${pkg}_$want.apk" "$tmp"; then
    rm -f "$tmp"
    if [ -f "$out" ] && _fdroid_verify "$out" "$pkg" "$signer"; then
      echo "   $label: F-Droid has no ${pkg}_$want.apk right now; using the cached $(fdroid_apk_version_name "$out") (verified)"
      return 0
    fi
    echo "!! $label: download failed and no verified copy is cached" >&2; return 1
  fi
  _fdroid_verify "$tmp" "$pkg" "$signer" || { rm -f "$tmp"; echo "!! $label: verification failed — refusing to use it" >&2; return 1; }
  mv -f "$tmp" "$out"
  echo "   verified: $label $(fdroid_apk_version_name "$out") ($want) — $pkg, arm64, signer pinned"
}

# fdroid_stage PKG APK SIGNER LABEL LIBDIR -> fetch + classify + unpack; FDROID_UNPACKED=yes|no
fdroid_stage() {
  local pkg="$1" apk="$2" signer="$3" label="$4" libdir="$5" loadable
  FDROID_UNPACKED=no
  fdroid_fetch_latest "$pkg" "$apk" "$signer" "$label" || return 1
  # Re-derived on every run from the APK that is there, so a release that changes its packaging
  # changes the wiring with it, in either direction.
  rm -rf "${libdir:?}/lib"
  loadable="$(fdroid_apk_libs_loadable "$apk")" || return 1
  [ "$loadable" = no ] || return 0
  mkdir -p "$libdir"
  unzip -q -o "$apk" 'lib/arm64-v8a/*.so' -d "$libdir" || { echo "!! $label: could not unpack native libraries" >&2; return 1; }
  echo "   $label: native libraries not loadable from the APK; unpacked $(ls "$libdir/lib/arm64-v8a" | wc -l) beside it"
  FDROID_UNPACKED=yes
}

fdroid_bp_wanted() { grep -qx '/Android.bp' "$1/.gitignore" 2>/dev/null; }

fdroid_bp_begin() {  # FILE WRITER
  {
    echo "// Written by forge/prebuilt/$2 on every fetch from the APKs it fetched; gitignored, not"
    echo "// edited by hand. Native libraries for the apps marked below are unpacked beside the APK and"
    echo "// installed by jni/Android.mk."
    echo "//"
    echo "// preprocessed: true installs each APK byte for byte. Any rewrite (uncompressing libs or dex,"
    echo "// re-aligning) invalidates the whole-file APK Signature Scheme v2 signature, and PackageManager"
    echo "// then rejects the package at boot scan without logging, so the build succeeds and the app is"
    echo "// absent. skip_preprocessed_apk_checks goes on exactly the APKs whose native libraries are"
    echo "// compressed or unaligned, or that are privileged with compressed dex: Soong fails the build"
    echo "// if it is set on one that passes the check."
    echo "// enforce_uses_libs: false -- the build otherwise refuses any APK whose manifest <uses-library>"
    echo "// tags it was not told about, and those change with releases."
  } > "$1"
}

fdroid_bp_module() {  # FILE NAME APK PKG UNPACKED [EXTRA_PROPERTY...]
  local file="$1" name="$2" apk="$3" pkg="$4" unpacked="$5" skip=""; shift 5
  [ "$unpacked" = yes ] && skip="libraries unpacked beside the APK"
  case " $* " in *" privileged: true, "*)
    [ "$(fdroid_apk_dex_compressed "$(dirname "$file")/$apk")" = yes ] && skip="${skip:+$skip; }privileged with compressed dex" ;;
  esac
  {
    echo
    echo "// $pkg"
    echo "android_app_import {"
    echo "    name: \"$name\","
    echo "    apk: \"$apk\","
    echo "    presigned: true,"
    echo "    preprocessed: true,"
    # skip_preprocessed_apk_checks exists only where Soong has the check it bypasses. It is valid on
    # lineage-24.0 and absent on lineage-20.0 (Android 13), where emitting it fails the build outright
    # with "unrecognized property" -- and check_prebuilt_presigned_apk.py, the thing it would bypass,
    # is not there either, so omitting it loses nothing. Ask the tree rather than assume the branch.
    [ -n "$skip" ] && _fdroid_soong_has_skip_checks && \
      echo "    skip_preprocessed_apk_checks: true, // $skip"
    echo "    product_specific: true,"
    echo "    enforce_uses_libs: false,"
    for p in "$@"; do echo "    $p"; done
    echo "}"
  } >> "$file"
}
