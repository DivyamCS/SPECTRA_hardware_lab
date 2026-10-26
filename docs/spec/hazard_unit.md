# hazard_unit (spec v1.0)

| Item | Value |
| --- | --- |
| File | rtl/core/hazard_unit.v |
| Testbench | tb/tb_hazard_unit.v |
| Vectors | directed scenarios, each with FWD = 0 and FWD = 1 |
| Interfaces | IF-D (`cfg[0]` FWD) |
| Removal parameter | `HAS_FWD` = 0 removes the forwarding muxes (behaves as FWD = 0) |

## Purpose
Decides, every cycle, forwarding selects, the FWD = 0 interlock, the global freeze, the
MUL/DIV hold and the 2-instruction squash. Purely combinational.

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `fwd_en` | in | 1 | `cfg[0]` FWD (and `HAS_FWD`) |
| `id_valid`, `id_rs1`, `id_rs2`, `id_uses_rs1`, `id_uses_rs2` | in | 1,5,5,1,1 | instruction in ID |
| `ex_valid`, `ex_rs1`, `ex_rs2`, `ex_rd`, `ex_writes_rd` | in | 1,5,5,5,1 | instruction in EX |
| `mw_valid`, `mw_rd`, `mw_writes_rd` | in | 1,5,1 | instruction in MEM/WB |
| `ex_taken` | in | 1 | taken branch, JAL or JALR resolved in EX this cycle |
| `md_busy` | in | 1 | MUL/DIV in EX has not finished |
| `dport_wait` | in | 1 | MEM/WB has an IF-A request without `ready` |
| `ic_wait` | in | 1 | the fetch path has no instruction this cycle |
| `fwd_a`, `fwd_b` | out | 1 each | EX operand A / B (and store data = B) taken from the MEM/WB result |
| `interlock` | out | 1 | FWD = 0: hold IF and ID, bubble into EX |
| `freeze` | out | 1 | hold every stage (no register advances) |
| `ex_hold` | out | 1 | hold IF, ID and EX; MEM/WB advances and receives a bubble |
| `squash` | out | 1 | invalidate the 2 younger instructions (IF/ID and the fetch in flight) |
| `if_hold` | out | 1 | IF re-reads the ID address: `freeze` \| `ex_hold` \| distance-1 dependence (FWD = 0), not gated by `squash` |

## Behaviour
1. **Forwarding (FWD = 1):** `fwd_a` = `ex_valid` & `mw_valid` & `mw_writes_rd` & `mw_rd` != 0 &
   `mw_rd` = `ex_rs1`; same for `fwd_b` with `ex_rs2`. Distance 2 needs nothing (regfile is
   write-through).
2. **Interlock (FWD = 0):** `interlock` = `id_valid` & `ex_valid` & `ex_writes_rd` & `ex_rd` != 0 &
   ((`id_uses_rs1` & `ex_rd` = `id_rs1`) | (`id_uses_rs2` & `ex_rd` = `id_rs2`)). Exactly 1 extra
   cycle per distance-1 dependence (PROTOCOL.md section 7); `fwd_a` = `fwd_b` = 0.
3. **Freeze:** `freeze` = `dport_wait` | `ic_wait`. Nothing advances; the pipeline resumes in the
   cycle after the cause clears, with no instruction lost or repeated.
4. **MUL/DIV hold:** `ex_hold` = `md_busy` & !`freeze`: the MUL/DIV stays in EX, the instruction
   in MEM/WB finishes, a bubble enters MEM/WB.
5. **Squash:** `squash` = `ex_taken` & !`freeze` & !`ex_hold`. A branch in EX during a freeze
   redirects only once unfrozen. Squashed instructions never write a register, store,
   start MUL/DIV, issue on IF-A or count as retired.
6. Priority: `freeze` > `ex_hold` > `squash` > `interlock`.
7. **Fetch hold:** `if_hold` = `freeze` | `ex_hold` | the ungated distance-1 condition of item 2.
   It does not wait for the branch decision: if a squash and a dependence meet, IF re-reads the
   ID address, that fetch is dropped by the squash and the fetch PC takes the target (load data -> forwarding -> branch -> squash -> fetch address missed 50 MHz by 1.15 ns).

## Reset values
None (combinational).

## Tests
Distance-1 and distance-2 ALU and load dependences for rs1, rs2 and store data, with FWD = 0
and 1 (FWD = 0 costs exactly 1 cycle per distance-1 case); x0 never forwarded or interlocked;
freeze during a forwarded pair; branch in EX during a freeze; MUL in EX while a load waits.
PASS = every scenario's select/stall pattern equals the expected table.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version |
| 1.0.1 | 16 Oct 2026 | output `if_hold` (behaviour 7) for timing; the other outputs unchanged |
