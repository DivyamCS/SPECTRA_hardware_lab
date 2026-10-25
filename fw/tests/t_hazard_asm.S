# t_hazard_asm.S - uint32_t hazard_suite(void): returns the number of failed checks (0 = pass).
# rv32sim -F stale1 / stale2 / nosquash injects the matching pipeline bug; each makes this fail.
# Every check is written so that a missing forward, a missing stall, a wrong squash or a
# wrong link address changes a register value. Uses only caller-saved registers.

# CHECK is itself hazard-free: three NOPs before and between every dependent step, so a broken
# pipeline cannot corrupt the check, only the instructions being tested.
    .macro CHECK reg, val
    nop
    nop
    nop
    lui     t6, %hi(\val)
    nop
    nop
    nop
    addi    t6, t6, %lo(\val)
    nop
    nop
    nop
    beq     \reg, t6, .Lok\@
    nop
    nop
    nop
    addi    a0, a0, 1
.Lok\@:
    .endm

    .text
    .globl hazard_suite
hazard_suite:
    addi    sp, sp, -32
    li      a0, 0

    # 1. dependence at distance 1, 2, 3
    addi    t0, x0, 5
    addi    t1, t0, 7               # distance 1
    CHECK   t1, 12
    addi    t0, x0, 9
    nop
    add     t1, t0, t0              # distance 2, both operands
    CHECK   t1, 18
    addi    t0, x0, 3
    nop
    nop
    slli    t1, t0, 4               # distance 3
    CHECK   t1, 48

    # 2. back-to-back chain
    addi    t0, x0, 1
    add     t0, t0, t0
    add     t0, t0, t0
    add     t0, t0, t0
    add     t0, t0, t0
    add     t0, t0, t0
    CHECK   t0, 32

    # 3. x0 is never forwarded
    addi    x0, x0, 5
    add     t0, x0, x0
    CHECK   t0, 0

    # 4. lui/auipc results used at once
    lui     t0, 0x12345
    addi    t0, t0, 0x678
    CHECK   t0, 0x12345678

    # 5. store data from the instruction just before (store-data forward)
    addi    t0, x0, 77
    sw      t0, 8(sp)
    lw      t1, 8(sp)
    CHECK   t1, 77

    # 6. load-use: loaded value used by the very next instruction
    li      t0, 1234
    sw      t0, 0(sp)
    lw      t1, 0(sp)
    addi    t2, t1, 1
    CHECK   t2, 1235

    # 7. load then store of the loaded value, then reload
    lw      t1, 0(sp)
    sw      t1, 4(sp)
    lw      t2, 4(sp)
    CHECK   t2, 1234

    # 8. byte and half-word loads and stores, sign and zero extension
    li      t0, 0x80FF7F80
    sw      t0, 12(sp)
    lb      t1, 12(sp)
    CHECK   t1, 0xFFFFFF80
    lbu     t1, 12(sp)
    CHECK   t1, 0x80
    lb      t1, 13(sp)
    CHECK   t1, 0x7F
    lh      t1, 14(sp)
    CHECK   t1, 0xFFFF80FF
    lhu     t1, 14(sp)
    CHECK   t1, 0x80FF
    li      t0, 0xAB
    sb      t0, 16(sp)
    li      t0, 0xCD
    sb      t0, 17(sp)
    li      t0, 0x1234
    sh      t0, 18(sp)
    lw      t1, 16(sp)
    CHECK   t1, 0x1234CDAB

    # 9. MUL and DIV results used by the next instruction
    li      t0, 1000
    mul     t1, t0, t0
    add     t2, t1, t1
    CHECK   t2, 2000000
    li      t0, 1000000
    li      t3, 7
    divu    t1, t0, t3
    addi    t2, t1, 1
    CHECK   t2, 142858
    rem     t1, t0, t3
    CHECK   t1, 1

    # 10. taken branch squashes the two instructions behind it
    li      t5, 0
    beq     x0, x0, 1f
    addi    t5, t5, 1
    addi    t5, t5, 2
1:  CHECK   t5, 0

    # 11. not-taken branch executes the fall-through
    li      t5, 0
    bne     x0, x0, 2f
    addi    t5, t5, 1
2:  CHECK   t5, 1

    # 12. branch on a value computed by the previous instruction
    li      t5, 0
    addi    t0, x0, 4
    addi    t0, t0, -4
    beqz    t0, 3f
    addi    t5, t5, 1
3:  CHECK   t5, 0

    # 13. branch on a just-loaded value
    li      t5, 0
    sw      x0, 20(sp)
    lw      t0, 20(sp)
    bnez    t0, 4f
    addi    t5, t5, 5
4:  CHECK   t5, 5

    # 14. JAL link address and squash
    li      t5, 0
    jal     t3, 5f
    addi    t5, t5, 1
5:  auipc   t4, 0
    addi    t4, t4, -4              # address of the squashed addi = jal + 4
    sub     t3, t3, t4
    CHECK   t3, 0
    CHECK   t5, 0

    # 15. JALR to a register computed just before, link value used at once
    li      t5, 0
    la      t0, 6f
    jalr    t3, 0(t0)
7:  addi    t5, t5, 1
6:  la      t4, 7b
    sub     t3, t3, t4
    CHECK   t3, 0
    CHECK   t5, 0

    # 16. dependence across a taken branch target
    addi    t0, x0, 10
    j       8f
8:  addi    t1, t0, 5
    CHECK   t1, 15

    addi    sp, sp, 32
    ret
