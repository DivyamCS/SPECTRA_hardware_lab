`timescale 1ns / 1ps
`default_nettype none
// tb_hazard_unit - 43 (freeze, MUL/DIV hold)
// and 44 (2-instruction squash, issued only once unfrozen).
//  1. Directed table: named scenarios, expected fwd_a fwd_b interlock freeze ex_hold squash with
//     FWD = 0 and 1 (and a HAS_FWD = 0 instance, which must equal FWD = 0).
//  2. 20,000 random input vectors against the spec equations (registers drawn from x0-x3 so
//     that matches are frequent).
//  3. A small IF-ID-EX-MEM/WB pipeline model built around the DUT and the real regfile, with a
//     MUL of 1-34 cycles in EX, BEQ and JAL resolved in EX on forwarded operands, a data port
//     that waits 0-3 cycles and a fetch path that misses at random. The model obeys each DUT
//     output on its own (a squash is applied even if the DUT raised it during a freeze). A
//     directed program and 8 random programs run with FWD = 1 and 0, without and with the
//     random waits. Registers and stores must equal a sequential model; instructions retire in
//     the sequential model's order, none lost, repeated or wrong-path; cycles = N + 3 + freeze
//     + hold + interlock + 2 per taken branch; without waits, FWD = 1 stalls only for MUL
//     (latency - 1 each) and FWD = 0 costs exactly one extra cycle per distance-1 dependence.
// Prints one PASS/FAIL line.

module tb_hazard_unit;

    // ---------------------------------------------------------------- DUTs
    reg        fwd_en = 1'b1;
    reg        id_valid = 1'b0, id_uses_rs1 = 1'b0, id_uses_rs2 = 1'b0;
    reg  [4:0] id_rs1 = 5'd0, id_rs2 = 5'd0;
    reg        ex_valid = 1'b0, ex_writes_rd = 1'b0;
    reg  [4:0] ex_rs1 = 5'd0, ex_rs2 = 5'd0, ex_rd = 5'd0;
    reg        mw_valid = 1'b0, mw_writes_rd = 1'b0;
    reg  [4:0] mw_rd = 5'd0;
    reg        md_busy = 1'b0, dport_wait = 1'b0, ic_wait = 1'b0, ex_taken = 1'b0;
    reg        use_pipe = 1'b0;                      // part 3 drives the DUTs from the pipeline

    // pipeline-side copies of the hazard inputs (part 3)
    wire       p_id_valid, p_id_uses_rs1, p_id_uses_rs2, p_ex_valid, p_ex_writes_rd;
    wire       p_mw_valid, p_mw_writes_rd, p_md_busy, p_dport_wait, p_ic_wait, p_ex_taken;
    wire [4:0] p_id_rs1, p_id_rs2, p_ex_rs1, p_ex_rs2, p_ex_rd, p_mw_rd;

    wire       h_id_valid    = use_pipe ? p_id_valid     : id_valid;
    wire       h_id_uses_rs1 = use_pipe ? p_id_uses_rs1  : id_uses_rs1;
    wire       h_id_uses_rs2 = use_pipe ? p_id_uses_rs2  : id_uses_rs2;
    wire [4:0] h_id_rs1      = use_pipe ? p_id_rs1       : id_rs1;
    wire [4:0] h_id_rs2      = use_pipe ? p_id_rs2       : id_rs2;
    wire       h_ex_valid    = use_pipe ? p_ex_valid     : ex_valid;
    wire [4:0] h_ex_rs1      = use_pipe ? p_ex_rs1       : ex_rs1;
    wire [4:0] h_ex_rs2      = use_pipe ? p_ex_rs2       : ex_rs2;
    wire [4:0] h_ex_rd       = use_pipe ? p_ex_rd        : ex_rd;
    wire       h_ex_writes   = use_pipe ? p_ex_writes_rd : ex_writes_rd;
    wire       h_mw_valid    = use_pipe ? p_mw_valid     : mw_valid;
    wire [4:0] h_mw_rd       = use_pipe ? p_mw_rd        : mw_rd;
    wire       h_mw_writes   = use_pipe ? p_mw_writes_rd : mw_writes_rd;
    wire       h_md_busy     = use_pipe ? p_md_busy      : md_busy;
    wire       h_dport_wait  = use_pipe ? p_dport_wait   : dport_wait;
    wire       h_ic_wait     = use_pipe ? p_ic_wait      : ic_wait;
    wire       h_ex_taken    = use_pipe ? p_ex_taken     : ex_taken;

    wire fwd_a, fwd_b, interlock, freeze, ex_hold, squash, if_hold;             // HAS_FWD = 1
    wire nf_fwd_a, nf_fwd_b, nf_interlock, nf_freeze, nf_ex_hold, nf_squash, nf_if_hold; // HAS_FWD = 0

    hazard_unit #(.HAS_FWD(1)) dut (
        .fwd_en(fwd_en),
        .id_valid(h_id_valid), .id_rs1(h_id_rs1), .id_rs2(h_id_rs2),
        .id_uses_rs1(h_id_uses_rs1), .id_uses_rs2(h_id_uses_rs2),
        .ex_valid(h_ex_valid), .ex_rs1(h_ex_rs1), .ex_rs2(h_ex_rs2), .ex_rd(h_ex_rd),
        .ex_writes_rd(h_ex_writes),
        .mw_valid(h_mw_valid), .mw_rd(h_mw_rd), .mw_writes_rd(h_mw_writes), .ex_taken(h_ex_taken),
        .md_busy(h_md_busy), .dport_wait(h_dport_wait), .ic_wait(h_ic_wait),
        .fwd_a(fwd_a), .fwd_b(fwd_b), .interlock(interlock), .freeze(freeze), .ex_hold(ex_hold),
        .squash(squash), .if_hold(if_hold));

    hazard_unit #(.HAS_FWD(0)) dut_nofwd (
        .fwd_en(1'b1),
        .id_valid(h_id_valid), .id_rs1(h_id_rs1), .id_rs2(h_id_rs2),
        .id_uses_rs1(h_id_uses_rs1), .id_uses_rs2(h_id_uses_rs2),
        .ex_valid(h_ex_valid), .ex_rs1(h_ex_rs1), .ex_rs2(h_ex_rs2), .ex_rd(h_ex_rd),
        .ex_writes_rd(h_ex_writes),
        .mw_valid(h_mw_valid), .mw_rd(h_mw_rd), .mw_writes_rd(h_mw_writes), .ex_taken(h_ex_taken),
        .md_busy(h_md_busy), .dport_wait(h_dport_wait), .ic_wait(h_ic_wait),
        .fwd_a(nf_fwd_a), .fwd_b(nf_fwd_b), .interlock(nf_interlock), .freeze(nf_freeze),
        .ex_hold(nf_ex_hold), .squash(nf_squash), .if_hold(nf_if_hold));

    wire [5:0] got    = {fwd_a, fwd_b, interlock, freeze, ex_hold, squash};
    wire [5:0] got_nf = {nf_fwd_a, nf_fwd_b, nf_interlock, nf_freeze, nf_ex_hold, nf_squash};

    integer errors = 0, checks = 0, seed = 42, seed2 = 43;

    // ---------------------------------------------------------------- part 1: directed table
    // set(ID: valid rs1 rs2 uses1 uses2 | EX: valid rs1 rs2 rd writes | MW: valid rd writes)
    task set(input iv, input [4:0] ir1, input [4:0] ir2, input iu1, input iu2,
             input ev, input [4:0] er1, input [4:0] er2, input [4:0] erd, input ew,
             input mv, input [4:0] mrd, input mwr);
        begin
            id_valid = iv; id_rs1 = ir1; id_rs2 = ir2; id_uses_rs1 = iu1; id_uses_rs2 = iu2;
            ex_valid = ev; ex_rs1 = er1; ex_rs2 = er2; ex_rd = erd; ex_writes_rd = ew;
            mw_valid = mv; mw_rd = mrd; mw_writes_rd = mwr;
        end
    endtask

    task stall(input md, input dp, input ic);
        begin md_busy = md; dport_wait = dp; ic_wait = ic; end
    endtask

    // expected {fwd_a fwd_b interlock freeze ex_hold squash} for FWD = 1 and for FWD = 0
    task expect2(input [8*40-1:0] name, input [5:0] want1, input [5:0] want0);
        begin
            fwd_en = 1'b1; #1; checks = checks + 1;
            if (got !== want1) begin
                errors = errors + 1;
                $display("table FWD=1 %0s: got %b want %b", name, got, want1);
            end
            fwd_en = 1'b0; #1; checks = checks + 2;
            if (got !== want0) begin
                errors = errors + 1;
                $display("table FWD=0 %0s: got %b want %b", name, got, want0);
            end
            if (got_nf !== want0) begin
                errors = errors + 1;
                $display("table HAS_FWD=0 %0s: got %b want %b", name, got_nf, want0);
            end
        end
    endtask

    task part1;
        begin
            stall(0, 0, 0);
            // distance 1: producer in EX writes x5, the instruction in ID reads it
            set(1, 5, 9, 1, 1,   1, 1, 2, 5, 1,   0, 0, 0); expect2("d1 rs1",              6'b000000, 6'b001000);
            set(1, 9, 5, 1, 1,   1, 1, 2, 5, 1,   0, 0, 0); expect2("d1 rs2 / store data", 6'b000000, 6'b001000);
            set(1, 5, 5, 1, 1,   1, 1, 2, 5, 1,   0, 0, 0); expect2("d1 rs1+rs2",          6'b000000, 6'b001000);
            set(1, 9, 5, 1, 0,   1, 1, 2, 5, 1,   0, 0, 0); expect2("d1 rs2 unused (imm)", 6'b000000, 6'b000000);
            set(1, 5, 9, 0, 1,   1, 1, 2, 5, 1,   0, 0, 0); expect2("d1 rs1 unused (LUI)", 6'b000000, 6'b000000);
            set(1, 0, 0, 1, 1,   1, 1, 2, 0, 1,   0, 0, 0); expect2("d1 x0 never",         6'b000000, 6'b000000);
            set(1, 5, 9, 1, 1,   1, 1, 2, 5, 0,   0, 0, 0); expect2("d1 EX no write",      6'b000000, 6'b000000);
            set(1, 5, 9, 1, 1,   0, 1, 2, 5, 1,   0, 0, 0); expect2("d1 EX bubble",        6'b000000, 6'b000000);
            set(0, 5, 9, 1, 1,   1, 1, 2, 5, 1,   0, 0, 0); expect2("d1 ID bubble",        6'b000000, 6'b000000);
            // forwarding MEM/WB -> EX (the consumer is in EX, the producer in MEM/WB)
            set(0, 0, 0, 0, 0,   1, 5, 9, 1, 1,   1, 5, 1); expect2("fwd rs1",             6'b100000, 6'b000000);
            set(0, 0, 0, 0, 0,   1, 9, 5, 1, 1,   1, 5, 1); expect2("fwd rs2 / store",     6'b010000, 6'b000000);
            set(0, 0, 0, 0, 0,   1, 5, 5, 1, 1,   1, 5, 1); expect2("fwd both",            6'b110000, 6'b000000);
            set(0, 0, 0, 0, 0,   1, 0, 0, 1, 1,   1, 0, 1); expect2("fwd x0 never",        6'b000000, 6'b000000);
            set(0, 0, 0, 0, 0,   1, 5, 5, 1, 1,   1, 5, 0); expect2("fwd MW no write",     6'b000000, 6'b000000);
            set(0, 0, 0, 0, 0,   1, 5, 5, 1, 1,   0, 5, 1); expect2("fwd MW bubble",       6'b000000, 6'b000000);
            set(0, 0, 0, 0, 0,   0, 5, 5, 1, 1,   1, 5, 1); expect2("fwd EX bubble",       6'b000000, 6'b000000);
            set(0, 0, 0, 0, 0,   1, 6, 7, 1, 1,   1, 5, 1); expect2("fwd no match",        6'b000000, 6'b000000);
            // both at once: ID depends on EX, EX depends on MW
            set(1, 3, 0, 1, 0,   1, 5, 0, 3, 1,   1, 5, 1); expect2("chain",               6'b100000, 6'b001000);
            // stall causes on the chain (a forwarded pair plus a distance-1 dependence)
            stall(0, 1, 0); expect2("freeze: data port during fwd pair", 6'b100100, 6'b000100);
            stall(0, 0, 1); expect2("freeze: fetch path",                6'b100100, 6'b000100);
            stall(1, 0, 0); expect2("MUL/DIV busy: hold, no interlock",  6'b100010, 6'b000010);
            stall(1, 1, 0); expect2("MUL in EX while a load waits",      6'b100100, 6'b000100);
            stall(1, 0, 1); expect2("MUL busy, fetch waits",             6'b100100, 6'b000100);
            stall(1, 1, 1); expect2("all three causes",                  6'b100100, 6'b000100);
            stall(0, 1, 1); expect2("both freeze causes",                6'b100100, 6'b000100);
            set(0, 0, 0, 0, 0,   0, 0, 0, 0, 0,   0, 0, 0);
            stall(0, 1, 0); expect2("freeze, empty pipeline",            6'b000100, 6'b000100);
            stall(1, 0, 0); expect2("hold, empty pipeline",              6'b000010, 6'b000010);
            stall(0, 0, 0);
            // taken branch / JAL in EX (JAL writes x5, the instruction in ID reads x5)
            set(1, 5, 0, 1, 0,   1, 5, 0, 5, 1,   1, 5, 1); ex_taken = 1'b1;
            expect2("taken, pipeline moves",           6'b100001, 6'b000001);
            stall(0, 1, 0); expect2("taken during data-port wait",   6'b100100, 6'b000100);
            stall(0, 0, 1); expect2("taken during fetch wait",       6'b100100, 6'b000100);
            stall(1, 0, 0); expect2("taken under hold (priority)",   6'b100010, 6'b000010);
            stall(0, 0, 0); ex_taken = 1'b0;
            expect2("not taken: interlock again",      6'b100000, 6'b001000);
        end
    endtask

    // ---------------------------------------------------------------- part 2: random vectors
    function [5:0] spec_out(input fwd);
        reg mres, eres, d1, frz, hold, sq;
        begin
            mres = mw_valid && mw_writes_rd && mw_rd != 0;
            eres = ex_valid && ex_writes_rd && ex_rd != 0;
            d1   = !fwd && id_valid && eres &&
                   ((id_uses_rs1 && ex_rd == id_rs1) || (id_uses_rs2 && ex_rd == id_rs2));
            frz  = dport_wait || ic_wait;
            hold = md_busy && !frz;
            sq   = ex_taken && !frz && !hold;
            spec_out[5] = fwd && ex_valid && mres && mw_rd == ex_rs1;
            spec_out[4] = fwd && ex_valid && mres && mw_rd == ex_rs2;
            spec_out[3] = d1 && !frz && !hold && !sq;
            spec_out[2] = frz;
            spec_out[1] = hold;
            spec_out[0] = sq;
        end
    endfunction

    function raw_d1(input fwd);
        raw_d1 = !fwd && id_valid && ex_valid && ex_writes_rd && ex_rd != 0 &&
                 ((id_uses_rs1 && ex_rd == id_rs1) || (id_uses_rs2 && ex_rd == id_rs2));
    endfunction

    integer k;
    task part2;
        begin
            for (k = 0; k < 20000; k = k + 1) begin
                set($random(seed), $random(seed) & 3, $random(seed) & 3, $random(seed), $random(seed),
                    $random(seed), $random(seed) & 3, $random(seed) & 3, $random(seed) & 3, $random(seed),
                    $random(seed), $random(seed) & 3, $random(seed));
                // each stall cause on a quarter of the vectors
                stall(($random(seed) & 3) == 0, ($random(seed) & 3) == 0, ($random(seed) & 3) == 0);
                ex_taken = ($random(seed) & 3) == 0;
                fwd_en = $random(seed); #1; checks = checks + 2;
                if (got !== spec_out(fwd_en)) begin
                    errors = errors + 1;
                    if (errors <= 10) $display("random %0d FWD=%b: got %b want %b", k, fwd_en, got, spec_out(fwd_en));
                end
                if (got_nf !== spec_out(1'b0)) begin
                    errors = errors + 1;
                    if (errors <= 10) $display("random %0d HAS_FWD=0: got %b want %b", k, got_nf, spec_out(1'b0));
                end
                // if_hold = freeze | ex_hold | distance-1 dependence, whatever the branch does
                checks = checks + 2;
                if (if_hold !== (spec_out(fwd_en) & 6'b000110 ? 1'b1 : raw_d1(fwd_en))) begin
                    errors = errors + 1;
                    if (errors <= 10) $display("random %0d FWD=%b: if_hold %b", k, fwd_en, if_hold);
                end
                if (nf_if_hold !== (spec_out(1'b0) & 6'b000110 ? 1'b1 : raw_d1(1'b0))) begin
                    errors = errors + 1;
                    if (errors <= 10) $display("random %0d HAS_FWD=0: if_hold %b", k, nf_if_hold);
                end
            end
            stall(0, 0, 0); ex_taken = 1'b0;
        end
    endtask

    // ---------------------------------------------------------------- part 3: pipeline model
    localparam OP_ADD = 3'd0, OP_ADDI = 3'd1, OP_LW = 3'd2, OP_SW = 3'd3, OP_LUI = 3'd4,
               OP_MUL = 3'd5,                        // MUL: rd = rs1 * rs2, latency = imm
               OP_BEQ = 3'd6,                        // if rs1 == rs2: go to index + imm
               OP_JAL = 3'd7;                        // rd = index + 1; go to index + imm
    localparam MAXN = 2048;

    reg  [2:0]  p_op  [0:MAXN-1];
    reg  [4:0]  p_rd  [0:MAXN-1];
    reg  [4:0]  p_rs1 [0:MAXN-1];
    reg  [4:0]  p_rs2 [0:MAXN-1];
    reg  [31:0] p_imm [0:MAXN-1];
    integer     nprog = 0;

    function uses1(input [2:0] op); uses1 = (op != OP_LUI && op != OP_JAL); endfunction
    function uses2(input [2:0] op);
        uses2 = (op == OP_ADD || op == OP_SW || op == OP_MUL || op == OP_BEQ);
    endfunction
    function writes(input [2:0] op); writes = (op != OP_SW && op != OP_BEQ); endfunction

    reg clk = 1'b0, rst = 1'b1;
    always #10 clk = ~clk;
    reg waits = 1'b0;                                // random data-port and fetch waits

    // IF: next program index; ID / EX / MEM-WB pipeline registers hold a program index
    integer     pc;
    reg         idv, exv, mwv;
    integer     idi, exi, mwi;
    reg  [31:0] ex_opa, ex_opb;                      // read in ID, latched into EX
    reg  [31:0] mw_alu, mw_sdata;                    // EX results latched into MEM/WB
    integer     mw_cnt, mw_lat;                      // cycles spent in MEM/WB, data-port latency
    reg         ic_r;                                // this cycle's fetch has no instruction
    reg         md_started;                          // the MUL in EX has started
    integer     md_done;                             // cycles completed since it started
    reg  [31:0] md_a, md_b;                          // operands taken at the start

    reg  [31:0] dmem  [0:63];                        // pipeline data memory (word index)
    reg  [31:0] sdmem [0:63];                        // sequential-model data memory
    reg  [31:0] sregs [0:31];                        // sequential-model registers

    wire [2:0]  id_op = p_op[idi], ex_op = p_op[exi], mw_op = p_op[mwi];
    assign p_id_valid     = idv;
    assign p_id_rs1       = p_rs1[idi];
    assign p_id_rs2       = p_rs2[idi];
    assign p_id_uses_rs1  = (id_op != OP_LUI && id_op != OP_JAL);  // same rules as uses1/uses2
    assign p_id_uses_rs2  = (id_op == OP_ADD || id_op == OP_SW || id_op == OP_MUL || id_op == OP_BEQ);
    assign p_ex_valid     = exv;
    assign p_ex_rs1       = p_rs1[exi];
    assign p_ex_rs2       = p_rs2[exi];
    assign p_ex_rd        = p_rd[exi];
    assign p_ex_writes_rd = (ex_op != OP_SW && ex_op != OP_BEQ);
    assign p_mw_valid     = mwv;
    assign p_mw_rd        = p_rd[mwi];
    assign p_mw_writes_rd = (mw_op != OP_SW && mw_op != OP_BEQ);
    // a MUL of latency L is busy in its first L - 1 cycles after it starts (it starts in its
    // first EX cycle that is not frozen, and then runs whatever the pipeline does)
    wire   ex_mul         = exv && ex_op == OP_MUL;
    assign p_md_busy      = ex_mul && ((md_started ? md_done : 0) < p_imm[exi] - 1);
    assign p_dport_wait   = mwv && (mw_op == OP_LW || mw_op == OP_SW) && mw_cnt < mw_lat;
    assign p_ic_wait      = ic_r;

    // MEM/WB result and register write (only in the cycle the instruction leaves MEM/WB)
    wire [31:0] mw_res = (mw_op == OP_LW) ? dmem[mw_alu[5:0]] : mw_alu;
    wire        rf_we  = mwv && p_mw_writes_rd && !freeze;
    wire [31:0] rf_rd1, rf_rd2;
    regfile rf (.clk(clk), .rst(rst), .raddr1(p_rs1[idi]), .raddr2(p_rs2[idi]),
                .rdata1(rf_rd1), .rdata2(rf_rd2), .we(rf_we), .waddr(p_rd[mwi]), .wdata(mw_res));

    // EX operands with forwarding (store data = operand B)
    wire [31:0] opa = fwd_a ? mw_res : ex_opa;
    wire [31:0] opb = fwd_b ? mw_res : ex_opb;
    assign p_ex_taken = exv && (ex_op == OP_JAL || (ex_op == OP_BEQ && opa == opb));
    reg  [31:0] ex_alu;
    always @(*) begin
        case (ex_op)
            OP_ADD:  ex_alu = opa + opb;
            OP_ADDI: ex_alu = opa + p_imm[exi];
            OP_LUI:  ex_alu = p_imm[exi];
            OP_MUL:  ex_alu = md_started ? md_a * md_b : opa * opb;
            OP_JAL:  ex_alu = exi + 1;
            default: ex_alu = (opa + p_imm[exi]) & 32'h3F;          // LW / SW word index
        endcase
    end

    integer cycles, n_freeze, n_hold, n_int, n_squash, retired, order_err;
    integer strace [0:MAXN-1];                       // sequential model's executed indices
    always @(posedge clk) begin
        if (rst) begin
            pc <= 0; idv <= 1'b0; exv <= 1'b0; mwv <= 1'b0;
            idi <= 0; exi <= 0; mwi <= 0; mw_cnt <= 0; mw_lat <= 0; ic_r <= 1'b0;
            md_started <= 1'b0; md_done <= 0;
            cycles <= 0; n_freeze <= 0; n_hold <= 0; n_int <= 0; n_squash <= 0;
            retired <= 0; order_err <= 0;
        end else begin
            cycles <= cycles + 1;
            ic_r   <= waits && ($unsigned($random(seed2)) % 7 == 0);
            // the MUL in EX starts in its first unfrozen cycle, then counts every cycle
            if (ex_mul && !md_started && !freeze) begin
                md_started <= 1'b1; md_done <= 1; md_a <= opa; md_b <= opb;
            end else if (ex_mul && md_started) begin
                md_done <= md_done + 1;
            end
            if (freeze) begin
                n_freeze <= n_freeze + 1;
                mw_cnt   <= mw_cnt + 1;
            end else begin
                // MEM/WB: retire in program order (the register write happens on this edge)
                if (mwv) begin
                    if (mwi != strace[retired]) order_err <= order_err + 1;
                    retired <= retired + 1;
                    if (mw_op == OP_SW) dmem[mw_alu[5:0]] <= mw_sdata;
                end
                mw_cnt <= 0;
                mw_lat <= waits ? $unsigned($random(seed2)) % 4 : 0;
                if (ex_hold) begin
                    mwv    <= 1'b0;                  // bubble into MEM/WB; IF, ID and EX hold
                    n_hold <= n_hold + 1;
                end else begin
                    mwv <= exv; mwi <= exi; mw_alu <= ex_alu; mw_sdata <= opb;
                    if (ex_mul) md_started <= 1'b0;
                    if (interlock) begin
                        exv   <= 1'b0;               // bubble into EX; IF and ID hold
                        n_int <= n_int + 1;
                    end else begin
                        exv <= idv; exi <= idi; ex_opa <= rf_rd1; ex_opb <= rf_rd2;
                        idv <= (pc < nprog); idi <= pc;
                        if (pc < nprog) pc <= pc + 1;
                    end
                end
            end
            // squash, obeyed on its own: the instruction leaving ID and the fetch in flight
            // (the one entering ID) are dropped, IF restarts at the target
            if (squash) begin
                exv <= 1'b0; idv <= 1'b0; pc <= exi + p_imm[exi];
                n_squash <= n_squash + 1;
            end
        end
    end

    // sequential model of the same program
    integer s, a, nexec, n_taken, n_taken_all, exp_d1, exp_md;
    reg     tk, prev_tk;
    task run_model;
        begin
            for (s = 0; s < 32; s = s + 1) sregs[s] = 32'd0;
            for (s = 0; s < 64; s = s + 1) sdmem[s] = 32'h1000 + s * 32'h01010101;
            for (s = 0; s < MAXN; s = s + 1) strace[s] = -1;
            nexec = 0; n_taken = 0; n_taken_all = 0; exp_d1 = 0; exp_md = 0; prev_tk = 1'b0;
            s = 0;
            while (s < nprog) begin
                // distance-1 dependence on the previous executed instruction, unless that one
                // was a taken branch (its target enters ID only after it has left EX)
                if (nexec > 0 && !prev_tk && writes(p_op[strace[nexec-1]]) && p_rd[strace[nexec-1]] != 0 &&
                    ((uses1(p_op[s]) && p_rs1[s] == p_rd[strace[nexec-1]]) ||
                     (uses2(p_op[s]) && p_rs2[s] == p_rd[strace[nexec-1]])))
                    exp_d1 = exp_d1 + 1;
                if (p_op[s] == OP_MUL) exp_md = exp_md + p_imm[s] - 1;
                strace[nexec] = s; nexec = nexec + 1;
                a  = (sregs[p_rs1[s]] + p_imm[s]) & 32'h3F;
                tk = (p_op[s] == OP_JAL) || (p_op[s] == OP_BEQ && sregs[p_rs1[s]] == sregs[p_rs2[s]]);
                case (p_op[s])
                    OP_ADD:  if (p_rd[s] != 0) sregs[p_rd[s]] = sregs[p_rs1[s]] + sregs[p_rs2[s]];
                    OP_ADDI: if (p_rd[s] != 0) sregs[p_rd[s]] = sregs[p_rs1[s]] + p_imm[s];
                    OP_LUI:  if (p_rd[s] != 0) sregs[p_rd[s]] = p_imm[s];
                    OP_MUL:  if (p_rd[s] != 0) sregs[p_rd[s]] = sregs[p_rs1[s]] * sregs[p_rs2[s]];
                    OP_LW:   if (p_rd[s] != 0) sregs[p_rd[s]] = sdmem[a];
                    OP_SW:   sdmem[a] = sregs[p_rs2[s]];
                    OP_JAL:  if (p_rd[s] != 0) sregs[p_rd[s]] = s + 1;
                endcase
                prev_tk = tk;
                if (tk) begin
                    n_taken_all = n_taken_all + 1;
                    s = s + p_imm[s];
                    if (s < nprog) n_taken = n_taken + 1;            // 2 cycles unless it ends the run
                end else begin
                    s = s + 1;
                end
            end
        end
    endtask

    integer base_cycles, end_cycles, r, total_d1 = 0, total_freeze = 0, total_hold = 0,
            total_squash = 0;
    task run_pipe(input fwd, input w, input [8*24-1:0] name);
        begin
            fwd_en = fwd; waits = w;
            for (s = 0; s < 64; s = s + 1) dmem[s] = 32'h1000 + s * 32'h01010101;
            rst = 1'b1; @(posedge clk); @(posedge clk); #1; rst = 1'b0;
            while (retired < nexec && cycles < 100 * nprog + 100) begin @(posedge clk); #1; end
            end_cycles = cycles;
            // drain: nothing more may retire (a wrong-path instruction would)
            for (r = 0; r < 100 && (idv || exv || mwv); r = r + 1) begin @(posedge clk); #1; end
            checks = checks + 1;
            if (retired != nexec || order_err != 0) begin
                errors = errors + 1;
                $display("%0s FWD=%0d waits=%0d: retired %0d of %0d, %0d out of order", name, fwd, w,
                         retired, nexec, order_err);
            end
            for (r = 1; r < 32; r = r + 1) if (rf.regs[r] !== sregs[r]) begin
                errors = errors + 1;
                if (errors <= 10) $display("%0s FWD=%0d waits=%0d: x%0d = %08h, model %08h", name, fwd, w,
                                           r, rf.regs[r], sregs[r]);
            end
            for (r = 0; r < 64; r = r + 1) if (dmem[r] !== sdmem[r]) begin
                errors = errors + 1;
                if (errors <= 10) $display("%0s FWD=%0d waits=%0d: mem[%0d] = %08h, model %08h", name, fwd, w,
                                           r, dmem[r], sdmem[r]);
            end
            // every cycle beyond N + 3 is accounted for: one per stall cycle, two per taken branch
            if (end_cycles != nexec + 3 + n_freeze + n_hold + n_int + 2 * n_taken) begin
                errors = errors + 1;
                $display("%0s FWD=%0d waits=%0d: %0d cycles != %0d + 3 + %0d freeze + %0d hold + %0d interlock + 2 x %0d taken",
                         name, fwd, w, end_cycles, nexec, n_freeze, n_hold, n_int, n_taken);
            end
            if (n_int != (fwd ? 0 : exp_d1)) begin
                errors = errors + 1;
                $display("%0s FWD=%0d waits=%0d: %0d interlocks, want %0d", name, fwd, w, n_int, fwd ? 0 : exp_d1);
            end
            // one squash per taken branch, JAL included (the final one too)
            if (n_squash != n_taken_all) begin
                errors = errors + 1;
                $display("%0s FWD=%0d waits=%0d: %0d squashes, want %0d", name, fwd, w, n_squash,
                         n_taken_all);
            end
            if (!w && (n_freeze != 0 || n_hold != exp_md)) begin
                errors = errors + 1;
                $display("%0s FWD=%0d no waits: %0d freeze, %0d hold; want 0, %0d", name, fwd, n_freeze,
                         n_hold, exp_md);
            end
            if (!w && fwd) base_cycles = end_cycles;
            if (!w && !fwd && end_cycles != base_cycles + exp_d1) begin
                errors = errors + 1;
                $display("%0s FWD=0: %0d cycles, want %0d (FWD = 1) + %0d", name, end_cycles, base_cycles, exp_d1);
            end
            total_freeze = total_freeze + n_freeze;
            total_hold   = total_hold + n_hold;
            total_squash = total_squash + n_squash;
        end
    endtask

    task add(input [2:0] op, input [4:0] rd, input [4:0] rs1, input [4:0] rs2, input [31:0] imm);
        begin
            p_op[nprog] = op; p_rd[nprog] = rd; p_rs1[nprog] = rs1; p_rs2[nprog] = rs2;
            p_imm[nprog] = imm; nprog = nprog + 1;
        end
    endtask

    integer prog_n;
    task run_all(input [8*24-1:0] name);
        begin
            run_model;
            run_pipe(1'b1, 1'b0, name);
            run_pipe(1'b0, 1'b0, name);
            run_pipe(1'b1, 1'b1, name);
            run_pipe(1'b0, 1'b1, name);
            total_d1 = total_d1 + exp_d1;
        end
    endtask

    task part3;
        begin
            use_pipe = 1'b1;
            // directed program: every dependence kind at distance 1 and 2, MUL of 1, 3 and 34
            // cycles, taken and not-taken branches (index in the comment where it matters)
            nprog = 0;
            add(OP_LUI,  1, 0, 0, 32'h00012000);   // x1 = 0x12000
            add(OP_ADDI, 2, 1, 7, 5);              // d1 ALU -> rs1 (rs2 field 7 unused)
            add(OP_ADD,  3, 0, 2, 0);              // d1 ALU -> rs2
            add(OP_ADD,  4, 3, 3, 0);              // d1 ALU -> rs1 and rs2
            add(OP_ADDI, 5, 0, 4, 9);              // rs2 field = x4 but unused: no stall
            add(OP_ADD,  6, 4, 5, 0);              // d2 on x4 (write-through), d1 on x5
            add(OP_SW,   0, 0, 6, 3);              // d1 ALU -> store data
            add(OP_LW,   7, 0, 0, 3);              // load back the stored word
            add(OP_ADD,  8, 7, 1, 0);              // d1 load -> rs1
            add(OP_LW,   9, 0, 0, 4);
            add(OP_ADD, 10, 1, 9, 0);              // d1 load -> rs2
            add(OP_LW,  11, 0, 0, 5);
            add(OP_SW,   0, 0, 11, 6);             // d1 load -> store data
            add(OP_ADDI,12, 0, 0, 2);
            add(OP_SW,   0, 12, 1, 0);             // d1 ALU -> store address
            add(OP_LW,  13, 12, 0, 0);             // d2 on x12 (address)
            add(OP_ADDI, 0, 13, 0, 77);            // write x0: never forwarded
            add(OP_ADD, 14, 0, 0, 0);              // reads x0 right after: must be 0
            add(OP_LUI, 15, 14, 14, 32'h000AB000); // LUI with rs1/rs2 fields = x14: no stall
            add(OP_ADD, 16, 13, 15, 0);            // d2 on x13, d1 on x15
            add(OP_LW,  17, 0, 0, 7);
            add(OP_MUL, 18, 17, 16, 3);            // MUL in EX while the load waits (waits = 1)
            add(OP_ADD, 19, 18, 17, 0);            // d1 on the MUL, d2 on the load
            add(OP_MUL, 20, 19, 19, 34);           // DIV-length MUL, both operands forwarded
            add(OP_MUL, 21, 20, 2, 1);             // single-cycle MUL right behind it
            add(OP_SW,   0, 0, 21, 8);             // d1 MUL -> store data
            add(OP_MUL, 22, 21, 21, 3);            // d2 on x21
            add(OP_LW,  23, 0, 0, 8);
            add(OP_ADD, 24, 23, 22, 0);
            add(OP_ADDI,25, 0, 0, 7);              // 29
            add(OP_ADDI,26, 0, 0, 7);              // 30
            add(OP_BEQ,  0, 25, 26, 3);            // 31: taken -> 34, x26 forwarded into the compare
            add(OP_SW,   0, 0, 1, 9);              // 32: squashed: must not store
            add(OP_MUL, 27, 1, 1, 3);              // 33: squashed: must not start or write
            add(OP_LW,  28, 0, 0, 9);              // 34
            add(OP_BEQ,  0, 28, 28, 2);            // 35: taken -> 37 on the load (waits: it waits)
            add(OP_ADDI,29, 0, 0, 1);              // 36: squashed
            add(OP_JAL,  5, 0, 0, 2);              // 37: x5 = 38 -> 39
            add(OP_ADD, 30, 5, 5, 0);              // 38: squashed although it reads x5 at d1
            add(OP_ADD, 31, 5, 5, 0);              // 39: target reads x5: no interlock needed
            add(OP_BEQ,  0, 31, 0, 2);             // 40: not taken, d1 on x31
            add(OP_JAL,  6, 0, 0, 1);              // 41: taken to the next index (refetched)
            add(OP_BEQ,  0, 0, 0, 1);              // 42: taken right after a taken JAL
            add(OP_ADDI, 7, 6, 0, 0);              // 43
            add(OP_JAL,  0, 0, 0, 4);              // 44: last executed, jumps past the end
            run_all("directed");
            // random programs over x0-x5 (many dependences, x0 writes included), forward
            // branches of 1-4 instructions
            for (prog_n = 0; prog_n < 8; prog_n = prog_n + 1) begin
                nprog = 0;
                for (s = 0; s < 1000 + 100 * prog_n; s = s + 1)
                    add($random(seed), $unsigned($random(seed)) % 6,
                        $unsigned($random(seed)) % 6, $unsigned($random(seed)) % 6, $random(seed));
                for (s = 0; s < nprog; s = s + 1) begin
                    if (p_op[s] == OP_MUL) p_imm[s] = 1 + $unsigned(p_imm[s]) % 5;      // latency 1-5
                    if (p_op[s] == OP_BEQ || p_op[s] == OP_JAL) p_imm[s] = 1 + $unsigned(p_imm[s]) % 4;
                end
                run_all("random");
            end
            use_pipe = 1'b0;
        end
    endtask

    initial begin
        part1;
        part2;
        part3;
        if (errors == 0 && checks > 40000)
            $display("PASS hazard_unit (%0d checks: table x3 configs, 20000 random, 9 programs x 4 runs; %0d distance-1 interlocks, %0d freeze, %0d hold, %0d squash cycles)",
                     checks, total_d1, total_freeze, total_hold, total_squash);
        else
            $display("FAIL hazard_unit: %0d errors in %0d checks", errors, checks);
        $finish;
    end

endmodule

`default_nettype wire
