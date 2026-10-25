"""run_all.py - every software check in the kit, one command (Windows, macOS, Linux).

    python tests/run_all.py          about 1-3 minutes

1. reference self-tests (M-extension, cache, arbiter, protocol) and the spec/header map check
2. firmware build with -Werror; .data must be empty; only RV32IM opcodes in the listings
3. rv32sim build
4. every demo program x 1 and 2 cores x feature settings: checksum must equal golden
5. every test program x 10 settings: must pass
6. C cache model in rv32sim = Python cache model, hit for hit, on recorded traces
7. every UART packet the simulated board sends = the Python golden data
8. 7-segment browser values = the counters
9. trace compare: identical runs match, a planted one-bit error is caught
10. fault injection: missing forwarding / write-through / squash makes every test image fail
11. dashboard host: a simulated run end to end
Exit status 0 only if everything passes.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path[:0] = [os.path.join(ROOT, "tools"), os.path.join(ROOT, "host")]
PY = sys.executable
TMP = tempfile.mkdtemp(prefix="spectra_")
fails = []


def check(name, ok, detail=""):
    print("  %-62s %s %s" % (name, "PASS" if ok else "FAIL", detail))
    if not ok:
        fails.append(name)


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT, **kw)


def sim(cfg, image="demo", extra=()):
    r = run([SIM, "-j", "-c", "%04x" % cfg, *extra, os.path.join(ROOT, "fw", "build", image)])
    try:
        return json.loads(r.stdout.splitlines()[0]), r
    except (ValueError, IndexError):
        return None, r


print("1. reference models")
for mod in ("mext_ref", "cache_model", "arbiter_ref"):
    r = run([PY, os.path.join("tools", mod + ".py")])
    check(mod + " self-test", r.returncode == 0 and "PASS" in r.stdout)
r = run([PY, os.path.join("host", "protocol.py")])
check("protocol self-test (round trip, corrupted packet dropped)", "PASS" in r.stdout)
r = run([PY, os.path.join("tools", "check_maps.py")])
check("PROTOCOL.md = spectra.h", r.returncode == 0, r.stdout.strip().splitlines()[-1] if r.stdout else r.stderr)

print("2. firmware")
r = run([PY, os.path.join("fw", "build.py")])
check("build all images (-Wall -Wextra -Werror, .data empty)", r.returncode == 0, r.stdout.splitlines()[0] if r.stdout else r.stderr[-300:])
if r.returncode:
    sys.exit("firmware build failed:\n" + r.stdout + r.stderr)
ALLOWED = set("lui auipc jal jalr beq bne blt bge bltu bgeu lb lh lw lbu lhu sb sh sw addi slti sltiu xori ori andi "
              "slli srli srai add sub sll slt sltu xor srl sra or and mul mulh mulhsu mulhu div divu rem remu "
              "li mv nop j jr ret not neg seqz snez sltz sgtz beqz bnez blez bgez bltz bgtz bgt ble bgtu bleu call tail la".split())
bad = set()
for img in os.listdir(os.path.join(ROOT, "fw", "build")):
    lst = os.path.join(ROOT, "fw", "build", img, img + ".lst")
    if os.path.exists(lst):
        for line in open(lst):
            p = line.split("\t")
            if len(p) >= 2 and line[:1] == " " and ":" in p[0]:
                # llvm-objdump: "addr: bytes<TAB>mnemonic<TAB>operands";
                # GNU objdump:  "addr:<TAB>encoding<TAB>mnemonic<TAB>operands"
                f = [x.strip() for x in p[1:] if x.strip()]
                if f and re.fullmatch(r"[0-9a-f]{4,8}", f[0]):
                    f = f[1:]
                if f:
                    bad |= {f[0].split()[0]} - ALLOWED
check("only RV32IM instructions in every image", not bad, " ".join(sorted(bad)))

print("3. simulator")
from simpath import find_sim  # noqa: E402
try:
    SIM = find_sim(rebuild=True)          # always rebuild from the current source when a compiler exists
    built = True
except RuntimeError as e:
    SIM, built = None, False
    print(e)
check("rv32sim ready (%s)" % (os.path.basename(SIM) if SIM else "none"), built)
if not built:
    sys.exit(1)

import golden  # noqa: E402
GOLD = golden.all_golden()
print("4. demo programs (checksum = golden)")
base = 0x0097
variants = {"all on": 0, "FWD off": 1, "DC off": 2, "IC off": 0x80, "L=5": 0x18, "L=10": -0x18}
for prog, pname in ((0, "gol"), (1, "mandel_halves"), (2, "mandel_interleaved"), (3, "matmul")):
    for dual in (0, 1):
        for vname, v in variants.items():
            if pname.startswith("mandel") and vname not in ("all on", "DC off", "FWD off"):
                continue
            cfg = (base & ~0x64) | prog << 5 | dual << 2
            cfg = cfg & ~v if v > 0 else cfg | -v
            if vname == "L=10":
                cfg |= 0x18
            j, r = sim(cfg)
            want = GOLD["GOLD_GOL" if prog == 0 else "GOLD_MATMUL" if prog == 3 else "GOLD_MANDEL"]
            ok = j is not None and j["checksum"] == want and j["leds"] & 3 == 3
            check("%-18s %d core%s %-13s 0x%04x" % (pname, dual + 1, "s" if dual else " ", vname, cfg), ok,
                  "" if ok else (r.stderr or r.stdout)[-200:])

print("5. test programs")
tcfgs = [0x0097, 0x0093, 0x0095, 0x0087, 0x008f, 0x009f, 0x0017, 0x0086, 0x0091, 0x0010]
for t in ("t_lock", "t_barrier", "t_mext", "t_hazard", "t_cache"):
    res = [sim(c, t)[0] for c in tcfgs]
    ok = all(x is not None and x["leds"] & 2 for x in res)
    check("%-10s x %d settings" % (t, len(tcfgs)), ok)

print("6. C cache model = Python cache model")
import cache_model  # noqa: E402
for cfg in (0x00f7, 0x00e7, 0x00ff, 0x0097, 0x0087, 0x0093, 0x00f3):
    mt = os.path.join(TMP, "mt.txt")
    j, _ = sim(cfg, extra=("-m", mt))
    py = cache_model.replay(mt, cfg)
    c = [[j["cores"][k]["dhit"], j["cores"][k]["dmiss"]] for k in range(2)]
    check("hits/misses identical, config 0x%04x" % cfg, py == c, "%s vs %s" % (c, py) if py != c else "")

print("7. streamed packets = golden data")
import protocol  # noqa: E402
frames, img, C = golden.gol_frames(), golden.mb_image(), golden.mm_result()
for cfg, name in ((0x0097, "Game of Life frames"), (0x00d7, "Mandelbrot rows"), (0x00f7, "MatMul rows")):
    ub = os.path.join(TMP, "u.bin")
    sim(cfg, extra=("-u", ub))
    pk = protocol.Parser().feed(open(ub, "rb").read())
    bad, n = 0, 0
    for x in pk:
        if x["type"] == "FRAME":
            ref = frames[x["gen"]]
            bits = bytes(sum(ref[i + b] << b for b in range(8)) for i in range(0, 4096, 8))
            bad += bits != x["bits"]
            n += 1
        elif x["type"] == "ROW":
            bad += x["data"] != img[x["row"] * 192:(x["row"] + 1) * 192]
            n += 1
        elif x["type"] == "MROW":
            bad += x["data"] != bytes(golden.mm_heat(v) for v in C[x["row"] * 32:(x["row"] + 1) * 32])
            n += 1
    st = [x for x in pk if x["type"] == "STATS"]
    check("%-20s %4d packets, 0 wrong, STATS present" % (name, n), bad == 0 and n > 0 and len(st) == 1)

print("8. 7-segment browser")
r = run([SIM, "-c", "00f7", "-b", "0,1,2,3,L,0,1,2,3,R,1", os.path.join(ROOT, "fw", "build", "demo")])
j, _ = sim(0x00f7)
lines = [ln.split() for ln in r.stdout.splitlines() if ln.startswith("browse")]
seg = [int(p[2].split("=")[1]) for p in lines]
c0, c1, cyc = j["cores"][0], j["cores"][1], j["cycles"]
want = [cyc // 1000, c0["dhit"], c0["dmiss"], c0["arbwait"],
        c0["arbwait"] * 10000 // cyc, cyc * 100 // c0["instret"], c0["dhit"] * 10000 // (c0["dhit"] + c0["dmiss"]),
        c0["ihit"] * 10000 // (c0["ihit"] + c0["imiss"]), c0["arbwait"] * 10000 // cyc,
        c1["arbwait"] * 10000 // cyc, c1["dhit"] * 10000 // (c1["dhit"] + c1["dmiss"])]
check("11 display states = counters", seg == want, "" if seg == want else "%s vs %s" % (seg, want))


import seg7_model  # noqa: E402


def shown(label, value, decimals, digits_left):
    """What a person reads: label (with "." after a core number), then the number right-aligned
    in the remaining digits, 2 decimals for rates (PROTOCOL.md section 4)."""
    num = str(value)
    if decimals:
        num = num.rjust(3, "0")
        num = num[:-2] + "." + num[-2:]
    body = "".join(ch for ch in num if ch != ".")
    pad = " " * (digits_left - len(body))
    return label + pad + num


def tour_items(cfg, j):
    """The tour of PROTOCOL.md section 4 from the run's counters: (display text, LEDS)."""
    cyc, dual = j["cycles"], (cfg >> 2) & 1
    ok = (j["leds"] >> 1) & 1
    led = lambda sel, rm, th, k: 1 | (ok << 1) | (1 << 10) | (rm << 11) | (th << 12) | (k << 13) | (sel << 14)  # noqa: E731
    out = [(shown("Cy", cyc // 1000, False, 6), led(0, 0, 1, 0))]
    core = lambda name, k: name + ("%d." % k if dual else "")  # noqa: E731
    free = lambda name: 8 - len(name) - (1 if dual else 0)    # noqa: E731
    for k in range(1 + dual):
        c = j["cores"][k]
        if (cfg >> 7) & 1:
            out.append((shown(core("IH", k), c["ihit"] * 10000 // (c["ihit"] + c["imiss"]), True, free("IH")), led(2, 1, 0, k)))
        if (cfg >> 1) & 1:
            out.append((shown(core("dH", k), c["dhit"] * 10000 // (c["dhit"] + c["dmiss"]), True, free("dH")), led(1, 1, 0, k)))
        out.append((shown(core("CPI", k), cyc * 100 // c["instret"], True, free("CPI")), led(0, 1, 0, k)))
    if dual:
        out += [(shown(core("Ar", k), j["cores"][k]["arbwait"] * 10000 // cyc, True, free("Ar")), led(3, 1, 0, k)) for k in (0, 1)]
    return out


for cfg in (0x00f7, 0x0073, 0x0093):
    j, _ = sim(cfg)
    items = tour_items(cfg, j)
    script = ",".join(["0"] + ["W"] * len(items) + ["U", "W"])
    r = run([SIM, "-c", "%04x" % cfg, "-b", script, os.path.join(ROOT, "fw", "build", "demo")])
    got = []
    for p in (ln.split() for ln in r.stdout.splitlines() if ln.startswith("browse")):
        f = dict(x.split("=") for x in p[2:])
        got.append((seg7_model.text(int(f["seg7"]), int(f["dp"], 16), int(f["txt"], 16)), int(f["leds"], 16)))
    want = items + [items[0]] + [items[0], items[1]]          # every item, back to the first; BTNU restarts
    check("tour 0x%04x: %d labelled items, 3 s each, loops, BTNU" % (cfg, len(items)), got == want,
          "  ".join(t for t, _ in got) if got == want else "%s vs %s" % (got, want))


print("9. trace compare")
ta, tb = os.path.join(TMP, "a"), os.path.join(TMP, "b")
sim(0x00f3, extra=("-t", ta))
sim(0x00f3, extra=("-t", tb))
r = run([PY, os.path.join("tools", "tracecmp.py"), ta + "0.txt", tb + "0.txt"])
check("identical runs match", r.returncode == 0, r.stdout.strip())
lines = open(tb + "0.txt").read().splitlines()
k = next(i for i, ln in enumerate(lines) if " st 1001800c " in ln and not ln.endswith(" 00000000"))
p = lines[k].split()
p[-1] = "%08x" % (int(p[-1], 16) ^ 1)
lines[k] = " ".join(p)
open(tb + "0.txt", "w").write("\n".join(lines) + "\n")
r = run([PY, os.path.join("tools", "tracecmp.py"), ta + "0.txt", tb + "0.txt"])
check("planted one-bit store error is caught", r.returncode == 1, r.stdout.strip().splitlines()[0])

print("10. fault injection: every test image must FAIL on a broken pipeline")
for fault in ("stale1", "stale2", "nosquash"):
    caught = []
    for t in ("t_hazard", "t_mext", "t_cache"):
        r = run([SIM, "-c", "0093", "-n", "50000000", "-F", fault, os.path.join(ROOT, "fw", "build", t)])
        caught.append(r.returncode != 0)
    what = {"stale1": "no forwarding", "stale2": "register file not write-through",
            "nosquash": "taken branch does not squash"}[fault]
    check("%-32s caught by %d of 3 images" % (what, sum(caught)), all(caught))

print("11. dashboard host")
r = run([PY, os.path.join("host", "spectra_host.py"), "--sim", "00f7", "--runs", os.path.join(TMP, "runs")])
check("simulated run through the host, checksum OK", r.returncode == 0, r.stdout.strip())

# fallback kit: the release's board recording, replayed and served with no board
rec = os.path.join(ROOT, "build", "releases", "fpga-v1", "board", "demo_uart.bin")
if os.path.exists(rec):
    import json as _json
    import socket
    import time
    import urllib.request
    fb = os.path.join(TMP, "runs_fallback")
    r = run([PY, os.path.join("host", "spectra_host.py"), "--replay", rec, "--source", "board", "--runs", fb])
    check("fallback: board recording replays (51 runs, 0 bytes dropped)", r.returncode == 0 and " 0 dropped, 51 run(s)" in r.stdout,
          r.stdout.strip().splitlines()[-1] if r.stdout.strip() else r.stderr[-200:])
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    host = subprocess.Popen([PY, os.path.join("host", "spectra_host.py"), "--runs", fb, "--http", str(port)], cwd=ROOT,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    runs, page = [], b""
    try:
        for _ in range(40):
            try:
                runs = _json.loads(urllib.request.urlopen("http://127.0.0.1:%d/api/runs" % port, timeout=2).read())["runs"]
                page = urllib.request.urlopen("http://127.0.0.1:%d/" % port, timeout=2).read()
                break
            except OSError:
                time.sleep(0.25)
    finally:
        host.terminate()
        host.wait()
    board = [x for x in runs if x["source"] == "board"]
    check("fallback: dashboard serves them offline (51 board runs, all golden)",
          len(board) == 51 and all(x["ok"] for x in board) and b"SPECTRA" in page, "%d board runs" % len(board))

print()
print("ALL PASS" if not fails else "%d FAILED: %s" % (len(fails), ", ".join(fails)))
sys.exit(1 if fails else 0)
