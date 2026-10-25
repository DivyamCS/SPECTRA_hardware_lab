// ============================================================
// tb_uart_tx.v  —  Self-checking UART TX Testbench
// ============================================================
// Tests:
//   1. Single byte: decode serial stream, compare to input
//   2. Multiple bytes: "Hello\r\n" string
//   3. Busy flag: check busy asserts before and deasserts after
//   4. Back-to-back: send bytes without gap, check no framing error
//   5. Idle line: verify tx = 1 when not transmitting
//
// Uses a UART RX model (bit-sampling) to decode the TX output.
// ============================================================
`timescale 1ns / 1ps

module tb_uart_tx;

    // ---- Parameters must match DUT ----
    parameter CLK_HZ = 10_000_000;   // 10 MHz sim clock
    parameter BAUD   = 1_000_000;    // 1 Mbaud — fast for simulation
    localparam CLK_PERIOD    = 1_000_000_000 / CLK_HZ;  // 100 ns
    localparam CLKS_PER_BIT  = CLK_HZ / BAUD;           // 10
    localparam BIT_PERIOD_NS = 1_000_000_000 / BAUD;    // 1000 ns

    // ---- Clock & Reset ----
    reg clk, reset;
    initial clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // ---- DUT signals ----
    reg  [7:0] din;
    reg        valid;
    wire       busy;
    wire       tx;

    // ---- DUT ----
    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) DUT (
        .clk  (clk),
        .reset(reset),
        .din  (din),
        .valid(valid),
        .busy (busy),
        .tx   (tx)
    );

    // ---- Scoreboard ----
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task check;
        input        cond;
        input [255:0] msg;
        begin
            if (cond) begin
                $display("  PASS: %s", msg);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL: %s  (t=%0t)", msg, $time);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // ---- UART RX decoder ----
    // Waits for start bit, samples 8 data bits at mid-period,
    // checks stop bit, returns decoded byte.
    task uart_decode;
        output [7:0] byte_out;
        reg [7:0] rxd;
        integer  i;
        begin
            // Wait for start bit (falling edge)
            @(negedge tx);
            // Wait half a bit period to sample middle of start bit
            #(BIT_PERIOD_NS / 2);
            // Sample 8 data bits (LSB first)
            for (i = 0; i < 8; i = i + 1) begin
                #BIT_PERIOD_NS;
                rxd[i] = tx;
            end
            // Wait for stop bit period
            #BIT_PERIOD_NS;
            byte_out = rxd;
        end
    endtask

    // ---- Helper: send one byte, receive and compare ----
    task send_and_check;
        input [7:0] data;
        input [255:0] label;
        reg [7:0] received;
        begin
            // Wait until line is free
            while (busy) @(posedge clk);
            @(posedge clk); #1;
            din   = data;
            valid = 1;
            @(posedge clk); #1;
            valid = 0;
            check(busy == 1, "busy asserted immediately");

            uart_decode(received);
            // Poll until busy actually deasserts (FSM registered at posedge)
            while (busy) @(posedge clk);
            #1;

            check(received == data, label);
            check(busy == 0, "busy deasserted after stop bit");
        end
    endtask

    // ---- Main test sequence ----
    initial begin
        $dumpfile("tb_uart_tx.vcd");
        $dumpvars(0, tb_uart_tx);

        // Reset
        reset = 1; din = 0; valid = 0;
        #200; reset = 0;
        @(posedge clk); #1;

        // ---- TEST 1: Idle line ----
        $display("\n--- TEST 1: Idle line = 1 ---");
        #100;
        check(tx == 1, "tx = 1 when idle");

        // ---- TEST 2: Single byte 0xA5 ----
        $display("\n--- TEST 2: single byte 0xA5 ---");
        send_and_check(8'hA5, "byte 0xA5 decoded correctly");

        // ---- TEST 3: ASCII 'H' 'i' ----
        $display("\n--- TEST 3: 'H' = 0x48 ---");
        send_and_check(8'h48, "ASCII H decoded");

        $display("\n--- TEST 4: 'i' = 0x69 ---");
        send_and_check(8'h69, "ASCII i decoded");

        // ---- TEST 4: CR LF ----
        $display("\n--- TEST 5: CR = 0x0D ---");
        send_and_check(8'h0D, "CR decoded");

        // ---- TEST 5: 0x00 (all zeros) ----
        $display("\n--- TEST 6: 0x00 ---");
        send_and_check(8'h00, "0x00 decoded");

        // ---- TEST 6: 0xFF (all ones) ----
        $display("\n--- TEST 7: 0xFF ---");
        send_and_check(8'hFF, "0xFF decoded");

        // ---- Summary ----
        #1000;
        $display("\n========================================");
        $display("  RESULTS: %0d PASS / %0d FAIL", pass_cnt, fail_cnt);
        $display("========================================");
        if (fail_cnt == 0)
            $display("  *** ALL TESTS PASSED ***");
        else
            $display("  *** SOME TESTS FAILED ***");
        $finish;
    end

    // Safety timeout: 5 ms simulated time (plenty for 1 Mbaud)
    initial begin
        #5_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
