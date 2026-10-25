`timescale 1ns / 1ps
`default_nettype none
// decoder - RV32IM instruction decoder for one SPECTRA core (spec: docs/spec/decoder.md).
// Purely combinational. Decode rules follow the lab's IF_ID.v, plus AUIPC (the lab decoder had
// none) and the M extension. Anything else (FENCE, ECALL/EBREAK, CSR, compressed, reserved
// funct3/funct7) sets `illegal` and clears every control bit, so it writes, stores and
// starts nothing.

module decoder (
    input  wire [31:0] instr,
    output wire [4:0]  rs1,
    output wire [4:0]  rs2,
    output wire [4:0]  rd,
    output reg         uses_rs1,
    output reg         uses_rs2,
    output reg         writes_rd,
    output reg  [31:0] imm,
    output reg  [3:0]  alu_op,
    output reg         use_imm,
    output reg         is_lui,
    output reg         is_auipc,
    output reg         is_jal,
    output reg         is_jalr,
    output reg         is_branch,
    output wire [2:0]  br_cond,
    output reg         is_load,
    output reg         is_store,
    output wire [1:0]  mem_size,
    output wire        load_unsigned,
    output reg         is_md,
    output wire [2:0]  md_op,
    output reg         illegal
);

`include "opcode.vh"

    wire [6:0] opcode = instr[6:0];
    wire [2:0] f3     = instr[14:12];
    wire [6:0] f7     = instr[31:25];

    assign rs1           = instr[19:15];
    assign rs2           = instr[24:20];
    assign rd            = instr[11:7];
    assign br_cond       = f3;
    assign mem_size      = f3[1:0];
    assign load_unsigned = f3[2];
    assign md_op         = f3;

    wire [31:0] imm_i = {{20{instr[31]}}, instr[31:20]};
    wire [31:0] imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    wire [31:0] imm_b = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
    wire [31:0] imm_u = {instr[31:12], 12'b0};
    wire [31:0] imm_j = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};

    always @(*) begin
        uses_rs1 = 1'b0; uses_rs2 = 1'b0; writes_rd = 1'b0; imm = 32'd0;
        alu_op = ALU_ADD; use_imm = 1'b0;
        is_lui = 1'b0; is_auipc = 1'b0; is_jal = 1'b0; is_jalr = 1'b0; is_branch = 1'b0;
        is_load = 1'b0; is_store = 1'b0; is_md = 1'b0; illegal = 1'b0;
        case (opcode)
            LUI: begin
                is_lui = 1'b1; writes_rd = 1'b1; imm = imm_u; alu_op = ALU_PASS_B; use_imm = 1'b1;
            end
            AUIPC: begin
                is_auipc = 1'b1; writes_rd = 1'b1; imm = imm_u;
            end
            JAL: begin
                is_jal = 1'b1; writes_rd = 1'b1; imm = imm_j;
            end
            JALR: begin
                if (f3 == 3'b000) begin
                    is_jalr = 1'b1; writes_rd = 1'b1; uses_rs1 = 1'b1; imm = imm_i;
                end else illegal = 1'b1;
            end
            BRANCH: begin
                if (f3 != 3'b010 && f3 != 3'b011) begin
                    is_branch = 1'b1; uses_rs1 = 1'b1; uses_rs2 = 1'b1; imm = imm_b;
                end else illegal = 1'b1;
            end
            LOAD: begin
                if (f3 == LB || f3 == LH || f3 == LW || f3 == LBU || f3 == LHU) begin
                    is_load = 1'b1; writes_rd = 1'b1; uses_rs1 = 1'b1; imm = imm_i;
                end else illegal = 1'b1;
            end
            STORE: begin
                if (f3 == SB || f3 == SH || f3 == SW) begin
                    is_store = 1'b1; uses_rs1 = 1'b1; uses_rs2 = 1'b1; imm = imm_s;
                end else illegal = 1'b1;
            end
            ARITHI: begin
                uses_rs1 = 1'b1; writes_rd = 1'b1; use_imm = 1'b1; imm = imm_i;
                case (f3)
                    ADD:  alu_op = ALU_ADD;
                    SLT:  alu_op = ALU_SLT;
                    SLTU: alu_op = ALU_SLTU;
                    XOR:  alu_op = ALU_XOR;
                    OR:   alu_op = ALU_OR;
                    AND:  alu_op = ALU_AND;
                    SLL:  if (f7 == 7'b0000000) alu_op = ALU_SLL; else illegal = 1'b1;
                    default: // SR
                          if (f7 == 7'b0000000)      alu_op = ALU_SRL;
                          else if (f7 == 7'b0100000) alu_op = ALU_SRA;
                          else illegal = 1'b1;
                endcase
            end
            ARITHR: begin
                uses_rs1 = 1'b1; uses_rs2 = 1'b1; writes_rd = 1'b1;
                if (f7 == FUNCT7_M) begin
                    is_md = 1'b1;
                end else if (f7 == 7'b0000000) begin
                    case (f3)
                        ADD:  alu_op = ALU_ADD;
                        SLL:  alu_op = ALU_SLL;
                        SLT:  alu_op = ALU_SLT;
                        SLTU: alu_op = ALU_SLTU;
                        XOR:  alu_op = ALU_XOR;
                        SR:   alu_op = ALU_SRL;
                        OR:   alu_op = ALU_OR;
                        default: alu_op = ALU_AND;
                    endcase
                end else if (f7 == 7'b0100000 && f3 == ADD) begin
                    alu_op = ALU_SUB;
                end else if (f7 == 7'b0100000 && f3 == SR) begin
                    alu_op = ALU_SRA;
                end else illegal = 1'b1;
            end
            default: illegal = 1'b1;
        endcase
        if (illegal) begin                     // an illegal instruction does nothing at all
            uses_rs1 = 1'b0; uses_rs2 = 1'b0; writes_rd = 1'b0; imm = 32'd0; alu_op = ALU_ADD;
            use_imm = 1'b0; is_md = 1'b0;
        end
    end

endmodule

`default_nettype wire
