// ============================================================
// tb_sw_counter_display.v  —  Testbench for sw_counter_display
//                              (Task 8)
// ============================================================
`timescale 1ns / 1ps

module tb_sw_counter_display;

    reg clk, reset;
    initial clk = 0;
    always #5 clk = ~clk;   // 100 MHz clock

    reg  [ 3:0] sw;
    reg  [31:0] cycle_cnt;
    reg  [31:0] instret_cnt;
    reg  [31:0] pc;
    reg  [19:0] mmio_seg7_val;

    wire [19:0] display_val;
    wire [ 2:0] mode_status;

    sw_counter_display DUT (
        .clk           (clk),
        .reset         (reset),
        .sw            (sw),
        .cycle_cnt     (cycle_cnt),
        .instret_cnt   (instret_cnt),
        .pc            (pc),
        .mmio_seg7_val (mmio_seg7_val),
        .display_val   (display_val),
        .mode_status   (mode_status)
    );

    integer pass_cnt = 0, fail_cnt = 0;
    task check;
        input cond;
        input [255:0] msg;
        begin
            if (cond) begin
                $display("  PASS: %s", msg);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL: %s (t=%0t)", msg, $time);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_sw_counter_display.vcd");
        $dumpvars(0, tb_sw_counter_display);

        reset         = 1;
        sw            = 4'd0;
        cycle_cnt     = 32'd12_345_678;
        instret_cnt   = 32'd7_890_123;
        pc            = 32'h0000_1048;
        mmio_seg7_val = 20'd99_999;

        repeat (4) @(posedge clk);
        reset = 0;
        @(posedge clk); #1;

        // ---- TEST 1: Mode 4'b0000 -> cycle_cnt lower 6 digits (345678) ----
        $display("\n--- TEST 1: SW 0000 -> cycle_cnt low ---");
        sw = 4'b0000;
        repeat (4) @(posedge clk); #1;
        check(display_val == 20'd345678, "display_val = cycle_cnt % 1M (345678)");
        check(mode_status == 3'd0, "mode_status = 0");

        // ---- TEST 2: Mode 4'b0001 -> cycle_cnt upper digits (12) ----
        $display("\n--- TEST 2: SW 0001 -> cycle_cnt high ---");
        sw = 4'b0001;
        repeat (4) @(posedge clk); #1;
        check(display_val == 20'd12, "display_val = cycle_cnt / 1M (12)");
        check(mode_status == 3'd1, "mode_status = 1");

        // ---- TEST 3: Mode 4'b0010 -> instret lower 6 digits (890123) ----
        $display("\n--- TEST 3: SW 0010 -> instret low ---");
        sw = 4'b0010;
        repeat (4) @(posedge clk); #1;
        check(display_val == 20'd890123, "display_val = instret % 1M (890123)");
        check(mode_status == 3'd2, "mode_status = 2");

        // ---- TEST 4: Mode 4'b0011 -> instret upper digits (7) ----
        $display("\n--- TEST 4: SW 0011 -> instret high ---");
        sw = 4'b0011;
        repeat (4) @(posedge clk); #1;
        check(display_val == 20'd7, "display_val = instret / 1M (7)");
        check(mode_status == 3'd3, "mode_status = 3");

        // ---- TEST 5: Mode 4'b0100 -> Program Counter (0x1048 = 4168) ----
        $display("\n--- TEST 5: SW 0100 -> PC ---");
        sw = 4'b0100;
        repeat (4) @(posedge clk); #1;
        check(display_val == 20'h01048, "display_val = PC[19:0]");
        check(mode_status == 3'd4, "mode_status = 4");

        // ---- TEST 6: Mode 4'b0101 -> Software MMIO override (99999) ----
        $display("\n--- TEST 6: SW 0101 -> MMIO override ---");
        sw = 4'b0101;
        repeat (4) @(posedge clk); #1;
        check(display_val == 20'd99999, "display_val = mmio_seg7_val (99999)");
        check(mode_status == 3'd5, "mode_status = 5");

        #20;
        $display("\n========================================");
        $display("  RESULTS: %0d PASS / %0d FAIL", pass_cnt, fail_cnt);
        $display("========================================");
        if (fail_cnt == 0) $display("  *** ALL TESTS PASSED ***");
        $finish;
    end

    initial begin #50000; $display("TIMEOUT"); $finish; end

endmodule
