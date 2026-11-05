`timescale 1ns / 1ps
`default_nettype none
// top_fpga - the Nexys A7-100T top (spec: docs/spec/top_fpga.md; pins in rtl/board/nexys_a7.xdc).
// Wrapper only: clk_rst (MMCM 50 MHz, BTNC reset), vio_hook (JTAG override of the switches and
// buttons, LED / SEG7 / UART-busy probes) and soc_top. SHELL = 1 builds the board shell:
// no cores, shell_driver on the data port (RUN_START once, then SWITCHES -> SEG7 and LEDS).

// verified & regression tests passed

module top_fpga #(
    parameter SHELL     = 0,
    parameter HAS_CORE1 = 1,
    parameter HAS_VIO   = 1,
    parameter HAS_MD     = 1,          // removal parameters (area builds)
    parameter HAS_FWD    = 1,
    parameter HAS_ICACHE = 1,
    parameter HAS_DCACHE = 1
) (
    input  wire        clk100,
    input  wire        btnc, btnl, btnr, btnu, btnd,
    input  wire [15:0] sw,
    output wire [15:0] led,
    output wire [7:0]  an,
    output wire [6:0]  seg,
    output wire        dp_n,
    output wire        uart_tx
);

    wire        clk, rst, locked;
    wire [15:0] sw_i;
    wire [4:0]  btn_i;
    wire [26:0] seg7_val;
    wire [7:0]  seg7_dp;
    wire [31:0] seg7_txt;
    wire        uart_busy;

    vio_hook #(.HAS_VIO(HAS_VIO)) u_vio_hook (.clk(clk), .sw_pin(sw), .btn_pin({btnd, btnu, btnr, btnl, btnc}),
        .sw(sw_i), .btn(btn_i), .leds(led), .seg7_val({5'd0, seg7_val}), .seg7_dp(seg7_dp), .seg7_txt(seg7_txt),
        .uart_busy(uart_busy));
    clk_rst u_clk (.clk100(clk100), .btn_rst(btn_i[0]), .clk(clk), .rst(rst), .locked(locked));
    soc_top #(.HAS_CORES(SHELL ? 0 : 1), .HAS_CORE1(HAS_CORE1), .HAS_MD(HAS_MD), .HAS_FWD(HAS_FWD),
              .HAS_ICACHE(HAS_ICACHE), .HAS_DCACHE(HAS_DCACHE)) u_soc (.clk(clk), .rst(rst), .sw(sw_i),
        .btn(btn_i[4:1]), .led(led), .an(an), .seg(seg), .dp_n(dp_n), .uart_tx(uart_tx),
        .seg7_val(seg7_val), .seg7_dp(seg7_dp), .seg7_txt(seg7_txt), .uart_busy(uart_busy));

endmodule

`default_nettype wire
