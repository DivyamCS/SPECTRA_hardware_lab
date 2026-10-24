`timescale 1ns / 1ps

module tb_memory;

    reg clk;
    reg reset;

    // Instruction memory signals
    reg  [31:0] pc;
    wire [31:0] instr;

    // Data memory signals
    reg         re;
    reg  [31:0] raddr;
    wire [31:0] rdata;

    reg         we;
    reg  [31:0] waddr;
    reg  [31:0] wdata;
    reg  [3:0]  wstrb;

    integer errors;
    integer i;

    // --------------------------------------------------------
    // DUTs
    // --------------------------------------------------------

    instr_mem IMEM (
        .clk   (clk),
        .reset (reset),
        .pc    (pc),
        .instr (instr)
    );

    data_mem DMEM (
        .clk   (clk),
        .reset (reset),
        .re    (re),
        .raddr (raddr),
        .rdata (rdata),
        .we    (we),
        .waddr (waddr),
        .wdata (wdata),
        .wstrb (wstrb)
    );

    // 100 MHz clock
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // --------------------------------------------------------
    // Test sequence
    // --------------------------------------------------------

    initial begin
        reset = 1'b1;

        pc    = 32'd0;
        re    = 1'b0;
        raddr = 32'd0;
        we    = 1'b0;
        waddr = 32'd0;
        wdata = 32'd0;
        wstrb = 4'b0000;

        errors = 0;

        // Initialize memories explicitly so the test does not
        // depend on external imem.hex/dmem.hex files.
        #1;

        for (i = 0; i < 1024; i = i + 1) begin
            IMEM.imem[i] = 32'h00000013;
            DMEM.dmem[i] = 32'h00000000;
        end

        IMEM.imem[0] = 32'h00500093;
        IMEM.imem[1] = 32'h00A00113;
        IMEM.imem[2] = 32'h002081B3;

        repeat (2) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // ----------------------------------------------------
        // Test 1: synchronous instruction fetch
        // ----------------------------------------------------

        pc = 32'd0;
        @(posedge clk);
        #1;

        if (instr !== 32'h00500093) begin
            $display("FAIL: instruction fetch address 0");
            $display("  Expected: 00500093, got: %08h", instr);
            errors = errors + 1;
        end
        else
            $display("PASS: instruction fetch address 0");

        @(negedge clk);
        pc = 32'd4;

        @(posedge clk);
        #1;

        if (instr !== 32'h00A00113) begin
            $display("FAIL: instruction fetch address 4");
            $display("  Expected: 00A00113, got: %08h", instr);
            errors = errors + 1;
        end
        else
            $display("PASS: instruction fetch address 4");

        // ----------------------------------------------------
        // Test 2: full-word data write
        // ----------------------------------------------------

        @(negedge clk);
        we    = 1'b1;
        waddr = 32'd0;
        wdata = 32'h11223344;
        wstrb = 4'b1111;
        re    = 1'b0;

        @(posedge clk);
        #1;

        if (DMEM.dmem[0] !== 32'h11223344) begin
            $display("FAIL: full-word write");
            $display("  Expected: 11223344, got: %08h",
                     DMEM.dmem[0]);
            errors = errors + 1;
        end
        else
            $display("PASS: full-word write");

        // ----------------------------------------------------
        // Test 3: synchronous data read
        // ----------------------------------------------------

        @(negedge clk);
        we    = 1'b0;
        wstrb = 4'b0000;
        re    = 1'b1;
        raddr = 32'd0;

        @(posedge clk);
        #1;

        if (rdata !== 32'h11223344) begin
            $display("FAIL: data read");
            $display("  Expected: 11223344, got: %08h", rdata);
            errors = errors + 1;
        end
        else
            $display("PASS: data read");

        // ----------------------------------------------------
        // Test 4: byte-enable write
        //
        // Replace only byte 3 (bits 31:24):
        // 11223344 -> AA223344
        // ----------------------------------------------------

        @(negedge clk);
        re    = 1'b0;
        we    = 1'b1;
        waddr = 32'd0;
        wdata = 32'hAA000000;
        wstrb = 4'b1000;

        @(posedge clk);
        #1;

        if (DMEM.dmem[0] !== 32'hAA223344) begin
            $display("FAIL: byte-enable write");
            $display("  Expected: AA223344, got: %08h",
                     DMEM.dmem[0]);
            errors = errors + 1;
        end
        else
            $display("PASS: byte-enable write");

        // ----------------------------------------------------
        // Test 5: simultaneous read and write to same word
        //
        // Verify byte-level forwarding on the read output.
        // ----------------------------------------------------

        @(negedge clk);
        re    = 1'b1;
        raddr = 32'd0;

        we    = 1'b1;
        waddr = 32'd0;
        wdata = 32'h0000BB00;
        wstrb = 4'b0010;

        @(posedge clk);
        #1;

        if (rdata !== 32'hAA22BB44) begin
            $display("FAIL: read-after-write forwarding");
            $display("  Expected: AA22BB44, got: %08h", rdata);
            errors = errors + 1;
        end
        else
            $display("PASS: read-after-write forwarding");

        // ----------------------------------------------------
        // Test 6: disabled write must not modify memory
        // ----------------------------------------------------

        @(negedge clk);
        re    = 1'b0;
        we    = 1'b0;
        wstrb = 4'b0000;

        @(posedge clk);
        #1;

        if (DMEM.dmem[0] !== 32'hAA22BB44) begin
            $display("FAIL: memory changed with write disabled");
            errors = errors + 1;
        end
        else
            $display("PASS: disabled write leaves memory unchanged");

        // ----------------------------------------------------
        // Summary
        // ----------------------------------------------------

        $display("");
        $display("========================================");

        if (errors == 0)
            $display("ALL MEMORY TESTS PASSED.");
        else
            $display("MEMORY TESTS FAILED: %0d error(s).", errors);

        $display("========================================");

        $finish;
    end

endmodule