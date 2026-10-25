"""gen_vectors.py - MUL/DIV testbench vectors from the RISC-V reference (mext_ref.py).

    python tools/gen_vectors.py OUTDIR        writes OUTDIR/mul_vectors.mem, OUTDIR/div_vectors.mem

Each line: FUNCT3 A B EXPECTED, all hex, for $readmemh or $fscanf in tb_mul_unit / tb_div_unit.
MUL file: funct3 0-3 (MUL, MULH, MULHSU, MULHU). DIV file: funct3 4-7 (DIV, DIVU, REM, REMU).
Every edge-case pair first, then 10,000 random pairs per file (seeded, so files never change).
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mext_ref  # noqa: E402
from golden import MEXT_EDGE  # noqa: E402


def lines(names, rng, n):
    out = []
    pairs = [(a, b) for a in MEXT_EDGE for b in MEXT_EDGE]
    for _ in range(n):
        a = rng.getrandbits(32)
        b = rng.getrandbits(32) >> rng.randrange(32)     # small and large operands, some zero
        pairs.append((a, b))
    for a, b in pairs:
        for nm in names:
            out.append("%x %08x %08x %08x" % (mext_ref.FUNCT3[nm], a, b, mext_ref.OPS[nm](a, b)))
    return out


def main(outdir):
    os.makedirs(outdir, exist_ok=True)
    rng = random.Random(20261016)
    for fname, names in (("mul_vectors.mem", ["mul", "mulh", "mulhsu", "mulhu"]),
                         ("div_vectors.mem", ["div", "divu", "rem", "remu"])):
        ls = lines(names, rng, 10000)
        with open(os.path.join(outdir, fname), "w", newline="\n") as f:
            f.write("\n".join(ls) + "\n")
        print("%s: %d vectors" % (fname, len(ls)))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "vectors")
