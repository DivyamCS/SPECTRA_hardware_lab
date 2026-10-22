`timescale 1ns / 1ps
`default_nettype none

module tb_top_stress;

    // -------------------------------------------------------------------------
    // 1. Clock and Reset Generation
    // -------------------------------------------------------------------------
    reg clk   = 1'b0;
    reg reset = 1'b1;
    always #5 clk = ~clk; // 100 MHz clock

    // -------------------------------------------------------------------------
    // 2. Instantiate Dual Cores: Cached (ON) and Direct Bypass (OFF)
    // -------------------------------------------------------------------------
    wire [15:0] led_on;
    wire [15:0] led_off;

    top_fpga #(.DIV(0)) DUT_CACHED (
        .clk      (clk),
        .reset    (reset),
        .cache_en (1'b1),
        .led      (led_on)
    );

    top_fpga #(.DIV(0)) DUT_BYPASS (
        .clk      (clk),
        .reset    (reset),
        .cache_en (1'b0),
        .led      (led_off)
    );

    // -------------------------------------------------------------------------
    // 3. Test Control and Assertion Tracking
    // -------------------------------------------------------------------------
    integer errors = 0;
    integer total_tests = 0;
    integer cycle_count = 0;

    // Monitor for lockups/hangs
    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;
        if (cycle_count > 60000) begin
            $display("\n[FATAL] TIMEOUT: Simulation hung or exceeded maximum runtime.");
            $display("        Cached PC : 0x%08h | dc_stall = %b", DUT_CACHED.current_pc, DUT_CACHED.dc_stall);
            $display("        Bypass PC : 0x%08h | dc_stall = %b", DUT_BYPASS.current_pc, DUT_BYPASS.dc_stall);
            $finish;
        end
    end

    // -------------------------------------------------------------------------
    // 4. In-Memory Micro-Benchmark Assembler
    // -------------------------------------------------------------------------
    // We synthesize RV32I machine instructions directly into IMEM to test all
    // targeted corner cases without needing an external compiler.
    //
    // Set 0 Aliased Addresses (Assuming 16-byte block, Set index = addr[7:4]):
    //   Addr A: 0x0000_1000 (Tag 0x000010, Set 0, Offset 0)
    //   Addr B: 0x0000_2000 (Tag 0x000020, Set 0, Offset 0)
    //   Addr C: 0x0000_3000 (Tag 0x000030, Set 0, Offset 0)
    //   Addr D: 0x0000_4000 (Tag 0x000040, Set 0, Offset 0)
    //   Addr E: 0x0000_5000 (Tag 0x000050, Set 0, Offset 0) -> Triggers Eviction
    // -------------------------------------------------------------------------
    task load_stress_program;
        integer k;
        begin
            // Pre-fill instruction memory with NOPs
            for (k = 0; k < 1024; k = k + 1) begin
                DUT_CACHED.IMEM.imem[k] = 32'h0000_0013; // nop (addi x0, x0, 0)
                DUT_BYPASS.IMEM.imem[k] = 32'h0000_0013;
            end

            // Base address pointers in registers
            // x1  = 0x00001000 (Way 0 candidate)
            // x2  = 0x00002000 (Way 1 candidate)
            // x3  = 0x00003000 (Way 2 candidate)
            // x4  = 0x00004000 (Way 3 candidate)
            // x5  = 0x00005000 (Way 4 candidate -> causes conflict miss)
            // x6  = 0x00001004 (Same line, offset word 1)
            
            // 0x00: lui x1, 0x1          (x1 = 0x00001000)
            DUT_CACHED.IMEM.imem[0] = 32'h000010b7; DUT_BYPASS.IMEM.imem[0] = 32'h000010b7;
            // 0x04: lui x2, 0x2          (x2 = 0x00002000)
            DUT_CACHED.IMEM.imem[1] = 32'h00002137; DUT_BYPASS.IMEM.imem[1] = 32'h00002137;
            // 0x08: lui x3, 0x3          (x3 = 0x000031b7)
            DUT_CACHED.IMEM.imem[2] = 32'h000031b7; DUT_BYPASS.IMEM.imem[2] = 32'h000031b7;
            // 0x0C: lui x4, 0x4          (x4 = 0x00004237)
            DUT_CACHED.IMEM.imem[3] = 32'h00004237; DUT_BYPASS.IMEM.imem[3] = 32'h00004237;
            // 0x10: lui x5, 0x5          (x5 = 0x000052b7)
            DUT_CACHED.IMEM.imem[4] = 32'h000052b7; DUT_BYPASS.IMEM.imem[4] = 32'h000052b7;

            // [TEST 1: Sub-word strobes (SB / SH) into same word]
            // 0x14: addi x7, x0, 0xAA
            DUT_CACHED.IMEM.imem[5] = 32'h0aa00393; DUT_BYPASS.IMEM.imem[5] = 32'h0aa00393;
            // 0x18: sb x7, 0(x1)         (Byte 0 = 0xAA)
            DUT_CACHED.IMEM.imem[6] = 32'h00708023; DUT_BYPASS.IMEM.imem[6] = 32'h00708023;
            // 0x1C: addi x7, x0, 0x55
            DUT_CACHED.IMEM.imem[7] = 32'h05500393; DUT_BYPASS.IMEM.imem[7] = 32'h05500393;
            // 0x20: sb x7, 1(x1)         (Byte 1 = 0x55)
            DUT_CACHED.IMEM.imem[8] = 32'h007080a3; DUT_BYPASS.IMEM.imem[8] = 32'h007080a3;
            // 0x24: lui x7, 0x12340
            //       addi x7, x7, 0x567
            //       sh x7, 2(x1)         (Half-word 1 = 0x0567)
            DUT_CACHED.IMEM.imem[9]  = 32'h123403b7; DUT_BYPASS.IMEM.imem[9]  = 32'h123403b7;
            DUT_CACHED.IMEM.imem[10] = 32'h56738393; DUT_BYPASS.IMEM.imem[10] = 32'h56738393;
            DUT_CACHED.IMEM.imem[11] = 32'h00709123; DUT_BYPASS.IMEM.imem[11] = 32'h00709123;

            // [TEST 2: Immediate Read-After-Write (RAW) hazard check]
            // 0x30: lw x8, 0(x1)         (Read full word: Expect 0x056755AA)
            DUT_CACHED.IMEM.imem[12] = 32'h0000a403; DUT_BYPASS.IMEM.imem[12] = 32'h0000a403;

            // [TEST 3: Fill Remaining 3 Ways of Set 0 with Dirty Writes]
            // 0x34: lui x9, 0x22222
            DUT_CACHED.IMEM.imem[13] = 32'h222224b7; DUT_BYPASS.IMEM.imem[13] = 32'h222224b7;
            // 0x38: sw  x9, 0(x2)        (Way 1 dirty store)
            DUT_CACHED.IMEM.imem[14] = 32'h00912023; DUT_BYPASS.IMEM.imem[14] = 32'h00912023;
            // 0x3C: lui x10, 0x33333
            DUT_CACHED.IMEM.imem[15] = 32'h33333537; DUT_BYPASS.IMEM.imem[15] = 32'h33333537;
            // 0x40: sw  x10, 0(x3)       (Way 2 dirty store)
            DUT_CACHED.IMEM.imem[16] = 32'h00a1a023; DUT_BYPASS.IMEM.imem[16] = 32'h00a1a023;
            // 0x44: lui x11, 0x44444
            DUT_CACHED.IMEM.imem[17] = 32'h444445b7; DUT_BYPASS.IMEM.imem[17] = 32'h444445b7;
            // 0x48: sw  x11, 0(x4)       (Way 3 dirty store)
            DUT_CACHED.IMEM.imem[18] = 32'h00b22023; DUT_BYPASS.IMEM.imem[18] = 32'h00b22023;

            // [TEST 4: Touch Way 0, 1, 2 to adjust PLRU state]
            // Accessing x1, x2, x3 leaves x4 (Way 3) as least recently used
            // 0x4C: lw x12, 0(x1)
            DUT_CACHED.IMEM.imem[19] = 32'h0000e603; DUT_BYPASS.IMEM.imem[19] = 32'h0000e603;
            // 0x50: lw x13, 0(x2)
            DUT_CACHED.IMEM.imem[20] = 32'h00016683; DUT_BYPASS.IMEM.imem[20] = 32'h00016683;
            // 0x54: lw x14, 0(x3)
            DUT_CACHED.IMEM.imem[21] = 32'h0001e703; DUT_BYPASS.IMEM.imem[21] = 32'h0001e703;

            // [TEST 5: Thrash Set 0 - Force Eviction of Way 3 with 5th Tag]
            // 0x58: lui x15, 0x55555
            DUT_CACHED.IMEM.imem[22] = 32'h555557b7; DUT_BYPASS.IMEM.imem[22] = 32'h555557b7;
            // 0x5C: sw  x15, 0(x5)       (Miss, dirty writeback of evicted way, allocate Line 5)
            DUT_CACHED.IMEM.imem[23] = 32'h00f2a023; DUT_BYPASS.IMEM.imem[23] = 32'h00f2a023;

            // [TEST 6: Reload the Evicted Line from Main Memory]
            // If dirty writeback worked, reading x4 (0x4000) must return 0x44444000
            // 0x60: lw x16, 0(x4)        (Read evicted line)
            DUT_CACHED.IMEM.imem[24] = 32'h00022803; DUT_BYPASS.IMEM.imem[24] = 32'h00022803;

            // [TEST 7: Read back the 5th Line]
            // 0x64: lw x17, 0(x5)        (Expect 0x55555000)
            DUT_CACHED.IMEM.imem[25] = 32'h0002a883; DUT_BYPASS.IMEM.imem[25] = 32'h0002a883;

            // 0x68: Infinite Halt Loop (j .)
            DUT_CACHED.IMEM.imem[26] = 32'h0000006f; DUT_BYPASS.IMEM.imem[26] = 32'h0000006f;
        end
    endtask

    // -------------------------------------------------------------------------
    // 5. Execution and Self-Checking Verifications
    // -------------------------------------------------------------------------
    initial begin
        $display("\n=======================================================");
        $display("[*] Starting Hardware Top-Level Edge Case Stress Suite");
        $display("=======================================================");

        load_stress_program();

        // Release reset after 100 ns
        #100;
        @(negedge clk);
        reset = 1'b0;

        // Wait until both cores land on the self-loop at PC = 0x68
        wait (DUT_CACHED.current_pc == 32'h0000_0068 && DUT_BYPASS.current_pc == 32'h0000_0068);

        // Allow writebacks and memory pipelines to settle
        repeat (100) @(posedge clk);

        $display("\n--- [Phase 1] Byte/Half-word Sub-Strobe & RAW Forwarding ---");
        total_tests = total_tests + 1;
        if (DUT_CACHED.pipe_u.regs[8] === 32'h0567_55AA) begin
            $display("[+] PASS: Sub-word strobes (SB/SH) and RAW word load matched (0x%08h)", DUT_CACHED.pipe_u.regs[8]);
        end else begin
            $display("[-] FAIL: Expected 0x056755AA, got 0x%08h", DUT_CACHED.pipe_u.regs[8]);
            errors = errors + 1;
        end

        $display("\n--- [Phase 2] Set-Thrashing & Dirty Eviction Verification ---");
        total_tests = total_tests + 1;
        if (DUT_CACHED.pipe_u.regs[16] === 32'h4444_4000) begin
            $display("[+] PASS: Evicted dirty line was correctly restored from backing store (0x%08h)", DUT_CACHED.pipe_u.regs[16]);
        end else begin
            $display("[-] FAIL: Dirty eviction data corrupted. Expected 0x44444000, got 0x%08h", DUT_CACHED.pipe_u.regs[16]);
            errors = errors + 1;
        end

        total_tests = total_tests + 1;
        if (DUT_CACHED.pipe_u.regs[17] === 32'h5555_5000) begin
            $display("[+] PASS: Conflicting 5th line allocated and retained (0x%08h)", DUT_CACHED.pipe_u.regs[17]);
        end else begin
            $display("[-] FAIL: 5th line read failed. Expected 0x55555000, got 0x%08h", DUT_CACHED.pipe_u.regs[17]);
            errors = errors + 1;
        end

        $display("\n--- [Phase 3] Coherency: Full Register File Comparison ---");
        begin : reg_diff_check
            integer r;
            integer reg_mismatch;
            reg_mismatch = 0;
            for (r = 1; r < 32; r = r + 1) begin
                if (DUT_CACHED.pipe_u.regs[r] !== DUT_BYPASS.pipe_u.regs[r]) begin
                    $display("[-] MISMATCH on x%0d: Cached=0x%08h | Bypass=0x%08h",
                             r, DUT_CACHED.pipe_u.regs[r], DUT_BYPASS.pipe_u.regs[r]);
                    reg_mismatch = reg_mismatch + 1;
                end
            end
            total_tests = total_tests + 1;
            if (reg_mismatch == 0) begin
                $display("[+] PASS: All 31 registers are 100%% identical between Cached and Bypass cores.");
            end else begin
                $display("[-] FAIL: %0d register mismatches detected against golden bypass.", reg_mismatch);
                errors = errors + 1;
            end
        end

        $display("\n--- [Phase 4] Exceptions and Traps ---");
        total_tests = total_tests + 1;
        if (DUT_CACHED.exception === 1'b0 && DUT_BYPASS.exception === 1'b0) begin
            $display("[+] PASS: No spurious exceptions triggered during stress cycles.");
        end else begin
            $display("[-] FAIL: Core raised exception (Cached=%b, Bypass=%b)", 
                     DUT_CACHED.exception, DUT_BYPASS.exception);
            errors = errors + 1;
        end

        $display("\n=======================================================");
        if (errors == 0) begin
            $display("[+] SUITE PASSED (%0d/%0d checks successful)", total_tests, total_tests);
            $display("    Hardware is verified against aliasing, dirty evictions, and byte-strobes.");
        end else begin
            $display("[-] SUITE FAILED (%0d errors out of %0d tests)", errors, total_tests);
        end
        $display("=======================================================\n");

        $finish;
    end

endmodule
`default_nettype wire