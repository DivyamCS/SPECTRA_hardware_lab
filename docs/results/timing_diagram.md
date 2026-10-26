# MatMul inner-loop timing, C1-C30

RTL (tb_core_dc with TIMING_DUMP, CONFIG 0x00F3: FWD, D-cache write-back PLRU, I-cache, L = 8,
one core) against a pipeline model built from the documented rules (tb/timing/run.py). C1 =
the 5-th time inside the run that the loop's first instruction 0xAD4 has just entered ID
with a bubble in EX (after the taken bne).

Result: all 30 rows equal, every field. PC in hex, - = empty stage (bubble).

| C | ID | EX | MEM/WB | freeze | ex_hold | squash | interlock | ic_wait | dport_wait |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| C1 | ad4 | - | af0 | 0 | 0 | 0 | 0 | 0 | 0 |
| C2 | ad8 | ad4 | - | 0 | 0 | 0 | 0 | 0 | 0 |
| C3 | adc | ad8 | ad4 | 1 | 0 | 0 | 0 | 0 | 1 |
| C4 | adc | ad8 | ad4 | 0 | 0 | 0 | 0 | 0 | 0 |
| C5 | ae0 | adc | ad8 | 0 | 0 | 0 | 0 | 0 | 0 |
| C6 | ae4 | ae0 | adc | 1 | 0 | 0 | 0 | 0 | 1 |
| C7 | ae4 | ae0 | adc | 0 | 1 | 0 | 0 | 0 | 0 |
| C8 | ae4 | ae0 | - | 0 | 1 | 0 | 0 | 0 | 0 |
| C9 | ae4 | ae0 | - | 0 | 0 | 0 | 0 | 0 | 0 |
| C10 | ae8 | ae4 | ae0 | 0 | 0 | 0 | 0 | 0 | 0 |
| C11 | aec | ae8 | ae4 | 0 | 0 | 0 | 0 | 0 | 0 |
| C12 | af0 | aec | ae8 | 0 | 0 | 0 | 0 | 0 | 0 |
| C13 | af4 | af0 | aec | 1 | 0 | 0 | 0 | 0 | 1 |
| C14 | af4 | af0 | aec | 0 | 0 | 1 | 0 | 0 | 0 |
| C15 | - | - | af0 | 1 | 0 | 0 | 0 | 1 | 0 |
| C16 | ad4 | - | af0 | 0 | 0 | 0 | 0 | 0 | 0 |
| C17 | ad8 | ad4 | - | 0 | 0 | 0 | 0 | 0 | 0 |
| C18 | adc | ad8 | ad4 | 1 | 0 | 0 | 0 | 0 | 1 |
| C19 | adc | ad8 | ad4 | 0 | 0 | 0 | 0 | 0 | 0 |
| C20 | ae0 | adc | ad8 | 0 | 0 | 0 | 0 | 0 | 0 |
| C21 | ae4 | ae0 | adc | 1 | 0 | 0 | 0 | 0 | 1 |
| C22 | ae4 | ae0 | adc | 0 | 1 | 0 | 0 | 0 | 0 |
| C23 | ae4 | ae0 | - | 0 | 1 | 0 | 0 | 0 | 0 |
| C24 | ae4 | ae0 | - | 0 | 0 | 0 | 0 | 0 | 0 |
| C25 | ae8 | ae4 | ae0 | 0 | 0 | 0 | 0 | 0 | 0 |
| C26 | aec | ae8 | ae4 | 0 | 0 | 0 | 0 | 0 | 0 |
| C27 | af0 | aec | ae8 | 0 | 0 | 0 | 0 | 0 | 0 |
| C28 | af4 | af0 | aec | 1 | 0 | 0 | 0 | 0 | 1 |
| C29 | af4 | af0 | aec | 0 | 0 | 1 | 0 | 0 | 0 |
| C30 | - | - | af0 | 1 | 0 | 0 | 0 | 1 | 0 |

D-cache results of the accesses in the window (cache_model.py, = the RTL's pulses): 0xad4 hit, 0xadc hit, 0xaec hit, 0xad4 hit, 0xadc hit, 0xaec hit, 0xad4 hit, 0xadc hit, 0xaec hit, 0xad4 miss_dirty, 0xadc miss_dirty, 0xaec hit
Further windows (tb/timing/run.py N): N = 1, 2, 3, 4, 6, 7, 33, 100 also give 30 equal rows; the
windows N = 3 and 4 each contain two D-cache misses among their first six data accesses, so the
refill freezes are covered too.

Reading the window: one iteration of the 8-instruction loop is 15 cycles here (C1-C15): each load
and the store stay 2 cycles in MEM/WB (one freeze each), the MUL holds EX for 2 extra cycles, and
the taken bne squashes 0xAF4 (the fall-through word in ID) and the fetch in flight, after which
ID is empty for one cycle (ic_wait) before 0xAD4 returns.

Note (17 Oct 2026): the loop moved to 0xE60 when fw/display.c grew (7-segment tour); tb/timing/run.py
now finds the loop in demo.lst by its 8 instructions instead of a fixed address, and C1-C30 still
equal the pipeline model in every field.
