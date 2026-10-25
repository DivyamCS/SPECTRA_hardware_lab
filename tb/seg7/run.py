"""run.py - seg7_bcd against tools/seg7_model.py.

    python tb/seg7/run.py

Writes build/<commit>/seg7/vec/seg7.mem, one test per line (hex): "value dp txt seg0 dp0 ...
seg7 dp7", seg = the active-high {g..a} pattern of digit n (0 = blank), dpN = its decimal point,
for 0, 9, 10, 99,999,999, a clamped 123,456,789, the firmware's labels, every letter code on
every digit, and 1,000 random values of every size (a third with a random decimal-point mask, a
third with random letters in random digits), then runs tb_seg7_bcd in xsim and requires PASS.
"""
import os
import random
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import seg7_model  # noqa: E402


def commit_dir():
    c = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True)
    d = subprocess.run(["git", "status", "--porcelain", "--untracked-files=no"], cwd=ROOT,
                       capture_output=True, text=True)
    return os.path.join(ROOT, "build", (c.stdout.strip() or "nogit") + ("-dirty" if d.stdout.strip() else ""))


def main():
    rng = random.Random(88)
    tests = [(0, 0, 0), (9, 0, 0), (10, 0, 0), (99999999, 0, 0), (123456789, 0, 0), (73, 0x04, 0), (5, 0x80, 0),
             (1000, 0x08, 0), (9998, 0x04, 0x34000000), (220, 0x04, 0x17300000), (70337, 0, 0x12000000),
             (368, 0x20, 0x56B00000), (9998, 0x24, 0x34C00000), (49300, 0x20, 0x54B00000)]
    for code in range(1, 16):
        for digit in range(8):
            tests.append((rng.randrange(10 ** 8), rng.randrange(256), code << (4 * digit)))
    for k in range(1000):
        v = rng.randrange(10 ** rng.randrange(1, 9))
        txt = 0
        if k % 3 == 1:
            for digit in rng.sample(range(8), rng.randrange(1, 4)):
                txt |= rng.randrange(1, 16) << (4 * digit)
        tests.append((v, rng.randrange(256) if k % 3 == 0 else 0, txt))
    out = os.path.join(commit_dir(), "seg7")
    vec = os.path.join(out, "vec")
    os.makedirs(vec, exist_ok=True)              # rewritten in place, nothing deleted
    with open(os.path.join(vec, "seg7.mem"), "w", newline="\n") as f:
        for v, dp, txt in tests:
            cells = seg7_model.display(v, dp, txt)
            f.write("%07x %02x %08x %s\n" % (v, dp, txt, " ".join("%02x %x" % (s, int(d)) for s, d in cells)))
    vivado = shutil.which("vivado") or shutil.which("vivado.bat")
    if not vivado:
        sys.exit("FAIL seg7: vivado not on PATH")
    run = os.path.join(out, "xsim")
    r = subprocess.run([vivado, "-mode", "batch", "-nojournal", "-nolog", "-notrace", "-source", "scripts/sim.tcl",
                        "-tclargs", "-f", "sim/seg7_bcd.f", "-top", "tb_seg7_bcd",
                        "-hex", os.path.relpath(vec, ROOT).replace("\\", "/"), "-run", run.replace("\\", "/")],
                       cwd=ROOT, capture_output=True, text=True)
    log = open(os.path.join(run, "xsim.log")).read() if os.path.exists(os.path.join(run, "xsim.log")) else r.stdout
    shown = [ln for ln in log.splitlines() if ln.startswith(("PASS", "FAIL")) or ": got" in ln or "ERROR" in ln]
    print("\n".join(shown[:20]))
    if r.returncode or not any(ln.startswith("PASS seg7_bcd") for ln in shown):
        sys.exit("FAIL seg7")


if __name__ == "__main__":
    main()
