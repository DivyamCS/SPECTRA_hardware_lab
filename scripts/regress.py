"""regress.py - run every RTL test listed in sim/tests.txt and print a PASS/FAIL table.

    python scripts/regress.py                 every test in sim/tests.txt
    python scripts/regress.py --list FILE     another list (for example an empty one)
    python scripts/regress.py NAME ...        only the named tests

sim/tests.txt, one test per line ('#' starts a comment):
    tb <name> <file list> <testbench top> [hex dir] [expect=finish]
        an xsim testbench run through scripts/sim.tcl; it must print exactly one
        "PASS <name>" line (or, with expect=finish, only reach $finish without errors)
    py <name> <script>
        a Python check script (paths relative to the repo root); PASS = exit status 0

Run directories: build/<commit>/regress/<name>/. Exit status 0 only if every test passes
(an empty list passes).
"""
import os
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def commit_dir():
    c = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True)
    d = subprocess.run(["git", "status", "--porcelain", "--untracked-files=no"], cwd=ROOT,
                       capture_output=True, text=True)
    return os.path.join(ROOT, "build", (c.stdout.strip() or "nogit") + ("-dirty" if d.stdout.strip() else ""))


def read_list(path):
    tests = []
    for n, line in enumerate(open(path), 1):
        line = line.split("#", 1)[0].split()
        if not line:
            continue
        kind = line[0]
        if (kind == "tb" and len(line) >= 4) or (kind == "py" and len(line) == 3):
            tests.append(line)
        else:
            sys.exit("%s line %d: cannot read %r" % (path, n, " ".join(line)))
    return tests


def run_tb(t, rundir):
    _, name, flist, top, *rest = t
    vivado = shutil.which("vivado") or shutil.which("vivado.bat")
    if not vivado:
        return False, "vivado not on PATH"
    cmd = [vivado, "-mode", "batch", "-nojournal", "-nolog", "-notrace", "-source", "scripts/sim.tcl",
           "-tclargs", "-f", flist, "-top", top, "-run", rundir.replace("\\", "/")]
    for r in rest:
        if r == "expect=finish":
            cmd += ["-expect", "finish"]
        else:
            cmd += ["-hex", r]
    p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    last = [ln for ln in p.stdout.splitlines() if ln.startswith("SIM ")]
    return p.returncode == 0, (last[-1] if last else (p.stdout + p.stderr)[-200:].strip())


def run_py(t, rundir):
    _, name, script = t
    p = subprocess.run([sys.executable, os.path.join(ROOT, script)], cwd=ROOT, capture_output=True, text=True)
    os.makedirs(rundir, exist_ok=True)
    with open(os.path.join(rundir, "output.txt"), "w") as f:
        f.write(p.stdout + p.stderr)
    lines = [ln for ln in p.stdout.splitlines() if ln.startswith(("PASS", "FAIL"))]
    return p.returncode == 0, (lines[-1] if lines else (p.stdout + p.stderr)[-200:].strip())


def main():
    args = sys.argv[1:]
    path = os.path.join(ROOT, "sim", "tests.txt")
    if "--list" in args:
        i = args.index("--list")
        path = args[i + 1]
        del args[i:i + 2]
    tests = read_list(path)
    if args:
        tests = [t for t in tests if t[1] in args]
    base = os.path.join(commit_dir(), "regress")
    rows, failed = [], 0
    for t in tests:
        t0 = time.time()
        ok, detail = (run_tb if t[0] == "tb" else run_py)(t, os.path.join(base, t[1]))
        failed += not ok
        rows.append((t[1], "PASS" if ok else "FAIL", time.time() - t0, detail))
        print("  %-24s %s  %5.0f s  %s" % rows[-1], flush=True)
    print("regress: %d tests, %d failed -> %s" % (len(tests), failed, "PASS" if not failed else "FAIL"))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
