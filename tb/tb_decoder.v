`timescale 1ns / 1ps
`default_nettype none
// tb_decoder - every line of decoder_vectors.mem (tools/gen_decoder_vectors.py): genuine RV32IM
// encodings from the GNU assembler (all 45 supported instructions x 12 variants), 30 illegal
// encodings and 10,000 random words, each with the 22 expected decoder outputs computed by an
// independent Python model of the RISC-V spec. Every output field is compared.
// Prints exactly one PASS/FAIL line.

module tb_decoder;

    reg  [31:0] instr = 32'd0;
    wire [4:0]  rs1, rs2, rd;
    wire        uses_rs1, uses_rs2, writes_rd, use_imm, is_lui, is_auipc, is_jal, is_jalr;
    wire        is_branch, is_load, is_store, load_unsigned, is_md, illegal;
    wire [31:0] imm;
    wire [3:0]  alu_op;
    wire [2:0]  br_cond, md_op;
    wire [1:0]  mem_size;

    decoder dut (.instr(instr), .rs1(rs1), .rs2(rs2), .rd(rd), .uses_rs1(uses_rs1),
                 .uses_rs2(uses_rs2), .writes_rd(writes_rd), .imm(imm), .alu_op(alu_op),
                 .use_imm(use_imm), .is_lui(is_lui), .is_auipc(is_auipc), .is_jal(is_jal),
                 .is_jalr(is_jalr), .is_branch(is_branch), .br_cond(br_cond), .is_load(is_load),
                 .is_store(is_store), .mem_size(mem_size), .load_unsigned(load_unsigned),
                 .is_md(is_md), .md_op(md_op), .illegal(illegal));

    integer fd, n, words = 0, errors = 0, illegal_seen = 0;
    reg [31:0] e_instr, e_rs1, e_rs2, e_rd, e_u1, e_u2, e_wr, e_imm, e_alu, e_ui, e_lui, e_auipc,
               e_jal, e_jalr, e_br, e_brc, e_ld, e_st, e_sz, e_uns, e_md, e_mdop, e_ill;
    reg [255:0] got, want;

    initial begin
        fd = $fopen("decoder_vectors.mem", "r");
        if (fd == 0) begin
            $display("FAIL decoder: cannot open decoder_vectors.mem");
            $finish;
        end
        n = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                    e_instr, e_rs1, e_rs2, e_rd, e_u1, e_u2, e_wr, e_imm, e_alu, e_ui, e_lui, e_auipc,
                    e_jal, e_jalr, e_br, e_brc, e_ld, e_st, e_sz, e_uns, e_md, e_mdop, e_ill);
        while (n == 23) begin
            instr = e_instr;
            #1;
            got  = {rs1, rs2, rd, uses_rs1, uses_rs2, writes_rd, imm, alu_op, use_imm, is_lui,
                    is_auipc, is_jal, is_jalr, is_branch, br_cond, is_load, is_store, mem_size,
                    load_unsigned, is_md, md_op, illegal};
            want = {e_rs1[4:0], e_rs2[4:0], e_rd[4:0], e_u1[0], e_u2[0], e_wr[0], e_imm, e_alu[3:0],
                    e_ui[0], e_lui[0], e_auipc[0], e_jal[0], e_jalr[0], e_br[0], e_brc[2:0], e_ld[0],
                    e_st[0], e_sz[1:0], e_uns[0], e_md[0], e_mdop[2:0], e_ill[0]};
            if (got !== want) begin
                errors = errors + 1;
                if (errors <= 5)
                    $display("mismatch: instr %08h  got %h  want %h", e_instr, got, want);
            end
            illegal_seen = illegal_seen + e_ill;
            words = words + 1;
            n = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                        e_instr, e_rs1, e_rs2, e_rd, e_u1, e_u2, e_wr, e_imm, e_alu, e_ui, e_lui, e_auipc,
                        e_jal, e_jalr, e_br, e_brc, e_ld, e_st, e_sz, e_uns, e_md, e_mdop, e_ill);
        end
        $fclose(fd);
        if (words > 10000 && errors == 0)
            $display("PASS decoder (%0d words, %0d of them illegal, all 22 fields equal)", words, illegal_seen);
        else
            $display("FAIL decoder: %0d words, %0d mismatches", words, errors);
        $finish;
    end

endmodule

`default_nettype wire
