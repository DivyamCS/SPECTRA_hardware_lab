"""check_counters.py - the counters of the whole SoC = the values.

    python tb/top/check_counters.py [DIR ...]      default: every <image>_<cfg> run of this commit

For each tb_top run (tb/top/run.py), the STATS packet decoded from uart_rtl.hex gives the
hardware counters of each running core. Reference:
  * one core: D_HIT and D_MISS from tools/cache_model.py replayed on rv32sim's data-access
    trace of the same image and CONFIG,
    INSTRET from rv32sim;
  * two cores: the D-cache is shared, so which access hits depends on the order the arbiter
    serves the two cores, and that order is timing (rv32sim's differs). D_HIT / D_MISS come from
    cache_model replayed on the RTL's own order (xsim/dc_trace.txt, written by tb_top); INSTRET
    of core 0 from rv32sim; core 1's INSTRET is not compared (it spins in spectra_main's final
    loop until core 0 writes RUN_STOP), nor core 0's for t_lock (its LOCK spin count is timing).
PASS only if every compared value is exactly equal for every run and core.
"""
import glob
import os
import re
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, HERE)
import cache_model  # noqa: E402
import simpath  # noqa: E402
import run as toprun  # noqa: E402


def main():
    dirs = sys.argv[1:] or sorted(glob.glob(os.path.join(toprun.commit_dir(), "top", "*_*")))
    seen, bad, n = set(), 0, 0
    for d in sorted(dirs, key=os.path.getmtime, reverse=True):
        m = re.match(r"(\w+)_([0-9a-f]{4})$", os.path.basename(d))
        hexf = os.path.join(d, "xsim", "uart_rtl.hex")
        if not m or m.group(0) in seen or not os.path.exists(hexf):
            continue
        seen.add(m.group(0))
        image, cfg = m.group(1), m.group(2)
        pk, _ = toprun.packets(bytes(int(x, 16) for x in open(hexf).read().split()))
        stats = [p for t, p in pk if t == 5]
        if not stats:
            continue
        cnt = struct.unpack("<14I", stats[-1][12:68])
        trace = os.path.join(d, "check_mem.txt")
        s = subprocess.run([simpath.find_sim(), "-c", cfg, "-m", trace, os.path.join(ROOT, "fw", "build", image)],
                           cwd=ROOT, capture_output=True, text=True)
        dual = (int(cfg, 16) >> 2) & 1
        order = os.path.join(d, "xsim", "dc_trace.txt") if dual else trace
        if not os.path.exists(order):
            print("skip %s %s: two cores, no dc_trace.txt (run before tb_top wrote it)" % (image, cfg))
            continue
        ref = cache_model.replay(order, int(cfg, 16)) if (int(cfg, 16) >> 1) & 1 else [[0, 0], [0, 0]]
        inst = [int(x) for x in re.findall(r"core\d: instret=(\d+)", s.stdout)]
        for core in range(1 + dual):
            n += 1
            names = ["INSTRET", "D_HIT", "D_MISS"]
            got = [cnt[7 * core], cnt[7 * core + 1], cnt[7 * core + 2]]
            want = [inst[core], ref[core][0], ref[core][1]]
            if dual and (core == 1 or image == "t_lock"):
                names, got, want = names[1:], got[1:], want[1:]
            ok = got == want
            bad += not ok
            print("%s %s %s core %d: %s (reference %s)" % ("ok  " if ok else "FAIL", image, cfg, core,
                  ", ".join("%s %d" % nv for nv in zip(names, got)), ", ".join(str(w) for w in want)))
    if n == 0 or bad:
        sys.exit("FAIL check_counters: %d of %d differ" % (bad, n))
    print("PASS check_counters: %d core runs, INSTRET / D_HIT / D_MISS = rv32sim / cache_model exactly" % n)


if __name__ == "__main__":
    main()
