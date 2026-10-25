"""run.py - result_streamer verification suite.

    python tb/streamer/run.py

Generates stimulus vectors into build/<commit>/streamer/vec/stim.mem, writes
stim.mem in the run directory for tb_result_streamer, invokes Vivado batch
simulation using sim/result_streamer.f, and requires PASS.
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))


def commit_dir():
    c = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True)
    d = subprocess.run(["git", "status", "--porcelain", "--untracked-files=no"], cwd=ROOT,
                       capture_output=True, text=True)
    return os.path.join(ROOT, "build", (c.stdout.strip() or "nogit") + ("-dirty" if d.stdout.strip() else ""))


def generate_stim(target_dirs):
    """
    Generates stim.mem matching the 4-column hex format expected by tb_result_streamer:
    op  a  b  c
    """
    stim_lines = [
        # op=6: ev_run_start
        "6 00000000 00000000 00000000",
        # op=2: wait 16 cycles
        "2 00000010 00000000 00000000",
        # op=1: snoop write (addr=0x1000, data=0x12345678, be=0xF)
        "1 00001000 12345678 0000000f",
        # op=2: wait 8 cycles
        "2 00000008 00000000 00000000",
        # op=4: ev_row_done (row=0, core=0)
        "4 00000000 00000000 00000000",
        # op=3: ev_gen_done (gen_word=0xdeadbeef)
        "3 deadbeef 00000000 00000000",
        # op=7: ev_checksum (checksum=0xc001cafe)
        "7 c001cafe 00000000 00000000",
        # op=8: wait for uart drain
        "8 00000000 00000000 00000000",
        # op=0: terminate simulation
        "0 00000000 00000000 00000000"
    ]
    content = "\n".join(stim_lines) + "\n"
    for d in target_dirs:
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "stim.mem"), "w", newline="\n") as f:
            f.write(content)


def main():
    out = os.path.join(commit_dir(), "streamer")
    vec = os.path.join(out, "vec")
    run = os.path.join(out, "xsim")

    # Generate stim.mem in the vector store and in the execution directory
    generate_stim([vec, run, ROOT])

    vivado = shutil.which("vivado") or shutil.which("vivado.bat")
    if not vivado:
        sys.exit("FAIL streamer: vivado not on PATH")

    r = subprocess.run([vivado, "-mode", "batch", "-nojournal", "-nolog", "-notrace", "-source", "scripts/sim.tcl",
                        "-tclargs", "-f", "sim/result_streamer.f", "-top", "tb_result_streamer",
                        "-hex", os.path.relpath(vec, ROOT).replace("\\", "/"), "-run", run.replace("\\", "/")],
                       cwd=ROOT, capture_output=True, text=True)

    log = open(os.path.join(run, "xsim.log")).read() if os.path.exists(os.path.join(run, "xsim.log")) else r.stdout
    shown = [ln for ln in log.splitlines() if ln.startswith(("PASS", "FAIL")) or ": got" in ln or "ERROR" in ln]
    print("\n".join(shown[:20]))

    if r.returncode or not any("PASS result_streamer" in ln for ln in shown):
        sys.exit("FAIL streamer")


if __name__ == "__main__":
    main()