`timescale 1ns / 1ps

module tb_pipeline;

////////////////////////////////////////////////////////////
// CLOCK & RESET
////////////////////////////////////////////////////////////
reg clk;
reg reset;

// 50 MHz clock (20 ns period: 10 ns High / 10 ns Low)
initial begin
	clk = 0;
	forever #10 clk = ~clk;
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
	#50000;   // run long enough to see program execute
	$display("\n========================================================");
	$display("             RV32M PIPELINE EXECUTION REPORT            ");
	$display("========================================================");

	// Check Test 1: MUL (x3 = 12 * 8 = 96) and RAW Hazard forwarding (x4 = 96 + 12 = 108)
	if (DUT.regs[3] == 32'd96 && DUT.regs[4] == 32'd108)
		$display("[PASS] Test 1 (MUL & RAW Stall/Forward): x3 = 96, x4 = 108");
	else
		$display("[FAIL] Test 1: x3 = %0d (expected 96), x4 = %0d (expected 108)", DUT.regs[3], DUT.regs[4]);

	// Check Test 2: DIV (x6 = 100 / 12 = 8) and RAW Hazard forwarding (x7 = 8 - 8 = 0)
	if (DUT.regs[6] == 32'd8 && DUT.regs[7] == 32'd0)
		$display("[PASS] Test 2 (DIV & 32-Cycle Stall/Forward): x6 = 8, x7 = 0");
	else
		$display("[FAIL] Test 2: x6 = %0d (expected 8), x7 = %0d (expected 0)", DUT.regs[6], DUT.regs[7]);

	// Check Test 3: REM (x8 = 100 % 12 = 4) and Chained MUL (x9 = 4 * 8 = 32)
	if (DUT.regs[8] == 32'd4 && DUT.regs[9] == 32'd32)
		$display("[PASS] Test 3 (REM & Chained Math): x8 = 4, x9 = 32");
	else
		$display("[FAIL] Test 3: x8 = %0d (expected 4), x9 = %0d (expected 32)", DUT.regs[8], DUT.regs[9]);

	// Check Test 4: Branch on M result and Final Status Marker (x31 = 42)
	if (DUT.regs[31] == 32'd42)
		$display("[PASS] Test 4 (Branch on M-result & Final Pass Flag): x31 = 42 (0x2A)");
	else
		$display("[FAIL] Test 4: Final flag x31 = %0d (expected 42). Trap loop reached.", DUT.regs[31]);

	$display("========================================================\n");
	$finish;
end

endmodule
