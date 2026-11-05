`timescale 1ns / 1ps
`default_nettype none
// regfile - 32 x 32-bit register file, x0 = 0 (spec: docs/spec/regfile.md).
// Two combinational read ports (used in ID) and one write port (MEM/WB). Write-through: a
// register written in a cycle is read with its new value in that same cycle, which covers
// dependences at distance 2; distance 1 is covered by forwarding in EX (hazard_unit).
// x1-x31 reset to 0, as lab 5A and rv32sim's initial state.

// verified & regression tests passed

module regfile (
    input  wire        clk,
    input  wire        rst,
    input  wire [4:0]  raddr1,
    input  wire [4:0]  raddr2,
    output wire [31:0] rdata1,
    output wire [31:0] rdata2,
    input  wire        we,
    input  wire [4:0]  waddr,
    input  wire [31:0] wdata
);

    reg [31:0] regs [1:31];
    integer i;

    always @(posedge clk) begin
        if (rst) begin
            for (i = 1; i < 32; i = i + 1)
                regs[i] <= 32'd0;
        end else if (we && waddr != 5'd0) begin
            regs[waddr] <= wdata;
        end
    end

    wire wt1 = we && (waddr == raddr1);
    wire wt2 = we && (waddr == raddr2);

    assign rdata1 = (raddr1 == 5'd0) ? 32'd0 : wt1 ? wdata : regs[raddr1];
    assign rdata2 = (raddr2 == 5'd0) ? 32'd0 : wt2 ? wdata : regs[raddr2];

endmodule

`default_nettype wire
