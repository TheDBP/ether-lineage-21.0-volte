#!/usr/bin/env bash
# prefetch.sh — download the build's network inputs into /dl, IN-CONTAINER, so they overlap `repo
# sync` instead of running serially after it. Consumed later by the extractors (from /dl). Each
# *_URL is optional, but a set-but-FAILED download is fatal: a missing
# input must stop the build, never silently degrade the ROM.
set -euo pipefail
mkdir -p /dl

# Cache key is the URL, not just the filename. A bare [ -f "$dest" ] check is NOT enough: when
# ether's GApps URL changed from Android-11 to Android-12.1, the Android-11 zip was still sitting in
# /dl under the same name, and a plain existence check would have silently rebuilt the wrong GApps
# straight back in. The recorded size additionally catches a download that was interrupted partway,
# which otherwise looks exactly like a valid cache hit -- bonito had a half-written 271 MB gapps.zip
# for precisely this reason.
dl() {  # $1=url  $2=dest-name  $3=label
  local url="$1" dest="/dl/$2" label="$3" meta="/dl/$2.url"
  if [ -s "$dest" ] && [ -f "$meta" ]; then
    local want_url="" want_size="" have_size=""
    want_url=$(sed -n 1p "$meta" 2>/dev/null || true)
    want_size=$(sed -n 2p "$meta" 2>/dev/null || true)
    have_size=$(stat -c %s "$dest" 2>/dev/null || echo 0)
    if [ "$want_url" = "$url" ] && [ "$want_size" = "$have_size" ]; then
      echo ">> prefetch: $label -- cached, skipping ($(du -h "$dest" 2>/dev/null | cut -f1))"
      return 0
    fi
    if [ "$want_url" != "$url" ]; then
      echo ">> prefetch: $label -- cached copy is from a different URL, refetching"
    else
      echo ">> prefetch: $label -- cached copy is truncated ($have_size != $want_size), refetching"
    fi
  fi
  echo ">> prefetch: $label"
  rm -f "$meta"                     # drop the receipt first: a failed download must not look cached
  curl -fSL -o "$dest" "$url" || { echo "!! prefetch failed: $label ($url)" >&2; exit 1; }
  printf '%s\n%s\n' "$url" "$(stat -c %s "$dest" 2>/dev/null || echo 0)" > "$meta"
  echo "   got $label ($(du -h "$dest" 2>/dev/null | cut -f1))"
}

[ -n "${STOCK_DL_URL:-}" ]   && dl "$STOCK_DL_URL"   "stock.zip"   "stock ROM"
[ -n "${GAPPS_DL_URL:-}" ]   && dl "$GAPPS_DL_URL"   "gapps.zip"   "NikGapps"
# Magisk is tiny and caches into /repo/forge/prebuilt/; prefetch it too so nothing is left for later.
[ -f /repo/forge/prebuilt/fetch-magisk.sh ] && bash /repo/forge/prebuilt/fetch-magisk.sh || true
echo ">> prefetch done."
