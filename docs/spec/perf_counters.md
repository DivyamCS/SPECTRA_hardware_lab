# perf_counters (spec v1.0)

| Item | Value |
| --- | --- |
| File | rtl/soc/perf_counters.v |
| Testbench | tb/tb_perf_counters.v |
| Vectors | directed event patterns |
| Interfaces | read through mmio_bus |
| Removal parameter | none |

## Purpose
The cycle counter and, per core, INSTRET, D_HIT, D_MISS, I_HIT, I_MISS, ARB_WAIT and BAR_WAIT:
the numbers the dashboard and the 7-segment display use.

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 each | |
| `run_start`, `run_stop` | in | 1 each | 1-cycle pulses from the RUN_START / RUN_STOP writes |
| `ev_instret`, `ev_ihit`, `ev_imiss`, `ev_arbwait`, `ev_barwait` | in | 2 each | bit k = core k event this cycle |
| `ev_dhit`, `ev_dmiss`, `ev_downer` | in | 1,1,1 | D-cache events with their core |
| `rd_sel` | in | 4 | 0 = CYCLES, 1-7 = core 0 counters, 9-15 = core 1 counters (mmio_bus) |
| `rd_data` | out | 32 | selected counter (combinational) |
| `snap` | out | 32 x 15 | all counters, for the STATS packet (streamer) |

## Behaviour
1. `run_start` clears every counter and starts counting; `run_stop` freezes them; outside a
   run nothing counts (PROTOCOL.md section 3). (1.0.1) The RUN_START cycle's own events count:
   every counter restarts at that cycle's increment, so the RUN_START store is in INSTRET, as
   rv32sim counts it; the RUN_STOP cycle is not counted.
2. CYCLES counts every `clk` cycle of the run. The other counters add one per event pulse.
3. 32-bit, wrapping (no run comes near 2^32 cycles: the longest, GoL on 1 core, is about 72 M
   by the simulator's estimate).

## Reset values
All counters 0, not counting.

## Tests
Events before RUN_START are ignored; each counter counts its own core's events only; RUN_STOP
freezes values while events continue; RUN_START clears. PASS = all counters equal the expected
counts.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version |
| 1.0.1 | 16 Oct 2026 | RUN_START cycle counted (INSTRET = rv32sim exactly; found by the first full-SoC run) |
