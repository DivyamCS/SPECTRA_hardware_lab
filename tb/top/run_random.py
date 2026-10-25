"""run_random.py - random switch settings on the whole SoC.

    python tb/top/run_random.py PROGRAM [COUNT] [SEED]     PROGRAM = matmul | mandel | gol
    python tb/top/run_random.py --board-list FILE           the list for the board

COUNT (default 40) seeded random settings of FWD, DC, DUAL, LAT, IC, WPOL and WAYS (SW0-13
except PROGRAM, which is fixed by PROGRAM; SW8 is drawn too but reserved, so ignored; Mandelbrot alternates halves / interleaved), the same
settings for every program with the same SEED (default 106). Each runs through tb/top/run.py:
golden checksum = rv32sim's, every running hart's trace = rv32sim's, every UART packet equal
to rv32sim's. Prints one line per setting and PASS only if all pass.
"""
import os
import random
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import run  # noqa: E402


def settings(count, seed):
    rng = random.Random(seed)
    out = []
    for _ in range(count):
        v = rng.getrandbits(14) & ~(3 << 5)            # SW13:0 without PROGRAM
        out.append(v)
    return out


def configs(prog, count=40, seed=106):
    """The switch words (hex) of the random set for one program, in run order."""
    return ["%04x" % (v | ({"gol": 0, "matmul": 3}.get(prog, 1 + (i & 1)) << 5))
            for i, v in enumerate(settings(count, seed))]


def board_list(path):
    """The random settings of the three programs as a list for the board
    regression (scripts/board_regress.py). Column xsim = PASS for the settings already run here (MatMul 1-40,
    Mandelbrot 1-15; Divyam's decision of 16 Oct: the rest on the board)."""
    done = {"matmul": 40, "mandel": 15, "gol": 0}
    with open(path, "w", newline="\n") as f:
        f.write("# program index config xsim   (tb/top/run_random.py, seed 106)\n")
        for prog in ("matmul", "mandel", "gol"):
            for i, cfg in enumerate(configs(prog)):
                f.write("%-6s %2d %s %s\n" % (prog, i + 1, cfg, "PASS" if i < done[prog] else "-"))


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--board-list":
        board_list(sys.argv[2])
        return
    if len(sys.argv) < 2 or sys.argv[1] not in ("matmul", "mandel", "gol"):
        sys.exit(__doc__)
    prog = sys.argv[1]
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 40
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 106
    vivado = shutil.which("vivado") or shutil.which("vivado.bat")
    bad = 0
    for i, cfg in enumerate(configs(prog, count, seed)):
        ok, msg = run.run_one("demo", cfg, vivado)
        print(("ok   " if ok else "FAIL ") + "%2d " % (i + 1) + msg, flush=True)
        bad += not ok
    if bad:
        sys.exit("FAIL random_%s: %d of %d" % (prog, bad, count))
    print("PASS random_%s: %d settings (seed %d)" % (prog, count, seed))


if __name__ == "__main__":
    main()
