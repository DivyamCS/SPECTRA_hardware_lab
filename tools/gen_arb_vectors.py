"""gen_arb_vectors.py - rr_arbiter testbench vectors from tools/arbiter_ref.py.

    python tools/gen_arb_vectors.py OUTDIR      write OUTDIR/arb_vectors.mem
    python tools/gen_arb_vectors.py --check     self-test

About 10,000 cycles of two-master traffic, seeded. Each core has at most one request open
(IF-A rule 1): it requests again a random 0-6 cycles (sometimes 20-60) after its previous
`ready`. Service time = cycles from grant to `ready`, inclusive: 2 (D-cache hit or MMIO),
14 (miss at L = 8) or 26 (dirty miss at L = 8). Expected grants come from
arbiter_ref.simulate(). Line format (decimal):

    master request_cycle service grant_cycle ready_cycle

sorted by request cycle. The testbench raises `req` for `master` in `request_cycle`, its slave
model pulses `ready` `service` cycles after the grant (in `ready_cycle`), and checks that the
request reaches the downstream port in `grant_cycle` with `owner` = master. Wait cycles per
master = sum of (grant - request).
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import arbiter_ref  # noqa: E402

CYCLES = 10000


def generate(seed=20):
    rng = random.Random(seed)
    jobs = []
    nxt = {0: rng.randrange(4), 1: rng.randrange(4)}
    while min(nxt.values()) < CYCLES:
        t = min(nxt.values())
        for m in (0, 1):                       # add every master requesting in cycle t together
            if nxt[m] == t:
                jobs.append((m, t, rng.choice((2, 2, 2, 2, 14, 26))))
        out, _ = arbiter_ref.simulate(jobs)
        for m in (0, 1):
            if nxt[m] == t:
                ready = [o for o in out if o[0] == m and o[1] == t][0][3]
                think = rng.randrange(7) if rng.random() < 0.9 else rng.randrange(20, 61)
                nxt[m] = ready + 1 + think
    out, waits = arbiter_ref.simulate(jobs)
    svc = {(m, t): d for m, t, d in jobs}
    lines = ["%d %d %d %d %d" % (m, rt, svc[(m, rt)], g, r) for m, rt, g, r in sorted(out, key=lambda o: (o[1], o[0]))]
    return lines, waits


def self_test(outdir=None):
    assert arbiter_ref.self_test()
    lines, waits = generate()
    recs = [tuple(map(int, ln.split())) for ln in lines]
    last_ready = {0: -1, 1: -1}
    busy_until = -1
    for m, rt, d, g, r in sorted(recs, key=lambda x: x[3]):
        assert g >= rt and r == g + d - 1, recs                     # grant then service
        assert g > busy_until                                        # one owner at a time
        busy_until = r
    for m, rt, d, g, r in sorted(recs, key=lambda x: x[1]):
        assert rt > last_ready[m]                                    # one open request per master
        last_ready[m] = r
    assert [sum(g - rt for m2, rt, d, g, r in recs if m2 == m) for m in (0, 1)] == waits
    assert sum(waits) > 0 and max(r for *_, r in recs) >= CYCLES - 100
    if outdir:
        with open(os.path.join(outdir, "arb_vectors.mem")) as f:
            assert f.read().splitlines() == lines, "arb_vectors.mem differs from a fresh generation"
    return True


if __name__ == "__main__":
    if sys.argv[1:] == ["--check"]:
        d = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tb", "vectors")
        print("gen_arb_vectors self-test:", "PASS" if self_test(
            d if os.path.exists(os.path.join(d, "arb_vectors.mem")) else None) else "FAIL")
    elif len(sys.argv) == 2:
        os.makedirs(sys.argv[1], exist_ok=True)
        lines, waits = generate()
        with open(os.path.join(sys.argv[1], "arb_vectors.mem"), "w", newline="\n") as f:
            f.write("\n".join(lines) + "\n")
        print("wrote arb_vectors.mem: %d requests, waits core0=%d core1=%d" % (len(lines), waits[0], waits[1]))
    else:
        sys.exit(__doc__)
