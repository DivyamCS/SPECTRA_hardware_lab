# dcache (spec v1.2)

| Item | Value |
| --- | --- |
| File | rtl/mem/dcache.v |
| Testbench | tb/tb_dcache.v, tb/tb_dcache_random.v (68), tb/tb_dcache_corner.v (69) |
| Vectors | tb/vectors/dcache_s*.mem from `tools/cache_model.py`: four random seeds, every L |
| Interfaces | IF-A slave (from addr_decode, with `owner`), IF-B master (to the D-side mem_delay), IF-D |
| Removal parameter | `HAS_DCACHE` = 0: always bypass, as DC = 0 |

## Purpose
The shared D-cache: 4 KB, 4-way, 16-byte lines, 64 sets, PLRU, write-back / write-allocate; tags
and data in BRAM. DC changes cycle counts only, never results.

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 each | |
| `cfg_dc` | in | 1 | `cfg[1]` |
| IF-A slave | in/out | - | `req`, `we`, `addr`, `wdata`, `be`, `owner` -> `rdata`, `ready` |
| IF-B master | out/in | - | to mem_delay -> dmem_bram |
| `ev_hit`, `ev_miss`, `ev_owner` | out | 1,1,1 | 1-cycle pulse per cacheable access when DC = 1, with the requesting core |

## Behaviour
1. Geometry (PROTOCOL.md section 6): index `addr[9:4]`, tag `addr[31:10]`; data in 4 BRAMs
   (1 KB per way); valid, dirty and tag per line.
2. Timing (core's view, IF-A rule 3): hit -> `ready` in cycle 2; miss with clean victim ->
   2 + (L + 4); dirty victim -> write-back burst (L + 4) before the refill (L + 4); DC = 0 ->
   every access a 1-word burst, 2 + (L + 1).
3. Miss: fill the lowest-numbered invalid way; otherwise the victim from plru (tree pseudo-LRU).
4. Write-back, write-allocate: store hit writes the line and sets dirty; store miss allocates the
   line, then writes it; a dirty victim is written back before the refill.
5. DC = 0 bypass: arrays untouched, no hit/miss pulses.
6. No coherence is needed: the one D-cache is shared by both cores (private D-caches with
   snooping are the stretch variant).

## Reset values
All valid and dirty bits 0, replacement state 0, no burst open.

## Tests
Directed tests, one feature each (bypass, read hit, clean miss, WB-WA, dirty eviction, PLRU,
owner-tagged pulses); 100,000 random accesses per latency against
the Python model and a memory image (0 mismatches in data, hit/miss and cycles); corner cases
(5 lines into one set, hit right after a miss, byte and half stores).

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version |
| 1.1 | 24 Oct 2026 | PLRU only: `cfg_repl` (SW8) and repl_fifo removed |
| 1.2 | 25 Oct 2026 | Write-back / write-allocate only; `cfg_wpol` (SW9) and `cfg_ways` (SW13:10) removed, both switches reserved |
