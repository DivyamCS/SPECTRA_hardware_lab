.global _start
_start:
    # -------------------------------------------------------------
    # Test 1: Basic MUL & RAW Data Hazard / Stall Check
    # -------------------------------------------------------------
    addi x1, x0, 12        # x1 = 12
    addi x2, x0, 8         # x2 = 8
    mul  x3, x1, x2        # x3 = 96 (0x60) -> Stalls pipeline for 3 cycles
    add  x4, x3, x1        # RAW hazard: x4 = 96 + 12 = 108 (0x6C)

    # -------------------------------------------------------------
    # Test 2: Basic DIV & RAW Data Hazard / Long Stall Check
    # -------------------------------------------------------------
    addi x5, x0, 100       # x5 = 100
    div  x6, x5, x1        # x6 = 100 / 12 = 8 -> Stalls pipeline for 32 cycles
    sub  x7, x6, x2        # RAW hazard: x7 = 8 - 8 = 0

    # -------------------------------------------------------------
    # Test 3: REM (Remainder) & Chained Execution
    # -------------------------------------------------------------
    rem  x8, x5, x1        # x8 = 100 % 12 = 4 (0x04)
    mul  x9, x8, x2        # x9 = 4 * 8 = 32 (0x20)

    # -------------------------------------------------------------
    # Test 4: Branch Dependent on M-Extension Result
    # -------------------------------------------------------------
    addi x10, x0, 8        # x10 = 8
    beq  x6, x10, pass     # Branch if x6 == 8 (Branch TAKEN)
    addi x31, x0, 1        # If branch failed to evaluate: x31 = 1 (FAIL)
    beq  x0, x0, end_loop  # Jump to end

pass:
    addi x31, x0, 42       # Success marker: x31 = 42 (0x0000002A)

end_loop:
    beq  x0, x0, end_loop  # Infinite loop (halt equivalent).global _start
_start:
    # -------------------------------------------------------------
    # Test 1: Basic MUL & RAW Data Hazard / Stall Check
    # -------------------------------------------------------------
    addi x1, x0, 12        # x1 = 12
    addi x2, x0, 8         # x2 = 8
    mul  x3, x1, x2        # x3 = 96 (0x60) -> Stalls pipeline for 3 cycles
    add  x4, x3, x1        # RAW hazard: x4 = 96 + 12 = 108 (0x6C)

    # -------------------------------------------------------------
    # Test 2: Basic DIV & RAW Data Hazard / Long Stall Check
    # -------------------------------------------------------------
    addi x5, x0, 100       # x5 = 100
    div  x6, x5, x1        # x6 = 100 / 12 = 8 -> Stalls pipeline for 32 cycles
    sub  x7, x6, x2        # RAW hazard: x7 = 8 - 8 = 0

    # -------------------------------------------------------------
    # Test 3: REM (Remainder) & Chained Execution
    # -------------------------------------------------------------
    rem  x8, x5, x1        # x8 = 100 % 12 = 4 (0x04)
    mul  x9, x8, x2        # x9 = 4 * 8 = 32 (0x20)

    # -------------------------------------------------------------
    # Test 4: Branch Dependent on M-Extension Result
    # -------------------------------------------------------------
    addi x10, x0, 8        # x10 = 8
    beq  x6, x10, pass     # Branch if x6 == 8 (Branch TAKEN)
    addi x31, x0, 1        # If branch failed to evaluate: x31 = 1 (FAIL)
    beq  x0, x0, end_loop  # Jump to end

pass:
    addi x31, x0, 42       # Success marker: x31 = 42 (0x0000002A)

end_loop:
    beq  x0, x0, end_loop  # Infinite loop (halt equivalent)