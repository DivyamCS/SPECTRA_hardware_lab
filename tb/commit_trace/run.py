"""run.py - commit_trace writes rv32sim's trace format.

    python tb/commit_trace/run.py

1. traces t_hazard, t_mext (config 0093, as tools/make_refs.py does) and t_lab5a, which has
   loads into x0, with rv32sim now, and turns the traces into retire events: PC, INSTR, register write, load address, store address and data. Store
   data gets random bits above the access size (from the instruction's funct3), as rs2 has;
2. runs tb_commit_trace in xsim (scripts/sim.tcl, file list sim/commit_trace.f with SIM defined);
3. requires trace_rtl0.txt to equal the reference byte for byte (both simulators write the
   platform's line ending, CRLF on Windows), and tools/tracecmp.py to report 0 differences.

Everything lands in build/<commit>/commit_trace/. Prints PASS only if both hold.
"""
import os
import random
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import simpath  # noqa: E402

# rv32sim traces made by this test (tb/ref/ is not committed, so a fresh clone has none)
TRACES = [("t_hazard", "fw/build/t_hazard"), ("t_mext", "fw/build/t_mext"), ("t_lab5a", "tb/lab5a/image")]


def commit_dir():
    c = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True)
    d = subprocess.run(["git", "status", "--porcelain", "--untracked-files=no"], cwd=ROOT,
                       capture_output=True, text=True)
    name = (c.stdout.strip() or "nogit") + ("-dirty" if d.stdout.strip() else "")
    return os.path.join(ROOT, "build", name)


def events(lines, rnd):
    for line in lines:
        p = line.split()
        pc, ins = int(p[0], 16), int(p[1], 16)
        we = rd = val = ld = st = addr = sd = 0
        i = 2
        while i < len(p):
            if p[i].startswith("x"):
                r, v = p[i][1:].split("=")
                we, rd, val = 1, int(r), int(v, 16)
                i += 1
            elif p[i] == "ld":
                ld, addr = 1, int(p[i + 1], 16)
                i += 2
            elif p[i] == "st":
                st, addr, sd = 1, int(p[i + 1], 16), int(p[i + 2], 16)
                i += 3
            else:
                raise ValueError("bad token %r in %r" % (p[i], line))
        size = (ins >> 12) & 3 if (ld or st) else rnd.randrange(4)
        if st and size < 2:                     # rs2 has more bits than the store writes
            sd |= rnd.getrandbits(32) & ~((1 << (8 * (size + 1))) - 1) & 0xFFFFFFFF
        if not (ld or st):
            addr, sd = rnd.getrandbits(32), rnd.getrandbits(32)
        if not we:
            val, rd = rnd.getrandbits(32), rnd.randrange(32)
        flags = we | (rd << 1) | (ld << 6) | (st << 7) | (size << 8)
        yield pc, ins, val, addr, sd, flags


def main():
    out = os.path.join(commit_dir(), "commit_trace")
    vec = os.path.join(out, "vec")
    os.makedirs(vec, exist_ok=True)              # every file below is rewritten, nothing deleted
    traces = []
    for name, image in TRACES:
        prefix = os.path.join(out, name + "_")
        subprocess.run([simpath.find_sim(), "-c", "0093", "-t", prefix, os.path.join(ROOT, image)],
                       cwd=ROOT, capture_output=True)
        if not os.path.exists(prefix + "0.txt"):
            sys.exit("FAIL commit_trace: rv32sim wrote no %s trace" % name)
        traces.append(prefix + "0.txt")
    ref_lines, ref_bytes = [], b""
    for r in traces:
        raw = open(r, "rb").read()  # as rv32sim wrote it (CRLF on Windows)
        ref_bytes += raw
        ref_lines += raw.decode().splitlines()
    rnd = random.Random(47)
    cols = [[] for _ in range(6)]
    for ev in events(ref_lines, rnd):
        for c, v in zip(cols, ev):
            c.append("%08x" % v)
    for name, c in zip(["pc", "ins", "val", "addr", "sd", "flags"], cols):
        open(os.path.join(vec, name + ".mem"), "w").write("\n".join(c) + "\n")
    open(os.path.join(vec, "n.mem"), "w").write("%08x\n" % len(ref_lines))
    ref_path = os.path.join(out, "ref.txt")
    with open(ref_path, "wb") as f:
        f.write(ref_bytes)

    vivado = shutil.which("vivado") or shutil.which("vivado.bat")
    if not vivado:
        sys.exit("FAIL commit_trace: vivado not on PATH")
    run = os.path.join(out, "xsim")
    r = subprocess.run([vivado, "-mode", "batch", "-nojournal", "-nolog", "-notrace",
                        "-source", "scripts/sim.tcl", "-tclargs", "-f", "sim/commit_trace.f",
                        "-top", "tb_commit_trace",
                        "-hex", os.path.relpath(vec, ROOT).replace("\\", "/"),
                        "-run", run.replace("\\", "/")],
                       cwd=ROOT, capture_output=True, text=True)
    print("\n".join(ln for ln in r.stdout.splitlines() if ln.startswith(("SIM ", "PASS", "FAIL"))))
    if r.returncode:
        print(r.stdout[-2000:] + r.stderr[-2000:])
        sys.exit("FAIL commit_trace: xsim run")
    rtl_path = os.path.join(run, "trace_rtl0.txt")
    rtl = open(rtl_path, "rb").read()
    ref = open(ref_path, "rb").read()
    if rtl != ref:
        a, b = rtl.splitlines(), ref.splitlines()
        n = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), min(len(a), len(b)))
        print("line %d: rtl %r ref %r (%d vs %d lines)" % (n + 1, a[n:n + 1], b[n:n + 1], len(a), len(b)))
        sys.exit("FAIL commit_trace: trace differs from the reference")
    t = subprocess.run([sys.executable, "tools/tracecmp.py", rtl_path, ref_path], cwd=ROOT,
                       capture_output=True, text=True)
    if t.returncode:
        print(t.stdout + t.stderr)
        sys.exit("FAIL commit_trace: tracecmp")
    n_x0 = sum(1 for ln in ref_lines if " ld " in ln and " x" not in ln)
    print("PASS commit_trace: %d lines identical to rv32sim's (%s; %d loads into x0)"
          % (len(ref_lines), ", ".join(n for n, _ in TRACES), n_x0))


if __name__ == "__main__":
    main()
