#!/usr/bin/env python3
"""disas.py <addr|sel-substring> [maxlines]
Print otool -tV listing of the function starting at addr, until the next known
method IMP (from methods.txt), annotating bl targets that are known IMPs."""
import bisect, os, re, sys

# Directory holding methods.txt and text.ann.asm (see the pipeline in ann.py).
SP = os.environ.get("BOYA_RE_DIR",
                    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "re-work"))
imps = {}
for line in open(f"{SP}/methods.txt"):
    a, name = line.rstrip("\n").split(" ", 1)
    imps[int(a, 16)] = name
starts = sorted(imps)

arg = sys.argv[1]
maxlines = int(sys.argv[2]) if len(sys.argv) > 2 else 400
if arg.startswith("0x"):
    start = int(arg, 16)
else:
    cands = [a for a, n in imps.items() if arg in n]
    if len(cands) != 1:
        print("candidates:", [(hex(a), imps[a]) for a in cands])
        sys.exit(1)
    start = cands[0]
i = bisect.bisect_right(starts, start)
end = starts[i] if i < len(starts) else start + 0x4000
print(f"=== {imps.get(start, '?')} @ {start:#x} .. {end:#x}")

out = []
printing = False
for line in open(f"{SP}/text.ann.asm", errors="replace"):
    m = re.match(r"^([0-9a-f]{16})\t", line)
    if not m:
        continue
    a = int(m.group(1), 16)
    if a == start:
        printing = True
    if a >= end:
        break
    if printing:
        s = line.rstrip("\n")
        mb = re.search(r"\tbl\t0x([0-9a-f]+)$", s)
        if mb:
            t = int(mb.group(1), 16)
            if t in imps:
                s += f"\t; -> {imps[t]}"
            else:
                # function without objc name: show nearest preceding imp
                j = bisect.bisect_right(starts, t) - 1
                if j >= 0 and t - starts[j] < 0x10000:
                    s += f"\t; -> sub_{t:x} (after {imps[starts[j]]}+{t-starts[j]:#x})"
                else:
                    s += f"\t; -> sub_{t:x}"
        out.append(s)
        if len(out) >= maxlines:
            out.append("... (truncated)")
            break
print("\n".join(out))
