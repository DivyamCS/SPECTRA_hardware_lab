"""updatemem.py - put a program into a built FPGA design without re-implementing.

    python scripts/updatemem.py neutral FILE
        write the neutral instruction image used for synthesis (see below)
    python scripts/updatemem.py swap DCP IMAGE_DIR OUT_DIR [--expect DIR] [--flash]
        load IMAGE_DIR/imem.hex and dmem.hex into the block RAMs of the routed design DCP and
        write OUT_DIR/top_fpga.bit (+ top_fpga.ltx); --flash: the bitstream for booting from the
        board's QSPI flash (SPI x4, 33 MHz, compressed) and OUT_DIR/top_fpga.mcs (write_cfgmem,
        16 MB, for scripts/program_flash.tcl)

Why: imem has no write port, so Vivado treats it as a ROM and optimises it by its contents (the
demo image has instruction bits 0 and 1 equal in every word, and Vivado stored that column once).
A bitstream built that way cannot take every program, and its RAM layout depends on the image.
So synthesis sees a neutral image instead - pseudo-random words, every bit column distinct and
none constant, so nothing can be folded - and every real program, the demo included, goes in
through this script.

swap:
  1. Vivado dumps every RAMB36 of u_imem / u_dmem: ram_addr / ram_slice, port width, INIT_00-7F,
     INITP_00-0F;
  2. coverage: every bit 0-31 of every address of each memory is held by exactly one RAM lane;
  3. with --expect DIR, the dumped contents must decode to DIR/imem.hex / dmem.hex (the images the
     design was synthesised with): this checks the bit mapping against Vivado's own placement of
     a known image, independently of this script's encoder;
  4. new INIT / INITP values are computed and applied, the contents dumped again and decoded:
     they must equal IMAGE_DIR exactly; then write_bitstream.
Bit mapping (7-series RAMB36, data bits only): a port of width 1, 2, 4, 9, 18 or 36 holds 1, 2,
4, 8, 16 or 32 data bits per address; data bit j of address a is bit a * d + j of the 32,768-bit
INIT space (INIT_xx = bits 256 * xx ... 256 * xx + 255, written most significant first). Parity
bits (INITP) are not used by these memories; they are set to 0 and checked to stay 0.
Prints PASS updatemem or FAIL updatemem: <reason>.
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEPTH = {"u_imem": 4096, "u_dmem": 32768}
DATA_BITS = {1: 1, 2: 2, 4: 4, 9: 8, 18: 16, 36: 32}

DUMP_TCL = r"""
proc dump {f} {
    foreach c [get_cells -hier -filter {REF_NAME =~ RAMB* && (NAME =~ *u_imem/* || NAME =~ *u_dmem/*)}] {
        puts $f "CELL $c [get_property REF_NAME $c] [get_property ram_addr_begin $c] [get_property ram_addr_end $c] [get_property ram_slice_begin $c] [get_property ram_slice_end $c] [get_property READ_WIDTH_A $c]"
        for {set i 0} {$i < 128} {incr i} { puts $f "INIT [format %02X $i] [get_property [format INIT_%02X $i] $c]" }
        for {set i 0} {$i < 16} {incr i} { puts $f "INITP [format %02X $i] [get_property [format INITP_%02X $i] $c]" }
    }
}
"""


def neutral_words():
    out, x = [], 0x9E3779B97F4A7C15
    for _ in range(DEPTH["u_imem"]):
        x = (x + 0x9E3779B97F4A7C15) & (2 ** 64 - 1)
        z = x
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & (2 ** 64 - 1)
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & (2 ** 64 - 1)
        out.append((z ^ (z >> 31)) & 0xFFFFFFFF)
    cols = [tuple((w >> b) & 1 for w in out) for b in range(32)]
    assert len(set(cols)) == 32 and all(0 < sum(c) < len(out) for c in cols), "neutral image not neutral"
    return out


def read_hex(path, depth):
    words = [int(t, 16) for t in open(path).read().split() if not t.startswith("@")]
    if len(words) > depth:
        raise ValueError("%s has %d words, memory holds %d" % (path, len(words), depth))
    return words + [0] * (depth - len(words))


def parse_dump(path):
    cells, cur = [], None
    for ln in open(path):
        p = ln.split()
        if not p:
            continue
        if p[0] == "CELL":
            cur = {"name": p[1], "ref": p[2], "a0": int(p[3]), "a1": int(p[4]), "s0": int(p[5]), "s1": int(p[6]),
                   "w": int(p[7]), "init": {}, "initp": {}}
            cur["mem"] = "u_imem" if "/u_imem/" in cur["name"] else "u_dmem"
            cells.append(cur)
        elif p[0] in ("INIT", "INITP"):
            v = p[2].split("'h", 1)[1]
            cur["init" if p[0] == "INIT" else "initp"][int(p[1], 16)] = int(v, 16)
    return cells


def check_coverage(cells):
    for mem, depth in DEPTH.items():
        owner = {}
        for c in (c for c in cells if c["mem"] == mem):
            if c["ref"] != "RAMB36E1":
                raise ValueError("%s is %s (only RAMB36E1 handled)" % (c["name"], c["ref"]))
            d = DATA_BITS[c["w"]]
            if c["s1"] - c["s0"] + 1 != d:
                raise ValueError("%s: slice %d-%d but %d data bits per address" % (c["name"], c["s0"], c["s1"], d))
            for b in range(c["s0"], c["s1"] + 1):
                key = (b, c["a0"], c["a1"])
                if key in owner:
                    raise ValueError("%s bit %d held twice" % (mem, b))
                owner[key] = c["name"]
        for b in range(32):
            spans = sorted((k[1], k[2]) for k in owner if k[0] == b)
            pos = 0
            for a0, a1 in spans:
                if a0 != pos:
                    raise ValueError("%s bit %d: addresses %d-%d not held by any RAM" % (mem, b, pos, a0 - 1))
                pos = a1 + 1
            if pos != depth:
                raise ValueError("%s bit %d: addresses %d-%d not held by any RAM (Vivado merged or removed "
                                 "this bit column?)" % (mem, b, pos, depth - 1))


def decode(cells, mem):
    words = [0] * DEPTH[mem]
    for c in (c for c in cells if c["mem"] == mem):
        d = DATA_BITS[c["w"]]
        bits = 0
        for i in range(128):
            bits |= c["init"][i] << (256 * i)
        for a in range(c["a0"], c["a1"] + 1):
            v = (bits >> ((a - c["a0"]) * d)) & ((1 << d) - 1)
            words[a] |= v << c["s0"]
        if any(c["initp"].values()):
            raise ValueError("%s: parity INIT bits set" % c["name"])
    return words


def encode(c, words):
    d = DATA_BITS[c["w"]]
    bits = 0
    for a in range(c["a0"], c["a1"] + 1):
        bits |= ((words[a] >> c["s0"]) & ((1 << d) - 1)) << ((a - c["a0"]) * d)
    return {i: (bits >> (256 * i)) & (2 ** 256 - 1) for i in range(128)}


def vivado():
    v = shutil.which("vivado") or shutil.which("vivado.bat")
    if not v:
        sys.exit("FAIL updatemem: vivado not on PATH")
    return v


def run_tcl(script, workdir):
    workdir = os.path.abspath(workdir)
    path = os.path.join(workdir, "updatemem_run.tcl")
    open(path, "w", newline="\n").write(script)
    r = subprocess.run([vivado(), "-mode", "batch", "-nojournal", "-nolog", "-notrace", "-source", tclpath(path)],
                       cwd=workdir, capture_output=True, text=True)
    open(os.path.join(workdir, "updatemem_vivado.log"), "w", newline="\n").write(r.stdout + r.stderr)
    if r.returncode:
        sys.exit("FAIL updatemem: Vivado failed (%s)" % os.path.join(workdir, "updatemem_vivado.log"))


def tclpath(p):
    return os.path.abspath(p).replace("\\", "/")


FLASH_PART = "s25fl128sxxxxxx0-spi-x1_x2_x4"     # Nexys A7-100T: Spansion S25FL128S, 16 MB QSPI
FLASH_PROPS = [("BITSTREAM.CONFIG.SPI_BUSWIDTH", "4"), ("BITSTREAM.CONFIG.CONFIGRATE", "33"),
               ("BITSTREAM.GENERAL.COMPRESS", "TRUE")]


def swap(dcp, image, out, expect, flash=False):
    os.makedirs(out, exist_ok=True)
    new = {"u_imem": read_hex(os.path.join(image, "imem.hex"), DEPTH["u_imem"]),
           "u_dmem": read_hex(os.path.join(image, "dmem.hex"), DEPTH["u_dmem"])}
    d1 = os.path.join(out, "ram_before.txt")
    run_tcl(DUMP_TCL + "open_checkpoint {%s}\nset f [open {%s} w]\ndump $f\nclose $f\n" % (tclpath(dcp), tclpath(d1)), out)
    cells = parse_dump(d1)
    check_coverage(cells)
    if expect:
        for mem, f in (("u_imem", "imem.hex"), ("u_dmem", "dmem.hex")):
            want = read_hex(os.path.join(expect, f), DEPTH[mem])
            got = decode(cells, mem)
            if got != want:
                a = next(i for i in range(len(want)) if got[i] != want[i])
                sys.exit("FAIL updatemem: %s in the design differs from %s at word %d (0x%08x vs 0x%08x): bit "
                         "mapping wrong" % (mem, os.path.join(expect, f), a, got[a], want[a]))
        print("ok   mapping: the design's contents decode to %s exactly (imem, dmem)" % expect)
    lines = [DUMP_TCL, "open_checkpoint {%s}" % tclpath(dcp)]
    for c in cells:
        for i, v in encode(c, new[c["mem"]]).items():
            lines.append("set_property INIT_%02X 256'h%064X [get_cells {%s}]" % (i, v, c["name"]))
        for i in range(16):
            lines.append("set_property INITP_%02X 256'h%064X [get_cells {%s}]" % (i, 0, c["name"]))
    d2 = os.path.join(out, "ram_after.txt")
    lines += ["set f [open {%s} w]" % tclpath(d2), "dump $f", "close $f"]
    if flash:                                     # boot from the board's QSPI flash: x4 at 33 MHz, compressed
        lines += ["set_property %s %s [current_design]" % kv for kv in FLASH_PROPS]
    lines += ["write_bitstream -force {%s}" % tclpath(os.path.join(out, "top_fpga.bit")),
              "catch { write_debug_probes -force {%s} }" % tclpath(os.path.join(out, "top_fpga.ltx"))]
    if flash:
        lines += ["write_cfgmem -force -format mcs -size 16 -interface SPIx4 -loadbit {up 0x00000000 %s} "
                  "-file {%s}" % (tclpath(os.path.join(out, "top_fpga.bit")), tclpath(os.path.join(out, "top_fpga.mcs")))]
    run_tcl("\n".join(lines) + "\n", out)
    after = parse_dump(d2)
    check_coverage(after)
    for mem in DEPTH:
        if decode(after, mem) != new[mem]:
            sys.exit("FAIL updatemem: %s read back from the design differs from %s" % (mem, image))
    print("ok   read back: imem and dmem in the design = %s exactly" % image)
    if flash and not os.path.exists(os.path.join(out, "top_fpga.mcs")):
        sys.exit("FAIL updatemem: no flash image written (see %s)" % os.path.join(out, "updatemem_vivado.log"))
    print("PASS updatemem: %s -> %s" % (image, os.path.join(out, "top_fpga.mcs" if flash else "top_fpga.bit")))


def main():
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == "neutral":
        with open(a[1], "w", newline="\n") as f:
            f.write("".join("%08x\n" % w for w in neutral_words()))
        print("neutral imem image: %s" % a[1])
    elif len(a) >= 4 and a[0] == "swap":
        flash = "--flash" in a
        if flash:
            a.remove("--flash")
        expect = a[5] if len(a) == 6 and a[4] == "--expect" else None
        if len(a) not in (4, 6) or (len(a) == 6 and not expect):
            sys.exit(__doc__)
        try:
            swap(a[1], a[2], a[3], expect, flash)
        except ValueError as e:
            sys.exit("FAIL updatemem: %s" % e)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
