"""board_browser.py - the 7-segment tour and browser on the board.

    python scripts/board_browser.py [--port PORT] --ltx FILE.ltx [CONFIG ...]      default COM8; 00f3 00f7

For each CONFIG: records the UART, sets the switches through the VIO and resets, waits for the run,
reads the display (the tour's first item; the wait is 1.2 x rv32sim's run at 50 MHz + 0.3 s), then walks tb/top/run_browser.py's 15 steps (every
SW15:14 setting in count mode, BTNL into rate mode, every setting, BTNR, back) reading SEG7,
SEG7_DP, SEG7_TXT and the LEDs after each; then BTNU (tour again) and a 3.3 s wait (the tour's
second item). The expected values come from PROTOCOL.md section 4's rules applied to this run's
STATS packet (tb/top/run_browser.py's expected()), so every value shown is checked against the
counters the board itself sent. PASS = every reading equal. These are board measurements.
"""
import os
import re
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path[:0] = [HERE, os.path.join(ROOT, "tb", "top"), os.path.join(ROOT, "tools"), os.path.join(ROOT, "host")]
import board_regress  # noqa: E402
import run as toprun  # noqa: E402
import run_browser  # noqa: E402
import seg7_model  # noqa: E402
import simpath  # noqa: E402
import protocol  # noqa: E402


def main():
    a = sys.argv[1:]
    port = "COM8"
    if "--port" in a:
        i = a.index("--port")
        port = a[i + 1]
        del a[i:i + 2]
    if len(a) < 2 or a[0] != "--ltx":
        sys.exit(__doc__)
    ltx, configs = a[1], [c.lower() for c in a[2:]] or ["00f3", "00f7"]
    bad = 0
    for cfg in configs:
        c = int(cfg, 16)
        # wait for the run itself (rv32sim's cycles x 1.2 at 50 MHz + 0.3 s): the tour starts at
        # the end of the run, so the first readings still see its first item
        sim = subprocess.run([simpath.find_sim(), "-c", cfg, os.path.join(ROOT, "fw", "build", "demo")],
                             cwd=ROOT, capture_output=True, text=True)
        cyc = int(re.search(r"cycles=(\d+)", sim.stdout).group(1))
        wait = int(1000 * (1.2 * cyc / 50e6 + 0.3))
        cmds = ["probes", ltx, "sw", cfg, "reset", "wait", str(wait), "read"]
        for sel, btn in run_browser.STEPS:
            cmds += ["sw", "%04x" % (c | (sel << 14))]
            if btn & run_browser.BTN_L:
                cmds += ["press", "BTNL"]
            if btn & run_browser.BTN_R:
                cmds += ["press", "BTNR"]
            cmds += ["wait", "150", "read"]
        cmds += ["press", "BTNU", "wait", "150", "read", "wait", "3300", "read", "pins"]
        rec = board_regress.Recorder(port)
        rec.start()
        r = subprocess.run(["vivado", "-mode", "batch", "-nojournal", "-nolog", "-notrace", "-source", "scripts/board.tcl",
                            "-tclargs"] + cmds, cwd=ROOT, capture_output=True, text=True, shell=os.name == "nt")
        time.sleep(0.5)
        rec.stop = True
        rec.join()
        reads = [dict(x.split("=") for x in ln.split()[1:]) for ln in r.stdout.splitlines() if ln.startswith("BOARD leds=")]
        data, dropped = board_regress.from_first_begin(rec.buf, c)
        pk, errs = toprun.packets(data)
        st = [p for t, p in pk if t == protocol.STATS]
        if r.returncode or len(reads) != len(run_browser.STEPS) + 3 or not st or errs:
            sys.exit("FAIL board_browser %s: %d readings, %d STATS, %d UART errors" % (cfg, len(reads), len(st), len(errs)))
        got = [(int(x["seg7"]), int(x["seg7_dp"], 16), int(x["leds"], 16), int(x["seg7_txt"], 16)) for x in reads]
        steps = [(0, 0)] + run_browser.STEPS                  # the reading right after the run: no move yet
        want = run_browser.expected(st[-1], steps)
        # BTNU: the tour from its first item; 3.3 s later its second (with I-cache on: the I-hit %)
        tour = run_browser.expected(st[-1], [(0, 0)])[0]
        want.append(tour)
        sel2 = run_browser.label(2, 1, 0, struct.unpack_from("<B", st[-1], 2)[0] == 2)
        cnt = struct.unpack_from("<14I", st[-1], 12)
        ihit = cnt[3] * 10000 // (cnt[3] + cnt[4]) if cnt[3] + cnt[4] else 0
        want.append((ihit, 4 | sel2[1], 1 | 2 | (1 << 10) | (1 << 11) | (2 << 14), sel2[0]))
        for i, (g, w) in enumerate(zip(got, want)):
            ok = g == w
            bad += not ok
            print("%s %s step %2d: '%s' LEDs %04x%s" % ("ok  " if ok else "FAIL", cfg, i, seg7_model.text(g[0], g[1], g[3]), g[2],
                  "" if ok else "   (expected '%s' LEDs %04x)" % (seg7_model.text(w[0], w[1], w[3]), w[2])))
    if bad:
        sys.exit("FAIL board_browser: %d readings differ" % bad)
    print("PASS board_browser (%s): tour, every browser setting, BTNU, labels = the run's own STATS" % " ".join(configs))


if __name__ == "__main__":
    main()
