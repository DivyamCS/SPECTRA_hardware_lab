"""gen_decoder_vectors.py - decoder testbench vectors.

    python tools/gen_decoder_vectors.py OUTDIR     write OUTDIR/decoder_vectors.mem
    python tools/gen_decoder_vectors.py --check    self-test

Instruction words come from three sources:
  1. the GNU assembler (the firmware toolchain): every one of the 45 RV32IM instructions SPECTRA
     supports (37 RV32I without FENCE/ECALL/EBREAK, + 8 M), 12 variants each with random
     registers and immediates, so the encodings are genuine, not written by this script;
  2. illegal encodings: FENCE, ECALL, EBREAK, CSR instructions, compressed words, reserved
     funct3/funct7 values, all-zero and all-one words;
  3. 10,000 seeded random words (half of them with a valid opcode field).
The expected fields come from ref_decode() below, written from the RISC-V unprivileged spec
independently of rtl/core/decoder.v. One line per word, hex fields, in this order:

  instr rs1 rs2 rd uses_rs1 uses_rs2 writes_rd imm alu_op use_imm is_lui is_auipc is_jal
  is_jalr is_branch br_cond is_load is_store mem_size load_unsigned is_md md_op illegal

(for an illegal word every control field is 0; rs1/rs2/rd/br_cond/mem_size/load_unsigned/md_op
are the raw instruction bit fields in all cases).
"""
import importlib.util
import os
import random
import struct
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ALU = {"ADD": 0, "SUB": 1, "SLL": 2, "SLT": 3, "SLTU": 4, "XOR": 5, "SRL": 6, "SRA": 7, "OR": 8, "AND": 9,
       "PASS_B": 10}
FIELDS = ["instr", "rs1", "rs2", "rd", "uses_rs1", "uses_rs2", "writes_rd", "imm", "alu_op", "use_imm",
          "is_lui", "is_auipc", "is_jal", "is_jalr", "is_branch", "br_cond", "is_load", "is_store",
          "mem_size", "load_unsigned", "is_md", "md_op", "illegal"]


def sx(v, bits):
    return (v - (1 << bits)) & 0xFFFFFFFF if v >> (bits - 1) & 1 else v


def ref_decode(w):
    """Expected decoder outputs, from the RISC-V spec (RV32IM, no FENCE/SYSTEM)."""
    op, f3, f7 = w & 0x7F, (w >> 12) & 7, w >> 25
    d = dict.fromkeys(FIELDS, 0)
    d.update(instr=w, rs1=(w >> 15) & 31, rs2=(w >> 20) & 31, rd=(w >> 7) & 31, br_cond=f3,
             mem_size=f3 & 3, load_unsigned=f3 >> 2, md_op=f3)
    i_imm = sx(w >> 20, 12)
    s_imm = sx(((w >> 25) << 5) | ((w >> 7) & 31), 12)
    b_imm = sx((((w >> 31) & 1) << 12) | (((w >> 7) & 1) << 11) | (((w >> 25) & 63) << 5) | (((w >> 8) & 15) << 1), 13)
    u_imm = w & 0xFFFFF000
    j_imm = sx((((w >> 31) & 1) << 20) | (((w >> 12) & 255) << 12) | (((w >> 20) & 1) << 11) | (((w >> 21) & 1023) << 1), 21)
    ok = True
    if op == 0x37:
        d.update(is_lui=1, writes_rd=1, imm=u_imm, alu_op=ALU["PASS_B"], use_imm=1)
    elif op == 0x17:
        d.update(is_auipc=1, writes_rd=1, imm=u_imm)
    elif op == 0x6F:
        d.update(is_jal=1, writes_rd=1, imm=j_imm)
    elif op == 0x67 and f3 == 0:
        d.update(is_jalr=1, writes_rd=1, uses_rs1=1, imm=i_imm)
    elif op == 0x63 and f3 not in (2, 3):
        d.update(is_branch=1, uses_rs1=1, uses_rs2=1, imm=b_imm)
    elif op == 0x03 and f3 in (0, 1, 2, 4, 5):
        d.update(is_load=1, writes_rd=1, uses_rs1=1, imm=i_imm)
    elif op == 0x23 and f3 in (0, 1, 2):
        d.update(is_store=1, uses_rs1=1, uses_rs2=1, imm=s_imm)
    elif op == 0x13:
        names = {0: "ADD", 2: "SLT", 3: "SLTU", 4: "XOR", 6: "OR", 7: "AND"}
        if f3 in names:
            alu = names[f3]
        elif f3 == 1 and f7 == 0:
            alu = "SLL"
        elif f3 == 5 and f7 in (0, 0x20):
            alu = "SRL" if f7 == 0 else "SRA"
        else:
            ok = False
        if ok:
            d.update(uses_rs1=1, writes_rd=1, use_imm=1, imm=i_imm, alu_op=ALU[alu])
    elif op == 0x33:
        if f7 == 1:
            d.update(uses_rs1=1, uses_rs2=1, writes_rd=1, is_md=1)
        elif f7 == 0:
            alu = ["ADD", "SLL", "SLT", "SLTU", "XOR", "SRL", "OR", "AND"][f3]
            d.update(uses_rs1=1, uses_rs2=1, writes_rd=1, alu_op=ALU[alu])
        elif f7 == 0x20 and f3 in (0, 5):
            d.update(uses_rs1=1, uses_rs2=1, writes_rd=1, alu_op=ALU["SUB" if f3 == 0 else "SRA"])
        else:
            ok = False
    else:
        ok = False
    if not ok:
        d["illegal"] = 1
    return d


REGS = ["zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1"] + ["a%d" % i for i in range(8)] + \
       ["s%d" % i for i in range(2, 12)] + ["t3", "t4", "t5", "t6"]


def asm_source(rng):
    r = lambda: rng.choice(REGS)  # noqa: E731
    lines = []
    for _ in range(12):
        i12, sh, u20 = rng.randrange(-2048, 2048), rng.randrange(32), rng.randrange(1 << 20)
        lines += ["lui %s, %d" % (r(), u20), "auipc %s, %d" % (r(), u20),
                  "jal %s, .+%d" % (r(), 2 * rng.randrange(-200, 200)),
                  "jalr %s, %d(%s)" % (r(), i12, r())]
        for b in ("beq", "bne", "blt", "bge", "bltu", "bgeu"):
            lines.append("%s %s, %s, .+%d" % (b, r(), r(), 2 * rng.randrange(-1000, 1000)))
        for ld in ("lb", "lh", "lw", "lbu", "lhu"):
            lines.append("%s %s, %d(%s)" % (ld, r(), i12, r()))
        for st in ("sb", "sh", "sw"):
            lines.append("%s %s, %d(%s)" % (st, r(), i12, r()))
        for ii in ("addi", "slti", "sltiu", "xori", "ori", "andi"):
            lines.append("%s %s, %s, %d" % (ii, r(), r(), i12))
        for si in ("slli", "srli", "srai"):
            lines.append("%s %s, %s, %d" % (si, r(), r(), sh))
        for rr in ("add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and",
                   "mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"):
            lines.append("%s %s, %s, %s" % (rr, r(), r(), r()))
    return "\n".join("    .option norvc\n    .text" .split("\n") + lines) + "\n"


ILLEGAL = [0x0000000F, 0x0FF0000F, 0x00000073, 0x00100073, 0x30200073, 0x34011073, 0xC00022F3, 0x00002073,
           0x00000000, 0xFFFFFFFF, 0x00010001, 0x45014501, 0x00003003, 0x0000E003, 0x0000F003, 0x00003023,
           0x00007023, 0x00001067, 0x00002063, 0x00003063, 0x40001013, 0x02001013, 0x20005013, 0x40002033,
           0x02000033 | (0x10 << 25), 0x7E000033, 0x0000005B, 0x0000007F, 0x00000057, 0x0000002F]


def assembled_words(rng):
    spec = importlib.util.spec_from_file_location("fwbuild", os.path.join(ROOT, "fw", "build.py"))
    fw = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fw)
    name, cc, _ = fw.toolchain(os.environ.get("SPECTRA_CC"))
    tmp = tempfile.mkdtemp()
    src, elf = os.path.join(tmp, "all.S"), os.path.join(tmp, "all.elf")
    open(src, "w").write(asm_source(rng))
    r = subprocess.run(cc + ["-nostdlib", "-nostartfiles", "-Wl,-Ttext=0", "-Wl,-e,0", src, "-o", elf],
                       capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stdout + r.stderr)
    segs, _ = fw.read_elf(elf)
    blob = b"".join(b for _, b in sorted(segs))
    return [struct.unpack_from("<I", blob, i)[0] for i in range(0, len(blob) - 3, 4)]


def all_words():
    rng = random.Random(40)
    words = assembled_words(rng) + ILLEGAL
    valid_ops = [0x37, 0x17, 0x6F, 0x67, 0x63, 0x03, 0x23, 0x13, 0x33]
    for k in range(10000):
        w = rng.getrandbits(32)
        if k % 2:
            w = (w & ~0x7F) | rng.choice(valid_ops)
        words.append(w)
    return words


def line(d):
    return " ".join("%x" % d[f] for f in FIELDS)


def self_test(outdir=None):
    words = all_words()
    assert len(words) >= 12 * 45 + 10000
    asm = words[:12 * 45]
    assert all(not ref_decode(w)["illegal"] for w in asm), "assembler produced a word the model calls illegal"
    assert all(ref_decode(w)["illegal"] for w in ILLEGAL), "an ILLEGAL word decodes as legal"
    # spot checks against hand-encoded instructions from the spec
    assert ref_decode(0x00500093)["imm"] == 5 and ref_decode(0x00500093)["rd"] == 1        # addi x1, x0, 5
    assert ref_decode(0x02B50533)["is_md"] == 1 and ref_decode(0x02B50533)["md_op"] == 0   # mul a0, a0, a1
    assert ref_decode(0x00000517)["is_auipc"] == 1                                       # auipc a0, 0
    assert ref_decode(0xFE000EE3)["imm"] == 0xFFFFFFFC        # beq x0, x0, -4 (GNU objdump agrees)
    if outdir:
        with open(os.path.join(outdir, "decoder_vectors.mem")) as f:
            assert f.read().splitlines() == [line(ref_decode(w)) for w in words], "file differs from a fresh run"
    return True


if __name__ == "__main__":
    if sys.argv[1:] == ["--check"]:
        d = os.path.join(ROOT, "tb", "vectors")
        print("gen_decoder_vectors self-test:", "PASS" if self_test(
            d if os.path.exists(os.path.join(d, "decoder_vectors.mem")) else None) else "FAIL")
    elif len(sys.argv) == 2:
        words = all_words()
        with open(os.path.join(sys.argv[1], "decoder_vectors.mem"), "w", newline="\n") as f:
            f.write("\n".join(line(ref_decode(w)) for w in words) + "\n")
        print("wrote decoder_vectors.mem: %d words (%d assembled, %d illegal, 10000 random)"
              % (len(words), len(words) - len(ILLEGAL) - 10000, len(ILLEGAL)))
    else:
        sys.exit(__doc__)
