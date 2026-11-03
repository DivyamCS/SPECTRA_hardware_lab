# Lab 5A baseline on the board

The lab 5A core (`rtl/lab5a`, with its two marked fixes) built for the board unchanged, as the
starting point.

| Item | Value |
| --- | --- |
| Build | `vivado -mode batch -source scripts/build.tcl -tclargs -f sim/lab5a_top.f -top top_fpga -xdc rtl/lab5a/constraint.xdc -hex tb/lab5a/image` |
| Image | `tb/lab5a/image` (t_lab5a.S; the lab has no program of its own) |
| Part | xc7a100tcsg324-1 (Nexys A7-100T) |
| Programming | `scripts/program.tcl` over JTAG, DONE pin high |

## Implementation results (Vivado 2025.2)

| WNS | WHS | LUT | FF | BRAM tiles | DSP | Critical warnings |
| --- | --- | --- | --- | --- | --- | --- |
| +5.498 ns | +0.337 ns | 2,726 | 1,305 | 1 | 0 | 0 |

Timing covers the 100 MHz board clock and the 1 Hz divider only: the lab's core clock is a divided,
unconstrained net, so this is not a 50 MHz core result.

## Board behaviour

Reset is on J15 = SW0, as in the lab. With SW0 up, all LEDs are off (fetch PC = 0). With SW0 down,
LED[15:0] = fetch PC, stepping up by 4 once a second; the first lit pattern is LED2 (PC 4), because
`pc_out` is the fetch PC, which leaves 0 on the first 1 Hz edge after reset.
