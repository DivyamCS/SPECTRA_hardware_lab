////////////////////////////////////////////////////////////
// Single CPU Core
// - Private instruction memory
// - Shared data memory/cache interface
// - Synchronous, active-high reset
////////////////////////////////////////////////////////////

module core #(
    parameter [31:0] RESET = 32'h0000_0000
)(
    input  wire        clk,
    input  wire        reset,
    input  wire        stall,

    output wire        exception,
    output wire [31:0] pc_out,

    // Shared data-cache interface
    input  wire [31:0] dmem_read_data,
    input  wire        dmem_read_valid,
    input  wire        dmem_write_valid,

    output wire        dmem_read_ready,
    output wire [31:0] dmem_read_address,

    output wire        dmem_write_ready,
    output wire [31:0] dmem_write_address,
    output wire [31:0] dmem_write_data,
    output wire [3:0]  dmem_write_byte
);

    ////////////////////////////////////////////////////////////
    // Private Instruction Memory Interface
    ////////////////////////////////////////////////////////////

    wire [31:0] inst_mem_address;
    wire [31:0] inst_mem_read_data;
    reg         inst_mem_is_valid;

    // The instruction memory has a synchronous read interface.
    // Mark its output valid after the initial reset cycle.
    always @(posedge clk) begin
        if (reset)
            inst_mem_is_valid <= 1'b0;
        else
            inst_mem_is_valid <= 1'b1;
    end

    ////////////////////////////////////////////////////////////
    // Private Instruction Memory
    ////////////////////////////////////////////////////////////

    instr_mem IMEM (
        .clk   (clk),
        .reset (reset),
        .pc    (inst_mem_address),
        .instr (inst_mem_read_data)
    );

    ////////////////////////////////////////////////////////////
    // CPU Pipeline
    ////////////////////////////////////////////////////////////

    pipe #(
        .RESET (RESET)
    ) PIPELINE (
        .clk                  (clk),
        .reset                (reset),
        .stall                (stall),

        .exception            (exception),
        .pc_out               (pc_out),

        // Private instruction memory
        .inst_mem_is_valid    (inst_mem_is_valid),
        .inst_mem_read_data   (inst_mem_read_data),
        .inst_mem_address     (inst_mem_address),

        // Shared data-cache interface
        .dmem_read_data_temp  (dmem_read_data),
        .dmem_read_valid      (dmem_read_valid),
        .dmem_write_valid     (dmem_write_valid),

        .dmem_read_ready      (dmem_read_ready),
        .dmem_read_address    (dmem_read_address),

        .dmem_write_ready     (dmem_write_ready),
        .dmem_write_address   (dmem_write_address),
        .dmem_write_data      (dmem_write_data),
        .dmem_write_byte      (dmem_write_byte)
    );

endmodule