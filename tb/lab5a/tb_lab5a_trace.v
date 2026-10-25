`timescale 1ns/1ps
// tb_lab5a_trace - commit trace of the UNMODIFIED lab 5A core.
//
// The lab core has no commit-trace output and no per-stage valid bit, so this testbench
// follows each instruction from outside: it copies the PC and instruction word the core's
// ID/EX register captures (inst_fetch_pc, inst_mem_read_data) and moves them along a shadow
// pipeline, EX -> MEM/WB, on the same clock edges as the core. An instruction retires when it
// is in MEM/WB and the core is not squashing it (wb_stall = 0, the lab's 2-cycle branch
// squash). The register write, load address and store (address, data as written to memory)
// are read from the core's own MEM/WB signals.
//
// Output: one line per retired instruction in the format of docs/PROTOCOL.md section 8,
// written to trace_rtl0.txt in the run directory. The run ends after the load from
// SWITCHES (0x2000_0038), the last instruction of the test image; then it prints
// "PASS tb_lab5a_trace" (trace complete; tools/tracecmp.py compares it with rv32sim).
// A watchdog prints FAIL after 100,000 cycles without reaching the end.

module tb_lab5a_trace;

reg clk = 1'b0;
reg reset = 1'b1;
always #5 clk = ~clk;
initial begin
    #100 reset = 1'b0;
end

// ---- the lab core and the lab memories, wired exactly as in the lab's tb_pipeline ----
wire [31:0] inst_mem_read_data, dmem_read_data;
wire        exception;
wire [31:0] current_pc, inst_mem_address;
wire        dmem_read_ready, dmem_write_ready;
wire [31:0] dmem_read_address, dmem_write_address, dmem_write_data;
wire [3:0]  dmem_write_byte;

pipe DUT (
    .clk(clk), .reset(reset), .stall(1'b0), .exception(exception), .pc_out(current_pc),
    .inst_mem_is_valid(1'b1), .inst_mem_read_data(inst_mem_read_data),
    .dmem_read_data_temp(dmem_read_data), .dmem_write_valid(1'b1), .dmem_read_valid(1'b1),
    .inst_mem_address(inst_mem_address),
    .dmem_read_ready(dmem_read_ready), .dmem_read_address(dmem_read_address),
    .dmem_write_ready(dmem_write_ready), .dmem_write_address(dmem_write_address),
    .dmem_write_data(dmem_write_data), .dmem_write_byte(dmem_write_byte)
);

instr_mem IMEM (.clk(clk), .pc(inst_mem_address), .instr(inst_mem_read_data));

data_mem DMEM (
    .clk(clk),
    .re(dmem_read_ready), .raddr(dmem_read_address), .rdata(dmem_read_data),
    .we(dmem_write_ready), .waddr(dmem_write_address), .wdata(dmem_write_data),
    .wstrb(dmem_write_byte)
);

// ---- shadow pipeline: which instruction is in EX and in MEM/WB ----
reg        ex_v = 1'b0, wb_v = 1'b0;
reg [31:0] ex_pc, ex_ins, wb_pc, wb_ins, wb_ldaddr;

always @(posedge clk) begin
    if (reset) begin
        ex_v <= 1'b0;
        wb_v <= 1'b0;
    end else if (!DUT.stall_read) begin
        ex_v      <= !DUT.boot_bubble;           // ID/EX captures every cycle once reset is low,
                                                 // except the NOP of the boot-bubble fix
        ex_pc     <= DUT.inst_fetch_pc;
        ex_ins    <= inst_mem_read_data;
        wb_v      <= ex_v;
        wb_pc     <= ex_pc;
        wb_ins    <= ex_ins;
        wb_ldaddr <= dmem_read_address;          // load address is formed in EX
    end
end

// ---- retirement: sample MEM/WB just before each clock edge ----
integer    fd, cycles = 0, retired = 0;
reg        rf_we;
reg [31:0] rf_val, st_data;
reg [1:0]  lane;

initial begin
    fd = $fopen("trace_rtl0.txt", "w");
end

always @(posedge clk) begin
    if (!reset) begin
        cycles = cycles + 1;
        if (wb_v && !DUT.wb_stall && !DUT.stall_read) begin
            retired = retired + 1;
            rf_we  = DUT.wb_alu_to_reg && (DUT.wb_dest_reg_sel != 5'd0);
            rf_val = DUT.wb_mem_to_reg ? DUT.wb_read_data : DUT.wb_result;
            $fwrite(fd, "%08x %08x", wb_pc, wb_ins);
            if (rf_we)
                $fwrite(fd, " x%0d=%08x", DUT.wb_dest_reg_sel, rf_val);
            if (DUT.wb_mem_to_reg)
                $fwrite(fd, " ld %08x", wb_ldaddr);
            if (DUT.wb_mem_write) begin
                // the data as it reaches memory: the byte lanes the strobes enable
                lane = DUT.wb_write_address[1:0];
                case (DUT.wb_write_byte)
                    4'b1111: st_data = DUT.wb_write_data;
                    4'b0011: st_data = {16'h0, DUT.wb_write_data[15:0]};
                    4'b1100: st_data = {16'h0, DUT.wb_write_data[31:16]};
                    default: st_data = {24'h0, DUT.wb_write_data[8*lane +: 8]};
                endcase
                $fwrite(fd, " st %08x %08x", DUT.wb_write_address, st_data);
            end
            $fwrite(fd, "\n");
            if (DUT.wb_mem_to_reg && wb_ldaddr == 32'h2000_0038) begin
                $fclose(fd);
                $display("retired %0d instructions in %0d cycles; exception flag = %0d",
                         retired, cycles, exception);
                $display("PASS tb_lab5a_trace");
                $finish;
            end
        end
        if (cycles == 100000) begin
            $fclose(fd);
            $display("FAIL tb_lab5a_trace: end of program not reached after 100000 cycles (%0d retired)", retired);
            $finish;
        end
    end
end

endmodule
