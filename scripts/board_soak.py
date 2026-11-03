"""board_soak.py - reset robustness on the board: runs cut off by BTNC, then rerun.

    python scripts/board_soak.py [--port PORT] --ltx FILE.ltx [N] [SEED]          default COM8, N = 40, SEED = 7

N iterations, each with a seeded random setting (MatMul, Mandelbrot, Game of Life; 1 or 2 cores;
caches, latency, replacement, write policy random): set the switches through the VIO, reset,
wait a random 1 ms .. 0.8 x the run (the run is cut off mid-way, often mid-packet on the UART),
reset again, wait for the whole run and read the LEDs. Every 10th iteration first sends a
burst of 10 resets 5 ms apart. The UART is recorded throughout.

Each iteration passes when the completed run (the last BEGIN of its CONFIG before the next
iteration) has LED0 and LED1 on and its bytes, from BEGIN to STATS, parse without an error and
equal rv32sim's packets (tb/top/run.py's rules). A reset must never leave memory, caches or the
streamer in a state that changes the next run. Cut-off runs are counted, not checked.
"""
import os
import random
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path[:0] = [HERE, os.path.join(ROOT, "tb", "top"), os.path.join(ROOT, "tools"), os.path.join(ROOT, "host")]
import board_regress  # noqa: E402
import run as toprun  # noqa: E402
import protocol  # noqa: E402
import simpath  # noqa: E402


def main():
    a = sys.argv[1:]
    port = "COM8"
    if "--port" in a:
        i = a.index("--port")
        port = a[i + 1]
        del a[i:i + 2]
    if len(a) < 2 or a[0] != "--ltx":
        sys.exit(__doc__)
    ltx = a[1]
    n = int(a[2]) if len(a) > 2 else 40
    rng = random.Random(int(a[3]) if len(a) > 3 else 7)
    out = os.path.join(toprun.commit_dir(), "board_soak")
    os.makedirs(out, exist_ok=True)
    image = os.path.join(ROOT, "fw", "build", "demo")
    its, refs = [], {}
    for k in range(n):
        while True:
            cfg = (rng.choice([0, 1, 2, 3]) << 5) | rng.getrandbits(5) & 0x1F | rng.choice([0, 0x80]) | \
                  (rng.getrandbits(2) << 8) | (rng.choice([0, 0, 1, 2, 4, 8, 3]) << 10)
            cfg |= 0x2 if rng.random() < 0.8 else 0          # mostly D-cache on (shorter runs)
            if cfg not in refs:
                rb = os.path.join(out, "ref_%04x.bin" % cfg)
                s = subprocess.run([simpath.find_sim(), "-c", "%04x" % cfg, "-u", rb, image], cwd=ROOT,
                                   capture_output=True, text=True)
                refs[cfg] = (int(re.search(r"cycles=(\d+)", s.stdout).group(1)), open(rb, "rb").read())
            if refs[cfg][0] < 150e6:                         # at most ~3 s per run
                break
        cyc, ref = refs[cfg]
        cut = rng.randint(1, max(1, int(0.8 * cyc / 50e3)))
        its.append((cfg, cut, int(1000 * (1.5 * cyc / 50e6 + len(ref) / 100000 + 0.4)), k % 10 == 9))
    cmds = ["probes", ltx]
    for cfg, cut, full, burst in its:
        cmds += ["sw", "%04x" % cfg]
        if burst:
            for _ in range(10):
                cmds += ["reset", "wait", "5"]
        cmds += ["reset", "wait", str(cut), "reset", "wait", str(full), "read"]
    cmds += ["pins"]
    print("board_soak: %d iterations, %d cut-off runs, %d reset bursts" % (n, n, sum(b for *_, b in its)), flush=True)
    rec = board_regress.Recorder(port)
    rec.start()
    r = subprocess.run(["vivado", "-mode", "batch", "-nojournal", "-nolog", "-notrace", "-source", "scripts/board.tcl",
                        "-tclargs"] + cmds, cwd=ROOT, capture_output=True, text=True, shell=os.name == "nt")
    time.sleep(1.0)
    rec.stop = True
    rec.join()
    buf = bytes(rec.buf)
    open(os.path.join(out, "soak_uart.bin"), "wb").write(buf)
    reads = [dict(x.split("=") for x in ln.split()[1:]) for ln in r.stdout.splitlines() if ln.startswith("BOARD leds=")]
    if len(reads) != n:
        sys.exit("FAIL board_soak: %d of %d readings" % (len(reads), n))
    # BEGIN headers: every run (cut-off or complete) starts with one
    begins = [m.start() for m in re.finditer(re.escape(bytes([protocol.SYNC, protocol.BEGIN, 4, 0])), buf)]
    bad, pos, cuts = 0, 0, 0
    for k, (cfg, cut, full, burst) in enumerate(its):
        head = bytes([protocol.SYNC, protocol.BEGIN, 4, 0, cfg & 0xFF, cfg >> 8])
        mine = [b for b in begins if b >= pos and buf[b:b + 6] == head]
        # the iteration's runs: those of this CONFIG before the first run of the next iteration
        nxt = None
        if k + 1 < n:
            h2 = bytes([protocol.SYNC, protocol.BEGIN, 4, 0, its[k + 1][0] & 0xFF, its[k + 1][0] >> 8])
            later = [b for b in begins if b > (mine[-1] if mine else pos) and buf[b:b + 6] == h2]
            nxt = later[0] if later else None
        mine = [b for b in mine if nxt is None or b < nxt]
        probs = []
        if not mine:
            probs.append("no BEGIN")
        else:
            cuts += len(mine) - 1
            end = nxt if nxt is not None else len(buf)
            pk, errs = toprun.packets(buf[mine[-1]:end])
            ref_pk, _ = toprun.packets(refs[cfg][1])
            p, _, _ = toprun.compare_streams(pk, ref_pk, (cfg >> 5) & 3, bool((cfg >> 2) & 1))
            probs += ["UART: " + e for e in errs[:2]] + p
            pos = mine[-1] + 1
        leds = int(reads[k]["leds"], 16)
        if leds & 3 != 3:
            probs.append("LEDs 0x%04x" % leds)
        ok = not probs
        bad += not ok
        print("%s %2d 0x%04x: cut after %4d ms%s, then the whole run: %s" % (
            "ok  " if ok else "FAIL", k + 1, cfg, cut, " (after 10 resets)" if burst else "",
            "checksum OK, packets = rv32sim" if ok else "; ".join(probs[:3])), flush=True)
    print("board_soak: %d cut-off runs seen in the recording (%d bytes)" % (cuts, len(buf)))
    if bad:
        sys.exit("FAIL board_soak: %d of %d iterations" % (bad, n))
    print("PASS board_soak: %d runs cut off by reset at random times (+ %d bursts of 10 resets), every rerun exact" % (
        n, sum(b for *_, b in its)))


if __name__ == "__main__":
    main()
