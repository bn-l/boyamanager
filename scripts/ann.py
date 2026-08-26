#!/usr/bin/env python3
"""Annotate otool -tV output (text.asm) with resolved objc selector stubs,
selrefs, classrefs, cfstrings, cstrings and fixup binds. Writes text.ann.asm."""
import os, re, struct, bisect

# Working directory for the big intermediate listings (text.asm, objc_stubs.asm,
# fixups.txt, methods.txt, text.ann.asm).  Pipeline:
#   otool -tV BOYA.app/BOYA > $SP/text.asm
#   otool -v -s __TEXT __objc_stubs BOYA.app/BOYA > $SP/objc_stubs.asm
#   dyld_info -fixups BOYA.app/BOYA > $SP/fixups.txt
#   otool -oV BOYA.app/BOYA > $SP/objc.txt && python3 methods.py $SP/objc.txt > $SP/methods.txt
#   python3 ann.py          -> $SP/text.ann.asm
#   python3 disas.py <addr|selector-substring>
_HERE = os.path.dirname(os.path.abspath(__file__))
SP = os.environ.get("BOYA_RE_DIR", os.path.join(_HERE, "..", "re-work"))
BIN = os.environ.get("BOYA_BIN", os.path.join(_HERE, "..", "BOYA.app", "BOYA"))
BASE = 0x100000000
data = open(BIN, "rb").read()

SEC = {
    "cstring": (0x10034d5b0, 0x8322),
    "methname": (0x1003558d2, 0x26400),
    "classname": (0x10037bcd2, 0x17e0),
    "got": (0x100394000, 0xca8),
    "cfstring": (0x10039aa58, 0xd040),
    "selrefs": (0x1003d6f98, 0x9b88),
    "classrefs": (0x1003e0b20, 0xab0),
    "superrefs": (0x1003e15d0, 0x650),
    "objc_data": (0x1003e43e0, 0x50f0),
    "data": (0x1003e94d0, 0x13d0),
    "bss": (0x1003ea8a0, 0x3b728),
    "common": (0x100425fc8, 0x1f5c40),
    "const": (0x100394ca8, 0x5db0),
}


def sec_of(a):
    for k, (s, n) in SEC.items():
        if s <= a < s + n:
            return k
    return None


# fixups: addr -> ("bind", sym) | ("rebase", target)
fix = {}
for line in open(f"{SP}/fixups.txt"):
    m = re.match(r"\s*(\S+)\s+(\S+)\s+(0x[0-9A-Fa-f]+)\s+(bind|rebase)\s+(\S+)", line)
    if m:
        a = int(m.group(3), 16)
        if m.group(4) == "bind":
            fix[a] = ("bind", m.group(5).split("/", 1)[-1])
        else:
            fix[a] = ("rebase", int(m.group(5), 16))


def cstr(addr, maxlen=200):
    off = addr - BASE
    if off < 0 or off >= len(data):
        return None
    end = data.find(b"\0", off, off + 4000)
    if end < 0:
        return None
    s = data[off:end].decode("utf-8", "replace")
    return s if len(s) <= maxlen else s[:maxlen] + "…"


def deref(addr):
    """resolve pointer at addr via fixups (chained) -> ('bind',sym)|('rebase',target)|None"""
    if addr in fix:
        return fix[addr]
    off = addr - BASE
    if 0 <= off + 8 <= len(data):
        v = struct.unpack_from("<Q", data, off)[0]
        if v == 0:
            return None
        if v >> 63:
            return ("bind?", hex(v))
        return ("rebase", BASE + (v & 0xFFFFFFFFF))
    return None


def class_name(class_addr):
    ro = deref(class_addr + 0x20)
    if not ro or ro[0] != "rebase":
        return None
    nm = deref(ro[1] + 0x18)
    if not nm or nm[0] != "rebase":
        return None
    return cstr(nm[1])


def describe(addr):
    k = sec_of(addr)
    if k == "selrefs":
        d = deref(addr)
        if d and d[0] == "rebase":
            return f"@selector({cstr(d[1])})"
        return "selref?"
    if k == "classrefs" or k == "superrefs":
        d = deref(addr)
        if d and d[0] == "bind":
            return d[1].replace("_OBJC_CLASS_$_", "class ")
        if d and d[0] == "rebase":
            return f"class {class_name(d[1])}"
        return "classref?"
    if k == "cfstring":
        d = deref(addr + 0x10)
        ln = struct.unpack_from("<Q", data, addr + 0x18 - BASE)[0]
        if d and d[0] == "rebase":
            s = cstr(d[1])
            return f'@"{s}"'
        return "cfstring?"
    if k in ("cstring", "methname", "classname"):
        return f'"{cstr(addr)}"'
    if k == "got":
        d = deref(addr)
        if d:
            return f"&{d[1]}" if d[0] == "bind" else f"got->{d[1]:#x}"
    if k in ("data", "bss", "common", "objc_data", "const"):
        d = deref(addr)
        if k == "objc_data":
            return f"class-obj {class_name(addr)}"
        extra = ""
        if d and d[0] == "bind":
            extra = f" -> {d[1]}"
        elif d and d[0] == "rebase":
            extra = f" -> {d[1]:#x}"
        return f"{k}:{addr:#x}{extra}"
    return None


# objc stubs map
stubs = {}
cur = None
page = {}
for line in open(f"{SP}/objc_stubs.asm"):
    m = re.match(r"^([0-9a-f]{16})\t(\S+)\t(.*)$", line)
    if not m:
        continue
    a = int(m.group(1), 16)
    op, args = m.group(2), m.group(3)
    if op == "adrp" and args.startswith("x1,"):
        cur = a
        page[cur] = int(args.split(";")[1].strip(), 16)
    elif op == "ldr" and args.startswith("x1, [x1, #") and cur is not None:
        off = int(args.split("#")[1].rstrip("]"), 16)
        sel_addr = page[cur] + off
        d = deref(sel_addr)
        stubs[cur] = f"objc_msgSend$" + (cstr(d[1]) if d and d[0] == "rebase" else "?")
        cur = None

# methods for bl annotation
imps = {}
for line in open(f"{SP}/methods.txt"):
    a, name = line.rstrip("\n").split(" ", 1)
    imps[int(a, 16)] = name
starts = sorted(imps)

out = open(f"{SP}/text.ann.asm", "w")
regpage = {}
for line in open(f"{SP}/text.asm", errors="replace"):
    m = re.match(r"^([0-9a-f]{16})\t(\S+)\t?(.*)$", line.rstrip("\n"))
    if not m:
        out.write(line)
        continue
    a = int(m.group(1), 16)
    op, args = m.group(2), m.group(3)
    s = line.rstrip("\n")
    ann = None
    if op == "adrp":
        mm = re.match(r"(x\d+|xzr), \d+ ; (0x[0-9a-f]+)", args)
        if mm:
            regpage[mm.group(1)] = int(mm.group(2), 16)
    elif op in ("ldr", "add", "ldrb", "ldrh", "str", "strb", "strh", "ldrsw", "ldp", "stp"):
        mm = re.search(r"\[(x\d+), #(0x[0-9a-f]+|\d+)\]", args) if op.startswith(("ld", "st")) else None
        if op == "add":
            mm = re.match(r"(x\d+), (x\d+), #(0x[0-9a-f]+|\d+)$", args)
            if mm and mm.group(2) in regpage:
                tgt = regpage[mm.group(2)] + int(mm.group(3), 0)
                ann = describe(tgt)
                if ann:
                    ann = f"{tgt:#x} {ann}"
        elif mm and mm.group(1) in regpage:
            tgt = regpage[mm.group(1)] + int(mm.group(2), 0)
            ann = describe(tgt)
            if ann:
                ann = f"{tgt:#x} {ann}"
                # track register loaded with a selref/classref for later use? (skip)
        if op in ("ldr", "add") and mm:
            # dest register now holds a non-page value; drop page tracking for dest
            dst = args.split(",")[0]
            regpage.pop(dst, None)
    elif op in ("bl", "b"):
        mm = re.match(r"0x([0-9a-f]+)", args)
        if mm:
            t = int(mm.group(1), 16)
            if t in stubs:
                ann = stubs[t]
            elif t in imps:
                ann = imps[t]
            elif t < 0x100316b4c and op == "bl":
                j = bisect.bisect_right(starts, t) - 1
                ann = f"sub_{t:x}" + (f" ({imps[starts[j]]}+{t-starts[j]:#x})" if j >= 0 and t - starts[j] < 0x8000 else "")
    if op in ("bl", "blr", "ret") and op != "bl":
        pass
    if ann and "bad " in s:
        s = s.split(";")[0].rstrip()
    if ann:
        s += f"\t;; {ann}"
    out.write(s + "\n")
out.close()
print("stubs:", len(stubs), "fixups:", len(fix))
