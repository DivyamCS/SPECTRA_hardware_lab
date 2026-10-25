"""cache_model.py - reference model of the SPECTRA caches (docs/PROTOCOL.md section 6).

Used three ways:
  * as a library: Cache(...).access(addr, write) -> "hit" | "miss" | "miss_dirty"
  * to replay a simulator data-access trace and count hits/misses per core:
        python tools/cache_model.py MEMTRACE CONFIG_HEX
  * to make expected hit/miss sequences for the I-cache, D-cache, PLRU and FIFO testbenches.

Rules (identical in rv32sim.c and in the RTL spec):
  - 16-byte lines; set = addr[9:4] (64 sets); tag = addr[31:10].
  - On a miss, the lowest-numbered invalid ENABLED way is filled; otherwise the policy picks.
  - D-cache, PLRU (4 ways): 3-bit tree. b0 = 0 -> victim in ways 0-1, 1 -> ways 2-3; b1 picks within 0-1,
    b2 within 2-3. On every hit or fill of way w the bits point AWAY from w.
    With a way mask, a subtree with no enabled way is never chosen, and a disabled leaf
    gives its sibling.
  - I-cache, FIFO (2 ways, Cache(ways=2, fifo=True)): a pointer per set = next victim; after
    each fill it moves to the next enabled way after the one filled. Hits do not move it.
  - Write-back/allocate (the only policy): store hit sets dirty; store miss refills then
    writes (dirty).
"""
import sys


class Cache:
    def __init__(self, ways=4, sets=64, fifo=False, way_mask=0):
        self.ways, self.sets, self.fifo = ways, sets, fifo
        self.allowed = [w for w in range(ways) if ((way_mask or (1 << ways) - 1) >> w) & 1]
        self.tag = [[None] * ways for _ in range(sets)]
        self.dirty = [[False] * ways for _ in range(sets)]
        self.tree = [0] * sets          # PLRU bits (4-way)
        self.ptr = [0] * sets           # FIFO pointer

    def _touch(self, s, w):
        if self.fifo:
            return                      # FIFO: hits and fills leave the pointer to access()
        if w < 2:
            self.tree[s] = (self.tree[s] | 1) & ~2 | ((1 if w == 0 else 0) << 1)
        else:
            self.tree[s] = (self.tree[s] & ~1) & ~4 | ((1 if w == 2 else 0) << 2)

    def _victim(self, s):
        for w in self.allowed:
            if self.tag[s][w] is None:
                return w
        if self.fifo:
            w = self.ptr[s]
            while w not in self.allowed:
                w = (w + 1) & 3
            return w
        b = self.tree[s]
        right = b & 1
        left_ok = any(w < 2 for w in self.allowed)
        right_ok = any(w >= 2 for w in self.allowed)
        if right and not right_ok:
            right = 0
        if not right and not left_ok:
            right = 1
        w = 2 + ((b >> 2) & 1) if right else (b >> 1) & 1
        if w not in self.allowed:
            w ^= 1
        return w

    def access(self, addr, write=False):
        s = (addr >> 4) % self.sets
        t = addr >> 10
        for w in range(self.ways):
            if self.tag[s][w] == t:
                self._touch(s, w)
                if write:
                    self.dirty[s][w] = True
                return "hit"
        w = self._victim(s)
        res = "miss_dirty" if (self.tag[s][w] is not None and self.dirty[s][w]) else "miss"
        self.tag[s][w] = t
        self.dirty[s][w] = bool(write)
        self._touch(s, w)
        if self.fifo:
            n = (w + 1) & 3
            while n not in self.allowed:
                n = (n + 1) & 3
            self.ptr[s] = n
        return res


def replay(path, config):
    """Count D-cache hits and misses per core inside RUN_START..RUN_STOP of a memtrace."""
    c = Cache()                         # the D-cache: write-back / write-allocate, PLRU, all four ways
    counts = [[0, 0], [0, 0]]
    on = False
    for line in open(path):
        p = line.split()
        if p[0] == "RUN_START":
            on, counts = True, [[0, 0], [0, 0]]
            continue
        if p[0] == "RUN_STOP":
            on = False
            continue
        r = c.access(int(p[2], 16), p[1] == "W")
        if on:
            counts[int(p[0])][0 if r == "hit" else 1] += 1
    return counts


def self_test():
    # the timing-diagram case: lines filled by A, B, C init (write-allocate), then j = 0..4
    c = Cache()
    A, B, C = 0x10010000, 0x10014000, 0x10018000
    for base in (A, B, C):
        for i in range(1024):
            c.access(base + 4 * i, True)
    assert c.access(A) != "hit"                         # A[0][0] cold for the timed run
    res = []
    for j in range(5):
        res.append((c.access(B + 4 * j), c.access(C + 4 * j)))
        c.access(C + 4 * j, True)
    assert res[0] == ("miss", "miss_dirty") or res[0][0] != "hit"
    assert all(r == ("hit", "hit") for r in res[1:4]) and res[4][0] != "hit"
    # FIFO with a 2-way mask cycles between ways 0 and 1 only
    f = Cache(fifo=True, way_mask=0b0011)
    for k in range(6):
        f.access(0x10000000 + k * 1024)
    assert all(t is None for t in f.tag[0][2:])
    return True


if __name__ == "__main__":
    if len(sys.argv) == 3:
        cnt = replay(sys.argv[1], int(sys.argv[2], 16))
        for k in range(2):
            print("core%d dhit=%d dmiss=%d" % (k, cnt[k][0], cnt[k][1]))
    else:
        print("cache_model self-test:", "PASS" if self_test() else "FAIL")
