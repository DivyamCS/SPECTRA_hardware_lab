//////////////// Including Stages ////////////////////////////
`include "IF_ID.v"
`include "execute.v"
`include "wb.v"

 module pipe
#(
    parameter [31:0] RESET = 32'h0000_0000
)
(
	input               	clk,
	input               	reset,
	input               	stall,
	output          	exception,  
	output [31:0] pc_out,

    // Interface of instruction memory and data memory
    input               inst_mem_is_valid,
    input [31:0]        inst_mem_read_data,
    input [31:0]        dmem_read_data_temp,
    input               dmem_write_valid,
    input               dmem_read_valid,

    output [31:0]       inst_mem_address,
    output              dmem_read_ready,
    output [31:0]       dmem_read_address,
    output              dmem_write_ready,
    output [31:0]       dmem_write_address,
    output [31:0]       dmem_write_data,
    output [3:0]        dmem_write_byte
);

    // ------------------------------------------------------
    // Data Memory Wires
    // ------------------------------------------------------

    wire [31:0] dmem_read_data;
    wire [1:0]  dmem_read_offset;
    wire        inst_mem_is_ready;
    wire        dmem_read_valid_checker;

    // ------------------------------------------------------
    // Instruction Fetch / Decode Stage
    // ------------------------------------------------------

    reg  [31:0] immediate;
    wire        immediate_sel;

    wire [4:0]  src1_select;
    wire [4:0]  src2_select;
    wire [4:0]  dest_reg_sel;

    wire [2:0]  alu_operation;
    wire        arithsubtype;
    wire        mem_write;
    wire        mem_to_reg;
    wire        illegal_inst;

    wire [31:0] execute_immediate;

    wire        alu;
    wire        lui;
    wire        jal;
    wire        jalr;
    wire        branch;

    reg         stall_read;

    wire [31:0] instruction;
    wire [31:0] reg_rdata2;
    wire [31:0] reg_rdata1;

    reg [31:0] regs [31:1];

    // ------------------------------------------------------
    // Program Counter
    // ------------------------------------------------------

    wire [31:0] pc;
    wire [31:0] inst_fetch_pc;

    reg  [31:0] fetch_pc;

    // ------------------------------------------------------
    // Stall Signals
    // ------------------------------------------------------

    wire wb_stall_first;
    wire wb_stall_second;
    wire wb_stall;

    // ------------------------------------------------------
    // RV32M and Front-End Control Signals
    // ------------------------------------------------------

    wire        muldiv;
    wire        valid;

    wire        md_start;
    wire        md_wait;
    wire        md_done;
    wire [31:0] md_result;

    wire        wb_valid;

    wire        flush_if;
    wire        fetch_hold;
    wire        ex_bubble;

    // ------------------------------------------------------
    // Execute Stage
    // ------------------------------------------------------

    wire [31:0] next_pc;
    wire [31:0] write_address;

    wire        branch_taken;
    wire        branch_stall;

    wire [31:0] alu_operand1;
    wire [31:0] alu_operand2;

    // ------------------------------------------------------
    // Writeback Signals
    // ------------------------------------------------------

    wire        wb_alu_to_reg;
    wire [31:0] wb_result;
    wire [2:0]  wb_alu_operation;

    wire        wb_mem_write;
    wire        wb_mem_to_reg;

    wire [4:0]  wb_dest_reg_sel;

    wire        wb_branch;
    wire        wb_branch_nxt;

    wire [31:0] wb_write_address;
    wire [1:0]  wb_read_address;

    wire [3:0]  wb_write_byte;
    wire [31:0] wb_write_data;
    wire [31:0] wb_read_data;

    // ------------------------------------------------------
    // Memory Interface Assignments
    // ------------------------------------------------------

    assign dmem_write_address = wb_write_address;

    assign dmem_read_address =
        alu_operand1 + execute_immediate;

    assign dmem_read_offset =
        dmem_read_address[1:0];

    assign dmem_read_ready =
        mem_to_reg;

    assign dmem_write_ready =
        wb_mem_write;

    assign dmem_write_data =
        wb_write_data;

    assign dmem_write_byte =
        wb_write_byte;

    assign dmem_read_data =
        dmem_read_data_temp;

    assign dmem_read_valid_checker =
        1'b1;

    // ------------------------------------------------------
    // RV32M Datapath
    //
    // Combinational implementation.
    // md_done is held high because the operations do not
    // use a multi-cycle execution unit in this version.
    // ------------------------------------------------------

    assign md_done = 1'b1;

    reg [63:0] md_product;
    reg [31:0] md_result_comb;

    always @(*) begin

        md_product     = 64'd0;
        md_result_comb = 32'd0;

        case (alu_operation)

            // MUL
            3'b000: begin
                md_product =
                    $signed({{32{alu_operand1[31]}},
                              alu_operand1}) *
                    $signed({{32{alu_operand2[31]}},
                              alu_operand2});

                md_result_comb = md_product[31:0];
            end

            // MULH
            3'b001: begin
                md_product =
                    $signed({{32{alu_operand1[31]}},
                              alu_operand1}) *
                    $signed({{32{alu_operand2[31]}},
                              alu_operand2});

                md_result_comb = md_product[63:32];
            end

            // MULHSU
            3'b010: begin
                md_product =
                    $signed({{32{alu_operand1[31]}},
                              alu_operand1}) *
                    $signed({32'd0, alu_operand2});

                md_result_comb = md_product[63:32];
            end

            // MULHU
            3'b011: begin
                md_product =
                    {32'd0, alu_operand1} *
                    {32'd0, alu_operand2};

                md_result_comb = md_product[63:32];
            end

            // DIV
            3'b100: begin
                if (alu_operand2 == 32'd0)
                    md_result_comb = 32'hffff_ffff;

                else if (
                    alu_operand1 == 32'h8000_0000 &&
                    alu_operand2 == 32'hffff_ffff
                )
                    md_result_comb = 32'h8000_0000;

                else
                    md_result_comb =
                        $signed(alu_operand1) /
                        $signed(alu_operand2);
            end

            // DIVU
            3'b101: begin
                if (alu_operand2 == 32'd0)
                    md_result_comb = 32'hffff_ffff;

                else
                    md_result_comb =
                        alu_operand1 / alu_operand2;
            end

            // REM
            3'b110: begin
                if (alu_operand2 == 32'd0)
                    md_result_comb = alu_operand1;

                else if (
                    alu_operand1 == 32'h8000_0000 &&
                    alu_operand2 == 32'hffff_ffff
                )
                    md_result_comb = 32'd0;

                else
                    md_result_comb =
                        $signed(alu_operand1) %
                        $signed(alu_operand2);
            end

            // REMU
            3'b111: begin
                if (alu_operand2 == 32'd0)
                    md_result_comb = alu_operand1;

                else
                    md_result_comb =
                        alu_operand1 % alu_operand2;
            end

        endcase
    end

    assign md_result = md_result_comb;

    // ------------------------------------------------------
    // Front-End Control
    // ------------------------------------------------------

    assign fetch_hold =
        stall_read | ~inst_mem_is_valid;

    assign flush_if =
        !inst_mem_is_valid |
        (branch_taken && (branch || jal || jalr));

    assign ex_bubble =
        md_wait && !md_start;

    // ------------------------------------------------------
    // Instruction Fetch / Decode
    // ------------------------------------------------------

    IF_ID IF_ID_stage (

        .clk                (clk),
        .reset              (reset),
        .stall              (stall),
        .exception          (exception),

        // Instruction memory interface
        .inst_mem_is_valid  (inst_mem_is_valid),
        .inst_mem_read_data (inst_mem_read_data),

        .stall_read_i       (stall_read),
        .inst_fetch_pc      (inst_fetch_pc),

        .instruction_i      (
            inst_mem_is_valid
                ? inst_mem_read_data
                : 32'h0000_0013
        ),

        // Writeback signals
        .wb_stall           (wb_stall),
        .wb_alu_to_reg      (wb_alu_to_reg),
        .wb_mem_to_reg      (wb_mem_to_reg),
        .wb_dest_reg_sel    (wb_dest_reg_sel),
        .wb_result          (wb_result),
        .wb_read_data       (wb_read_data),

        .flush_i            (flush_if),

        // Instruction memory address offset
        .inst_mem_offset    (inst_mem_address[1:0]),

        // Decode outputs
        .execute_immediate_w(execute_immediate),
        .immediate_sel_w    (immediate_sel),

        .alu_w              (alu),
        .lui_w              (lui),
        .jal_w              (jal),
        .jalr_w             (jalr),
        .branch_w           (branch),

        .mem_write_w        (mem_write),
        .mem_to_reg_w       (mem_to_reg),

        .arithsubtype_w     (arithsubtype),

        .pc_w               (pc),

        .src1_select_w      (src1_select),
        .src2_select_w      (src2_select),
        .dest_reg_sel_w     (dest_reg_sel),

        .alu_operation_w    (alu_operation),
        .illegal_inst_w     (illegal_inst),

        .instruction_o      (instruction),

        .muldiv_w           (muldiv),
        .valid_w            (valid)
    );

    // ------------------------------------------------------
    // Register File Read / Forwarding
    //
    // x0 always reads as zero.
    // Forward from WB when the destination matches.
    // ------------------------------------------------------

    assign reg_rdata1 =
        (src1_select == 5'd0)
            ? 32'd0
            : (
                (!wb_stall &&
                 wb_alu_to_reg &&
                 (wb_dest_reg_sel == src1_select))
                    ? (wb_mem_to_reg
                        ? wb_read_data
                        : wb_result)
                    : regs[src1_select]
              );

    assign reg_rdata2 =
        (src2_select == 5'd0)
            ? 32'd0
            : (
                (!wb_stall &&
                 wb_alu_to_reg &&
                 (wb_dest_reg_sel == src2_select))
                    ? (wb_mem_to_reg
                        ? wb_read_data
                        : wb_result)
                    : regs[src2_select]
              );

    // ------------------------------------------------------
    // Register File Writeback
    // ------------------------------------------------------

    integer i;

    always @(posedge clk) begin

        if (reset) begin

            for (i = 1; i < 32; i = i + 1)
                regs[i] <= 32'd0;

        end

        else if (
            wb_alu_to_reg &&
            !stall_read &&
            !wb_stall &&
            (wb_dest_reg_sel != 5'd0)
        ) begin

            regs[wb_dest_reg_sel] <=
                wb_mem_to_reg
                    ? wb_read_data
                    : wb_result;

        end
    end

    // ------------------------------------------------------
    // Stall Register
    // ------------------------------------------------------

    always @(posedge clk) begin

        if (reset)
            stall_read <= 1'b0;

        else
            stall_read <=
                stall ||
                !inst_mem_is_valid ||
                (mem_to_reg && !dmem_read_valid) ||
                (md_wait && !md_start);

    end

    // ------------------------------------------------------
    // Execute Stage
    // ------------------------------------------------------

    execute execute (

        // Clock / Reset
        .clk                (clk),
        .reset              (reset),

        // Decode / Execute inputs
        .reg_rdata1         (reg_rdata1),
        .reg_rdata2         (reg_rdata2),

        .execute_imm        (execute_immediate),

        .pc                 (pc),
        .fetch_pc           (fetch_pc),

        .immediate_sel      (immediate_sel),

        .mem_write          (mem_write),

        .jal                (jal),
        .jalr               (jalr),
        .lui                (lui),
        .alu                (alu),
        .branch             (branch),

        .arithsubtype       (arithsubtype),
        .mem_to_reg         (mem_to_reg),

        .stall_read         (stall_read),

        .muldiv             (muldiv),
        .valid              (valid),

        .md_done            (md_done),
        .md_result          (md_result),
        .bubble             (ex_bubble),

        .dest_reg_sel       (dest_reg_sel),
        .alu_op             (alu_operation),

        .dmem_raddr         (dmem_read_offset),

        // Writeback branch signals
        .wb_branch_i        (wb_branch),
        .wb_branch_nxt_i    (wb_branch_nxt),

        // Execute outputs
        .alu_operand1       (alu_operand1),
        .alu_operand2       (alu_operand2),

        .write_address      (write_address),

        .branch_stall       (branch_stall),
        .next_pc            (next_pc),
        .branch_taken       (branch_taken),

        // Execute to writeback
        .wb_result          (wb_result),
        .wb_mem_write       (wb_mem_write),
        .wb_alu_to_reg      (wb_alu_to_reg),
        .wb_dest_reg_sel    (wb_dest_reg_sel),

        .wb_branch          (wb_branch),
        .wb_branch_nxt      (wb_branch_nxt),

        .wb_mem_to_reg      (wb_mem_to_reg),
        .wb_read_address    (wb_read_address),
        .mem_alu_operation  (wb_alu_operation),

        // RV32M control
        .md_start           (md_start),
        .md_wait            (md_wait),
        .wb_valid           (wb_valid)
    );

    // ------------------------------------------------------
    // PC Update Logic
    // ------------------------------------------------------

    always @(posedge clk) begin

        if (reset)
            fetch_pc <= RESET;

        else if (!stall_read)
            fetch_pc <=
                branch_stall
                    ? fetch_pc + 32'd4
                    : next_pc;

    end

    // ------------------------------------------------------
    // Writeback Stage
    // ------------------------------------------------------

    wb wb_stage (

        .clk                (clk),
        .reset              (reset),

        // Writeback inputs
        .stall_read_i       (stall_read),
        .fetch_pc_i         (fetch_pc),

        .wb_branch_i        (wb_branch),
        .wb_mem_to_reg_i    (wb_mem_to_reg),

        .mem_write_i        (mem_write),

        .write_address_i    (write_address),
        .alu_operand2_i     (alu_operand2),

        .alu_operation_i    (alu_operation),
        .wb_alu_operation_i (wb_alu_operation),

        .wb_read_address_i  (wb_read_address),

        .dmem_read_data_i   (dmem_read_data),
        .dmem_write_valid_i (dmem_write_valid),

        .fetch_hold_i       (fetch_hold),

        // Writeback outputs
        .inst_mem_address_o  (inst_mem_address),
        .inst_mem_is_ready_o (inst_mem_is_ready),

        .wb_stall_o          (wb_stall),

        .wb_write_address_o  (wb_write_address),
        .wb_write_data_o     (wb_write_data),
        .wb_write_byte_o     (wb_write_byte),

        .wb_read_data_o      (wb_read_data),

        .inst_fetch_pc_o     (inst_fetch_pc),

        .wb_stall_first_o    (wb_stall_first),
        .wb_stall_second_o   (wb_stall_second)
    );

    // ------------------------------------------------------
    // Program Counter Output
    // ------------------------------------------------------

    assign pc_out = fetch_pc;

endmodule
