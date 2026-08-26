#!/usr/bin/env python3
"""Resolve ObjC class/method/IMP table from `otool -oV` output of a stripped
arm64 binary (relative method lists).  fileoff == vmaddr - 0x100000000 for
this binary (all segments contiguous)."""
import re, sys

BIN = "/Users/bml/projects/misc-projects/misc/BOYA.app/BOYA"
OBJC = sys.argv[1]
BASE = 0x100000000
data = open(BIN, "rb").read()


def cstr(addr):
    off = addr - BASE
    end = data.index(b"\0", off)
    return data[off:end].decode("utf-8", "replace")


cur_class = None
is_meta = False
name_addr = None
rows = []
for line in open(OBJC, errors="replace"):
    s = line.strip()
    m = re.match(r"name\s+0x[0-9a-f]+ (\S+)$", s)
    if m and ("data " in prev if (prev := s) else False):
        pass
    if s.startswith("Meta Class"):
        is_meta = True
    if s.startswith("Contents of (__DATA") or s.startswith("Contents of ("):
        pass
    m = re.match(r"name\s+0x[0-9a-f]+ (\S+)$", s)
    if m and not re.match(r"name\s+0x[0-9a-f]+ \(0x", s):
        # class name line (follows ivarLayout / layout map)
        cur_class = m.group(1)
        continue
    m = re.match(r"name\s+0x[0-9a-f]+ \((0x[0-9a-f]+)\)$", s)
    if m:
        name_addr = int(m.group(1), 16)
        continue
    m = re.match(r"imp\s+0x[0-9a-f]+ \((0x[0-9a-f]+)\)$", s)
    if m and name_addr:
        imp = int(m.group(1), 16)
        try:
            import struct
            v = struct.unpack_from("<Q", data, name_addr - BASE)[0]
            sel = cstr(BASE + (v & 0xFFFFFFFFF))
        except Exception:
            sel = "?"
        rows.append((cur_class, "+" if is_meta else "-", sel, imp))
        name_addr = None
        continue
    if re.match(r"^\+\s*isa|^isa\s", s) or s.startswith("Contents of"):
        is_meta = False

for cls, kind, sel, imp in rows:
    print(f"{imp:#x} {kind}[{cls} {sel}]")
