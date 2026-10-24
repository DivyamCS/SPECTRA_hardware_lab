# One core + D-cache (+ I-cache): every program x DC, WPOL, L

tb_core_dc (core + I-cache + D-cache + mem_delay + DMEM, MMIO stub), `tb/core/run_m3.py`. PASS =
rv32sim's checksum (golden OK) and 0 trace differences. The D-cache hit/miss counts (pulses inside
RUN_START..RUN_STOP) are compared with tools/cache_model.py on rv32sim's data trace
(`tb/core/check_hits.py`). Cycles are xsim counts, not board measurements.
Recorded with the earlier I-cache policy (1-bit LRU); the I-cache is now FIFO.
rv32sim gives the same cycles and I-cache hits under both policies for every demo and test program, and the D-cache (PLRU) is unchanged.

## Short matrix (`run_m3.py short`): 72 runs, all PASS

t_hazard, t_mext, t_cache, t_lock, t_barrier and MatMul, each for DC = 0 and both WPOL
settings, at L = 5, 6, 8, 10 (12 configurations per program).

## Long set (`run_m3.py long`): 9 runs at L = 8, all PASS

| Program | DC = 0 | DC = 1, write-back | DC = 1, write-through |
| --- | --- | --- | --- |
| Mandelbrot, halves (cycles) | 12,960,670 | 12,525,232 | 12,732,558 |
| Mandelbrot, interleaved | 12,960,580 | 12,525,142 | 12,732,468 |
| Game of Life | 193,444,249 | 70,473,233 | 82,223,839 |

Every run: golden checksum, 0 trace differences (GoL 46,920,119 instructions).

## Hit/miss cross-check

All 54 DC = 1 runs of both sets: RTL hits and misses = cache_model.py exactly (e.g. GoL
write-back 13,852,343 / 201,604).

## Not run

Mandelbrot and Game of Life at L = 5, 6 and 10 (36 runs, about 8 hours of xsim): the cache
behaviour does not depend on L (hit/miss sequences are the same; only waits change), and L is
covered at every value by the short matrix. Proposed as an overnight run when wanted.
