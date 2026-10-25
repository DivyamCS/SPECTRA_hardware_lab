`timescale 1ns/1ps


module tb_mul;

    // -------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------
    reg         clk;
    reg         rst;
    reg         start;
    reg  [2:0]  funct3;
    reg  [31:0] in_a;
    reg  [31:0] in_b;
    wire [31:0] product;
    wire        busy;
    wire        done;

    // Test tracking
    integer error_count = 0;
    integer test_count  = 0;

    `include "opcode.vh"
   

    // -------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------
    mul u_dut (
        .clk     (clk),
        .rst     (rst),
        .start   (start),
        .funct3  (funct3),
        .in_a    (in_a),
        .in_b    (in_b),
        .product (product),
        .busy    (busy),
        .done    (done)
    );

    // -------------------------------------------------------------
    // Clock Generation (50 MHz target: 20 ns period)
    // -------------------------------------------------------------
    always #10 clk = ~clk;

    // -------------------------------------------------------------
    // Task: Standard Transaction Check (with strict 5-cycle guard)
    // -------------------------------------------------------------
    task run_mul_test(
        input [2:0]         f3,
        input [31:0]        op_a,
        input [31:0]        op_b,
        input [31:0]        expected,
        input [8*16-1:0]    test_name
    );
        integer wait_cycles;
        begin
            test_count = test_count + 1;

            @(posedge clk);
            #1;
            start  <= 1'b1;
            funct3 <= f3;
            in_a   <= op_a;
            in_b   <= op_b;

            @(posedge clk);
            #1;
            start  <= 1'b0;

            // Strict 5-cycle timeout guard
            wait_cycles = 0;
            while (!done && wait_cycles < 5) begin
                @(posedge clk);
                #1;
                wait_cycles = wait_cycles + 1;
            end

            if (!done) begin
                $display("[FAIL] %s: Timeout! 'done' did not assert within 5 cycles.", test_name);
                error_count = error_count + 1;
            end else if (product !== expected) begin
                $display("[FAIL] %s: in_a=0x%08h, in_b=0x%08h | Expected: 0x%08h, Got: 0x%08h",
                         test_name, op_a, op_b, expected, product);
                error_count = error_count + 1;
            end else begin
                $display("[PASS] %s: 0x%08h * 0x%08h -> Result = 0x%08h", 
                         test_name, op_a, op_b, product);
            end

            @(posedge clk);
        end
    endtask

    // -------------------------------------------------------------
    // Main Test Execution
    // -------------------------------------------------------------
    initial begin
        clk    = 0;
        rst    = 1;
        start  = 0;
        funct3 = 3'b000;
        in_a   = 32'h0;
        in_b   = 32'h0;

        // Apply Synchronous Reset for 3 cycles
        repeat (3) @(posedge clk);
        #1;
        rst <= 0;
        @(posedge clk);

        $display("\n=======================================================");
        $display("          STARTING COMPLETE HARDWARE MULTIPLIER TESTS   ");
        $display("=======================================================\n");

        // =========================================================
        // SECTION 1: BASELINE TESTS
        // =========================================================

        // --- 1.1 MUL (Lower 32-bit, Signed x Signed) ---
        run_mul_test(MUL, 32'd5, 32'd10, 32'd50, "MUL pos x pos");
        run_mul_test(MUL, -32'd5, 32'd10, -32'd50, "MUL neg x pos");
        run_mul_test(MUL, -32'd6, -32'd7, 32'd42, "MUL neg x neg");
        run_mul_test(MUL, 32'd0, 32'h12345678, 32'd0, "MUL zero x val");
        run_mul_test(MUL, 32'h7FFFFFFF, 32'h7FFFFFFF, 32'h00000001, "MUL overflow low");
        run_mul_test(MUL, 32'h80000000, 32'hFFFFFFFF, 32'h80000000, "MUL INT_MIN*-1");

        // --- 1.2 MULH (Upper 32-bit, Signed x Signed) ---
        run_mul_test(MULH, 32'd5, 32'd10, 32'h00000000, "MULH small pos");
        run_mul_test(MULH, -32'd5, 32'd10, 32'hFFFFFFFF, "MULH small neg");
        run_mul_test(MULH, 32'h7FFFFFFF, 32'h7FFFFFFF, 32'h3FFFFFFF, "MULH max_pos");
        run_mul_test(MULH, 32'h80000000, 32'h80000000, 32'h40000000, "MULH INT_MIN sq");

        // --- 1.3 MULHSU (Upper 32-bit, Signed x Unsigned) ---
        run_mul_test(MULHSU, 32'hFFFFFFFF, 32'd2, 32'hFFFFFFFF, "MULHSU -1 x 2");
        run_mul_test(MULHSU, 32'h80000000, 32'h80000000, 32'hC0000000, "MULHSU bounds");

        // --- 1.4 MULHU (Upper 32-bit, Unsigned x Unsigned) ---
        run_mul_test(MULHU, 32'hFFFFFFFF, 32'hFFFFFFFF, 32'hFFFFFFFE, "MULHU max_u32");
        run_mul_test(MULHU, 32'h00001000, 32'h00002000, 32'h00000000, "MULHU small");


        // =========================================================
        // SECTION 2: ADDITIONAL ARITHMETIC TESTS
        // =========================================================

        // --- 2.1 Identity and Sign Handling (1 and -1) ---
        run_mul_test(MUL, 32'd42, 32'd1, 32'd42, "MUL x 1");
        run_mul_test(MUL, 32'd42, -32'd1, -32'd42, "MUL x -1");
        run_mul_test(MUL, -32'd42, -32'd1, 32'd42, "MUL -X x -1");
        run_mul_test(MULH, 32'd42, -32'd1, 32'hFFFFFFFF, "MULH pos x -1");

        // --- 2.2 Wraparound and High-Word Behavior (0xFFFFFFFF * 2) ---
        run_mul_test(MUL, 32'hFFFFFFFF, 32'd2, 32'hFFFFFFFE, "MUL 0xFFFFFFFF*2");
        run_mul_test(MULH, 32'hFFFFFFFF, 32'd2, 32'hFFFFFFFF, "MULH 0xFFFFFFFF*2");
        run_mul_test(MULHU, 32'hFFFFFFFF, 32'd2, 32'h00000001, "MULHU 0xFFFFFFFF*2");

        // --- 2.3 Nontrivial Partial Products (0x0000FFFF * 0x0000FFFF) ---
        run_mul_test(MUL, 32'h0000FFFF, 32'h0000FFFF, 32'hFFFE0001, "MUL partial prod");
        run_mul_test(MULHU, 32'h0000FFFF, 32'h0000FFFF, 32'h00000000, "MULHU partial prod");

        // --- 2.4 Alternating Bit Patterns (0xAAAAAAAA * 0x55555555) ---
        run_mul_test(MUL,   32'hAAAAAAAA, 32'h55555555, 32'h71C71C72, "MUL alternating");
        run_mul_test(MULHU, 32'hAAAAAAAA, 32'h55555555, 32'h38E38E38, "MULHU alternating");


        // =========================================================
            // SECTION 3: START,BUSY,RESTART,DONE CHECKS
            // =========================================================

        // --- 3.1 Start Asserted While Busy ---
        test_count = test_count + 1;
        $display("[INFO] Running: Start While Busy Test...");
        @(posedge clk);
        #1;
        // Start Operation 1: 10 * 10 = 100
        start  <= 1'b1;
        funct3 <= MUL;
        in_a   <= 32'd10;
        in_b   <= 32'd10;

        @(posedge clk);
        #1;
        // Attempt an illegal restart during Cycle 2 while busy
        start  <= 1'b1;
        in_a   <= 32'd999; 
        in_b   <= 32'd999;

        @(posedge clk);
        #1;
        start <= 1'b0;

        // Wait until cycle 3 finishes
        while (!done) @(posedge clk);
        #1;

        // Operation 1 must have been protected and produce 100, not 999*999
        if (product !== 32'd100) begin
            $display("[FAIL] Start While Busy: Data corrupted! Got 0x%08h, Expected 100", product);
            error_count = error_count + 1;
        end else begin
            $display("[PASS] Start While Busy: Correctly rejected mid-cycle interruption.");
        end
        @(posedge clk);

        // --- 3.2 Reset Mid-Flight Abort and Recovery ---
        test_count = test_count + 1;
        $display("[INFO] Running: Reset Mid-Flight Test...");
        @(posedge clk);
        #1;
        start  <= 1'b1;
        funct3 <= MUL;
        in_a   <= 32'd50;
        in_b   <= 32'd50;

        @(posedge clk); // Cycle 1 entered
        #1;
        start <= 1'b0;
        rst   <= 1'b1; // Assert synchronous reset mid-operation

        @(posedge clk); // Reset takes effect
        #1;
        rst <= 1'b0;    // Release reset

        // Verify module cleanly returns to IDLE (busy = 0, done = 0)
        #1;
        if (busy !== 1'b0 || done !== 1'b0) begin
            $display("[FAIL] Reset Mid-Flight: Multiplier did not return to idle! busy=%b, done=%b", busy, done);
            error_count = error_count + 1;
        end else begin
            $display("[PASS] Reset Mid-Flight: Multiplier cleanly aborted and returned to IDLE.");
        end

        // Post-reset recovery verification: ensure subsequent operations execute normally
        run_mul_test(MUL, 32'd7, 32'd8, 32'd56, "MUL post-abort test");


        // =========================================================
        // SUMMARY
        // =========================================================
        $display("\n=======================================================");
        if (error_count == 0) begin
            $display(" ALL %0d TESTS (ARITHMETIC + EDGE + PROTOCOL) PASSED! ", test_count);
        end else begin
            $display(" TESTS COMPLETED WITH %0d ERRORS OUT OF %0d TESTS! ", error_count, test_count);
        end
        $display("=======================================================\n");

        $finish;
    end

endmodule