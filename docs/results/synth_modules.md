# Per-module synthesis results (out of context)

`scripts/synth_ooc.tcl`: synthesis, placement and routing of one module alone on xc7a100tcsg324-1,
clock `clk` at 20 ns (50 MHz), 30 % of the period as input/output delay. Vivado 2025.2 post-route
numbers (a measurement of the netlist, not of the board). Each row names the commit it was run at;
rows at d43e071 are the current modules (mul.v and div.v behind the mul_unit / div_unit adapters,
the write-back-only D-cache with plru, the I-cache with fifo).

| Module | Commit | WNS (ns) | WHS (ns) | LUT | FF | BRAM | DSP | Latches | Check |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| mul_unit | d43e071 | +6.715 | +0.204 | 83 | 40 | 0 | 4 | 0 | <= 4 DSP48E1, WNS >= 0: PASS |
| div_unit | d43e071 | +8.973 | +0.151 | 377 | 172 | 0 | 0 | 0 | WNS >= 0: PASS |
| core, first version (one core, no I-cache) | c6fdf46 + core | +0.757 | +0.144 | 2,158 | 1,472 | 0 | 4 | 0 | no latches, no multi-driven nets, WNS >= 0: PASS |
| dmem_bram (128 KB) | b986de4; again at d43e071 (same result) | +9.565 | +5.511 | 18 | 0 | 32 (RAMB36E1 only) | 0 | 0 | 32 RAMB36 as specified: PASS |
| imem_bram (16 KB, 2 read ports) | b986de4 + imem_bram | +9.565 | +5.556 | 0 | 0 | 4 (RAMB36E1 only) | 0 | 0 | block RAM (updatemem-ready): PASS |
| dcache (4 KB, 4-way, write-back) | d43e071 | +1.863 | +0.110 | 1,477 | 853 | 8 RAMB18 (4 data + 4 tag) = 4 tiles | 0 | 0 | data and tags in BRAM, WNS >= 0: PASS |
| core with its I-cache and I-side mem_delay | d43e071 | +2.127 | +0.144 | 2,549 | 1,923 | 2 tiles (I-cache data + tags) | 4 | 0 | WNS >= 0: PASS |

Core: the first run (same commit, fetch address held by `interlock`) failed at
WNS -1.152 ns. Worst path: `d_rdata` (input) -> load extension -> forwarding -> branch compare
-> squash -> interlock gating -> IF hold mux -> `imem_addr` (output), 16 logic levels. Fixed in
the RTL, not the clock: hazard_unit's new `if_hold` (spec 1.0.1) does not wait for the squash.
The worst path was then `imem_rdata` -> decoder -> distance-1 compare -> `imem_addr`, 8 levels.
At d43e071 (core with I-cache) it is `d_rdata` (input) -> load extension -> forwarding -> branch
compare -> the fetch-PC register's enable, 16 levels, slack +2.127 ns.
Both ends are ports here with 30 % of the period as external delay; inside the SoC they are a
BRAM output and a BRAM address.

D-cache: the first run (commit 475f37b) put the tags in 5,632 flip-flops (6,825 FF,
4,160 LUT, WNS +0.760 ns): a 2-D tag array read in the same always block as the reset loops is
not inferred as memory. One 64 x 22 RAM per way (as the spec's "tags and data in BRAM")
gives 4 more RAMB18 and 988 FF (WNS +0.545 ns). At d43e071 (write-back only, no way mask) the
worst path is tag RAM -> tag compare -> `m_addr`, 7 levels, slack +1.863 ns.

dmem_bram reads `dmem.hex` with $readmemh: run it with that file in the output directory
(`-out`), as the full build does; without it Vivado 2025.2 stops with an access violation.
