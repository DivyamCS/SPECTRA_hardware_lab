# Core + I-cache: every program with IC = 1 and IC = 0

tb_core (ideal 1-cycle data memory) with the core's own I-cache and I-side mem_delay (L = 8),
RTL at ef22203. PASS = rv32sim's checksum (golden OK) and 0 trace differences.
Cycles are xsim counts (simulation, not board measurements).

| Program | IC = 1 (CONFIG) | cycles | IC = 0 (CONFIG) | cycles | Instructions compared |
| --- | --- | --- | --- | --- | --- |
| t_hazard | 0093 | 2,366 | 0013 | 5,014 | 450 / 449 |
| t_mext | 0093 | 241,613 | 0013 | 676,861 | 45,187 / 45,186 |
| t_cache | 0093 | 95,856 | 0013 | 707,722 | 54,496 / 54,495 |
| t_lock | 0093 | 310,357 | 0013 | 2,250,694 | 170,062 / 170,061 |
| t_barrier | 0093 | 8,891 | 0013 | 51,376 | 4,576 / 4,575 |
| MatMul | 00F3 | 572,415 | 0073 | 3,592,886 | 307,565 / 307,564 |
| Mandelbrot, halves | 00B3 | 12,462,925 | 0033 | 87,625,657 | 7,750,959 / 7,750,958 |
| Mandelbrot, interleaved | 00D3 | 12,462,835 | 0053 | 87,625,561 | 7,750,956 / 7,750,955 |
| Game of Life | 0093 | 66,848,125 | 0013 | 501,357,875 | 46,920,119 / 46,920,118 |

Every row: same checksum with IC = 1 and 0, 0 trace differences. With IC = 1 the I-cache costs
little over ideal fetch (MatMul +556 cycles over 571,859; GoL +811 over 66,847,314): only cold
misses. IC = 0 costs L + 1 = 9 cycles per fetch. The compared count differs by one between the
two columns only in the instructions retired during the 4-cycle drain after CHECKSUM.
Log: build/logs/step074_runs.log (plus the runs for t_hazard, t_mext and MatMul).
