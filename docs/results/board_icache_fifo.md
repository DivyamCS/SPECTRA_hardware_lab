# I-cache FIFO, D-cache PLRU only: check on the board

| Item | Value |
| --- | --- |
| Date | 24 Oct 2026 |
| Change | I-cache replacement 1-bit LRU -> FIFO (repl_fifo, way mask 0011); D-cache PLRU only (the FIFO option and SW8 REPL removed; SW8 is reserved) |
| Bitstream | `python scripts/fpga_build.py` on this RTL: PASS; WNS +0.408 ns, WHS +0.038 ns, LUT 10,034, FF 8,087, BRAM 53, DSP 8 (fpga-v1: LUT 10,329, FF 8,223) |
| Programs | the demo image, then t_lock, t_barrier, t_hazard, t_mext, t_cache swapped in by scripts/updatemem.py |
| Lists | scripts/board_list_demo.txt (50 settings), scripts/board_list_tests.txt (13 settings per test program) |
| Control, capture | `scripts/board_regress.py ... --bit` over JTAG, COM8 at 1 Mbaud |
| Data | [board_icache_fifo.csv](board_icache_fifo.csv): one row per run, the same columns as board_regress.py's CSV |

## Results

| Image | Runs | Result | Against fpga-v1 (build/releases/fpga-v1/board/) |
| --- | ---: | --- | --- |
| demo (Demo guide cases and the latency sweep) | 50 | all PASS: every run = rv32sim's packets, checksum OK | all 50 identical in every column: cycles, instructions, D- and I-cache hits and misses, arbiter and barrier wait |
| t_lock | 13 | all PASS | identical cycles, packets and result |
| t_barrier | 13 | all PASS | identical |
| t_hazard | 13 | all PASS | identical |
| t_mext | 13 | all PASS | identical |
| t_cache | 13 | all PASS | identical |

UART for the demo list: 2,812,604 bytes, 7,671 packets, 0 errors.

In these programs FIFO and 1-bit LRU evict the same I-cache lines: rv32sim gives the same cycles
and I-cache hits under both policies, and the board confirms it run for run. The numbers measured on fpga-v1 (README, docs/results/numbers.md,
ablation.md) therefore hold for this RTL; the FIFO D-cache rows were dropped from the lists and the
ablation (they measured 1.00x and 1.02x against PLRU).
