"""run.py - cycles C1-C30 of the MatMul inner loop, RTL against a pipeline model.

    python tb/timing/run.py [N] [--write]

The MatMul inner loop is 8 instructions at 0xAD4 (docs/results/matmul_loop.md); it is checked
against a pipeline model built from the documented rules.

1. rv32sim -c 00f3 (MatMul, FWD, DC write-back PLRU, IC, L = 8, one core): the executed
   instruction stream (-t) and the data-access trace (-m) of the demo image;
2. tb_core_dc with TIMING_DUMP (sim/core_dc_timing.f): from C1 = the N-th time (default 5) inside
   the run that 0xAD4 has just entered ID with a bubble in EX (right after the taken bne), 30
   rows of ID / EX / MEM-WB contents and freeze, ex_hold, squash, interlock, ic_wait, dport_wait;
3. the model below predicts the same 30 rows from that starting point, using only the documented
   rules: hazard_unit's equations; nothing moves under a freeze, MEM/WB advances with a bubble
   under ex_hold, else everything moves; D-cache from tools/cache_model.py on the data trace:
   2 cycles in MEM/WB on a hit, 2 + (L + 4) on a miss, 2 + 2(L + 4) on a dirty miss; MUL 3
   cycles in EX from its first unfrozen cycle; a taken branch squashes ID and the fetch in
   flight, leaving ID empty for one cycle (ic_wait -> freeze) before the target arrives; I-cache
   hits deliver the next instruction to ID the cycle after ID gives one up; fetch is sequential,
   so the word after a taken branch (pc + 4) sits in ID until the squash drops it.
PASS = every field of every row equal. --write writes docs/results/timing_diagram.md.
"""
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from cache_model import Cache  # noqa: E402
import simpath  # noqa: E402

CFG, L = "00f3", 8
FIELDS = ["ID", "EX", "MEM/WB", "freeze", "ex_hold", "squash", "interlock", "ic_wait", "dport_wait"]


def commit_dir():
    c = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True)
    d = subprocess.run(["git", "status", "--porcelain", "--untracked-files=no"], cwd=ROOT,
                       capture_output=True, text=True)
    return os.path.join(ROOT, "build", (c.stdout.strip() or "nogit") + ("-dirty" if d.stdout.strip() else ""))


def is_dmem(a):
    return 0x10000000 <= a < 0x10020000


def model(executed, results, acc_index, r0, rows=30):
    """executed: list of dicts (pc, ins, mem address or None); returns 30 rows of FIELDS."""
    def instr(i):
        e = executed[i]
        op, f7 = e["ins"] & 0x7F, e["ins"] >> 25
        lat = 1
        if e["mem"] is not None and is_dmem(e["mem"]):
            r = results[acc_index[i]]
            lat = 2 if r == "hit" else (2 + L + 4 if r == "miss" else 2 + 2 * (L + 4))
        elif e["mem"] is not None:
            lat = 2                                            # MMIO
        taken = op in (0x63, 0x6F, 0x67) and i + 1 < len(executed) and executed[i + 1]["pc"] != e["pc"] + 4
        return {"i": i, "pc": e["pc"], "mem": e["mem"] is not None, "lat": lat,
                "mul": op == 0x33 and f7 == 1 and ((e["ins"] >> 12) & 7) < 4, "taken": taken,
                "el": 0, "start": None}

    def fetch_after(cur):
        # sequential fetch: the next executed instruction if it is at pc + 4, else the
        # wrong-path word at pc + 4 (after a taken branch; squashed while the branch is in EX)
        i = cur["i"]
        if i is not None and i + 1 < len(executed) and executed[i + 1]["pc"] == cur["pc"] + 4:
            return instr(i + 1)
        return {"i": None, "pc": cur["pc"] + 4, "mem": False, "lat": 1, "mul": False, "taken": False,
                "el": 0, "start": None}

    MW, EX, ID = instr(r0), None, instr(r0 + 1)
    nxt, pending = r0 + 2, None                                # next fetch; (index, cycle) after a squash
    out = []
    for t in range(1, rows + 1):
        dport_wait = MW is not None and MW["mem"] and MW["el"] < MW["lat"] - 1
        ic_wait = ID is None
        freeze = dport_wait or ic_wait
        md_busy = EX is not None and EX["mul"] and (EX["start"] is None or t < EX["start"] + 2)
        ex_hold = md_busy and not freeze
        squash = EX is not None and EX["taken"] and not freeze and not ex_hold
        out.append(["%x" % ID["pc"] if ID else "-", "%x" % EX["pc"] if EX else "-",
                    "%x" % MW["pc"] if MW else "-", int(freeze), int(ex_hold), int(squash), 0,
                    int(ic_wait), int(dport_wait)])
        if EX is not None and EX["mul"] and EX["start"] is None and not freeze:
            EX["start"] = t
        if freeze:
            if MW is not None:
                MW["el"] += 1
        elif ex_hold:
            MW = None
        else:
            MW = EX
            if MW is not None:
                MW["el"] = 0
            if squash:
                # ID and the fetch in flight are dropped; the target (the next executed
                # instruction after the branch, now in MEM/WB) reaches ID two cycles later
                EX, ID = None, None
                pending = (MW["i"] + 1, t + 2)
                nxt = MW["i"] + 2
            else:
                EX, ID = ID, fetch_after(ID)
        if ID is None and pending is not None and pending[1] <= t + 1:
            ID, pending = instr(pending[0]), None
    return out


LOOP = ["lw", "add", "lw", "mul", "addi", "add", "sw", "bne"]


def find_loop(lst):
    """The MatMul inner loop (docs/results/matmul_loop.md): in matmul_run, the backward bne whose
    body is exactly LOOP. Its address moves when the firmware changes, so it is found, not fixed."""
    code, inside = [], False
    for ln in open(lst):
        if "<matmul_run>:" in ln:
            inside = True
            continue
        if inside and ln.strip().endswith(">:"):
            break
        m = re.match(r"\s*([0-9a-f]+):\s+[0-9a-f]{8}\s+(\S+)\s*(.*)", ln)
        if inside and m:
            code.append((int(m.group(1), 16), m.group(2), m.group(3)))
    for i, (pc, op, args) in enumerate(code):
        t = re.search(r",([0-9a-f]+)\s*<", args)
        if op == "bne" and t and int(t.group(1), 16) == pc - 4 * (len(LOOP) - 1):
            body = [o for _, o, _ in code[i - len(LOOP) + 1:i + 1]]
            if body == LOOP:
                return pc - 4 * (len(LOOP) - 1)
    sys.exit("FAIL timing: the MatMul inner loop (%s) not found in %s" % (" ".join(LOOP), lst))


def main():
    n = 5
    args = [a for a in sys.argv[1:] if a != "--write"]
    if args:
        n = int(args[0])
    out = os.path.join(commit_dir(), "timing")
    vec = os.path.join(out, "vec")
    os.makedirs(vec, exist_ok=True)              # rewritten in place, nothing deleted
    src = os.path.join(ROOT, "fw", "build", "demo")
    for f in ("imem.hex", "dmem.hex"):
        shutil.copy(os.path.join(src, f), vec)
    open(os.path.join(vec, "cfg.mem"), "w").write(CFG + "\n")
    loop = find_loop(os.path.join(src, "demo.lst"))
    open(os.path.join(vec, "tdump.mem"), "w").write("%08x\n%08x\n" % (n, loop))
    open(os.path.join(vec, "maxcyc.mem"), "w").write("%08x\n" % 4000000)
    prefix, mtr = os.path.join(out, "sim"), os.path.join(out, "mem.txt")
    subprocess.run([simpath.find_sim(), "-c", CFG, "-t", prefix, "-m", mtr, src], cwd=ROOT, capture_output=True)
    vivado = shutil.which("vivado") or shutil.which("vivado.bat")
    run = os.path.join(out, "xsim")
    r = subprocess.run([vivado, "-mode", "batch", "-nojournal", "-nolog", "-notrace", "-source", "scripts/sim.tcl",
                        "-tclargs", "-f", "sim/core_dc_timing.f", "-top", "tb_core_dc",
                        "-hex", os.path.relpath(vec, ROOT).replace("\\", "/"), "-run", run.replace("\\", "/")],
                       cwd=ROOT, capture_output=True, text=True)
    tfile = os.path.join(run, "timing_rtl.txt")
    if r.returncode or not os.path.exists(tfile):
        sys.exit("FAIL timing: RTL run failed or no dump: " + r.stdout[-400:])
    lines = open(tfile).read().split("\n")
    r0 = int(lines[0].split()[1])
    rtl = []
    for ln in lines[1:31]:
        v = ln.split()
        pcs = ["%x" % int(v[j + 1], 16) if v[j] == "1" else "-" for j in (1, 3, 5)]
        rtl.append(pcs + [int(x) for x in v[7:13]])
    # executed stream and D-cache results
    executed, acc_index, k = [], {}, 0
    for i, ln in enumerate(open(prefix + "0.txt")):
        p = ln.split()
        mem = None
        if "ld" in p:
            mem = int(p[p.index("ld") + 1], 16)
        if "st" in p:
            mem = int(p[p.index("st") + 1], 16)
        executed.append({"pc": int(p[0], 16), "ins": int(p[1], 16), "mem": mem})
        if mem is not None and is_dmem(mem):
            acc_index[i] = k
            k += 1
    c = Cache()
    results = [c.access(int(q[2], 16), q[1] == "W") for q in (ln.split() for ln in open(mtr)) if len(q) == 3]
    if len(results) != k:
        sys.exit("FAIL timing: %d data accesses in the trace, %d in the memory trace" % (k, len(results)))
    mod = model(executed, results, acc_index, r0)
    bad = [t for t in range(30) if [str(x) for x in mod[t]] != [str(x) for x in rtl[t]]]
    hdr = "| C | " + " | ".join(FIELDS) + " |"
    sep = "| --- " * (len(FIELDS) + 1) + "|"
    table = [hdr, sep] + ["| C%d | %s |" % (t + 1, " | ".join(str(x) for x in rtl[t])) for t in range(30)]
    print("\n".join(table))
    if bad:
        for t in bad[:5]:
            print("C%d: RTL %s, model %s" % (t + 1, rtl[t], mod[t]))
        sys.exit("FAIL timing: %d of 30 rows differ" % len(bad))
    win = [results[acc_index[i]] for i in range(r0, r0 + 24) if i in acc_index]
    nmiss = sum(1 for x in win[:6] if x != "hit")
    print("PASS timing: C1-C30 (instructions %d..) RTL = pipeline model, every field; %d of the window's "
          "first 6 data accesses miss" % (r0 + 1, nmiss))
    if "--write" in sys.argv:
        accs = [(executed[i]["pc"], results[acc_index[i]]) for i in range(r0, r0 + 40) if i in acc_index]
        doc = ["# MatMul inner-loop timing, C1-C30", "",
               "RTL (tb_core_dc with TIMING_DUMP, CONFIG 0x00F3: FWD, D-cache write-back PLRU, I-cache, L = 8,",
               "one core) against a pipeline model built from the documented rules (tb/timing/run.py). C1 =",
               "the %d-th time inside the run that the loop's first instruction 0xAD4 has just entered ID" % n,
               "with a bubble in EX (after the taken bne).", "",
               "Result: all 30 rows equal, every field. PC in hex, - = empty stage (bubble).", ""] + table + [
               "", "D-cache results of the accesses in the window (cache_model.py, = the RTL's pulses): " +
               ", ".join("0x%x %s" % a for a in accs[:12]), ""]
        open(os.path.join(ROOT, "docs", "results", "timing_diagram.md"), "w", newline="\n").write("\n".join(doc))
        print("wrote docs/results/timing_diagram.md")


if __name__ == "__main__":
    main()
