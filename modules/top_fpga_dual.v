// ============================================================
// top_fpga_dual.v  —  Full Dual-Core CAMEO Top Module (Task 10)
// ============================================================
// Complete integration of the dual-core RISC-V architecture on Nexys A7:
//   - 100 MHz board oscillator with 50 MHz pipeline clock divider
//   - Dual CPU Cores (pipe_0: Hart 0, pipe_1: Hart 1)
//   - Dedicated Instruction Memory BRAMs for each core
//   - Shared Data Memory BRAM with wait-state generator (memory_delay.v)
//   - Round-robin memory arbiter for fair core access
//   - Core 1 release register (0x8000_003C): Core 1 stays in reset until
//     Core 0 boots and triggers release
//   - Shared MMIO block with hardware spinlocks & barriers (Task 5)
//   - Dual-Core Performance Counters (cycles, instret for each core)
//   - Result Streamer (store_streamer.v) snooping stores (Task 6)
//   - UART Transmitter (uart_tx.v at 115200 baud on pin D4)
//   - Switch-selectable 7-segment display (Task 8) with Core 0/1 metrics
//   - Status LEDs for both cores
// ============================================================
`timescale 1ns / 1ps

module top_fpga_dual #(
    parameter CLK_HZ    = 50_000_000,
    parameter BAUD      = 115_200,
    parameter MEM_DELAY = 5
)(
    input  wire        clk,        // 100 MHz board clock (pin E3)
    input  wire        reset,      // Active-high BTNC (pin N17)

    // UART serial output
    output wire        uart_tx,    // USB-UART TXD (pin D4)

    // 7-segment display
    output wire [6:0]  seg,        // Segments CA-CG (pins T10-L18)
    output wire        dp,         // Decimal point (pin H15)
    output wire [5:0]  an,         // Digit anodes AN0-AN5 (pins J17-T14)

    // Slide switches
    input  wire [3:0]  sw,         // SW0-SW3 (pins J15, L16, M13, R15)

    // Status LEDs
    output wire [15:0] led         // LD0-LD15 (pins H17-V11)
);

    // ------------------------------------------------------------
    // 1. Clock divider: 100 MHz -> 50 MHz system clock
    // ------------------------------------------------------------
    reg sys_clk;
    always @(posedge clk or posedge reset) begin
        if (reset) sys_clk <= 1'b0;
        else       sys_clk <= ~sys_clk;
    end

    // ------------------------------------------------------------
    // 2. Core 1 Release Logic
    // ------------------------------------------------------------
    wire core1_release_pulse;
    reg  core1_released;
    always @(posedge sys_clk or posedge reset) begin
        if (reset)
            core1_released <= 1'b0;
        else if (core1_release_pulse)
            core1_released <= 1'b1;
    end
    wire core1_reset = reset | ~core1_released;

    // ------------------------------------------------------------
    // 3. Core 0 Signals
    // ------------------------------------------------------------
    wire        c0_stall;
    wire        c0_exception;
    wire [31:0] c0_pc;
    wire [31:0] c0_imem_addr, c0_imem_rdata;
    wire        c0_dmem_re, c0_dmem_we;
    wire [31:0] c0_dmem_raddr, c0_dmem_rdata;
    wire [31:0] c0_dmem_waddr, c0_dmem_wdata;
    wire [ 3:0] c0_dmem_wstrb;

    // ------------------------------------------------------------
    // 4. Core 1 Signals
    // ------------------------------------------------------------
    wire        c1_stall;
    wire        c1_exception;
    wire [31:0] c1_pc;
    wire [31:0] c1_imem_addr, c1_imem_rdata;
    wire        c1_dmem_re, c1_dmem_we;
    wire [31:0] c1_dmem_raddr, c1_dmem_rdata;
    wire [31:0] c1_dmem_waddr, c1_dmem_wdata;
    wire [ 3:0] c1_dmem_wstrb;

    // ------------------------------------------------------------
    // 5. Instruction Memories (Dedicated BRAM per core)
    // ------------------------------------------------------------
    instr_mem IMEM_0 (
        .clk   (sys_clk),
        .pc    (c0_imem_addr),
        .instr (c0_imem_rdata)
    );

    instr_mem IMEM_1 (
        .clk   (sys_clk),
        .pc    (c1_imem_addr),
        .instr (c1_imem_rdata)
    );

    // ------------------------------------------------------------
    // 6. Round-Robin Shared Memory Arbiter
    // ------------------------------------------------------------
    reg arb_turn; // 0 = Core 0 priority, 1 = Core 1 priority
    wire c0_req = (c0_dmem_re || c0_dmem_we) && !c0_dmem_raddr[31] && !c0_dmem_waddr[31];
    wire c1_req = (c1_dmem_re || c1_dmem_we) && !c1_dmem_raddr[31] && !c1_dmem_waddr[31];

    wire grant_c0 = c0_req && (!c1_req || arb_turn == 1'b0);
    wire grant_c1 = c1_req && (!c0_req || arb_turn == 1'b1);

    always @(posedge sys_clk or posedge reset) begin
        if (reset) arb_turn <= 1'b0;
        else if (grant_c0 && c1_req) arb_turn <= 1'b1;
        else if (grant_c1 && c0_req) arb_turn <= 1'b0;
    end

    // Multiplexed bus to memory_delay
    wire        arb_re    = grant_c0 ? c0_dmem_re    : (grant_c1 ? c1_dmem_re    : 1'b0);
    wire [31:0] arb_raddr = grant_c0 ? c0_dmem_raddr : (grant_c1 ? c1_dmem_raddr : 32'd0);
    wire        arb_we    = grant_c0 ? c0_dmem_we    : (grant_c1 ? c1_dmem_we    : 1'b0);
    wire [31:0] arb_waddr = grant_c0 ? c0_dmem_waddr : (grant_c1 ? c1_dmem_waddr : 32'd0);
    wire [31:0] arb_wdata = grant_c0 ? c0_dmem_wdata : (grant_c1 ? c1_dmem_wdata : 32'd0);
    wire [ 3:0] arb_wstrb = grant_c0 ? c0_dmem_wstrb : (grant_c1 ? c1_dmem_wstrb : 4'd0);

    wire        shared_mem_stall;
    wire [31:0] shared_bram_rdata;

    // Stall logic for each core: stalled if active request not granted or memory delay is busy
    assign c0_stall = (c0_req && !grant_c0) || (grant_c0 && shared_mem_stall);
    assign c1_stall = (c1_req && !grant_c1) || (grant_c1 && shared_mem_stall);

    // ------------------------------------------------------------
    // 7. Shared Memory Delay Module
    // ------------------------------------------------------------
    wire        bram_re, bram_we;
    wire [31:0] bram_raddr, bram_waddr, bram_wdata, bram_raw_rdata;
    wire [ 3:0] bram_wstrb;

    memory_delay #(
        .WAIT_CYCLES(MEM_DELAY)
    ) U_MEM_DELAY (
        .clk       (sys_clk),
        .reset     (reset),
        .re        (arb_re),
        .raddr     (arb_raddr),
        .rdata     (shared_bram_rdata),
        .stall_out (shared_mem_stall),
        .we        (arb_we),
        .waddr     (arb_waddr),
        .wdata     (arb_wdata),
        .wstrb     (arb_wstrb),
        .mem_re    (bram_re),
        .mem_raddr (bram_raddr),
        .mem_rdata (bram_raw_rdata),
        .mem_we    (bram_we),
        .mem_waddr (bram_waddr),
        .mem_wdata (bram_wdata),
        .mem_wstrb (bram_wstrb)
    );

    data_mem DMEM (
        .clk   (sys_clk),
        .re    (bram_re),
        .raddr (bram_raddr),
        .rdata (bram_raw_rdata),
        .we    (bram_we),
        .waddr (bram_waddr),
        .wdata (bram_wdata),
        .wstrb (bram_wstrb)
    );

    // ------------------------------------------------------------
    // 8. Performance Counters & MMIO Decoder (Shared & Core-Specific)
    // ------------------------------------------------------------
    wire [31:0] c0_cycles, c0_instret;
    wire [31:0] c1_cycles, c1_instret;

    cycle_counters U_PERF_C0 (
        .clk           (sys_clk),
        .reset         (reset),
        .instret_en    (!c0_stall && !c0_exception),
        .cycle_cnt_o   (c0_cycles),
        .instret_cnt_o (c0_instret)
    );

    cycle_counters U_PERF_C1 (
        .clk           (sys_clk),
        .reset         (core1_reset),
        .instret_en    (!c1_stall && !c1_exception && core1_released),
        .cycle_cnt_o   (c1_cycles),
        .instret_cnt_o (c1_instret)
    );

    // Core 0 MMIO
    wire [31:0] c0_mmio_rdata;
    wire [ 7:0] c0_uart_din;
    wire        c0_uart_valid;
    wire [19:0] c0_seg7_val;
    wire        uart_busy;

    mmio_decoder #(.CORE_ID(0)) MMIO_C0 (
        .clk           (sys_clk),
        .reset         (reset),
        .we            (c0_dmem_we && c0_dmem_waddr[31]),
        .waddr         (c0_dmem_waddr),
        .wdata         (c0_dmem_wdata),
        .wstrb         (c0_dmem_wstrb),
        .re            (c0_dmem_re && c0_dmem_raddr[31]),
        .raddr         (c0_dmem_raddr),
        .rdata         (c0_mmio_rdata),
        .uart_din      (c0_uart_din),
        .uart_valid    (c0_uart_valid),
        .uart_busy     (uart_busy),
        .seg7_val      (c0_seg7_val),
        .core1_release (core1_release_pulse),
        .lock_reg      (),
        .barrier_cnt   (),
        .barrier_rel   (),
        .cache_ctrl    (),
        .cycle_cnt     (c0_cycles),
        .instret_cnt   (c0_instret)
    );

    // Core 1 MMIO
    wire [31:0] c1_mmio_rdata;
    wire [ 7:0] c1_uart_din;
    wire        c1_uart_valid;
    wire [19:0] c1_seg7_val;

    mmio_decoder #(.CORE_ID(1)) MMIO_C1 (
        .clk           (sys_clk),
        .reset         (core1_reset),
        .we            (c1_dmem_we && c1_dmem_waddr[31]),
        .waddr         (c1_dmem_waddr),
        .wdata         (c1_dmem_wdata),
        .wstrb         (c1_dmem_wstrb),
        .re            (c1_dmem_re && c1_dmem_raddr[31]),
        .raddr         (c1_dmem_raddr),
        .rdata         (c1_mmio_rdata),
        .uart_din      (c1_uart_din),
        .uart_valid    (c1_uart_valid),
        .uart_busy     (uart_busy),
        .seg7_val      (c1_seg7_val),
        .core1_release (),
        .lock_reg      (),
        .barrier_cnt   (),
        .barrier_rel   (),
        .cache_ctrl    (),
        .cycle_cnt     (c1_cycles),
        .instret_cnt   (c1_instret)
    );

    assign c0_dmem_rdata = (c0_dmem_raddr[31]) ? c0_mmio_rdata : shared_bram_rdata;
    assign c1_dmem_rdata = (c1_dmem_raddr[31]) ? c1_mmio_rdata : shared_bram_rdata;

    // ------------------------------------------------------------
    // 9. CPU Core Pipelines
    // ------------------------------------------------------------
    pipe pipe_core0 (
        .clk                 (sys_clk),
        .reset               (reset),
        .stall               (c0_stall),
        .exception           (c0_exception),
        .pc_out              (c0_pc),
        .inst_mem_is_valid   (1'b1),
        .inst_mem_read_data  (c0_imem_rdata),
        .dmem_read_data_temp (c0_dmem_rdata),
        .dmem_write_valid    (1'b1),
        .dmem_read_valid     (1'b1),
        .inst_mem_address    (c0_imem_addr),
        .dmem_read_ready     (c0_dmem_re),
        .dmem_read_address   (c0_dmem_raddr),
        .dmem_write_ready    (c0_dmem_we),
        .dmem_write_address  (c0_dmem_waddr),
        .dmem_write_data     (c0_dmem_wdata),
        .dmem_write_byte     (c0_dmem_wstrb)
    );

    pipe pipe_core1 (
        .clk                 (sys_clk),
        .reset               (core1_reset),
        .stall               (c1_stall),
        .exception           (c1_exception),
        .pc_out              (c1_pc),
        .inst_mem_is_valid   (1'b1),
        .inst_mem_read_data  (c1_imem_rdata),
        .dmem_read_data_temp (c1_dmem_rdata),
        .dmem_write_valid    (1'b1),
        .dmem_read_valid     (1'b1),
        .inst_mem_address    (c1_imem_addr),
        .dmem_read_ready     (c1_dmem_re),
        .dmem_read_address   (c1_dmem_raddr),
        .dmem_write_ready    (c1_dmem_we),
        .dmem_write_address  (c1_dmem_waddr),
        .dmem_write_data     (c1_dmem_wdata),
        .dmem_write_byte     (c1_dmem_wstrb)
    );

    // ------------------------------------------------------------
    // 10. Result Streamer
    // ------------------------------------------------------------
    wire [ 7:0] stream_uart_din;
    wire        stream_uart_valid;

    // Stream stores from whichever core was granted memory write
    store_streamer #(
        .OUTPUT_BASE (32'h0001_F000),
        .OUTPUT_MASK (32'hFFFF_F000)
    ) U_STREAMER (
        .clk        (sys_clk),
        .reset      (reset),
        .we         (arb_we),
        .waddr      (arb_waddr),
        .wdata      (arb_wdata),
        .uart_din   (stream_uart_din),
        .uart_valid (stream_uart_valid),
        .uart_busy  (uart_busy)
    );

    // ------------------------------------------------------------
    // 11. UART Transmitter Arbiter
    // ------------------------------------------------------------
    wire [7:0] uart_tx_din = c0_uart_valid ? c0_uart_din :
                            (c1_uart_valid ? c1_uart_din : stream_uart_din);
    wire uart_tx_valid     = c0_uart_valid | c1_uart_valid | stream_uart_valid;

    uart_tx #(
        .CLK_HZ (CLK_HZ),
        .BAUD   (BAUD)
    ) U_UART (
        .clk   (sys_clk),
        .reset (reset),
        .din   (uart_tx_din),
        .valid (uart_tx_valid),
        .busy  (uart_busy),
        .tx    (uart_tx)
    );

    // ------------------------------------------------------------
    // 12. Switch-Selectable Display & 7-Segment Driver
    // ------------------------------------------------------------
    // SW[3] selects between Core 0 (SW[3]=0) and Core 1 (SW[3]=1)
    wire [31:0] sel_cycles  = sw[3] ? c1_cycles  : c0_cycles;
    wire [31:0] sel_instret = sw[3] ? c1_instret : c0_instret;
    wire [31:0] sel_pc      = sw[3] ? c1_pc      : c0_pc;
    wire [19:0] sel_mmio    = sw[3] ? c1_seg7_val: c0_seg7_val;

    wire [19:0] display_num;
    wire [ 2:0] mode_status;

    sw_counter_display U_SW_DISP (
        .clk           (sys_clk),
        .reset         (reset),
        .sw            ({1'b0, sw[2:0]}),
        .cycle_cnt     (sel_cycles),
        .instret_cnt   (sel_instret),
        .pc            (sel_pc),
        .mmio_seg7_val (sel_mmio),
        .display_val   (display_num),
        .mode_status   (mode_status)
    );

    seg7 #(
        .CLK_HZ (CLK_HZ)
    ) U_SEG7 (
        .clk    (sys_clk),
        .reset  (reset),
        .bin_in (display_num),
        .seg    (seg),
        .dp     (dp),
        .an     (an)
    );

    // ------------------------------------------------------------
    // 13. Status LEDs
    // ------------------------------------------------------------
    reg [24:0] hb_cnt;
    always @(posedge sys_clk or posedge reset) begin
        if (reset) hb_cnt <= 25'd0;
        else       hb_cnt <= hb_cnt + 1'b1;
    end

    assign led[15:10] = c0_pc[7:2];       // Core 0 PC
    assign led[ 9: 6] = c1_pc[5:2];       // Core 1 PC
    assign led[    5] = core1_released;   // Core 1 active indicator
    assign led[    4] = sw[3];            // Selected core on 7-seg (0=C0, 1=C1)
    assign led[ 3: 1] = mode_status;      // 7-segment display mode
    assign led[    0] = hb_cnt[24];       // Heartbeat LED

endmodule
