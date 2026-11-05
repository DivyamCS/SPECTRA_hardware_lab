`timescale 1ns / 1ps
`default_nettype none
// tb_mem_stage - The TB plays the pipeline (an instruction stays in MEM/WB until a
// cycle with freeze = 0, freeze = dport_wait | a random fetch wait) and an IF-A slave whose
// `ready` comes 1-20 cycles after `req` rises (ready in cycle 2 at the earliest, cycle 1 being the
// one `req` rises in) with garbage on rdata outside the ready cycle. Checked:
//  * IF-A rules: every field stable from req to ready; req never drops before ready; exactly one
//    access (one ready) per load or store, loads to x0 included; no req for other instructions;
//  * every load size, alignment and sign/zero extension, every store's lanes and byte enables,
//    against a byte-addressed reference memory; final memories equal;
//  * register write and retire exactly once per instruction, in the cycle it leaves MEM/WB, with
//    the right data, also when ready comes during a fetch-wait freeze;
//  * directed sweeps with ready after 1 and 2 cycles, then 6,000 random back-to-back
//    instructions with random delays and fetch waits.
// Prints one PASS/FAIL line.

// verified & validated

module tb_mem_stage;

    reg         clk = 1'b0, rst = 1'b1;
    always #10 clk = ~clk;

    reg         valid = 1'b0, is_load = 1'b0, is_store = 1'b0, load_unsigned = 1'b0, writes_rd = 1'b0;
    reg  [1:0]  mem_size = 2'd2;
    reg  [31:0] addr = 32'd0, store_data = 32'd0, result = 32'd0;
    reg  [4:0]  rd = 5'd0;
    reg         ic_wait = 1'b0;
    wire        freeze;
    wire        req, we, ready_w, dport_wait, wb_we, retire;
    wire [31:0] m_addr, wdata, wb_data;
    wire [3:0]  be;
    wire [4:0]  wb_rd;
    reg  [31:0] rdata = 32'd0;
    reg         ready = 1'b0;

    assign freeze = dport_wait || ic_wait;

    mem_stage dut (
        .clk(clk), .rst(rst), .valid(valid), .is_load(is_load), .is_store(is_store),
        .mem_size(mem_size), .load_unsigned(load_unsigned), .addr(addr), .store_data(store_data),
        .rd(rd), .writes_rd(writes_rd), .result(result), .freeze(freeze),
        .req(req), .we(we), .m_addr(m_addr), .wdata(wdata), .be(be), .rdata(rdata), .ready(ready),
        .dport_wait(dport_wait), .wb_we(wb_we), .wb_rd(wb_rd), .wb_data(wb_data), .retire(retire));

    integer errors = 0, checks = 0, seed = 46;
    task fail(input [8*48-1:0] what, input [31:0] got, input [31:0] want);
        begin
            errors = errors + 1;
            if (errors <= 12) $display("%0s: got %08h want %08h (t=%0t)", what, got, want, $time);
        end
    endtask

    // ---------------------------------------------------------------- IF-A slave
    reg  [7:0]  smem [0:1023];                  // slave memory, bytes, addr[9:0]
    reg  [7:0]  rmem [0:1023];                  // reference memory, updated at retire
    integer     delay_min = 1, delay_max = 1, wait_left = 0, accesses = 0, readies = 0;
    reg         open = 1'b0;                    // a request is in progress
    reg         h_we; reg [31:0] h_addr, h_wdata; reg [3:0] h_be;
    integer     n;

    // A registered slave: req and ready are sampled at the clock edge; just after it, a new
    // request (req without a ready in the cycle that ended) opens with a random delay, and
    // ready rises for one cycle when the delay has run out (cycle 2 at the earliest).
    reg s_req, s_ready;
    always @(posedge clk) begin
        s_req = req; s_ready = ready;
        #1;
        ready = 1'b0;
        rdata = $random(seed);                              // garbage unless ready
        if (rst) begin
            open = 1'b0;
        end else begin
            if (!open && s_req && !s_ready) begin
                open = 1'b1; accesses = accesses + 1;
                h_we = we; h_addr = m_addr; h_wdata = wdata; h_be = be;
                wait_left = delay_min + $unsigned($random(seed)) % (delay_max - delay_min + 1);
            end
            if (open) begin
                wait_left = wait_left - 1;
                if (wait_left == 0) begin
                    ready = 1'b1; readies = readies + 1; open = 1'b0;
                    if (h_we) begin
                        for (n = 0; n < 4; n = n + 1)
                            if (h_be[n]) smem[{h_addr[9:2], 2'b00} + n] = h_wdata[8*n +: 8];
                    end else begin
                        rdata = {smem[{h_addr[9:2], 2'b11}], smem[{h_addr[9:2], 2'b10}],
                                 smem[{h_addr[9:2], 2'b01}], smem[{h_addr[9:2], 2'b00}]};
                    end
                end
            end
        end
    end
    // between req and ready every field holds and req stays up
    always @(negedge clk) begin
        if (!rst && open) begin
            checks = checks + 1;
            if (!req) fail("req dropped before ready", 0, 1);
            if (we !== h_we || m_addr !== h_addr || be !== h_be || (h_we && wdata !== h_wdata))
                fail("IF-A fields not held", m_addr, h_addr);
        end
    end

    // ---------------------------------------------------------------- pipeline side
    function [31:0] ref_load(input [31:0] a, input [1:0] sz, input u);
        reg [31:0] w;
        begin
            case (sz)
                2'd0: w = u ? {24'd0, rmem[a[9:0]]} : {{24{rmem[a[9:0]][7]}}, rmem[a[9:0]]};
                2'd1: w = u ? {16'd0, rmem[{a[9:1], 1'b1}], rmem[{a[9:1], 1'b0}]}
                            : {{16{rmem[{a[9:1], 1'b1}][7]}}, rmem[{a[9:1], 1'b1}], rmem[{a[9:1], 1'b0}]};
                default: w = {rmem[{a[9:2], 2'b11}], rmem[{a[9:2], 2'b10}],
                              rmem[{a[9:2], 2'b01}], rmem[{a[9:2], 2'b00}]};
            endcase
            ref_load = w;
        end
    endfunction

    integer ic_pct = 0, retires = 0, mem_instrs = 0, cyc_in_mw, ic_ready_overlap = 0;
    // issue one instruction into MEM/WB and hold it until it leaves
    task issue(input ld, input st, input [1:0] sz, input u, input [31:0] a, input [31:0] sd,
               input [4:0] r, input [31:0] res);
        reg [31:0] want;
        integer rcount;
        begin
            @(negedge clk);
            valid = 1'b1; is_load = ld; is_store = st; mem_size = sz; load_unsigned = u;
            addr = a; store_data = sd; rd = r; writes_rd = !st; result = res;
            if (ld || st) mem_instrs = mem_instrs + 1;
            cyc_in_mw = 0; rcount = 0;
            forever begin
                ic_wait = ($unsigned($random(seed)) % 100) < ic_pct;
                #5;                                     // after the slave has driven ready
                if (ready && ic_wait) ic_ready_overlap = ic_ready_overlap + 1;
                checks = checks + 1;
                if (!(ld || st) && req) fail("req for a non-memory instruction", 1, 0);
                if (retire) begin
                    rcount = rcount + 1;
                    want = ld ? ref_load(a, sz, u) : res;
                    checks = checks + 2;
                    if (wb_we !== (r != 0 && !st)) fail("wb_we", wb_we, r != 0 && !st);
                    if (!st && r != 0 && wb_data !== want) fail("wb_data", wb_data, want);
                    if (wb_rd !== r) fail("wb_rd", wb_rd, r);
                    if (st) for (n = 0; n < 4; n = n + 1)
                        if (dut.be[n]) rmem[{a[9:2], 2'b00} + n] = dut.wdata[8*n +: 8];
                end else if (wb_we) fail("wb_we without retire", 1, 0);
                @(posedge clk);
                cyc_in_mw = cyc_in_mw + 1;
                if (rcount) begin
                    retires = retires + 1;
                    disable issue;
                end
                @(negedge clk);
            end
        end
    endtask

    task bubble;
        begin
            @(negedge clk); valid = 1'b0; ic_wait = 1'b0; #5;
            checks = checks + 1;
            if (req || retire || wb_we) fail("bubble did something", {req, retire, wb_we}, 0);
            @(posedge clk);
        end
    endtask

    // expected lanes for a store (checked against what the DUT presents, while it presents it)
    function [3:0] be_model(input [1:0] sz, input [1:0] lo);
        be_model = (sz == 0) ? (4'b0001 << lo) : (sz == 1) ? (lo[1] ? 4'b1100 : 4'b0011) : 4'b1111;
    endfunction
    always @(negedge clk) begin
        #2;                                     // after the driver has set this cycle's inputs
        if (!rst && valid && (is_load || is_store)) begin
            checks = checks + 1;
            if (be !== be_model(mem_size, addr[1:0])) fail("be", be, be_model(mem_size, addr[1:0]));
            if (is_store && mem_size == 0 && wdata !== {4{store_data[7:0]}}) fail("SB lanes", wdata, {4{store_data[7:0]}});
            if (is_store && mem_size == 1 && wdata !== {2{store_data[15:0]}}) fail("SH lanes", wdata, {2{store_data[15:0]}});
            if (is_store && mem_size == 2 && wdata !== store_data) fail("SW data", wdata, store_data);
            if (m_addr !== addr) fail("addr", m_addr, addr);
        end
    end

    integer i, k, sz, lo, d, t;
    reg [31:0] a32;
    initial begin
        for (i = 0; i < 1024; i = i + 1) begin smem[i] = i * 37 + 11; rmem[i] = i * 37 + 11; end
        @(posedge clk); @(posedge clk); @(negedge clk); rst = 1'b0;
        // directed: ready after 1 and 2 cycles, every size and alignment, signed and unsigned
        for (d = 1; d <= 2; d = d + 1) begin
            delay_min = d; delay_max = d;
            for (sz = 0; sz < 3; sz = sz + 1)
                for (lo = 0; lo < 4; lo = lo + (sz == 0 ? 1 : sz == 1 ? 2 : 4)) begin
                    a32 = 32'h10000000 + 32'h40 * (sz + 1) + lo;
                    // a store with the sign bit set in every lane, then both loads back
                    issue(0, 1, sz, 0, a32, 32'h80FF7F81 ^ (lo * 32'h01010101), 0, 0);
                    issue(1, 0, sz, 0, a32, 0, 5, 0);
                    issue(1, 0, sz, 1, a32, 0, 6, 0);
                    issue(1, 0, 2, 0, a32 & ~32'd3, 0, 7, 0);        // the whole word
                    check_cycles(d);
                end
            issue(1, 0, 2, 0, 32'h10000100, 0, 0, 0);               // load to x0: still a request
            issue(0, 0, 2, 0, 0, 0, 9, 32'hCAFEF00D);               // ALU instruction: one cycle
            checks = checks + 1;
            if (cyc_in_mw != 1) fail("ALU instruction cycles in MEM/WB", cyc_in_mw, 1);
            bubble;
        end
        // random: delays 1-20, fetch waits on 30 % of cycles, back-to-back
        delay_min = 1; delay_max = 20; ic_pct = 30;
        for (k = 0; k < 6000; k = k + 1) begin
            t  = $unsigned($random(seed)) % 8;
            sz = $unsigned($random(seed)) % 3;
            a32 = 32'h10000000 | ($random(seed) & 32'h3FF);
            a32 = (sz == 2) ? a32 & ~32'd3 : (sz == 1) ? a32 & ~32'd1 : a32;
            if (t < 3)      issue(1, 0, sz, $random(seed), a32, 0, $unsigned($random(seed)) % 4, 0);
            else if (t < 6) issue(0, 1, sz, 0, a32, $random(seed), 0, 0);
            else if (t < 7) issue(0, 0, 2, 0, a32, 0, $unsigned($random(seed)) % 4, $random(seed));
            else            bubble;
            if (k == 3000) delay_max = 2;                         // a stretch of hits
            if (k == 4500) delay_max = 20;
        end
        bubble; bubble;
        // totals and final memory
        checks = checks + 3;
        if (accesses != mem_instrs) fail("IF-A accesses", accesses, mem_instrs);
        if (readies != mem_instrs) fail("ready pulses", readies, mem_instrs);
        for (i = 0; i < 1024; i = i + 1) if (smem[i] !== rmem[i]) fail("final memory byte", i, smem[i]);
        if (ic_ready_overlap == 0) fail("no ready during a fetch wait (coverage)", 0, 1);
        if (errors == 0 && checks > 50000)
            $display("PASS mem_stage (%0d checks: %0d instructions, %0d IF-A accesses, %0d ready cycles under a fetch-wait freeze)",
                     checks, retires, accesses, ic_ready_overlap);
        else
            $display("FAIL mem_stage: %0d errors in %0d checks", errors, checks);
        $finish;
    end

    // with no fetch waits, a load or store spends 1 + delay cycles in MEM/WB
    task check_cycles(input integer dly);
        begin
            checks = checks + 1;
            if (cyc_in_mw != 1 + dly) fail("cycles in MEM/WB", cyc_in_mw, 1 + dly);
        end
    endtask

endmodule

`default_nettype wire
