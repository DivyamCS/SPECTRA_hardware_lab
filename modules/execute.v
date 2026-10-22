`timescale 1ns/1ps

////////////////////////////////////////////////////////////// Stage 2: Execute////////////////////////////////////////////////////////////
module execute
#(
	parameter [31:0] RESET = 32'h0000_0000
)
(
	input clk,
	input reset,

	// -----------------------------	// FROM ID/EX	// -----------------------------
	input  [31:0] reg_rdata1,
	input  [31:0] reg_rdata2,
	input  [31:0] execute_imm,
	input  [31:0] pc,
	input  [31:0] fetch_pc,
	input     	immediate_sel,
	input     	mem_write,
	input     	jal,    
	input     	jalr,
	input     	lui,
	input     	alu,
	input     	branch,
	input     	arithsubtype,
	input     	mem_to_reg,
	input     	stall_read,
	input       m_ext, // <-- ADD

	input  [4:0]  dest_reg_sel,
	input  [2:0]  alu_op,
	input  [1:0]  dmem_raddr,

	// -----------------------------	// FROM WB	// -----------------------------
	input     	wb_branch_i,
	input     	wb_branch_nxt_i,

	// -----------------------------	// EX → PIPE	// -----------------------------
	output [31:0] alu_operand1,
	output [31:0] alu_operand2,
	output [31:0] write_address,
	output    	branch_stall,

	output reg [31:0] next_pc,
	output reg    	branch_taken,

	output      mul_busy_o,         // <-- ADD 
    output      mul_done_o,         // <-- ADD 
    output      div_busy_o,         // <-- ADD 
    output      div_done_o,         // <-- ADD 

	// -----------------------------  // EX → WB	// -----------------------------
	output [31:0] wb_result,
	output    	wb_mem_write,
	output    	wb_alu_to_reg,
	output [4:0]  wb_dest_reg_sel,
	output    	wb_branch,
	output    	wb_branch_nxt,
	output    	wb_mem_to_reg,
	output [1:0]  wb_read_address,
	output [2:0]  mem_alu_operation
);

//////////////// Including OPCODES ////////////////////////////
`include "opcode.vh"

////////////////////////////////////////////////////////////// LOCAL INTERNAL SIGNALS/////////////////////////////////

reg  [31:0] ex_result;
wire [32:0] ex_result_subs;
wire [32:0] ex_result_subu;

////////////////////////////////////////////////////////////// Operand selection///////////////////////////////////////////////////////

// TODO-EX-1:
// Select ALU operands
// - The first operand must come from the first value read from the register file
// - The second operand must come from the immediate when immediate selection is enabled
// - Otherwise, the second operand must come from the second value read from the register file

assign alu_operand1 = reg_rdata1;
// FIX: arithmetic shift must be computed on a signed net. Inside a ?: with an unsigned
// branch, $signed(..) >>> gets coerced to unsigned and degenerates into a logical shift.
wire signed [31:0] sra_res = $signed(alu_operand1) >>> alu_operand2[4:0];
assign alu_operand2 = immediate_sel ? execute_imm : reg_rdata2;

////////////////////////////////////////////////////////////// Subtractions////////////////////////////////////////////////////////////


// TODO-EX-2:
// Generate subtraction results required for branch comparison
// - One result (ex_result_subs) must treat both operands as signed values
// - Another result (ex_result_subu) must treat both operands as unsigned values
// - The results must be wide enough to capture the sign/borrow bit
// - These results will be used later to evaluate branch conditions

assign ex_result_subs =
	{alu_operand1[31], alu_operand1} -
	{alu_operand2[31], alu_operand2};

assign ex_result_subu = {1'b0, alu_operand1} - {1'b0, alu_operand2};

////////////////////////////////////////////////////////////// Address & branch stall////////////////////////////////////////

assign write_address = alu_operand1 + execute_imm;
assign branch_stall  = wb_branch_nxt_i || wb_branch_i;

////////////////////////////////////////////////////////////// Next PC logic////////////////////////////////////////////////////////////


// TODO-EX-3:
// Compute the next program counter and branch decision
// Guidelines:
// - Default next PC advances to the next sequential instruction
// - For jump instructions:
// 	* JAL computes the target using the current PC and an immediate
// 	* JALR computes the target using a register value (first read) and an immediate
// - For branch instructions:
// 	* Evaluate the branch condition using comparison/subtraction results
// 	* If the condition is satisfied, jump to the branch target
// 	* Otherwise, continue sequential execution
// - Branch resolution must be suppressed when a branch stall is active

always @(*) begin
	next_pc  	= fetch_pc + 4;
	branch_taken = !branch_stall;

	case (1'b1)
    	jal  : next_pc = pc + execute_imm;
    	jalr : next_pc = alu_operand1 + execute_imm;

    	branch: begin
        	case (alu_op)
            	BEQ:  begin
                	next_pc = (ex_result_subs == 0)
                          	? pc + execute_imm
                          	: fetch_pc + 4;
                	if (ex_result_subs != 0)
                    	branch_taken = 1'b0;
            	end
            	BNE:  begin
                	next_pc = (ex_result_subs != 0) 
                              ? pc + execute_imm 
                              : fetch_pc + 4;
                    if (ex_result_subs == 0) 
                        branch_taken = 1'b0;
            	end
            	BLT:  begin
                	next_pc = ex_result_subs[32]
                          	? pc + execute_imm
                          	: fetch_pc + 4;
                	if (!ex_result_subs[32])
                    	branch_taken = 1'b0;
            	end
            	BGE:  begin
                	next_pc = (!ex_result_subs[32]) 
                              ? pc + execute_imm 
                              : fetch_pc + 4;
                    if (ex_result_subs[32]) 
                        branch_taken = 1'b0;
            	end
            	BLTU: begin
                	next_pc = ex_result_subu[32]
                          	? pc + execute_imm
                          	: fetch_pc + 4;
                	if (!ex_result_subu[32])
                    	branch_taken = 1'b0;
            	end
            	BGEU: begin
                	next_pc = (!ex_result_subu[32]) 
                              ? pc + execute_imm 
                              : fetch_pc + 4;
                    if (ex_result_subu[32]) 
                        branch_taken = 1'b0;
            	end
            	default: begin
            	next_pc = fetch_pc+4;
            	branch_taken=1'b0;
            	end
        	endcase
    	end

    	default: begin     	 
        	next_pc  	= fetch_pc + 4;
        	branch_taken = 1'b0;
    	end
	endcase
end

////////////////////////////////////////////////////////////// ALU result logic////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////// RV32M Hardware Integration ///////////////////////////////////

////////////////////////////////////////////////////////////// RV32M Hardware Integration ///////////////////////////////////

wire is_mul_inst = m_ext && !branch_stall && (alu_op[2] == 1'b0);  // ignore wrong-path M-ops in branch shadow // funct3: MUL, MULH, MULHSU, MULHU
wire is_div_inst = m_ext && !branch_stall && (alu_op[2] == 1'b1); // funct3: DIV, DIVU, REM,  REMU

wire [31:0] mul_result;
wire        mul_done;
wire        mul_busy;

wire [31:0] div_result;
wire        div_done;
wire        div_busy;

// Robust start generator:
// Fires 'start' for exactly ONE cycle upon entering EX, then stays low until done
reg mul_running;
reg div_running;

always @(posedge clk) begin
    if (reset) begin
        mul_running <= 1'b0;
        div_running <= 1'b0;
    end else begin
        if (is_mul_inst && !mul_running && !mul_done)
            mul_running <= 1'b1;
        else if (mul_done)
            mul_running <= 1'b0;

        if (is_div_inst && !div_running && !div_done)
            div_running <= 1'b1;
        else if (div_done)
            div_running <= 1'b0;
    end
end

wire mul_start = is_mul_inst && !mul_running;
wire div_start = is_div_inst && !div_running;

mul u_mul (
    .clk    (clk),
    .rst    (reset),
    .start  (mul_start),
    .funct3 (alu_op),
    .in_a   (alu_operand1),
    .in_b   (alu_operand2),
    .product(mul_result),
    .done   (mul_done),
    .busy   (mul_busy)
);

div u_div (
    .clk    (clk),
    .rst    (reset),
    .start  (div_start),
    .funct3 (alu_op),
    .in_a   (alu_operand1),
    .in_b   (alu_operand2),
    .result (div_result),
    .done   (div_done),
    .busy   (div_busy)
);

assign mul_busy_o = mul_busy | mul_start;
assign mul_done_o = mul_done;
assign div_busy_o = div_busy | div_start;
assign div_done_o = div_done;

// TODO-EX-4:
// Generate the execute-stage result (ex_result)
// Guidelines:
// - For store instructions, forward the value that will be written to memory
// - For jump instructions (JAL/JALR), produce the return address (PC + 4)
// - LUI must place the immediate value directly into the destination register
// - For ALU instructions, compute the result based on the decoded ALU operation
// - The arithmetic subtype signal selects between related operations


always @(*) begin
	case (1'b1)
    	mem_write: ex_result = alu_operand2;
    	jal,
    	jalr:  	ex_result = pc + 4;
    	lui:   	ex_result = execute_imm;

		//<---- ADDED ---- >
		m_ext: begin
            if (alu_op[2] == 1'b0)
                ex_result = mul_result;
            else
                ex_result = div_result;
        end

    	alu: begin
        	case (alu_op)
            	ADD : ex_result =
                  	arithsubtype
                  	? alu_operand1 - alu_operand2
                  	: alu_operand1 + alu_operand2;
            	SLL : ex_result = alu_operand1 << alu_operand2[4:0];
            	SLT : ex_result = {31'b0, ex_result_subs[32]};
            	SLTU: ex_result = {31'b0, ex_result_subu[32]};
            	XOR : ex_result = alu_operand1 ^ alu_operand2;
            	SR  : ex_result = arithsubtype ? sra_res : (alu_operand1 >> alu_operand2[4:0]);
            	OR  : ex_result = alu_operand1 | alu_operand2;
            	AND : ex_result = alu_operand1 & alu_operand2;
            	default: ex_result = 'hx;
        	endcase
    	end

    	default: ex_result = 'hx;
	endcase
end


////////////////////////////////////////////////////////////// EX → WB pipeline register/////////////////////////////////////////
wire ex_wb_stall = stall_read;
// While MUL/DIV is still running, push a bubble into WB (do NOT repeat the previous instruction)
wire m_stall     = (mul_busy_o | div_busy_o) & ~(mul_done | div_done);
ex_mem_wb_reg u_ex_mem_wb (
	.clk        	(clk),
	.reset_n    	(reset),
	.stall_n    	(ex_wb_stall),

	.ex_result  	(ex_result),

	.mem_write  	(mem_write && !branch_stall && !m_stall),
	.alu_to_reg     ((alu | lui | jal | jalr | mem_to_reg | m_ext) && !m_stall),
	.dest_reg_sel   (dest_reg_sel),
	.branch_taken   (branch_taken && !m_stall),
	.mem_to_reg 	(mem_to_reg),
	.read_address   (dmem_raddr),
	.alu_operation  (alu_op),

	.ex_mem_result    	(wb_result),
	.ex_mem_mem_write 	(wb_mem_write),
	.ex_mem_alu_to_reg	(wb_alu_to_reg),
	.ex_mem_dest_reg_sel  (wb_dest_reg_sel),
	.ex_mem_branch    	(wb_branch),
	.ex_mem_branch_nxt	(wb_branch_nxt),
	.ex_mem_mem_to_reg	(wb_mem_to_reg),
	.ex_mem_read_address  (wb_read_address),
	.ex_mem_alu_operation (mem_alu_operation)
);

endmodule


module ex_mem_wb_reg (
	input     	clk,
	input     	reset_n,
	input     	stall_n,

	// Data
	input  [31:0] ex_result,

	// Control inputs from EX/MEM
	input     	mem_write,
	input     	alu_to_reg,
	input  [4:0]  dest_reg_sel,
	input     	branch_taken,
	input     	mem_to_reg,
	input  [1:0]  read_address,
	input  [2:0]  alu_operation,

	// Outputs to WB
	output reg [31:0] ex_mem_result,
	output reg    	ex_mem_mem_write,
	output reg    	ex_mem_alu_to_reg,
	output reg [4:0]  ex_mem_dest_reg_sel,
	output reg    	ex_mem_branch,
	output reg    	ex_mem_branch_nxt,
	output reg    	ex_mem_mem_to_reg,
	output reg [1:0]  ex_mem_read_address,
	output reg [2:0]  ex_mem_alu_operation
);

// TODO-EX-5:
// EX/MEM → WB pipeline register
// Guidelines:
// - Store all execute-stage data and control signals on the rising clock edge
// - On reset, clear all stored values to a safe default
// - When a stall is asserted, prevent unintended updates
// - All outputs must hold their previous values unless explicitly updated

always @(posedge clk) begin
	if (reset_n) begin
    	ex_mem_result     	<= 32'h0;
    	ex_mem_mem_write  	<= 1'b0;
    	ex_mem_alu_to_reg 	<= 1'b0;
    	ex_mem_dest_reg_sel   <= 5'h0;
    	ex_mem_branch     	<= 1'b0;
    	ex_mem_branch_nxt 	<= 1'b0;
    	ex_mem_mem_to_reg 	<= 1'b0;
    	ex_mem_read_address   <= 2'h0;
    	ex_mem_alu_operation  <= 3'h0;
	end
	else if (!stall_n) begin
    	ex_mem_result     	<= ex_result;
    	ex_mem_mem_write  	<= mem_write;
    	ex_mem_alu_to_reg 	<= alu_to_reg;
    	ex_mem_dest_reg_sel   <= dest_reg_sel;
    	ex_mem_branch     	<= branch_taken;
    	ex_mem_branch_nxt 	<= ex_mem_branch;   
    	ex_mem_mem_to_reg 	<= mem_to_reg;
    	ex_mem_read_address   <= read_address;
    	ex_mem_alu_operation  <= alu_operation;
	end
end

endmodule
 

