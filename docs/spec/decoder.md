# decoder (spec v1.0)

| Item | Value |
| --- | --- |
| File | rtl/core/decoder.v (from the decode logic of the lab's IF_ID.v) |
| Testbench | tb/tb_decoder.v |
| Vectors | directed table: every RV32IM encoding class plus illegal ones |
| Interfaces | none (inside the core) |
| Removal parameter | none |

## Purpose
Turns a 32-bit instruction into register numbers, the immediate and control bits for one
3-stage RV32IM core. Purely combinational; the ID/EX register lives in the core wrapper.

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `instr` | in | 32 | instruction in ID |
| `rs1`, `rs2`, `rd` | out | 5 each | register numbers (`instr[19:15]`, `[24:20]`, `[11:7]`) |
| `uses_rs1`, `uses_rs2` | out | 1 each | the instruction really reads rs1 / rs2 (for interlocks) |
| `writes_rd` | out | 1 | writes rd (rd may be x0: the write is then dropped by regfile) |
| `imm` | out | 32 | sign-extended immediate of the instruction's format |
| `alu_op` | out | 4 | ADD SUB SLL SLT SLTU XOR SRL SRA OR AND, and PASS_B for LUI |
| `use_imm` | out | 1 | ALU operand B = imm |
| `is_lui`, `is_auipc`, `is_jal`, `is_jalr`, `is_branch` | out | 1 each | instruction class |
| `br_cond` | out | 3 | funct3 of a branch |
| `is_load`, `is_store` | out | 1 each | memory access |
| `mem_size` | out | 2 | 0 byte, 1 half, 2 word |
| `load_unsigned` | out | 1 | LBU / LHU |
| `is_md` | out | 1 | M extension (opcode 0110011, funct7 0000001) |
| `md_op` | out | 3 | funct3: MUL MULH MULHSU MULHU DIV DIVU REM REMU |
| `illegal` | out | 1 | not an RV32IM instruction SPECTRA supports |

## Behaviour
1. RV32I as the lab decoder, **plus AUIPC** (opcode 0010111; result = pc + imm, plan amendment) and the M extension.
2. FENCE, ECALL, EBREAK, CSR, compressed and any unknown encoding set `illegal`; an illegal
   instruction writes nothing, stores nothing and is otherwise a no-op. The core latches a sticky
   `illegal_seen` flag (visible in simulation; the firmware never contains such instructions).
3. SLLI/SRLI/SRAI with funct7 other than 0000000 / 0100000 are illegal (as rv32sim).
4. A load with rd = x0 is still a load (`is_load` = 1, `writes_rd` = 1, rd = 0).

## Reset values
None (combinational).

## Tests
Table testbench (tools/gen_decoder_vectors.py): 12 assembler-made encodings of each of the 45
RV32IM instructions SPECTRA supports (37 RV32I without FENCE/ECALL/EBREAK, incl. AUIPC, + 8 M),
30 illegal encodings (FENCE, ECALL, EBREAK, CSR, compressed, reserved funct3/funct7, 0x00000000)
and 10,000 random words; all 22 outputs checked against an independent Python model. PASS = 0
mismatches.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version |
| 1.0.1 | 16 Oct 2026 | Test list: 45 instructions (not 47), as built; no port change |
