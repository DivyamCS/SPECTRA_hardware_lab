"""run_m3.py - the core + D-cache regression (core + D-cache + mem_delay + DMEM, tb_core_dc).

    python tb/core/run_m3.py short        t_hazard, t_mext, t_cache, t_lock, t_barrier and MatMul
                                          for DC = 0 and 1 at every L (8 configurations)
    python tb/core/run_m3.py long         Mandelbrot halves, interleaved and Game of Life for
                                          DC = 0 and 1 at L = 8
    python tb/core/run_m3.py IMAGE CFG... any image and configs, as tb/core/run.py

Every run: rv32sim's checksum (golden OK) and 0 trace differences. Base CONFIG 0x0081 (FWD, IC,
one core, all ways); DC = cfg[1], LAT = cfg[4:3] (D-cache write-back, PLRU); PROGRAM =
cfg[6:5] for the demo image. Files: build/<commit>/core_dc/.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run  # noqa: E402

run.FILELIST, run.TOP, run.OUTDIR = "sim/core_dc.f", "tb_core_dc", "core_dc"


def cfg(dc, lat, program=0):
    return "%04x" % (0x0081 | (dc << 1) | (lat << 3) | (program << 5))


def matrix(lats=(0, 1, 2, 3)):
    out = []
    for lat in lats:
        out.append((0, lat))
        out.append((1, lat))
    return out


def main():
    arg = sys.argv[1:]
    if arg == ["short"]:
        jobs = [(img, [cfg(*c) for c in matrix()]) for img in ("t_hazard", "t_mext", "t_cache", "t_lock", "t_barrier")]
        jobs.append(("demo", [cfg(*c, program=3) for c in matrix()]))
    elif arg == ["long"]:
        jobs = [("demo", [cfg(*c, program=p) for c in matrix((2,))]) for p in (1, 2, 0)]
    elif len(arg) >= 2:
        jobs = [(arg[0], arg[1:])]
    else:
        sys.exit(__doc__)
    failed = 0
    for image, cfgs in jobs:
        sys.argv = [sys.argv[0], image] + cfgs
        try:
            run.main()
        except SystemExit as e:
            if e.code:
                print(e.code)
                failed += 1
    if failed:
        sys.exit("FAIL core_dc: %d image batches failed" % failed)
    print("PASS core_dc (%s)" % " ".join(arg))


if __name__ == "__main__":
    main()
