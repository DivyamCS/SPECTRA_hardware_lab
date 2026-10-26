`timescale 1ns / 1ps
// mul_unit - adapter: the project's MUL interface onto Hiya's mul.v
module mul_unit (
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
    mul u (.clk(clk), .rst(rst), .start(start), .funct3({1'b0, op}), .in_a(a), .in_b(b),
           .product(result), .busy(busy), .done(done));
endmodule
