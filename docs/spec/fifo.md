# fifo (spec v1.2)

| Item | Value |
| --- | --- |
| File | rtl/mem/fifo.v |
| Testbench | tb/tb_fifo.v |
| Interfaces | none (inside icache) |
| Removal parameter | none |

## Purpose
FIFO (round-robin) replacement for the 2-way I-cache: one pointer bit per set, 64 sets.

## Parameters
| Name | Default | Meaning |
| --- | --- | --- |
| `NUM_SETS` | 64 | sets |
| `INDEX_BITS` | 6 | set index width |

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 each | |
| `set` | in | 6 | set being looked up |
| `way_mask` | in | 2 | enabled ways, 00 treated as 11 (icache ties it to 11) |
| `victim` | out | 1 | the pointer of `set`, or the other way if the pointer's way is disabled (combinational) |
| `fill` | in | 1 | a line was filled this cycle |
| `fill_set` | in | 6 | its set |
| `fill_way` | in | 1 | the way filled (the cache may fill an invalid way, not the victim) |

## Behaviour
PROTOCOL.md section 6: the pointer names the next victim; after each fill it moves to the other
way (unless that way is disabled). "Other" counts from the way actually filled (`fill_way`), as
tools/cache_model.py does, also when the cache filled the lowest invalid way. Hits do not move it.

## Reset values
All pointers 0.

## Tests
tb_fifo: reset, directed walk, cold-fill order on every set, exhaustive transitions
(pointer x fill way x fill mask x read mask), way-mask invariants, set isolation, idle invariance;
159,512 checks. In context: the I-cache test (tb/icache/run.py), 29,464 fetch answers with hit /
miss and exact cycles equal to tools/cache_model.py.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version (repl_fifo, 4 ways) |
| 1.1 | 24 Oct 2026 | the I-cache's replacement (way mask 0011); the D-cache no longer uses it |
| 1.2 | 25 Oct 2026 | 2-way fifo.v replaces repl_fifo.v; tb_fifo replaces tb_repl_fifo |
