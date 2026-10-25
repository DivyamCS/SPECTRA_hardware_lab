`timescale 1ns / 1ps
`default_nettype none
// div_unit - RV32M divider: DIV, DIVU, REM, REMU (spec: docs/spec/div_unit.md).
//
// Radix-2 restoring division of the operand magnitudes, one quotient bit per cycle, then a sign
// fix. Fixed latency: `start` in cycle 0 -> `done` (1-cycle pulse) and `result` in cycle 33,
// i.e. 34 cycles in EX, for every operand value (no early exit, so cycle counts never depend
// on data).
//   cycle 0     : magnitudes and sign flags registered
//   cycles 1-32 : 32 iterations: {rem, quo} <<= 1; if rem >= |b| then rem -= |b|, quo[0] = 1
//   cycle 33    : sign fix -> result, done = 1
// RISC-V special cases come out of the algorithm itself:
//   b = 0          -> quotient all ones (DIV, DIVU = 0xFFFFFFFF), remainder = a (REM, REMU = a)
//   INT_MIN / -1   -> quotient 0x80000000 (DIV = INT_MIN), remainder 0
// `result` holds until the next division ends. `start` is ignored while iterating; a start in
// the done cycle begins the next division.

module div_unit (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [1:0]  op,       // 0 DIV, 1 DIVU, 2 REM, 3 REMU (funct3[1:0])
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire        busy,
    output reg         done,
    output wire [31:0] result
);

    wire is_signed = !op[0];                       // DIV, REM
    wire a_neg = is_signed & a[31];
    wire b_neg = is_signed & b[31];

    reg  [32:0] rem;                               // 33 bits: rem < |b| <= 2^32 - 1, shifted
    reg  [31:0] quo;                               // dividend magnitude shifts out, quotient in
    reg  [31:0] bmag;
    reg         want_rem, neg_q, neg_r;
    reg         running;
    reg  [4:0]  count;

    // one iteration
    wire [32:0] rem_sh = {rem[31:0], quo[31]};
    wire [33:0] diff   = {1'b0, rem_sh} - {2'b00, bmag};
    wire        fits   = !diff[33];

    always @(posedge clk) begin
        if (rst) begin
            running  <= 1'b0;
            done     <= 1'b0;
            count    <= 5'd0;
            rem      <= 33'd0;
            quo      <= 32'd0;
            bmag     <= 32'd0;
            want_rem <= 1'b0;
            neg_q    <= 1'b0;
            neg_r    <= 1'b0;
        end else begin
            done <= running && (count == 5'd31);
            if (start && !running) begin
                running  <= 1'b1;
                count    <= 5'd0;
                rem      <= 33'd0;
                quo      <= a_neg ? (~a + 32'd1) : a;
                bmag     <= b_neg ? (~b + 32'd1) : b;
                want_rem <= op[1];
                neg_q    <= (a_neg ^ b_neg) && (b != 32'd0);   // x / 0 stays all ones
                neg_r    <= a_neg;                              // remainder takes a's sign
            end else if (running) begin
                rem   <= fits ? diff[32:0] : rem_sh;
                quo   <= {quo[30:0], fits};
                count <= count + 5'd1;
                if (count == 5'd31)
                    running <= 1'b0;
            end
        end
    end

    wire [31:0] q = neg_q ? (~quo + 32'd1) : quo;
    wire [31:0] r = neg_r ? (~rem[31:0] + 32'd1) : rem[31:0];
    assign result = want_rem ? r : q;
    assign busy   = running | done;

endmodule

`default_nettype wire
