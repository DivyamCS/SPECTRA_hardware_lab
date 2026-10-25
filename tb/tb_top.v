`timescale 1ns / 1ps
`default_nettype none
// tb_top - the whole SoC in simulation (soc_top), driven by
// tb/top/run.py. Files in the run directory: imem.hex, dmem.hex, cfg.mem (the switches),
// maxcyc.mem (cycle cap). The TB holds reset while the (shortened) switch debouncers settle,
// releases it, and runs until the CHECKSUM write, then until the streamer has sent everything.
// Outputs: uart_rtl.hex (every byte decoded from the UART line, one hex byte per line: binary
// files on Windows could turn 0x0A into 0x0D 0x0A), shadow_img.hex / shadow_c.hex /
// shadow_grid.hex (the streamer's shadows at the end), trace_rtl0.txt / trace_rtl1.txt (the
// cores' commit traces), dc_trace.txt with two cores (every access the shared D-cache
// completes, in the order it serves them: "owner R|W addr", and RUN_START / RUN_STOP; replayed
// by tb/top/check_counters.py). Prints "CHECKSUM <hex> cycles <n> ..." and PASS, or FAIL: watchdog (no
// instruction retired by a running core for 100,000 cycles while it is not parked at BARRIER),
// cycle cap, or decode error (LED2).

module tb_top;

    reg         clk = 1'b0, rst = 1'b1;
    always #10 clk = ~clk;
    reg  [15:0] sw = 16'h0093;
    reg  [3:0]  btn = 4'd0;
    wire [15:0] led;
    wire [7:0]  an, seg7_dp;
    wire [6:0]  seg;
    wire        dp_n, uart_tx, uart_busy;
    wire [26:0] seg7_val;
    wire [31:0] seg7_txt;

    soc_top #(.HAS_CORE1(1), .DEB_BITS(4)) dut (.clk(clk), .rst(rst), .sw(sw), .btn(btn), .led(led),
        .an(an), .seg(seg), .dp_n(dp_n), .uart_tx(uart_tx), .seg7_val(seg7_val), .seg7_dp(seg7_dp), .seg7_txt(seg7_txt),
        .uart_busy(uart_busy));

    reg  [15:0] cfg_mem [0:0];
    reg  [31:0] maxcyc_mem [0:0];
    integer     max_cycles = 10000000;
    initial begin
        cfg_mem[0] = 16'h0093; $readmemh("cfg.mem", cfg_mem); sw = cfg_mem[0];
        maxcyc_mem[0] = 32'd10000000; $readmemh("maxcyc.mem", maxcyc_mem); max_cycles = maxcyc_mem[0];
    end

    // ---- UART line decoder: start bit, 8 data bits LSB first sampled at bit centres
    integer fu, ucyc = 0, ubit = -1, nbytes = 0;
    reg [7:0] ub;
    reg       uprev = 1'b1;
    initial fu = $fopen("uart_rtl.hex", "w");
    always @(posedge clk) begin
        if (ubit < 0) begin
            if (uprev && !uart_tx) begin ubit = 0; ucyc = 0; end
        end else begin
            ucyc = ucyc + 1;
            if (ucyc == 25 + 50 * (ubit + 1) && ubit < 8) begin ub[ubit] = uart_tx; ubit = ubit + 1; end
            if (ucyc == 25 + 50 * 9) begin                     // stop bit centre
                $fwrite(fu, "%02x\n", ub); nbytes = nbytes + 1;
                if (!uart_tx) $display("FAIL top: UART stop bit low at byte %0d", nbytes);
                ubit = -1;
            end
        end
        uprev = uart_tx;
    end

    // ---- D-cache access order with two cores (the per-core hit counts depend on it)
    integer fdc = 0;
    initial begin #1 if (sw[2]) fdc = $fopen("dc_trace.txt", "w"); end
    always @(posedge clk) if (fdc != 0 && !rst) begin
        if (dut.run_start) $fwrite(fdc, "RUN_START\n");
        if (dut.run_stop)  $fwrite(fdc, "RUN_STOP\n");
        if (dut.dc_req && dut.dc_ready) $fwrite(fdc, "%0d %s %08x\n", dut.dc_owner, dut.dc_we ? "W" : "R", dut.dc_addr);
    end

    // ---- run control
    integer cycles = 0, idle0 = 0, idle1 = 0;
    reg     done = 1'b0;
    reg [31:0] checksum;
    always @(posedge clk) if (!rst) begin
        cycles = cycles + 1;
        // watchdog: a core parked at BARRIER (bar_req) waits by design and is not counted
        idle0 = (dut.ev_instret[0] || dut.bar_req[0]) ? 0 : idle0 + 1;
        idle1 = (dut.ev_instret[1] || dut.rst1 || dut.bar_req[1]) ? 0 : idle1 + 1;
        if (dut.u_mmio.st_checksum) begin done = 1'b1; checksum = dut.u_mmio.st_data; end
    end

    integer i, k, fs, fb, fo, b_wait;
    reg [1:0] b_sel;
    reg [3:0] b_btn;
    initial begin
        repeat (40) @(posedge clk);                           // debouncers (2^4) settle on sw
        #1 rst = 1'b0;
        while (!done && idle0 < 100000 && idle1 < 100000 && cycles < max_cycles && !led[2]) @(posedge clk);
        if (done) begin
            k = 0;                                            // let the streamer finish (STATS)
            while ((uart_busy || k < 10) && cycles < max_cycles + 600000) begin @(posedge clk); k = k + 1; end
            repeat (1000) @(posedge clk);
            // display browser: browser.mem lines "sw15_14 btn wait" (hex, hex, decimal):
            // set SW15:14, press the buttons in btn (bit 0 BTNL, 1 BTNR) for 50,000 cycles (1 ms), wait,
            // then log "seg7 dp leds txt" to browser.txt
            fb = $fopen("browser.mem", "r");
            if (fb != 0) begin
                fo = $fopen("browser.txt", "w");
                while (!$feof(fb)) begin
                    if ($fscanf(fb, "%h %h %d\n", b_sel, b_btn, b_wait) == 3) begin
                        sw[15:14] = b_sel;
                        btn = b_btn; repeat (50000) @(posedge clk); btn = 4'd0;   // 1 ms: longer than a browser pass
                        repeat (b_wait) @(posedge clk);
                        $fwrite(fo, "%0d %0d %0d %0d\n", seg7_val, seg7_dp, led, seg7_txt);
                    end
                end
                $fclose(fb); $fclose(fo);
            end
        end
        $fclose(fu);
        if (fdc != 0) $fclose(fdc);
        // shadows
        fs = $fopen("shadow_img.hex", "w");
        for (i = 0; i < 6912; i = i + 1) $fwrite(fs, "%08x\n", dut.u_st.imem[i]);
        $fclose(fs);
        fs = $fopen("shadow_c.hex", "w");
        for (i = 0; i < 1024; i = i + 1) $fwrite(fs, "%02x\n", dut.u_st.cmem[i]);
        $fclose(fs);
        fs = $fopen("shadow_grid.hex", "w");
        for (i = 0; i < 2048; i = i + 1)
            $fwrite(fs, "%1x\n", {dut.u_st.g_lane[3].gm[i], dut.u_st.g_lane[2].gm[i], dut.u_st.g_lane[1].gm[i], dut.u_st.g_lane[0].gm[i]});
        $fclose(fs);
        if (done && !led[2] && !uart_busy) begin
            $display("CHECKSUM %08h cycles %0d uart_bytes %0d leds %04h seg7 %0d", checksum, cycles, nbytes, led, seg7_val);
            $display("PASS top");
        end else if (led[2])         $display("FAIL top: decode error (LED2) at cycle %0d", cycles);
        else if (idle0 >= 100000 || idle1 >= 100000) $display("FAIL top: watchdog, no instruction retired for 100000 cycles (cycle %0d)", cycles);
        else if (done)               $display("FAIL top: streamer still busy after the run");
        else                         $display("FAIL top: no CHECKSUM write after %0d cycles", cycles);
        $finish;
    end

endmodule

`default_nettype wire
