// ============================================================
// store_streamer.v  —  Snooped-Store Result Streamer (Task 6)
// ============================================================
// Watches the pipeline's write-back store bus. When a store
// falls within the configured OUTPUT_BASE region it packetises
// the address + data and sends a 9-byte packet over uart_tx.
//
// Packet format (little-endian, 9 bytes per packet):
//   Byte 0   : SOF = 0xAB
//   Bytes 1-4: store address (little-endian, byte 0 first)
//   Bytes 5-8: store data   (little-endian, byte 0 first)
//
// Handshake:
//   Pulsing uart_valid starts byte transmission. The streamer
//   waits for uart_busy to assert and then deassert before
//   transmitting the next byte. Also supports zero-latency UARTs
//   via a 2-cycle timeout fallback.
// ============================================================
`timescale 1ns / 1ps

module store_streamer #(
    parameter [31:0] OUTPUT_BASE = 32'h0001_F000,
    parameter [31:0] OUTPUT_MASK = 32'hFFFF_F000   // snoop 4KB window
)(
    input  wire        clk,
    input  wire        reset,

    // ---- Pipeline store-bus snoop ----
    input  wire        we,           // store enable (from WB)
    input  wire [31:0] waddr,        // store address
    input  wire [31:0] wdata,        // store data

    // ---- UART TX interface ----
    output reg  [ 7:0] uart_din,
    output reg         uart_valid,
    input  wire        uart_busy
);

    localparam ST_IDLE       = 2'd0;
    localparam ST_SEND       = 2'd1;
    localparam ST_WAIT_HIGH  = 2'd2;
    localparam ST_WAIT_LOW   = 2'd3;

    reg [ 1:0] state;
    reg [ 3:0] byte_idx;
    reg [ 1:0] wait_cnt;
    reg [31:0] addr_buf, data_buf;

    wire in_region = (waddr & OUTPUT_MASK) == (OUTPUT_BASE & OUTPUT_MASK);

    // Mux packet byte by index
    reg [7:0] current_byte;
    always @(*) begin
        case (byte_idx)
            4'd0: current_byte = 8'hAB;
            4'd1: current_byte = addr_buf[ 7: 0];
            4'd2: current_byte = addr_buf[15: 8];
            4'd3: current_byte = addr_buf[23:16];
            4'd4: current_byte = addr_buf[31:24];
            4'd5: current_byte = data_buf[ 7: 0];
            4'd6: current_byte = data_buf[15: 8];
            4'd7: current_byte = data_buf[23:16];
            4'd8: current_byte = data_buf[31:24];
            default: current_byte = 8'h00;
        endcase
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state      <= ST_IDLE;
            uart_valid <= 1'b0;
            uart_din   <= 8'd0;
            byte_idx   <= 4'd0;
            wait_cnt   <= 2'd0;
            addr_buf   <= 32'd0;
            data_buf   <= 32'd0;
        end
        else begin
            uart_valid <= 1'b0;

            case (state)
                ST_IDLE: begin
                    byte_idx <= 4'd0;
                    if (we && in_region && !uart_busy) begin
                        addr_buf <= waddr;
                        data_buf <= wdata;
                        state    <= ST_SEND;
                    end
                end

                ST_SEND: begin
                    uart_din   <= current_byte;
                    uart_valid <= 1'b1;
                    wait_cnt   <= 2'd2;
                    state      <= ST_WAIT_HIGH;
                end

                // Wait for UART to assert busy
                ST_WAIT_HIGH: begin
                    if (uart_busy) begin
                        state <= ST_WAIT_LOW;
                    end else if (wait_cnt > 2'd0) begin
                        wait_cnt <= wait_cnt - 1'b1;
                    end else begin
                        // Fallback: UART never raised busy (0-cycle model)
                        if (byte_idx == 4'd8) begin
                            state <= ST_IDLE;
                        end else begin
                            byte_idx <= byte_idx + 1'b1;
                            state    <= ST_SEND;
                        end
                    end
                end

                // Wait for UART to finish transmitting (busy goes low)
                ST_WAIT_LOW: begin
                    if (!uart_busy) begin
                        if (byte_idx == 4'd8) begin
                            state <= ST_IDLE;
                        end else begin
                            byte_idx <= byte_idx + 1'b1;
                            state    <= ST_SEND;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
