"""fpga_build.py - build the FPGA top and check it.

    python scripts/fpga_build.py [--check-only DIR]

Runs scripts/build.tcl for top_fpga (sim/fpga.f, rtl/board/nexys_a7.xdc) with the neutral
instruction image of scripts/updatemem.py (so synthesis cannot optimise the ROM by a program's
contents), saves Vivado's output as build.log in the output directory
(build/<commit>/impl/top_fpga), keeps that bitstream as top_fpga_neutral.bit, and loads the demo
image with updatemem.py into top_fpga.bit (bit mapping checked against the synthesised images,
contents read back). Then checks:
  * updatemem.log: PASS;
  * timing: WNS >= 0 and WHS >= 0 (summary.txt);
  * resources: every entry of scripts/fpga_budget.txt (LUT, FF, BRAM, DSP; "max" or "exact");
  * the log: no critical warning, no error, and none of the warnings in FORBIDDEN (a memory whose
    board read-during-write result can differ from simulation, latches, multiple drivers, ...);
    plain warnings from files of generated Xilinx IP (build .../ip/, the VIO) are not ours;
  * drc.rpt: no REQP-1839 / REQP-1840 (block RAM control driven by an asynchronously reset
    register: a reset edge can corrupt a write);
  * timing_summary.rpt: every check_timing count 0 (registers without a clock, unconstrained
    endpoints and ports, combinational loops, ...);
  * cdc.rpt: no critical clock-domain crossing outside the JTAG debug hub (every pin through a
    2-flop synchroniser with no logic before it);
  * drc.rpt: no DRC error.
--check-only DIR re-checks an existing output directory (needs DIR/build.log).
Prints one line per check and PASS fpga_build or FAIL fpga_build; exit status 0 / 1.
"""
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
IMAGE = "fw/build/demo"                  # the program in the bitstream
FORBIDDEN = {
    "Synth 8-6430": "block RAM read/write collision: board result can differ from simulation",
    "Synth 8-327": "latch inferred",
    "Synth 8-3352": "multi-driven net",
    "Synth 8-6859": "multi-driven net",
    "Synth 8-5559": "multi-driven net",
    "Synth 8-87": "always block with an incomplete sensitivity list",
    "Synth 8-3848": "net without a driver",
    "Synth 8-3295": "port tied to a constant (undriven input)",
    "DRC 23-20": "DRC rule violation",
}


def commit_dir():
    c = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True)
    d = subprocess.run(["git", "status", "--porcelain", "--untracked-files=no"], cwd=ROOT,
                       capture_output=True, text=True)
    return os.path.join(ROOT, "build", (c.stdout.strip() or "nogit") + ("-dirty" if d.stdout.strip() else ""))


def budgets():
    out = []
    for ln in open(os.path.join(HERE, "fpga_budget.txt")):
        ln = ln.split("#", 1)[0].split()
        if ln:
            out.append((ln[0], ln[1], float(ln[2])))
    return out


def check(out):
    probs, lines = [], []
    summ = dict(ln.strip().split("=", 1) for ln in open(os.path.join(out, "summary.txt")) if "=" in ln)
    wns, whs = summ.get("WNS", "?"), summ.get("WHS", "?")
    ok = summ.get("timing") == "met"
    lines.append("%s timing: WNS %s ns, WHS %s ns" % ("ok  " if ok else "FAIL", wns, whs))
    probs += [] if ok else ["timing"]
    for key, kind, lim in budgets():
        v = float(summ.get(key, "nan"))
        ok = (v <= lim) if kind == "max" else (v == lim)
        lines.append("%s %s %g (%s %g)" % ("ok  " if ok else "FAIL", key, v, "<=" if kind == "max" else "=", lim))
        probs += [] if ok else [key]
    log = open(os.path.join(out, "build.log"), errors="replace").read()
    found = {}
    for m in re.finditer(r"^(CRITICAL WARNING|WARNING|ERROR): \[([^\]]+)\] (.*)$", log, re.M):
        sev, mid, text = m.groups()
        if sev == "WARNING" and "/ip/" in text.replace("\\", "/"):
            continue                       # inside generated Xilinx IP (the VIO): not our RTL
        if sev != "WARNING" or mid in FORBIDDEN:
            found.setdefault((sev, mid), []).append(text[:110])
    for (sev, mid), texts in sorted(found.items()):
        lines.append("FAIL %s [%s] x%d: %s (%s)" % (sev, mid, len(texts), FORBIDDEN.get(mid, "not allowed"), texts[0]))
        probs.append(mid)
    if not found:
        lines.append("ok   log: no critical warning, no error, none of %d forbidden warnings" % len(FORBIDDEN))
    drc = open(os.path.join(out, "drc.rpt"), errors="replace").read()
    errs = len(re.findall(r"^\| \S+ +\| (?:Error|Critical Warning) ", drc, re.M))
    ram = sum(int(n) for n in re.findall(r"^\| REQP-18(?:39|40) +\| \S+ +\| [^|]*\| (\d+)", drc, re.M))
    lines.append("%s drc.rpt: %d errors, %d block RAM async-control warnings" % (
        "ok  " if errs == 0 and ram == 0 else "FAIL", errs, ram))
    probs += [] if errs == 0 and ram == 0 else ["drc"]
    ts = open(os.path.join(out, "timing_summary.rpt"), errors="replace").read()
    nonzero = [m.group(0).strip() for m in re.finditer(r"There are (\d+) [^\n]*", ts) if int(m.group(1))]
    unc = [int(n) for n in re.findall(r"checking unconstrained_internal_endpoints \((\d+)\)", ts)]
    ok = not nonzero and not any(unc)
    lines.append("%s timing_summary.rpt: every check_timing item 0 (unclocked registers, unconstrained "
                 "paths and ports, combinational loops)%s" % ("ok  " if ok else "FAIL", "" if ok else ": " + "; ".join(nonzero[:3])))
    probs += [] if ok else ["check_timing"]
    cdc = open(os.path.join(out, "cdc.rpt"), errors="replace").read() if os.path.exists(os.path.join(out, "cdc.rpt")) else None
    if cdc is None:
        lines.append("FAIL cdc.rpt missing")
        probs.append("cdc")
    else:
        crit = [ln.split() for ln in cdc.splitlines() if re.match(r"^\s*\d+\s+CDC-\d+\s+Critical\s", ln)]
        ours = [c for c in crit if not all("dbg_hub" in f for f in c[-2:])]
        lines.append("%s cdc.rpt: %d critical crossings in our logic (%d inside the debug hub)%s" % (
            "ok  " if not ours else "FAIL", len(ours), len(crit) - len(ours),
            "" if not ours else ": " + ", ".join("%s %s -> %s" % (c[1], c[-2], c[-1]) for c in ours[:3])))
        probs += [] if not ours else ["cdc"]
    return probs, lines


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--check-only":
        out = os.path.abspath(sys.argv[2])
    else:
        out = os.path.join(commit_dir(), "impl", "top_fpga")
        os.makedirs(out, exist_ok=True)
        vivado = shutil.which("vivado") or shutil.which("vivado.bat")
        if not vivado:
            sys.exit("FAIL fpga_build: vivado not on PATH")
        # synthesis sees the neutral instruction image (scripts/updatemem.py), never a program
        stage = os.path.join(out, "synth_image")
        os.makedirs(stage, exist_ok=True)
        subprocess.run([sys.executable, os.path.join(HERE, "updatemem.py"), "neutral", os.path.join(stage, "imem.hex")],
                       check=True, capture_output=True)
        shutil.copy(os.path.join(ROOT, IMAGE, "dmem.hex"), stage)
        with open(os.path.join(out, "build.log"), "w", newline="\n") as lg:
            subprocess.run([vivado, "-mode", "batch", "-nojournal", "-nolog", "-notrace", "-source", "scripts/build.tcl",
                            "-tclargs", "-f", "sim/fpga.f", "-top", "top_fpga", "-xdc", "rtl/board/nexys_a7.xdc",
                            "-hex", os.path.relpath(stage, ROOT).replace("\\", "/"),
                            "-out", os.path.relpath(out, ROOT).replace("\\", "/")],
                           cwd=ROOT, stdout=lg, stderr=subprocess.STDOUT, text=True)
        if os.path.exists(os.path.join(out, "top_fpga.bit")):
            os.replace(os.path.join(out, "top_fpga.bit"), os.path.join(out, "top_fpga_neutral.bit"))
            r = subprocess.run([sys.executable, os.path.join(HERE, "updatemem.py"), "swap",
                                os.path.join(out, "post_route.dcp"), os.path.join(ROOT, IMAGE), out, "--expect", stage],
                               capture_output=True, text=True)
            open(os.path.join(out, "updatemem.log"), "w", newline="\n").write(r.stdout + r.stderr)
    if not os.path.exists(os.path.join(out, "summary.txt")):
        sys.exit("FAIL fpga_build: no summary.txt in %s (see build.log)" % out)
    probs, lines = check(out)
    um = os.path.join(out, "updatemem.log")
    um_ok = os.path.exists(um) and "PASS updatemem" in open(um).read()
    lines.append("%s program: %s loaded by scripts/updatemem.py and read back exactly (%s)" % (
        "ok  " if um_ok else "FAIL", IMAGE, "top_fpga.bit" if um_ok else um))
    probs += [] if um_ok else ["updatemem"]
    print("\n".join(lines))
    if probs:
        sys.exit("FAIL fpga_build: %s (%s)" % (", ".join(probs), out))
    print("PASS fpga_build (%s)" % out)


if __name__ == "__main__":
    main()
