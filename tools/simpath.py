"""simpath.py - locate (or build) the rv32sim binary for this computer.

Order: sim/rv32sim[.exe] if present; else compile sim/rv32sim.c with cc, gcc, clang or zig.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def find_sim(rebuild=False):
    exe = os.path.join(ROOT, "sim", "rv32sim.exe" if os.name == "nt" else "rv32sim")
    if os.path.exists(exe) and not rebuild:
        return exe
    src = os.path.join(ROOT, "sim", "rv32sim.c")
    for cc in (["cc"], ["gcc"], ["clang"], [sys.executable, "-m", "ziglang", "cc"]):
        try:
            if subprocess.run(cc + ["-O2", "-o", exe, src], capture_output=True).returncode == 0:
                return exe
        except OSError:
            continue
    raise RuntimeError("no rv32sim: install a C compiler or 'pip install ziglang', then retry")


if __name__ == "__main__":
    print(find_sim("--rebuild" in sys.argv))
