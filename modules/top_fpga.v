`timescale 1ns / 1ps

module top_fpga #(
    parameter IMEMSIZE = 4096,
    parameter DMEMSIZE = 4096,
    parameter DIV      = 49_999_999      // slow-clock divider (set to 0 in simulation)
)(
    input  wire clk,        // fast board clock
    input  wire reset,      // active-high reset
    input  wire cache_en,   // slide switch: 1 = cache on, 0 = bypass (change only with a reset)
    output [15:0] led
);

wire exception;

// ---------------- slow clock ----------------
reg [25:0] clk_cnt;
reg        slow_clk;
always @(posedge clk or posedge reset) begin
    if (reset) begin
        clk_cnt  <= 26'd0;
        slow_clk <= 1'b0;
    end else begin
        if (clk_cnt == DIV) begin
            clk_cnt  <= 26'd0;
            slow_clk <= ~slow_clk;
        end else begin
            clk_cnt <= clk_cnt + 1'b1;
        end
    end
end

// ---------------- pipe <-> memory wires ----------------
wire [31:0] inst_mem_read_data;
wire [31:0] inst_mem_address;
wire [31:0] current_pc;
assign led = current_pc[15:0];

wire        dmem_read_ready;
wire [31:0] dmem_read_address;
wire        dmem_write_ready;
wire [31:0] dmem_write_address;
wire [31:0] dmem_write_data;
wire [3:0]  dmem_write_byte;
wire [31:0] dmem_read_data;

// ---------------- adapter <-> dcache <-> memory wires ----------------
wire        dc_stall, dc_stall_q;
wire        dc_re, dc_we, dc_ready, dc_busy;
wire [31:0] dc_addr, dc_wdata, dc_rdata;
wire [3:0]  dc_wstrb;
wire        mem_req, mem_we, mem_ready;
wire [31:0] mem_addr;
wire [127:0] mem_wdata, mem_rdata;

pipe pipe_u (
    .clk(slow_clk),
    .reset(reset),
    .stall(dc_stall),                       // <-- was 1'b0
    .exception(exception),
    .pc_out(current_pc),
    .inst_mem_is_valid(1'b1),
    .inst_mem_read_data(inst_mem_read_data),
    .dmem_read_data_temp(dmem_read_data),
    .dmem_write_valid(1'b1),
    .dmem_read_valid(1'b1),
    .inst_mem_address(inst_mem_address),
    .dmem_read_ready(dmem_read_ready),
    .dmem_read_address(dmem_read_address),
    .dmem_write_ready(dmem_write_ready),
    .dmem_write_address(dmem_write_address),
    .dmem_write_data(dmem_write_data),
    .dmem_write_byte(dmem_write_byte)
);

instr_mem IMEM (
    .clk(slow_clk),
    .en(~dc_stall_q),                       // <-- hold the fetched instruction while frozen
    .pc(inst_mem_address),
    .instr(inst_mem_read_data)
);

dcache_adapter ADAPTER (
    .clk(slow_clk), .rst(reset),
    .dmem_read_ready(dmem_read_ready),   .dmem_read_address(dmem_read_address),
    .dmem_write_ready(dmem_write_ready), .dmem_write_address(dmem_write_address),
    .dmem_write_data(dmem_write_data),   .dmem_write_byte(dmem_write_byte),
    .dmem_read_data_temp(dmem_read_data),
    .stall(dc_stall), .stall_q_o(dc_stall_q),
    .dc_re(dc_re), .dc_we(dc_we), .dc_addr(dc_addr),
    .dc_wdata(dc_wdata), .dc_wstrb(dc_wstrb),
    .dc_rdata(dc_rdata), .dc_ready(dc_ready)
);

dcache DCACHE (
    .clk(slow_clk), .rst(reset),
    .re(dc_re), .we(dc_we), .addr(dc_addr), .wdata(dc_wdata), .wstrb(dc_wstrb),
    .rdata(dc_rdata), .ready(dc_ready), .busy(dc_busy),
    .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr),
    .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_ready(mem_ready),
    .cache_en(cache_en), .hit_pulse(), .miss_pulse()
);

mem_delay MEM (                              // your teammate's 128-bit backing memory
    .clk(slow_clk), .rst(reset),
    .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr),
    .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_ready(mem_ready)
);

endmodule


//OLD//


// `timescale 1ns / 1ps

// module top_fpga #(
// 	parameter IMEMSIZE = 4096,
// 	parameter DMEMSIZE = 4096
// )(
// 	input  wire clk,    	// fast board clock (e.g. 100 MHz)
// 	input  wire reset,  	// active-high reset
 
 
// output [15:0] led
    
// );

// wire exception;
// 	////////////////////////////////////////////////////////////
// 	// Slow clock generator (clock divider)
// 	////////////////////////////////////////////////////////////
// ////////////////////////////////////////////////////////////
// // 100 MHz → 1 Hz clock divider (Nexys A7)
// ////////////////////////////////////////////////////////////
// reg [25:0] clk_cnt;   	// enough for 50 million
// reg    	slow_clk;

// always @(posedge clk or posedge reset) begin
// 	if (reset) begin
//     	clk_cnt  <= 26'd0;
//     	slow_clk <= 1'b0;
// 	end else begin
//     	if (clk_cnt == 26'd49_999_999) begin
//         	clk_cnt  <= 26'd0;
//         	slow_clk <= ~slow_clk;   // toggle every 0.5 sec
//     	end else begin
//         	clk_cnt <= clk_cnt + 1'b1;
//     	end
// 	end
// end


// 	////////////////////////////////////////////////////////////
// 	// PIPE ↔ MEMORY WIRES
// 	////////////////////////////////////////////////////////////
// 	wire [31:0] inst_mem_read_data;
// 	wire    	inst_mem_is_valid;

// 	wire [31:0] dmem_read_data;
// 	wire    	dmem_write_valid;
// 	wire    	dmem_read_valid;

// 	assign inst_mem_is_valid = 1'b1;
// 	assign dmem_write_valid  = 1'b1;
// 	assign dmem_read_valid   = 1'b1;
// 	wire [31:0] current_pc;
// assign led = current_pc[15:0];

// wire [31:0] inst_mem_address;
// wire        dmem_read_ready;
// wire [31:0] dmem_read_address;
// wire        dmem_write_ready;
// wire [31:0] dmem_write_address;
// wire [31:0] dmem_write_data;
// wire [3:0]  dmem_write_byte;
// ////////////////////////////////////////////////////////////
// // PIPELINE CPU
// ////////////////////////////////////////////////////////////
// pipe pipe_u (
// 	.clk(slow_clk),
// 	.reset(reset),
// 	.stall(1'b0),
// 	.exception(exception),
// 	.pc_out(current_pc),

// 	.inst_mem_is_valid(inst_mem_is_valid),
// 	.inst_mem_read_data(inst_mem_read_data),

// 	.dmem_read_data_temp(dmem_read_data),
// 	.dmem_write_valid(dmem_write_valid),
// 	.dmem_read_valid(dmem_read_valid),
// // TODO: Might have a few more port signals
//     .inst_mem_address(inst_mem_address),
//     .dmem_read_ready(dmem_read_ready),
//     .dmem_read_address(dmem_read_address),
//     .dmem_write_ready(dmem_write_ready),
//     .dmem_write_address(dmem_write_address),
//     .dmem_write_data(dmem_write_data),
//     .dmem_write_byte(dmem_write_byte)
// );


// ////////////////////////////////////////////////////////////
// // INSTRUCTION MEMORY  (matches instr_mem.v)
// ////////////////////////////////////////////////////////////
// instr_mem IMEM (
// 	.clk(slow_clk),
// 	.pc(inst_mem_address),//TODO
// 	.instr(inst_mem_read_data)
// );


// ////////////////////////////////////////////////////////////
// // DATA MEMORY  (matches data_mem.v)
// ////////////////////////////////////////////////////////////
// data_mem DMEM (
// 	.clk(slow_clk),

// 	.re(dmem_read_ready),//TODO
// 	.raddr(dmem_read_address),//TODO
// 	.rdata(dmem_read_data),

// 	.we(dmem_write_ready),//TODO
// 	.waddr(dmem_write_address),//TODO
// 	.wdata(dmem_write_data),//TODO
// 	.wstrb(dmem_write_byte)//TODO
// );



// endmodule