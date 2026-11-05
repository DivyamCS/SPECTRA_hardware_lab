`timescale 1ns / 1ps
`default_nettype none
// execute - EX stage datapath of one SPECTRA core (spec: docs/spec/execute.md).
// Operand forwarding muxes, ALU, branch decision and target, load/store address, MUL/DIV beside
// the ALU and the result mux. Combinational except the MUL/DIV units and two flags; the EX/MEM
// register is in the core wrapper. ALU and branch rules as the lab's execute.v (with its SRA
// fix), recoded on the SPECTRA decoder's fields.
//
// MUL/DIV: a valid MUL/DIV in EX starts its unit in its first cycle that is not frozen, so one
// that enters EX during a load stall starts in the cycle after the stall ends. `md_busy` stays
// high until the unit's `done`; if a freeze holds EX in or after the done cycle, the result is
// kept (the units hold `result`) and the unit is not started again. Both flags clear when the
// instruction leaves EX (not frozen and not busy, the hazard unit's rule for EX to advance).

// verified & regression tests passed

module execute #(
    parameter HAS_MD = 1
) (
    input  wire        clk,
    input  wire        rst,
    // ID/EX fields
    input  wire        valid,
    input  wire [31:0] pc,
    input  wire [31:0] rs1_val,
    input  wire [31:0] rs2_val,
    input  wire [31:0] imm,
    input  wire [3:0]  alu_op,
    input  wire        use_imm,
    input  wire        is_lui,
    input  wire        is_auipc,
    input  wire        is_jal,
    input  wire        is_jalr,
    input  wire        is_branch,
    input  wire [2:0]  br_cond,
    input  wire        is_md,
    input  wire [2:0]  md_op,
    // forwarding (hazard_unit) and the MEM/WB result
    input  wire        fwd_a,
    input  wire        fwd_b,
    input  wire [31:0] mw_result,
    input  wire        freeze,         // hazard_unit freeze: nothing advances, no MUL/DIV start
    // results
    output reg  [31:0] result,
    output wire        taken,
    output wire [31:0] target,
    output wire [31:0] mem_addr,
    output wire [31:0] store_data,
    output wire        md_busy
);

`include "opcode.vh"

    // ---- operands
    wire [31:0] a = fwd_a ? mw_result : rs1_val;
    wire [31:0] b = fwd_b ? mw_result : rs2_val;          // also the store data
    wire [31:0] y = use_imm ? imm : b;                    // ALU second operand

    // ---- ALU
    wire [32:0] sub_s = {a[31], a} - {y[31], y};
    wire [32:0] sub_u = {1'b0, a} - {1'b0, y};
    reg  [31:0] alu;
    always @(*) begin
        case (alu_op)
            ALU_ADD:    alu = a + y;
            ALU_SUB:    alu = a - y;
            ALU_SLL:    alu = a << y[4:0];
            ALU_SLT:    alu = {31'd0, sub_s[32]};
            ALU_SLTU:   alu = {31'd0, sub_u[32]};
            ALU_XOR:    alu = a ^ y;
            ALU_SRL:    alu = a >> y[4:0];
            ALU_SRA:    alu = $unsigned($signed(a) >>> y[4:0]);   // self-determined (lab fix)
            ALU_OR:     alu = a | y;
            ALU_AND:    alu = a & y;
            ALU_PASS_B: alu = y;
            default:    alu = 32'd0;
        endcase
    end

    // ---- branch decision (rs1 against rs2, never the immediate)
    wire [32:0] cmp_s = {a[31], a} - {b[31], b};
    wire [32:0] cmp_u = {1'b0, a} - {1'b0, b};
    reg         cond;
    always @(*) begin
        case (br_cond)
            BEQ:     cond = (a == b);
            BNE:     cond = (a != b);
            BLT:     cond = cmp_s[32];
            BGE:     cond = !cmp_s[32];
            BLTU:    cond = cmp_u[32];
            BGEU:    cond = !cmp_u[32];
            default: cond = 1'b0;                         // 010 / 011: decoder flags illegal
        endcase
    end

    assign taken      = valid && (is_jal || is_jalr || (is_branch && cond));
    assign target     = is_jalr ? ((a + imm) & ~32'd1) : (pc + imm);
    assign mem_addr   = a + imm;
    assign store_data = b;

    // ---- MUL/DIV
    wire        md_ex = valid && is_md && (HAS_MD != 0);
    reg         md_started;                               // this MUL/DIV has started its unit
    reg         md_have;                                  // ... and finished while EX was held
    wire        md_done;
    wire [31:0] md_result;
    wire        md_start = md_ex && !md_started && !freeze;
    assign md_busy = md_ex && !md_done && !md_have;
    wire        ex_moves = !freeze && !md_busy;

    always @(posedge clk) begin
        if (rst || ex_moves) begin
            md_started <= 1'b0;
            md_have    <= 1'b0;
        end else begin
            if (md_start) md_started <= 1'b1;
            if (md_ex && md_done) md_have <= 1'b1;
        end
    end

    generate
        if (HAS_MD != 0) begin : g_md
            wire        mul_busy, mul_done, div_busy, div_done;
            wire [31:0] mul_result, div_result;
            mul_unit u_mul (.clk(clk), .rst(rst), .start(md_start && !md_op[2]), .op(md_op[1:0]),
                            .a(a), .b(b), .busy(mul_busy), .done(mul_done), .result(mul_result));
            div_unit u_div (.clk(clk), .rst(rst), .start(md_start && md_op[2]), .op(md_op[1:0]),
                            .a(a), .b(b), .busy(div_busy), .done(div_done), .result(div_result));
            assign md_done   = md_op[2] ? div_done : mul_done;
            assign md_result = md_op[2] ? div_result : mul_result;
        end else begin : g_no_md
            assign md_done   = 1'b0;
            assign md_result = 32'd0;
        end
    endgenerate

    // ---- result mux
    always @(*) begin
        if (is_md)                 result = md_result;
        else if (is_jal || is_jalr) result = pc + 32'd4;
        else if (is_auipc)         result = pc + imm;
        else if (is_lui)           result = imm;
        else                       result = alu;
    end

endmodule

`default_nettype wire
