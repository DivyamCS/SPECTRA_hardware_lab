`timescale 1ns / 1ps
`default_nettype none

//=============================================================================
// Testbench: tb_result_streamer
// Description:
//   Result streamer alone, driven by tb/streamer/run.py via `stim.mem`.
//   Simulates snooped stores, MMIO events, and randomized UART back-pressure.
//   Outputs `st_bytes.hex` for verification against `rv32sim -u`.
//=============================================================================

module tb_result_streamer;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #10 clk = ~clk;

    // Config and Core count
    reg  [15:0]  cfg = 16'h0093;
    reg  [1:0]   ncores = 2'd1;

    // Snoop Interface
    reg          snoop_we = 1'b0;
    reg          snoop_done = 1'b0;
    reg  [31:0]  snoop_addr = 32'd0;
    reg  [31:0]  snoop_wdata = 32'd0;
    reg  [3:0]   snoop_be = 4'd0;

    // MMIO Event Pulses
    reg          ev_run_start = 1'b0;
    reg          ev_gen_done = 1'b0;
    reg          ev_row_done = 1'b0;
    reg          ev_mrow_done = 1'b0;
    reg          ev_owner = 1'b0;
    reg          ev_checksum = 1'b0;
    
    reg  [31:0]  gen_word = 32'd0;
    reg  [31:0]  ev_row = 32'd0;
    reg  [31:0]  checksum = 32'd0;

    // Cycle count and Counter snapshot
    reg  [31:0]  cyc = 32'd0;
    reg  [447:0] cnt_pat;
    wire [479:0] snap = {cnt_pat, cyc};

    // UART Output
    wire         wr;
    wire         uart_busy;
    wire [7:0]   wr_data;
    
    // UART Back-pressure (LFSR driven)
    reg  [15:0]  lfsr = 16'hACE1;
    wire         full    = (lfsr[1:0] == 2'b00);
    wire         tx_busy = (lfsr[3:2] == 2'b00);

    //=========================================================================
    // DUT Instantiation
    //=========================================================================
    result_streamer dut (
        .clk(clk), 
        .rst(rst), 
        .cfg(cfg), 
        .ncores(ncores),
        .snoop_we(snoop_we), 
        .snoop_addr(snoop_addr), 
        .snoop_wdata(snoop_wdata), 
        .snoop_be(snoop_be),
        .snoop_done(snoop_done), 
        .ev_run_start(ev_run_start), 
        .ev_gen_done(ev_gen_done), 
        .gen_word(gen_word),
        .ev_row_done(ev_row_done), 
        .ev_mrow_done(ev_mrow_done), 
        .ev_owner(ev_owner), 
        .ev_row(ev_row),
        .ev_checksum(ev_checksum), 
        .checksum(checksum), 
        .snap(snap),
        .wr(wr), 
        .wr_data(wr_data), 
        .full(full), 
        .tx_busy(tx_busy), 
        .uart_busy(uart_busy)
    );

    //=========================================================================
    // LFSR and Byte Output Logger
    //=========================================================================
    integer i, fo, fs, n, nbytes = 0;
    reg [31:0] op, a, b, c;
    
    initial begin
        for (i = 0; i < 14; i = i + 1) begin
            cnt_pat[32*i +: 32] = 32'h01010101 * (i + 1) + 32'h00100000;
        end
        fo = $fopen("st_bytes.hex", "w");
    end

    always @(posedge clk) begin
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        if (!rst) cyc <= cyc + 32'd1;
        if (wr) begin 
            $fwrite(fo, "%02x\n", wr_data); 
            nbytes = nbytes + 1; 
        end
    end

    //=========================================================================
    // Stimulus Execution
    //=========================================================================
    task clear;
        begin
            snoop_we     = 1'b0; 
            snoop_done   = 1'b0; 
            ev_run_start = 1'b0; 
            ev_gen_done  = 1'b0;
            ev_row_done  = 1'b0; 
            ev_mrow_done = 1'b0; 
            ev_checksum  = 1'b0;
        end
    endtask

    integer k;
    initial begin
        repeat (5) @(posedge clk);
        #1 rst = 1'b0;
        
        fs = $fopen("stim.mem", "r");
        if (fs == 0) begin 
            $display("FAIL result_streamer: no stim.mem"); 
            $finish; 
        end
        
        op = 32'hFFFF_FFFF;
        while (op != 0 && !$feof(fs)) begin
            n = $fscanf(fs, "%h %h %h %h\n", op, a, b, c);
            #1 clear;
            
            case (op)
                1: begin 
                       snoop_we = 1'b1; snoop_done = 1'b1; snoop_addr = a; 
                       snoop_wdata = b; snoop_be = c[3:0];
                       @(posedge clk); 
                   end
                2: begin 
                       for (k = 0; k < a; k = k + 1) @(posedge clk); 
                   end
                3: begin 
                       ev_gen_done = 1'b1; gen_word = a; 
                       @(posedge clk); 
                   end
                4: begin 
                       ev_row_done = 1'b1; ev_row = a; ev_owner = b[0]; 
                       @(posedge clk); 
                   end
                5: begin 
                       ev_mrow_done = 1'b1; ev_row = a; ev_owner = b[0]; 
                       @(posedge clk); 
                   end
                6: begin 
                       ev_run_start = 1'b1; 
                       @(posedge clk); 
                   end
                7: begin 
                       ev_checksum = 1'b1; checksum = a; 
                       @(posedge clk); 
                   end
                8: begin 
                       @(posedge clk); 
                       while (uart_busy) @(posedge clk); 
                       repeat (10) @(posedge clk); 
                   end
                default: ;
            endcase
        end
        
        #1 clear;
        repeat (20) @(posedge clk);
        $fclose(fo);
        
        if (uart_busy) 
            $display("FAIL result_streamer: still busy at the end");
        else           
            $display("PASS result_streamer: %0d bytes", nbytes);
        $finish;
    end

endmodule

`default_nettype wire