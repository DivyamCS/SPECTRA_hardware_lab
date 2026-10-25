"""check_maps.py - fail if docs/PROTOCOL.md and fw/spectra.h disagree.

Checks every MMIO register offset, every per-core counter offset, every CONFIG field position
and width, and the memory-map base addresses.   python tools/check_maps.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    doc = open(os.path.join(ROOT, "docs", "PROTOCOL.md")).read()
    hdr = open(os.path.join(ROOT, "fw", "spectra.h")).read()
    errors = []

    regs_doc = {m[1]: int(m[0], 16) for m in re.findall(r"^\| (0x[0-9A-F]{2}) \| ([A-Z0-9_]+) \|", doc, re.M)}
    for a, b, oa, ob in re.findall(r"^\| (0x[0-9A-F]{2}) / (0x[0-9A-F]{2}) \| ([A-Z_]+) / ([A-Z_]+) \|", doc, re.M):
        regs_doc[oa], regs_doc[ob] = int(a, 16), int(b, 16)
    regs_hdr = {m[0]: int(m[1], 16) for m in re.findall(r"#define (\w+)\s+MMIO\((0x[0-9A-Fa-f]+)\)", hdr)}
    for name in sorted(set(regs_doc) | set(regs_hdr)):
        if regs_doc.get(name) != regs_hdr.get(name):
            errors.append("MMIO %s: doc %s, spectra.h %s" % (name, regs_doc.get(name), regs_hdr.get(name)))

    cnt_doc = {n: int(o, 16) for o, n in re.findall(r"\+(0x[0-9A-F]{2}) ([A-Z_]+)", doc)}
    names = {"INSTRET": "C_INSTRET", "D_HIT": "C_DHIT", "D_MISS": "C_DMISS", "I_HIT": "C_IHIT",
             "I_MISS": "C_IMISS", "ARB_WAIT": "C_ARBWAIT", "BAR_WAIT": "C_BARWAIT"}
    cnt_hdr = {m[0]: int(m[1], 16) for m in re.findall(r"#define (C_\w+)\s+(0x[0-9A-Fa-f]+)u", hdr)}
    for d, h in names.items():
        if cnt_doc.get(d) != cnt_hdr.get(h):
            errors.append("counter %s: doc %s, spectra.h %s" % (d, cnt_doc.get(d), cnt_hdr.get(h)))
    if "0x50 + 0x20*k" not in doc or "MMIO(0x50u + 0x20u * (k) + (off))" not in hdr:
        errors.append("per-core counter base or stride differs")

    fields_doc = {}
    for sw, f in re.findall(r"^\| SW(\d+(?::\d+)?) \| ([A-Z]+) \|", doc, re.M):
        hi, lo = (sw.split(":") + [sw])[:2] if ":" in sw else (sw, sw)
        fields_doc[f] = (int(lo), int(hi) - int(lo) + 1)
    fields_hdr = {m[0]: (int(m[1]), bin(int(m[2])).count("1"))
                  for m in re.findall(r"#define CFG_(\w+)\(c\)\s+\(\(\(c\) >> (\d+)\) & (\d+)u\)", hdr)}
    for name in sorted(set(fields_doc) | set(fields_hdr)):
        if fields_doc.get(name) != fields_hdr.get(name):
            errors.append("CONFIG %s: doc %s, spectra.h %s" % (name, fields_doc.get(name), fields_hdr.get(name)))

    for sym, val in (("DMEM_BASE", "0x10000000u"), ("MMIO_BASE", "0x20000000u"), ("GRID0", "0x10008000u"),
                     ("GRID1", "0x10009000u"), ("IMAGE", "0x10010000u"), ("MATB", "0x10014000u"),
                     ("MATC", "0x10018000u")):
        if not re.search(r"#define %s\b.*%s" % (sym, val), hdr):
            errors.append("spectra.h %s is not %s" % (sym, val))
    for txt in ("0x1000_8000-0x1000_8FFF", "0x1000_9000-0x1000_9FFF", "0x1001_0000 / 0x1001_4000 / 0x1001_8000",
                "0x2000_0000-0x2000_00FF"):
        if txt not in doc:
            errors.append("PROTOCOL.md memory map lacks %s" % txt)

    for e in errors:
        print("MISMATCH:", e)
    print("check_maps: %d registers, %d counters, %d CONFIG fields -> %s"
          % (len(regs_doc), len(cnt_doc), len(fields_doc), "FAIL" if errors else "PASS"))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
