// ============================================================
// memory_delay.v  —  Wait-State Memory Delay Model
// ============================================================
// Wraps a data_mem (or imem_bram) and inserts WAIT_CYCLES
// wait states on every read, simulating off-chip DRAM latency.
//
// Interface mirrors data_mem so this module can be inserted
// transparently between pipe.v and the physical BRAM.
//
// Parameters
//   WAIT_CYCLES  – number of extra stall cycles before data is
//                  returned (default 7, range 5–10).
//
// Handshake (read path)
//   1. CPU asserts  re + raddr
//   2. memory_delay asserts  stall_out for WAIT_CYCLES cycles
//   3. After the wait, rdata is valid and stall_out deasserts
//
// Write path is pass-through (no stall added; writes complete
// in 1 cycle just like BRAM).
// ============================================================
`timescale 1ns / 1ps

module memory_delay #(
    parameter WAIT_CYCLES = 7          // 5–10 configurable
)(
    input  wire        clk,
    input  wire        reset,

    // ---- CPU-side (connects to pipe.v) ----
    input  wire        re,             // read enable from CPU
    input  wire [31:0] raddr,          // read address from CPU
    output wire [31:0] rdata,          // read data back to CPU
    output reg         stall_out,      // stall signal → pipe stall

    input  wire        we,             // write enable from CPU
    input  wire [31:0] waddr,          // write address
    input  wire [31:0] wdata,          // write data
    input  wire [ 3:0] wstrb,          // byte strobes

    // ---- Memory-side (connects to data_mem / BRAM) ----
    output reg         mem_re,         // pass-through read enable
    output reg  [31:0] mem_raddr,      // pass-through read address
    input  wire [31:0] mem_rdata,      // data coming back from mem

    output wire        mem_we,         // write pass-through
    output wire [31:0] mem_waddr,
    output wire [31:0] mem_wdata,
    output wire [ 3:0] mem_wstrb
);

    // --------------------------------------------------------
    // Write path: fully combinational pass-through (no stall)
    // --------------------------------------------------------
    assign mem_we    = we;
    assign mem_waddr = waddr;
    assign mem_wdata = wdata;
    assign mem_wstrb = wstrb;

    // --------------------------------------------------------
    // Read path: counter-based wait-state insertion
    // --------------------------------------------------------
    // State encoding
    localparam ST_IDLE  = 2'd0;   // waiting for a read request
    localparam ST_WAIT  = 2'd1;   // counting down wait cycles
    localparam ST_VALID = 2'd2;   // data is ready, stall released

    reg [ 1:0] state;
    reg [ 3:0] cnt;               // wait-state countdown
    reg [31:0] rdata_buf;         // latch the BRAM output
    reg        first_wait;        // high on first cycle of ST_WAIT (BRAM data valid)

    // The BRAM has 1-cycle read latency on its own; we must
    // issue the read one cycle early so data is ready after
    // WAIT_CYCLES total stall cycles.
    //
    // Cycle 0:  re asserted → issue mem_re, go to ST_WAIT
    // Cycle 1:  BRAM data appears on mem_rdata (latched here)
    // Cycles 1…WAIT_CYCLES: assert stall_out, count down
    // Cycle WAIT_CYCLES+1: deassert stall, return rdata_buf

    assign rdata = rdata_buf;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state      <= ST_IDLE;
            cnt        <= 4'd0;
            stall_out  <= 1'b0;
            mem_re     <= 1'b0;
            mem_raddr  <= 32'd0;
            rdata_buf  <= 32'd0;
            first_wait <= 1'b0;
        end
        else begin
            case (state)

                // ---- IDLE: wait for a read request ----
                ST_IDLE: begin
                    stall_out  <= 1'b0;
                    first_wait <= 1'b0;
                    if (re) begin
                        // Issue read to BRAM now; data appears next cycle.
                        mem_re     <= 1'b1;
                        mem_raddr  <= raddr;
                        stall_out  <= 1'b1;
                        first_wait <= 1'b1;
                        // cnt counts the remaining stall cycles AFTER
                        // the first one (where we latch BRAM data).
                        cnt        <= WAIT_CYCLES[3:0] - 4'd1;
                        state      <= ST_WAIT;
                    end
                    else begin
                        mem_re <= 1'b0;
                    end
                end

                // ---- WAIT: count down remaining stall cycles ----
                ST_WAIT: begin
                    mem_re    <= 1'b0;   // de-assert after one-shot
                    stall_out <= 1'b1;

                    // Latch BRAM output on the first ST_WAIT cycle.
                    // BRAM was presented the address on the previous
                    // posedge, so mem_rdata is valid right now.
                    if (first_wait) begin
                        rdata_buf  <= mem_rdata;
                        first_wait <= 1'b0;
                    end

                    if (cnt == 4'd0) begin
                        stall_out <= 1'b0;
                        state     <= ST_IDLE;
                    end
                    else begin
                        cnt <= cnt - 4'd1;
                    end
                end

                default: begin
                    state      <= ST_IDLE;
                    stall_out  <= 1'b0;
                    mem_re     <= 1'b0;
                    first_wait <= 1'b0;
                end

            endcase
        end
    end

endmodule
