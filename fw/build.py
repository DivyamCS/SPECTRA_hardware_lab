"""build.py - build every SPECTRA firmware image (Windows, macOS, Linux).

    python fw/build.py                 build all images into fw/build/<name>/
    python fw/build.py --cc zig        force a toolchain: gcc | clang | zig
    python fw/build.py --out DIR       write the images into DIR/<name>/ instead

Toolchain, first found wins (or --cc / env SPECTRA_CC):
  gcc   riscv-none-elf-gcc or riscv64-unknown-elf-gcc   (xPack on the lab PC)
  clang clang with the riscv32 target + ld.lld           (Linux)
  zig   python -m ziglang  (pip install ziglang==0.13.0)  (works everywhere, incl. macOS)

Each image directory gets: <name>.elf, imem.hex (4096 words), dmem.hex (8192 words),
<name>.lst (disassembly, when an objdump is available). The hex files are what Vivado
loads with $readmemh: one 32-bit word per line, lowest address first.
"""
import os
import shutil
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(HERE, "build")

COMMON = ["boot.S", "util.c", "display.c"]
IMAGES = {
    "demo": ["main.c", "gol.c", "mandel.c", "matmul.c", "maze.c"],   # maze mode behind SW15
    "t_lock": ["tests/t_lock.c"],
    "t_barrier": ["tests/t_barrier.c"],
    "t_mext": ["tests/t_mext.c"],
    "t_hazard": ["tests/t_hazard.c", "tests/t_hazard_asm.S"],
    "t_cache": ["tests/t_cache.c"],
}
IMEM_WORDS, DMEM_WORDS = 4096, 8192
CFLAGS = ["-O2", "-ffreestanding", "-nostdlib", "-fno-builtin", "-fno-pic", "-Wall", "-Wextra", "-Werror",
          "-I", HERE, "-T", os.path.join(HERE, "link.ld")]


def which(*names):
    for n in names:
        p = shutil.which(n)
        if p:
            return p
    return None


def toolchain(choice):
    if choice in (None, "gcc"):
        gcc = which("riscv-none-elf-gcc", "riscv64-unknown-elf-gcc", "riscv32-unknown-elf-gcc")
        if gcc:
            # Strip "gcc" (and ".exe" on Windows, where which() returns "...-gcc.EXE").
            stem, ext = os.path.splitext(gcc) if gcc.lower().endswith(".exe") else (gcc, "")
            od = stem[:-3] + "objdump" + ext
            od = od if os.path.exists(od) else which(os.path.basename(stem[:-3] + "objdump"))
            return ("gcc", [gcc, "-march=rv32im", "-mabi=ilp32", "-mno-relax", "-msmall-data-limit=0",
                            "-fno-tree-loop-distribute-patterns", "-nostartfiles"],
                    [od] if od else None)
        if choice == "gcc":
            sys.exit("riscv-none-elf-gcc not found on PATH")
    if choice in (None, "clang"):
        clang = which("clang")
        if clang and which("ld.lld"):
            cmd = [clang, "--target=riscv32-unknown-elf", "-march=rv32im", "-mabi=ilp32", "-mno-relax",
                   "-fuse-ld=lld"]
            probe = subprocess.run(cmd + ["-x", "c", "-c", "-o", os.devnull, "-"], input=b"int x;",
                                   capture_output=True)
            if probe.returncode == 0:
                od = which("llvm-objdump")
                return ("clang", cmd, [od, "--mattr=+m"] if od else None)
        if choice == "clang":
            sys.exit("clang with the riscv32 target and ld.lld not found")
    import importlib.util
    if importlib.util.find_spec("ziglang"):
        return ("zig", [sys.executable, "-m", "ziglang", "cc", "-target", "riscv32-freestanding-none",
                        "-mcpu=generic_rv32+m", "-mno-relax"], None)
    sys.exit("No RISC-V toolchain found. Install one of: the xPack riscv-none-elf-gcc, "
                 "or 'pip install ziglang==0.13.0'.")


def read_elf(path):
    """Return (segments, sections) of a little-endian ELF32 file."""
    data = open(path, "rb").read()
    assert data[:4] == b"\x7fELF" and data[4] == 1 and data[5] == 1, "not a little-endian ELF32"
    e_phoff, e_shoff = struct.unpack_from("<II", data, 28)
    e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHHHH", data, 42)
    segs = []
    for i in range(e_phnum):
        p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, _, _ = struct.unpack_from(
            "<IIIIIIII", data, e_phoff + i * e_phentsize)
        if p_type == 1 and p_filesz:
            segs.append((p_paddr, data[p_offset:p_offset + p_filesz]))
    shdrs = [struct.unpack_from("<IIIIIIIIII", data, e_shoff + i * e_shentsize) for i in range(e_shnum)]
    strtab = shdrs[e_shstrndx]
    names = data[strtab[4]:strtab[4] + strtab[5]]
    secs = {}
    for sh in shdrs:
        n = names[sh[0]:names.index(b"\0", sh[0])].decode()
        secs[n] = (sh[3], sh[5], sh[1])          # addr, size, type
    return segs, secs


def write_hex(path, mem, words):
    with open(path, "w", newline="\n") as f:
        for i in range(words):
            f.write("%08x\n" % struct.unpack_from("<I", mem, 4 * i)[0])


def make_hex(elf, outdir):
    segs, secs = read_elf(elf)
    for s in (".data", ".sdata"):
        if s in secs and secs[s][1]:
            sys.exit("%s: section %s is not empty; writable globals must start as zero (.bss) "
                     "because a soft reset does not reload BRAM" % (elf, s))
    imem, dmem = bytearray(IMEM_WORDS * 4), bytearray(DMEM_WORDS * 4)
    for addr, blob in segs:
        if addr + len(blob) <= len(imem):
            imem[addr:addr + len(blob)] = blob
        elif 0x10000000 <= addr and addr + len(blob) <= 0x10000000 + len(dmem):
            o = addr - 0x10000000
            dmem[o:o + len(blob)] = blob
        else:
            sys.exit("%s: segment at 0x%08x (%d bytes) is outside IMEM/DMEM" % (elf, addr, len(blob)))
    write_hex(os.path.join(outdir, "imem.hex"), imem, IMEM_WORDS)
    write_hex(os.path.join(outdir, "dmem.hex"), dmem, DMEM_WORDS)
    text = secs.get(".text", (0, 0, 0))[1]
    bss = secs.get(".bss", (0, 0, 0))[1]
    return text, bss


def main():
    global OUT
    if "--out" in sys.argv:
        OUT = os.path.abspath(sys.argv[sys.argv.index("--out") + 1])
    choice = os.environ.get("SPECTRA_CC")
    if "--cc" in sys.argv:
        choice = sys.argv[sys.argv.index("--cc") + 1]
    subprocess.run([sys.executable, os.path.join(ROOT, "tools", "golden.py"), "--header",
                    os.path.join(HERE, "golden.h")], check=True, stdout=subprocess.DEVNULL)
    name, cc, objdump = toolchain(choice)
    print("toolchain:", name)
    for img, srcs in IMAGES.items():
        d = os.path.join(OUT, img)
        os.makedirs(d, exist_ok=True)
        elf = os.path.join(d, img + ".elf")
        cmd = cc + CFLAGS + [os.path.join(HERE, s) for s in COMMON + srcs] + ["-o", elf]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stdout + r.stderr)
            sys.exit("build of %s failed" % img)
        text, bss = make_hex(elf, d)
        if objdump:
            # run in the ELF's folder: the listing names the file without the checkout's path
            lst = subprocess.run(objdump + ["-d", os.path.basename(elf)], cwd=os.path.dirname(elf) or ".",
                                 capture_output=True, text=True).stdout
            open(os.path.join(d, img + ".lst"), "w", newline="\n").write(lst)
        print("  %-10s text %5d B  bss %5d B  -> %s" % (img, text, bss, os.path.relpath(d, ROOT)))


if __name__ == "__main__":
    main()
