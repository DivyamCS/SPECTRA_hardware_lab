`timescale 1ns / 1ps

module tb_dcache;

    // =========================================================================
    // Parameters & Signals
    // =========================================================================
    localparam ADDR_WIDTH = 32;
    localparam DATA_WIDTH = 32;
    
    reg clk;
    reg rst;

    // Core Interface
    reg                       re;
    reg                       we;
    reg  [ADDR_WIDTH-1:0]     addr;
    reg  [DATA_WIDTH-1:0]     wdata;
    reg  [3:0]                wstrb;
    wire [DATA_WIDTH-1:0]     rdata;
    wire                      ready;
    wire                      busy;

    // Memory Interface
    wire                      mem_req;
    wire                      mem_we;
    wire [ADDR_WIDTH-1:0]     mem_addr;
    wire [127:0]              mem_wdata;
    reg  [127:0]              mem_rdata;
    reg                       mem_ready;

    // Config/Telemetry
    reg                       cache_en;
    wire                      hit_pulse;
    wire                      miss_pulse;

    // Test tracking
    integer error_count = 0;
    integer test_count  = 0;

    // =========================================================================
    // DUT Instantiation
    // =========================================================================
    dcache #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_dut (
        .clk        (clk),
        .rst        (rst),
        .re         (re),
        .we         (we),
        .addr       (addr),
        .wdata      (wdata),
        .wstrb      (wstrb),
        .rdata      (rdata),
        .ready      (ready),
        .busy       (busy),
        .mem_req    (mem_req),
        .mem_we     (mem_we),
        .mem_addr   (mem_addr),
        .mem_wdata  (mem_wdata),
        .mem_rdata  (mem_rdata),
        .mem_ready  (mem_ready),
        .cache_en   (cache_en),
        .hit_pulse  (hit_pulse),
        .miss_pulse (miss_pulse)
    );

    // =========================================================================
    // Clock Generation (50 MHz target: 20 ns period)
    // =========================================================================
    always #10 clk = ~clk;

    // =========================================================================
    // Mock Main Memory & Reference Model
    // =========================================================================
    reg [127:0] mock_ram   [0:8191];  
    reg [31:0]  shadow_ram [0:32767]; 

    integer mem_delay_cnt;
    integer current_latency;

    always @(posedge clk) begin
        if (rst) begin
            mem_ready     <= 1'b0;
            mem_delay_cnt <= 0;
            mem_rdata     <= 128'h0;
        end else begin
            mem_ready <= 1'b0;
            
            if (mem_req && !mem_ready) begin
                if (mem_delay_cnt >= current_latency) begin
                    mem_ready     <= 1'b1;
                    mem_delay_cnt <= 0;
                    
                    if (mem_we) begin
                        mock_ram[mem_addr[16:4]] <= mem_wdata;
                    end else begin
                        mem_rdata <= mock_ram[mem_addr[16:4]];
                    end
                end else begin
                    mem_delay_cnt <= mem_delay_cnt + 1;
                end
            end else begin
                mem_delay_cnt <= 0;
            end
        end
    end

    // =========================================================================
    // BFM Tasks (Cleaned for Verilog-2001 Compatibility)
    // =========================================================================
    reg [31:0] current_val;

    task do_write(
        input [31:0] a,
        input [31:0] d,
        input [3:0]  strb
    );
        begin
            @(negedge clk);
            re    = 0; 
            we    = 1; 
            addr  = a; 
            wdata = d; 
            wstrb = strb;
            
            while (!ready) @(negedge clk);
            
            re = 0; 
            we = 0; 
            
            // Update Golden Shadow RAM
            current_val = shadow_ram[a[16:2]];
            if (strb[0]) current_val[7:0]   = d[7:0];
            if (strb[1]) current_val[15:8]  = d[15:8];
            if (strb[2]) current_val[23:16] = d[23:16];
            if (strb[3]) current_val[31:24] = d[31:24];
            shadow_ram[a[16:2]] = current_val;
            
            // Optional: Comment out this display if the output gets too spammy during stress tests
            // $display("[WRITE] Addr=%08x | Data=%08x", a, d);
        end
    endtask

    task do_read(
        input [31:0] a
    );
        reg [31:0] exp_d;
        begin
            test_count = test_count + 1;
            exp_d = shadow_ram[a[16:2]];

            @(negedge clk);
            re   = 1; 
            we   = 0; 
            addr = a;
            
            while (!ready) @(negedge clk);
            
            if (rdata !== exp_d) begin
                $display(">>> [FAIL] Addr=%08x | Expected: %08x, Got: %08x", a, exp_d, rdata);
                error_count = error_count + 1;
            end else begin
                // $display("[PASS] Addr=%08x -> Data = %08x", a, rdata);
            end
            
            re = 0; 
        end
    endtask

    // =========================================================================
    // Main Test Execution
    // =========================================================================
    integer i, loop_i;
    reg [31:0] rand_addr, rand_data;

    initial begin
        // Initialize RAM
        for (i = 0; i < 8192; i = i + 1)  mock_ram[i] = 128'h0;
        for (i = 0; i < 32768; i = i + 1) shadow_ram[i] = 32'h0;

        clk             = 0;
        rst             = 1;
        re              = 0; 
        we              = 0; 
        addr            = 0; 
        wdata           = 0; 
        wstrb           = 0; 
        cache_en        = 1;
        current_latency = 5; 
        
        repeat (3) @(posedge clk);
        #1;
        rst <= 1'b0;
        @(posedge clk);

        $display("\n=======================================================");
        $display("          STARTING MASSIVE DCACHE STRESS TEST            ");
        $display("=======================================================\n");

        // ---------------------------------------------------------
        $display("---> PHASE 1: Sequential Line Fills & Word Offsets");
        // Write across all 4 words of the same cache line
        do_write(32'h0000_1000, 32'hAAAA_1111, 4'b1111); // Word 0
        do_write(32'h0000_1004, 32'hBBBB_2222, 4'b1111); // Word 1
        do_write(32'h0000_1008, 32'hCCCC_3333, 4'b1111); // Word 2
        do_write(32'h0000_100C, 32'hDDDD_4444, 4'b1111); // Word 3
        
        // Read back to ensure multiplexing works properly
        do_read(32'h0000_100C);
        do_read(32'h0000_1008);
        do_read(32'h0000_1004);
        do_read(32'h0000_1000);

        // ---------------------------------------------------------
        $display("---> PHASE 2: Heavy Set Thrashing (Eviction Stress)");
        // Write 10 different tags to Set 7 (addr[9:4] = 7 -> offset 0x70)
        // This forces 6 lines to be evicted and replaced consecutively
        for (loop_i = 0; loop_i < 10; loop_i = loop_i + 1) begin
            // Address format: {Tag (varies), Index (7), Offset (0)}
            rand_addr = {loop_i[21:0], 6'd7, 4'h0}; 
            rand_data = $random;
            do_write(rand_addr, rand_data, 4'b1111);
        end
        // Verify the last 4 written tags are still in cache (or fetch cleanly from memory)
        for (loop_i = 0; loop_i < 10; loop_i = loop_i + 1) begin
            rand_addr = {loop_i[21:0], 6'd7, 4'h0}; 
            do_read(rand_addr);
        end

        // ---------------------------------------------------------
        $display("---> PHASE 3: Read-after-Write Hazard Checks");
        do_write(32'h0000_2000, 32'h1234_5678, 4'b1111);
        do_write(32'h0000_2000, 32'hDEAD_BEEF, 4'b1111); // Overwrite identical address
        do_read (32'h0000_2000); // Should read DEADBEEF cleanly

        // ---------------------------------------------------------
        // ---------------------------------------------------------
        $display("---> PHASE 4: Bypass Operations Mixed with Normal");
        
        // 1. Bypass Writes (Goes straight to memory)
        cache_en = 0;
        do_write(32'h0000_4000, 32'hB1B1_B1B1, 4'b1111);
        do_write(32'h0000_4004, 32'hB2B2_B2B2, 4'b1111);
        
        // 2. Enable Cache 
        cache_en = 1;
        
        // 3. Cached Reads (Forces a fetch from memory)
        // If bypass wrote correctly, the cache will pull B1B1 and B2B2 into its arrays.
        do_read(32'h0000_4000); 
        do_read(32'h0000_4004); 
        
        // 4. Cached Write (Write-back, stays in cache)
        do_write(32'h0000_4008, 32'hC3C3_C3C3, 4'b1111); 
        do_read(32'h0000_4008); // Cached read correctly sees C3C3

        // ---------------------------------------------------------
        $display("---> PHASE 5: Massive Randomized Stress Loop");
        // Perform 200 random writes followed by 200 random reads
        for (loop_i = 0; loop_i < 200; loop_i = loop_i + 1) begin
            // Keep addresses within 0x0000_0000 and 0x0000_1FFF to force overlap/hits
            rand_addr = {$random} & 32'h0000_1FFC; 
            rand_data = $random;
            do_write(rand_addr, rand_data, 4'b1111);
        end

        for (loop_i = 0; loop_i < 200; loop_i = loop_i + 1) begin
            rand_addr = {$random} & 32'h0000_1FFC; 
            do_read(rand_addr);
        end

        // ---------------------------------------------------------
        $display("\n=======================================================");
        if (error_count == 0) begin
            $display(" MASSIVE STRESS TEST PASSED: %0d Operations ", test_count);
        end else begin
            $display(" FAILED WITH %0d ERRORS OUT OF %0d TESTS ", error_count, test_count);
        end
        $display("=======================================================\n");

        $finish;
    end

endmodule