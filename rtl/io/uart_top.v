`timescale 1ns / 1ps
`default_nettype none

//=============================================================================
// Module: uart_top
// Description:
//   Transmit-only UART with 1,000,000 baud 8N1 framing and a 512-byte FIFO.
//   - Frame format: 1 Start bit (0), 8 Data bits (LSB first), 1 Stop bit (1).
//   - Timing: Exactly DIV = 50 clock cycles per bit (500 cycles per frame).
//   - FIFO: 512 x 8 synchronous block RAM with prefetch pipeline so frames
//     transmit back-to-back with zero idle inter-frame gaps.
//   - Status signals:
//       * full: Active when exactly 512 bytes are queued in the RAM.
//       * busy: Active when transmitting or any bytes are buffered/pending.
//=============================================================================

module uart_top #(
    parameter integer DIV = 50
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       wr,
    input  wire [7:0] wr_data,
    output wire       full,
    output wire       busy,
    output reg        tx
);

    //=========================================================================
    // 1. Storage & State Declarations
    //=========================================================================
    (* ram_style = "block" *) reg [7:0] mem [0:511];

    reg  [8:0] wp;
    reg  [8:0] rp;
    reg  [9:0] count;                  // Buffered byte count: 0 to 512
    reg  [7:0] q;
    reg        rd_pend;                // Read issued previous cycle; q is valid
    reg        nxt_valid;
    reg  [7:0] nxt;

    reg        sending;
    reg  [9:0] shreg;                  // Shift register: {stop, data[7:0], start}
    reg  [3:0] nbit;                   // Bits remaining in active frame
    reg  [5:0] cyc;                    // Clock cycles remaining in active bit

    //=========================================================================
    // 2. Control & Handshake Decodes
    //=========================================================================
    wire bit_end   = sending && (cyc == 6'd0);
    wire frame_end = bit_end && (nbit == 4'd1);
    wire load      = nxt_valid && (!sending || frame_end);
    wire rd        = (count != 10'd0) && !rd_pend && (!nxt_valid || load);
    wire push      = wr && !full;

    assign full = (count == 10'd512);
    assign busy = sending || nxt_valid || rd_pend || (count != 10'd0);

    //=========================================================================
    // 3. FIFO Synchronous Memory Port
    //=========================================================================
    always @(posedge clk) begin
        if (push) begin
            mem[wp] <= wr_data;
        end
        if (rd) begin
            q <= mem[rp];
        end
    end

    //=========================================================================
    // 4. Sequential Pointer, Prefetch, & Transmitter Engine
    //=========================================================================
    always @(posedge clk) begin
        if (rst) begin
            wp        <= 9'd0;
            rp        <= 9'd0;
            count     <= 10'd0;
            rd_pend   <= 1'b0;
            nxt_valid <= 1'b0;
            nxt       <= 8'd0;
            sending   <= 1'b0;
            shreg     <= 10'd0;
            nbit      <= 4'd0;
            cyc       <= 6'd0;
            tx        <= 1'b1;         // Line idles high
        end else begin
            // Pointer management
            if (push) begin
                wp <= wp + 9'd1;
            end
            if (rd) begin
                rp <= rp + 9'd1;
            end

            // Occupancy counter tracking
            count <= count + (push ? 10'd1 : 10'd0) - (rd ? 10'd1 : 10'd0);
            rd_pend <= rd;

            // Prefetch staging register logic
            if (rd_pend) begin
                nxt       <= q;
                nxt_valid <= 1'b1;
            end else if (load) begin
                nxt_valid <= 1'b0;
            end

            // Serial transmission shift engine
            if (load) begin
                shreg   <= {1'b1, nxt, 1'b0};
                tx      <= 1'b0;       // Assert start bit
                nbit    <= 4'd10;
                cyc     <= DIV - 1;
                sending <= 1'b1;
            end else if (bit_end) begin
                if (nbit == 4'd1) begin
                    sending <= 1'b0;
                    tx      <= 1'b1;   // Restore line idle after stop bit
                end else begin
                    shreg   <= {1'b1, shreg[9:1]};
                    tx      <= shreg[1];
                    nbit    <= nbit - 4'd1;
                    cyc     <= DIV - 1;
                end
            end else if (sending) begin
                cyc <= cyc - 6'd1;
            end
        end
    end

endmodule

`default_nettype wire