# Lab 5A baseline on the board

| Item | Value |
| --- | --- |
| Date | 16 Oct 2026 |
| Commit | 0e79801 (lab core in `rtl/lab5a`, unchanged since the two fixes ccb7e2a, 629fb60) |
| Build | `vivado -mode batch -source scripts/build.tcl -tclargs -f sim/lab5a_top.f -top top_fpga -xdc rtl/lab5a/constraint.xdc -hex tb/lab5a/image` |
| Image | `tb/lab5a/image` (t_lab5a.S; the lab repo has no program of its own) |
| Part | xc7a100tcsg324-1, found on JTAG as xc7a100t_0 (Nexys A7-100T) |
| Programming | `scripts/program.tcl` over JTAG, DONE pin high (log `build/logs/step007_program.log`) |

## Implementation results (Vivado 2025.2)

| WNS | WHS | LUT | FF | BRAM tiles | DSP | Critical warnings |
| --- | --- | --- | --- | --- | --- | --- |
| +5.498 ns | +0.337 ns | 2,726 | 1,305 | 1 | 0 | 0 |

Timing is on the 100 MHz board clock and the 1 Hz divider only: the lab's core clock is a
divided, unconstrained net. An earlier build of the same top gave WNS +5.612 ns and
LUT 2,593; that run's image is not recorded, and the data memory is LUTRAM whose logic depends
on its initial contents, so the difference was not investigated further. This is not a 50 MHz
core result; that comes with the SPECTRA top.

## Board behaviour (observed by Divyam)

Reset is on J15 = SW0, as in the lab. With SW0 up, all LEDs are off (fetch PC = 0). With SW0
down, LED[15:0] = fetch PC steps up by 4 once a second; the first lit pattern is LED2 (PC 4),
because `pc_out` is the fetch PC, which leaves 0 on the first 1 Hz edge after reset.
Verdict: behaves as in the lab.
