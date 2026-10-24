`timescale 1ns / 1ps
`default_nettype none

// tb_icache - Unified Self-Checking Testbench
// Verifies the 128-bit memory interface, FIFO replacement, bypass mode, 
// and pipeline handshaking (fetch_accept / fetch_ready) without requiring 
// external Python scripts or hex files.

module tb_icache;

    parameter LAT = 5;       // Main memory latency in cycles

    reg         clk = 0, rst = 1, ic_en = 1;
    reg         fetch_req = 0;
    reg  [31:0] fetch_addr = 0;
    
    wire        fetch_accept, fetch_ready, fetch_stall;
    wire [31:0] instr;
    wire        mem_req, mem_ready;
    wire [31:0] mem_addr;
    wire [127:0] mem_rdata;
    wire        ic_hit, ic_miss;

    // ---------------- DUT Instantiation ----------------
    icache #(.HAS_ICACHE(1)) dut (
        .clk(clk), .rst(rst), .ic_en(ic_en),
        .fetch_req(fetch_req), .fetch_addr(fetch_addr),
        .fetch_accept(fetch_accept), .fetch_ready(fetch_ready),
        .fetch_stall(fetch_stall), .instr(instr),
        .mem_req(mem_req), .mem_addr(mem_addr),
        .mem_rdata(mem_rdata), .mem_ready(mem_ready),
        .ic_hit(ic_hit), .ic_miss(ic_miss)
    );

    always #5 clk = ~clk;

    // ---------------- Backing Memory Model (128-bit native) ----------------
    // Generates deterministic pseudo-random instructions based on address
    function [31:0] word_val(input [31:0] a);
        word_val = {a[31:2], 2'b00} * 32'h9E3779B1 + 32'h1234_5678;
    endfunction

    reg [7:0] mem_cnt = 0;
    reg       mem_ready_reg = 0;
    
    // Pack 4 words into the 128-bit line for the new icache interface
    assign mem_rdata = {word_val(mem_addr | 32'hC), word_val(mem_addr | 32'h8), 
                        word_val(mem_addr | 32'h4), word_val(mem_addr)};
    assign mem_ready = mem_ready_reg;

    integer mem_txn = 0;
    always @(posedge clk) begin
        if (rst) begin
            mem_cnt <= 0;
            mem_ready_reg <= 0;
        end else begin
            if (mem_req && !mem_ready_reg) begin
                if (mem_cnt == LAT - 1) begin
                    mem_ready_reg <= 1;
                    mem_cnt <= 0;
                    mem_txn <= mem_txn + 1;
                end else begin
                    mem_cnt <= mem_cnt + 1;
                end
            end else begin
                mem_ready_reg <= 0;
            end
        end
    end

    // ---------------- Fetch Driver (Core Pipeline Model) ----------------
    reg [31:0] seq [0:4095];
    integer    seq_len = 0, seq_idx = 0;
    reg        run_seq = 0;

    always @(*) begin
        fetch_req  = run_seq && (seq_idx < seq_len);
        fetch_addr = (seq_idx < seq_len) ? seq[seq_idx] : 32'd0;
    end

    // ---------------- Checker & Performance Counters ----------------
    reg [31:0] pend_addr;
    reg        pend_valid = 0;
    integer    n_resp = 0, n_hit = 0, n_miss = 0, n_stall_cycles = 0, errors = 0;

    always @(posedge clk) if (!rst) begin
        if (fetch_ready && pend_valid) begin
            n_resp = n_resp + 1;
            if (instr !== word_val(pend_addr)) begin
                errors = errors + 1;
                $display("[%0t] DATA ERROR addr=%h got=%h exp=%h", $time, pend_addr, instr, word_val(pend_addr));
            end
        end
        if (ic_hit)  n_hit  = n_hit  + 1;
        if (ic_miss) n_miss = n_miss + 1;
        if (fetch_stall) n_stall_cycles = n_stall_cycles + 1;
        
        if (fetch_accept && fetch_req) begin
            pend_addr  <= fetch_addr;
            pend_valid <= 1'b1;
            seq_idx    = seq_idx + 1;
        end else if (fetch_accept) begin
            pend_valid <= 1'b0;
        end
    end

    // ---------------- Reference Model (2-way FIFO) ----------------
    reg [21:0] m_tag [0:1][0:63];
    reg        m_val [0:1][0:63];
    reg        m_ptr [0:63];
    integer    m_hits, m_misses, mi;

    task model_reset;
        begin
            m_hits = 0; m_misses = 0;
            for (mi = 0; mi < 64; mi = mi + 1) begin
                m_val[0][mi] = 0; m_val[1][mi] = 0; m_ptr[mi] = 0;
            end
        end
    endtask

    task model_access(input [31:0] a);
        reg [5:0] s; reg [21:0] t; reg w;
        begin
            s = a[9:4]; t = a[31:10];
            if (m_val[0][s] && m_tag[0][s] == t) m_hits = m_hits + 1;
            else if (m_val[1][s] && m_tag[1][s] == t) m_hits = m_hits + 1;
            else begin
                m_misses = m_misses + 1;
                w = !m_val[0][s] ? 1'b0 : !m_val[1][s] ? 1'b1 : m_ptr[s];
                m_tag[w][s] = t; m_val[w][s] = 1'b1; m_ptr[s] = ~w;
            end
        end
    endtask

    // ---------------- Test Tasks ----------------
    task do_reset;
        begin
            rst = 1; run_seq = 0; repeat (3) @(posedge clk); #1; rst = 0; @(posedge clk); #1;
            n_resp = 0; n_hit = 0; n_miss = 0; n_stall_cycles = 0; seq_len = 0; seq_idx = 0;
            pend_valid = 0; mem_txn = 0; model_reset;
        end
    endtask

    task run_until_done;
        integer guard;
        begin
            run_seq = 1; guard = 0;
            while ((seq_idx < seq_len || fetch_stall || pend_valid) && guard < 100000) begin
                @(posedge clk); #1; guard = guard + 1;
            end
            repeat (4) begin @(posedge clk); #1; end
            run_seq = 0;
            if (guard >= 100000) begin errors = errors + 1; $display("TIMEOUT"); end
        end
    endtask

    task add(input [31:0] a);
        begin seq[seq_len] = a; seq_len = seq_len + 1; end
    endtask

    task expect_counts(input integer eh, input integer em, input [255:0] name);
        begin
            if (n_hit !== eh || n_miss !== em) begin
                errors = errors + 1;
                $display("FAIL %0s: hits=%0d (exp %0d) misses=%0d (exp %0d)", name, n_hit, eh, n_miss, em);
            end else $display("PASS %0s: hits=%0d misses=%0d stalls=%0d", name, n_hit, n_miss, n_stall_cycles);
        end
    endtask

    // ---------------- Execution ----------------
    integer k, seed, r;

    initial begin
        do_reset;

        // T1: Cold miss followed by 3 line hits (0 stalls for hits)
        add(32'h0000_0000); add(32'h0000_0004); add(32'h0000_0008); add(32'h0000_000C);
        run_until_done;
        expect_counts(3, 1, "T1 cold miss + line hits");
        if (mem_txn !== 1) begin errors = errors + 1; $display("FAIL T1: expected 1 memory txn, got %0d", mem_txn); end

        // T2: Sequential hits across lines
        do_reset;
        for (k = 0; k < 16; k = k + 1) add(k * 4);
        run_until_done;
        expect_counts(12, 4, "T2 sequential 4 lines");

        // T3: FIFO Eviction check (A, B, A, B, A, C -> miss under FIFO)
        do_reset;
        add(32'h000); add(32'h400); add(32'h000); add(32'h400);
        add(32'h000); add(32'h800); add(32'h000);
        run_until_done;
        expect_counts(3, 4, "T3 FIFO eviction");

        // T4: Bypass mode (ic_en = 0)
        do_reset; ic_en = 0;
        add(32'h000); add(32'h004); add(32'h000); add(32'h010);
        run_until_done;
        if (n_hit !== 0 || n_miss !== 0 || mem_txn !== 4) begin
            errors = errors + 1; $display("FAIL T4 bypass: hit=%0d miss=%0d txn=%0d", n_hit, n_miss, mem_txn);
        end else $display("PASS T4 bypass: no pulses, 4 transactions");
        ic_en = 1;

        // T5: Fuzz testing against Reference Model
        do_reset; seed = 7;
        for (k = 0; k < 3000; k = k + 1) begin
            r = $random(seed);
            add({18'd0, r[13:8] % 6'd5, 4'd0} | ({r[20:16] % 5'd4, 10'd0} << 0) | ({r[3:2], 2'b00}));
        end
        for (k = 0; k < seq_len; k = k + 1) model_access(seq[k]);
        run_until_done;
        if (n_resp !== seq_len) begin errors = errors + 1; $display("FAIL T5: %0d resp for %0d fetches", n_resp, seq_len); end
        expect_counts(m_hits, m_misses, "T5 random vs model");

        $display("----------------------------------------");
        if (errors == 0) $display("ALL TESTS PASSED (%0d fetches simulated)", seq_len + 16 + 7 + 4);
        else             $display("%0d ERRORS FOUND", errors);
        $finish;
    end

    initial begin #50_000_000; $display("GLOBAL TIMEOUT"); $finish; end
endmodule
`default_nettype wire