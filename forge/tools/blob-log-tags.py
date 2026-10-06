#!/usr/bin/env python3
"""blob-log-tags.py -- find which logcat tags a prebuilt .so logs under, by resolving the tag literal
at its __android_log_* call sites.

  blob-log-tags.py <lib.so> [--objdump PATH] [--window N] [-v]
  blob-log-tags.py libimsmmpf.so            -> MMPF  (and the prio of each call site)

Why: a vendor blob that misbehaves silently is usually not silent -- it is logging under a tag nobody
thought to grep. `logcat` shows you the tags of processes you already know about; a library linked
into someone else's process contributes its own tag, and `strings` cannot tell you which of the
thousands of literals is the tag. Finding them turns "no logs" into a diagnosis: on the V20 the LG
IMS media stack logged the real cause of a call failure under MMPF and QMI_FW while the only tag
anyone filtered on was the SIP core's.

How: disassemble, find calls to __android_log_print / _write / _buf_write / _assert, and walk back
from each call site for the instruction that loads the tag argument (arg 2, or arg 3 for buf_write):
arm64 `adrp`+`add`, arm32 `movw`+`movt` or a pc-relative literal load. Resolve that address through
the program headers to a NUL-terminated string. Counts per tag, so the blob's main tag is the top
row. Priority (arg 1) is reported when it is an immediate: a tag that only ever logs at V/D is
useless on a `userdebug` build with default log levels, one that logs E is where to look first.

Heuristic by nature -- it reports what it resolved and how many call sites it could not. A tag it
misses is a tag you would not have found at all; a tag it invents would have to survive being a
plausible NUL-terminated string at a code-referenced address, which is rare but check anything
surprising against `strings`. ARM/AArch64 little-endian ELF.
"""
import argparse, os, re, struct, subprocess, sys
from collections import Counter, defaultdict

# A logcat tag is a short identifier-ish string. Mis-resolved addresses land on fragments of other
# literals (")", "]", a word out of a format string), so require that shape and report the rest only
# under -v. Costs the occasional real tag with odd punctuation; buys output you can act on.
TAG_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_.:/+-]{0,22}$')

LOG_FNS = ('__android_log_print', '__android_log_write', '__android_log_buf_write',
           '__android_log_assert', '__android_log_vprint', '__android_log_buf_print')
# tag argument position (0-based register index) per function
TAG_ARG = {'__android_log_print': 1, '__android_log_vprint': 1, '__android_log_write': 1,
           '__android_log_assert': 1, '__android_log_buf_write': 2, '__android_log_buf_print': 2}


class Elf:
    def __init__(self, path):
        self.d = open(path, 'rb').read()
        if self.d[:4] != b'\x7fELF':
            raise SystemExit('!! not an ELF: ' + path)
        self.is64 = self.d[4] == 2
        if self.is64:
            phoff = struct.unpack_from('<Q', self.d, 0x20)[0]
            phentsize, phnum = struct.unpack_from('<HH', self.d, 0x36)
            fmt, voff, foff, fsz = '<IIQQQQQQ', 3, 2, 5
        else:
            phoff = struct.unpack_from('<I', self.d, 0x1c)[0]
            phentsize, phnum = struct.unpack_from('<HH', self.d, 0x2a)
            fmt, voff, foff, fsz = '<IIIIIIII', 2, 1, 4
        self.segs = []
        for i in range(phnum):
            f = struct.unpack_from(fmt, self.d, phoff + i * phentsize)
            if f[0] == 1:  # PT_LOAD
                self.segs.append((f[voff], f[foff], f[fsz]))

    def read_cstr(self, vaddr, limit=96):
        for va, off, fsz in self.segs:
            if va <= vaddr < va + fsz:
                o = off + (vaddr - va)
                end = self.d.find(b'\0', o, o + limit)
                if end < 0:
                    return None
                raw = self.d[o:end]
                if not raw:
                    return ''
                try:
                    s = raw.decode('utf-8')
                except UnicodeDecodeError:
                    return None
                return s if all(32 <= ord(c) < 127 for c in s) else None
        return None

    def u32(self, vaddr):
        for va, off, fsz in self.segs:
            if va <= vaddr < va + fsz - 3:
                return struct.unpack_from('<I', self.d, off + (vaddr - va))[0]
        return None


def disasm(objdump, path, triple=None):
    cmd = [objdump, '-d', '--no-show-raw-insn']
    if triple:
        cmd.append('--triple=' + triple)
    p = subprocess.run(cmd + [path], capture_output=True, text=True, errors='replace')
    if p.returncode != 0:
        # Forcing the wrong instruction set makes llvm-objdump abort outright on some blobs
        # ("LLVM ERROR: tBcc: expected 3 operands"). That is an answer about the triple, not a
        # fatal error -- let the caller try the next one.
        return []
    rows = []
    for line in p.stdout.splitlines():
        m = re.match(r'\s*([0-9a-f]+):\s+(\S+)\s*(.*)', line)
        if m:
            rows.append((int(m.group(1), 16), m.group(2), m.group(3).strip()))
    return rows


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument('lib'); ap.add_argument('--objdump', default=os.environ.get('OBJDUMP', 'llvm-objdump'))
    ap.add_argument('--window', type=int, default=24); ap.add_argument('-v', action='store_true')
    ap.add_argument('-h', '--help', action='store_true')
    a = ap.parse_args()
    if a.help:
        print(__doc__); return
    elf = Elf(a.lib)

    def find_sites(rows):
        out = []
        for i, (addr, mnem, ops) in enumerate(rows):
            if not (mnem.startswith('bl') or mnem.startswith('b.') or mnem == 'b'):
                continue
            for fn in LOG_FNS:
                if fn in ops:
                    out.append((i, fn)); break
        return out

    # A stripped 32-bit ARM blob has no $t/$a mapping symbols, so objdump guesses ARM and silently
    # mis-decodes Thumb into plausible garbage (no call sites, bogus branch targets). Try both and
    # keep whichever actually finds log calls.
    triples = [None] if elf.is64 else [None, 'thumbv7-linux-android', 'armv7-linux-android']
    rows, sites, used = [], [], None
    for t in triples:
        r = disasm(a.objdump, a.lib, t)
        sv = find_sites(r)
        if len(sv) > len(sites) or (not rows and r):
            rows, sites, used = r, sv, t
    if not rows:
        raise SystemExit('!! no disassembly from any triple tried '
                         f'({", ".join(str(t) for t in triples)}) -- wrong arch, or no executable '
                         'sections? Pass --objdump for a matching toolchain.')
    if used and a.v:
        print(f'   (decoded with --triple={used})')
    if not sites:
        print('   no __android_log_* call sites found (does it log through a wrapper lib?)')
        return

    tags = Counter(); prios = defaultdict(Counter); unresolved = 0
    for idx, fn in sites:
        want = TAG_ARG[fn]
        prio = None
        val = None          # literal built so far for the tag register
        hi = lo = None
        addpc = None        # address of an `add rN, pc` applied to it (PIC)
        for j in range(idx - 1, max(-1, idx - 1 - a.window), -1):
            addr, mnem, ops = rows[j]
            txt = mnem + ' ' + ops
            # arm64: adrp xN, <page> / add xN, xN, #off
            m = re.match(r'adrp\s+x(\d+),\s*0x([0-9a-f]+)', txt)
            if m and int(m.group(1)) == want and hi is None:
                hi = int(m.group(2), 16)
            m = re.match(r'add\s+x(\d+),\s*x(\d+),\s*#?(?:0x([0-9a-f]+)|(\d+))', txt)
            if m and int(m.group(1)) == want and lo is None:
                lo = int(m.group(3), 16) if m.group(3) else int(m.group(4))
            # PIC: add rN, pc  /  add rN, pc, rN  -- the literal is an offset from this pc
            m = re.match(r'add(?:\.w)?\s+r(\d+),\s*pc(?:,\s*r(\d+))?\s*$', txt)
            if m and int(m.group(1)) == want and addpc is None:
                addpc = addr
            m = re.match(r'add(?:\.w)?\s+r(\d+),\s*r(\d+),\s*pc\s*$', txt)
            if m and int(m.group(1)) == want and addpc is None:
                addpc = addr
            # movw/movt pair
            m = re.match(r'mov([wt])(?:\.w)?\s+r(\d+),\s*#?(?:0x([0-9a-f]+)|(\d+))', txt)
            if m and int(m.group(2)) == want:
                v = int(m.group(3), 16) if m.group(3) else int(m.group(4))
                if m.group(1) == 't':
                    hi = v << 16 if hi is None else hi
                else:
                    lo = v if lo is None else lo
            # pc-relative literal load; objdump annotates the pool address in a comment
            m = re.match(r'ldr(?:\.w)?\s+r(\d+),\s*\[pc', txt)
            if m and int(m.group(1)) == want and val is None:
                t = re.search(r'@\s*0x([0-9a-f]+)', ops) or re.search(r'0x([0-9a-f]+)', ops)
                if t:
                    v = elf.u32(int(t.group(1), 16))
                    if v is not None:
                        val = v
            if prio is None:
                m = re.match(r'mov(?:s|\.w)?\s+r0,\s*#?(?:0x([0-9a-f]+)|(\d+))', txt)
                if m:
                    prio = int(m.group(1), 16) if m.group(1) else int(m.group(2))
            if (hi is not None and lo is not None) or val is not None:
                if addpc is not None or j < idx - 3:
                    break
        if val is None and hi is not None and lo is not None:
            val = hi + lo
        elif val is None and lo is not None and hi is None:
            val = lo
        tag_addr = None
        if val is not None:
            if addpc is not None:
                is_thumb = bool(used and used.startswith('thumb'))
                bias = ((addpc & ~3) + 4) if is_thumb else (addpc + 8)
                tag_addr = (bias + val) & 0xffffffff
            else:
                tag_addr = val
        s = elf.read_cstr(tag_addr) if tag_addr else None
        if s is not None and not TAG_RE.match(s):
            if a.v:
                print(f'   ? {rows[idx][0]:#x}: implausible tag {s!r} at {tag_addr:#x}')
            s = None
        if s:
            tags[s] += 1
            if prio is not None:
                prios[s][{2: 'V', 3: 'D', 4: 'I', 5: 'W', 6: 'E', 7: 'F'}.get(prio, str(prio))] += 1
        else:
            unresolved += 1
            if a.v and tag_addr:
                print(f'   ? {rows[idx][0]:#x}: tag at {tag_addr:#x} is not a printable string')

    tri = f' [--triple={used}]' if used else ''
    print(f'>> {os.path.basename(a.lib)}{tri}: {len(sites)} log call site(s), '
          f'{len(sites) - unresolved} resolved, {unresolved} not')
    for t, n in tags.most_common():
        pr = ''.join(f' {k}:{v}' for k, v in sorted(prios[t].items())) if prios[t] else ''
        print(f'   {n:5d}  {t!r}{pr}')
    if not tags:
        print('   (nothing resolved -- try --window larger, or -v to see near-misses)')


if __name__ == '__main__':
    main()
