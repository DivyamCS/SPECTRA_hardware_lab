// ============================================================
// top_fpga.v  —  Single-Core FPGA Bring-Up Top Module (Task 7)
// ============================================================
// Integrates on Nexys A7:
//   - 100 MHz board clock with 50 MHz system clock divider
//   - Single-Core RISC-V 3-stage CPU pipeline (pipe.v)
//   - Instruction Memory BRAM (instr_mem)
//   - Data Memory BRAM (data_mem) with wait-state delay (mem_delay.v)
//   - MMIO Address Decoder (mmio_decoder.v at 0x8000_0000)
//   - Hardware Performance Counters (perf_counters.v)
//   - Result Streamer (result_streamer.v snooping 0x0001_F000)
//   - UART Transmitter (uart_tx.v at 115200 baud on pin D4)
//   - Switch-Selectable 7-Segment Display (sw_counter_display.v + seg7.v)
//   - Status LEDs (led[15:0])
// ============================================================
`timescale 1ns / 1ps

module top_fpga #(
    parameter CLK_HZ      = 50_000_000,
    parameter BAUD        = 115_200,
    parameter MEM_DELAY   = 5
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
        if (reset)
            sys_clk <= 1'b0;
        else
            sys_clk <= ~sys_clk;
    end

    // ------------------------------------------------------------
    // 2. CPU Pipeline Signals
    // ------------------------------------------------------------
    wire        pipe_stall;
    wire        exception;
    wire [31:0] current_pc;

    wire [31:0] imem_addr;
    wire [31:0] imem_rdata;

    wire        dmem_re;
    wire [31:0] dmem_raddr;
    wire [31:0] dmem_rdata;
    wire        dmem_we;
    wire [31:0] dmem_waddr;
    wire [31:0] dmem_wdata;
    wire [ 3:0] dmem_wstrb;

    // Address region decode: MMIO is 0x8000_0000 and above
    wire is_mmio_read  = dmem_re && dmem_raddr[31];
    wire is_mmio_write = dmem_we && dmem_waddr[31];
    wire is_bram_read  = dmem_re && !dmem_raddr[31];
    wire is_bram_write = dmem_we && !dmem_waddr[31];

    // Stall CPU when memory delay is active on BRAM accesses
    wire mem_delay_stall;
    assign pipe_stall = mem_delay_stall;

    // Multiplex CPU read data between MMIO and delayed BRAM
    wire [31:0] mmio_rdata;
    wire [31:0] bram_delayed_rdata;
    assign dmem_rdata = (dmem_raddr[31]) ? mmio_rdata : bram_delayed_rdata;

    // ------------------------------------------------------------
    // 3. Instruction Memory BRAM
    // ------------------------------------------------------------
    instr_mem IMEM (
        .clk   (sys_clk),
        .pc    (imem_addr),
        .instr (imem_rdata)
    );

    // ------------------------------------------------------------
    // 4. Memory Delay Module (Wait-State Generator)
    // ------------------------------------------------------------
    wire        bram_re;
    wire [31:0] bram_raddr;
    wire [31:0] bram_raw_rdata;
    wire        bram_we;
    wire [31:0] bram_waddr;
    wire [31:0] bram_wdata;
    wire [ 3:0] bram_wstrb;

    mem_delay #(
        .WAIT_CYCLES(MEM_DELAY)
    ) U_MEM_DELAY (
        .clk         (sys_clk),
        .reset       (reset),

        // CPU facing port
        .re          (is_bram_read),
        .raddr       (dmem_raddr),
        .rdata       (bram_delayed_rdata),
        .stall_out   (mem_delay_stall),
        .we          (is_bram_write),
        .waddr       (dmem_waddr),
        .wdata       (dmem_wdata),
        .wstrb       (dmem_wstrb),

        // Physical BRAM facing port
        .mem_re      (bram_re),
        .mem_raddr   (bram_raddr),
        .mem_rdata   (bram_raw_rdata),
        .mem_we      (bram_we),
        .mem_waddr   (bram_waddr),
        .mem_wdata   (bram_wdata),
        .mem_wstrb   (bram_wstrb)
    );

    // ------------------------------------------------------------
    // 5. Physical Data Memory BRAM
    // ------------------------------------------------------------
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
    // 6. CPU Pipeline Datapath
    // ------------------------------------------------------------
    pipe pipe_u (
        .clk                 (sys_clk),
        .reset               (reset),
        .stall               (pipe_stall),
        .exception           (exception),
        .pc_out              (current_pc),

        .inst_mem_is_valid   (1'b1),
        .inst_mem_read_data  (imem_rdata),
        .dmem_read_data_temp (dmem_rdata),
        .dmem_write_valid    (1'b1),
        .dmem_read_valid     (1'b1),

        .inst_mem_address    (imem_addr),
        .dmem_read_ready     (dmem_re),
        .dmem_read_address   (dmem_raddr),
        .dmem_write_ready    (dmem_we),
        .dmem_write_address  (dmem_waddr),
        .dmem_write_data     (dmem_wdata),
        .dmem_write_byte     (dmem_wstrb)
    );

    // ------------------------------------------------------------
    // 7. Hardware Performance Counters (Task 5)
    // ------------------------------------------------------------
    wire [31:0] cycle_cnt;
    wire [31:0] instret_cnt;
    // An instruction retires when pipeline is active and not stalled
    wire instret_pulse = !pipe_stall && !exception;

    perf_counters U_PERF (
        .clk           (sys_clk),
        .reset         (reset),
        .instret_en    (instret_pulse),
        .cycle_cnt_o   (cycle_cnt),
        .instret_cnt_o (instret_cnt)
    );

    // ------------------------------------------------------------
    // 8. MMIO Address Decoder (Task 5)
    // ------------------------------------------------------------
    wire [ 7:0] mmio_uart_din;
    wire        mmio_uart_valid;
    wire [19:0] mmio_seg7_val;
    wire        uart_busy;

    mmio_decoder #(
        .CORE_ID(0)
    ) U_MMIO (
        .clk           (sys_clk),
        .reset         (reset),
        .we            (is_mmio_write),
        .waddr         (dmem_waddr),
        .wdata         (dmem_wdata),
        .wstrb         (dmem_wstrb),
        .re            (is_mmio_read),
        .raddr         (dmem_raddr),
        .rdata         (mmio_rdata),

        .uart_din      (mmio_uart_din),
        .uart_valid    (mmio_uart_valid),
        .uart_busy     (uart_busy),

        .seg7_val      (mmio_seg7_val),
        .core1_release (),
        .lock_reg      (),
        .barrier_cnt   (),
        .barrier_rel   (),
        .cache_ctrl    (),

        .cycle_cnt     (cycle_cnt),
        .instret_cnt   (instret_cnt)
    );

    // ------------------------------------------------------------
    // 9. Result Streamer (Task 6)
    // ------------------------------------------------------------
    wire [ 7:0] stream_uart_din;
    wire        stream_uart_valid;

    result_streamer #(
        .OUTPUT_BASE (32'h0001_F000),
        .OUTPUT_MASK (32'hFFFF_F000)
    ) U_STREAMER (
        .clk        (sys_clk),
        .reset      (reset),
        .we         (dmem_we),
        .waddr      (dmem_waddr),
        .wdata      (dmem_wdata),
        .uart_din   (stream_uart_din),
        .uart_valid (stream_uart_valid),
        .uart_busy  (uart_busy)
    );

    // ------------------------------------------------------------
    // 10. UART TX Arbiter & Transmitter (Task 3 & 7)
    // ------------------------------------------------------------
    // Priority: Software MMIO console writes > Automated Result Streamer
    wire [7:0] uart_tx_din   = (mmio_uart_valid) ? mmio_uart_din : stream_uart_din;
    wire       uart_tx_valid = mmio_uart_valid | stream_uart_valid;

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
    // 11. Switch-Selectable Display & 7-Segment Driver (Task 4 & 8)
    // ------------------------------------------------------------
    wire [19:0] display_num;
    wire [ 2:0] mode_status;

    sw_counter_display U_SW_DISP (
        .clk           (sys_clk),
        .reset         (reset),
        .sw            (sw),
        .cycle_cnt     (cycle_cnt),
        .instret_cnt   (instret_cnt),
        .pc            (current_pc),
        .mmio_seg7_val (mmio_seg7_val),
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
    // 12. Diagnostic LEDs
    // ------------------------------------------------------------
    // Heartbeat counter for visual FPGA liveness check
    reg [24:0] hb_cnt;
    always @(posedge sys_clk or posedge reset) begin
        if (reset) hb_cnt <= 25'd0;
        else       hb_cnt <= hb_cnt + 1'b1;
    end

    assign led[15:8] = current_pc[9:2]; // Program counter instruction index
    assign led[ 7:4] = sw;              // Current slide switch setting
    assign led[ 3:1] = mode_status;     // Active display mode
    assign led[0]    = hb_cnt[24];      // Heartbeat blink (~1.5 Hz)

endmodule