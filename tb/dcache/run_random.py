"""run_random.py - the D-cache against tools/cache_model.py on random accesses.

    python tb/dcache/run_random.py [N]          N accesses per file (default 25,000)

Writes 4 vector files (four random seeds; write-back / write-allocate, PLRU) with
tools/gen_cache_vectors.py's generator and N accesses each, so every L sees 4 x N accesses
(100,000 by default); runs tb_dcache_random in xsim (each file once per L);
PASS only if the testbench reports 0 mismatches in data, hit/miss, victim and cycles.
Files: build/<commit>/dcache_random/ (rewritten in place).
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import gen_cache_vectors as gcv  # noqa: E402


def commit_dir():
    c = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True)
    d = subprocess.run(["git", "status", "--porcelain", "--untracked-files=no"], cwd=ROOT,
                       capture_output=True, text=True)
    return os.path.join(ROOT, "build", (c.stdout.strip() or "nogit") + ("-dirty" if d.stdout.strip() else ""))


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 25000
    out = os.path.join(commit_dir(), "dcache_random")
    vec = os.path.join(out, "vec")
    os.makedirs(vec, exist_ok=True)              # every file is rewritten, nothing deleted
    gcv.N = n
    for i, seed in enumerate(gcv.SEEDS):
        lines = gcv.generate(seed)
        with open(os.path.join(vec, "v%02d.mem" % i), "w", newline="\n") as f:
            f.write("\n".join(lines) + "\n")
    vivado = shutil.which("vivado") or shutil.which("vivado.bat")
    if not vivado:
        sys.exit("FAIL dcache_random: vivado not on PATH")
    run = os.path.join(out, "xsim")
    r = subprocess.run([vivado, "-mode", "batch", "-nojournal", "-nolog", "-notrace",
                        "-source", "scripts/sim.tcl", "-tclargs", "-f", "sim/dcache_random.f",
                        "-top", "tb_dcache_random", "-hex", os.path.relpath(vec, ROOT).replace("\\", "/"),
                        "-run", run.replace("\\", "/")], cwd=ROOT, capture_output=True, text=True)
    log = open(os.path.join(run, "xsim.log")).read() if os.path.exists(os.path.join(run, "xsim.log")) else ""
    lines = [ln for ln in log.splitlines() if ln.startswith(("PASS", "FAIL", "file ")) or ": got" in ln]
    print("\n".join(lines[:25]))
    if r.returncode or not any(ln.startswith("PASS dcache_random") for ln in lines):
        sys.exit("FAIL dcache_random")


if __name__ == "__main__":
    main()
