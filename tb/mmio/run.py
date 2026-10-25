"""run.py - mmio_bus tested from the register map in docs/PROTOCOL.md section 3.

    python tb/mmio/run.py

Parses the register table (the same pattern as tools/check_maps.py) and the per-core counter
list, and writes build/<commit>/mmio/vec/mmio_map.mem, one register per line (hex):
"offset code access core index" - code names the behaviour the testbench checks (below),
access 1 = R, 2 = W, 3 = R/W, core / index for the counters. A register the table lists but this
script does not know fails the run, so the map and the test cannot drift apart. Then runs
tb_mmio_bus in xsim and requires PASS.
"""
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
CODES = {"CORE_ID": 1, "NCORES": 2, "CONFIG": 3, "BARRIER": 4, "LOCK": 5, "RUN_START": 6, "RUN_STOP": 7,
         "GEN_DONE": 8, "CHECKSUM": 9, "LEDS": 10, "SEG7": 11, "ROW_DONE": 12, "MROW_DONE": 13,
         "CYCLES": 14, "SWITCHES": 15, "BUTTONS": 16, "SEG7_DP": 17, "TIMER": 19, "SEG7_TXT": 20}
COUNTERS = ["INSTRET", "D_HIT", "D_MISS", "I_HIT", "I_MISS", "ARB_WAIT", "BAR_WAIT"]


def commit_dir():
    c = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True)
    d = subprocess.run(["git", "status", "--porcelain", "--untracked-files=no"], cwd=ROOT,
                       capture_output=True, text=True)
    return os.path.join(ROOT, "build", (c.stdout.strip() or "nogit") + ("-dirty" if d.stdout.strip() else ""))


def main():
    doc = open(os.path.join(ROOT, "docs", "PROTOCOL.md")).read()
    rows = re.findall(r"^\| (0x[0-9A-F]{2}) \| ([A-Z0-9_]+) \| (R/W|R|W) \|", doc, re.M)
    lines = []
    for off, name, rw in rows:
        if name not in CODES:
            sys.exit("FAIL mmio: PROTOCOL.md register %s (%s) has no test in tb/mmio/run.py" % (name, off))
        lines.append("%02x %02x %x 0 0" % (int(off, 16), CODES[name], {"R": 1, "W": 2, "R/W": 3}[rw]))
    cnt = dict((n, int(o, 16)) for o, n in re.findall(r"\+(0x[0-9A-F]{2}) ([A-Z_]+)", doc))
    if "0x50 + 0x20*k" not in doc or sorted(cnt) != sorted(COUNTERS):
        sys.exit("FAIL mmio: the counter list in PROTOCOL.md changed")
    for k in range(2):
        for j, n in enumerate(COUNTERS):
            lines.append("%02x 12 1 %x %x" % (0x50 + 0x20 * k + cnt[n], k, j))   # code 0x12 = 18
    if len(rows) != len(CODES):
        sys.exit("FAIL mmio: expected %d registers in PROTOCOL.md, found %d" % (len(CODES), len(rows)))
    out = os.path.join(commit_dir(), "mmio")
    vec = os.path.join(out, "vec")
    os.makedirs(vec, exist_ok=True)              # rewritten in place, nothing deleted
    with open(os.path.join(vec, "mmio_map.mem"), "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    vivado = shutil.which("vivado") or shutil.which("vivado.bat")
    if not vivado:
        sys.exit("FAIL mmio: vivado not on PATH")
    run = os.path.join(out, "xsim")
    r = subprocess.run([vivado, "-mode", "batch", "-nojournal", "-nolog", "-notrace", "-source", "scripts/sim.tcl",
                        "-tclargs", "-f", "sim/mmio_bus.f", "-top", "tb_mmio_bus",
                        "-hex", os.path.relpath(vec, ROOT).replace("\\", "/"), "-run", run.replace("\\", "/")],
                       cwd=ROOT, capture_output=True, text=True)
    log = open(os.path.join(run, "xsim.log")).read() if os.path.exists(os.path.join(run, "xsim.log")) else r.stdout
    shown = [ln for ln in log.splitlines() if ln.startswith(("PASS", "FAIL")) or ": got" in ln or "ERROR" in ln]
    print("\n".join(shown[:20]))
    if r.returncode or not any(ln.startswith("PASS mmio") for ln in shown):
        sys.exit("FAIL mmio")
    print("(%d registers + %d counters from PROTOCOL.md section 3)" % (len(rows), 14))


if __name__ == "__main__":
    main()