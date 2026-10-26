# core_ctrl (spec v1.0)

| Item | Value |
| --- | --- |
| File | rtl/soc/core_ctrl.v |
| Testbench | tb/tb_core_ctrl.v |
| Vectors | directed |
| Interfaces | IF-D (`cfg[2]` DUAL) |
| Removal parameter | `HAS_CORE1` = 0: core 1 is never released and is not built |

## Purpose
Releases core 0 with the system reset, and core 1 only when DUAL = 1; tells the MMIO block how
many cores run.

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 each | |
| `cfg_dual` | in | 1 | `cfg[2]` |
| `rst_core0`, `rst_core1` | out | 1 each | per-core resets |
| `ncores` | out | 2 | 1 or 2 (NCORES register, barrier count) |

## Behaviour
1. `rst_core0` = `rst`. `rst_core1` = `rst` | !`cfg_dual` | !`HAS_CORE1`.
2. Both cores leave reset in the same cycle when DUAL = 1 (they start together at PC 0).
3. A core held in reset makes no IF-A requests, retires nothing (INSTRET = 0) and is
   not counted by the barrier.

## Reset values
Both core resets high during `rst`.

## Tests
DUAL = 0: core 1 stays in reset, `ncores` = 1; DUAL = 1: both release in the same cycle,
`ncores` = 2. PASS = all checks.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version |
