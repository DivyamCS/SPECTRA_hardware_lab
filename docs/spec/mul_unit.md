# mul_unit (spec v1.0)

| Item | Value |
| --- | --- |
| File | rtl/core/mul_unit.v |
| Testbench | tb/tb_mul_unit.v |
| Vectors | tb/vectors/mul_vectors.mem from `tools/gen_vectors.py` (40,676 lines) |
| Interfaces | none |
| Removal parameter | `HAS_MD` = 0 removes it (M instructions then flagged illegal) |

## Purpose
MUL, MULH, MULHSU and MULHU on the DSP48 slices, at most 3 cycles.

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 each | |
| `start` | in | 1 | 1-cycle pulse with valid operands |
| `op` | in | 2 | 0 MUL, 1 MULH, 2 MULHSU, 3 MULHU (funct3[1:0]) |
| `a`, `b` | in | 32 each | rs1, rs2 values |
| `busy` | out | 1 | high from the cycle after `start` until `done` |
| `done` | out | 1 | 1-cycle pulse: `result` valid |
| `result` | out | 32 | product low (MUL) or high word; held until the next `start` |

## Behaviour
1. `start` in cycle 0 -> `done` in cycle 2 (3 cycles in EX, PROTOCOL.md section 7).
2. 33 x 33-bit signed multiply of the sign- or zero-extended operands, pipelined across the DSP
   input and output registers.
3. `start` is ignored while `busy`. The core starts it only when not frozen.

## Reset values
`busy` = 0, `done` = 0, `result` = 0.

## Tests
All vector lines (edge cases and random pairs) for all 4 operations; every result exactly
3 cycles after `start`. PASS = 0 mismatches.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version, approved by Divyam |
