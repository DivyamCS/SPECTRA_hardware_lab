# Dual core in simulation

The whole SoC (soc_top + tb_top, `tb/top/run.py`) with CONFIG 0x0093 + DUAL (bit 2) and the
program bits. RTL cycle counts in xsim: simulation, not board measurements.

## Programs on two cores

| Program | CONFIG | Checksum (golden) | Traces | Packets | Run cycles, 1 core | 2 cores | Speedup |
| --- | --- | --- | --- | --- | --- | --- | --- |
| MatMul | 00F7 | 0xC063A00F | both harts = rv32sim | 34 / 34 | 535,598 | 297,026 | 1.80x |
| Mandelbrot halves | 00B7 | 0x22B8E929 | both harts = rv32sim | 146 / 146 | 12,224,499 | 6,209,739 | 1.97x |
| Mandelbrot interleaved | 00D7 | 0x22B8E929 | both harts = rv32sim | 146 / 146 | 12,224,409 | 6,131,228 | 1.99x |
| Game of Life | 0097 | 0xA556EEC3 | both harts = rv32sim | 136 / 136 (134 FRAMEs, the same as rv32sim) | 70,337,751 | 38,660,359 | 1.82x |
| t_lock (102) | 0097 | counter 20,000 | (spin loops: checksum only) | 2 / 2 | | | |
| t_barrier (103) | 0097 | OK | both harts = rv32sim | 2 / 2 | | | |

The speedups equal rv32sim's estimates (1.80x, 1.97x, 1.99x, 1.82x). With two
cores the per-core counters and the order of the two cores' ROW / MROW packets depend on timing:
STATS is compared on config, ncores, program and checksum, ROW / MROW as sets; each hart's
instruction stream is checked by its trace.

## DUAL = 0 vs 1

Same checksum for every program; DUAL = 0: ncores 1 and core 1 INSTRET 0; DUAL = 1: ncores 2 and
core 1 retires instructions (MatMul 134,804, GoL 23,415,782).

## Arbiter fairness

Symmetric load, Mandelbrot interleaved on two cores: ARB_WAIT 854 / 828 cycles, 3.0 % apart
(limit 10 %). MatMul's 42,208 / 20,958 is the program's own asymmetry (core 1 has 1,558 D-cache
misses to core 0's 368, each holding the shared port 14-26 cycles); rv32sim shows the same
50 % split. tb_rr_arbiter's symmetric test alternates strictly.

## Watchdog

tb_core and tb_top fail a run after 100,000 cycles with no retired instruction.
In tb_top a core parked at BARRIER does not count: it waits by design. Before that rule the
watchdog fired falsely three times (Mandelbrot halves on two cores - the lighter half's core
waits about 160 k cycles at the final barrier - and two random settings with IC = 0, where core
1 waits at the boot barrier while core 0 prepares the data); all three pass with it. In every
other run it never fired.

## Finding about rv32sim

rv32sim's BAR_WAIT adds a core's whole barrier wait when the barrier releases, including the
part before RUN_START (MatMul two cores: core 1 46,195 in rv32sim, 5 in the RTL). PROTOCOL.md
section 3 counts only inside the run, as the RTL does. Results are unaffected.

## Random settings

40 seeded random settings of SW13:0 per program (tb/top/run_random.py, seed 106; PROGRAM fixed,
Mandelbrot alternating halves / interleaved). Each run: checksum golden, every running hart's
trace = rv32sim's, every UART packet under the rules, shadows = golden.py.

| Program | In xsim | Result | Log |
| --- | --- | --- | --- |
| MatMul | 1-40 | 40 / 40 PASS | build/logs/step106_matmul.log (+ 337c, 0476 rerun after the watchdog fix) |
| Mandelbrot | 1-15 (one two-core: 10d6) | 15 / 15 PASS | build/logs/step106_mandel.log |
| Game of Life | none | - | - |

xsim stopped after Mandelbrot setting 15 (about 30 min per Mandelbrot
setting, up to 2 h per Game of Life setting); every one of the 120 settings runs on the board in
the board regression instead, from scripts/board_random_106.txt (column xsim marks the 55
already passed here). The board checks checksum, CONFIG and every UART packet against rv32sim, not
the instruction trace. Game of Life's RTL in xsim is covered at fixed settings on the whole SoC
(0093 one core, 0097 two cores).

Setting 14 (10d6, two cores, interleaved): 7,265,297 run cycles (STATS), rv32sim 7,265,316; the
same setting on one core (10d2) is 14,485,774 in rv32sim: 1.99x. The 14.7 M "cycles" in the log
line were tb_top's count from reset until the UART had sent everything; tb/top/run.py now prints
the STATS run cycles beside it (757e3d7).
