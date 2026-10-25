`timescale 1ns/1ps

module tb_div;

    reg         clk;
    reg         rst;
    reg         start;
    reg  [2:0]  funct3;
    reg  [31:0] in_a;
    reg  [31:0] in_b;
    wire [31:0] result;
    wire        busy;
    wire        done;

    integer error_count = 0;
    integer test_count  = 0;

    `include "opcode.vh"

    // Device Under Test
    div u_dut (
        .clk    (clk),
        .rst    (rst),
        .start  (start),
        .funct3 (funct3),
        .in_a   (in_a),
        .in_b   (in_b),
        .result (result),
        .busy   (busy),
        .done   (done)
    );

    // 50 MHz Clock (20 ns period)
    always #10 clk = ~clk;

    // -------------------------------------------------------------
    // Task: Standard Transaction Check (35-cycle guard for 32-bit radix-2)
    // -------------------------------------------------------------
    task run_div_test(
        input [2:0]         f3,
        input [31:0]        op_a,
        input [31:0]        op_b,
        input [31:0]        expected,
        input [8*18-1:0]    test_name
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

            // Wait up to 36 cycles for done
            wait_cycles = 0;
            while (!done && wait_cycles < 36) begin
                @(posedge clk);
                #1;
                wait_cycles = wait_cycles + 1;
            end

            if (!done) begin
                $display("[FAIL] %s: Timeout! 'done' did not assert within 36 cycles.", test_name);
                error_count = error_count + 1;
            end else if (result !== expected) begin
                $display("[FAIL] %s: op_a=0x%08h, op_b=0x%08h | Expected: 0x%08h, Got: 0x%08h",
                         test_name, op_a, op_b, expected, result);
                error_count = error_count + 1;
            end else begin
                $display("[PASS] %s: op_a=0x%08h / 0x%08h -> Result = 0x%08h", 
                         test_name, op_a, op_b, result);
            end

            @(posedge clk);
        end
    endtask

    // -------------------------------------------------------------
    // Main Test Sequence
    // -------------------------------------------------------------
    initial begin
        clk    = 0;
        rst    = 1;
        start  = 0;
        funct3 = 3'b000;
        in_a   = 32'd0;
        in_b   = 32'd0;

        repeat (3) @(posedge clk);
        #1;
        rst <= 0;
        @(posedge clk);

        $display("\n=======================================================");
        $display("          STARTING HARDWARE DIVIDER TESTS             ");
        $display("=======================================================\n");

        // 1. Basic Signed Division (DIV)
        run_div_test(DIV, 32'd20, 32'd5, 32'd4, "DIV pos / pos");
        run_div_test(DIV, -32'd20, 32'd5, -32'd4, "DIV neg / pos");
        run_div_test(DIV, 32'd20, -32'd5, -32'd4, "DIV pos / neg");
        run_div_test(DIV, -32'd20, -32'd5, 32'd4, "DIV neg / neg");
        run_div_test(DIV, 32'd7, 32'd10, 32'd0, "DIV a < b");

        // 2. Basic Unsigned Division (DIVU)
        run_div_test(DIVU, 32'hFFFFFFFF, 32'd2, 32'h7FFFFFFF, "DIVU max_u32 / 2");
        run_div_test(DIVU, 32'd100, 32'd7, 32'd14, "DIVU 100 / 7");

        // 3. Signed Remainder (REM) - sign follows dividend
        run_div_test(REM, 32'd23, 32'd5, 32'd3, "REM pos % pos");
        run_div_test(REM, -32'd23, 32'd5, -32'd3, "REM neg % pos");
        run_div_test(REM, 32'd23, -32'd5, 32'd3, "REM pos % neg");
        run_div_test(REM, -32'd23, -32'd5, -32'd3, "REM neg % neg");

        // 4. Unsigned Remainder (REMU)
        run_div_test(REMU, 32'd100, 32'd7, 32'd2, "REMU 100 % 7");
        run_div_test(REMU, 32'hFFFFFFFF, 32'd10, 32'd5, "REMU max_u32 % 10");

        // 5. RISC-V Mandated Corner Cases
        // Div by zero: DIV/DIVU -> 0xFFFFFFFF, REM/REMU -> in_a
        run_div_test(DIV, 32'd15, 32'd0, 32'hFFFFFFFF, "DIV div-by-zero");
        run_div_test(DIVU, 32'd15, 32'd0, 32'hFFFFFFFF, "DIVU div-by-zero");
        run_div_test(REM, 32'd15, 32'd0, 32'd15, "REM div-by-zero");
        run_div_test(REMU, 32'd15, 32'd0, 32'd15, "REMU div-by-zero");

        // Signed Overflow: INT_MIN / -1 -> INT_MIN, REM -> 0
        run_div_test(DIV, 32'h80000000, 32'hFFFFFFFF, 32'h80000000, "DIV INT_MIN / -1");
        run_div_test(REM, 32'h80000000, 32'hFFFFFFFF, 32'd0, "REM INT_MIN % -1");

        // 6. Protocol Robustness: Reset Mid-Flight
        test_count = test_count + 1;
        $display("[INFO] Running: Reset Mid-Flight Test...");
        @(posedge clk);
        #1;
        start  <= 1'b1;
        funct3 <= DIV;
        in_a   <= 32'd1000;
        in_b   <= 32'd2;

        @(posedge clk);
        #1;
        start <= 1'b0;

        repeat (5) @(posedge clk); // Let it compute 5 cycles
        #1;
        rst <= 1'b1; // Abort with reset

        @(posedge clk);
        #1;
        rst <= 1'b0;

        #1;
        if (busy !== 1'b0 || done !== 1'b0) begin
            $display("[FAIL] Reset Mid-Flight: Multiplier did not return to idle! busy=%b, done=%b", busy, done);
            error_count = error_count + 1;
        end else begin
            $display("[PASS] Reset Mid-Flight: Divider cleanly aborted to IDLE.");
        end

        // Ensure clean recovery after reset
        run_div_test(DIV, 32'd81, 32'd9, 32'd9, "DIV post-abort recovery");

        // ---------------------------------------------------------
        // Summary
        // ---------------------------------------------------------
        $display("\n=======================================================");
        if (error_count == 0) begin
            $display(" ALL %0d DIVIDER TESTS PASSED! ", test_count);
        end else begin
            $display(" DIVIDER TESTS FAILED! Errors: %0d / %0d ", error_count, test_count);
        end
        $display("=======================================================\n");

        $finish;
    end

endmodule