"""board_regress.py - run a list of switch settings on the board and check every run.

    python scripts/board_regress.py LIST [--bit FILE.bit | --ltx FILE.ltx] [--image DIR] [--out DIR] [--port PORT]

LIST: a text file, one setting per line ("#" comments): either "NAME CONFIG_HEX" or the
scripts/board_random_106.txt format "PROGRAM INDEX CONFIG XSIM"; or "--configs 00f3,00f7".
--bit programs the FPGA first (FILE.ltx next to it gives the VIO probes); --ltx uses an FPGA
programmed earlier. --image is the program in the bitstream (default fw/build/demo).

For each setting: rv32sim gives the reference UART stream (-u) and its cycle count; one Vivado
session (scripts/board.tcl) sets the switches through the VIO, pulses reset, waits long enough
for the run and its UART stream (1.5 x the reference cycles at 50 MHz + the stream at 100 kB/s
+ 0.4 s) and reads the LEDs; meanwhile this script records the UART (--port, default COM8) the whole time. The recording
is split into runs at each BEGIN packet; run k must belong to setting k. Each run passes when:
  * BEGIN's CONFIG = the setting; LED0 and LED1 on (done, checksum = golden); uart_busy = 0 when
    read (the run and its stream finished in the wait);
  * every packet has a valid CRC and the packets equal rv32sim's under tb/top/run.py's rules
    (BEGIN, ROW, MROW exact; STATS exact except timing counters - one core: INSTRET, D_HIT,
    D_MISS exact; FRAMEs = rv32sim's or golden.py's grid of that generation).
Writes OUT/board_regress.csv (one row per setting, with the board's STATS counters of both
cores) and prints PASS board_regress or FAIL.
These are board measurements; rv32sim's cycles in the CSV are its approximate model.
"""
import csv
import os
import re
import struct
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path[:0] = [os.path.join(ROOT, "tb", "top"), os.path.join(ROOT, "tools"), os.path.join(ROOT, "host")]
import run as toprun  # noqa: E402
import protocol  # noqa: E402
import simpath  # noqa: E402


def read_list(arg):
    out = []
    for ln in open(arg):
        p = ln.split("#", 1)[0].split()
        if len(p) == 2:
            out.append((p[0], p[1].lower()))
        elif len(p) == 4:
            out.append(("%s_%s" % (p[0], p[1]), p[2].lower()))
    return out


def from_first_begin(buf, cfg):
    """The recording from the first BEGIN packet of CONFIG cfg: whatever the board was sending
    before (the end of a run started earlier, cut by our first reset) belongs to no setting.
    Returns (bytes, number of bytes dropped)."""
    head = bytes([protocol.SYNC, protocol.BEGIN, 4, 0, cfg & 0xFF, cfg >> 8])
    i = bytes(buf).find(head)
    return (bytes(buf), 0) if i < 0 else (bytes(buf[i:]), i)


class Recorder(threading.Thread):
    def __init__(self, port):
        super().__init__(daemon=True)
        import serial
        self.ser = serial.Serial(port, 1000000, timeout=0.05)
        self.ser.reset_input_buffer()
        self.buf, self.stop = bytearray(), False

    def run(self):
        while not self.stop:
            self.buf += self.ser.read(65536)
        self.ser.close()


def main():
    a = sys.argv[1:]
    opt = {"--bit": None, "--ltx": None, "--image": "fw/build/demo", "--out": None, "--port": "COM8", "--configs": None}
    lst = None
    while a:
        k = a.pop(0)
        if k in opt:
            opt[k] = a.pop(0)
        else:
            lst = k
    settings = [("cfg_" + c, c.lower()) for c in opt["--configs"].split(",")] if opt["--configs"] else read_list(lst)
    if not settings or not (opt["--bit"] or opt["--ltx"]):
        sys.exit(__doc__)
    out = opt["--out"] or os.path.join(toprun.commit_dir(), "board_regress", os.path.splitext(os.path.basename(lst or "configs"))[0])
    os.makedirs(out, exist_ok=True)
    image = os.path.join(ROOT, opt["--image"])
    demo = os.path.basename(os.path.normpath(image)) == "demo"

    # references
    refs = {}
    for name, cfg in settings:
        if cfg in refs:
            continue
        rb = os.path.join(out, "ref_%s.bin" % cfg)
        s = subprocess.run([simpath.find_sim(), "-c", cfg, "-u", rb, image], cwd=ROOT, capture_output=True, text=True)
        m = re.search(r"cycles=(\d+)", s.stdout)
        if not m:
            sys.exit("FAIL board_regress: rv32sim gave no result for %s" % cfg)
        refs[cfg] = (int(m.group(1)), open(rb, "rb").read())
    cmds = (["program", opt["--bit"]] if opt["--bit"] else ["probes", opt["--ltx"]])
    total = 0.0
    for name, cfg in settings:
        cyc, ref = refs[cfg]
        ms = int(1000 * (1.5 * cyc / 50e6 + len(ref) / 100000 + 0.4))
        total += ms / 1000
        cmds += ["sw", cfg, "reset", "wait", str(ms), "read"]
    cmds += ["pins"]
    print("board_regress: %d settings, about %.0f s of runs" % (len(settings), total), flush=True)

    rec = Recorder(opt["--port"])
    rec.start()
    r = subprocess.run(["vivado", "-mode", "batch", "-nojournal", "-nolog", "-notrace", "-source", "scripts/board.tcl",
                        "-tclargs"] + cmds, cwd=ROOT, capture_output=True, text=True, shell=os.name == "nt")
    time.sleep(1.0)
    rec.stop = True
    rec.join()
    open(os.path.join(out, "board_uart.bin"), "wb").write(rec.buf)
    open(os.path.join(out, "board_tcl.log"), "w").write(r.stdout)
    reads = [dict(x.split("=") for x in ln.split()[1:]) for ln in r.stdout.splitlines() if ln.startswith("BOARD leds=")]
    if r.returncode or len(reads) != len(settings):
        sys.exit("FAIL board_regress: board.tcl ended with %d of %d readings (see %s)" % (
            len(reads), len(settings), os.path.join(out, "board_tcl.log")))

    data, dropped = from_first_begin(rec.buf, int(settings[0][1], 16))
    if dropped:
        print("     (%d bytes before the first run ignored: a run started before this session)" % dropped)
    pk, errs = toprun.packets(data)
    runs, cur = [], None
    for t, p in pk:
        if t == protocol.BEGIN:
            cur = []
            runs.append(cur)
        if cur is not None:
            cur.append((t, p))
    # programming the FPGA (--bit) boots it once on the physical switches before the first
    # scripted reset: that run comes first in the recording and belongs to no setting
    boot = len(runs) - len(settings) if opt["--bit"] and len(runs) == len(settings) + 1 else 0
    if boot:
        print("     (one power-up run after programming, config 0x%04x, not counted)" % struct.unpack_from("<H", runs[0][0][1])[0])
        runs = runs[boot:]
    rows, bad = [], 0
    for i, (name, cfg) in enumerate(settings):
        c = int(cfg, 16)
        probs = []
        run = runs[i] if i < len(runs) else []
        rd = reads[i]
        leds = int(rd["leds"], 16)
        if not run or struct.unpack_from("<H", run[0][1])[0] != c:
            probs.append("run %d does not start with BEGIN of 0x%04x" % (i + 1, c))
        if leds & 3 != 3:
            probs.append("LEDs 0x%04x (want done + checksum OK)" % leds)
        if rd["uart_busy"] != "0":
            probs.append("streamer still busy after the wait")
        st = [p for t, p in run if t == protocol.STATS]
        bcyc = struct.unpack_from("<I", st[-1], 4)[0] if st else None
        ref_pk, _ = toprun.packets(refs[cfg][1])
        nf = 0
        if run:
            p, nf, _ = toprun.compare_streams(run, ref_pk, (c >> 5) & 3 if demo else 3, bool((c >> 2) & 1))
            probs += p
        ok = not probs
        bad += not ok
        rows.append([name, "%04x" % c, (c >> 5) & 3 if demo else "-", 1 + ((c >> 2) & 1), bcyc, refs[cfg][0],
                     int(bool(leds & 2)), len(run), nf, "ok" if ok else "; ".join(probs[:3])]
                    + (list(struct.unpack_from("<14I", st[-1], 12)) if st else [""] * 14))
        print("%s %-16s 0x%04x: board %s cycles (rv32sim %d), %d packets, %d FRAMEs, LEDs 0x%04x%s" % (
            "ok  " if ok else "FAIL", name, c, bcyc, refs[cfg][0], len(run), nf, leds, "" if ok else "; " + "; ".join(probs[:3])), flush=True)
    if len(runs) != len(settings):
        bad += 1
        print("FAIL %d runs recorded for %d settings" % (len(runs), len(settings)))
    with open(os.path.join(out, "board_regress.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["name", "config", "program", "cores", "board_cycles", "rv32sim_cycles", "checksum_ok", "packets", "frames", "result"]
                   + ["c%d_%s" % (k, n) for k in (0, 1) for n in protocol.COUNTERS])     # the board's STATS counters
        w.writerows(rows)
    print("UART: %d bytes, %d packets, %d errors" % (len(rec.buf), len(pk), len(errs)))
    if bad or errs:
        sys.exit("FAIL board_regress: %d of %d settings (%s)" % (bad, len(settings), out))
    print("PASS board_regress: %d settings on the board, every run = rv32sim's packets, checksum OK (%s)" % (len(settings), out))


if __name__ == "__main__":
    main()
