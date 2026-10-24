////////////////////////////////////////////////////////////
// SPECTRA Dual-Core Top-Level
//
// - Two CPU cores
// - Private instruction memories (one per core)
// - Shared data-memory backend
// - Single shared read/write arbitration path
// - Synchronous, active-high reset
////////////////////////////////////////////////////////////

module top_core #(
    parameter [31:0] RESET0 = 32'h0000_0000,
    parameter [31:0] RESET1 = 32'h0000_0000
)(
    input  wire        clk,
    input  wire        reset,

    output wire [31:0] core0_pc,
    output wire [31:0] core1_pc,

    output wire        core0_exception,
    output wire        core1_exception
);

    ////////////////////////////////////////////////////////////
    // Core 0 Data-Memory Interface
    ////////////////////////////////////////////////////////////

    wire        c0_dmem_read_ready;
    wire [31:0] c0_dmem_read_address;

    wire        c0_dmem_write_ready;
    wire [31:0] c0_dmem_write_address;
    wire [31:0] c0_dmem_write_data;
    wire [3:0]  c0_dmem_write_byte;

    wire [31:0] c0_dmem_read_data;
    wire        c0_dmem_read_valid;
    wire        c0_dmem_write_valid;
    wire        c0_stall;

    ////////////////////////////////////////////////////////////
    // Core 1 Data-Memory Interface
    ////////////////////////////////////////////////////////////

    wire        c1_dmem_read_ready;
    wire [31:0] c1_dmem_read_address;

    wire        c1_dmem_write_ready;
    wire [31:0] c1_dmem_write_address;
    wire [31:0] c1_dmem_write_data;
    wire [3:0]  c1_dmem_write_byte;

    wire [31:0] c1_dmem_read_data;
    wire        c1_dmem_read_valid;
    wire        c1_dmem_write_valid;
    wire        c1_stall;

    ////////////////////////////////////////////////////////////
    // Shared Data-Memory Interface
    ////////////////////////////////////////////////////////////

    wire        shared_re;
    wire [31:0] shared_raddr;
    wire [31:0] shared_rdata;

    wire        shared_we;
    wire [31:0] shared_waddr;
    wire [31:0] shared_wdata;
    wire [3:0]  shared_wstrb;

    ////////////////////////////////////////////////////////////
    // Arbitration
    ////////////////////////////////////////////////////////////

    wire c0_request;
    wire c1_request;

    reg  round_robin;

    wire grant0;
    wire grant1;

    assign c0_request =
        c0_dmem_read_ready | c0_dmem_write_ready;

    assign c1_request =
        c1_dmem_read_ready | c1_dmem_write_ready;

    // round_robin = 0: prefer core 0
    // round_robin = 1: prefer core 1

    assign grant0 =
        c0_request &&
        (!c1_request || !round_robin);

    assign grant1 =
        c1_request &&
        (!c0_request || round_robin);

    // Stall a requesting core when it loses arbitration.
    assign c0_stall = c0_request && !grant0;
    assign c1_stall = c1_request && !grant1;

    // Advance priority after a contested grant.
    always @(posedge clk) begin
        if (reset)
            round_robin <= 1'b0;
        else if (c0_request && c1_request)
            round_robin <= ~round_robin;
    end

    ////////////////////////////////////////////////////////////
    // Shared Read Port
    ////////////////////////////////////////////////////////////

    assign shared_re =
        (grant0 && c0_dmem_read_ready) ||
        (grant1 && c1_dmem_read_ready);

    assign shared_raddr =
        (grant1)
            ? c1_dmem_read_address
            : c0_dmem_read_address;

    ////////////////////////////////////////////////////////////
    // Shared Write Port
    ////////////////////////////////////////////////////////////

    assign shared_we =
        (grant0 && c0_dmem_write_ready) ||
        (grant1 && c1_dmem_write_ready);

    assign shared_waddr =
        (grant1)
            ? c1_dmem_write_address
            : c0_dmem_write_address;

    assign shared_wdata =
        (grant1)
            ? c1_dmem_write_data
            : c0_dmem_write_data;

    assign shared_wstrb =
        (grant1)
            ? c1_dmem_write_byte
            : c0_dmem_write_byte;

    ////////////////////////////////////////////////////////////
    // Read Response Routing
    ////////////////////////////////////////////////////////////

    reg read_valid_q;
    reg read_owner_q;

    always @(posedge clk) begin
        if (reset) begin
            read_valid_q <= 1'b0;
            read_owner_q <= 1'b0;
        end
        else begin
            read_valid_q <= shared_re;

            if (shared_re)
                read_owner_q <= grant1;
        end
    end

    assign c0_dmem_read_valid =
        read_valid_q && !read_owner_q;

    assign c1_dmem_read_valid =
        read_valid_q && read_owner_q;

    // Read data is broadcast; validity identifies the recipient.
    assign c0_dmem_read_data = shared_rdata;
    assign c1_dmem_read_data = shared_rdata;

    // The current memory accepts writes synchronously.
    assign c0_dmem_write_valid =
        grant0 && c0_dmem_write_ready;

    assign c1_dmem_write_valid =
        grant1 && c1_dmem_write_ready;

    ////////////////////////////////////////////////////////////
    // Core 0
    // Private instruction memory is inside core.
    ////////////////////////////////////////////////////////////

    core #(
        .RESET (RESET0)
    ) CORE0 (
        .clk                 (clk),
        .reset               (reset),
        .stall               (c0_stall),

        .exception            (core0_exception),
        .pc_out               (core0_pc),

        .dmem_read_data       (c0_dmem_read_data),
        .dmem_read_valid      (c0_dmem_read_valid),
        .dmem_write_valid     (c0_dmem_write_valid),

        .dmem_read_ready      (c0_dmem_read_ready),
        .dmem_read_address    (c0_dmem_read_address),

        .dmem_write_ready     (c0_dmem_write_ready),
        .dmem_write_address   (c0_dmem_write_address),
        .dmem_write_data      (c0_dmem_write_data),
        .dmem_write_byte      (c0_dmem_write_byte)
    );

    ////////////////////////////////////////////////////////////
    // Core 1
    // Separate private instruction memory.
    ////////////////////////////////////////////////////////////

    core #(
        .RESET (RESET1)
    ) CORE1 (
        .clk                 (clk),
        .reset               (reset),
        .stall               (c1_stall),

        .exception            (core1_exception),
        .pc_out               (core1_pc),

        .dmem_read_data       (c1_dmem_read_data),
        .dmem_read_valid      (c1_dmem_read_valid),
        .dmem_write_valid     (c1_dmem_write_valid),

        .dmem_read_ready      (c1_dmem_read_ready),
        .dmem_read_address    (c1_dmem_read_address),

        .dmem_write_ready     (c1_dmem_write_ready),
        .dmem_write_address   (c1_dmem_write_address),
        .dmem_write_data      (c1_dmem_write_data),
        .dmem_write_byte      (c1_dmem_write_byte)
    );

    ////////////////////////////////////////////////////////////
    // Shared Data Memory
    //
    // Temporary shared backend. Replace with the shared
    // D-cache when its interface is implemented.
    ////////////////////////////////////////////////////////////

    data_mem DMEM (
        .clk   (clk),
        .reset (reset),

        .re    (shared_re),
        .raddr (shared_raddr),
        .rdata (shared_rdata),

        .we    (shared_we),
        .waddr (shared_waddr),
        .wdata (shared_wdata),
        .wstrb (shared_wstrb)
    );

endmodule