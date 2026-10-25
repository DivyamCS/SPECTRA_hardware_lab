`timescale 1ns / 1ps
`default_nettype none
// clk_rst - 50 MHz system clock and reset (spec: docs/spec/clk_rst.md).
// MMCME2_BASE: 100 MHz in (E3), VCO 1000 MHz (x10), CLKOUT0 / 20 = 50 MHz through a BUFG.
// rst is a plain clk-synchronous register with no asynchronous set or reset anywhere: a 2-flop
// synchroniser samples btn_rst (BTNC, already synchronised by vio_hook) or !locked, so rst
// rises 2-3 clk cycles after a press and falls 16 cycles after both clear. (An asynchronous rst
// drives block RAM address / enable logic, where an edge between clocks can corrupt a write:
// DRC REQP-1839/1840; logic before an asynchronous set: CDC-7.) Power-up: rst = 1 (initial
// values). Replaces the lab's register-divided 1 Hz clock.

module clk_rst (
    input  wire clk100,
    input  wire btn_rst,               // BTNC after vio_hook (synchronised, VIO override), active high
    output wire clk,
    output reg  rst,
    output wire locked
);

    wire clkfb, clk_mmcm;

    MMCME2_BASE #(
        .CLKIN1_PERIOD   (10.0),
        .DIVCLK_DIVIDE   (1),
        .CLKFBOUT_MULT_F (10.0),       // VCO 1000 MHz
        .CLKOUT0_DIVIDE_F(20.0)        // 50 MHz
    ) u_mmcm (
        .CLKIN1(clk100), .CLKFBIN(clkfb), .CLKFBOUT(clkfb), .CLKOUT0(clk_mmcm),
        .LOCKED(locked), .PWRDWN(1'b0), .RST(1'b0),
        .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(),
        .CLKOUT4(), .CLKOUT5(), .CLKOUT6(), .CLKFBOUTB());

    BUFG u_bufg (.I(clk_mmcm), .O(clk));

    wire       req  = btn_rst || !locked;
    (* ASYNC_REG = "TRUE" *) reg [1:0] sync = 2'b11;   // 2-flop synchroniser (locked is asynchronous)
    reg  [4:0] cnt  = 5'd0;            // then 16 cycles
    initial rst = 1'b1;

    always @(posedge clk) begin
        sync <= {sync[0], req};
        if (sync[1])            cnt <= 5'd0;
        else if (cnt != 5'd16)  cnt <= cnt + 5'd1;
        rst <= sync[1] || (cnt != 5'd16);
    end

endmodule

`default_nettype wire
