"""build_image.py - build the RV32I test image for the lab 5A core.

    python tb/lab5a/build_image.py

Assembles tb/lab5a/t_lab5a.S with the firmware toolchain (fw/build.py picks it) and writes
tb/lab5a/image/: t_lab5a.elf, t_lab5a.lst, imem.hex and dmem.hex. The hex files hold 1024
words each, the size of the lab's 4 KB instr_mem and data_mem, so $readmemh loads them
without warnings; rv32sim accepts the shorter files too.

Fails if the image uses anything the lab core does not decode (AUIPC, M extension, FENCE,
SYSTEM) or does not fit in 4 KB.
"""
import importlib.util
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(HERE, "image")
WORDS = 1024                     # lab 5A: 4 KB instruction and data memories

spec = importlib.util.spec_from_file_location("fwbuild", os.path.join(ROOT, "fw", "build.py"))
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)


def lab_supported(ins):
    """True if the unmodified lab 5A decoder implements this instruction."""
    op, f3, f7 = ins & 0x7F, (ins >> 12) & 7, ins >> 25
    if op in (0x37, 0x6F, 0x67, 0x63, 0x03, 0x23, 0x13):    # LUI JAL JALR BRANCH LOAD STORE OP-IMM
        return True
    if op == 0x33:                                           # OP: RV32I only, no M (funct7 = 1)
        return f7 == 0 or (f7 == 0x20 and f3 in (0, 5))
    return False                                             # AUIPC, FENCE, SYSTEM, ...


def main():
    name, cc, objdump = fw.toolchain(os.environ.get("SPECTRA_CC"))
    os.makedirs(OUT, exist_ok=True)
    elf = os.path.join(OUT, "t_lab5a.elf")
    src = os.path.join(HERE, "t_lab5a.S")
    r = fw.subprocess.run(cc + fw.CFLAGS + [src, "-o", elf], capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stdout + r.stderr + "\nbuild of t_lab5a failed")
    segs, secs = fw.read_elf(elf)
    imem, dmem = bytearray(WORDS * 4), bytearray(WORDS * 4)
    for addr, blob in segs:
        if addr + len(blob) <= len(imem):
            imem[addr:addr + len(blob)] = blob
        elif 0x10000000 <= addr and addr + len(blob) <= 0x10000000 + len(dmem):
            dmem[addr - 0x10000000:addr - 0x10000000 + len(blob)] = blob
        else:
            sys.exit("segment at 0x%08x (%d bytes) does not fit the lab's 4 KB memories" % (addr, len(blob)))
    text_addr, text_size, _ = secs[".text"]
    bad = []
    for a in range(text_addr, text_addr + text_size, 4):
        ins = struct.unpack_from("<I", imem, a)[0]
        if not lab_supported(ins):
            bad.append("0x%04x: %08x" % (a, ins))
    if bad:
        sys.exit("instructions the lab 5A core does not implement:\n  " + "\n  ".join(bad))
    fw.write_hex(os.path.join(OUT, "imem.hex"), imem, WORDS)
    fw.write_hex(os.path.join(OUT, "dmem.hex"), dmem, WORDS)
    if objdump:
        lst = fw.subprocess.run(objdump + ["-d", os.path.basename(elf)], cwd=os.path.dirname(elf) or ".",
                                capture_output=True, text=True).stdout
        open(os.path.join(OUT, "t_lab5a.lst"), "w", newline="\n").write(lst)
    print("toolchain: %s; t_lab5a: %d instructions, all RV32I without AUIPC -> %s"
          % (name, text_size // 4, os.path.relpath(OUT, ROOT)))


if __name__ == "__main__":
    main()
