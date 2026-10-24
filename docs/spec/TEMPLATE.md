# <module> (spec v1.0)

| Item | Value |
| --- | --- |
| File | rtl/<area>/<module>.v |
| Testbench | tb/tb_<module>.v (prints one `PASS <module>` / `FAIL <module>` line) |
| Vectors | tb/vectors/<file> from <Python model>, or "directed" |
| Interfaces | <IF-A/B/C/D role, or none> |
| Removal parameter | <`HAS_X` = 0 removes the hardware (area builds), or none> |

## Purpose
One or two sentences: what the module does and why SPECTRA needs it.

## Parameters
| Name | Default | Meaning |

## Ports
| Port | Dir | Width | Meaning |
(`clk` and `rst` on every module unless it is purely combinational.)

## Behaviour
Cycle-level rules, numbered. Every timing number refers to PROTOCOL.md or interfaces.md.

## Reset values
Every register and output after `rst`.

## Tests
The test list the testbench must cover, and its pass criterion.

## Change log
| Version | Date | Change |
