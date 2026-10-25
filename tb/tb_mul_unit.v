`timescale 1ns / 1ps
`default_nettype none
// tb_mul_unit - every line of mul_vectors.mem (tools/gen_vectors.py, from the RISC-V reference
// tools/mext_ref.py): "funct3 a b expected" in hex, funct3 0-3 = MUL, MULH, MULHSU, MULHU.
// Checks: result equal to the reference; done exactly 2 cycles after start (3 cycles in EX);
// back-to-back operation (next start in the done cycle); a start during cycle 1 is ignored;
// result holds through idle cycles. Prints exactly one PASS/FAIL line.

module tb_mul_unit;

    reg         clk = 1'b0, rst = 1'b1, start = 1'b0;
    reg  [1:0]  op = 2'd0;
    reg  [31:0] a = 32'd0, b = 32'd0;
    wire        busy, done;
    wire [31:0] result;

    mul_unit dut (.clk(clk), .rst(rst), .start(start), .op(op), .a(a), .b(b),
                  .busy(busy), .done(done), .result(result));

    always #10 clk = ~clk;                         // 50 MHz

    integer fd, n, vectors = 0, errors = 0, timing_errors = 0, i;
    reg [31:0] f3, va, vb, vexp;

    // drive inputs just after a rising edge, sample just before the next one
    task step; begin @(posedge clk); #1; end endtask

    initial begin
        fd = $fopen("mul_vectors.mem", "r");
        if (fd == 0) begin
            $display("FAIL mul_unit: cannot open mul_vectors.mem");
            $finish;
        end
        step; step; rst = 1'b0; step;
        n = $fscanf(fd, "%h %h %h %h\n", f3, va, vb, vexp);
        while (n == 4) begin
            // cycle 0: start
            start = 1'b1; op = f3[1:0]; a = va; b = vb;
            step;
            // cycle 1: a start here must be ignored (garbage operands every 5th vector)
            if (vectors % 5 == 0) begin start = 1'b1; a = 32'hDEADBEEF; b = 32'h12345678; op = 2'd3; end
            else start = 1'b0;
            if (done) timing_errors = timing_errors + 1;      // too early
            step;
            start = 1'b0;
            // cycle 2: done and result
            if (!done) timing_errors = timing_errors + 1;
            if (result !== vexp) begin
                errors = errors + 1;
                if (errors <= 5)
                    $display("mismatch: op %0d a %08h b %08h got %08h want %08h", f3, va, vb, result, vexp);
            end
            vectors = vectors + 1;
            // every 7th vector: idle cycles, result must hold
            if (vectors % 7 == 0) begin
                for (i = 0; i < 3; i = i + 1) begin
                    step;
                    if (result !== vexp || done) errors = errors + 1;
                end
            end
            n = $fscanf(fd, "%h %h %h %h\n", f3, va, vb, vexp);
            // the next start is applied in this same (done) cycle: back-to-back
        end
        $fclose(fd);
        if (vectors > 40000 && errors == 0 && timing_errors == 0)
            $display("PASS mul_unit (%0d vectors, every result in 3 cycles)", vectors);
        else
            $display("FAIL mul_unit: %0d vectors, %0d wrong results, %0d timing errors", vectors, errors, timing_errors);
        $finish;
    end

endmodule

`default_nettype wire
