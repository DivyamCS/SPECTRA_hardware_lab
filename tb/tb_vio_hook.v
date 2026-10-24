`timescale 1ns / 1ps
`default_nettype none
// tb_vio_hook - vio_hook with a stub of the VIO IP (vio_0 below; the build uses the real core).
// Checks, at 1 ns after every clk edge, 3,000 cycles with the pins changing at random times
// between edges:
//  * ovr_en = 0: sw / btn = the pins as sampled two clk edges earlier (2-flop synchroniser),
//    so they change only on clk edges;
//  * ovr_en = 1: sw / btn = ovr_sw / ovr_btn, whatever the pins do;
//  * the probe inputs carry leds, seg7_val, seg7_dp, uart_busy and seg7_txt.
// Prints one PASS/FAIL line.

module vio_0 (
    input  wire        clk,
    input  wire [15:0] probe_in0,
    input  wire [31:0] probe_in1,
    input  wire [7:0]  probe_in2,
    input  wire        probe_in3,
    input  wire [31:0] probe_in4,
    output reg         probe_out0 = 1'b0,
    output reg  [15:0] probe_out1 = 16'd0,
    output reg  [4:0]  probe_out2 = 5'd0
);
endmodule

module tb_vio_hook;

    reg clk = 1'b0;
    always #10 clk = ~clk;
    reg  [15:0] sw_pin = 16'd0, leds = 16'h1234;
    reg  [4:0]  btn_pin = 5'd0;
    reg  [31:0] seg7_val = 32'h00ABCDEF;
    reg  [7:0]  seg7_dp = 8'h24;
    reg         uart_busy = 1'b1;
    reg  [31:0] seg7_txt = 32'h17300000;
    wire [15:0] sw;
    wire [4:0]  btn;

    vio_hook #(.HAS_VIO(1)) dut (.clk(clk), .sw_pin(sw_pin), .btn_pin(btn_pin), .sw(sw), .btn(btn),
        .leds(leds), .seg7_val(seg7_val), .seg7_dp(seg7_dp), .seg7_txt(seg7_txt), .uart_busy(uart_busy));

    integer errors = 0, checks = 0, i, seed = 95;
    reg [20:0] at_edge [0:2];          // {btn, sw} pins at the last three clk edges (0 = newest)
    always @(posedge clk) begin
        at_edge[2] <= at_edge[1]; at_edge[1] <= at_edge[0]; at_edge[0] <= {btn_pin, sw_pin};
    end
    // the pins change at random times, never within 2 ns of a clk edge
    always @(posedge clk) begin
        #(3 + ($unsigned($random(seed)) % 14));
        if ($unsigned($random(seed)) % 3 == 0) sw_pin = $random(seed);
        if ($unsigned($random(seed)) % 3 == 0) btn_pin = $random(seed);
    end

    task check(input [8*40-1:0] what, input [20:0] got, input [20:0] want);
        begin
            checks = checks + 1;
            if (got !== want) begin
                errors = errors + 1;
                if (errors < 6) $display("%0s: got %h want %h (t=%0t)", what, got, want, $time);
            end
        end
    endtask

    initial begin
        at_edge[0] = 21'd0; at_edge[1] = 21'd0; at_edge[2] = 21'd0;
        repeat (4) @(posedge clk);
        for (i = 0; i < 3000; i = i + 1) begin
            if (i == 1000) begin                         // override on, between edges
                #7 dut.g_vio.u_vio.probe_out1 = 16'hBEEF; dut.g_vio.u_vio.probe_out2 = 5'h15;
                dut.g_vio.u_vio.probe_out0 = 1'b1;
            end
            if (i == 2000) begin #7 dut.g_vio.u_vio.probe_out0 = 1'b0; end
            @(posedge clk); #1;
            if (i >= 1003 && i < 2000)
                check("override", {btn, sw}, {5'h15, 16'hBEEF});
            else if ((i >= 3 && i < 1000) || i >= 2003)
                check("pins two edges late", {btn, sw}, at_edge[1]);
        end
        check("probe_in0 = leds", {5'd0, dut.g_vio.u_vio.probe_in0}, {5'd0, leds});
        check("probe_in1 = seg7_val", dut.g_vio.u_vio.probe_in1[20:0], seg7_val[20:0]);
        check("probe_in2/3", {12'd0, dut.g_vio.u_vio.probe_in2, dut.g_vio.u_vio.probe_in3}, {12'd0, seg7_dp, uart_busy});
        check("probe_in4 = seg7_txt (low)", dut.g_vio.u_vio.probe_in4[20:0], seg7_txt[20:0]);
        check("probe_in4 = seg7_txt (high)", {10'd0, dut.g_vio.u_vio.probe_in4[31:21]}, {10'd0, seg7_txt[31:21]});
        if (errors == 0 && checks > 2900)
            $display("PASS vio_hook (%0d checks: pins two clk edges late, override, probes)", checks);
        else
            $display("FAIL vio_hook: %0d errors of %0d checks", errors, checks);
        $finish;
    end

endmodule

`default_nettype wire
