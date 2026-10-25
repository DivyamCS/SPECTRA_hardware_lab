`timescale 1ns / 1ps
`default_nettype none
// core_ctrl - per-core resets and the core count (spec: docs/spec/core_ctrl.md).
// rst_core0 = rst; rst_core1 = rst | !DUAL | !HAS_CORE1, so with DUAL = 1 both cores leave reset
// in the same cycle (and start together at PC 0). ncores = 2 with DUAL = 1, else 1 (NCORES
// register, barrier count). cfg only changes when reset releases (interfaces.md section 4).

module core_ctrl #(
    parameter HAS_CORE1 = 1
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       cfg_dual,        // cfg[2]
    output wire       rst_core0,
    output wire       rst_core1,
    output wire [1:0] ncores
);

    wire dual = cfg_dual && (HAS_CORE1 != 0);

    assign rst_core0 = rst;
    assign rst_core1 = rst || !dual;
    assign ncores    = dual ? 2'd2 : 2'd1;

endmodule

`default_nettype wire
