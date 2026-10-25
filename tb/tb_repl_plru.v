`timescale 1ns / 1ps
`default_nettype none
// tb_repl_plru - Replays tb/vectors/plru_vectors.mem (tools/gen_repl_vectors.py:
// 10,000 operations from tools/cache_model.py in 8 sections, way masks 0000, 0001, 0011, 0111,
// 1010, 0110, 1000, 1101). Line "kind set way mask victim": kind 2 = reset and new mask; 0 = hit
// of way (update); 1 = fill: the module's victim must equal `victim`, which is then filled.
// Prints one PASS/FAIL line.

module tb_repl_plru;

    reg        clk = 1'b0, rst = 1'b1, upd = 1'b0;
    reg  [5:0] set = 6'd0, upd_set = 6'd0;
    reg  [3:0] way_mask = 4'd0;
    reg  [1:0] upd_way = 2'd0;
    wire [1:0] victim;
    always #10 clk = ~clk;

    plru dut (.clk(clk), .rst(rst), .set(set), .way_mask(way_mask), .victim(victim),
                   .upd(upd), .upd_set(upd_set), .upd_way(upd_way));

    integer fd, r, kind, s, w, m, v, lines = 0, fills = 0, errors = 0;
    initial begin
        fd = $fopen("plru_vectors.mem", "r");
        if (fd == 0) begin $display("FAIL repl_plru: cannot open plru_vectors.mem"); $finish; end
        @(negedge clk);
        while (!$feof(fd)) begin
            r = $fscanf(fd, "%d %d %d %d %d\n", kind, s, w, m, v);
            if (r == 5) begin
                lines = lines + 1;
                upd = 1'b0; rst = 1'b0;
                if (kind == 2) begin
                    rst = 1'b1; way_mask = m;
                end else if (kind == 0) begin
                    upd = 1'b1; upd_set = s; upd_way = w;
                end else begin
                    set = s; #1;
                    fills = fills + 1;
                    if (victim !== v) begin
                        errors = errors + 1;
                        if (errors <= 10) $display("line %0d: set %0d mask %b victim %0d, model %0d", lines, s, m, victim, v);
                    end
                    upd = 1'b1; upd_set = s; upd_way = v;
                end
                @(negedge clk);
            end
        end
        $fclose(fd);
        if (errors == 0 && lines == 10000 && fills > 4000)
            $display("PASS repl_plru (%0d operations, %0d victims = the Python model, 8 way masks)", lines, fills);
        else
            $display("FAIL repl_plru: %0d errors, %0d lines, %0d fills", errors, lines, fills);
        $finish;
    end

endmodule

`default_nettype wire
