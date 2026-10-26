# Board test campaign

| Item | Value |
| --- | --- |
| Date | 17 Oct 2026 |
| Bitstream | build/releases/fpga-v1/top_fpga.bit (build 0cd48e2, RTL = e155237; demo image loaded by scripts/updatemem.py) |
| Build | WNS +0.272 ns, WHS +0.031 ns, LUT 10,329, BRAM 53, DSP 8; `scripts/fpga_build.py` PASS (timing, budgets, no forbidden warning, DRC, check_timing, CDC) |
| Control | `scripts/board.tcl` over JTAG through the VIO: switches, BTNC / BTNL / BTNR / BTNU, LEDS / SEG7 / SEG7_DP / SEG7_TXT read back; no hand on the board |
| Capture | COM8 at 1 Mbaud, recorded for the whole session |
| Reference | rv32sim of the same image and CONFIG; packets compared with tb/top/run.py's rules (BEGIN, ROW, MROW exact; STATS exact except timing counters, one core: INSTRET, D_HIT, D_MISS exact; FRAMEs = rv32sim's or golden.py's grid) |

Recorded with the fpga-v1 bitstream, before the I-cache moved from LRU to FIFO and SW8 (D-cache FIFO)
was retired; the lists have since dropped the FIFO settings (one guide case, one test setting).
The current RTL reran the demo and test lists on the board with identical results: board_icache_fifo.md.
Since then the D-cache is write-back only: the write-through and 1-way settings below are no longer in the lists.
Every number here is a board measurement; rv32sim's cycle counts in the CSVs are its approximate
timing model.

## Results

| Test | Script | Runs | Result |
| --- | --- | --- | --- |
| Demo guide: the 19 cases of the dashboard's guide | board_regress.py scripts/board_list_demo.txt | 19 | all PASS |
| Latency sweep: L = 5, 6, 8, 10 for every program on 1 and 2 cores | same list | 32 | all PASS; the checksum never changes and the cycles rise with L in all 8 sweeps |
| The 120 seeded random settings (MatMul, Mandelbrot, Game of Life x 40) | board_regress.py scripts/board_random_106.txt | 120 | all PASS (incl. the 65 never run in xsim) |
| Test programs: t_lock, t_barrier, t_hazard, t_mext, t_cache swapped in (updatemem.py), 14 settings each (FWD, IC, DC, both caches, FIFO, write-through, 1 way, L = 5 / 10; 1 and 2 cores) | board_regress.py scripts/board_list_tests.txt --bit | 70 | all PASS: t_mext checks MULH / MULHSU / MULHU / DIV / REM edge cases on the DSP multiplier and divider; t_lock counts 20,000 with two cores |
| The 7-segment tour and browser, 18 readings per run (tour, every SW15:14 in count and rate mode, BTNR, BTNL, BTNU, the tour's second item 3.3 s later), checked against that run's own STATS packet | board_browser.py | 6 runs (00f3, 00f7, 0093, 0097, 0091, 00b7), 108 readings | all PASS, labels included |
| Reset soak: 40 seeded settings, each cut off by BTNC at a random time (2 ms - 2 s, often mid-packet), 4 bursts of 10 resets 5 ms apart, then the whole run | board_soak.py | 40 runs after 80 cut-off ones | all PASS: every rerun exact |

UART totals: demo list 2,904,746 bytes / 7,874 packets, random list 8,115,801 bytes / 20,427
packets, soak 2,240,748 bytes; 0 CRC errors and 0 bytes outside packets in every checked run.

## Findings

* **Harness, fixed in the scripts**: programming the FPGA boots it once on the physical
  switches (switches down = Game of Life with no caches, about 10 s, streaming frames), and a
  recording started during that run begins mid-packet. board_regress.py and board_browser.py
  now ignore everything before the first BEGIN of the first scripted setting, and a power-up run
  after `--bit` is not counted. board_browser.py waits for the run's length (rv32sim's cycles x
  1.2), not a fixed 600 ms.
* **rv32sim's timing model**: with both caches off (0x0011) the board needs 514.6 M cycles,
  rv32sim estimates 614.8 M; with the I-cache off (0x0013) 502.5 M vs 492.0 M. Results are
  identical; only the estimate differs. The demo script's numbers get replaced with board
  measurements.
* **Static audit**: 0 warnings in the 198 xvlog / xelab logs of the regression; every synthesis
  warning on our RTL is explained (SIM-only trace registers removed, unused CONFIG bits, address
  widths trimmed to the real memory, the multiplier's product bits absorbed into the DSP48
  pipeline registers - t_mext on the board confirms the multiplier).

Archive: build/releases/fpga-v1/ (bitstream, probes, routed design for updatemem.py, reports,
CSVs and logs).
