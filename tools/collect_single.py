"""collect_single.py - single-core simulation results per configuration.

    python tools/collect_single.py > docs/results/sim_single.md

Reads every tb_core_dc run under build/*/core_dc/<image>_<config>/xsim/xsim.log (for each image and config the newest run), and prints a Markdown table: run cycles and
instructions inside RUN_START..RUN_STOP, CPI, D-cache hits, misses and hit rate. These are xsim
cycle counts of the RTL (one core, ideal 2-cycle MMIO stub), not board measurements.
"""
import glob
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROG = {0: "Game of Life", 1: "Mandelbrot halves", 2: "Mandelbrot interleaved", 3: "MatMul"}
LAT = {0: 5, 1: 6, 2: 8, 3: 10}


def main():
    runs = {}
    for log in glob.glob(os.path.join(ROOT, "build", "*", "core_dc", "*", "xsim", "xsim.log")):
        name = os.path.basename(os.path.dirname(os.path.dirname(log)))
        m = re.match(r"(\w+)_([0-9a-f]{4})$", name)
        if not m:
            continue
        txt = open(log).read()
        c = re.search(r"\(run (\d+) cycles, (\d+) instructions\)", txt)
        d = re.search(r"DCACHE hits (\d+) misses (\d+)", txt)
        if not (c and d and "PASS core" in txt):
            continue
        key = (m.group(1), m.group(2))
        t = os.path.getmtime(log)
        if key not in runs or runs[key][0] < t:
            runs[key] = (t, int(c.group(1)), int(c.group(2)), int(d.group(1)), int(d.group(2)))
    print("# Single-core results in simulation\n")
    print(__doc__.split("\n\n", 2)[2].strip().replace("\n", " ") + "\n")
    print("CONFIG bits: DC = bit 1, LAT = bits 4:3, PROGRAM = bits 6:5 (demo image);")
    print("FWD and IC are on in every row (bits 0 and 7); the D-cache is write-back with PLRU, the I-cache FIFO.\n")
    print("| Image / program | CONFIG | DC | L | Run cycles | Instructions | CPI | D hits | D misses | D hit rate |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    def order(k):
        img, cfg = k
        v = int(cfg, 16)
        return (img, (v >> 5) & 3, (v >> 3) & 3, (v >> 1) & 1)
    for key in sorted(runs, key=order):
        img, cfg = key
        v = int(cfg, 16)
        _, cyc, ins, h, mi = runs[key]
        dc = (v >> 1) & 1
        name = PROG[(v >> 5) & 3] if img == "demo" else img
        rate = "%.2f %%" % (100.0 * h / (h + mi)) if dc and h + mi else "-"
        print("| %s | %s | %d | %d | %s | %s | %.3f | %s | %s | %s |" % (
            name, cfg.upper(), dc,
            LAT[(v >> 3) & 3], format(cyc, ","), format(ins, ","), cyc / ins if ins else 0,
            format(h, ",") if dc else "-", format(mi, ",") if dc else "-", rate))
    print("\n%d runs. Every one gave rv32sim's checksum (golden OK) with 0 trace differences "
          "(docs/results/merge3.md)." % len(runs))


if __name__ == "__main__":
    main()
