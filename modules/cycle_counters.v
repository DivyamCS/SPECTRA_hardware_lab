// ============================================================
// cycle_counters.v  —  Cycle & Instruction-Retired Counters
// ============================================================
// Implements two 32-bit performance counters readable via MMIO:
//   CYCLE_CNT   @ MMIO_BASE + 0x40  — free-running clock cycles
//   INSTRET_CNT @ MMIO_BASE + 0x44  — retired instructions
//
// The instruction counter increments when the pipeline commits
// (wb_alu_to_reg asserted, or mem_write committed) and there
// is no stall.  Connect instret_en from the WB stage.
//
// Both counters clear on reset and never wrap (32-bit @ 50 MHz
// overflows after ~85 seconds — sufficient for benchmarks).
//
// Ports
//   clk, reset     – standard
//   instret_en     – pulse from WB stage: 1 cycle per retired instr
//   cycle_cnt_o    – current cycle count (MMIO read data)
//   instret_cnt_o  – current instret count (MMIO read data)
// ============================================================
`timescale 1ns / 1ps

module cycle_counters (
    input  wire        clk,
    input  wire        reset,
    input  wire        instret_en,      // 1 cycle per retired instruction

    output wire [31:0] cycle_cnt_o,
    output wire [31:0] instret_cnt_o
);

    reg [31:0] cycle_r;
    reg [31:0] instret_r;

    // ---- Cycle counter: always ticks ----
    always @(posedge clk or posedge reset) begin
        if (reset) cycle_r <= 32'd0;
        else        cycle_r <= cycle_r + 1'b1;
    end

    // ---- Instruction-retired counter ----
    always @(posedge clk or posedge reset) begin
        if (reset)          instret_r <= 32'd0;
        else if (instret_en) instret_r <= instret_r + 1'b1;
    end

    assign cycle_cnt_o   = cycle_r;
    assign instret_cnt_o = instret_r;

endmodule
