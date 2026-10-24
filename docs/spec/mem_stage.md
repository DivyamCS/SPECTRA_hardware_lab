# mem_stage (spec v1.0)

| Item | Value |
| --- | --- |
| File | rtl/core/mem_stage.v (replaces the lab's direct BRAM ports; store/load formatting from wb.v) |
| Testbench | tb/tb_mem_stage.v |
| Vectors | directed + random accesses against a memory model with random `ready` delay |
| Interfaces | IF-A master |
| Removal parameter | none |

## Purpose
The MEM/WB stage's memory side: turns a load or store in MEM/WB into one IF-A request, waits for
`ready`, formats store data and byte enables, extends load data, and produces the value written
back to the register file.

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 each | |
| EX/MEM fields | in | - | `valid`, `is_load`, `is_store`, `mem_size`, `load_unsigned`, `addr`, `store_data`, `rd`, `writes_rd`, `result` |
| `freeze` | in | 1 | `freeze` from hazard_unit: MEM/WB does not advance |
| IF-A master | out/in | - | `req`, `we`, `addr`, `wdata`, `be`, `rdata`, `ready` (interfaces.md section 1) |
| `dport_wait` | out | 1 | a request is open and `ready` has not come (to hazard_unit) |
| `wb_we`, `wb_rd`, `wb_data` | out | 1,5,32 | register write (to regfile; `wb_data` also to forwarding) |
| `retire` | out | 1 | an instruction leaves MEM/WB this cycle (INSTRET, commit trace) |

## Behaviour
1. A valid load or store raises `req` in its first MEM/WB cycle and holds every field until
   `ready`; loads to x0 issue a request too. Non-memory instructions retire in one cycle.
2. Stores: byte enables and lane placement as the lab's wb.v (SB one lane, SH two, SW four).
3. Loads: the word from `rdata` is shifted and sign/zero extended by `mem_size`, `load_unsigned`
   and `addr[1:0]` as the lab's wb.v.
4. Timing: a hit or MMIO access completes in the 2nd MEM/WB cycle (1 stall); longer waits come
   from the slave. `dport_wait` = `req` & !`ready`.
5. The `ready` cycle retires the instruction; the next instruction may raise `req` in the
   following cycle.
6. If `ready` comes in a cycle frozen for another reason (fetch path waiting), the access is
   complete: the loaded word is kept and `req` is not raised again. `wb_we` and `retire` are
   raised only in the cycle the instruction leaves MEM/WB (`freeze` = 0), once per instruction.

## Reset values
`req` = 0; no instruction in flight.

## Tests
Every load/store size and alignment; sign and zero extension; `ready` after 1, 2 and random
1-20 cycles with fields held stable; back-to-back accesses; load to x0 issues a request.
PASS = 0 mismatches against the memory model.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version, approved by Divyam |
| 1.0.1 | 16 Oct 2026 | input `freeze` and behaviour 6 (ready during a fetch-wait freeze; write and retire once). Approved by Divyam, 16 Oct 2026 |
