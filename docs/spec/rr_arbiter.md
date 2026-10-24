# rr_arbiter (spec v1.0)

| Item | Value |
| --- | --- |
| File | rtl/soc/rr_arbiter.v |
| Testbench | tb/tb_rr_arbiter.v |
| Vectors | tb/vectors/arb_*.mem from `tools/arbiter_ref.py` `simulate()` |
| Interfaces | IF-A: two slave ports (core 0, core 1), one master port with `owner` |
| Removal parameter | none |

## Purpose
Shares the single data port between the two cores, round-robin, and counts the cycles each core
waits for it (ARB_WAIT).

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 each | |
| IF-A slave 0 / 1 | in/out | - | from each core: `req`, `we`, `addr`, `wdata`, `be` -> `rdata`, `ready` |
| IF-A master | out/in | - | to addr_decode, plus `owner` |
| `ev_arbwait0`, `ev_arbwait1` | out | 1 each | 1 in every cycle that core's request waits because the port serves the other core |

## Behaviour
1. A request on a free port is forwarded in the same cycle (combinational grant), so an
   uncontended access has the timing of IF-A rule 3 with no extra cycle.
2. The grant is held from the cycle it is given until that request's `ready`.
3. When both cores request in the same cycle with the port free, the core that did not get the
   last grant wins (priority alternates); no starvation.
4. `ready` and `rdata` go only to the owner; the other core sees `ready` = 0.
5. (1.0.1) A BARRIER read (load from 0x2000_000C) is not arbitrated: it raises `bar_req[k]` to
   lock_barrier from the cycle after it appears, and is answered (`rdata` 0) when
   `bar_release[k]` comes; the other core keeps using the port. Ports `bar_req[1:0]` (out),
   `bar_release[1:0]` (in).

## Reset values
Port free; last grant = core 1 (so core 0 wins the first tie).

## Tests
10,000 random cycles of two-master request patterns against `arbiter_ref.py` (grant cycles and
wait counts); a long symmetric load shows no starvation. PASS = 0 mismatches.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version, approved by Divyam |
| 1.0.1 | 16 Oct 2026 | BARRIER reads are parked in rr_arbiter (they never hold the shared data port, which would keep the other core from reaching the barrier: a deadlock in the 1.0 design). Pending Divyam's review |
