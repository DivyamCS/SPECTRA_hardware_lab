`timescale 1ns/1ps

module mul (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,      // Asserted when a MUL instruction enters EX stage
    input  wire [2:0]  funct3,     // 000: MUL, 001: MULH, 010: MULHSU, 011: MULHU
    input  wire [31:0] in_a,       // rs1 operand
    input  wire [31:0] in_b,       // rs2 operand
    output reg  [31:0] product,    // Result to write back
    output wire        busy,       // Multiplier is busy computing
    output wire        done        // Multiplier has valid result ready
);

`include "opcode.vh"

    // -------------------------------------------------------------
    // Sign Extension Logic
    // -------------------------------------------------------------
    // MUL / MULH   : Signed   x Signed   (sign extend both to 33 bits)
    // MULHSU       : Signed   x Unsigned (sign extend A, zero extend B)
    // MULHU        : Unsigned x Unsigned (zero extend both to 33 bits)
    // -------------------------------------------------------------
    wire sign_a = (funct3 == MUL || funct3 == MULH || funct3 == MULHSU);
    wire sign_b = (funct3 == MUL || funct3 == MULH);

    wire signed [32:0] ext_a = {sign_a & in_a[31], in_a};
    wire signed [32:0] ext_b = {sign_b & in_b[31], in_b};

    // -------------------------------------------------------------
    // Pipeline Registers (3 cycles total)
    // -------------------------------------------------------------
    // Stage 1 registers: Capture operands & operation
    reg signed [32:0] a_reg1, b_reg1;
    reg [2:0]         funct3_reg1;

    // Stage 2 registers: Store 66-bit intermediate product
    reg signed [65:0] prod_reg2;
    reg [2:0]         funct3_reg2;

    // State / Handshake Shift Register 
    reg [1:0] state_pipe;          // [0] = cycle 1 (multiplying), [1] = cycle 2 (done)

    wire accept = start && (state_pipe == 2'b00);

    always @(posedge clk) begin
        if (rst) state_pipe <= 2'b00;
        else     state_pipe <= {state_pipe[0], accept};
    end

    always @(posedge clk) begin
        if (accept) begin
            a_reg1      <= ext_a;
            b_reg1      <= ext_b;
            funct3_reg1 <= funct3;
        end
        if (state_pipe[0]) begin
            prod_reg2   <= a_reg1 * b_reg1;
            funct3_reg2 <= funct3_reg1;
        end
    end

    assign busy = state_pipe[0] | state_pipe[1];
    assign done = state_pipe[1];
    
    // -------------------------------------------------------------
    // Pipeline Stage 3: Output Selection
    // -------------------------------------------------------------
    always @(*) begin
        case (funct3_reg2)
            MUL: begin
                // Return lower 32 bits
                product = prod_reg2[31:0];
            end
            MULH, MULHSU, MULHU: begin
                // Return upper 32 bits
                product = prod_reg2[63:32];
            end
            default: begin
                product = 32'h0;
            end
        endcase
    end

endmodule