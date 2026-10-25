"""check_hits.py - the D-cache's hit and miss pulses = the Python cache model.

    python tb/core/check_hits.py                 run t_cache, t_hazard and MatMul (DC = 1, L = 8,
                                                 L = 5 and 10) through tb_core_dc,
                                                 then compare
    python tb/core/check_hits.py --from DIR      compare every DC = 1 run already in DIR
                                                 (a build/<commit>/core_dc directory)

For each run: the RTL count is tb_core_dc's "DCACHE hits N misses M" (pulses counted inside
RUN_START..RUN_STOP); the reference is tools/cache_model.py replayed on rv32sim's data-access
trace (-m) for the same image and CONFIG. PASS only if every pair is exactly equal.
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, HERE)
import cache_model  # noqa: E402
import simpath  # noqa: E402


def reference(image, cfg, workdir):
    trace = os.path.join(workdir, "memtrace_%s_%s.txt" % (image, cfg))
    subprocess.run([simpath.find_sim(), "-c", cfg, "-m", trace, os.path.join(ROOT, "fw", "build", image)],
                   cwd=ROOT, capture_output=True)
    hits, misses = cache_model.replay(trace, int(cfg, 16))[0]
    return hits, misses


def rtl_counts(run_dir):
    log = os.path.join(run_dir, "xsim", "xsim.log")
    if not os.path.exists(log):
        return None
    m = re.search(r"DCACHE hits (\d+) misses (\d+)", open(log).read())
    return (int(m.group(1)), int(m.group(2))) if m else None


def main():
    if sys.argv[1:2] == ["--from"]:
        base = sys.argv[2]
    else:
        import run_m3
        jobs = [("t_cache", ["0093", "0083", "009b"]), ("t_hazard", ["0093", "009b"]),
                ("demo", ["00f3", "00fb"])]
        for image, cfgs in jobs:
            sys.argv = [sys.argv[0], image] + cfgs
            run_m3.main()
        base = os.path.join(run_m3.run.commit_dir(), "core_dc")
    work = os.path.join(base, "_hits")
    os.makedirs(work, exist_ok=True)
    pairs, bad = 0, 0
    for name in sorted(os.listdir(base)):
        m = re.match(r"(\w+)_([0-9a-f]{4})$", name)
        if not m or not (int(m.group(2), 16) >> 1) & 1:            # DC = 1 runs only
            continue
        got = rtl_counts(os.path.join(base, name))
        if got is None:
            continue
        want = reference(m.group(1), m.group(2), work)
        pairs += 1
        ok = tuple(got) == tuple(want)
        bad += not ok
        print("%s %-10s %s: RTL hits %d misses %d, cache_model hits %d misses %d" % (
            "ok  " if ok else "FAIL", m.group(1), m.group(2), got[0], got[1], want[0], want[1]))
    if pairs == 0 or bad:
        sys.exit("FAIL check_hits: %d of %d runs differ" % (bad, pairs))
    print("PASS check_hits: %d runs, D-cache hit and miss counts = cache_model.py on rv32sim's trace" % pairs)


if __name__ == "__main__":
    main()
