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

    // State / Handshake Shift Register (3-cycle counter)
    reg [2:0] state_pipe;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state_pipe  <= 3'b000;
            a_reg1      <= 33'sh0;
            b_reg1      <= 33'sh0;
            funct3_reg1 <= 3'b000;
            prod_reg2   <= 66'sh0;
            funct3_reg2 <= 3'b000;
        end else begin
            // 3-bit one-hot tracker for cycles
            if (start && state_pipe == 3'b000) begin
                state_pipe <= 3'b001; // Cycle 1: Started
            end else if (state_pipe[0]) begin
                state_pipe <= 3'b010; // Cycle 2: Multiplying
            end else if (state_pipe[1]) begin
                state_pipe <= 3'b100; // Cycle 3: Done
            end else begin
                state_pipe <= 3'b000; // Idle
            end

            // --- Pipeline Stage 1: Input Registering ---
            if (start && state_pipe == 3'b000) begin
                a_reg1      <= ext_a;
                b_reg1      <= ext_b;
                funct3_reg1 <= funct3;
            end

            // --- Pipeline Stage 2: Hardware DSP Multiply ---
            // (Vivado DSP48 slices infer a pipeline stage here cleanly)
            if (state_pipe[0]) begin
                prod_reg2   <= a_reg1 * b_reg1;
                funct3_reg2 <= funct3_reg1;
            end
        end
    end

    // Multiplier is busy while active in cycles 1 and 2
    assign busy = state_pipe[0] | state_pipe[1];

    // Done asserts during cycle 3 when prod_reg2 holds the complete product
    assign done = state_pipe[2];

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