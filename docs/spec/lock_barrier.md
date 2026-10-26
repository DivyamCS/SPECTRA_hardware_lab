# lock_barrier (spec v1.0)

| Item | Value |
| --- | --- |
| File | rtl/soc/lock_barrier.v |
| Testbench | tb/tb_lock_barrier.v |
| Vectors | directed |
| Interfaces | driven by mmio_bus (IF-C accesses to CORE_ID, NCORES, BARRIER, LOCK); IF-D via `ncores` |
| Removal parameter | none |

## Purpose
The hardware synchronisation for two cores: a test-and-set LOCK and a BARRIER that blocks each
core's load until every running core has arrived.

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 each | |
| `ncores` | in | 2 | from core_ctrl |
| `lock_rd`, `lock_wr0`, `owner` | in | 1,1,1 | a LOCK read / a write of 0 to LOCK, and which core |
| `lock_rdata` | out | 1 | 0 = acquired, 1 = busy (same cycle as `lock_rd`) |
| `bar_req` | in | 2 | bit k: core k has an open BARRIER read (parked in rr_arbiter, 1.0.1) |
| `bar_release` | out | 2 | bit k: complete core k's BARRIER read this cycle |
| `ev_barwait0`, `ev_barwait1` | out | 1 each | 1 in every cycle core k is blocked in BARRIER |

## Behaviour
1. LOCK read: returns the lock bit and sets it in the same cycle (atomic: the single data port
   serialises the two cores, so two back-to-back reads give exactly one 0).
2. LOCK write 0: clears it. Any core may release (the firmware only releases what it holds).
3. BARRIER: when the number of cores with `bar_req` set equals `ncores`, every waiting core is
   released in the same cycle and the barrier resets for the next round. With one core it
   releases at once.
4. A BARRIER read returns 0 (PROTOCOL.md section 3).

## Reset values
Lock free, no core waiting.

## Tests
Back-to-back LOCK reads from both cores: exactly one gets 0; release then re-acquire; barrier
with 1 and 2 cores, 1,000 rounds, either core arriving first; BAR_WAIT counts the blocked
cycles. PASS = all checks.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version |
| 1.0.1 | 16 Oct 2026 | `bar_req` / `bar_release` connect to rr_arbiter, not mmio_bus: BARRIER reads are parked in rr_arbiter (they never hold the shared data port, which would keep the other core from reaching the barrier: a deadlock in the 1.0 design) |
