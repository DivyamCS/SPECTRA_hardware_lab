`timescale 1ns / 1ps
`default_nettype none
// tb_execute - Checks, against behavioural models in this file:
//  1. every ALU operation (register and immediate forms) on all pairs of 12 edge values
//     (0, 1, -1, INT_MIN, INT_MAX, 31, 32, ...) plus 5,000 random pairs; LUI, AUIPC, JAL, JALR
//     results; load/store address and store data; operand forwarding from MEM/WB;
//  2. every branch condition taken and not taken on the same pairs; JALR target bit 0 cleared;
//     valid = 0 never takes;
//  3. MUL/DIV timing, the TB acting as the pipeline (EX holds while frozen or md_busy):
//     a MUL that enters EX during a load stall starts in the cycle after the stall ends (as in
//     the timing diagram), then 3 cycles in EX; a DIV keeps md_busy for its whole run (34
//     cycles); a freeze in or after the done cycle keeps the result with no second start; a
//     freeze during the run does not delay done; back-to-back MUL/DIV; 3,000 random MUL/DIV
//     operations (edge values, /0, INT_MIN / -1) under random freezes;
//  4. HAS_MD = 0: md_busy never rises.
// Prints one PASS/FAIL line.

// verified & validated

module tb_execute;

`include "opcode.vh"

    reg         clk = 1'b0, rst = 1'b1;
    always #10 clk = ~clk;

    reg         valid = 1'b0, use_imm = 1'b0, is_lui = 1'b0, is_auipc = 1'b0, is_jal = 1'b0;
    reg         is_jalr = 1'b0, is_branch = 1'b0, is_md = 1'b0, fwd_a = 1'b0, fwd_b = 1'b0;
    reg         freeze = 1'b0;
    reg  [31:0] pc = 32'd0, rs1_val = 32'd0, rs2_val = 32'd0, imm = 32'd0, mw_result = 32'd0;
    reg  [3:0]  alu_op = 4'd0;
    reg  [2:0]  br_cond = 3'd0, md_op = 3'd0;
    wire [31:0] result, target, mem_addr, store_data, nm_result;
    wire        taken, md_busy, nm_busy;

    execute #(.HAS_MD(1)) dut (
        .clk(clk), .rst(rst), .valid(valid), .pc(pc), .rs1_val(rs1_val), .rs2_val(rs2_val),
        .imm(imm), .alu_op(alu_op), .use_imm(use_imm), .is_lui(is_lui), .is_auipc(is_auipc),
        .is_jal(is_jal), .is_jalr(is_jalr), .is_branch(is_branch), .br_cond(br_cond),
        .is_md(is_md), .md_op(md_op), .fwd_a(fwd_a), .fwd_b(fwd_b), .mw_result(mw_result),
        .freeze(freeze), .result(result), .taken(taken), .target(target), .mem_addr(mem_addr),
        .store_data(store_data), .md_busy(md_busy));

    execute #(.HAS_MD(0)) dut_nomd (
        .clk(clk), .rst(rst), .valid(valid), .pc(pc), .rs1_val(rs1_val), .rs2_val(rs2_val),
        .imm(imm), .alu_op(alu_op), .use_imm(use_imm), .is_lui(is_lui), .is_auipc(is_auipc),
        .is_jal(is_jal), .is_jalr(is_jalr), .is_branch(is_branch), .br_cond(br_cond),
        .is_md(is_md), .md_op(md_op), .fwd_a(fwd_a), .fwd_b(fwd_b), .mw_result(mw_result),
        .freeze(freeze), .result(nm_result), .taken(), .target(), .mem_addr(), .store_data(),
        .md_busy(nm_busy));

    // the unit starts, observed inside the DUT
    wire mul_start = dut.g_md.u_mul.start, div_start = dut.g_md.u_div.start;

    integer errors = 0, checks = 0, seed = 45, nm_busy_seen = 0;
    always @(posedge clk) if (nm_busy) nm_busy_seen = nm_busy_seen + 1;

    task fail(input [8*48-1:0] what, input [31:0] got, input [31:0] want);
        begin
            errors = errors + 1;
            if (errors <= 12) $display("%0s: got %08h want %08h", what, got, want);
        end
    endtask

    task check(input [8*48-1:0] what, input [31:0] got, input [31:0] want);
        begin
            checks = checks + 1;
            if (got !== want) fail(what, got, want);
        end
    endtask

    task clear;
        begin
            valid = 1'b1; use_imm = 1'b0; is_lui = 1'b0; is_auipc = 1'b0; is_jal = 1'b0;
            is_jalr = 1'b0; is_branch = 1'b0; is_md = 1'b0; fwd_a = 1'b0; fwd_b = 1'b0;
            alu_op = ALU_ADD; br_cond = 3'd0; md_op = 3'd0;
        end
    endtask

    // ---------------------------------------------------------------- models
    function [31:0] alu_model(input [3:0] op, input [31:0] x, input [31:0] y);
        case (op)
            ALU_ADD:  alu_model = x + y;
            ALU_SUB:  alu_model = x - y;
            ALU_SLL:  alu_model = x << y[4:0];
            ALU_SLT:  alu_model = ($signed(x) < $signed(y)) ? 32'd1 : 32'd0;
            ALU_SLTU: alu_model = (x < y) ? 32'd1 : 32'd0;
            ALU_XOR:  alu_model = x ^ y;
            ALU_SRL:  alu_model = x >> y[4:0];
            ALU_SRA:  begin : sra                      // sign fill written out bit by bit
                          integer i;
                          for (i = 0; i < 32; i = i + 1)
                              alu_model[i] = (i + y[4:0] > 31) ? x[31] : x[i + y[4:0]];
                      end
            ALU_OR:   alu_model = x | y;
            ALU_AND:  alu_model = x & y;
            default:  alu_model = y;                   // ALU_PASS_B
        endcase
    endfunction

    function br_model(input [2:0] c, input [31:0] x, input [31:0] y);
        case (c)
            BEQ:  br_model = (x == y);
            BNE:  br_model = (x != y);
            BLT:  br_model = ($signed(x) < $signed(y));
            BGE:  br_model = ($signed(x) >= $signed(y));
            BLTU: br_model = (x < y);
            default: br_model = (x >= y);              // BGEU
        endcase
    endfunction

    function [31:0] md_model(input [2:0] op, input [31:0] x, input [31:0] y);
        reg signed [63:0] p;
        reg signed [31:0] sx, sy, q, r;                 // signed temporaries: a ?: with an
        begin                                           // unsigned branch would make / unsigned
            sx = x; sy = y; q = 0; r = 0;
            if (y != 0 && !(x == 32'h80000000 && y == 32'hFFFFFFFF)) begin  // xsim traps on these
                q = sx / sy; r = sx % sy;
            end
            case (op)
                MUL:    md_model = x * y;
                MULH:   begin p = $signed({{32{x[31]}}, x}) * $signed({{32{y[31]}}, y}); md_model = p[63:32]; end
                MULHSU: begin p = $signed({{32{x[31]}}, x}) * $signed({32'd0, y});       md_model = p[63:32]; end
                MULHU:  begin p = {32'd0, x} * {32'd0, y};                               md_model = p[63:32]; end
                DIV:    md_model = (y == 0) ? 32'hFFFFFFFF :
                                   (x == 32'h80000000 && y == 32'hFFFFFFFF) ? 32'h80000000 :
                                   q;
                DIVU:   md_model = (y == 0) ? 32'hFFFFFFFF : x / y;
                REM:    md_model = (y == 0) ? x :
                                   (x == 32'h80000000 && y == 32'hFFFFFFFF) ? 32'd0 :
                                   r;
                default: md_model = (y == 0) ? x : x % y;   // REMU
            endcase
        end
    endfunction

    reg [31:0] edge_v [0:11];
    initial begin
        edge_v[0] = 32'h00000000; edge_v[1] = 32'h00000001; edge_v[2]  = 32'hFFFFFFFF;
        edge_v[3] = 32'h80000000; edge_v[4] = 32'h7FFFFFFF; edge_v[5]  = 32'h0000001F;
        edge_v[6] = 32'h00000020; edge_v[7] = 32'h80000001; edge_v[8]  = 32'hFFFFFFFE;
        edge_v[9] = 32'h12345678; edge_v[10] = 32'hDEADBEEF; edge_v[11] = 32'h00000002;
    end

    // ---------------------------------------------------------------- part 1 + 2: combinational
    integer i, j, k, op;
    reg [31:0] x, y;
    task comb_pair(input [31:0] xa, input [31:0] ya);
        begin
            // ALU, register form, operands from the register file
            for (op = 0; op <= 10; op = op + 1) begin
                clear; alu_op = op; rs1_val = xa; rs2_val = ya; #1;
                check("alu reg", result, alu_model(op, xa, ya));
            end
            // ALU, immediate form, operand A forwarded from MEM/WB
            for (op = 0; op <= 10; op = op + 1) begin
                clear; alu_op = op; use_imm = 1'b1; imm = ya; fwd_a = 1'b1; mw_result = xa;
                rs1_val = ~xa; rs2_val = 32'h5A5A5A5A; #1;
                check("alu imm, fwd A", result, alu_model(op, xa, ya));
            end
            // branches, with operand B forwarded every other pair
            for (op = 0; op < 8; op = op + 1) if (op != 2 && op != 3) begin
                clear; is_branch = 1'b1; br_cond = op; rs1_val = xa; pc = ya ^ 32'h00400000;
                imm = 32'hFFFFFF00; use_imm = 1'b1;          // never the immediate: rs2 only
                if (ya[0]) begin fwd_b = 1'b1; mw_result = ya; rs2_val = ~ya; end else rs2_val = ya;
                #1; checks = checks + 2;
                if (taken !== br_model(op, xa, ya)) fail("branch taken", taken, br_model(op, xa, ya));
                if (target !== pc + imm) fail("branch target", target, pc + imm);
                valid = 1'b0; #1; checks = checks + 1;
                if (taken !== 1'b0) fail("branch with valid = 0", taken, 0);
            end
            // load/store address, store data (B forwarded)
            clear; rs1_val = xa; imm = ya; fwd_b = 1'b1; mw_result = ya ^ xa; rs2_val = 32'd0; #1;
            check("mem_addr", mem_addr, xa + ya);
            check("store_data fwd B", store_data, ya ^ xa);
            // JAL, JALR (target bit 0 cleared), LUI, AUIPC
            clear; is_jal = 1'b1; pc = xa & ~32'd3; imm = ya; #1;
            check("jal result", result, (xa & ~32'd3) + 4);
            check("jal target", target, (xa & ~32'd3) + ya);
            checks = checks + 1; if (taken !== 1'b1) fail("jal taken", taken, 1);
            clear; is_jalr = 1'b1; pc = 32'h00000100; rs1_val = xa; imm = ya; #1;
            check("jalr target", target, (xa + ya) & ~32'd1);
            check("jalr result", result, 32'h00000104);
            checks = checks + 1; if (taken !== 1'b1) fail("jalr taken", taken, 1);
            clear; is_lui = 1'b1; use_imm = 1'b1; alu_op = ALU_PASS_B; imm = ya & 32'hFFFFF000; #1;
            check("lui", result, ya & 32'hFFFFF000);
            clear; is_auipc = 1'b1; pc = xa; imm = ya & 32'hFFFFF000; #1;
            check("auipc", result, xa + (ya & 32'hFFFFF000));
        end
    endtask

    task part12;
        begin
            for (i = 0; i < 12; i = i + 1)
                for (j = 0; j < 12; j = j + 1)
                    comb_pair(edge_v[i], edge_v[j]);
            for (k = 0; k < 5000; k = k + 1) begin
                x = $random(seed); y = $random(seed);
                if (k % 4 == 0) y = y & 32'h1F;                // shift amounts 0-31 often
                if (k % 7 == 0) y = x;                         // equal operands for branches
                comb_pair(x, y);
            end
            // JALR with an odd sum: bit 0 cleared
            clear; is_jalr = 1'b1; rs1_val = 32'h00001001; imm = 32'h00000000; #1;
            check("jalr odd target", target, 32'h00001000);
            clear; valid = 1'b0; #1;
        end
    endtask

    // ---------------------------------------------------------------- part 3: MUL/DIV timing
    // run_md: put a MUL/DIV in EX for "pre" frozen cycles, then hold EX as the pipeline does
    // (freeze, or md_busy). frz_at / frz_len add a freeze counted from the start cycle.
    // Returns the start cycle (relative to entry) and the cycles spent in EX.
    integer cyc, start_cyc, starts, ex_cycles, busy_cycles;
    reg     moved;
    task run_md(input [2:0] mop, input [31:0] xa, input [31:0] ya, input integer pre,
                input integer frz_at, input integer frz_len);
        begin
            @(negedge clk);
            clear; is_md = 1'b1; md_op = mop; rs1_val = xa; rs2_val = ya;
            cyc = 0; start_cyc = -1; starts = 0; busy_cycles = 0; moved = 1'b0;
            while (!moved && cyc < 200) begin
                freeze = (cyc < pre) ||
                         (start_cyc >= 0 && cyc >= start_cyc + frz_at && cyc < start_cyc + frz_at + frz_len);
                #1;
                if (mul_start || div_start) begin
                    starts = starts + 1;
                    if (start_cyc < 0) start_cyc = cyc;
                    if (freeze) fail("MUL/DIV started while frozen", cyc, -1);
                end
                if (md_busy) busy_cycles = busy_cycles + 1;
                moved = !freeze && !md_busy;               // EX advances at the next edge
                if (moved) begin
                    checks = checks + 1;
                    if (result !== md_model(mop, xa, ya)) begin
                        if (errors < 12) $display("  op %0d a %08h b %08h pre %0d frz_at %0d len %0d start %0d cyc %0d",
                                                  mop, xa, ya, pre, frz_at, frz_len, start_cyc, cyc);
                        fail("MUL/DIV result", result, md_model(mop, xa, ya));
                    end
                end
                @(negedge clk);
                cyc = cyc + 1;
            end
            ex_cycles = cyc;
            freeze = 1'b0; valid = 1'b0; is_md = 1'b0;
            checks = checks + 1;
            if (starts != 1) fail("MUL/DIV starts per instruction", starts, 1);
        end
    endtask

    integer lat, f, pre_n;
    task part3;
        begin
            // a. MUL entering EX during a 3-cycle load stall: starts in cycle 3, 3 cycles in EX
            run_md(MUL, 32'd7, 32'd6, 3, 0, 0);
            check("MUL after load stall: start cycle", start_cyc, 3);
            check("MUL after load stall: EX cycles", ex_cycles, 6);
            check("MUL after load stall: busy cycles", busy_cycles, 5);
            // no stall: starts in its first cycle
            run_md(MULH, 32'h80000000, 32'h80000000, 0, 0, 0);
            check("MUL no stall: start cycle", start_cyc, 0);
            check("MUL no stall: EX cycles", ex_cycles, 3);
            // b. DIV holds md_busy for its whole run: 34 cycles in EX, busy in 33
            run_md(DIV, 32'h80000000, 32'hFFFFFFFF, 0, 0, 0);
            check("DIV: EX cycles", ex_cycles, 34);
            check("DIV: busy cycles", busy_cycles, 33);
            run_md(REMU, 32'd100, 32'd0, 2, 0, 0);
            check("REMU /0 after stall: EX cycles", ex_cycles, 36);
            // c. freeze in the done cycle and after: result kept, no second start
            run_md(MULHU, 32'hFFFFFFFF, 32'hFFFFFFFF, 0, 2, 4);
            check("MUL frozen at done: EX cycles", ex_cycles, 7);
            check("MUL frozen at done: busy cycles", busy_cycles, 2);
            run_md(DIVU, 32'hDEADBEEF, 32'd3, 0, 33, 5);
            check("DIV frozen at done: EX cycles", ex_cycles, 39);
            // d. freeze during the run does not delay done
            run_md(REM, 32'hFFFFFF9C, 32'd7, 0, 5, 10);
            check("DIV frozen mid-run: EX cycles", ex_cycles, 34);
            run_md(MULHSU, 32'hFFFFFFFF, 32'h00000002, 0, 1, 1);
            check("MUL frozen mid-run: EX cycles", ex_cycles, 3);
            // e. back to back: each starts in its own first cycle (run_md enters at once)
            run_md(MUL, 32'd3, 32'd5, 0, 0, 0);  check("b2b MUL 1 start", start_cyc, 0);
            run_md(DIV, 32'd99, 32'd9, 0, 0, 0); check("b2b DIV start", start_cyc, 0);
            run_md(MUL, 32'd4, 32'd4, 0, 0, 0);  check("b2b MUL 2 start", start_cyc, 0);
            // f. random operations under random freezes
            for (k = 0; k < 3000; k = k + 1) begin
                x = (k % 5 == 0) ? edge_v[$unsigned($random(seed)) % 12] : $random(seed);
                y = (k % 3 == 0) ? edge_v[$unsigned($random(seed)) % 12] : $random(seed);
                op = $random(seed); pre_n = $unsigned($random(seed)) % 4;
                lat = op[2] ? 34 : 3;
                f = $unsigned($random(seed)) % (lat + 2);
                run_md(op, x, y, pre_n, f, $unsigned($random(seed)) % 4);
                checks = checks + 1;
                if (start_cyc != pre_n) fail("random: start cycle", start_cyc, pre_n);
            end
        end
    endtask

    initial begin
        part12;
        @(posedge clk); @(posedge clk); #1; rst = 1'b0;
        part3;
        // a MUL/DIV with HAS_MD = 0 never raises md_busy (it ran next to every case above)
        checks = checks + 1;
        if (nm_busy_seen != 0) fail("HAS_MD = 0 md_busy", nm_busy_seen, 0);
        if (errors == 0 && checks > 50000)
            $display("PASS execute (%0d checks: ALU, branches, JAL/JALR/LUI/AUIPC, forwarding, MUL/DIV timing, 3000 random MUL/DIV under freezes)", checks);
        else
            $display("FAIL execute: %0d errors in %0d checks", errors, checks);
        $finish;
    end

endmodule

`default_nettype wire
