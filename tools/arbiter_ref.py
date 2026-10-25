"""arbiter_ref.py - cycle-level reference of the round-robin data-port arbiter (rr_arbiter.v).

Rules: a master raises req and holds it until it sees ready. When the port is idle and only one
master requests, it is granted. When both request in the same cycle, the master that was NOT
granted last time wins. A grant is held until the slave's ready pulse; the next grant can start
in the cycle after ready. Every cycle a master's request waits ungranted counts as one
arbiter-wait cycle for that master.

    python tools/arbiter_ref.py            self-test + a random scenario summary
Library: simulate(jobs) where jobs = list of (master, request_cycle, service_cycles).
"""
import random


def simulate(jobs):
    """Return list of (master, request_cycle, grant_cycle, ready_cycle) and total waits."""
    pending = {0: [], 1: []}
    for m, t, d in sorted(jobs, key=lambda j: j[1]):
        pending[m].append((t, d))
    t, busy_until, last = 0, -1, 1
    out, waits = [], [0, 0]
    while pending[0] or pending[1]:
        ready_now = [m for m in (0, 1) if pending[m] and pending[m][0][0] <= t]
        if t > busy_until and ready_now:
            m = ready_now[0] if len(ready_now) == 1 else last ^ 1
            rt, d = pending[m].pop(0)
            waits[m] += t - rt
            out.append((m, rt, t, t + d - 1))
            busy_until, last = t + d - 1, m
        t += 1
    return out, waits


def self_test():
    # simultaneous requests alternate; master 1 was "last", so master 0 goes first
    out, waits = simulate([(0, 0, 2), (1, 0, 2), (0, 2, 2), (1, 2, 2)])
    assert [o[0] for o in out] == [0, 1, 0, 1], out
    assert waits == [2, 6], waits          # m1 waits 2 (behind m0), then 4 (behind both)
    # no starvation: one master requesting back-to-back cannot block the other
    jobs = [(0, t, 2) for t in range(0, 200, 2)] + [(1, 5, 2)]
    out, _ = simulate(jobs)
    g1 = [o for o in out if o[0] == 1][0]
    assert g1[2] - g1[1] <= 2, g1
    return True


if __name__ == "__main__":
    print("arbiter_ref self-test:", "PASS" if self_test() else "FAIL")
    rng = random.Random(7)
    jobs = [(rng.randrange(2), rng.randrange(40000), rng.choice([2, 2, 2, 14, 26])) for _ in range(2000)]
    out, waits = simulate(jobs)
    print("random 2000 requests: waits core0=%d core1=%d, max single wait=%d"
          % (waits[0], waits[1], max(o[2] - o[1] for o in out)))
