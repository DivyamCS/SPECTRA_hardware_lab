"""preflight.py - is this computer ready for SPECTRA work?

    python scripts/preflight.py            human-readable report
    python scripts/preflight.py --json     the same as JSON
    python scripts/preflight.py --board    also ask Vivado which FPGA is on the cable (about 30 s)

Each check prints OK, WARN or FAIL and, when not OK, the exact fix.
Exit status: 0 = ready, 1 = something FAILs.
"""
import json
import os
import platform
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
results = []


def add(name, status, detail, fix=""):
    results.append({"check": name, "status": status, "detail": detail, "fix": fix})


def run(cmd, timeout=60):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout + r.stderr).strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return -1, str(e)


def first_line(s):
    return s.splitlines()[0] if s else ""


# ---- machine ----
osname = platform.system()
add("operating system", "OK" if osname in ("Windows", "Linux") else "FAIL", "%s %s, %s" % (osname, platform.release(), platform.machine()),
    "Vivado runs only on Windows or Linux (x86-64). Use the lab PC or another Windows/Linux computer as the linked machine.")
free_gb = shutil.disk_usage(ROOT).free / 2**30
add("free disk", "OK" if free_gb >= 40 else "WARN", "%.0f GB free on the project drive" % free_gb,
    "Vivado builds need about 10 GB per run directory; free at least 40 GB.")
bad_path = " " in ROOT or "onedrive" in ROOT.lower()
add("project path", "FAIL" if bad_path else "OK", ROOT,
    "Move the repo to C:\\fpga\\spectra: no spaces, not inside OneDrive.")
if osname == "Windows":
    code, out = run(["reg", "query", r"HKLM\SYSTEM\CurrentControlSet\Control\FileSystem", "/v", "LongPathsEnabled"])
    on = "0x1" in out
    add("Windows long paths", "OK" if on else "WARN", "enabled" if on else "disabled",
        "PowerShell as Administrator: Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\FileSystem' -Name LongPathsEnabled -Value 1, then reboot.")

# ---- tools ----
add("python", "OK" if sys.version_info >= (3, 11) else ("WARN" if sys.version_info >= (3, 9) else "FAIL"), sys.version.split()[0], "Install Python 3.11+ and tick 'Add to PATH'.")
try:
    import serial.tools.list_ports as lp
    ports = [p.device + " (" + (p.description or "") + ")" for p in lp.comports()]
    add("pyserial", "OK", "installed")
    ftdi = [p for p in ports if "USB Serial" in p or "FTDI" in p or "usbserial" in p.lower()]
    add("board serial port", "OK" if ftdi else "WARN", ", ".join(ports) or "no serial ports",
        "Plug the Nexys A7 into the PROG/UART micro-USB port and switch it on; it appears as 'USB Serial Port (COMn)'.")
except ImportError:
    add("pyserial", "FAIL", "missing", "python -m pip install pyserial")
code, out = run(["git", "--version"])
add("git", "OK" if code == 0 else "FAIL", first_line(out), "Install Git for Windows (it also provides bash).")
if code == 0:
    # Repo-local identity is enough: the global config is never changed.
    _, name = run(["git", "-C", ROOT, "config", "user.name"])
    add("git identity", "OK" if name else "WARN", name or "not set", 'inside the repo: git config user.name "SPECTRA local" and user.email')
viv = shutil.which("vivado") or shutil.which("vivado.bat")
if viv:
    # Vivado 2025.2's "-version" prints the version but exits non-zero, so judge by the output.
    code, out = run([viv, "-version"], timeout=120)
    ok = first_line(out).lower().startswith("vivado v")
    add("vivado", "OK" if ok else "FAIL", first_line(out), "Reinstall Vivado ML Standard with Artix-7 and cable drivers.")
else:
    add("vivado", "FAIL", "not on PATH", "Add C:\\Xilinx\\Vivado\\<version>\\bin to PATH, then open a new terminal.")
gcc = shutil.which("riscv-none-elf-gcc") or shutil.which("riscv64-unknown-elf-gcc")
try:
    import importlib.util
    zig = importlib.util.find_spec("ziglang") is not None
except Exception:
    zig = False
add("RISC-V toolchain", "OK" if (gcc or zig) else "FAIL", gcc or ("ziglang (pip)" if zig else "none"),
    "Install the xPack riscv-none-elf-gcc, or: python -m pip install ziglang==0.13.0")
cc = shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")
add("C compiler for rv32sim", "OK" if (cc or zig) else "FAIL", cc or ("zig" if zig else "none"),
    "Install a C compiler (gcc / clang), or: python -m pip install ziglang==0.13.0")

# ---- repository files ----
need = ["fw/build.py", "sim/rv32sim.c", "host/spectra_host.py", "tests/run_all.py", "docs/PROTOCOL.md"]
missing = [n for n in need if not os.path.exists(os.path.join(ROOT, n))]
add("SPECTRA files", "OK" if not missing else "FAIL", "complete" if not missing else "missing " + ", ".join(missing),
    "Clone the whole repository.")
lab = [f for f in ("pipe.v", "IF_ID.v", "execute.v", "memory.v", "wb.v", "opcode.vh", "top_fpga.v", "constraint.xdc")
       if not any(os.path.exists(os.path.join(ROOT, d, f)) for d in ("rtl/lab5a", "rtl/core", "rtl", "lab5a"))]
add("lab 5A files", "OK" if not lab else "WARN", "found" if not lab else "not found: " + ", ".join(lab),
    "Copy the lab 5A files into rtl/core/.")

# ---- board through Vivado ----
if "--board" in sys.argv and viv:
    tcl = os.path.join(ROOT, "build", "hwcheck.tcl")
    os.makedirs(os.path.dirname(tcl), exist_ok=True)
    with open(tcl, "w") as f:
        f.write("open_hw_manager\nconnect_hw_server\nopen_hw_target\nputs \"DEVICES: [get_hw_devices]\"\n"
                "close_hw_target\ndisconnect_hw_server\n")
    code, out = run([viv, "-mode", "batch", "-nojournal", "-nolog", "-source", tcl], timeout=300)
    dev = [ln for ln in out.splitlines() if ln.startswith("DEVICES:")]
    ok = bool(dev) and "xc7a" in dev[0]
    add("board on JTAG", "OK" if ok else "FAIL", dev[0] if dev else first_line(out),
        "Board on and connected; JP1 on JTAG; cable drivers installed with Vivado.")

failed = any(r["status"] == "FAIL" for r in results)
if "--json" in sys.argv:
    print(json.dumps({"ready": not failed, "checks": results}, indent=1))
else:
    for r in results:
        print("%-5s %-24s %s" % (r["status"], r["check"], r["detail"]))
        if r["status"] != "OK" and r["fix"]:
            print("      fix: " + r["fix"])
    print("\nREADY" if not failed else "\nNOT READY: fix every FAIL above, then run again")
sys.exit(1 if failed else 0)
