// ============================================================
// tb_store_streamer.v  —  Testbench for store_streamer (Task 6)
// ============================================================
`timescale 1ns / 1ps

module tb_store_streamer;

    reg clk, reset;
    initial clk = 0;
    always #5 clk = ~clk;   // 100 MHz clock

    reg        we;
    reg [31:0] waddr;
    reg [31:0] wdata;

    wire [7:0] uart_din;
    wire       uart_valid;
    reg        uart_busy;

    // Instantiate store_streamer with 4KB window at 0x0001_F000
    store_streamer #(
        .OUTPUT_BASE(32'h0001_F000),
        .OUTPUT_MASK(32'hFFFF_F000)
    ) DUT (
        .clk        (clk),
        .reset      (reset),
        .we         (we),
        .waddr      (waddr),
        .wdata      (wdata),
        .uart_din   (uart_din),
        .uart_valid (uart_valid),
        .uart_busy  (uart_busy)
    );

    integer pass_cnt = 0, fail_cnt = 0;
    task check;
        input cond;
        input [255:0] msg;
        begin
            if (cond) begin
                $display("  PASS: %s", msg);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL: %s (t=%0t)", msg, $time);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // Simulated UART receiver collecting bytes and holding busy
    reg [7:0] rx_bytes [0:17];
    integer rx_idx;
    integer busy_cnt;
    integer busy_len;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            rx_idx    <= 0;
            uart_busy <= 1'b0;
            busy_cnt  <= 0;
        end else begin
            if (uart_busy) begin
                if (busy_cnt > 1) begin
                    busy_cnt <= busy_cnt - 1;
                end else begin
                    busy_cnt  <= 0;
                    uart_busy <= 1'b0;
                end
            end else if (uart_valid) begin
                rx_bytes[rx_idx] <= uart_din;
                rx_idx   <= rx_idx + 1;
                if (busy_len > 0) begin
                    uart_busy <= 1'b1;
                    busy_cnt  <= busy_len;
                end
            end
        end
    end

    initial begin
        $dumpfile("tb_store_streamer.vcd");
        $dumpvars(0, tb_store_streamer);

        reset    = 1;
        we       = 0;
        waddr    = 0;
        wdata    = 0;
        busy_len = 0;   // 0-cycle busy for fast initial check

        repeat (4) @(posedge clk);
        reset = 0;
        @(posedge clk); #1;

        // ---- TEST 1: Store outside monitored region should NOT trigger UART ----
        $display("\n--- TEST 1: Ignore out-of-region store ---");
        we    = 1;
        waddr = 32'h0000_1000;  // Outside 0x0001_Fxxx
        wdata = 32'h1234_5678;
        @(posedge clk); #1;
        we = 0;
        repeat (10) @(posedge clk); #1;
        check(rx_idx == 0, "No bytes streamed for store outside monitored region");

        // ---- TEST 2: In-region store streams 9-byte packet ----
        $display("\n--- TEST 2: In-region store streams 9-byte packet (0-latency model) ---");
        rx_idx = 0;
        we    = 1;
        waddr = 32'h0001_F010;
        wdata = 32'hDEAD_BEEF;
        @(posedge clk); #1;
        we = 0;

        repeat (40) @(posedge clk); #1;
        check(rx_idx == 9, "All 9 bytes transmitted");
        check(rx_bytes[0] == 8'hAB, "Byte 0 is SOF (0xAB)");
        check(rx_bytes[1] == 8'h10 && rx_bytes[2] == 8'hF0 && rx_bytes[3] == 8'h01 && rx_bytes[4] == 8'h00,
              "Bytes 1-4 match little-endian address 0x0001_F010");
        check(rx_bytes[5] == 8'hEF && rx_bytes[6] == 8'hBE && rx_bytes[7] == 8'hAD && rx_bytes[8] == 8'hDE,
              "Bytes 5-8 match little-endian data 0xDEAD_BEEF");

        // ---- TEST 3: Back-pressure with realistic UART busy latency (4 cycles per byte) ----
        $display("\n--- TEST 3: UART back-pressure handling (4-cycle busy latency) ---");
        rx_idx   = 0;
        busy_len = 4;   // UART takes 4 clock cycles to transmit each byte
        @(posedge clk); #1;
        we    = 1;
        waddr = 32'h0001_F080;
        wdata = 32'hCAFE_BABE;
        @(posedge clk); #1;
        we = 0;

        // Wait for all 9 bytes through backpressure
        repeat (100) @(posedge clk); #1;
        check(rx_idx == 9, "9 bytes successfully transmitted through back-pressure");
        check(rx_bytes[0] == 8'hAB, "SOF byte verified with back-pressure");
        check(rx_bytes[1] == 8'h80 && rx_bytes[2] == 8'hF0 && rx_bytes[3] == 8'h01 && rx_bytes[4] == 8'h00,
              "Address payload verified with back-pressure");
        check(rx_bytes[5] == 8'hBE && rx_bytes[6] == 8'hBA && rx_bytes[7] == 8'hFE && rx_bytes[8] == 8'hCA,
              "Data payload verified with back-pressure");

        #20;
        $display("\n========================================");
        $display("  RESULTS: %0d PASS / %0d FAIL", pass_cnt, fail_cnt);
        $display("========================================");
        if (fail_cnt == 0) $display("  *** ALL TESTS PASSED ***");
        $finish;
    end

    initial begin #100000; $display("TIMEOUT"); $finish; end

endmodule
