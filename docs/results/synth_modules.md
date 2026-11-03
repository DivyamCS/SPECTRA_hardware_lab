# Per-module synthesis results (out of context)

`scripts/synth_ooc.tcl -f sim/<module>_synth.f -top <module>`: synthesis, placement and routing of
one module alone on xc7a100tcsg324-1, clock `clk` at 20 ns (50 MHz), 30 % of the period as
input/output delay. Vivado 2025.2 post-route numbers.

| Module | WNS (ns) | WHS (ns) | LUT | FF | BRAM | DSP | Latches | Check |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| mul_unit (mul.v behind the adapter) | +6.715 | +0.204 | 83 | 40 | 0 | 4 | 0 | <= 4 DSP48E1, WNS >= 0: PASS |
| div_unit (div.v behind the adapter) | +8.973 | +0.151 | 377 | 172 | 0 | 0 | 0 | WNS >= 0: PASS |
| dmem_bram (128 KB) | +9.565 | +5.511 | 18 | 0 | 32 (RAMB36E1 only) | 0 | 0 | 32 RAMB36 as specified: PASS |
| imem_bram (16 KB, 2 read ports) | +9.565 | +5.556 | 0 | 0 | 4 (RAMB36E1 only) | 0 | 0 | block RAM (updatemem-ready): PASS |
| dcache (4 KB, 4-way, write-back) | +1.863 | +0.110 | 1,477 | 853 | 4 tiles (4 data + 4 tag RAMB18) | 0 | 0 | data and tags in BRAM, WNS >= 0: PASS |
| core with its I-cache and I-side mem_delay | +2.127 | +0.144 | 2,549 | 1,923 | 2 tiles (I-cache data + tags) | 4 | 0 | WNS >= 0: PASS |

Worst paths: core: `d_rdata` (input) -> load extension -> forwarding -> branch compare -> the
fetch-PC register's enable, 16 logic levels. dcache: tag RAM -> tag compare -> `m_addr`, 7 levels.
Both ends are ports here with 30 % of the period as external delay; inside the SoC they are a BRAM
output and a BRAM address.

dmem_bram reads `dmem.hex` with $readmemh: run it with that file in the output directory (`-out`),
as the full build does; without it Vivado 2025.2 stops with an access violation.
