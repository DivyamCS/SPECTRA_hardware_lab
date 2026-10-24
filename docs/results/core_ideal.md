# One core on ideal memory

`tb/core/run.py`: `tb_core` (core + 16 KB IMEM with a 1-cycle read + 128 KB data memory whose
`ready` comes in cycle 2 + MMIO stub) against rv32sim with the same CONFIG. PASS = the run
ends at the CHECKSUM write with rv32sim's checksum (which rv32sim checks against
`fw/golden.h`) and `tools/tracecmp.py` finds 0 differences. RTL cycles are xsim cycle counts on
ideal memory: a simulation of the netlist's behaviour, not a board measurement. The rv32sim
cycle counts for these configs model the D-cache and L = 8 and are not comparable.

Final RTL: the core as committed (hazard_unit with `if_hold`).

| Program | CONFIG | FWD | Checksum (golden) | RTL cycles | Instructions compared | Trace |
| --- | --- | --- | --- | --- | --- | --- |
| t_hazard | 0093 / 0092 | 1 / 0 | 0x00000000 (count check OK) | 630 / 671 | 452 | 0 differences |
| t_mext | 0093 / 0092 | 1 / 0 | 0xD7A9B563 | 241,270 / 266,518 | 45,189 | 0 differences |
| MatMul | 00F3 / 00F2 | 1 / 0 | 0xC063A00F | 571,859 / 648,712 | 307,567 | 0 differences |
| Mandelbrot, halves | 00B3 / 00B2 | 1 / 0 | 0x22B8E929 | 12,462,369 / 14,749,072 | 7,750,961 | 0 differences |
| Mandelbrot, interleaved | 00D3 / 00D2 | 1 / 0 | 0x22B8E929 | 12,462,327 / 14,749,029 | 7,750,958 | 0 differences |
| Game of Life | 0093 / 0092 | 1 / 0 | 0xA556EEC3 | 66,847,314 / 85,808,208 | 46,920,121 | 0 differences |

FWD = 0 costs cycles on every program (the 1-cycle interlock per distance-1 dependence).
Logs: `build/logs/step051_runs.log`; run directories `build/<commit>/core/<image>_<config>/`.

xsim speed on this laptop: about 75,000 core cycles per second, so a full Game of Life run takes
about 17 minutes. A shortened Game of Life was not needed.
MatMul, t_hazard and t_mext are in `sim/tests.txt`; Mandelbrot and Game of Life are re-run at
merges with `python tb/core/run.py demo 00b3 00d3 0093` (add the FWD = 0 configs as needed).
