`timescale 1ns / 1ps
`default_nettype none
// tb_imem_bram - run with the demo image's imem.hex in the run directory.
// Every word through both ports (same address and different addresses), then 20,000 cycles of
// random addresses on both ports, a quarter of them identical, against the hex file.
// Prints one PASS/FAIL line.

module tb_imem_bram;

    reg         clk = 1'b0;
    always #10 clk = ~clk;

    reg  [11:0] addr_a = 12'd0, addr_b = 12'd0;
    wire [31:0] rdata_a, rdata_b;

    imem_bram #(.INIT_FILE("imem.hex")) dut (.clk(clk), .addr_a(addr_a), .rdata_a(rdata_a),
                                            .addr_b(addr_b), .rdata_b(rdata_b));

    reg [31:0] model [0:4095];
    integer i, errors = 0, checks = 0, seed = 57;

    task cyc(input [11:0] a, input [11:0] b);
        begin
            @(negedge clk); addr_a = a; addr_b = b;
            @(posedge clk); #1;
            checks = checks + 2;
            if (rdata_a !== model[a]) begin
                errors = errors + 1;
                if (errors <= 10) $display("port A %0d: got %08h want %08h", a, rdata_a, model[a]);
            end
            if (rdata_b !== model[b]) begin
                errors = errors + 1;
                if (errors <= 10) $display("port B %0d: got %08h want %08h", b, rdata_b, model[b]);
            end
        end
    endtask

    initial begin
        for (i = 0; i < 4096; i = i + 1) model[i] = 32'd0;
        $readmemh("imem.hex", model);
        for (i = 0; i < 4096; i = i + 1) cyc(i, i);                 // same address, both ports
        for (i = 0; i < 4096; i = i + 1) cyc(i, 4095 - i);          // different addresses
        for (i = 0; i < 20000; i = i + 1) begin
            addr_a = $random(seed);
            cyc(addr_a, ($random(seed) & 3) == 0 ? addr_a : $random(seed));
        end
        if (errors == 0 && checks > 50000)
            $display("PASS imem_bram (%0d checks: every word on both ports, same and different addresses, 20000 random cycles)", checks);
        else
            $display("FAIL imem_bram: %0d errors in %0d checks", errors, checks);
        $finish;
    end

endmodule

`default_nettype wire
