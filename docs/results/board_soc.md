# The full SoC on the board

| Item | Value |
| --- | --- |
| Date | 16 Oct 2026 |
| Bitstream | build/794279c/impl/top_fpga/top_fpga.bit (`python scripts/fpga_build.py`: PASS; WNS +0.408 ns, LUT 10,229, BRAM 53, DSP 8; demo image loaded by scripts/updatemem.py) |
| Control | `scripts/board.tcl` over JTAG: VIO switches, VIO reset (BTNC), LEDS / SEG7 read back; no hand on the board |
| Capture | `python host/uart_packets.py --port COM8` (1 Mbaud), started before the reset |
| Compare | tb/top/run.py's packets() and compare_streams() against rv32sim's reference stream (ref.bin) and against the RTL simulation's stream (tb_top uart_rtl.hex) of the same CONFIG |

These are board measurements.

## A program swapped into the routed design

`scripts/updatemem.py swap` loaded fw/build/t_lock into the routed design (no re-implementation;
contents read back = the image exactly). On the board with SW = 0x0097: LEDS 0x1003 (LED0 done,
LED1 checksum OK), SEG7 380 (thousands of cycles; RTL simulation 380,212). t_mext and t_cache
were also swapped in and read back exactly (run on the board: docs/results/board_regress.md).

## Every demo program, one and two cores

| CONFIG | Program | Cores | LEDS | SEG7 (k cycles) | Run cycles (STATS, board) | RTL simulation | Packets | Stream = RTL simulation, byte for byte |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0x0093 | Game of Life | 1 | 0x1003 | 70,337 | 70,337,751 | 70,337,751 | 203 (201 FRAMEs) | yes |
| 0x0097 | Game of Life | 2 | 0x1003 | 38,660 | 38,660,359 | 38,660,359 | 136 | yes |
| 0x0091 | Game of Life, D-cache off | 1 | 0x1003 | 193,211 | (not captured) | 193,211,983 | - | - |
| 0x00b3 | Mandelbrot halves | 1 | 0x1003 | 12,224 | 12,224,499 | 12,224,499 | 146 | yes |
| 0x00d3 | Mandelbrot interleaved | 1 | 0x1003 | 12,224 | 12,224,409 | 12,224,409 | 146 | yes |
| 0x00b7 | Mandelbrot halves | 2 | 0x1003 | 6,209 | 6,209,739 | 6,209,739 | 146 | yes |
| 0x00d7 | Mandelbrot interleaved | 2 | 0x1003 | 6,131 | 6,131,228 | 6,131,228 | 146 | yes |
| 0x00f3 | MatMul | 1 | 0x1003 | 535 | 535,598 | 535,598 | 34 | yes |
| 0x00f7 | MatMul | 2 | 0x1003 | 297 | 297,026 | 297,026 | 34 | yes |

Every packet of every captured run is also equal to rv32sim's reference under the rules
(cycle stamps and timing counters aside; every FRAME = rv32sim's or golden.py's). UART: 296,117
bytes in 991 packets over two captures, 0 CRC errors, 0 bytes outside packets.

So the board, the RTL simulation and the dashboard's data agree exactly: every cycle count, every
counter and every byte the laptop receives. Two-core speedups measured on the board: Game of Life
1.82x, Mandelbrot halves 1.97x, interleaved 1.99x, MatMul 1.80x.

Not covered here: the dashboard window itself with the board live (`python host/spectra_host.py
--port COM8`, http://localhost:8000), the 7-segment browser on the board, the test programs on the board, L = 5, 6, 10, the board regression
over the settings.

## 7-segment tour with labels (17 Oct 2026, bitstream build/0cd48e2/impl/top_fpga)

After each run the display tours the run's counters, 3 s per item, with
labels. Board, SW = 0x00f7 (MatMul, 2 cores), read through the VIO every 3 s (SEG7, SEG7_DP and
SEG7_TXT decoded with tools/seg7_model.py):

`Cy   297` -> `IH0. 99.99` -> `dH0. 99.25` -> `CPI0. 2.20` -> `IH1. 99.99` -> `dH1. 96.86` ->
`CPI1. 2.20` -> `Ar0. 14.20` -> `Ar1.  7.05` -> `Cy   297` (loop). SW15:14 = 01: `dH0.49300`
(browser); BTNR: `dH1.48109`; BTNU: `Cy   297` (tour again). LEDs as specified (LED10 tour on).
Build: WNS +0.272 ns, LUT 10,329 (+94 for the tour), BRAM 53, DSP 8; scripts/fpga_build.py PASS.
