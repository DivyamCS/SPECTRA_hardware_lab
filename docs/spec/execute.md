# execute (spec v1.0)

| Item | Value |
| --- | --- |
| File | rtl/core/execute.v (from the lab's execute.v, now rtl/lab5a/execute.v; the EX/MEM register moves to the core wrapper) |
| Testbench | tb/tb_execute.v |
| Vectors | directed; ALU results checked against a behavioural model |
| Interfaces | none |
| Removal parameter | `HAS_MD` (MUL/DIV instances) |

## Purpose
The EX stage datapath: operand forwarding muxes, ALU, branch decision and target, load/store
address, MUL/DIV beside the ALU and the result mux.

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 each | (for mul_unit / div_unit) |
| ID/EX fields | in | - | `valid`, `pc`, `rs1_val`, `rs2_val`, `imm`, and the decoder's control bits |
| `fwd_a`, `fwd_b`, `mw_result` | in | 1,1,32 | forwarding selects and the MEM/WB result |
| `freeze` | in | 1 | `freeze` from hazard_unit: do not start MUL/DIV; EX is held |
| `result` | out | 32 | ALU result, pc + 4 for JAL/JALR, imm for LUI, pc + imm for AUIPC, MUL/DIV result |
| `taken` | out | 1 | valid taken branch, JAL or JALR |
| `target` | out | 32 | redirect PC (JALR: bit 0 cleared) |
| `mem_addr` | out | 32 | rs1 + imm for loads and stores |
| `store_data` | out | 32 | rs2 (after forwarding), unformatted |
| `md_busy` | out | 1 | a MUL/DIV in EX has not finished (to hazard_unit) |

## Behaviour
1. Operand A = `fwd_a` ? `mw_result` : `rs1_val`; B likewise with rs2 (store data uses B).
2. ALU as lab 5A with the SRA fix (signed shift evaluated self-determined).
3. MUL/DIV: when an `is_md` instruction is valid in EX and not frozen, `start` the unit in that
   cycle, once per instruction; `md_busy` stays high until `done`; the result is taken on `done`,
   and kept (no second start) if a freeze holds EX in or after the done cycle. A MUL that enters EX
   during a load stall starts in the cycle after the stall ends (timing diagram).
4. Branch condition from signed / unsigned compares of A and B (BEQ BNE BLT BGE BLTU BGEU).

## Reset values
Only inside mul_unit / div_unit.

## Tests
Every ALU op with edge values (0, -1, INT_MIN, INT_MAX, shift 0 and 31); every branch taken and
not taken; JALR target bit 0 cleared; MUL entering during a stall starts the next cycle;
DIV holds `md_busy` for its whole run. PASS = 0 mismatches.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version |
| 1.0.1 | 16 Oct 2026 | input `stall` (freeze or interlock) becomes `freeze`. The unit must know when EX moves (not frozen, not busy) to clear its started/finished flags, and an interlock never coincides with a start (it requires md_busy = 0). Start once per instruction; result kept under a freeze. |
