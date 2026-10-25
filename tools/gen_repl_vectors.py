"""gen_repl_vectors.py - PLRU and FIFO testbench vectors from tools/cache_model.py.

    python tools/gen_repl_vectors.py OUTDIR      write plru_vectors.mem (the FIFO is checked by tb/tb_fifo.v)
    python tools/gen_repl_vectors.py --check     self-test

10,000 seeded random operations per policy, in 8 sections of 1,250 with way masks 0000, 0001,
0011, 0111, 1010, 0110, 1000, 1101 (each section starts with a reset). The replacement modules
only see full sets (dcache handles "lowest invalid way first"), so the model here has every way
valid and only the policy decides. Line format (decimal):

    kind set way mask victim

  kind 2 = reset; `mask` is the way mask from now on (set, way, victim = 0)
  kind 0 = hit of `way` in `set` (PLRU: update; FIFO: no change); victim = 0
  kind 1 = fill in `set`: the module's victim must equal `victim`, then that way is filled
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cache_model import Cache  # noqa: E402

MASKS = (0b0000, 0b0001, 0b0011, 0b0111, 0b1010, 0b0110, 0b1000, 0b1101)
PER = 1250


def full_cache(fifo, mask):
    c = Cache(fifo=fifo, way_mask=mask)
    c.tag = [[-1] * 4 for _ in range(64)]          # every way valid: only the policy picks
    return c


def fill(c, s):
    w = c._victim(s)
    c._touch(s, w)
    if c.fifo:
        n = (w + 1) & 3
        while n not in c.allowed:
            n = (n + 1) & 3
        c.ptr[s] = n
    return w


def generate(fifo, seed):
    rng = random.Random(seed)
    out = []
    for mask in MASKS:
        c = full_cache(fifo, mask)
        out.append("2 0 0 %d 0" % mask)
        sets = rng.sample(range(64), 4)             # few sets, so state builds up
        for _ in range(PER - 1):
            s = rng.choice(sets)
            if rng.random() < 0.5:
                w = rng.choice(c.allowed)
                if not fifo:
                    c._touch(s, w)
                out.append("0 %d %d %d 0" % (s, w, mask))
            else:
                out.append("1 %d 0 %d %d" % (s, mask, fill(c, s)))
    return out


class SpecPolicy:
    """Second, independent implementation written from PROTOCOL.md section 6 (not cache_model)."""

    def __init__(self, fifo, mask):
        self.fifo, self.en = fifo, [((mask or 15) >> w) & 1 == 1 for w in range(4)]
        self.b = [[0, 0, 0] for _ in range(64)]
        self.p = [0] * 64

    def touch(self, s, w):                     # bits point away from w
        b = self.b[s]
        if w < 2:
            b[0], b[1] = 1, 1 - w              # b1 = the other way of 0-1
        else:
            b[0], b[2] = 0, 3 - w              # b2 = 0 -> way 2, 1 -> way 3; away from w

    def victim(self, s):
        if self.fifo:
            w = self.p[s]
            while not self.en[w]:
                w = (w + 1) % 4
            return w
        b = self.b[s]
        right = b[0]
        if right and not (self.en[2] or self.en[3]):
            right = 0
        if not right and not (self.en[0] or self.en[1]):
            right = 1
        w = 2 + b[2] if right else b[1]
        return w if self.en[w] else w ^ 1

    def filled(self, s, w):
        if self.fifo:
            n = (w + 1) % 4
            while not self.en[n]:
                n = (n + 1) % 4
            self.p[s] = n
        else:
            self.touch(s, w)


def self_test(outdir=None):
    for fifo, name in ((False, "plru_vectors.mem"),):
        lines = generate(fifo, 19 + fifo)
        assert len(lines) == 10000
        fills = 0
        for ln in lines:
            kind, s, w, mask, v = map(int, ln.split())
            if kind == 2:
                m = SpecPolicy(fifo, mask)
            elif kind == 0:
                assert m.en[w], ln
                if not fifo:
                    m.touch(s, w)
            else:
                assert m.victim(s) == v and m.en[v], ln
                m.filled(s, v)
                fills += 1
        assert fills > 4000
        if outdir:
            with open(os.path.join(outdir, name)) as f:
                assert f.read().splitlines() == lines, name + " differs from a fresh generation"
    return True


if __name__ == "__main__":
    if sys.argv[1:] == ["--check"]:
        d = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tb", "vectors")
        print("gen_repl_vectors self-test:", "PASS" if self_test(
            d if os.path.exists(os.path.join(d, "plru_vectors.mem")) else None) else "FAIL")
    elif len(sys.argv) == 2:
        os.makedirs(sys.argv[1], exist_ok=True)
        for fifo, name in ((False, "plru_vectors.mem"),):
            with open(os.path.join(sys.argv[1], name), "w", newline="\n") as f:
                f.write("\n".join(generate(fifo, 19 + fifo)) + "\n")
        print("wrote plru_vectors.mem (10,000 operations) to", sys.argv[1])
    else:
        sys.exit(__doc__)
