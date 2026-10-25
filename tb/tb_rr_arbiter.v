`timescale 1ns / 1ps
`default_nettype none
// tb_rr_arbiter - Part 1 replays tb/vectors/arb_vectors.mem (tools/
// gen_arb_vectors.py from arbiter_ref.py; line "master request_cycle service grant_cycle
// ready_cycle"): each master raises req in its request cycle with a unique address and holds it
// until ready; a slave model pulses ready `service` cycles after a grant (grant cycle counted).
// Checks: the request reaches the port (m_req, m_owner, m_addr) first in grant_cycle; ready goes
// only to the owner, in ready_cycle; ev_arbwait counts = the model's waits. Part 2: both cores
// requesting back to back for 2,000 cycles alternate strictly (no starvation).
// Prints one PASS/FAIL line.

module tb_rr_arbiter;

    reg         clk = 1'b0, rst = 1'b1;
    always #10 clk = ~clk;

    reg         req0 = 0, req1 = 0;
    reg  [31:0] addr0 = 0, addr1 = 0;
    wire [31:0] rdata0, rdata1, m_addr, m_wdata;
    wire        ready0, ready1, m_req, m_we, m_owner, ev0, ev1;
    wire [3:0]  m_be;
    reg         m_ready = 0;
    reg  [31:0] m_rdata = 0;

    rr_arbiter dut (.clk(clk), .rst(rst),
        .req0(req0), .we0(1'b0), .addr0(addr0), .wdata0(32'h0), .be0(4'hF), .rdata0(rdata0), .ready0(ready0),
        .req1(req1), .we1(1'b1), .addr1(addr1), .wdata1(32'h1), .be1(4'h3), .rdata1(rdata1), .ready1(ready1),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata), .m_be(m_be), .m_owner(m_owner),
        .m_rdata(m_rdata), .m_ready(m_ready), .bar_req(), .bar_release(2'b00),
        .ev_arbwait0(ev0), .ev_arbwait1(ev1));

    localparam MAXJ = 4096;
    integer jm [0:MAXJ-1], jr [0:MAXJ-1], js [0:MAXJ-1], jg [0:MAXJ-1], jy [0:MAXJ-1];
    integer nj = 0, fd, r, a, b, c, d, e;
    integer errors = 0, checks = 0, cyc = 0;
    task fail(input [8*44-1:0] what, input integer got, input integer want);
        begin
            errors = errors + 1;
            if (errors <= 12) $display("%0s: got %0d want %0d (cycle %0d)", what, got, want, cyc);
        end
    endtask

    // per-master queue of its jobs (index into the job table), in request order
    integer q [0:1][0:MAXJ-1];
    integer qn [0:1], qh [0:1];
    integer waits [0:1], model_waits [0:1], i, cur, srv_end, granted_job;
    reg     in_service;

    initial begin
        fd = $fopen("arb_vectors.mem", "r");
        qn[0] = 0; qn[1] = 0; qh[0] = 0; qh[1] = 0;
        model_waits[0] = 0; model_waits[1] = 0; waits[0] = 0; waits[1] = 0;
        while (!$feof(fd)) begin
            r = $fscanf(fd, "%d %d %d %d %d\n", a, b, c, d, e);
            if (r == 5) begin
                jm[nj] = a; jr[nj] = b; js[nj] = c; jg[nj] = d; jy[nj] = e;
                q[a][qn[a]] = nj; qn[a] = qn[a] + 1;
                model_waits[a] = model_waits[a] + (d - b);
                nj = nj + 1;
            end
        end
        $fclose(fd);
    end

    // cycle loop: drive at the negedge of cycle `cyc`, check before the next rising edge
    integer m;
    initial begin
        in_service = 0;
        @(negedge clk); @(negedge clk); rst = 1'b0;
        cyc = 0;                          // the vectors' cycle 0 is this cycle
        while ((qh[0] < qn[0] || qh[1] < qn[1] || in_service) && cyc < 200000) begin
            // each master: raise its next request in its request cycle (one open at a time)
            for (m = 0; m < 2; m = m + 1)
                if (qh[m] < qn[m] && jr[q[m][qh[m]]] <= cyc) begin
                    if (m == 0) begin req0 = 1; addr0 = q[0][qh[0]]; end
                    else        begin req1 = 1; addr1 = q[1][qh[1]]; end
                end
            // slave: answer the job in service in its ready cycle
            m_ready = in_service && (cyc == srv_end);
            m_rdata = granted_job;
            #1;
            // a new grant shows as a request of a job not yet in service
            if (m_req && !in_service) begin
                granted_job = m_addr;
                checks = checks + 2;
                if (cyc != jg[granted_job]) fail("grant cycle", cyc, jg[granted_job]);
                if (m_owner !== jm[granted_job]) fail("owner", m_owner, jm[granted_job]);
                in_service = 1; srv_end = cyc + js[granted_job] - 1;
            end
            if (ev0) waits[0] = waits[0] + 1;
            if (ev1) waits[1] = waits[1] + 1;
            checks = checks + 2;
            if (ready0 !== (m_ready && jm[granted_job] == 0)) fail("ready0", ready0, m_ready && jm[granted_job] == 0);
            if (ready1 !== (m_ready && jm[granted_job] == 1)) fail("ready1", ready1, m_ready && jm[granted_job] == 1);
            if (m_ready) begin
                checks = checks + 1;
                if (cyc != jy[granted_job]) fail("ready cycle", cyc, jy[granted_job]);
            end
            @(negedge clk);
            if (m_ready) begin                       // the master drops req after ready
                in_service = 0;
                m = jm[granted_job];
                qh[m] = qh[m] + 1;
                if (m == 0) req0 = 0; else req1 = 0;
            end
            m_ready = 0;
            cyc = cyc + 1;
        end
        checks = checks + 2;
        if (waits[0] != model_waits[0]) fail("core 0 wait cycles", waits[0], model_waits[0]);
        if (waits[1] != model_waits[1]) fail("core 1 wait cycles", waits[1], model_waits[1]);
        // part 2: both always requesting, 2-cycle service: grants must alternate
        begin : sym
            integer k, prev, n0, n1;
            prev = -1; n0 = 0; n1 = 0;
            req0 = 1; req1 = 1; in_service = 0;
            for (k = 0; k < 2000; k = k + 1) begin
                #1;
                if (!in_service) begin
                    checks = checks + 1;
                    if (m_owner === prev) fail("same core granted twice in a row", m_owner, !prev);
                    prev = m_owner; if (m_owner) n1 = n1 + 1; else n0 = n0 + 1;
                    in_service = 1; m_ready = 0;
                end else m_ready = 1;              // 2-cycle service
                @(negedge clk);
                if (m_ready) in_service = 0;
                m_ready = 0;
            end
            checks = checks + 1;
            if (n0 - n1 > 1 || n1 - n0 > 1) fail("unfair split", n0 - n1, 0);
        end
        if (errors == 0 && nj > 1000)
            $display("PASS rr_arbiter (%0d checks: %0d requests = arbiter_ref.py, waits %0d / %0d, symmetric load alternates)",
                     checks, nj, waits[0], waits[1]);
        else
            $display("FAIL rr_arbiter: %0d errors in %0d checks", errors, checks);
        $finish;
    end

endmodule

`default_nettype wire
