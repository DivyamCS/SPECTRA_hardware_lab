"""run.py - the I-cache against tools/cache_model.py (2 ways, FIFO).

    python tb/icache/run.py

Writes, into build/<commit>/icache/vec/ (rewritten in place):
  imem.hex    4,096 patterned words (word i = i * 0x9E3779B9 xor 0x0F0F0000), so every fetched
              word is checkable;
  fetch.mem   one fetch per line: "addr hit c5 c6 c8 c10 n5 n6 n8 n10" (addr hex, the rest
              decimal): hit from cache_model, cN = the cycle of fetch_ready with IC = 1 and L = N
              (the request's first cycle is cycle 1: hit 2, miss 2 + L + 4), nN the same with
              IC = 0 (2 + L + 1). The streams: straight-line code, a loop of 16 instructions run
              10 times, jumps into missing lines, three lines in one set (FIFO), 3,000 random
              fetches mixing all of them.
Then runs tb_icache in xsim (IC = 1 and 0, every L) and requires PASS.
"""
import os
import random
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from cache_model import Cache  # noqa: E402

LATS = (5, 6, 8, 10)


def commit_dir():
    c = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True)
    d = subprocess.run(["git", "status", "--porcelain", "--untracked-files=no"], cwd=ROOT,
                       capture_output=True, text=True)
    return os.path.join(ROOT, "build", (c.stdout.strip() or "nogit") + ("-dirty" if d.stdout.strip() else ""))


def stream(rng):
    s = list(range(0x100, 0x500, 4))                       # straight line: 1 miss per 4
    for _ in range(10):                                     # a loop: hits after the first pass
        s += list(range(0x600, 0x640, 4))
    for _ in range(40):                                     # jumps into missing lines
        start = rng.randrange(0x4000 // 4) * 4                  # any word of any line
        s += [start + 4 * k for k in range(rng.randrange(1, 6))]
    a = 0x1230                                               # three lines in one set
    for _ in range(30):
        s += [a, a + 0x400, a, a + 0x800, a + 0x400]
    for _ in range(3000):                                    # random mix
        r = rng.random()
        if r < 0.5 and s:
            s.append((s[-1] + 4) & 0x3FFC)
        elif r < 0.8:
            s.append(rng.choice((0x600, 0x1230, 0x1630, 0x1A30)) + 4 * rng.randrange(4))
        else:
            s.append(rng.randrange(0x1000) * 4)
    return [x & 0x3FFC for x in s]


def main():
    out = os.path.join(commit_dir(), "icache")
    vec = os.path.join(out, "vec")
    os.makedirs(vec, exist_ok=True)              # every file is rewritten, nothing deleted
    with open(os.path.join(vec, "imem.hex"), "w", newline="\n") as f:
        for i in range(4096):
            f.write("%08x\n" % (((i * 0x9E3779B9) ^ 0x0F0F0000) & 0xFFFFFFFF))
    c = Cache(ways=2, fifo=True)
    lines = []
    for addr in stream(random.Random(72)):
        hit = c.access(addr) == "hit"
        ic1 = " ".join(str(2 if hit else 2 + L + 4) for L in LATS)
        ic0 = " ".join(str(2 + L + 1) for L in LATS)
        lines.append("%08x %d %s %s" % (addr, int(hit), ic1, ic0))
    with open(os.path.join(vec, "fetch.mem"), "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    vivado = shutil.which("vivado") or shutil.which("vivado.bat")
    if not vivado:
        sys.exit("FAIL icache: vivado not on PATH")
    run = os.path.join(out, "xsim")
    r = subprocess.run([vivado, "-mode", "batch", "-nojournal", "-nolog", "-notrace", "-source", "scripts/sim.tcl",
                        "-tclargs", "-f", "sim/icache.f", "-top", "tb_icache",
                        "-hex", os.path.relpath(vec, ROOT).replace("\\", "/"), "-run", run.replace("\\", "/")],
                       cwd=ROOT, capture_output=True, text=True)
    log = open(os.path.join(run, "xsim.log")).read() if os.path.exists(os.path.join(run, "xsim.log")) else r.stdout
    shown = [ln for ln in log.splitlines() if ln.startswith(("PASS", "FAIL")) or ": got" in ln or "ERROR" in ln]
    print("\n".join(shown[:20]))
    if r.returncode or not any(ln.startswith("PASS icache") for ln in shown):
        sys.exit("FAIL icache")


if __name__ == "__main__":
    main()
