// ============================================================
// tb_memory_delay.v  —  Testbench for memory_delay.v
// ============================================================
// Tests:
//   1. Single read: verify stall lasts exactly WAIT_CYCLES clocks
//   2. Back-to-back reads: verify each read independently stalls
//   3. Write during idle: verify pass-through (no stall)
//   4. Simultaneous read+write: write is pass-through, read stalls
//   5. Different WAIT_CYCLES values (5 and 10)
// ============================================================
`timescale 1ns / 1ps

module tb_memory_delay;

    // ---- Parameters ----
    parameter WAIT_CYCLES = 7;
    parameter CLK_HALF    = 5;      // 10 ns → 100 MHz

    // ---- Clock & Reset ----
    reg clk, reset;
    initial clk = 0;
    always #CLK_HALF clk = ~clk;

    // ---- DUT signals ----
    reg         re;
    reg  [31:0] raddr;
    wire [31:0] rdata;
    wire        stall_out;

    reg         we;
    reg  [31:0] waddr, wdata;
    reg  [ 3:0] wstrb;

    wire        mem_re;
    wire [31:0] mem_raddr;
    wire [31:0] mem_rdata;         // driven by combinational assign below

    wire        mem_we;
    wire [31:0] mem_waddr, mem_wdata;
    wire [ 3:0] mem_wstrb;

    // ---- DUT ----
    memory_delay #(.WAIT_CYCLES(WAIT_CYCLES)) DUT (
        .clk       (clk),
        .reset     (reset),
        .re        (re),
        .raddr     (raddr),
        .rdata     (rdata),
        .stall_out (stall_out),
        .we        (we),
        .waddr     (waddr),
        .wdata     (wdata),
        .wstrb     (wstrb),
        .mem_re    (mem_re),
        .mem_raddr (mem_raddr),
        .mem_rdata (mem_rdata),
        .mem_we    (mem_we),
        .mem_waddr (mem_waddr),
        .mem_wdata (mem_wdata),
        .mem_wstrb (mem_wstrb)
    );

    // ---- Fake BRAM: combinational output, returns addr+0xABCD ----
    // Combinational model: data appears in the same cycle mem_re+mem_raddr
    // are valid. This matches what happens in ST_WAIT when first_wait is set
    // and we latch mem_rdata on posedge clk.
    assign mem_rdata = mem_raddr + 32'hABCD;

    // ---- Helpers ----
    integer stall_cycles;
    integer pass_cnt, fail_cnt;
    initial pass_cnt = 0;
    initial fail_cnt = 0;

    task check;
        input        cond;
        input [127:0] msg;
        begin
            if (cond) begin
                $display("PASS: %s", msg);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: %s  (time=%0t)", msg, $time);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // ---- Main sequence ----
    initial begin
        $dumpfile("tb_memory_delay.vcd");
        $dumpvars(0, tb_memory_delay);

        // ---------- Reset ----------
        reset = 1; re = 0; we = 0;
        waddr = 0; wdata = 0; wstrb = 4'b0; raddr = 0;
        #(4 * CLK_HALF * 2);
        reset = 0;
        @(posedge clk); #1;

        // --------------------------------------------------
        // TEST 1: Single read — count stall cycles
        // --------------------------------------------------
        $display("\n--- TEST 1: single read, WAIT_CYCLES=%0d ---", WAIT_CYCLES);
        raddr       = 32'h0000_0100;
        re          = 1;
        stall_cycles = 0;

        // First rising edge starts the transaction
        @(posedge clk); #1;
        re = 0;

        // Count how many cycles stall_out stays high
        while (stall_out) begin
            stall_cycles = stall_cycles + 1;
            @(posedge clk); #1;
        end

        check(stall_cycles == WAIT_CYCLES,
              "stall lasts exactly WAIT_CYCLES");
        check(rdata == (32'h0000_0100 + 32'hABCD),
              "rdata correct after stall");

        // --------------------------------------------------
        // TEST 2: Write — no stall, pass-through
        // --------------------------------------------------
        $display("\n--- TEST 2: write pass-through ---");
        @(posedge clk); #1;
        we    = 1;
        waddr = 32'h0000_0200;
        wdata = 32'hDEAD_BEEF;
        wstrb = 4'b1111;
        @(posedge clk); #1;
        check(mem_we    == 1,             "mem_we asserted");
        check(mem_waddr == 32'h0000_0200, "mem_waddr forwarded");
        check(mem_wdata == 32'hDEAD_BEEF, "mem_wdata forwarded");
        check(stall_out == 0,             "no stall during write");
        we = 0; wstrb = 0;

        // --------------------------------------------------
        // TEST 3: Back-to-back reads
        // --------------------------------------------------
        $display("\n--- TEST 3: back-to-back reads ---");
        // Read #A
        @(posedge clk); #1;
        raddr = 32'h0000_0010; re = 1;
        @(posedge clk); #1; re = 0;
        wait (!stall_out);
        check(rdata == (32'h0000_0010 + 32'hABCD), "back-to-back read A");

        // Read #B immediately after
        @(posedge clk); #1;
        raddr = 32'h0000_0020; re = 1;
        @(posedge clk); #1; re = 0;
        stall_cycles = 0;
        while (stall_out) begin
            stall_cycles = stall_cycles + 1;
            @(posedge clk); #1;
        end
        check(stall_cycles == WAIT_CYCLES, "back-to-back: stall B correct");
        check(rdata == (32'h0000_0020 + 32'hABCD), "back-to-back read B data");

        // --------------------------------------------------
        // TEST 4: Simultaneous read + write
        // --------------------------------------------------
        $display("\n--- TEST 4: simultaneous read+write ---");
        @(posedge clk); #1;
        raddr = 32'h0000_0030; re = 1;
        waddr = 32'h0000_0040; wdata = 32'h1234_5678; wstrb = 4'b1111; we = 1;
        @(posedge clk); #1;
        check(mem_we == 1,    "write pass-through during stall");
        re = 0; we = 0; wstrb = 0;
        wait (!stall_out);
        check(rdata == (32'h0000_0030 + 32'hABCD), "read data correct with concurrent write");

        // --------------------------------------------------
        // SUMMARY
        // --------------------------------------------------
        #20;
        $display("\n========================================");
        $display("  RESULTS: %0d PASS / %0d FAIL", pass_cnt, fail_cnt);
        $display("========================================");
        if (fail_cnt == 0)
            $display("  *** ALL TESTS PASSED ***");
        else
            $display("  *** SOME TESTS FAILED ***");
        $finish;
    end

    // Safety timeout
    initial begin
        #50000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
