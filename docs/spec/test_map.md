# Test map: which RTL path each firmware check exercises

Every check in the five test images, mapped to the RTL path it proves. Pipeline terms follow docs/spec/: register file read in ID with
write-through (regfile), MEM/WB -> EX forwarding switched by FWD (hazard_unit),
global freeze, 2-instruction squash, data port (mem_stage).
"Fault" is **measured**: the rv32sim faults (`-F`) under which this check's failure path
executed, found by tracing t_hazard with each fault and looking for each CHECK's own
`addi a0, a0, 1` (27 of them, in source order). `stale1` (no forwarding) breaks the suite's own
surrounding code before the first check, so its per-check effect cannot be observed; the image
still fails (cycle limit). Details: docs/results/fault_injection.md.

## t_hazard: 27 checks (fw/tests/t_hazard_asm.S, checksum = failed checks, golden 0)

Each CHECK is itself hazard-free (three NOPs around every dependent step), so only the tested
instructions can be wrong.

| # | Section | Check | RTL path | Fault |
| --- | --- | --- | --- | --- |
| 1 | 1 | `addi t1, t0, 7` right after `t0` (distance 1) = 12 | MEM/WB -> EX forward, operand A; FWD = 0: interlock | - |
| 2 | 1 | `add t1, t0, t0` at distance 2, both operands = 18 | register file write-through | stale2 |
| 3 | 1 | `slli` at distance 3 = 48 | ordinary register read | - |
| 4 | 2 | chain of 5 back-to-back `add t0, t0, t0` = 32 | forward on every cycle | stale2 |
| 5 | 3 | `addi x0, 5` then `add t0, x0, x0` = 0 | x0 never written or forwarded | - |
| 6 | 4 | `lui` then `addi` on it = 0x12345678 | U-type immediate + forward | - |
| 7 | 5 | `addi t0` then `sw t0` (store data from distance 1), reload = 77 | forward into store data (operand B) | stale2 |
| 8 | 6 | `lw t1` then `addi t2, t1, 1` (load-use) = 1235 | load result forwarded after the hit stall | stale2 |
| 9 | 7 | `lw t1; sw t1; lw t2` = 1234 | loaded value as store data | stale2 |
| 10 | 8 | `lb` of 0x80 = 0xFFFFFF80 | load sign extension, lane 0 | stale2 |
| 11 | 8 | `lbu` of 0x80 = 0x80 | zero extension | stale2 |
| 12 | 8 | `lb` lane 1 = 0x7F | lane select | stale2 |
| 13 | 8 | `lh` upper half = 0xFFFF80FF | half sign extension, lane 2 | stale2 |
| 14 | 8 | `lhu` upper half = 0x80FF | half zero extension | stale2 |
| 15 | 8 | `sb, sb, sh` then `lw` = 0x1234CDAB | store byte enables and lane placement (+ D-cache byte write) | stale2 |
| 16 | 9 | `mul` then `add` on the product = 2,000,000 | mul_unit, EX hold, forward of the MUL result | - |
| 17 | 9 | `divu` then `addi` = 142,858 | div_unit, EX hold for 34 cycles | stale2 |
| 18 | 9 | `rem` = 1 | div_unit remainder path | - |
| 19 | 10 | taken `beq`: the 2 instructions behind it do not execute (t5 = 0) | 2-instruction squash | nosquash |
| 20 | 11 | not-taken `bne`: fall-through executes (t5 = 1) | no squash when not taken | - |
| 21 | 12 | `beqz` on a value computed just before | forward into the branch compare | stale2, nosquash |
| 22 | 13 | `bnez` on a just-loaded value | load forward into the branch compare | - |
| 23 | 14 | JAL link = address of the next instruction (checked with AUIPC) | link = pc + 4; AUIPC | stale2 |
| 24 | 14 | instruction after JAL squashed (t5 = 0) | squash on JAL | nosquash |
| 25 | 15 | JALR link correct; target from `la` just before | JALR target with forwarded rs1; AUIPC in `la` | - |
| 26 | 15 | instruction after JALR squashed | squash on JALR | nosquash |
| 27 | 16 | `addi t1, t0, 5` at the jump target uses `t0` from before the jump = 15 | forward across a taken jump and squash | - |

## t_mext (fw/tests/t_mext.c, checksum 0xD7A9B563)

| Check | RTL path |
| --- | --- |
| MUL, MULH, MULHSU, MULHU on all 13 x 13 edge pairs | mul_unit signed/unsigned extension, high word |
| DIV, DIVU, REM, REMU on the edge pairs, including /0 and INT_MIN / -1 | div_unit special cases |
| all 8 on 1,000 LCG pairs (small and large divisors, some 0) | both units, random data |
| result folded into the hash by the next instructions | forward of MUL/DIV results, EX hold |
| M decode (opcode 0110011, funct7 0000001) | decoder |

## t_cache (fw/tests/t_cache.c, checksum = wrong values, golden 0)

| Check | RTL path |
| --- | --- |
| 1. five lines 1 KB apart (one set), read and rewritten 200 rounds | dirty-victim write-back before refill; replacement with 5 lines in a 4-way set |
| 2. `sb, sb, sh` into a line, evicted by 4 lines of the same set, reloaded | byte enables in a cached line; merged word survives eviction and write-back |
| 2. the 4 evicting lines read back | refill of each victim |
| 3. 16 KB sequential write then read (4 x the cache) | streaming misses, every line evicted, write-allocate |
| all with DC = 0 | bypass path (1-word bursts with byte enables) |

## t_lock (fw/tests/t_lock.c, counter must equal 10,000 x NCORES)

| Check | RTL path |
| --- | --- |
| LOCK read = atomic test-and-set, write 0 = release | lock_barrier, mmio_bus |
| no lost update of the shared counter | rr_arbiter serialises the cores; one shared D-cache, so no stale copy |
| NCORES read | mmio_bus, core_ctrl |
| barriers at start and end | lock_barrier BARRIER |
| two cores | soc_top with both cores |

## t_barrier (fw/tests/t_barrier.c, checksum = mismatches, golden 0)

| Check | RTL path |
| --- | --- |
| each core sees the other's round number after the barrier, 1,000 rounds | BARRIER releases only when every running core arrived; stores visible through the shared D-cache |
| works with 1 core (releases at once) | NCORES = 1 path |
| BAR_WAIT counted | perf_counters |

