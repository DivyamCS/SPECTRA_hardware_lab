`timescale 1ns / 1ps
`default_nettype none
// seg7_bcd - the 8-digit 7-segment display (spec: docs/spec/seg7_bcd.md, PROTOCOL.md section 3;
// reference model tools/seg7_model.py).
// Binary (clamped to 99,999,999) to 8 BCD digits by a sequential double-dabble, one bit per
// cycle (27 cycles), started whenever `value` differs from the last value taken; the display
// keeps the previous digits until a conversion ends. Leading zeros are blank, except digit 0 and
// every digit at or right of the highest decimal point that is on a number digit. Digits are lit one at a time
// for 2^13 cycles each (763 Hz refresh at 50 MHz). Outputs active low (Nexys A7): an, seg
// (seg[0] = CA .. seg[6] = CG) and dp_n. Blank after reset until the first conversion.
// txt (SEG7_TXT): nibble n for digit n; 0 = the number's digit, 1-15 = a letter instead, always
// lit: C y I H d n P A r - 0 1 t E blank (labels such as "IH 99.98", "CPI 2.20").

module seg7_bcd #(
    parameter SCAN_BITS = 16           // each digit lit 2^(SCAN_BITS-3) cycles; tests use fewer
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [26:0] value,
    input  wire [7:0]  dp,
    input  wire [31:0] txt,
    output reg  [7:0]  an,
    output reg  [6:0]  seg,
    output reg         dp_n
);

    // ---- conversion
    wire [26:0] clamped = (value > 27'd99999999) ? 27'd99999999 : value;
    reg  [26:0] v_r;                   // value being or last converted
    reg  [26:0] bin;
    reg  [31:0] bcd;                   // working digits
    reg  [4:0]  step;                  // bits left to shift
    reg         busy, shown;
    reg  [31:0] digits;                // digits on the display

    // add 3 to every nibble >= 5, then shift one bit in
    reg  [31:0] adj;
    integer k;
    always @(*) begin
        for (k = 0; k < 8; k = k + 1)
            adj[4*k +: 4] = (bcd[4*k +: 4] >= 4'd5) ? bcd[4*k +: 4] + 4'd3 : bcd[4*k +: 4];
    end

    always @(posedge clk) begin
        if (rst) begin
            busy   <= 1'b0;
            shown  <= 1'b0;
            digits <= 32'd0;
            bin    <= 27'd0;
            bcd    <= 32'd0;
            step   <= 5'd0;
            v_r    <= 27'h7FFFFFF;
        end else if (clamped != v_r) begin
            v_r    <= clamped;
            bin    <= clamped;
            bcd    <= 32'd0;
            step   <= 5'd27;
            busy   <= 1'b1;
        end else if (busy) begin
            bcd    <= {adj[30:0], bin[26]};
            bin    <= {bin[25:0], 1'b0};
            step   <= step - 5'd1;
            if (step == 5'd1) begin
                busy   <= 1'b0;
                shown  <= 1'b1;
                digits <= {adj[30:0], bin[26]};
            end
        end
    end

    // ---- blanking: digit i lit if i <= the highest non-zero digit, the highest dp on a number
    //      digit (a dp on a letter, e.g. after the core number "dH0.", does not count), or 0
    reg  [2:0] keep;
    integer i;
    always @(*) begin
        keep = 3'd0;
        for (i = 1; i < 8; i = i + 1)
            if (digits[4*i +: 4] != 4'd0 || (dp[i] && txt[4*i +: 4] == 4'd0))
                keep = i[2:0];
    end

    // ---- scan: advance scan counter and preview next index to pipeline registered outputs
    reg  [SCAN_BITS-1:0] scan;
    wire [SCAN_BITS-1:0] next_scan = scan + 1'b1;
    wire [2:0]           next_idx  = next_scan[SCAN_BITS-1 -: 3];
    wire [3:0]           d         = digits[4*next_idx +: 4];
    wire [3:0]           t         = txt[4*next_idx +: 4];

    reg  [6:0] pat, gl;               // active high {g..a}: digit, letter
    always @(*) begin
        case (d)
            4'd0:    pat = 7'h3F;
            4'd1:    pat = 7'h06;
            4'd2:    pat = 7'h5B;
            4'd3:    pat = 7'h4F;
            4'd4:    pat = 7'h66;
            4'd5:    pat = 7'h6D;
            4'd6:    pat = 7'h7D;
            4'd7:    pat = 7'h07;
            4'd8:    pat = 7'h7F;
            4'd9:    pat = 7'h6F;
            default: pat = 7'h00;
        endcase
        case (t)
            4'd1:    gl = 7'h39; // C
            4'd2:    gl = 7'h6E; // y
            4'd3:    gl = 7'h30; // I
            4'd4:    gl = 7'h76; // H
            4'd5:    gl = 7'h5E; // d
            4'd6:    gl = 7'h54; // n
            4'd7:    gl = 7'h73; // P
            4'd8:    gl = 7'h77; // A
            4'd9:    gl = 7'h50; // r
            4'd10:   gl = 7'h40; // -
            4'd11:   gl = 7'h3F; // 0
            4'd12:   gl = 7'h06; // 1
            4'd13:   gl = 7'h78; // t
            4'd14:   gl = 7'h79; // E
            default: gl = 7'h00; // blank
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            scan <= {SCAN_BITS{1'b0}};
            an   <= 8'hFF;
            seg  <= 7'h7F;
            dp_n <= 1'b1;
        end else begin
            scan <= next_scan;
            an   <= ~(8'd1 << next_idx);
            seg  <= (t != 4'd0) ? ~gl : (shown && next_idx <= keep) ? ~pat : 7'h7F;
            dp_n <= ~(shown && dp[next_idx]);
        end
    end

endmodule

`default_nettype wire