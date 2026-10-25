"""run.py - the whole SoC (soc_top + tb_top) against rv32sim

    python tb/top/run.py IMAGE CONFIG [CONFIG ...]      e.g.  demo 00f3

For each CONFIG (switch word, hex):
1. rv32sim -c CONFIG -u ref.bin -t sim IMAGE: reference UART stream, traces, checksum, cycles;
2. tb_top in xsim (sim/top.f), cycle cap 4 x rv32sim's cycles + 1,000,000;
3. checks:
   * the CHECKSUM written = rv32sim's (golden OK), and every running core's commit trace
     = rv32sim's (tools/tracecmp.py);
   * the UART line (uart_rtl.hex) parses into valid packets (CRC) with host/protocol.py;
     BEGIN, ROW and MROW packets equal rv32sim's packet for packet, cycle stamps aside; STATS
     equal except the cycle count, ARB_WAIT / BAR_WAIT (timing) and I_HIT / I_MISS (the RTL
     counts every fetch, also the one squashed after a taken branch; rv32sim counts executed
     instructions); INSTRET, D_HIT and D_MISS must be exact; every FRAME sent
     equals rv32sim's frame of the same generation, or tools/golden.py's grid when rv32sim skipped
     that generation (frame skipping depends on timing: PROTOCOL.md section 5);
   * the streamer's shadows at the end = tools/golden.py's data (Mandelbrot image, MatMul C heat
     map, Game of Life final grid) for the program run.
Files: build/<commit>/top/<image>_<config>/ (rewritten in place).
"""
import os
import re
import shutil
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.join(ROOT, "host"))
import golden  # noqa: E402
import protocol  # noqa: E402
import simpath  # noqa: E402


def commit_dir():
    c = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True)
    d = subprocess.run(["git", "status", "--porcelain", "--untracked-files=no"], cwd=ROOT,
                       capture_output=True, text=True)
    return os.path.join(ROOT, "build", (c.stdout.strip() or "nogit") + ("-dirty" if d.stdout.strip() else ""))


def packets(data):
    """Split a byte stream into (type, payload) with CRC checks; returns (list, errors)."""
    out, errs, i = [], [], 0
    while i < len(data):
        if data[i] != protocol.SYNC:
            errs.append("byte %d: 0x%02x is not a sync byte" % (i, data[i]))
            i += 1
            continue
        if i + 4 > len(data):
            errs.append("truncated header at %d" % i)
            break
        t, n = data[i + 1], data[i + 2] | (data[i + 3] << 8)
        if i + 5 + n > len(data):
            errs.append("truncated packet at %d" % i)
            break
        body = data[i + 1:i + 4 + n]
        if protocol.crc8(body) != data[i + 4 + n]:
            errs.append("CRC error in packet type %d at %d" % (t, i))
        if protocol.LENGTHS.get(t) != n:
            errs.append("type %d with length %d" % (t, n))
        out.append((t, bytes(data[i + 4:i + 4 + n])))
        i += 5 + n
    return out, errs


def compare_streams(rtl, ref, program, dual=False):
    """The comparison rules in the module docstring; returns a list of problems. With two cores
    the per-core counters and the order of the two cores' ROW / MROW packets depend on timing,
    so STATS is compared on config, ncores, program and checksum only, and ROW / MROW as sets
    (each hart's instruction stream is checked by its trace instead)."""
    probs = []
    gol = golden.gol_frames() if program == 0 else None

    def strip(t, p):
        if t == protocol.FRAME:
            return p[:2] + p[6:]                       # generation and cells, not the cycle
        if t == protocol.ROW:
            return p[:3] + p[7:]
        if t == protocol.MROW:
            return p[:2] + p[6:]
        if t == protocol.STATS:
            if dual:
                return p[:4] + p[8:12]
            cnt = list(struct.unpack("<14I", p[12:68]))
            for core in (0, 1):                        # timing / fetch-path dependent: not compared
                for j in (3, 4, 5, 6):                 # I_HIT, I_MISS, ARB_WAIT, BAR_WAIT
                    cnt[7 * core + j] = 0
            return p[:4] + p[8:12] + struct.pack("<14I", *cnt)
        return p

    a = [(t, strip(t, p)) for t, p in rtl if t != protocol.FRAME]
    b = [(t, strip(t, p)) for t, p in ref if t != protocol.FRAME]
    if dual:
        a, b = sorted(a), sorted(b)
    if a != b:
        n = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), min(len(a), len(b)))
        probs.append("non-FRAME packets differ at packet %d of %d / %d (%s vs %s)" % (
            n, len(a), len(b), protocol.NAMES.get(a[n][0], "?") if n < len(a) else "-",
            protocol.NAMES.get(b[n][0], "?") if n < len(b) else "-"))
    ref_frames = {struct.unpack("<H", p[:2])[0]: p[6:] for t, p in ref if t == protocol.FRAME}
    gens = []
    for t, p in rtl:
        if t != protocol.FRAME:
            continue
        g = struct.unpack("<H", p[:2])[0]
        gens.append(g)
        if g in ref_frames:
            want = ref_frames[g]
        elif gol is not None and g < len(gol):
            cells = gol[g]
            want = bytes(sum((1 << j) for j in range(8) if cells[8 * i + j]) for i in range(512))
        else:
            probs.append("FRAME of generation %d has no reference" % g)
            continue
        if p[6:] != want:
            probs.append("FRAME of generation %d differs" % g)
    if gens != sorted(set(gens)):
        probs.append("FRAME generations not strictly increasing")
    return probs, len(gens), len(ref_frames)


def check_shadows(run, program):
    probs = []
    if program in (1, 2):
        img = b"".join(int(w, 16).to_bytes(4, "little") for w in open(os.path.join(run, "shadow_img.hex")).read().split())
        if img[:27648] != golden.mb_image():
            probs.append("IMAGE shadow differs from golden.mb_image()")
    elif program == 3:
        c = bytes(int(x, 16) for x in open(os.path.join(run, "shadow_c.hex")).read().split())
        if c != bytes(golden.mm_heat(v) for v in golden.mm_result()):
            probs.append("MatMul C shadow differs from golden heat map")
    else:
        nib = [int(x, 16) for x in open(os.path.join(run, "shadow_grid.hex")).read().split()]
        grids = [[(nib[g * 1024 + i // 4] >> (i % 4)) & 1 for i in range(4096)] for g in (0, 1)]
        final = list(golden.gol_frames()[golden.GOL_GENS])
        if final not in ([list(x) for x in grids]):
            probs.append("neither grid shadow equals the final Game of Life grid")
    return probs


def run_one(image, cfg, vivado, extra=None):
    out = os.path.join(commit_dir(), "top", "%s_%s" % (image, cfg))
    vec = os.path.join(out, "vec")
    os.makedirs(vec, exist_ok=True)              # rewritten in place, nothing deleted
    src = os.path.join(ROOT, "fw", "build", image)
    for f in ("imem.hex", "dmem.hex"):
        shutil.copy(os.path.join(src, f), vec)
    open(os.path.join(vec, "cfg.mem"), "w").write(cfg + "\n")
    ref_bin, prefix = os.path.join(out, "ref.bin"), os.path.join(out, "sim")
    s = subprocess.run([simpath.find_sim(), "-c", cfg, "-u", ref_bin, "-t", prefix, src], cwd=ROOT,
                       capture_output=True, text=True)
    ms = re.search(r"checksum=0x([0-9a-f]{8}) golden=(\w+) cycles=(\d+)", s.stdout)
    if not ms:
        return False, "%s %s: rv32sim gave no checksum: %s" % (image, cfg, s.stdout[-300:])
    open(os.path.join(vec, "maxcyc.mem"), "w").write("%08x\n" % (4 * int(ms.group(3)) + 1000000))
    # browser.mem: the display-browser scenario, empty for an ordinary run
    open(os.path.join(vec, "browser.mem"), "w", newline="\n").write((extra or {}).get("browser.mem", ""))
    run = os.path.join(out, "xsim")
    r = subprocess.run([vivado, "-mode", "batch", "-nojournal", "-nolog", "-notrace", "-source", "scripts/sim.tcl",
                        "-tclargs", "-f", "sim/top.f", "-top", "tb_top",
                        "-hex", os.path.relpath(vec, ROOT).replace("\\", "/"), "-run", run.replace("\\", "/")],
                       cwd=ROOT, capture_output=True, text=True)
    log = open(os.path.join(run, "xsim.log")).read() if os.path.exists(os.path.join(run, "xsim.log")) else ""
    m = re.search(r"CHECKSUM ([0-9a-f]{8}) cycles (\d+)", log)
    if r.returncode or not m:
        fails = [ln for ln in log.splitlines() if "FAIL" in ln][:3]
        return False, "%s %s: RTL run failed: %s" % (image, cfg, "; ".join(fails) or (r.stdout[-400:]))
    probs = []
    if m.group(1) != ms.group(1):
        probs.append("checksum %s, rv32sim %s" % (m.group(1), ms.group(1)))
    dual = (int(cfg, 16) >> 2) & 1
    # t_lock with two cores spins on LOCK, so its loop counts legitimately differ from
    # rv32sim's (tools/tracecmp.py notes): it is checked by its checksum (the counter) only
    for h in range(0 if (dual and image == "t_lock") else 1 + dual):
        t = subprocess.run([sys.executable, "tools/tracecmp.py", os.path.join(run, "trace_rtl%d.txt" % h),
                            "%s%d.txt" % (prefix, h)], cwd=ROOT, capture_output=True, text=True)
        if t.returncode:
            probs.append("hart %d trace: %s" % (h, (t.stdout.strip().splitlines() or ["?"])[-1]))
    rtl_bytes = bytes(int(x, 16) for x in open(os.path.join(run, "uart_rtl.hex")).read().split())
    rtl_p, errs = packets(rtl_bytes)
    ref_p, ref_errs = packets(open(ref_bin, "rb").read())
    probs += ["UART: " + e for e in errs[:3]] + ["reference: " + e for e in ref_errs[:3]]
    program = (int(cfg, 16) >> 5) & 3 if image == "demo" else -1
    nf = nrf = 0
    if image == "demo":
        p, nf, nrf = compare_streams(rtl_p, ref_p, program, bool(dual))
        probs += p
        probs += check_shadows(run, program)
    ok = not probs
    # run cycles = the STATS packet's CYCLES (RUN_START..RUN_STOP), the quantity rv32sim reports;
    # tb_top's own count runs from reset until the streamer has sent everything (UART-bound)
    stats = [p for t, p in rtl_p if t == protocol.STATS]
    run_cyc = struct.unpack_from("<I", stats[-1], 4)[0] if stats else -1
    msg = "%s %s: checksum %s (golden %s), %d run cycles (rv32sim %s; %s simulated in all), %d packets (%d FRAMEs; rv32sim %d packets, %d FRAMEs)%s" % (
        image, cfg, m.group(1), ms.group(2), run_cyc, ms.group(3), m.group(2), len(rtl_p), nf, len(ref_p), nrf,
        "" if ok else "; " + "; ".join(probs[:4]))
    return ok, msg


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    vivado = shutil.which("vivado") or shutil.which("vivado.bat")
    if not vivado:
        sys.exit("FAIL top: vivado not on PATH")
    all_ok = True
    for cfg in sys.argv[2:]:
        ok, msg = run_one(sys.argv[1], cfg.lower(), vivado)
        print(("ok   " if ok else "FAIL ") + msg, flush=True)
        all_ok = all_ok and ok
    if not all_ok:
        sys.exit("FAIL top_%s" % sys.argv[1])
    print("PASS top_%s (%s)" % (sys.argv[1], ", ".join(sys.argv[2:])))


if __name__ == "__main__":
    main()
