# top_fpga and soc_top (wrappers) (spec v1.1)

| Item | Value |
| --- | --- |
| Files | rtl/top_fpga.v (board pins, VIO, clk_rst), rtl/soc_top.v (everything clocked by `clk`, no pins) |
| Constraints | constraints/nexys_a7.xdc (the lab's constraint.xdc stays for the baseline) |
| Testbench | tb/tb_top.v drives soc_top |
| Interfaces | all four |
| Removal parameter | passes `HAS_*` down to the modules |

## Purpose
`soc_top` connects the two cores, core_ctrl, rr_arbiter, addr_decode, dcache, mem_delays,
dmem_bram, imem_bram, mmio_bus, lock_barrier, perf_counters, result_streamer, uart_top,
seg7_bcd and switch_cfg. `top_fpga` adds clk_rst, vio_hook and the board pins. Wrappers only
instantiate and connect (modular rule).

## Ports (top_fpga, Nexys A7-100T)
| Port | Pin(s) | Meaning |
| --- | --- | --- |
| `CLK100MHZ` | E3 | 100 MHz oscillator |
| `BTNC`, `BTNL`, `BTNR`, `BTNU`, `BTND` | N17, P17, M17, M18, P18 | BTNC = reset |
| `SW[15:0]` | Nexys A7 master XDC | slide switches |
| `LED[15:0]` | Nexys A7 master XDC | LEDs; LED2 = `decode_err` |
| `AN[7:0]`, `CA`-`CG`, `DP` | Nexys A7 master XDC | 7-segment |
| `UART_RXD_OUT` | D4 | UART transmit (board to laptop) |

## Behaviour
1. One clock domain (50 MHz) inside; switches and buttons enter through synchronisers only.
2. LED[15:0] = LEDS register, except LED2 = `decode_err`.
3. Constraints: `create_clock` 10 ns on E3; the MMCM output is a generated clock checked
   by Vivado; false paths only on the synchronised asynchronous inputs; no unconstrained paths.

## Reset values
As each module.

## Tests
tb_top runs every program on 1 and 2 cores with the UART line decoded in Python; board steps
114-122 compare board cycle counts with tb_top's. PASS = golden checksums, equal counters.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version, approved by Divyam |
| 1.1 | 17 Oct 2026 | soc_top output `seg7_txt` (mmio_bus to seg7_bcd and the VIO hook). Divyam's request (17 Oct, demo): labelled 7-segment tour. Approved by Divyam (his request) |
