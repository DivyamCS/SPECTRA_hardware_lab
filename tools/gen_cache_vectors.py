"""gen_cache_vectors.py - D-cache testbench vectors from tools/cache_model.py.

    python tools/gen_cache_vectors.py OUTDIR      write the vector files
    python tools/gen_cache_vectors.py --check     self-test (regenerate in memory, re-check)

Four files OUTDIR/dcache_s<K>.mem (K = 0..3, four random seeds; write-back / write-allocate, PLRU,
all four ways), 2,000 random accesses each, seeded so the files never change. Every latency L is
covered by four cycle columns. Line format (for $fscanf):

    op addr wdata be  rdata hit victim dirty  c5 c6 c8 c10

  op      0 = load, 1 = store                          (decimal)
  addr    byte address, aligned to the access size     (hex, 8 digits)
  wdata   store data already in its byte lanes         (hex; 0 for loads)
  be      byte enables                                 (hex digit)
  rdata   loads: the whole aligned word expected       (hex; 0 for stores)
  hit     1 = hit, 0 = miss                            (decimal)
  victim  way filled on a miss, 4 = no fill (hit)
  dirty   1 = the filled way held a dirty line (written back first)
  cN      cycles the core sees for L = N (IF-A rule 3): hit 2, miss 2 + (L + 4),
          dirty miss 2 + 2(L + 4)

Memory starts as all zeros (dmem_bram without an init file). Addresses use 8 sets x 8 tags in
0x1000_0000-0x1001_FFFF so lines conflict and get evicted often.
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cache_model import Cache  # noqa: E402

SEEDS = (1000, 1001, 1003, 1007)
LATS = (5, 6, 8, 10)
N = 2000


def cycles(kind, L):
    return {"hit": 2, "miss": 2 + L + 4, "miss_dirty": 2 + 2 * (L + 4)}[kind]


def generate(seed):
    rng = random.Random(seed)
    c = Cache()
    mem = {}
    sets = rng.sample(range(64), 8)
    tags = rng.sample(range(0x10000000 >> 10, 0x10020000 >> 10), 8)
    out = []
    for _ in range(N):
        store = rng.random() < 0.4
        size = rng.choice((1, 2, 4, 4))
        addr = (rng.choice(tags) << 10) | (rng.choice(sets) << 4) | (rng.randrange(16) & ~(size - 1))
        word = addr & ~3
        lane = addr & 3
        be = ((1 << size) - 1) << lane
        s, t = (addr >> 4) % 64, addr >> 10
        hit_way = next((w for w in range(4) if c.tag[s][w] == t), None)
        victim = 4
        if hit_way is None:
            victim = c._victim(s)
        res = c.access(addr, store)
        old = mem.get(word, 0)
        if store:
            val = rng.getrandbits(8 * size)
            wdata = (val << (8 * lane)) & 0xFFFFFFFF
            bmask = int.from_bytes(bytes(0xFF if (be >> i) & 1 else 0 for i in range(4)), "little")
            mem[word] = (old & ~bmask) | (wdata & bmask)
            rdata = 0
        else:
            wdata, rdata = 0, old
        out.append("%d %08x %08x %x %08x %d %d %d %s" % (
            int(store), addr, wdata, be, rdata, int(res == "hit"), victim, int(res == "miss_dirty"),
            " ".join(str(cycles(res, L)) for L in LATS)))
    return out


def all_files():
    files = {}
    for k, seed in enumerate(SEEDS):
        files["dcache_s%d.mem" % k] = generate(seed)
    return files


def self_test(outdir=None):
    files = all_files()
    for name, lines in files.items():
        c = Cache()
        mem = {}
        for ln in lines:
            op, addr, wdata, be, rdata, hit, victim, dirty, *cyc = ln.split()
            addr, wdata, be, rdata = int(addr, 16), int(wdata, 16), int(be, 16), int(rdata, 16)
            res = c.access(addr, op == "1")
            assert int(hit) == (res == "hit") and int(dirty) == (res == "miss_dirty"), (name, ln)
            assert victim == "4" or 0 <= int(victim) < 4, (name, ln)
            if op == "0":
                assert rdata == mem.get(addr & ~3, 0), (name, ln)
            else:
                bm = int.from_bytes(bytes(0xFF if (be >> i) & 1 else 0 for i in range(4)), "little")
                mem[addr & ~3] = (mem.get(addr & ~3, 0) & ~bm) | (wdata & bm)
        if outdir:
            with open(os.path.join(outdir, name)) as f:
                assert f.read().splitlines() == lines, name + " differs from a fresh generation"
    return True


if __name__ == "__main__":
    if sys.argv[1:] == ["--check"]:
        d = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tb", "vectors")
        print("gen_cache_vectors self-test:", "PASS" if self_test(d if os.path.exists(
            os.path.join(d, "dcache_s0.mem")) else None) else "FAIL")
    elif len(sys.argv) == 2:
        os.makedirs(sys.argv[1], exist_ok=True)
        for name, lines in all_files().items():
            with open(os.path.join(sys.argv[1], name), "w", newline="\n") as f:
                f.write("\n".join(lines) + "\n")
        print("wrote %d files x %d accesses to %s" % (len(SEEDS), N, sys.argv[1]))
    else:
        sys.exit(__doc__)
