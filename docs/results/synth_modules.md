# Per-module synthesis results (out of context)

`scripts/synth_ooc.tcl`: synthesis, placement and routing of one module alone on xc7a100tcsg324-1,
clock `clk` at 20 ns (50 MHz), 30 % of the period as input/output delay. Vivado 2025.2 post-route
numbers (a measurement of the netlist, not of the board). Each row names the commit it was run at.

| Module | Commit | WNS (ns) | WHS (ns) | LUT | FF | BRAM | DSP | Latches | Check |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| mul_unit | 4e25d24 | +7.176 | +0.380 | 83 | 38 | 0 | 4 | 0 | <= 4 DSP48E1, WNS >= 0: PASS |
| div_unit | c564e54 + div_unit | +6.568 | +0.184 | 290 | 106 | 0 | 0 | 0 | WNS >= 0: PASS |
| core (one core, no I-cache) | c6fdf46 + core | +0.757 | +0.144 | 2,158 | 1,472 | 0 | 4 | 0 | no latches, no multi-driven nets, WNS >= 0: PASS |
| dmem_bram (128 KB) | b986de4 + dmem_bram | +9.565 | +5.511 | 18 | 0 | 32 (RAMB36E1 only) | 0 | 0 | 32 RAMB36 as specified: PASS |
| imem_bram (16 KB, 2 read ports) | b986de4 + imem_bram | +9.565 | +5.556 | 0 | 0 | 4 (RAMB36E1 only) | 0 | 0 | block RAM (updatemem-ready): PASS |
| dcache (4 KB, 4-way) | 475f37b + dcache tag RAMs | +0.545 | +0.118 | 1,714 | 988 | 8 RAMB18 (4 data + 4 tag) = 4 tiles | 0 | 0 | data in 4 BRAMs as estimated, tags in BRAM, WNS >= 0: PASS |
| core with its I-cache and I-side mem_delay | d405670 | +1.169 | +0.096 | 2,627 | 1,857 | 2 tiles (I-cache data + tags) | 4 | 0 | WNS >= 0: PASS |

Core: the first run (same commit, fetch address held by `interlock`) failed at
WNS -1.152 ns. Worst path: `d_rdata` (input) -> load extension -> forwarding -> branch compare
-> squash -> interlock gating -> IF hold mux -> `imem_addr` (output), 16 logic levels. Fixed in
the RTL, not the clock: hazard_unit's new `if_hold` (spec 1.0.1) does not wait for the squash.
The worst path is now `imem_rdata` -> decoder -> distance-1 compare -> `imem_addr`, 8 levels.
Both ends are ports here with 30 % of the period as external delay; inside the SoC they are a
BRAM output and a BRAM address.

D-cache: the first run (commit 475f37b) put the tags in 5,632 flip-flops (6,825 FF,
4,160 LUT, WNS +0.760 ns): a 2-D tag array read in the same always block as the reset loops is
not inferred as memory. One 64 x 22 RAM per way (as the spec's "tags and data in BRAM")
gives 4 more RAMB18 and 988 FF. Worst path now: cfg_ways -> free-way select -> victim tag ->
m_addr (6 levels); cfg is constant for a run, so this path could be declared false later.
