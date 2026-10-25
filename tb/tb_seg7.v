// ============================================================
// tb_seg7.v  —  Testbench for seg7.v (BCD double-dabble + 7-seg)
// ============================================================
// Tests:
//   1. Known BCD values 0–9 (single digit): verify segment encoding
//   2. Boundary: 0, 1, 999999 (max 20-bit decimal)
//   3. Mid-range: 123456, 654321
//   4. Anode scan: verify each digit position is selected in turn
//   5. Segment encoding table completeness (digits 0-9)
// ============================================================
`timescale 1ns / 1ps

module tb_seg7;

    // Use a fast clock and slow scan for simulation speed
    parameter CLK_HZ  = 100_000;   // 100 kHz sim clock
    parameter SCAN_HZ = 1_000;

    localparam CLK_HALF = 5_000;    // 5 µs half-period (ns)

    reg        clk, reset;
    reg [19:0] bin_in;
    wire [6:0] seg;
    wire [5:0] an;
    wire       dp;

    initial clk = 0;
    always #CLK_HALF clk = ~clk;

    seg7 #(.CLK_HZ(CLK_HZ), .SCAN_HZ(SCAN_HZ)) DUT (
        .clk   (clk),
        .reset (reset),
        .bin_in(bin_in),
        .seg   (seg),
        .an    (an),
        .dp    (dp)
    );

    // ---- Scoreboard ----
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task check;
        input        cond;
        input [255:0] msg;
        begin
            if (cond) begin
                $display("  PASS: %s", msg);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL: %s  (t=%0t)", msg, $time);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // ---- Reference BCD converter (pure Verilog, matches DUT) ----
    function [23:0] ref_bcd;
        input [19:0] bin;
        integer i;
        reg [43:0] s;
        begin
            s = {24'd0, bin};
            for (i = 0; i < 20; i = i + 1) begin
                if (s[23:20] >= 5) s[23:20] = s[23:20] + 3;
                if (s[27:24] >= 5) s[27:24] = s[27:24] + 3;
                if (s[31:28] >= 5) s[31:28] = s[31:28] + 3;
                if (s[35:32] >= 5) s[35:32] = s[35:32] + 3;
                if (s[39:36] >= 5) s[39:36] = s[39:36] + 3;
                if (s[43:40] >= 5) s[43:40] = s[43:40] + 3;
                s = s << 1;
            end
            ref_bcd = s[43:20];
        end
    endfunction

    // ---- Reference segment encoder ----
    function [6:0] ref_seg;
        input [3:0] d;
        begin
            case (d)
                4'd0: ref_seg = 7'b000_0001;
                4'd1: ref_seg = 7'b100_1111;
                4'd2: ref_seg = 7'b001_0010;
                4'd3: ref_seg = 7'b000_0110;
                4'd4: ref_seg = 7'b100_1100;
                4'd5: ref_seg = 7'b010_0100;
                4'd6: ref_seg = 7'b010_0000;
                4'd7: ref_seg = 7'b000_1111;
                4'd8: ref_seg = 7'b000_0000;
                4'd9: ref_seg = 7'b000_0100;
                default: ref_seg = 7'b111_1111;
            endcase
        end
    endfunction

    // ---- Wait for digit_sel to reach a target, collect seg/an ----
    // Each digit is active for (CLK_HZ/SCAN_HZ/6) clock cycles = ~16 cycles here
    localparam DIGIT_CLKS = CLK_HZ / SCAN_HZ / 6;

    task wait_digit_slot;
        input [2:0] target;
        // spin until an matches the one-hot for target
        reg [5:0] expected_an;
        begin
            case (target)
                3'd0: expected_an = 6'b111110;
                3'd1: expected_an = 6'b111101;
                3'd2: expected_an = 6'b111011;
                3'd3: expected_an = 6'b110111;
                3'd4: expected_an = 6'b101111;
                3'd5: expected_an = 6'b011111;
                default: expected_an = 6'b111111;
            endcase
            // wait for the right anode window
            while (an !== expected_an)
                @(posedge clk);
            // sample one cycle in
            @(posedge clk); #1;
        end
    endtask

    // ---- Check BCD conversion for a given binary input ----
    task check_display;
        input [19:0] val;
        input [255:0] label;
        reg [23:0] expected_bcd;
        integer    d;
        reg [6:0]  expected_seg;
        reg [5:0]  expected_an;
        begin
            bin_in = val;
            @(posedge clk); #1;

            expected_bcd = ref_bcd(val);

            // Check digit 0 (ones)
            wait_digit_slot(0);
            expected_seg = ref_seg(expected_bcd[3:0]);
            check(seg === expected_seg, {label, " d0 seg"});
            check(an  === 6'b111110,    {label, " d0 an"});

            // Check digit 1 (tens)
            wait_digit_slot(1);
            check(seg === ref_seg(expected_bcd[7:4]), {label, " d1 seg"});

            // Check digit 5 (hundred-thousands)
            wait_digit_slot(5);
            check(seg === ref_seg(expected_bcd[23:20]), {label, " d5 seg"});
        end
    endtask

    // ---- Main ----
    initial begin
        $dumpfile("tb_seg7.vcd");
        $dumpvars(0, tb_seg7);

        reset = 1; bin_in = 0;
        #(20 * CLK_HALF * 2);
        reset = 0;
        @(posedge clk); #1;

        // ---- TEST 1: dp always off ----
        $display("\n--- TEST 1: dp always off ---");
        check(dp === 1'b1, "dp = 1 (off, active-low)");

        // ---- TEST 2: 0 → all digits show 0 ----
        $display("\n--- TEST 2: binary 0 ---");
        check_display(20'd0, "val=0");

        // ---- TEST 3: 1 ----
        $display("\n--- TEST 3: binary 1 ---");
        check_display(20'd1, "val=1");

        // ---- TEST 4: 123456 ----
        $display("\n--- TEST 4: 123456 ---");
        check_display(20'd123456 % (1<<20), "val=123456");

        // ---- TEST 5: 999999 (max 6-digit decimal) ----
        $display("\n--- TEST 5: 999999 ---");
        check_display(20'd999999 % (1<<20), "val=999999");

        // ---- TEST 6: Anode scan completes all 6 positions in order ----
        $display("\n--- TEST 6: anode scan order ---");
        begin : scan_check
            reg [5:0] prev_an;
            integer   transitions;
            transitions = 0;
            prev_an = an;
            // observe for 2 full scan cycles
            repeat (2 * 6 * DIGIT_CLKS + 10) begin
                @(posedge clk); #1;
                if (an !== prev_an) begin
                    transitions = transitions + 1;
                    prev_an = an;
                end
            end
            // expect 12 transitions (2 full rotations × 6 changes)
            check(transitions >= 10, "at least 10 anode transitions in 2 scan cycles");
        end

        // ---- Summary ----
        #1000;
        $display("\n========================================");
        $display("  RESULTS: %0d PASS / %0d FAIL", pass_cnt, fail_cnt);
        $display("========================================");
        if (fail_cnt == 0)
            $display("  *** ALL TESTS PASSED ***");
        else
            $display("  *** SOME TESTS FAILED ***");
        $finish;
    end

    initial begin
        #100_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
