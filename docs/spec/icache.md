# icache (spec v1.1)

| Item | Value |
| --- | --- |
| File | rtl/core/icache.v |
| Testbench | tb/tb_icache.v |
| Vectors | refill timing and hit/miss sequence from `tools/cache_model.py` (I-cache mode) |
| Interfaces | IF-B master (to the core's own mem_delay, in front of IMEM), IF-D (`cfg[7]` IC, `cfg[4:3]` LAT via mem_delay) |
| Removal parameter | `HAS_ICACHE` = 0: every fetch goes through mem_delay as with IC = 0 |

## Purpose
Private per-core instruction cache, 2 KB, 2-way, 16-byte lines, FIFO replacement, read-only. It exists so the
fetch path has a measurable latency (memory latency model) and so I-cache hit/miss counters
mean something.

## Parameters
| Name | Default | Meaning |
| --- | --- | --- |
| `HAS_ICACHE` | 1 | 0 removes the arrays |

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 each | |
| `ic_en` | in | 1 | `cfg[7]` IC |
| `fetch_req` | in | 1 | the core wants the instruction at `fetch_addr` (held until `fetch_ready`) |
| `fetch_addr` | in | 32 | byte address, word aligned, 0x0000_0000-0x0000_3FFF |
| `fetch_ready` | out | 1 | `instr` valid this cycle |
| `instr` | out | 32 | instruction word |
| IF-B master | out/in | - | to mem_delay -> IMEM port (interfaces.md section 2) |
| `ic_hit`, `ic_miss` | out | 1 each | 1-cycle pulses per fetch when IC = 1 (perf_counters) |

## Behaviour
1. 64 sets, index `addr[9:4]`, tag `addr[31:10]`, 2 ways, FIFO replacement through repl_fifo with way mask 0011
   (PROTOCOL.md section 6): one pointer per set, moved past the way filled at the end of each refill.
2. IC = 1, hit: `fetch_ready` the cycle after `fetch_req`, like a synchronous BRAM: no stall.
3. IC = 1, miss: a 4-word line burst (L + 4 cycles), lowest-numbered invalid way, else the FIFO
   victim; then `fetch_ready`. Extra cost L + 4 (PROTOCOL.md section 7).
4. IC = 0: every fetch is a 1-word burst: extra cost L + 1; arrays untouched; no hit/miss pulses.
5. A fetch for a squashed path still completes (its result is discarded by the core); the cycle
   count therefore includes it, in RTL and on the board alike.
6. Valid bits clear on reset; IMEM never changes during a run, so there is no invalidation.

## Reset values
All valid bits 0, FIFO pointers 0, no burst open.

## Tests
Straight-line code (1 miss per 4 instructions), a loop (hits after the first pass), a jump into
a missing line, three lines mapping to one set (FIFO), IC = 0 timing for every L. PASS = hit/miss
sequence and cycle counts equal to the Python model.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version, approved by Divyam |
| 1.1 | 24 Oct 2026 | FIFO replacement (repl_fifo) instead of the 1-bit LRU |
