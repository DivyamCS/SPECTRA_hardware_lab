// ============================================================
// sw_counter_display.v  —  Switch-Selectable 7-Seg Display Mux
//                          (Task 8)
// ============================================================
// Multiplexes what is shown on the 6-digit 7-segment display
// based on the 4-bit slide switch inputs sw[3:0]:
//
//   sw[3:0] | Display Content
//   --------+--------------------------------------------------
//    4'b0000| Lower 6 decimal digits of cycle_cnt  (% 1,000,000)
//    4'b0001| Upper decimal digits of cycle_cnt   (/ 1,000,000)
//    4'b0010| Lower 6 decimal digits of instret   (% 1,000,000)
//    4'b0011| Upper decimal digits of instret    (/ 1,000,000)
//    4'b0100| Current Program Counter PC[19:0]
//    4'b0101| Bare-metal software MMIO override (mmio_seg7_val)
//    default| Bare-metal software MMIO override (mmio_seg7_val)
//
// The selected 20-bit value feeds directly into seg7.v
// (BCD Double-Dabble converter + 1 kHz anode TDM scanner).
// ============================================================
`timescale 1ns / 1ps

module sw_counter_display (
    input  wire        clk,
    input  wire        reset,

    input  wire [ 3:0] sw,              // Slide switches SW3-SW0
    input  wire [31:0] cycle_cnt,       // Hardware cycle counter
    input  wire [31:0] instret_cnt,     // Hardware instructions-retired counter
    input  wire [31:0] pc,              // Pipeline PC
    input  wire [19:0] mmio_seg7_val,   // Value written by software via MMIO

    output reg  [19:0] display_val,     // Value driven to seg7.v
    output reg  [ 2:0] mode_status      // Current mode indication (for LEDs/debug)
);

    // Synchronize switches to avoid metastability
    reg [3:0] sw_sync_0, sw_sync_1;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            sw_sync_0 <= 4'd0;
            sw_sync_1 <= 4'd0;
        end else begin
            sw_sync_0 <= sw;
            sw_sync_1 <= sw_sync_0;
        end
    end

    // Mux display value registered on clk
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            display_val <= 20'd0;
            mode_status <= 3'd0;
        end else begin
            case (sw_sync_1)
                4'b0000: begin
                    display_val <= cycle_cnt % 32'd1_000_000;
                    mode_status <= 3'd0; // Cycle Low
                end
                4'b0001: begin
                    display_val <= (cycle_cnt / 32'd1_000_000) % 32'd1_000_000;
                    mode_status <= 3'd1; // Cycle High
                end
                4'b0010: begin
                    display_val <= instret_cnt % 32'd1_000_000;
                    mode_status <= 3'd2; // Instret Low
                end
                4'b0011: begin
                    display_val <= (instret_cnt / 32'd1_000_000) % 32'd1_000_000;
                    mode_status <= 3'd3; // Instret High
                end
                4'b0100: begin
                    display_val <= pc[19:0];
                    mode_status <= 3'd4; // Program Counter
                end
                4'b0101: begin
                    display_val <= mmio_seg7_val;
                    mode_status <= 3'd5; // Software MMIO
                end
                default: begin
                    display_val <= mmio_seg7_val;
                    mode_status <= 3'd6; // Default to Software MMIO
                end
            endcase
        end
    end

endmodule
