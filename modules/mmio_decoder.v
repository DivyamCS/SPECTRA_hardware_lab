// ============================================================
// mmio_decoder.v  —  Full MMIO Address Decoder
// ============================================================
// Decodes CPU store/load addresses in the MMIO region
// (0x8000_0000 – 0x8000_00FF) and routes them to the
// correct peripheral.
//
// MMIO Map (word-aligned, 32-bit):
//   0x80000000  UART_TX_DATA  write → TX byte
//   0x80000004  UART_TX_BUSY  read  → {31'd0, busy}
//   0x80000010  SEG7_VALUE    write → 20-bit binary to display
//   0x80000020  CORE_ID       read  → hart ID (0/1)
//   0x80000030  LOCK_ADDR     r/w   → test-and-set spinlock
//   0x80000034  BARRIER_CNT   r/w   → barrier counter
//   0x80000038  BARRIER_REL   r/w   → barrier release flag
//   0x8000003C  CORE1_RELEASE write → release core 1
//   0x80000040  CYCLE_CNT     read  → cycle counter
//   0x80000044  INSTRET_CNT   read  → retired-instr counter
//   0x80000050  CACHE_CTRL    r/w   → bit[0]=en, bit[1]=wp
//
// CPU interface matches data_mem / memory_delay:
//   we + waddr + wdata + wstrb  (write path)
//   re + raddr → rdata          (read path, combinational)
//
// Peripheral outputs:
//   uart_din / uart_valid      → uart_tx.v
//   seg7_val[19:0]             → seg7.v
//   core1_release              → startup.s release flag in BRAM
//   cache_ctrl[1:0]            → cache control
// ============================================================
`timescale 1ns / 1ps

module mmio_decoder #(
    parameter CORE_ID = 0    // 0 for core 0, 1 for core 1
)(
    input  wire        clk,
    input  wire        reset,

    // ---- CPU write interface ----
    input  wire        we,
    input  wire [31:0] waddr,
    input  wire [31:0] wdata,
    input  wire [ 3:0] wstrb,

    // ---- CPU read interface (combinational) ----
    input  wire        re,
    input  wire [31:0] raddr,
    output reg  [31:0] rdata,

    // ---- UART TX ----
    output reg  [ 7:0] uart_din,
    output reg         uart_valid,
    input  wire        uart_busy,

    // ---- 7-Segment display ----
    output reg  [19:0] seg7_val,

    // ---- Core-1 release ----
    output reg         core1_release,

    // ---- Spinlock / Barrier ----
    output reg  [31:0] lock_reg,
    output reg  [31:0] barrier_cnt,
    output reg         barrier_rel,

    // ---- Cache control ----
    output reg  [ 1:0] cache_ctrl,

    // ---- Performance counter inputs ----
    input  wire [31:0] cycle_cnt,
    input  wire [31:0] instret_cnt
);

    // ---- MMIO region check ----
    wire in_mmio_w = (waddr[31:8] == 24'h800000);
    wire in_mmio_r = (raddr[31:8] == 24'h800000);

    // ============================================================
    // WRITE path
    // ============================================================
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            uart_din      <= 8'd0;
            uart_valid    <= 1'b0;
            seg7_val      <= 20'd0;
            core1_release <= 1'b0;
            lock_reg      <= 32'd0;
            barrier_cnt   <= 32'd0;
            barrier_rel   <= 1'b0;
            cache_ctrl    <= 2'b01;    // cache on, write-back by default
        end
        else begin
            uart_valid <= 1'b0;        // default: no new byte

            if (we && in_mmio_w) begin
                case (waddr[7:0])
                    8'h00: begin        // UART TX DATA
                        uart_din   <= wdata[7:0];
                        uart_valid <= 1'b1;
                    end
                    8'h10: seg7_val      <= wdata[19:0];  // SEG7 value
                    8'h30: lock_reg      <= wdata;         // spinlock
                    8'h34: barrier_cnt   <= wdata;         // barrier counter
                    8'h38: barrier_rel   <= wdata[0];      // barrier release
                    8'h3C: core1_release <= wdata[0];      // release core 1
                    8'h50: cache_ctrl    <= wdata[1:0];    // cache ctrl
                    default: ;
                endcase
            end
        end
    end

    // ============================================================
    // READ path (combinational)
    // ============================================================
    always @(*) begin
        rdata = 32'd0;
        if (re && in_mmio_r) begin
            case (raddr[7:0])
                8'h00: rdata = {24'd0, uart_din};          // last TX byte
                8'h04: rdata = {31'd0, uart_busy};         // UART busy
                8'h10: rdata = {12'd0, seg7_val};          // SEG7 value
                8'h20: rdata = {31'd0, CORE_ID[0:0]};     // core ID
                8'h30: rdata = lock_reg;
                8'h34: rdata = barrier_cnt;
                8'h38: rdata = {31'd0, barrier_rel};
                8'h3C: rdata = {31'd0, core1_release};
                8'h40: rdata = cycle_cnt;                  // cycle counter
                8'h44: rdata = instret_cnt;                // instret counter
                8'h50: rdata = {30'd0, cache_ctrl};
                default: rdata = 32'hDEAD_BEEF;            // unmapped
            endcase
        end
    end

endmodule
