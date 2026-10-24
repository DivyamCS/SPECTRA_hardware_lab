# div_unit (spec v1.0)

| Item | Value |
| --- | --- |
| File | rtl/core/div_unit.v |
| Testbench | tb/tb_div_unit.v |
| Vectors | tb/vectors/div_vectors.mem from `tools/gen_vectors.py` |
| Interfaces | none |
| Removal parameter | `HAS_MD` = 0 removes it |

## Purpose
DIV, DIVU, REM and REMU with a radix-2 restoring divider: 32 iterations plus a sign fix, at most
34 cycles.

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 each | |
| `start` | in | 1 | 1-cycle pulse with valid operands |
| `op` | in | 2 | 0 DIV, 1 DIVU, 2 REM, 3 REMU (funct3[1:0]) |
| `a`, `b` | in | 32 each | dividend, divisor |
| `busy` | out | 1 | high from the cycle after `start` until `done` |
| `done` | out | 1 | 1-cycle pulse: `result` valid |
| `result` | out | 32 | quotient or remainder; held until the next `start` |

## Behaviour
1. `start` in cycle 0 -> `done` no later than cycle 33 (at most 34 cycles in EX). The count is
   fixed (no early exit), so cycle counts never depend on data.
2. Divide by zero: DIV and DIVU give 0xFFFFFFFF, REM and REMU give `a` (RISC-V spec).
3. Overflow INT_MIN / -1: DIV gives INT_MIN (0x80000000), REM gives 0.
4. `start` is ignored while `busy`; the unit never hangs.

## Reset values
`busy` = 0, `done` = 0, `result` = 0.

## Tests
All vector lines for all 4 operations including /0 and INT_MIN / -1; `done` always within 34
cycles; a watchdog fails the TB if `done` never comes. PASS = 0 mismatches.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version, approved by Divyam |
