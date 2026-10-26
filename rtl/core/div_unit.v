`timescale 1ns / 1ps
// div_unit - adapter: the project's DIV interface onto Hiya's div.v
module div_unit (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [1:0]  op,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire        busy,
    output wire        done,
    output wire [31:0] result
);
    div u (.clk(clk), .rst(rst), .start(start), .funct3({1'b1, op}), .in_a(a), .in_b(b),
           .result(result), .busy(busy), .done(done));
endmodule
