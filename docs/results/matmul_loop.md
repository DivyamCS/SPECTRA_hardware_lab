# MatMul inner loop in the project build

From `fw/build/demo/demo.lst`, firmware built with xPack riscv-none-elf-gcc 15.2.0 -O2
(commit 7b5fa38 onwards). The loop is `for j: c[j] += a * b[j]` in `matmul_run` (fw/matmul.c).

**Inner loop: 0xAD4-0xAF0, 8 instructions** (an earlier zig build had 10 instructions at 0xA04).

| Address | Instruction | Meaning |
| --- | --- | --- |
| 0xAD4 | `lw a5, 0(a4)` | b[j] |
| 0xAD8 | `add a3, a6, a4` | address of c[j] |
| 0xADC | `lw a2, 0(a3)` | c[j] |
| 0xAE0 | `mul a5, a5, a7` | a * b[j] |
| 0xAE4 | `addi a4, a4, 4` | next j |
| 0xAE8 | `add a5, a5, a2` | c[j] + a * b[j] |
| 0xAEC | `sw a5, 0(a3)` | store c[j] |
| 0xAF0 | `bne a4, a1, 0xAD4` | loop 32 times |

Consequence (final timing diagram from the RTL waveform): redraw with this
8-instruction loop and its addresses. Dependences, by distance in instructions:

| Producer | Consumer | Distance | Path |
| --- | --- | --- | --- |
| `add a3` (0xAD8) | `lw a2, 0(a3)` (0xADC) | 1 | forward into the load address |
| `add a5` (0xAE8) | `sw a5` (0xAEC) | 1 | forward into store data |
| `mul a5` (0xAE0) | `add a5` (0xAE8) | 2 | write-through |
| `lw a5` (0xAD4) | `mul` (0xAE0) | 3 | register file |
| `lw a2` (0xADC) | `add` (0xAE8) | 3 | register file |
| `addi a4` (0xAE4) | `bne` (0xAF0) | 3 | register file |

So FWD = 0 adds 2 cycles per iteration here (two distance-1 pairs), PROTOCOL.md section 7.
