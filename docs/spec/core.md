# core (wrapper) (spec v1.0)

| Item | Value |
| --- | --- |
| File | rtl/core/core.v (replaces the lab's pipe.v as the core top) |
| Testbench | tb/tb_core.v (core + ideal memories + MMIO stub; programs t_hazard, t_mext, demo) |
| Vectors | reference commit traces tb/ref/ from rv32sim |
| Interfaces | IF-A master (data port), IF-D (`cfg`), IMEM read port |
| Removal parameter | none (its submodules carry theirs) |

## Purpose
One 3-stage RV32IM core: IF/ID, EX, MEM/WB. Only instantiates and connects decoder, regfile,
hazard_unit, execute, mem_stage, icache and the I-side mem_delay, plus the three pipeline
registers (ID/EX, EX/MEM and the fetch PC) with a valid bit each.

## Parameters
| Name | Default | Meaning |
| --- | --- | --- |
| `HART_ID` | 0 | core number; core 1 is the same RTL with `HART_ID` = 1 |

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 each | `rst` held for core 1 while DUAL = 0 (core_ctrl) |
| `cfg` | in | 16 | IF-D config word |
| IF-A master | out/in | - | `d_req`, `d_we`, `d_addr`, `d_wdata`, `d_be`, `d_rdata`, `d_ready` |
| `imem_addr`, `imem_rdata` | out/in | 12, 32 | word address into imem_bram (port A or B), 1-cycle read |
| `ev_instret`, `ev_ihit`, `ev_imiss` | out | 1 each | 1-cycle event pulses (perf_counters) |

## Behaviour
1. Both cores start at PC 0 when `rst` releases. The first cycle after reset is a bubble (lab
   fix B1: the fetch path has no valid instruction yet).
2. Stage timing and stalls come from hazard_unit; a taken branch, JAL or JALR squashes the 2
   younger instructions (2 extra cycles).
3. `ev_instret` pulses once per retired (non-squashed, non-bubble) instruction.
4. Simulation only (`ifdef SIM`): one commit-trace line per retired instruction in the format of
   PROTOCOL.md section 8, written by MEM/WB to `trace_rtl<HART_ID>.txt`; synthesis sees
   none of it.

## Reset values
Fetch PC = 0; every valid bit 0; regfile cleared.

## Tests
tb_core runs t_hazard (FWD = 1 and 0), t_mext, MatMul, Game of Life and Mandelbrot on ideal
memory; the run ends at the CHECKSUM write; a watchdog fails it after 100,000 cycles with no
retired instruction. PASS = golden checksum and 0 trace differences against rv32sim.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version |
