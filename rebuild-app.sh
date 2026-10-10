#!/usr/bin/env bash
# rebuild-app.sh — turn the smali from deodex-app.sh back into an installable apk. Step 2.
#
#   rebuild-app.sh <workdir-from-deodex-app.sh> <ims|cne>
#
# cne is a straight reassemble: CNEService references nothing Android removed, so its classes go
# back untouched.
#
# ims cannot be. It is built against com.android.ims, which Android 9 deleted, so the apk is
# rewritten into org.codeaurora.ims.legacy.* and the 7.1 framework classes it needs are recovered
# from the stock boot image, renamed the same way, and merged into its dex. The apk then carries
# its own copy of the legacy framework and needs no uses-library.
#
# Two rules the rename has to respect, and they pull in opposite directions:
#
#   * AIDL descriptor strings MUST be renamed. Android 13 still ships
#     com/android/ims/internal/IImsService.aidl with different methods, so leaving 7.1 interfaces
#     advertising the same descriptor invites a binder call across incompatible signatures.
#   * Broadcast action strings must NOT be. "com.android.ims.IMS_SERVICE_UP" and friends are a
#     contract with whoever listens, not class names.
#
# The rule that separates them: rewrite a string only when it exactly names a class being renamed.
#
# Output apk is UNSIGNED and has no META-INF. ims declares sharedUserId="android.uid.phone", so it
# must be signed with the platform key -- ship it via android_app_import with certificate:
# "platform" and let the build sign it. Do not presign.
set -u

W="${1:?usage: rebuild-app.sh <workdir> <ims|cne>}"
T="${2:?usage: rebuild-app.sh <workdir> <ims|cne>}"
# baksmali/smali come from the Android tree. Look where the tree actually is -- this runs both from
# the host (tree under build_output/src) and from inside the container (tree at /aosp, cwd /aosp).
if [ -z "${SMALI_DIR:-}" ]; then
  for _c in build_output/src/prebuilts/extract-tools/common/smali \
            prebuilts/extract-tools/common/smali \
            /aosp/prebuilts/extract-tools/common/smali; do
    [ -f "$_c/baksmali.jar" ] && SMALI_DIR="$_c" && break
  done
fi
SMALI_DIR="${SMALI_DIR:-build_output/src/prebuilts/extract-tools/common/smali}"
BK="$SMALI_DIR/baksmali.jar"; SM="$SMALI_DIR/smali.jar"
for j in "$BK" "$SM"; do [ -f "$j" ] || { echo "!! missing $j (set SMALI_DIR)" >&2; exit 1; }; done
[ -d "$W/smali" ] || { echo "!! $W/smali not found -- run deodex-app.sh first" >&2; exit 1; }

case "$T" in
  ims) APK=ims.apk ;;
  cne) APK=CNEService.apk ;;
  *)   echo "!! target must be ims or cne" >&2; exit 1 ;;
esac
[ -f "$W/in/$APK" ] || { echo "!! $W/in/$APK not found" >&2; exit 1; }

SRC="$W/smali"
if [ "$T" = "ims" ]; then
  echo ">> computing the legacy closure and renaming"
  python3 - "$W" <<'PY' || exit 1
import os,re,sys,shutil,collections
W=sys.argv[1]
OLD_P='com/android/ims'; NEW_P='org/codeaurora/ims/legacy'
OLD_D='com.android.ims';  NEW_D='org.codeaurora.ims.legacy'
roots=[l.strip() for l in open(f'{W}/surface.txt') if l.strip()]
idx={}
for base in (f'{W}/legacy/ims-common',f'{W}/legacy/framework2'):
    for dp,_,fns in os.walk(base):
        for fn in fns:
            if fn.endswith('.smali'):
                p=os.path.join(dp,fn); c=os.path.relpath(p,base)[:-6]
                if c.startswith(OLD_P): idx.setdefault(c,p)
ref=re.compile(rb'L('+OLD_P.encode()+rb'[A-Za-z0-9_/$]*);')
seen=set(); q=[c for r in roots for c in idx if c==r or c.startswith(r+'$')]
while q:
    c=q.pop()
    if c in seen or c not in idx: continue
    seen.add(c)
    for m in ref.finditer(open(idx[c],'rb').read()):
        t=m.group(1).decode()
        for c2 in idx:
            if (c2==t or c2.startswith(t+'$')) and c2 not in seen: q.append(c2)
miss=[r for r in roots if r not in idx]
if miss:
    print('!! not recoverable: '+', '.join(miss)); sys.exit(1)
dotted={c.replace('/','.') for c in seen}
type_re=re.compile(r'L'+OLD_P+r'([A-Za-z0-9_/$]*);')
str_re=re.compile(r'"([^"]*)"')
def rewrite(txt):
    txt=type_re.sub(lambda m:'L'+NEW_P+m.group(1)+';',txt)
    return str_re.sub(lambda m:'"'+NEW_D+m.group(1)[len(OLD_D):]+'"' if m.group(1) in dotted else m.group(0),txt)
out=f'{W}/merged'; shutil.rmtree(out,ignore_errors=True)
shutil.copytree(f'{W}/smali',out)
for dp,_,fns in os.walk(out):
    for fn in fns:
        if fn.endswith('.smali'):
            p=os.path.join(dp,fn)
            # Read fully, THEN write. open(p,'w') truncates as soon as it is evaluated, so doing
            # both in one expression hands rewrite() an empty string and silently blanks the file.
            txt=open(p).read()
            open(p,'w').write(rewrite(txt))
for c in seen:
    d=os.path.join(out,NEW_P+c[len(OLD_P):]+'.smali')
    os.makedirs(os.path.dirname(d),exist_ok=True)
    src_txt=open(idx[c]).read()
    open(d,'w').write(rewrite(src_txt))
bad=[os.path.join(dp,fn) for dp,_,fns in os.walk(out) for fn in fns
     if fn.endswith('.smali') and 'L'+OLD_P in open(os.path.join(dp,fn)).read()]
print(f"   legacy classes merged: {len(seen)}")
print(f"   files still referencing {OLD_P}: {len(bad)}")
if bad: sys.exit(1)
PY
  SRC="$W/merged"
fi

# Hidden-API: libcore's type-specific System.arraycopy overloads -- arraycopy([BI[BII)V and friends
# -- are @hide/@UnsupportedAppUsage fast paths, not public API. A 2016 apk calling one directly dies
# on 13 with
#     java.lang.IllegalAccessError: Method 'void java.lang.System.arraycopy(byte[], ...)'
#     is inaccessible to class ...
# at the first call, which for ims.apk is inside ImsService.onCreate -- so com.android.phone
# crash-loops and IMS never comes up. The generic arraycopy(Object,int,Object,int,int) IS public and
# accepts arrays, so redirecting to it is semantically identical and keeps hidden-API enforcement on.
echo ">> redirecting hidden-API System.arraycopy overloads to the public one"
n=$(grep -rlE 'Ljava/lang/System;->arraycopy\(\[[A-Z]I\[[A-Z]II\)V' "$SRC" 2>/dev/null | wc -l)
if [ "$n" -gt 0 ]; then
  grep -rlE 'Ljava/lang/System;->arraycopy\(\[[A-Z]I\[[A-Z]II\)V' "$SRC" 2>/dev/null | while read -r f; do
    sed -i -E 's#Ljava/lang/System;->arraycopy\(\[[A-Z]I\[[A-Z]II\)V#Ljava/lang/System;->arraycopy(Ljava/lang/Object;ILjava/lang/Object;II)V#g' "$f"
  done
fi
left=$(grep -rhoE 'Ljava/lang/System;->arraycopy\(\[[A-Z]I\[[A-Z]II\)V' "$SRC" 2>/dev/null | wc -l)
echo "   rewrote in $n file(s); specialized calls remaining: $left"
[ "$left" -eq 0 ] || { echo "!! specialized arraycopy survived the rewrite" >&2; exit 1; }

# ImsService.onCreate calls ImsVideoGlobals.init(), whose static initialiser dlopens the VT natives.
# That used to be fatal -- libimsmedia_jni.so wants android::Surface::Surface(sp<IGBP> const&, bool),
# a two-argument constructor Android 13 no longer has, so ImsMedia.<clinit> threw UnsatisfiedLinkError
# and took the whole IMS service down at onCreate. Deleting the call cost four further build
# cycles patching out the singletons it would have created: openForSub's getInstance(),
# maybeCreateVideoProvider's CameraController, and maybeUpdateLowBatteryStatus's LowBatteryHandler,
# the last of which was killing com.android.phone on every call.
#
# libshim_vtsurface.so now supplies that constructor and extract-ims-blobs.sh resizes the blob's
# allocation to match today's sizeof(Surface), so init() can run and create those singletons itself.
# The call therefore STAYS. The three rewrites below are kept as belt and braces: they only disable
# video paths, which cannot work regardless -- lib-imsvt.so needs IOMXObserver and
# IGraphicBufferAlloc, platform interfaces that were deleted outright -- and video calling is now
# switched off at the framework too via config_device_vt_available.
if [ "$T" = "ims" ]; then
  f="$SRC/org/codeaurora/ims/ImsService.smali"
  [ -f "$f" ] || { echo "!! ImsService.smali not found" >&2; exit 1; }
  keep=$(grep -c 'ImsVideoGlobals;->init(' "$f")
  [ "$keep" -eq 1 ] || { echo "!! expected exactly 1 ImsVideoGlobals.init call, found $keep" >&2; exit 1; }
  echo ">> keeping ImsVideoGlobals.init (libshim_vtsurface supplies the Surface ctor)"

  # Dropping init() is not enough on its own. openForSub does
  #     ImsVideoGlobals.getInstance().setActiveSub(sub)
  # and getInstance() throws RuntimeException when the singleton is null -- with the misleading text
  # "ImsVideoGlobals: Multiple initializaiton." So every startSession came back as an uncaught remote
  # exception and the IMS session was never usable, while the bridge logged a successful open.
  # setActiveSub's result is unused, so the whole call goes. Video stays unsupported either way.
  g="$SRC/org/codeaurora/ims/ImsService\$2.smali"
  [ -f "$g" ] || { echo "!! ImsService\$2.smali not found" >&2; exit 1; }
  gi=$(grep -c 'ImsVideoGlobals;->getInstance()' "$g")
  sa=$(grep -c 'ImsVideoGlobals;->setActiveSub(' "$g")
  [ "$gi" -eq 1 ] && [ "$sa" -eq 1 ] || {
    echo "!! expected one getInstance and one setActiveSub in ImsService\$2, found $gi/$sa" >&2; exit 1; }
  python3 - "$g" <<'PYIN'
import io,re,sys
p=sys.argv[1]; lines=io.open(p,encoding='utf-8').read().split('\n')
out=[]; i=0; removed=0
while i < len(lines):
    l=lines[i]
    if 'ImsVideoGlobals;->getInstance()' in l:
        # drop the invoke and the move-result that consumes it
        i+=1; removed+=1
        while i < len(lines) and lines[i].strip()=='':
            i+=1
        if i < len(lines) and lines[i].strip().startswith('move-result-object'):
            i+=1; removed+=1
        continue
    if 'ImsVideoGlobals;->setActiveSub(' in l:
        i+=1; removed+=1
        continue
    out.append(l); i+=1
io.open(p,'w',encoding='utf-8').write('\n'.join(out))
print("   removed %d instruction(s) from openForSub" % removed)
PYIN
  left=$(grep -c 'ImsVideoGlobals' "$g")
  [ "$left" -eq 0 ] || { echo "!! ImsVideoGlobals references survived in ImsService\$2" >&2; exit 1; }

  # Third consequence of dropping init(): ImsCallSessionImpl.maybeCreateVideoProvider constructs an
  # ImsVideoCallProviderImpl, whose constructor calls CameraController.getInstance(), which throws
  #     java.lang.RuntimeException: CameraController: Not initialized
  # because init() is exactly what would have initialised it. The throw crosses binder as an uncaught
  # remote exception, so createCallSession returns null and every outgoing call fails. Worse, Telecom
  # has already built a connection by then, so the call wedges in DISCONNECTING and the device needs
  # a reboot before it can dial again.
  #
  # The guard is isConfigEnabled(0x7f030005), a bool in ims.apk's OWN resources, so the framework's
  # config_device_vt_available cannot switch it off. Force the parameter false at method entry and
  # the existing `if-eqz p1` early-return does the rest. Video stays unsupported either way.
  echo ">> forcing maybeCreateVideoProvider to no-op (CameraController is never initialised)"
  h="$SRC/org/codeaurora/ims/ImsCallSessionImpl.smali"
  [ -f "$h" ] || { echo "!! ImsCallSessionImpl.smali not found" >&2; exit 1; }
  python3 - "$h" <<'PYIN'
import io, sys
p = sys.argv[1]
lines = io.open(p, encoding='utf-8').read().split('\n')
out, i, done = [], 0, 0
SKIP = ('.registers', '.param', '.prologue', '.line', '.local')
while i < len(lines):
    out.append(lines[i])
    if lines[i].strip() == '.method private maybeCreateVideoProvider(Z)V':
        j = i + 1
        while j < len(lines) and (lines[j].strip() == '' or lines[j].strip().startswith(SKIP)):
            out.append(lines[j]); j += 1
        got = lines[j].strip() if j < len(lines) else '<eof>'
        if not got.startswith('if-eqz p1,'):
            print('!! expected "if-eqz p1," first, got: %r' % got); sys.exit(1)
        out.append('    const/4 p1, 0x0')
        done += 1
        i = j
        continue
    i += 1
if done != 1:
    print('!! expected exactly 1 maybeCreateVideoProvider, patched %d' % done); sys.exit(1)
io.open(p, 'w', encoding='utf-8').write('\n'.join(out))
print('   neutralised %d site(s)' % done)
PYIN
  [ $? -eq 0 ] || exit 1

  # Fourth site, same root: ImsCallSessionImpl.maybeUpdateLowBatteryStatus calls
  # LowBatteryHandler.getInstance(), which ImsVideoGlobals.init() would have initialised, so it
  # throws "LowBatteryHandler: Not initialized". It is reached from updateImsCallProfile via the
  # ImsCallSessionImpl constructor on ImsServiceClassTracker.handleCalls -- whenever the modem
  # reports a call -- and it is a FATAL EXCEPTION on com.android.phone's main thread. Telephony dies
  # mid-call-setup and the dialer is left holding a stuck tone.
  #
  # The method returns Z and callers read false as "nothing to report", which is the desired result: no VT,
  # no low-battery video downgrade. Force the early return.
  #
  # NOTE: this is the FOURTH place dropping init() has surfaced. If a fifth appears, stop patching
  # call sites and do the Surface shim instead so init() can run -- see VOLTE-BRINGUP.md.
  echo ">> forcing maybeUpdateLowBatteryStatus to no-op (LowBatteryHandler is never initialised)"
  python3 - "$h" <<'PYIN'
import io, sys
p = sys.argv[1]
lines = io.open(p, encoding='utf-8').read().split('\n')
out, i, done = [], 0, 0
SKIP = ('.registers', '.param', '.prologue', '.line', '.local')
while i < len(lines):
    out.append(lines[i])
    if lines[i].strip() == '.method private maybeUpdateLowBatteryStatus()Z':
        j = i + 1
        while j < len(lines) and (lines[j].strip() == '' or lines[j].strip().startswith(SKIP)):
            out.append(lines[j]); j += 1
        # Force the existing guard rather than inserting a return: the method opens with
        #     iget-boolean vN, p0, ...->mStateChangeReportingAllowed:Z
        #     if-nez vN, :cond_...
        # so zeroing that register takes the already-present "ignore, return false" path. Inserting
        # a bare `return` instead would leave the rest of the method unreachable.
        if j >= len(lines) or 'mStateChangeReportingAllowed' not in lines[j]:
            print('!! expected the mStateChangeReportingAllowed read first, got: %r'
                  % (lines[j].strip() if j < len(lines) else '<eof>')); sys.exit(1)
        reg = lines[j].split(',')[0].split()[-1]
        out.append(lines[j]); j += 1
        out.append('    const/4 %s, 0x0' % reg)
        done += 1
        i = j
        continue
    i += 1
if done != 1:
    print('!! expected exactly 1 maybeUpdateLowBatteryStatus, patched %d' % done); sys.exit(1)
io.open(p, 'w', encoding='utf-8').write('\n'.join(out))
print('   neutralised %d site(s)' % done)
PYIN
  [ $? -eq 0 ] || exit 1

fi

# Parcel.readParcelable(null) -- the rename's sharpest edge.
#
# On 7.1 these classes were com.android.ims.*, which lived on the BOOT classpath, so
# readParcelable(null) resolved them: a null loader makes Parcel fall back to its own
# (framework) loader. Renaming them into the app, and an app class is invisible to the boot
# loader, so the first inbound ImsCallProfile dies with
#     ClassNotFoundException: org.codeaurora.ims.legacy.ImsStreamMediaProfile
#         at ...ImsCallProfile.readFromParcel
# inside IImsService$Stub.onTransact, and every createCallSession fails.
#
# Rewrite each call site to pass the class's own loader. Inserted immediately before the invoke
# so the register is correct at the point of use regardless of what the prologue put there.
echo ">> repointing Parcel.readParcelable(null) at the app class loader"
python3 - "$SRC" <<'PYIN'
import io, os, re, sys
src = sys.argv[1]
INV = re.compile(r'^(\s*)invoke-virtual \{([pv]\d+), ([pv]\d+)\}, Landroid/os/Parcel;->readParcelable\(Ljava/lang/ClassLoader;\)')
total = 0
for root, _, files in os.walk(src):
    for fn in files:
        if not fn.endswith('.smali'):
            continue
        path = os.path.join(root, fn)
        text = io.open(path, encoding='utf-8').read()
        if 'Landroid/os/Parcel;->readParcelable(' not in text:
            continue
        lines = text.split('\n')
        cls = next((l.split()[-1] for l in lines if l.startswith('.class ')), None)
        if not cls:
            print('!! no .class in %s' % path); sys.exit(1)
        out = []
        for l in lines:
            m = INV.match(l)
            if m:
                ind, reg = m.group(1), m.group(3)
                out.append('%sconst-class %s, %s' % (ind, reg, cls))
                out.append('%sinvoke-virtual {%s}, Ljava/lang/Class;->getClassLoader()Ljava/lang/ClassLoader;' % (ind, reg))
                out.append('%smove-result-object %s' % (ind, reg))
                total += 1
            out.append(l)
        io.open(path, 'w', encoding='utf-8').write('\n'.join(out))
print('   repointed %d readParcelable call site(s)' % total)
if total != 4:
    print('!! expected 4 readParcelable call sites, found %d' % total); sys.exit(1)
PYIN
[ $? -eq 0 ] || exit 1

echo ">> assembling classes.dex"
java -jar "$SM" a "$SRC" -o "$W/classes.dex" 2>/dev/null || { echo "!! assembly failed" >&2; exit 1; }
echo "   $(java -jar "$BK" list classes "$W/classes.dex" 2>/dev/null | wc -l) classes"

echo ">> rebuilding $APK"
OUT="$W/${APK%.apk}-rebuilt.apk"
rm -f "$OUT"; cp "$W/in/$APK" "$OUT" || exit 1
zip -q -d "$OUT" 'META-INF/*' >/dev/null 2>&1
( cd "$W" && zip -q -j "$(basename "$OUT")" classes.dex ) || exit 1

# An apk that kept its stripped state, or quietly lost content, still builds and installs. Compare
# against the original rather than assuming a fixed layout -- CNEService.apk legitimately has no
# resources.arsc and no res/, it is a manifest-only app.
unzip -l "$OUT" 2>/dev/null | grep -q 'classes\.dex' || { echo "!! no classes.dex in the apk" >&2; exit 1; }
unzip -l "$OUT" 2>/dev/null | grep -qE ' META-INF/' && { echo "!! stale signature left in place" >&2; exit 1; }
lost=$(LC_ALL=C comm -23 \
  <(unzip -Z1 "$W/in/$APK" 2>/dev/null | grep -vE '^META-INF/' | LC_ALL=C sort) \
  <(unzip -Z1 "$OUT"       2>/dev/null | LC_ALL=C sort))
[ -z "$lost" ] || { echo "!! entries lost from the original apk:"; echo "$lost" | sed 's/^/   /'; exit 1; }
n=$(unzip -p "$OUT" classes.dex 2>/dev/null | wc -c)
echo "   $OUT  (classes.dex $n bytes, unsigned, resources intact)"
