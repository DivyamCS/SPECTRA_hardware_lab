`timescale 1ns / 1ps
`default_nettype none
// tb_div_unit - every line of div_vectors.mem (tools/gen_vectors.py, from tools/mext_ref.py):
// "funct3 a b expected" in hex, funct3 4-7 = DIV, DIVU, REM, REMU (op = funct3[1:0]); includes
// division by zero and INT_MIN / -1. Checks: result equal to the reference; done exactly 33
// cycles after start (34 cycles in EX, the same for every operand); back-to-back operation
// (next start in the done cycle); starts while iterating are ignored; a watchdog fails the
// test if done never comes. Prints exactly one PASS/FAIL line.

module tb_div_unit;

    reg         clk = 1'b0, rst = 1'b1, start = 1'b0;
    reg  [1:0]  op = 2'd0;
    reg  [31:0] a = 32'd0, b = 32'd0;
    wire        busy, done;
    wire [31:0] result;

    div_unit dut (.clk(clk), .rst(rst), .start(start), .op(op), .a(a), .b(b),
                  .busy(busy), .done(done), .result(result));

    always #10 clk = ~clk;

    integer fd, n, vectors = 0, errors = 0, timing_errors = 0, cyc, maxcyc = 0;
    reg [31:0] f3, va, vb, vexp;

    task step; begin @(posedge clk); #1; end endtask

    initial begin
        fd = $fopen("div_vectors.mem", "r");
        if (fd == 0) begin
            $display("FAIL div_unit: cannot open div_vectors.mem");
            $finish;
        end
        step; step; rst = 1'b0; step;
        n = $fscanf(fd, "%h %h %h %h\n", f3, va, vb, vexp);
        while (n == 4) begin
            start = 1'b1; op = f3[1:0]; a = va; b = vb;        // cycle 0
            step;
            cyc = 1;                                           // now in cycle 1
            // while iterating, poke start with garbage now and then: it must be ignored
            while (!done && cyc < 100) begin
                start = (cyc % 11 == 3); a = 32'hFFFF0000; b = 32'h3; op = 2'd1;
                step;
                cyc = cyc + 1;                                 // cyc = index of the current cycle
            end
            start = 1'b0;
            if (cyc != 33) begin
                timing_errors = timing_errors + 1;
                if (timing_errors <= 5) $display("timing: done after %0d cycles (want 33)", cyc);
            end
            if (cyc > maxcyc) maxcyc = cyc;
            if (cyc >= 100) begin
                $display("FAIL div_unit: hang (no done after 100 cycles), vector %0d", vectors);
                $finish;
            end
            if (result !== vexp) begin
                errors = errors + 1;
                if (errors <= 5)
                    $display("mismatch: op %0d a %08h b %08h got %08h want %08h", f3, va, vb, result, vexp);
            end
            vectors = vectors + 1;
            n = $fscanf(fd, "%h %h %h %h\n", f3, va, vb, vexp);
        end
        $fclose(fd);
        if (vectors > 40000 && errors == 0 && timing_errors == 0)
            $display("PASS div_unit (%0d vectors, every result %0d cycles after start = 34 cycles in EX)", vectors, maxcyc);
        else
            $display("FAIL div_unit: %0d vectors, %0d wrong results, %0d timing errors", vectors, errors, timing_errors);
        $finish;
    end

endmodule

`default_nettype wire
