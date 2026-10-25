`timescale 1ns / 1ps
`default_nettype none
// tb_dmem_bram - run with tb/dmem_init/dmem.hex (tb/dmem_init/make.py) in the run directory.
//  * initial contents: all 32,768 words equal dmem.hex (first 8,192 words) and 0 after;
//  * every byte-enable pattern written and read back at the first word, the last word and a
//    middle word; the write is read-first (a read in the write cycle returns the old word);
//  * 20,000 random cycles (write or read, random address, random enables) against a model.
// Prints one PASS/FAIL line.

module tb_dmem_bram;

    reg         clk = 1'b0;
    always #10 clk = ~clk;

    reg  [14:0] addr = 15'd0;
    reg         we = 1'b0;
    reg  [3:0]  be = 4'd0;
    reg  [31:0] wdata = 32'd0;
    wire [31:0] rdata;

    dmem_bram #(.INIT_FILE("dmem.hex")) dut (.clk(clk), .addr(addr), .we(we), .be(be),
                                            .wdata(wdata), .rdata(rdata));

    reg [31:0] model [0:32767];
    integer i, k, n, errors = 0, checks = 0, seed = 56;
    reg [31:0] want;

    task fail(input [8*40-1:0] what, input [31:0] got, input [31:0] w);
        begin
            errors = errors + 1;
            if (errors <= 12) $display("%0s: addr %0d got %08h want %08h", what, addr, got, w);
        end
    endtask

    // one cycle: drive at the negedge, check rdata after the posedge (it shows the word as it
    // was before this cycle's write: read-first), then apply the write to the model
    task cyc(input w, input [14:0] a, input [3:0] b, input [31:0] d);
        begin
            @(negedge clk);
            we = w; addr = a; be = b; wdata = d;
            want = model[a];
            @(posedge clk); #1;
            checks = checks + 1;
            if (rdata !== want) fail("read", rdata, want);
            if (w) for (n = 0; n < 4; n = n + 1) if (b[n]) model[a][8*n +: 8] = d[8*n +: 8];
        end
    endtask

    integer bp;
    reg [14:0] spots [0:2];
    initial begin
        for (i = 0; i < 32768; i = i + 1) model[i] = 32'd0;
        $readmemh("dmem.hex", model, 0, 8191);
        // initial contents, every word
        for (i = 0; i < 32768; i = i + 1) cyc(0, i, 4'd0, 32'd0);
        // every byte-enable pattern at the first, the last and a middle word
        spots[0] = 15'd0; spots[1] = 15'd32767; spots[2] = 15'd12345;
        for (k = 0; k < 3; k = k + 1)
            for (bp = 0; bp < 16; bp = bp + 1) begin
                cyc(1, spots[k], bp, $random(seed));          // write (reads the old word)
                cyc(0, spots[k], 4'd0, 32'd0);                // read back
            end
        // random cycles
        for (i = 0; i < 20000; i = i + 1)
            cyc($random(seed), (i % 5 == 0) ? spots[i % 3] : $random(seed), $random(seed), $random(seed));
        if (errors == 0 && checks > 50000)
            $display("PASS dmem_bram (%0d checks: initial contents, 16 byte-enable patterns at 3 words, read-first, 20000 random cycles)", checks);
        else
            $display("FAIL dmem_bram: %0d errors in %0d checks", errors, checks);
        $finish;
    end

endmodule

`default_nettype wire
