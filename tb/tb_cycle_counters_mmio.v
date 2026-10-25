// ============================================================
// tb_cycle_counters_mmio.v  —  Testbench for cycle_counters +
//                              mmio_decoder (Task 5)
// ============================================================
`timescale 1ns / 1ps

module tb_cycle_counters_mmio;

    reg clk, reset;
    initial clk = 0;
    always #5 clk = ~clk;   // 100 MHz

    // ---- cycle_counters DUT ----
    reg         instret_en;
    wire [31:0] cycle_cnt, instret_cnt;

    cycle_counters PC (
        .clk         (clk),
        .reset       (reset),
        .instret_en  (instret_en),
        .cycle_cnt_o (cycle_cnt),
        .instret_cnt_o(instret_cnt)
    );

    // ---- mmio_decoder DUT ----
    reg        we, re;
    reg [31:0] waddr, raddr, wdata;
    reg [ 3:0] wstrb;
    wire [31:0] rdata;
    wire [ 7:0] uart_din;
    wire        uart_valid;
    wire [19:0] seg7_val;
    wire        core1_release;

    mmio_decoder #(.CORE_ID(0)) MMIO (
        .clk          (clk),
        .reset        (reset),
        .we           (we),
        .waddr        (waddr),
        .wdata        (wdata),
        .wstrb        (wstrb),
        .re           (re),
        .raddr        (raddr),
        .rdata        (rdata),
        .uart_din     (uart_din),
        .uart_valid   (uart_valid),
        .uart_busy    (1'b0),
        .seg7_val     (seg7_val),
        .core1_release(core1_release),
        .lock_reg     (),
        .barrier_cnt  (),
        .barrier_rel  (),
        .cache_ctrl   (),
        .cycle_cnt    (cycle_cnt),
        .instret_cnt  (instret_cnt)
    );

    integer pass_cnt = 0, fail_cnt = 0;
    task check;
        input cond;
        input [255:0] msg;
        begin
            if (cond) begin $display("  PASS: %s", msg); pass_cnt = pass_cnt+1; end
            else       begin $display("  FAIL: %s (t=%0t)", msg, $time); fail_cnt = fail_cnt+1; end
        end
    endtask

    integer i;
    initial begin
        $dumpfile("tb_cycle_counters_mmio.vcd");
        $dumpvars(0, tb_cycle_counters_mmio);

        reset = 1; we = 0; re = 0; waddr = 0; wdata = 0;
        wstrb = 4'hF; raddr = 0; instret_en = 0;
        repeat(4) @(posedge clk); #1;
        reset = 0;

        // ---- TEST 1: cycle counter advances ----
        $display("\n--- TEST 1: cycle counter ---");
        @(posedge clk); #1;
        begin : t1
            reg [31:0] c0, c1;
            c0 = cycle_cnt;
            repeat(10) @(posedge clk); #1;
            c1 = cycle_cnt;
            check(c1 == c0 + 10, "cycle_cnt advances by 10 in 10 clocks");
        end

        // ---- TEST 2: instret counter ----
        $display("\n--- TEST 2: instret counter ---");
        begin : t2
            reg [31:0] i0;
            i0 = instret_cnt;
            repeat(5) begin
                instret_en = 1; @(posedge clk); #1;
                instret_en = 0; @(posedge clk); #1;
            end
            check(instret_cnt == i0 + 5, "instret_cnt incremented 5 times");
        end

        // ---- TEST 3: UART write via MMIO ----
        $display("\n--- TEST 3: UART write ---");
        @(posedge clk); #1;
        we = 1; waddr = 32'h8000_0000; wdata = 32'h41; wstrb = 4'hF;
        @(posedge clk); #1;
        we = 0;
        @(posedge clk); #1;
        check(uart_valid == 0,    "uart_valid deasserts after 1 cycle");
        check(uart_din  == 8'h41, "uart_din = 'A' (0x41)");

        // ---- TEST 4: SEG7 write via MMIO ----
        $display("\n--- TEST 4: SEG7 write ---");
        @(posedge clk); #1;
        we = 1; waddr = 32'h8000_0010; wdata = 32'd12345;
        @(posedge clk); #1; we = 0;
        @(posedge clk); #1;
        check(seg7_val == 20'd12345, "seg7_val updated to 12345");

        // ---- TEST 5: MMIO read CORE_ID ----
        $display("\n--- TEST 5: CORE_ID read ---");
        re = 1; raddr = 32'h8000_0020;
        #1;
        check(rdata == 32'd0, "CORE_ID reads 0 for core 0");
        re = 0;

        // ---- TEST 6: MMIO read cycle_cnt ----
        $display("\n--- TEST 6: cycle_cnt via MMIO ---");
        re = 1; raddr = 32'h8000_0040; #1;
        check(rdata == cycle_cnt, "MMIO cycle_cnt matches cycle_counters output");
        re = 0;

        // ---- TEST 7: core1_release ----
        $display("\n--- TEST 7: core1_release ---");
        we = 1; waddr = 32'h8000_003C; wdata = 32'd1;
        @(posedge clk); #1; we = 0;
        @(posedge clk); #1;
        check(core1_release == 1'b1, "core1_release asserted");

        // ---- TEST 8: unmapped address reads DEADBEEF ----
        $display("\n--- TEST 8: unmapped MMIO read ---");
        re = 1; raddr = 32'h8000_00F0; #1;
        check(rdata == 32'hDEAD_BEEF, "unmapped address returns DEADBEEF");
        re = 0;

        #20;
        $display("\n========================================");
        $display("  RESULTS: %0d PASS / %0d FAIL", pass_cnt, fail_cnt);
        $display("========================================");
        if (fail_cnt == 0) $display("  *** ALL TESTS PASSED ***");
        $finish;
    end

    initial begin #50000; $display("TIMEOUT"); $finish; end

endmodule
