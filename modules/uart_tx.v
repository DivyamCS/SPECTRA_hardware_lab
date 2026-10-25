// ============================================================
// uart_tx.v  —  UART Transmitter (8N1, configurable baud)
// ============================================================
// Parameters
//   CLK_HZ   – system clock frequency in Hz  (default 50 MHz)
//   BAUD     – baud rate                      (default 115200)
//
// Interface
//   din[7:0]  – parallel byte to transmit
//   valid     – strobe: assert for 1 cycle when din is ready
//   busy      – high while a byte is being serialised
//   tx        – UART serial output line
//
// Protocol: 8N1 (1 start bit, 8 data bits, 1 stop bit)
//           Idle line = 1 (MARK).
//
// MMIO integration
//   Connect directly to the MMIO address decoder:
//     write 0x8000_0000 → {din, valid}  (byte write)
//     read  0x8000_0004 → {31'd0, busy}
// ============================================================
`timescale 1ns / 1ps

module uart_tx #(
    parameter CLK_HZ = 50_000_000,
    parameter BAUD   = 115_200
)(
    input  wire       clk,
    input  wire       reset,

    input  wire [7:0] din,     // byte to send
    input  wire       valid,   // pulse high 1 cycle to start TX
    output reg        busy,    // high while transmitting
    output reg        tx       // serial output
);

    // ---- Baud-rate divider ----
    localparam integer CLKS_PER_BIT = CLK_HZ / BAUD;   // e.g. 434 @ 50 MHz/115200

    // ---- State machine ----
    localparam ST_IDLE  = 2'd0;
    localparam ST_START = 2'd1;
    localparam ST_DATA  = 2'd2;
    localparam ST_STOP  = 2'd3;

    reg [1:0]  state;
    reg [15:0] baud_cnt;   // baud period counter
    reg [3:0]  bit_idx;    // which data bit are we sending (0-7)
    reg [7:0]  shift;      // shift register

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state    <= ST_IDLE;
            baud_cnt <= 16'd0;
            bit_idx  <= 4'd0;
            shift    <= 8'd0;
            busy     <= 1'b0;
            tx       <= 1'b1;   // idle = MARK
        end
        else begin
            case (state)

                // ---- IDLE: wait for a byte to send ----
                ST_IDLE: begin
                    tx   <= 1'b1;
                    busy <= 1'b0;
                    if (valid) begin
                        shift    <= din;
                        baud_cnt <= 16'd0;
                        busy     <= 1'b1;
                        state    <= ST_START;
                    end
                end

                // ---- START BIT (logic 0 for one baud period) ----
                ST_START: begin
                    tx <= 1'b0;
                    if (baud_cnt == CLKS_PER_BIT - 1) begin
                        baud_cnt <= 16'd0;
                        bit_idx  <= 4'd0;
                        state    <= ST_DATA;
                    end
                    else begin
                        baud_cnt <= baud_cnt + 1'b1;
                    end
                end

                // ---- DATA BITS: LSB first ----
                ST_DATA: begin
                    tx <= shift[0];
                    if (baud_cnt == CLKS_PER_BIT - 1) begin
                        baud_cnt <= 16'd0;
                        shift    <= {1'b0, shift[7:1]};   // logical right shift
                        if (bit_idx == 4'd7) begin
                            state <= ST_STOP;
                        end
                        else begin
                            bit_idx <= bit_idx + 1'b1;
                        end
                    end
                    else begin
                        baud_cnt <= baud_cnt + 1'b1;
                    end
                end

                // ---- STOP BIT (logic 1 for one baud period) ----
                ST_STOP: begin
                    tx <= 1'b1;
                    if (baud_cnt == CLKS_PER_BIT - 1) begin
                        baud_cnt <= 16'd0;
                        busy     <= 1'b0;
                        state    <= ST_IDLE;
                    end
                    else begin
                        baud_cnt <= baud_cnt + 1'b1;
                    end
                end

                default: state <= ST_IDLE;

            endcase
        end
    end

endmodule
