# Lab 5A files: the starting point

Source: Divyam's repo https://github.com/DivyamCS/SPECTRA_hardware_lab (commit d335f25,
"Added 3-stage pipeline files ( initial )"), received 16 Oct 2026. Files are copied here unchanged;
`SHA256SUMS.txt` proves they are byte-identical.

| File | Contents |
| --- | --- |
| pipe.v | Core top: includes IF_ID.v, execute.v, wb.v; register file with WB-to-ID bypass (write-through); PC logic |
| IF_ID.v | Fetch/decode, immediates, illegal-instruction and misaligned-fetch exception; module id_ex_reg |
| execute.v | ALU, branches, jumps; module ex_mem_wb_reg |
| wb.v | Store byte/half/word formatting, load alignment, stall logic |
| memory.v | instr_mem (4 KB, $readmemh imem.hex) and data_mem (4 KB, $readmemh dmem.hex, byte strobes, 1-cycle read) |
| tb_pipeline.v | 100 MHz clock, reset, 20 us run; no self-check |
| top_fpga.v | Board top: 100 MHz divided to a 1 Hz core clock; LED[15:0] = PC[15:0] |
| constraint.xdc | clk E3; reset J15; LED0-15 |
| opcode.vh | RV32I opcode and funct3 constants (no M extension yet) |

Checks (Verilator 5.48):

* `verilator --lint-only -Wall --top-module pipe pipe.v`: **no errors**; only style warnings
  (unused signals and parameters, file name differs from extra module names, missing final newline).
* Every lab TODO is filled in (the TODO comments remain).

What this meant for SPECTRA (details in `docs/spec/core_gap.md`):

1. **No test program or golden outputs.** `imem.hex` and `dmem.hex` are not in the repo, and the
   testbench has no checker. SPECTRA therefore builds an RV32I-only test image with the kit's
   toolchain, runs it on the lab core (with a 4 KB-wrapped address map) and compares the commit
   trace with `rv32sim`, instead of diffing against lab golden outputs. 
2. **Reset is on J15, which is switch SW0 on the Nexys A7.** SPECTRA uses SW0 as FWD and BTNC
   (N17) as reset. The new XDC moves reset to BTNC; the baseline build keeps
   J15 so the board behaves exactly as in the lab.
3. **Core clock is 1 Hz** (divider in top_fpga.v) and the board shows PC on the LEDs. On the board the
   LEDs step through the PC once per second, as in the lab.
4. **Memory interface**: separate read and write ports with read/write enables and no ready
   handshake (`inst_mem_is_valid`, `dmem_read_valid` are tied to 1 and unused). SPECTRA adds
   the IF-A handshake and global freeze.
5. **No M extension** in opcode.vh or the decoder: added as planned.
