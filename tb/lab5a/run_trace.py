"""run_trace.py - the lab 5A core against rv32sim, by commit trace.

    python tb/lab5a/run_trace.py

1. builds tb/lab5a/image (t_lab5a.S, RV32I without AUIPC, fits the lab's 4 KB memories);
2. runs it on rv32sim, one core (CONFIG 0x0093), writing the reference trace;
3. runs tb_lab5a_trace in xsim through scripts/sim.tcl on the unmodified lab core;
4. compares the two traces with tools/tracecmp.py.

Everything lands in build/<commit>/lab5a_trace/. Prints PASS only with 0 differences.
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import simpath  # noqa: E402


def sh(cmd, **kw):
    print("$", " ".join(cmd))
    return subprocess.run(cmd, cwd=ROOT, **kw)


def commit_dir():
    c = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True)
    d = subprocess.run(["git", "status", "--porcelain", "--untracked-files=no"], cwd=ROOT,
                       capture_output=True, text=True)
    name = (c.stdout.strip() or "nogit") + ("-dirty" if d.stdout.strip() else "")
    return os.path.join(ROOT, "build", name)


def main():
    out = os.path.join(commit_dir(), "lab5a_trace")
    os.makedirs(out, exist_ok=True)
    if sh([sys.executable, os.path.join(HERE, "build_image.py")]).returncode:
        sys.exit("FAIL: image build")
    image = os.path.join(HERE, "image")
    sim_prefix = os.path.join(out, "sim")
    sh([simpath.find_sim(), "-c", "0093", "-t", sim_prefix, image], capture_output=True)
    if not os.path.exists(sim_prefix + "0.txt"):
        sys.exit("FAIL: rv32sim wrote no trace")
    vivado = shutil.which("vivado") or shutil.which("vivado.bat")
    if not vivado:
        sys.exit("FAIL: vivado not on PATH")
    rtl_trace = os.path.join(out, "xsim", "trace_rtl0.txt")    # the testbench's fixed file name
    r = sh([vivado, "-mode", "batch", "-nojournal", "-nolog", "-notrace", "-source", "scripts/sim.tcl",
            "-tclargs", "-f", "sim/lab5a_trace.f", "-top", "tb_lab5a_trace", "-hex", "tb/lab5a/image",
            # Tcl reads backslashes as escapes: hand it forward slashes
            "-run", os.path.join(out, "xsim").replace("\\", "/")],
           capture_output=True, text=True)
    lines = [ln for ln in r.stdout.splitlines() if ln.startswith(("SIM ", "retired", "PASS", "FAIL"))]
    print("\n".join(lines))
    if r.returncode:
        print(r.stdout[-2000:] + r.stderr[-2000:])
        sys.exit("FAIL: xsim run")
    n_rtl = sum(1 for _ in open(rtl_trace))
    n_sim = sum(1 for _ in open(sim_prefix + "0.txt"))
    print("trace lines: RTL %d, rv32sim %d" % (n_rtl, n_sim))
    c = sh([sys.executable, os.path.join(ROOT, "tools", "tracecmp.py"), rtl_trace, sim_prefix + "0.txt"])
    if c.returncode or n_rtl != n_sim:
        sys.exit("FAIL lab5a_trace: traces differ (files in %s)" % out)
    print("PASS lab5a_trace: 0 differences over %d instructions" % n_rtl)


if __name__ == "__main__":
    main()
