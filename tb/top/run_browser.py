"""run_browser.py - the 7-segment display browser in tb_top.

    python tb/top/run_browser.py [CONFIG]          default 00f3 (MatMul, one core)

Runs tb/top/run.py's full-SoC check for CONFIG with a browser scenario: after the run (the tour
is on: its first item, cycles), every SW15:14 setting in count mode (the first move leaves the
tour), BTNL into rate mode and every setting again, BTNR (a no-op with DUAL = 0, toggles the core
with DUAL = 1), BTNL back. tb_top logs SEG7, SEG7_DP, the LEDs and SEG7_TXT after each step
(browser.txt). The expected values come from PROTOCOL.md section 4's rules applied to the run's
own STATS counters (CYCLES frozen at RUN_STOP, per-core counters), labels included. The tour's
3 s steps are 150 M cycles, too long for xsim; tests/run_all.py checks them on rv32sim and
the board run checks them on the FPGA. PASS = every value equal.
"""
import os
import shutil
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import run  # noqa: E402
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(HERE)), "tools"))
import seg7_model  # noqa: E402

BTN_L, BTN_R = 1, 2
STEPS = [(0, 0), (1, 0), (2, 0), (3, 0),            # count mode, every selector
         (3, BTN_L), (2, 0), (1, 0), (0, 0),        # rate mode
         (0, BTN_R), (1, 0), (2, 0), (3, 0),        # BTNR: core 1 if DUAL, else nothing
         (2, BTN_L), (1, BTN_R), (0, 0)]            # back to count mode, core 0 again
WAIT = 60000


# labels (PROTOCOL.md section 3 letter codes): count mode / rate mode by SW15:14
LETTER = {"C": 1, "y": 2, "I": 3, "H": 4, "d": 5, "n": 6, "P": 7, "A": 8, "r": 9, "0": 11, "1": 12}
LABELS = [["Cy", "dH", "dn", "Ar"], ["CPI", "dH", "IH", "Ar"]]


def label(sel, rmode, core, dual):
    name = LABELS[rmode][sel] + (str(core) if dual and not (sel == 0 and not rmode) else "")
    txt = 0
    for i, ch in enumerate(name):
        txt |= LETTER[ch] << (28 - 4 * i)
    ldp = (1 << (8 - len(name))) if len(name) > len(LABELS[rmode][sel]) else 0
    return txt, ldp, 8 - len(name)


def expected(stats, steps):
    cfg, ncores = struct.unpack_from("<HB", stats)
    cyc, csum = struct.unpack_from("<II", stats, 4)
    c = struct.unpack_from("<14I", stats, 12)
    cnt = [dict(zip(["instret", "dhit", "dmiss", "ihit", "imiss", "arbwait", "barwait"], c[7 * k:7 * k + 7]))
           for k in (0, 1)]
    dual = ncores == 2
    core = rmode = 0
    tour, prev_sel = 1, (cfg >> 14) & 3                  # the tour is on after the run
    ok = 1                                               # checked separately: golden checksum
    out = []
    for sel, btn in steps:
        if tour and (btn & (BTN_L | BTN_R) or sel != prev_sel):
            tour = 0
        prev_sel = sel
        if tour:                                         # within 3 s: the first item, cycles
            s_, r_, k_ = 0, 0, 0
        else:
            if btn & BTN_R and dual:
                core ^= 1
            if btn & BTN_L:
                rmode ^= 1
            s_, r_, k_ = sel, rmode, core
        txt, ldp, free = label(s_, r_, k_, dual)
        maxv = 10 ** free - 1
        k, val, dp, th = cnt[k_], 0, 0, 0
        rate = lambda part, whole, scale: (part * scale) // whole if whole else 0  # noqa: E731
        if not r_:
            if s_ == 0:
                val, th = cyc // 1000, 1
            else:
                val = k["dhit"] if s_ == 1 else k["dmiss"] if s_ == 2 else k["arbwait"]
                if val > maxv:
                    val, th = val // 1000, 1
            val = min(val, maxv)
        else:
            dp = 1 << 2
            if s_ == 0:
                val = rate(cyc, k["instret"], 100)
            elif s_ == 1:
                val = rate(k["dhit"], k["dhit"] + k["dmiss"], 10000)
            elif s_ == 2:
                val = rate(k["ihit"], k["ihit"] + k["imiss"], 10000)
            else:
                val = rate(k["arbwait"], cyc, 10000)
            val = min(val, maxv)
        leds = 1 | (ok << 1) | (tour << 10) | (r_ << 11) | (th << 12) | (k_ << 13) | (s_ << 14)
        out.append((val, dp | ldp, leds, txt))
    return out


def main():
    cfg = sys.argv[1] if len(sys.argv) > 1 else "00f3"
    vivado = shutil.which("vivado") or shutil.which("vivado.bat")
    scen = "".join("%x %x %d\n" % (s, b, WAIT) for s, b in STEPS)
    d = os.path.join(run.commit_dir(), "top", "demo_%s" % cfg, "xsim")    # before the run, as run_one
    ok, msg = run.run_one("demo", cfg, vivado, extra={"browser.mem": scen})
    print(("ok   " if ok else "FAIL ") + msg)
    pk, _ = run.packets(bytes(int(x, 16) for x in open(os.path.join(d, "uart_rtl.hex")).read().split()))
    stats = [p for t, p in pk if t == 5][-1]
    got = [tuple(int(x) for x in ln.split()) for ln in open(os.path.join(d, "browser.txt")) if ln.strip()]
    want = expected(stats, STEPS)
    bad = 0
    for i, ((sel, btn), g, w) in enumerate(zip(STEPS, got, want)):
        same = g == w
        bad += not same
        print("%s step %2d SW15:14=%d btn=%s: %-11s SEG7 %d dp %02x LEDs %04x txt %08x%s" % (
            "ok  " if same else "FAIL", i + 1, sel, {0: "-", 1: "L", 2: "R"}[btn],
            "'" + seg7_model.text(g[0], g[1], g[3]) + "'", g[0], g[1], g[2], g[3],
            "" if same else "   (expected '%s' SEG7 %d dp %02x LEDs %04x txt %08x)" % ((seg7_model.text(w[0], w[1], w[3]),) + w)))
    if not ok or bad or len(got) != len(STEPS):
        sys.exit("FAIL browser: %d of %d steps differ" % (bad + abs(len(STEPS) - len(got)), len(STEPS)))
    print("PASS browser (%s): %d steps, SEG7 / SEG7_DP / SEG7_TXT / LEDs = PROTOCOL.md's rules on the run's counters" % (cfg, len(STEPS)))


if __name__ == "__main__":
    main()
