`timescale 1ns/1ps

module div (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [2:0]  funct3,
    input  wire [31:0] in_a,
    input  wire [31:0] in_b,
    output reg  [31:0] result,
    output wire        busy,
    output wire        done
);

    `include "opcode.vh"
    
    // FSM States
    localparam IDLE    = 2'b00;
    localparam COMPUTE = 2'b01;
    localparam FINISH  = 2'b10;

    reg [1:0]  state;
    reg [5:0]  count;       // 32 down to 0

    // Working division register: [63:32] remainder, [31:0] quotient
    reg [63:0] working_reg;
    reg [31:0] divisor;
    
    // Sign tracking
    reg        is_rem;
    reg        neg_quotient;
    reg        neg_remainder;

    assign busy = (state != IDLE);
    assign done = (state == FINISH);

    // Non-restoring / Restoring trial subtraction on the upper 32 bits
    // We compare working_reg[62:31] with divisor because we shift left by 1 bit each step
    wire [32:0] sub_res = {1'b0, working_reg[62:31]} - {1'b0, divisor};

    // Calculate the next step's working register value
    wire [63:0] next_working_reg = (!sub_res[32]) ? 
                                   {sub_res[31:0], working_reg[30:0], 1'b1} : 
                                   {working_reg[62:0], 1'b0};

    // Combinational final sign restoration on completion of the 32nd step
    wire [31:0] final_quotient  = neg_quotient  ? -next_working_reg[31:0]  : next_working_reg[31:0];
    wire [31:0] final_remainder = neg_remainder ? -next_working_reg[63:32] : next_working_reg[63:32];

    always @(posedge clk) begin
        if (rst) begin
            state         <= IDLE;
            count         <= 6'd0;
            working_reg   <= 64'd0;
            divisor       <= 32'd0;
            result        <= 32'd0;
            is_rem        <= 1'b0;
            neg_quotient  <= 1'b0;
            neg_remainder <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    if (start) begin
                        is_rem <= (funct3 == REM || funct3 == REMU);

                        // -------------------------------------------------
                        // Check RISC-V Corner Cases in Cycle 0
                        // -------------------------------------------------
                        if (in_b == 32'd0) begin
                            // Case 1: Division by Zero
                            // DIV/DIVU -> -1 (32'hFFFFFFFF); REM/REMU -> in_a
                            result <= (funct3 == REM || funct3 == REMU) ? in_a : 32'hFFFFFFFF;
                            state  <= FINISH;
                        end else if ((funct3 == DIV || funct3 == REM) && 
                                     (in_a == 32'h80000000) && (in_b == 32'hFFFFFFFF)) begin
                            // Case 2: Signed Overflow (INT_MIN / -1)
                            result <= (funct3 == REM) ? 32'd0 : 32'h80000000;
                            state  <= FINISH;
                        end else begin
                            // Normal Division Setup
                            if (funct3 == DIV || funct3 == REM) begin
                                neg_quotient  <= in_a[31] ^ in_b[31];
                                neg_remainder <= in_a[31];
                                working_reg   <= {32'd0, (in_a[31] ? -in_a : in_a)};
                                divisor       <= in_b[31] ? -in_b : in_b;
                            end else begin
                                neg_quotient  <= 1'b0;
                                neg_remainder <= 1'b0;
                                working_reg   <= {32'd0, in_a};
                                divisor       <= in_b;
                            end

                            count <= 6'd32;
                            state <= COMPUTE;
                        end
                    end
                end

                COMPUTE: begin
                    working_reg <= next_working_reg;
                    count       <= count - 1'b1;

                    // When transitioning to FINISH on the last cycle, register the final result
                    if (count == 6'd1) begin
                        result <= is_rem ? final_remainder : final_quotient;
                        state  <= FINISH;
                    end
                end

                FINISH: begin
                    // result is already valid and stable here when done == 1
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule