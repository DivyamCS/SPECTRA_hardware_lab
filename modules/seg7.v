// ============================================================
// seg7.v  —  BCD Double-Dabble + 7-Segment Display Driver
// ============================================================
// Converts a 20-bit binary number to BCD using the
// double-dabble (shift-and-add-3) algorithm, then drives
// six 7-segment digits (common-anode) on the Nexys A7 board
// using time-division multiplexing.
//
// Ports
//   bin_in[19:0]  – binary value 0 – 999999
//   clk           – board clock (100 MHz)
//   reset         – active-high synchronous reset
//   seg[6:0]      – segment outputs {CA,CB,CC,CD,CE,CF,CG} (active-low)
//   an[5:0]       – anode enables (active-low), one-hot scan
//   dp            – decimal point (active-low, always off)
//
// Internal pipeline
//   Stage 1: double-dabble combinational converter (≤26 shift steps)
//   Stage 2: 7-segment lookup ROM
//   Stage 3: mux + anode scan counter clocked at ~1 kHz
//
// Nexys A7 segment pinout (Digilent reference):
//   seg[6]=CA  seg[5]=CB  seg[4]=CC  seg[3]=CD
//   seg[2]=CE  seg[1]=CF  seg[0]=CG
// ============================================================
`timescale 1ns / 1ps

module seg7 #(
    parameter CLK_HZ   = 100_000_000,  // board clock
    parameter SCAN_HZ  = 1_000         // digit refresh rate
)(
    input  wire        clk,
    input  wire        reset,
    input  wire [19:0] bin_in,   // 0..999999

    output reg  [ 6:0] seg,      // active-low segments {CA..CG}
    output reg  [ 5:0] an,       // active-low anodes   (6 digits)
    output wire        dp         // decimal point (always off)
);

    assign dp = 1'b1;   // decimal point off (active-low, so 1=off)

    // ============================================================
    // Stage 1: Double-Dabble — binary to 6-digit BCD
    // ============================================================
    // 20-bit binary → 6 BCD digits (4 bits each) = 24-bit BCD
    // Algorithm: shift left 20 times;
    //            after each shift, add 3 to any BCD nybble ≥ 5.
    //
    // Implemented purely combinationally (no clock needed —
    // synthesiser unrolls the loop into LUTs).

    function [23:0] bin_to_bcd;
        input [19:0] bin;
        integer       i;
        reg [43:0]    scratch;  // 20 input bits + 24 BCD bits
        begin
            scratch = {24'd0, bin};
            for (i = 0; i < 20; i = i + 1) begin
                // Add 3 to each BCD nybble ≥ 5 (before the shift)
                if (scratch[23:20] >= 5) scratch[23:20] = scratch[23:20] + 3;
                if (scratch[27:24] >= 5) scratch[27:24] = scratch[27:24] + 3;
                if (scratch[31:28] >= 5) scratch[31:28] = scratch[31:28] + 3;
                if (scratch[35:32] >= 5) scratch[35:32] = scratch[35:32] + 3;
                if (scratch[39:36] >= 5) scratch[39:36] = scratch[39:36] + 3;
                if (scratch[43:40] >= 5) scratch[43:40] = scratch[43:40] + 3;
                // Left shift entire scratch register
                scratch = scratch << 1;
            end
            bin_to_bcd = scratch[43:20];   // top 24 bits = BCD
        end
    endfunction

    wire [23:0] bcd = bin_to_bcd(bin_in);

    // Individual BCD digits (digit 0 = least significant)
    wire [3:0] d0 = bcd[ 3: 0];   // ones
    wire [3:0] d1 = bcd[ 7: 4];   // tens
    wire [3:0] d2 = bcd[11: 8];   // hundreds
    wire [3:0] d3 = bcd[15:12];   // thousands
    wire [3:0] d4 = bcd[19:16];   // ten-thousands
    wire [3:0] d5 = bcd[23:20];   // hundred-thousands

    // ============================================================
    // Stage 2: 7-segment lookup (combinational)
    // ============================================================
    // Encoding (active-low, common-anode):
    //   seg = {CA, CB, CC, CD, CE, CF, CG}
    //   0 → segment ON, 1 → segment OFF

    function [6:0] bcd_to_seg;
        input [3:0] digit;
        begin
            case (digit)
                4'd0: bcd_to_seg = 7'b000_0001;  // 0: all on except G
                4'd1: bcd_to_seg = 7'b100_1111;  // 1: B C
                4'd2: bcd_to_seg = 7'b001_0010;  // 2: A B D E G
                4'd3: bcd_to_seg = 7'b000_0110;  // 3: A B C D G
                4'd4: bcd_to_seg = 7'b100_1100;  // 4: B C F G
                4'd5: bcd_to_seg = 7'b010_0100;  // 5: A C D F G
                4'd6: bcd_to_seg = 7'b010_0000;  // 6: A C D E F G
                4'd7: bcd_to_seg = 7'b000_1111;  // 7: A B C
                4'd8: bcd_to_seg = 7'b000_0000;  // 8: all segments
                4'd9: bcd_to_seg = 7'b000_0100;  // 9: A B C D F G
                default: bcd_to_seg = 7'b111_1111; // blank
            endcase
        end
    endfunction

    // ============================================================
    // Stage 3: Time-division multiplexing
    // ============================================================
    localparam SCAN_DIV = CLK_HZ / SCAN_HZ / 6;  // counter top per digit

    reg [16:0] scan_cnt;    // baud divider
    reg [ 2:0] digit_sel;   // which of the 6 digits is active (0-5)

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            scan_cnt  <= 17'd0;
            digit_sel <= 3'd0;
        end
        else begin
            if (scan_cnt == SCAN_DIV - 1) begin
                scan_cnt  <= 17'd0;
                digit_sel <= (digit_sel == 3'd5) ? 3'd0 : digit_sel + 1'b1;
            end
            else begin
                scan_cnt <= scan_cnt + 1'b1;
            end
        end
    end

    // Mux the correct digit onto seg and enable the correct anode
    always @(*) begin
        case (digit_sel)
            3'd0: begin seg = bcd_to_seg(d0); an = 6'b111110; end
            3'd1: begin seg = bcd_to_seg(d1); an = 6'b111101; end
            3'd2: begin seg = bcd_to_seg(d2); an = 6'b111011; end
            3'd3: begin seg = bcd_to_seg(d3); an = 6'b110111; end
            3'd4: begin seg = bcd_to_seg(d4); an = 6'b101111; end
            3'd5: begin seg = bcd_to_seg(d5); an = 6'b011111; end
            default: begin seg = 7'b111_1111; an = 6'b111111; end
        endcase
    end

endmodule
