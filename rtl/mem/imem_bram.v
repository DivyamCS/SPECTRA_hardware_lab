`timescale 1ns / 1ps
`default_nettype none
// imem_bram - 16 KB instruction memory, 4K x 32, two read ports (spec: docs/spec/imem_bram.md).
// Port A feeds core 0, port B core 1; each is a synchronous read with 1-cycle latency, and both
// may read any addresses (the same one included) in the same cycle. Read-only during a run.
// Inferred as block RAM (4 RAMB36 in true dual-port mode) so scripts/updatemem.tcl
// can swap programs into a built bitstream. Initial contents: INIT_FILE (imem.hex).

module imem_bram #(
    parameter INIT_FILE = "imem.hex"
) (
    input  wire        clk,
    input  wire [11:0] addr_a,
    output reg  [31:0] rdata_a,
    input  wire [11:0] addr_b,
    output reg  [31:0] rdata_b
);

    (* ram_style = "block" *) reg [31:0] mem [0:4095];

    integer i;
    initial begin
        for (i = 0; i < 4096; i = i + 1) mem[i] = 32'd0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    always @(posedge clk) rdata_a <= mem[addr_a];
    always @(posedge clk) rdata_b <= mem[addr_b];

endmodule

`default_nettype wire
