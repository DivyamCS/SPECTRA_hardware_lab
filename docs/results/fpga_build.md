# Full FPGA build

Top `top_fpga` (two cores, VIO hook, demo image), xc7a100tcsg324-1, 50 MHz, Vivado 2025.2,
`python scripts/fpga_build.py` (scripts/build.tcl + checks). Numbers are Vivado's reports for the
routed design, not estimates.

## Builds

| Commit | WNS / WHS (ns) | LUT | FF | BRAM tiles | DSP | Checks failed |
| --- | --- | --- | --- | --- | --- | --- |
| 960b44b (first) | +0.266 / +0.030 | 9,897 | 7,952 | 55 | 10 | Synth 8-6430 x8, DRC REQP-1839/1840 x40, CDC-10 x20, CDC-7, budgets |
| 6ca196e | +0.218 / +0.038 | 10,231 | 7,951 | 53 | 8 | CDC-10 x20, CDC-7, budgets |
| f11ea85 | **+0.652 / +0.048** | **10,235** | 7,992 | **53** | **8** | budgets only (LUT, BRAM) |

## What the first build showed, and the fixes

| Finding | Risk on the board | Fix | Proof |
| --- | --- | --- | --- |
| Synth 8-6430: the streamer's grid shadows inferred as block RAM | a store to the cell being copied in the same cycle reads differently on the chip than in simulation: wrong FRAME cells | distributed RAM (as the spec intended); shadows start at 0 | tb_result_streamer: a mutant with block-RAM (write-first) behaviour fails |
| `cur_row * 192` in two DSPs | none (budget: 10 DSP) | shifts and an add | DSP = 8 |
| REQP-1839/1840 x40: `rst`, asserted asynchronously by BTNC, drives block RAM address / enable logic | a press between clock edges can corrupt a memory write (every demo step starts with BTNC) | `rst` fully synchronous (clk_rst 1.0.1) | tb_clk_rst: the old version fails; 0 REQP warnings |
| CDC-10 x20: the VIO override mux between each pin and its first flop; CDC-7: BTNC through it into an asynchronous set | glitches from logic in front of a synchroniser | every pin synchronised first, then the mux (vio_hook 1.0.1) | tb_vio_hook (new: the spec named it, it did not exist); 0 critical CDC |

Remaining methodology warnings: LUTAR-1 (4, inside Xilinx's debug hub), SYNTH-10 (the core
multipliers, 4 DSP each as designed), SYNTH-5/6/15 (RAM mapping notes), XDCH-2 (the zero I/O
delays of rtl/board/nexys_a7.xdc, set on purpose: every pin is asynchronous).

## Where the resources go (f11ea85)

| Block | LUT | RAMB36 | RAMB18 | DSP |
| --- | --- | --- | --- | --- |
| core 0 / core 1 (each with its I-cache) | 2,867 / 2,716 | 0 | 4 / 4 | 4 / 4 |
| D-cache (data + tags in BRAM) | 1,582 | 0 | 8 | 0 |
| result_streamer (IMAGE, C in BRAM; grids in LUT RAM) | 1,215 | 8 | 1 | 0 |
| DMEM 128 KB / IMEM 16 KB | - | 32 / 4 | 0 | 0 |
| VIO hook + JTAG debug hub | 328 + 449 | 0 | 0 | 0 |
| everything else (arbiter, decode, MMIO, counters, config, 7-seg, UART) | about 1,100 | 0 | 2 | 0 |
| **Total** | **10,235** (16.1 % of 63,400) | **53 tiles** (39.3 % of 135) | | **8** |

## Budgets (first estimates: LUT <= 9,500, BRAM <= 49, DSP = 8)

DSP meets its target. LUT and BRAM do not:
* BRAM 53 vs 49: reaching 49 means moving the I-cache and D-cache tags out of block RAM
  (D-cache spec: "tags and data in BRAM"), changing two verified caches for a figure of the
  report; it would add about 180 LUTs.
* LUT 10,235 vs 9,500: 777 of them are the VIO hook and debug hub that the board regression needs; without them the design is 9,458. The grid shadows in LUT RAM, the fix
  for the board/simulation difference, cost 334.
The submitted report's figures ("<= 37 % BRAMs (49 blocks)", 36.3 %) were estimates;
the measured values above replace them. Decision on the budgets: Divyam's (scripts/fpga_budget.txt).
