# Board test campaign

| Item | Value |
| --- | --- |
| Date | 3 Nov 2026 |
| Bitstream | build/releases/fpga-v2/top_fpga.bit (demo image loaded by scripts/updatemem.py) |
| Build | WNS +0.262 ns, WHS +0.041 ns, LUT 9,982, FF 8,230, BRAM 53, DSP 8; `scripts/fpga_build.py` PASS (timing, budgets, no forbidden warning, DRC, check_timing, CDC) |
| Control | `scripts/board.tcl` over JTAG through the VIO: switches, BTNC / BTNL / BTNR / BTNU, LEDS / SEG7 / SEG7_DP / SEG7_TXT read back |
| Capture | COM8 at 1 Mbaud, recorded for the whole session |
| Reference | rv32sim of the same image and CONFIG; packets compared with tb/top/run.py's rules (BEGIN, ROW, MROW exact; STATS exact except timing counters, one core: INSTRET, D_HIT, D_MISS exact; FRAMEs = rv32sim's or golden.py's grid) |

Every number here is a board measurement; rv32sim's cycle counts in the CSVs are its approximate
timing model.

## Results

| Test | Script | Runs | Result |
| --- | --- | --- | --- |
| Demo guide: the 16 cases of the dashboard's guide | board_regress.py scripts/board_list_demo.txt | 16 | all PASS |
| Latency sweep: L = 5, 6, 8, 10 for every program on 1 and 2 cores | same list | 32 | all PASS; the checksum never changes and the cycles rise with L in all 8 sweeps |
| Ablation: every feature off alone, then all off (Game of Life, MatMul) | board_regress.py scripts/ablation_list.txt | 16 | all PASS (docs/results/ablation.md) |
| The 120 seeded random settings (MatMul, Mandelbrot, Game of Life x 40) | board_regress.py scripts/board_random_106.txt | 120 | all PASS |
| Test programs: t_lock, t_barrier, t_hazard, t_mext, t_cache swapped in (updatemem.py), 11 settings each (FWD, IC, DC, both caches, L = 5 / 10; 1 and 2 cores) | board_regress.py scripts/board_list_tests.txt --bit | 55 | all PASS: t_mext checks MULH / MULHSU / MULHU / DIV / REM edge cases on the DSP multiplier and divider; t_lock's counter = 10,000 x cores |
| The 7-segment tour and browser, 18 readings per run (tour, every SW15:14 in count and rate mode, BTNR, BTNL, BTNU, the tour's second item 3.3 s later), checked against that run's own STATS packet | board_browser.py | 6 runs (00f3, 00f7, 0093, 0097, 0091, 00b7), 108 readings | all PASS, labels included |
| Reset soak: 40 seeded settings, each cut off by BTNC at a random time (often mid-packet), 4 bursts of 10 resets 5 ms apart, then the whole run | board_soak.py | 40 runs after 80 cut-off ones | all PASS: every rerun exact |
| Boot from flash: fpga-v2 written to the QSPI flash (scripts/program_flash.tcl, programmed and verified), FPGA rebooted from it with JP1 on QSPI, then the demo list again | board_regress.py scripts/board_list_demo.txt --ltx | 48 | all PASS, identical to the JTAG-programmed runs (build/releases/fpga-v2/flash/boot_check/) |

UART: demo list 2,497,615 bytes / 7,065 packets, ablation 1,026,940 / 2,228, random list
7,687,633 / 19,585, soak 1,925,420 bytes; 0 CRC errors.

The demo and ablation runs give the same cycle count and the same counters, run for run, as the
earlier release build (one with three more test switches, SW8, SW9 and SW13:10, at 0).

Archive: build/releases/fpga-v2/ (bitstream, probes, routed design for updatemem.py, flash image,
reports, CSVs and logs).
