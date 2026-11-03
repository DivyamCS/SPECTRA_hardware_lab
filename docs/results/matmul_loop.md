# MatMul inner loop

From `fw/build/demo/demo.lst` (xPack riscv-none-elf-gcc 15.2.0, -O2). The loop is
`for j: c[j] += a * b[j]` in `matmul_run` (fw/matmul.c): 0xE60-0xE7C, 8 instructions.

| Address | Instruction | Meaning |
| --- | --- | --- |
| 0xE60 | `lw a5, 0(a4)` | b[j] |
| 0xE64 | `add a3, a6, a4` | address of c[j] |
| 0xE68 | `lw a2, 0(a3)` | c[j] |
| 0xE6C | `mul a5, a5, a7` | a * b[j] |
| 0xE70 | `addi a4, a4, 4` | next j |
| 0xE74 | `add a5, a5, a2` | c[j] + a * b[j] |
| 0xE78 | `sw a5, 0(a3)` | store c[j] |
| 0xE7C | `bne a4, a1, 0xE60` | loop 32 times |

Dependences, by distance in instructions:

| Producer | Consumer | Distance | Path |
| --- | --- | --- | --- |
| `add a3` (0xE64) | `lw a2, 0(a3)` (0xE68) | 1 | forward into the load address |
| `add a5` (0xE74) | `sw a5` (0xE78) | 1 | forward into store data |
| `mul a5` (0xE6C) | `add a5` (0xE74) | 2 | register file write-through |
| `lw a5` (0xE60) | `mul` (0xE6C) | 3 | register file |
| `lw a2` (0xE68) | `add` (0xE74) | 3 | register file |
| `addi a4` (0xE70) | `bne` (0xE7C) | 3 | register file |

With FWD = 0 each distance-1 pair costs one stall cycle: 2 cycles per iteration (PROTOCOL.md section 7).
