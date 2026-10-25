`timescale 1ns / 1ps
`default_nettype none
// commit_trace - simulation-only commit trace of one SPECTRA core (spec: docs/spec/core.md,
// behaviour 4; format: docs/PROTOCOL.md section 8, the same as rv32sim -t).
// Instantiated by core.v at MEM/WB. On every clock edge with `retire`, writes one line to
// trace_rtl<HART_ID>.txt in the simulator's run directory:
//     PC INSTR [xN=VALUE] [ld ADDR | st ADDR DATA]
// xN=VALUE when the instruction writes a register other than x0 (`wb_we`, which mem_stage
// raises only for rd != 0); store DATA is rs2 masked to the access size, as rv32sim prints it.
// Without `define SIM the module is empty: synthesis sees none of it.

module commit_trace #(
    parameter HART_ID = 0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        retire,         // an instruction leaves MEM/WB this cycle
    input  wire [31:0] pc,
    input  wire [31:0] instr,
    input  wire        wb_we,
    input  wire [4:0]  wb_rd,
    input  wire [31:0] wb_data,
    input  wire        is_load,
    input  wire        is_store,
    input  wire [1:0]  mem_size,       // 0 byte, 1 half, 2 word
    input  wire [31:0] addr,
    input  wire [31:0] store_data      // rs2 after forwarding, unformatted
);

`ifdef SIM
    integer fd;
    initial begin
        fd = $fopen(HART_ID == 0 ? "trace_rtl0.txt" : "trace_rtl1.txt", "w");
        if (fd == 0) $display("commit_trace: cannot open trace_rtl%0d.txt", HART_ID);
    end

    wire [31:0] st_masked = (mem_size == 2'd0) ? {24'd0, store_data[7:0]}  :
                            (mem_size == 2'd1) ? {16'd0, store_data[15:0]} : store_data;

    always @(posedge clk) begin
        if (!rst && retire && fd != 0) begin
            $fwrite(fd, "%08x %08x", pc, instr);
            if (wb_we)    $fwrite(fd, " x%0d=%08x", wb_rd, wb_data);
            if (is_load)  $fwrite(fd, " ld %08x", addr);
            if (is_store) $fwrite(fd, " st %08x %08x", addr, st_masked);
            $fwrite(fd, "\n");
            $fflush(fd);                    // complete lines even if the run stops abruptly
        end
    end
`endif

endmodule

`default_nettype wire
