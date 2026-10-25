`timescale 1ns / 1ps
`default_nettype none
// mul_unit - RV32M multiplier: MUL, MULH, MULHSU, MULHU on DSP48 slices (spec: docs/spec/mul_unit.md).
//
// Timing: `start` in cycle 0 -> `done` (1-cycle pulse) and `result` in cycle 2, i.e. 3 cycles in EX.
//   cycle 0: operands sign/zero-extended to 33 bits and registered (DSP A/B input registers)
//   cycle 1: 33 x 33 signed product registered (DSP P register; 4 x DSP48E1 at 25x18 each)
//   cycle 2: low or high word selected -> result, done = 1
// `result` holds its value until the next product is registered. `busy` = cycles 1 and 2;
// `start` is ignored in cycle 1 (a start in the done cycle begins the next multiply).

module mul_unit (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [1:0]  op,       // 0 MUL, 1 MULH, 2 MULHSU, 3 MULHU (funct3[1:0])
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire        busy,
    output reg         done,
    output wire [31:0] result
);

    // MUL needs only the low word, so any extension works; signed is used.
    wire a_signed = (op != 2'd3);                  // MUL, MULH, MULHSU
    wire b_signed = (op == 2'd0) || (op == 2'd1);  // MUL, MULH

    reg  signed [32:0] a_r, b_r;
    reg         [1:0]  op_r;
    reg  signed [65:0] p_r;
    reg                s1;                         // product being formed (cycle 1)

    // A start is taken unless a product is being formed (cycle 1); the done cycle may start the next.
    wire accept = start && !s1;

    always @(posedge clk) begin
        if (rst) begin
            s1   <= 1'b0;
            done <= 1'b0;
            a_r  <= 33'sd0;
            b_r  <= 33'sd0;
            op_r <= 2'd0;
            p_r  <= 66'sd0;
        end else begin
            done <= s1;
            s1   <= accept;
            if (accept) begin
                a_r  <= {a_signed & a[31], a};
                b_r  <= {b_signed & b[31], b};
                op_r <= op;
            end
            if (s1)
                p_r <= a_r * b_r;
        end
    end

    assign busy   = s1 | done;
    assign result = (op_r == 2'd0) ? p_r[31:0] : p_r[63:32];

endmodule

`default_nettype wire
