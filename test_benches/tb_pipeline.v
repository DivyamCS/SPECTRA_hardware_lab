`timescale 1ns / 1ps

module tb_pipeline;

////////////////////////////////////////////////////////////
// CLOCK & RESET
////////////////////////////////////////////////////////////
reg clk;
reg reset;

// 100 MHz clock
initial begin
	clk = 0;
	forever #5 clk = ~clk;
end

// reset (active high)
initial begin
	reset = 1;
	#100;
	reset = 0;
end


////////////////////////////////////////////////////////////
// PIPE ↔ MEMORY SIGNALS
////////////////////////////////////////////////////////////
wire [31:0] inst_mem_read_data;
wire    	inst_mem_is_valid;

wire [31:0] dmem_read_data;
wire    	dmem_write_valid;
wire    	dmem_read_valid;

assign inst_mem_is_valid = 1'b1;
assign dmem_write_valid  = 1'b1;
assign dmem_read_valid   = 1'b1;

wire exception;
wire [31:0] current_pc;
wire [31:0] inst_mem_address;
wire        dmem_read_ready;
wire [31:0] dmem_read_address;
wire        dmem_write_ready;
wire [31:0] dmem_write_address;
wire [31:0] dmem_write_data;
wire [3:0]  dmem_write_byte;


////////////////////////////////////////////////////////////
// DUT : PIPELINE CPU
////////////////////////////////////////////////////////////
pipe DUT (
	.clk(clk),
	.reset(reset),
	.stall(1'b0),
	.exception(exception),

	.inst_mem_is_valid(inst_mem_is_valid),
	.inst_mem_read_data(inst_mem_read_data),

	.dmem_read_data_temp(dmem_read_data),
	.dmem_write_valid(dmem_write_valid),
	.dmem_read_valid(dmem_read_valid),
// TODO: Might have a few more port signals
    .pc_out(current_pc),
    .inst_mem_address(inst_mem_address),
	.dmem_read_ready(dmem_read_ready),
	.dmem_read_address(dmem_read_address),
	.dmem_write_ready(dmem_write_ready),
	.dmem_write_address(dmem_write_address),
	.dmem_write_data(dmem_write_data),
	.dmem_write_byte(dmem_write_byte)
);


////////////////////////////////////////////////////////////
// INSTRUCTION MEMORY  (matches instr_mem.v)
////////////////////////////////////////////////////////////
instr_mem IMEM (//TODO
	.clk(clk),
	.pc(inst_mem_address),
	.instr(inst_mem_read_data)
);


////////////////////////////////////////////////////////////
// DATA MEMORY  (matches data_mem.v)
////////////////////////////////////////////////////////////
data_mem DMEM (//TODO
	.clk(clk),

	.re(dmem_read_ready),
	.raddr(dmem_read_address),
	.rdata(dmem_read_data),

	.we(dmem_write_ready),
	.waddr(dmem_write_address),
	.wdata(dmem_write_data),
	.wstrb(dmem_write_byte)
);


////////////////////////////////////////////////////////////
// SIMULATION TIME
////////////////////////////////////////////////////////////
initial begin
	#20000;   // run long enough to see program execute
	$finish;
end

endmodule
