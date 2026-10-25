"""tracecmp.py - compare two commit traces (RTL testbench vs rv32sim), one hart each.

    python tools/tracecmp.py rtl_trace0.txt sim_trace0.txt

Trace format (one retired instruction per line, docs/PROTOCOL.md section 8):
    PC INSTR [xN=VALUE] [ld ADDR | st ADDR DATA]
Values loaded from registers that depend on timing (CYCLES, counters, SWITCHES, BUTTONS,
LOCK) are not compared. Comparison stops at the first read of CYCLES or SWITCHES: the firmware
reads CYCLES only in finish(), after RUN_STOP and the CHECKSUM write, and then computes with it
(SEG7 = cycles / 1000), so later values depend on timing (spec v1.1); SWITCHES starts the browser.
Programs that spin on LOCK (t_lock with two cores) legitimately differ in loop counts:
check those by checksum, not by trace.
Exit status 0 = identical, 1 = first difference printed.
"""
import sys

TIMING_REGS = {0x20000010, 0x20000034, 0x20000038, 0x2000003C, 0x20000044} | set(range(0x20000050, 0x20000090, 4))


def parse(line):
    p = line.split()
    rec = {"pc": p[0], "ins": p[1], "rd": None, "ld": None, "st": None}
    i = 2
    while i < len(p):
        if p[i].startswith("x"):
            rec["rd"] = p[i]
            i += 1
        elif p[i] == "ld":
            rec["ld"] = int(p[i + 1], 16)
            i += 2
        elif p[i] == "st":
            rec["st"] = (p[i + 1], p[i + 2])
            i += 3
        else:
            raise ValueError("bad trace token %r" % p[i])
    return rec


def same(a, b):
    if (a["pc"], a["ins"], a["ld"], a["st"]) != (b["pc"], b["ins"], b["ld"], b["st"]):
        return False
    if a["ld"] in TIMING_REGS:
        return (a["rd"] or "").split("=")[0] == (b["rd"] or "").split("=")[0]
    return a["rd"] == b["rd"]


def compare(fa, fb):
    n = 0
    with open(fa) as A, open(fb) as B:
        for la, lb in zip(A, B):
            n += 1
            ra, rb = parse(la), parse(lb)
            if not same(ra, rb):
                print("first difference at instruction %d:\n  %s  %s" % (n, la.rstrip(), lb.rstrip()))
                return 1
            if ra["ld"] in (0x20000034, 0x20000038):
                break
    print("traces match: %d instructions" % n)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(compare(sys.argv[1], sys.argv[2]))
