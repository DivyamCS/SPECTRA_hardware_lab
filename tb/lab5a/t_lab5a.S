# t_lab5a.S - RV32I test image for the unmodified lab 5A core.
#
# The lab core is compared with rv32sim by commit trace (docs/PROTOCOL.md section 8), so this
# program only uses what the lab core implements and only addresses it decodes the same way:
#   * RV32I without AUIPC (the lab decoder has no AUIPC), FENCE, ECALL, EBREAK or CSRs;
#     addresses are built with LUI + ADDI, calls use JAL / JALR;
#   * data only in 0x1000_0000-0x1000_0FFF: the lab's 4 KB data memory indexes addr[11:2],
#     so it sees these addresses at the same offsets ("4 KB-wrapped address map");
#   * no MMIO except the last instruction's SWITCHES read, which ends the trace (tracecmp
#     stops there and rv32sim stops running).
# Each taken branch or jump is followed by two "poison" instructions that must be squashed;
# they would add 0x100 to s10, which is stored in the result block.

    .section .text.boot, "ax"
    .globl _start
_start:
    lui   s0, 0x10000               # s0 = data base 0x1000_0000
    addi  s10, x0, 0                # poison counter (stays 0 if squashing works)

# ---- ALU, immediate forms ----
    addi  a0, x0, 1234
    addi  a1, x0, -7
    slti  a2, a1, 0
    slti  a3, a0, -1
    sltiu a4, a1, 5
    sltiu a5, a0, 2000
    xori  a6, a0, -1
    ori   a7, a0, 0x0F0
    andi  t0, a0, 0x0F0
    slli  t1, a0, 7
    srli  t2, a1, 4
    srai  t3, a1, 2
    lui   t4, 0xABCDE
    addi  t4, t4, 0x123             # 0xABCDE123
    lui   t5, 0x80000
    addi  t6, t5, -1                # 0x7FFFFFFF

# ---- ALU, register forms ----
    add   s1, a0, a1
    sub   s2, a0, a1
    sub   s3, a1, a0
    sll   s4, a0, a1                # shift amount = low 5 bits of -7 = 25
    slt   s5, a1, a0
    slt   s6, a0, a1
    sltu  s7, a1, a0
    sltu  s8, a0, a1
    xor   s9, t4, a0
    srl   s11, t4, a2               # a2 = 1
    sra   a2, t4, a0                # 1234 & 31 = 18
    or    a3, t4, a1
    and   a4, t4, a1
    add   a5, t6, a2                # signed overflow wraps
    sra   a6, t5, a1                # 0x80000000 >> 25 (arithmetic)
    srl   a7, t5, a1

# ---- dependences at distance 1 and 2, writes to x0 ----
    addi  t0, x0, 3
    add   t0, t0, t0                # distance 1
    add   t0, t0, t0                # distance 1
    add   t1, t0, t0
    add   t2, t0, t1                # distances 2 and 1
    addi  x0, x0, 5                 # writes to x0 are ignored
    add   t3, x0, t2
    sub   x0, t3, t2
    add   t3, t3, x0

# ---- stores, loads, load-use, store-to-load ----
    sw    t4, 0(s0)
    sw    a1, 4(s0)
    lw    t0, 0(s0)                 # load right behind a store to the same word
    add   t1, t0, t0                # load-use at distance 1
    lw    t2, 4(s0)
    sw    t2, 8(s0)                 # store data from a load at distance 1
    lb    t3, 0(s0)
    lb    t3, 1(s0)
    lb    t3, 2(s0)
    lb    t3, 3(s0)
    lbu   t3, 0(s0)
    lbu   t3, 1(s0)
    lbu   t3, 2(s0)
    lbu   t3, 3(s0)
    lh    t3, 0(s0)
    lh    t3, 2(s0)
    lhu   t3, 0(s0)
    lhu   t3, 2(s0)
    lb    t3, 4(s0)                 # sign extension of 0xF9
    lhu   t3, 6(s0)
    sb    a0, 16(s0)                # byte stores into each lane
    sb    a1, 17(s0)
    sb    t4, 18(s0)
    sb    a0, 19(s0)
    lw    t3, 16(s0)
    sh    t4, 20(s0)                # half-word stores into both halves
    sh    a1, 22(s0)
    lw    t3, 20(s0)
    lw    x0, 0(s0)                 # load to x0: memory is read, nothing written
    addi  t5, x0, 77
    sw    t5, 24(s0)
    sb    t5, 25(s0)                # sub-word store right after a word store
    lw    t5, 24(s0)

# ---- branches: each condition taken and not taken ----
    addi  t0, x0, 5
    addi  t1, x0, -5
    beq   t0, t0, 1f
    addi  s10, s10, 0x100
    addi  s10, s10, 0x100
1:  beq   t0, t1, poison
    bne   t0, t1, 1f
    addi  s10, s10, 0x100
    addi  s10, s10, 0x100
1:  bne   t0, t0, poison
    blt   t1, t0, 1f
    addi  s10, s10, 0x100
    addi  s10, s10, 0x100
1:  blt   t0, t1, poison
    bge   t0, t1, 1f
    addi  s10, s10, 0x100
    addi  s10, s10, 0x100
1:  bge   t1, t0, poison
    bge   t0, t0, 1f                # equal operands
    addi  s10, s10, 0x100
    addi  s10, s10, 0x100
1:  bltu  t0, t1, 1f                # 5 < 0xFFFFFFFB unsigned
    addi  s10, s10, 0x100
    addi  s10, s10, 0x100
1:  bltu  t1, t0, poison
    bgeu  t1, t0, 1f
    addi  s10, s10, 0x100
    addi  s10, s10, 0x100
1:  bgeu  t0, t1, poison
    lw    t2, 4(s0)                 # branch on a load result at distance 1
    beq   t2, a1, 1f
    addi  s10, s10, 0x100
    addi  s10, s10, 0x100
1:  add   t3, t0, t0                # branch on an ALU result at distance 1
    bne   t3, t0, 1f
    addi  s10, s10, 0x100
    addi  s10, s10, 0x100
1:  beq   t0, t0, 1f                # taken branch to a taken branch
    addi  s10, s10, 0x100
    addi  s10, s10, 0x100
1:  beq   t0, t0, 1f
    addi  s10, s10, 0x100
    addi  s10, s10, 0x100
1:  sw    t0, 28(s0)                # store right behind a taken branch: must not be squashed
    beq   t0, t0, 1f
    sw    s10, 28(s0)               # stores in the squash shadow must not happen
    sw    s10, 28(s0)
1:  lw    t4, 28(s0)

# ---- JAL / JALR, links, calls ----
    jal   ra, func_double           # call; func returns with jalr
    jal   ra, func_double
    jal   x0, 1f                    # plain jump, no link
    addi  s10, s10, 0x100
    addi  s10, s10, 0x100
1:  lui   t0, %hi(func_double)      # indirect call through a register
    addi  t0, t0, %lo(func_double)
    jalr  ra, 0(t0)
    lui   t1, %hi(jtarget)
    addi  t1, t1, %lo(jtarget)
    sw    t1, 32(s0)
    lw    t2, 32(s0)
    jalr  ra, 0(t2)                 # jalr on a load result at distance 1
    addi  s10, s10, 0x100
    addi  s10, s10, 0x100
jtarget:
    lui   t1, %hi(jt2_m4)
    addi  t1, t1, %lo(jt2_m4)
    jalr  t3, 4(t1)                 # link in another register, non-zero offset: goes to jt2
    addi  s10, s10, 0x100
jt2_m4:
    addi  s10, s10, 0x100
jt2:

# ---- loop: fill a table and fold it into a checksum ----
    addi  t0, x0, 0                 # i
    addi  t1, x0, 64                # n
    addi  t2, s0, 256               # table at 0x1000_0100
    lui   t3, 0x12345
    addi  t3, t3, 0x678             # running value
2:  slli  t4, t3, 3
    xor   t3, t3, t4
    srli  t4, t3, 5
    xor   t3, t3, t4
    add   t3, t3, t0
    sw    t3, 0(t2)
    addi  t2, t2, 4
    addi  t0, t0, 1
    blt   t0, t1, 2b                # backward taken branch, 64 times
    addi  t2, s0, 256
    addi  t5, x0, 0                 # FNV-1a over the table, bytewise
    lui   a0, 0x811CA
    addi  a0, a0, -571              # 0x811C9DC5, the FNV-1a offset basis
3:  lbu   a2, 0(t2)
    xor   a0, a0, a2
    # a0 *= 16777619 without MUL: shift-and-add over the set bits of 0x01000193
    slli  a3, a0, 24
    slli  a4, a0, 8
    add   a3, a3, a4
    slli  a4, a0, 7
    add   a3, a3, a4
    slli  a4, a0, 4
    add   a3, a3, a4
    slli  a4, a0, 1
    add   a3, a3, a4
    add   a0, a3, a0
    addi  t2, t2, 1
    addi  t5, t5, 1
    addi  a5, x0, 256
    bne   t5, a5, 3b

# ---- result block and end ----
    sw    a0, 36(s0)                # checksum
    sw    s10, 40(s0)               # poison counter, must be 0
    lw    a6, 36(s0)
    lw    a7, 40(s0)
    lui   t0, 0x20000
    lw    t1, 0x38(t0)              # SWITCHES: the trace ends here
end:
    jal   x0, end

poison:                             # reached only by a wrong branch decision
    addi  s10, s10, 0x700
    jal   x0, end

func_double:                        # a0 = a0 + a0, returns through ra
    add   a0, a0, a0
    jalr  x0, 0(ra)
    addi  s10, s10, 0x100           # squashed after the return
    addi  s10, s10, 0x100
