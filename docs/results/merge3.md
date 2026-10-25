# One core + D-cache (+ I-cache): every program x DC, L

tb_core_dc (core + I-cache + D-cache + mem_delay + DMEM, MMIO stub), `tb/core/run_m3.py`. PASS =
rv32sim's checksum (golden OK) and 0 trace differences. The D-cache hit/miss counts (pulses inside
RUN_START..RUN_STOP) are compared with tools/cache_model.py on rv32sim's data trace
(`tb/core/check_hits.py`). Cycles are xsim counts, not board measurements.
Recorded before the I-cache moved to FIFO and the D-cache to the write-back-only design; the
current RTL gives the same cycles and hit / miss counts (rv32sim for the I-cache, the cycle-exact
D-cache tests against tools/cache_model.py for the D-cache).

## Short matrix (`run_m3.py short`): 48 runs, all PASS

t_hazard, t_mext, t_cache, t_lock, t_barrier and MatMul, each for DC = 0 and 1,
at L = 5, 6, 8, 10 (8 configurations per program).

## Long set (`run_m3.py long`): 6 runs at L = 8, all PASS

| Program | DC = 0 | DC = 1 |
| --- | --- | --- |
| Mandelbrot, halves (cycles) | 12,960,670 | 12,525,232 |
| Mandelbrot, interleaved | 12,960,580 | 12,525,142 |
| Game of Life | 193,444,249 | 70,473,233 |

Every run: golden checksum, 0 trace differences (GoL 46,920,119 instructions).

## Hit/miss cross-check

All 27 DC = 1 runs of both sets: RTL hits and misses = cache_model.py exactly (e.g. GoL
13,852,343 / 201,604).

## Not run

Mandelbrot and Game of Life at L = 5, 6 and 10 (36 runs, about 8 hours of xsim): the cache
behaviour does not depend on L (hit/miss sequences are the same; only waits change), and L is
covered at every value by the short matrix. Proposed as an overnight run when wanted.
