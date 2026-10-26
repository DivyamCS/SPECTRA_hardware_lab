# regfile (spec v1.0)

| Item | Value |
| --- | --- |
| File | rtl/core/regfile.v |
| Testbench | tb/tb_regfile.v |
| Vectors | directed + 10,000 random read/write cycles against a behavioural model |
| Interfaces | none |
| Removal parameter | none |

## Purpose
32 x 32-bit register file, x0 = 0, with two read ports used in ID and one write port used by
MEM/WB. Write-through: a register written in a cycle is read with its new value in that same
cycle (PROTOCOL.md section 1). This covers dependences at distance 2; distance 1 is covered by
forwarding (hazard_unit).

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 each | |
| `raddr1`, `raddr2` | in | 5 each | read addresses (ID) |
| `rdata1`, `rdata2` | out | 32 each | read data, combinational |
| `we` | in | 1 | write enable (MEM/WB retires an instruction that writes rd) |
| `waddr` | in | 5 | destination |
| `wdata` | in | 32 | value |

## Behaviour
1. `rdata` = 0 when `raddr` = 0.
2. `rdata` = `wdata` when `we` and `waddr` = `raddr` != 0 (write-through), else the stored value.
3. Writes to x0 are dropped. The write happens on the rising edge.
4. **Structural change from lab 5A:** the lab reads the register array in EX (from registered
   selects) with a MEM/WB bypass, which merges forwarding and write-through into one path. In
   SPECTRA the read happens in ID and the operands are latched in ID/EX, so FWD = 0 can remove
   forwarding while write-through stays (rv32sim's faults `stale1` and `stale2` are separate).

## Reset values
x1-x31 = 0 (as lab 5A and rv32sim's initial state).

## Tests
Same-cycle write and read of one register returns the new value (both ports); x0 always 0
even when written; random sequence against the model. PASS = 0 mismatches.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version |
