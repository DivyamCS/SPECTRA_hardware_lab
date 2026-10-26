# clk_rst (spec v1.0.1)

| Item | Value |
| --- | --- |
| File | rtl/soc/clk_rst.v |
| Testbench | tb/tb_clk_rst.v (behavioural MMCM model in simulation) |
| Vectors | directed |
| Interfaces | none |
| Removal parameter | none |

## Purpose
Makes the 50 MHz system clock from the board's 100 MHz oscillator with an MMCM, and the system
reset from BTNC: active high, held until the MMCM locks, synchronised to the 50 MHz clock.

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk100` | in | 1 | board clock, pin E3 |
| `btn_rst` | in | 1 | BTNC (N17) after vio_hook (2-flop synchroniser, then the VIO override mux); active high, clk domain |
| `clk` | out | 1 | 50 MHz (MMCME2_BASE, BUFG) |
| `rst` | out | 1 | synchronous to `clk`, active high |
| `locked` | out | 1 | MMCM lock |

## Behaviour
1. `rst` = 1 from 2-3 `clk` cycles after `btn_rst` = 1 or `locked` = 0 until at least 16 `clk`
   cycles after both clear. No asynchronous set or reset anywhere: a 2-flop synchroniser
   (ASYNC_REG) samples `btn_rst || !locked`, and `rst` is a plain `clk` register. A button press
   (milliseconds) is always seen. (Version 1.0 asserted `rst` asynchronously; it drives block RAM
   address and enable logic, where an edge between clocks can corrupt a write: Vivado DRC
   REQP-1839/1840; and its asynchronous input passed the VIO mux first: CDC-7.)
2. Replaces the lab's register-divided 1 Hz clock, which Vivado could not time (lab build:
   2,302 unclocked pins). The 100 MHz input clock and the generated 50 MHz clock are both
   constrained.

## Reset values
`rst` = 1 at power-up until lock.

## Tests
`rst` stays high until lock, releases 16 cycles later on a `clk` edge; a one-cycle pulse on
`btn_rst` produces a full reset, with `rst` rising on a `clk` edge within 3 edges; a press holds
`rst`. PASS = timing as specified.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version |
| 1.0.1 | 16 Oct 2026 | Fully synchronous reset (2-flop synchroniser of `btn_rst` or `!locked`; `btn_rst` now synchronised in vio_hook), after DRC REQP-1839/1840 and CDC-7 on the first full FPGA build. |
