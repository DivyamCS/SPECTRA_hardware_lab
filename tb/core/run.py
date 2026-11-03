"""run.py - one core on ideal memory (tb_core) against rv32sim

    python tb/core/run.py IMAGE [CONFIG ...]      e.g.  t_hazard 0093 0092

IMAGE is a directory under fw/build; CONFIG is the 16-bit switch word in hex (default 0093:
FWD DC IC, L = 8, one core). For each config:
1. runs rv32sim with the same config, writing its commit trace and giving the cycle cap
   for the RTL run (4 x its cycles + 100,000, in maxcyc.mem);
2. runs tb_core in xsim (scripts/sim.tcl, sim/core.f) with imem.hex, dmem.hex, cfg.mem and
   maxcyc.mem;
3. requires the run to end at the CHECKSUM write with rv32sim's checksum, and the two commit
   traces to match (tools/tracecmp.py, 0 differences);
4. when a config is given with FWD = 1 and FWD = 0, the FWD = 0 run must take more cycles.
Prints one line per config and PASS only if every config passes. Files: build/<commit>/core/.
"""
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import simpath  # noqa: E402

# testbench and its file list
FILELIST, TOP, OUTDIR = "sim/core.f", "tb_core", "core"


def commit_dir():
    c = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True)
    d = subprocess.run(["git", "status", "--porcelain", "--untracked-files=no"], cwd=ROOT,
                       capture_output=True, text=True)
    name = (c.stdout.strip() or "nogit") + ("-dirty" if d.stdout.strip() else "")
    return os.path.join(ROOT, "build", name)


def run_one(image, cfg, vivado):
    out = os.path.join(commit_dir(), OUTDIR, "%s_%s" % (image, cfg))
    vec = os.path.join(out, "vec")
    os.makedirs(vec, exist_ok=True)              # every file below is rewritten, nothing deleted
    src = os.path.join(ROOT, "fw", "build", image)
    for f in ("imem.hex", "dmem.hex"):
        shutil.copy(os.path.join(src, f), vec)
    open(os.path.join(vec, "cfg.mem"), "w").write(cfg + "\n")
    prefix = os.path.join(out, "sim")
    s = subprocess.run([simpath.find_sim(), "-c", cfg, "-t", prefix, src], cwd=ROOT,
                       capture_output=True, text=True)
    ms = re.search(r"checksum=0x([0-9a-f]{8}) golden=(\w+)", s.stdout)
    if not ms:
        return False, "%s %s: rv32sim gave no checksum: %s" % (image, cfg, s.stdout[-300:]), 0
    mc = re.search(r"cycles=(\d+)", s.stdout)
    open(os.path.join(vec, "maxcyc.mem"), "w").write("%08x\n" % (4 * int(mc.group(1)) + 100000))
    run = os.path.join(out, "xsim")
    r = subprocess.run([vivado, "-mode", "batch", "-nojournal", "-nolog", "-notrace",
                        "-source", "scripts/sim.tcl", "-tclargs", "-f", FILELIST, "-top", TOP,
                        "-hex", os.path.relpath(vec, ROOT).replace("\\", "/"),
                        "-run", run.replace("\\", "/")],
                       cwd=ROOT, capture_output=True, text=True)
    log = open(os.path.join(run, "xsim.log")).read() if os.path.exists(os.path.join(run, "xsim.log")) else ""
    m = re.search(r"CHECKSUM ([0-9a-f]{8}) cycles (\d+) instret (\d+)", log)
    if r.returncode or not m:
        fails = [ln for ln in log.splitlines() if "FAIL" in ln or "decode error" in ln][:3]
        return False, "%s %s: RTL run failed: %s" % (image, cfg, "; ".join(fails) or r.stdout[-300:]), 0
    rtl_sum, rtl_cycles, rtl_instret = m.group(1), int(m.group(2)), int(m.group(3))
    t = subprocess.run([sys.executable, "tools/tracecmp.py", os.path.join(run, "trace_rtl0.txt"),
                        prefix + "0.txt"], cwd=ROOT, capture_output=True, text=True)
    ok = (rtl_sum == ms.group(1)) and t.returncode == 0
    msg = "%s %s: checksum %s (rv32sim %s, golden %s), %d cycles, %d instructions; tracecmp: %s" % (
        image, cfg, rtl_sum, ms.group(1), ms.group(2), rtl_cycles, rtl_instret,
        (t.stdout.strip().splitlines() or ["?"])[-1])
    return ok, msg, rtl_cycles


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    image, cfgs = sys.argv[1], sys.argv[2:] or ["0093"]
    vivado = shutil.which("vivado") or shutil.which("vivado.bat")
    if not vivado:
        sys.exit("FAIL core: vivado not on PATH")
    all_ok, cycles = True, {}
    for cfg in cfgs:
        ok, msg, cycles[int(cfg, 16)] = run_one(image, cfg.lower(), vivado)
        print(("ok   " if ok else "FAIL ") + msg)
        all_ok = all_ok and ok
    # FWD = 0 (cfg bit 0 clear) must cost cycles against the same config with FWD = 1
    for c in cycles:
        if c & 1 and (c & ~1) in cycles and cycles[c] and cycles[c & ~1] <= cycles[c]:
            print("FAIL %04x takes %d cycles, not more than %04x's %d" % (c & ~1, cycles[c & ~1], c, cycles[c]))
            all_ok = False
    if not all_ok:
        sys.exit("FAIL core_%s" % image)
    print("PASS core_%s (%s)" % (image, ", ".join(cfgs)))


if __name__ == "__main__":
    main()
