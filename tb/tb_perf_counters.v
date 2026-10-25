`timescale 1ns / 1ps
`default_nettype none
// tb_perf_counters - Random event pulses for both cores every cycle (D-cache
// events with a random owner) through three runs: events before RUN_START are ignored, each
// counter counts only its own core's events, RUN_STOP freezes everything while events go on,
// the next RUN_START clears. A model counts the same events; all 15 counters are compared every
// cycle through rd_sel and through snap. Prints one PASS/FAIL line.

module tb_perf_counters;

    reg         clk = 1'b0, rst = 1'b1, run_start = 0, run_stop = 0;
    reg  [1:0]  ev_instret = 0, ev_ihit = 0, ev_imiss = 0, ev_arbwait = 0, ev_barwait = 0;
    reg         ev_dhit = 0, ev_dmiss = 0, ev_downer = 0;
    reg  [3:0]  rd_sel = 0;
    wire [31:0] rd_data;
    wire [479:0] snap;
    always #10 clk = ~clk;

    perf_counters dut (.clk(clk), .rst(rst), .run_start(run_start), .run_stop(run_stop),
        .ev_instret(ev_instret), .ev_ihit(ev_ihit), .ev_imiss(ev_imiss), .ev_arbwait(ev_arbwait),
        .ev_barwait(ev_barwait), .ev_dhit(ev_dhit), .ev_dmiss(ev_dmiss), .ev_downer(ev_downer),
        .rd_sel(rd_sel), .rd_data(rd_data), .snap(snap));

    reg [31:0] m [0:15];                 // model, same indices as rd_sel
    reg        counting = 0;
    integer    errors = 0, checks = 0, seed = 86, i, cyc, phase;

    task fail(input [8*40-1:0] what, input [31:0] got, input [31:0] want);
        begin
            errors = errors + 1;
            if (errors <= 12) $display("%0s: got %0d want %0d (cycle %0d)", what, got, want, cyc);
        end
    endtask

    // the model steps at each rising edge with this cycle's inputs
    always @(posedge clk) begin
        if (rst) begin
            counting = 0;
            for (i = 0; i < 16; i = i + 1) m[i] = 0;
        end else if (run_start) begin                // restart from this cycle's events
            counting = 1;
            m[0] = 1;
            for (i = 0; i < 2; i = i + 1) begin
                m[1 + 8*i] = ev_instret[i];
                m[2 + 8*i] = (ev_dhit && ev_downer == i);
                m[3 + 8*i] = (ev_dmiss && ev_downer == i);
                m[4 + 8*i] = ev_ihit[i];
                m[5 + 8*i] = ev_imiss[i];
                m[6 + 8*i] = ev_arbwait[i];
                m[7 + 8*i] = ev_barwait[i];
            end
        end else begin
            if (counting && !run_stop) begin
                m[0] = m[0] + 1;
                for (i = 0; i < 2; i = i + 1) begin
                    m[1 + 8*i] = m[1 + 8*i] + ev_instret[i];
                    m[2 + 8*i] = m[2 + 8*i] + (ev_dhit && ev_downer == i);
                    m[3 + 8*i] = m[3 + 8*i] + (ev_dmiss && ev_downer == i);
                    m[4 + 8*i] = m[4 + 8*i] + ev_ihit[i];
                    m[5 + 8*i] = m[5 + 8*i] + ev_imiss[i];
                    m[6 + 8*i] = m[6 + 8*i] + ev_arbwait[i];
                    m[7 + 8*i] = m[7 + 8*i] + ev_barwait[i];
                end
            end
            if (run_stop) counting = 0;
        end
    end

    integer n;
    initial begin
        repeat (2) @(negedge clk); rst = 0;
        for (cyc = 0; cyc < 6000; cyc = cyc + 1) begin
            // events every cycle; runs: 1000-2500, 3000-3500, 4000-5500 (with a stop inside)
            ev_instret = $random(seed); ev_ihit = $random(seed); ev_imiss = $random(seed);
            ev_arbwait = $random(seed); ev_barwait = $random(seed);
            ev_dhit = $random(seed); ev_dmiss = !ev_dhit && ($random(seed) & 1); ev_downer = $random(seed);
            run_start = (cyc == 1000 || cyc == 3000 || cyc == 4000);
            run_stop  = (cyc == 2500 || cyc == 3500 || cyc == 5500);
            // compare every counter (the state from the previous edges)
            for (n = 0; n < 16; n = n + 1) if (n != 8) begin
                rd_sel = n; #0.1;
                checks = checks + 1;
                if (rd_data !== m[n]) fail("rd_data", rd_data, m[n]);
            end
            for (n = 0; n < 15; n = n + 1) begin
                checks = checks + 1;
                if (snap[32*n +: 32] !== m[n < 8 ? n : n + 1]) fail("snap", snap[32*n +: 32], m[n < 8 ? n : n + 1]);
            end
            rd_sel = 8; #0.1; checks = checks + 1;
            if (rd_data !== 32'd0) fail("rd_sel 8 reads 0", rd_data, 0);
            @(negedge clk);
        end
        // after the last stop: frozen, non-zero
        checks = checks + 1;
        if (m[0] != 1500) fail("CYCLES of the last run (cycles 4000-5499)", m[0], 1500);
        if (errors == 0 && checks > 150000)
            $display("PASS perf_counters (%0d checks: 3 runs, events outside runs ignored, per-core counts, freeze, clear)", checks);
        else
            $display("FAIL perf_counters: %0d errors in %0d checks", errors, checks);
        $finish;
    end

endmodule

`default_nettype wire
