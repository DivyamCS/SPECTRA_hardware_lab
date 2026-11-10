`timescale 1ns / 1ps
`default_nettype none

//=============================================================================
// Module: result_streamer
// Description: 
//   Turns snooped stores and MMIO events into UART packets for the laptop
//   (spec: docs/spec/result_streamer.md, PROTOCOL.md section 5; rv32sim -u).
//   Shadows written only from stores completing on the data port.
//=============================================================================

module result_streamer (
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] cfg,
    input  wire [1:0]  ncores,

    //-------------------------------------------------------------------------
    // Snooped Stores (write ready on the data port)
    //-------------------------------------------------------------------------
    input  wire        snoop_we,
    input  wire [31:0] snoop_addr,
    input  wire [31:0] snoop_wdata,
    input  wire [3:0]  snoop_be,
    input  wire        snoop_done,

    //-------------------------------------------------------------------------
    // MMIO Events (1-cycle pulses from mmio_bus)
    //-------------------------------------------------------------------------
    input  wire        ev_run_start,
    input  wire        ev_gen_done,
    input  wire [31:0] gen_word,
    input  wire        ev_row_done,
    input  wire        ev_mrow_done,
    input  wire        ev_owner,
    input  wire [31:0] ev_row,
    input  wire        ev_checksum,
    input  wire [31:0] checksum,
    input  wire [479:0] snap,

    //-------------------------------------------------------------------------
    // Maze Mode (PROTOCOL.md section 11): MAZEFRAME / MAZEMAP writes
    //-------------------------------------------------------------------------
    input  wire        ev_maze_frame,
    input  wire        ev_maze_map,
    input  wire [31:0] maze_cycles,

    //-------------------------------------------------------------------------
    // uart_top
    //-------------------------------------------------------------------------
    output reg         wr,
    output reg  [7:0]  wr_data,
    input  wire        full,
    input  wire        tx_busy,
    output wire        uart_busy
);

    wire        st     = snoop_done && snoop_we;
    wire [31:0] a      = snoop_addr;
    wire [31:0] cycles = snap[31:0];

    //-------------------------------------------------------------------------
    // Grid Shadows (1 bit per cell)
    // cell c of grid g is bit c[1:0] of word {g, c[11:2]}
    //-------------------------------------------------------------------------
    wire        is_grid = st && (a[31:13] == 19'h08004); // 0x1000_8000-0x1000_9FFF
    wire [10:0] g_widx  = {a[12], a[11:2]};
    reg  [10:0] cp_rd;                                   // copy engine read index
    wire [3:0]  g_rbits;
    
    genvar l;
    generate
        for (l = 0; l < 4; l = l + 1) begin : g_lane
            // distributed RAM, read without a clock
            (* ram_style = "distributed" *) reg gm [0:2047];
            integer z;
            initial for (z = 0; z < 2048; z = z + 1) gm[z] = 1'b0;
            
            always @(posedge clk) begin
                if (is_grid && snoop_be[l]) 
                    gm[g_widx] <= (snoop_wdata[8*l +: 8] != 8'd0);
            end
            assign g_rbits[l] = gm[cp_rd];
        end
    endgenerate

    // frame buffer: 1024 x 4 cells
    reg  [3:0]  fbuf [0:1023];
    reg         copying, frame_queued, frame_sending, frame_drain;
    reg  [10:0] cp_cnt;
    reg  [15:0] frame_gen;
    reg  [31:0] frame_cyc;
    
    wire        frame_busy = copying || frame_queued || frame_sending || frame_drain;
    wire        take_frame = ev_gen_done && !frame_busy;

    //-------------------------------------------------------------------------
    // Packet Engine State
    //-------------------------------------------------------------------------
    reg  [2:0]  ptype;             // 1 BEGIN, 2 FRAME, 3 ROW, 4 MROW, 5 STATS, 6 MAZEFRAME, 7 MAZEMAP
    reg  [9:0]  plen, pidx;        // payload length; byte index 0 .. plen + 4
    reg  [48:0] cur;               // sending: [48] MROW, [47] core, [46:32] row, [31:0] cycle

    wire [9:0]  k       = pidx - 10'd4;                      // payload byte index
    wire [15:0] cur_row = {1'b0, cur[46:32]};
    wire [31:0] cur_cyc = cur[31:0];
    wire [17:0] row18   = {3'd0, cur_row[14:0]};
    wire [17:0] i_byte  = (row18 << 7) + (row18 << 6) + {8'd0, k} - 18'd7;
    wire [9:0]  c_idx   = {cur_row[4:0], 5'd0} + (k - 10'd6);
    // MAZEFRAME byte k -> COLUMNS byte: seq 0, n_cols 1, (cycles 2-5 from mz_cyc), pose 4-9 at
    // k 6-11, columns 16.. at k 12..; MAZEMAP byte k >= 2 -> map byte k - 2
    wire [9:0]  mzf_b   = (k < 10'd2) ? k : (k < 10'd12) ? k - 10'd2 : k + 10'd4;
    wire [9:0]  mzm_b   = k - 10'd2;

    //-------------------------------------------------------------------------
    // IMAGE Shadow (bytes)
    //-------------------------------------------------------------------------
    wire        is_img = st && (a[31:16] == 16'h1001) && (a[15:0] < 16'h6C00);
    wire [12:0] i_widx = a[14:2];
    reg  [31:0] i_q;
    
    (* ram_style = "block" *) reg [31:0] imem [0:6911];
    integer zi;
    initial for (zi = 0; zi < 6912; zi = zi + 1) imem[zi] = 32'd0;
    
    always @(posedge clk) begin
        if (is_img) begin
            if (snoop_be[0]) imem[i_widx][7:0]   <= snoop_wdata[7:0];
            if (snoop_be[1]) imem[i_widx][15:8]  <= snoop_wdata[15:8];
            if (snoop_be[2]) imem[i_widx][23:16] <= snoop_wdata[23:16];
            if (snoop_be[3]) imem[i_widx][31:24] <= snoop_wdata[31:24];
        end
    end
    always @(posedge clk) i_q <= imem[i_byte[14:2]];

    //-------------------------------------------------------------------------
    // MatMul C Shadow (heat bytes)
    //-------------------------------------------------------------------------
    wire        is_c = st && (a[31:12] == 20'h10018) && (snoop_be == 4'hF);
    wire [7:0]  heat = (snoop_wdata[31:13] != 19'd0) ? 8'hFF : snoop_wdata[12:5];
    reg  [7:0]  c_q;
    
    (* ram_style = "block" *) reg [7:0] cmem [0:1023];
    integer zc;
    initial for (zc = 0; zc < 1024; zc = zc + 1) cmem[zc] = 8'd0;
    
    always @(posedge clk) if (is_c) cmem[a[11:2]] <= heat;
    always @(posedge clk) c_q <= cmem[c_idx];
    // the maze shadow's read port (declared below with the RAM): the byte of the packet being sent

    // ------------------------------------------------------------ maze shadows (one 512 x 32 RAM)
    // words 0..143: MAZE_MAP (0x1000_A000, 576 bytes); words 256..511: two banks of COLUMNS
    // (0x1000_A800, 336 bytes: header 16 + 160 x 2). Snooped stores go to the live bank; MAZEFRAME
    // swaps the banks, so the frame being sent is frozen while the cores already write the next
    // one (every frame rewrites all the bytes a packet uses). A MAZEFRAME while the previous one is
    // still on its way (queued, sending, or the UART still busy) is skipped, as rv32sim does.
    wire        is_mmap = st && (a[31:10] == 22'h040028) && (a[9:0] < 10'd576);   // 0x1000_A000..A23F
    wire        is_mcol = st && (a[31:9] == 23'h080054) && (a[8:0] < 9'd336);    // 0x1000_A800..A94F
    reg         mz_wbank, mz_queued, mz_sending, mz_drain, mz_map_pend;
    reg  [31:0] mz_cyc;
    wire        mz_busy = mz_queued || mz_sending || mz_drain;
    wire        take_maze = ev_maze_frame && !mz_busy;
    reg  [31:0] mz_q;
    (* ram_style = "block" *) reg [31:0] mzmem [0:511];
    integer zm;
    initial for (zm = 0; zm < 512; zm = zm + 1) mzmem[zm] = 32'd0;
    wire [8:0]  mz_widx = is_mmap ? {1'b0, a[9:2]} : {1'b1, mz_wbank, a[8:2]};
    always @(posedge clk) begin
        if (is_mmap || is_mcol) begin
            if (snoop_be[0]) mzmem[mz_widx][7:0]   <= snoop_wdata[7:0];
            if (snoop_be[1]) mzmem[mz_widx][15:8]  <= snoop_wdata[15:8];
            if (snoop_be[2]) mzmem[mz_widx][23:16] <= snoop_wdata[23:16];
            if (snoop_be[3]) mzmem[mz_widx][31:24] <= snoop_wdata[31:24];
        end
    end

    //-------------------------------------------------------------------------
    // Row FIFO {mrow, core, row, cycle}
    //-------------------------------------------------------------------------
    reg  [48:0] rq [0:255];
    reg  [8:0]  rq_n;
    reg  [7:0]  rq_w, rq_r;
    
    wire        row_ev  = ev_row_done || ev_mrow_done;
    wire [31:0] row_mod = ev_row_done ? (ev_row % 32'd144) : (ev_row % 32'd32);

    //-------------------------------------------------------------------------
    // Pending BEGIN / STATS
    //-------------------------------------------------------------------------
    reg         begin_pend, stats_pend;
    reg  [31:0] stats_cyc, stats_sum;
    reg [447:0] stats_cnt;             

    //-------------------------------------------------------------------------
    // Packet Engine State Machine
    //-------------------------------------------------------------------------
    localparam P_IDLE = 2'd0, P_ADDR = 2'd1, P_DATA = 2'd2;
    reg  [1:0]  ps;
    reg  [7:0]  crc;
    wire [7:0]  prog = {6'd0, cfg[6:5]};

    function [7:0] crc_step(input [7:0] c, input [7:0] d);
        reg [7:0] x; integer j;
        begin
            x = c ^ d;
            for (j = 0; j < 8; j = j + 1) 
                x = x[7] ? ({x[6:0], 1'b0} ^ 8'h07) : {x[6:0], 1'b0};
            crc_step = x;
        end
    endfunction

    reg [7:0] pay, b;
    always @(*) begin
        pay = 8'd0;
        case (ptype)
            3'd1: case (k)                                                   // BEGIN
                      10'd0:   pay = cfg[7:0];
                      10'd1:   pay = cfg[15:8];
                      10'd2:   pay = {6'd0, ncores};
                      default: pay = prog;
                  endcase
            3'd2: if (k < 2)       pay = frame_gen[8*k +: 8];                // FRAME
                  else if (k < 6)  pay = frame_cyc[8*(k-2) +: 8];
                  else             pay = {fbuf[2*(k-6)+1], fbuf[2*(k-6)]};
            3'd3: if (k == 0)      pay = {7'd0, cur[47]};                    // ROW
                  else if (k < 3)  pay = cur_row[8*(k-1) +: 8];
                  else if (k < 7)  pay = cur_cyc[8*(k-3) +: 8];
                  else             pay = i_q[8*i_byte[1:0] +: 8];
            3'd4: if (k == 0)      pay = {7'd0, cur[47]};                    // MROW
                  else if (k == 1) pay = cur_row[7:0];
                  else if (k < 6)  pay = cur_cyc[8*(k-2) +: 8];
                  else             pay = c_q;
            3'd5: if (k < 2)       pay = cfg[8*k +: 8];                      // STATS
                  else if (k == 2) pay = {6'd0, ncores};
                  else if (k == 3) pay = prog;
                  else if (k < 8)  pay = stats_cyc[8*(k-4) +: 8];
                  else if (k < 12) pay = stats_sum[8*(k-8) +: 8];
                  else             pay = stats_cnt[8*(k-12) +: 8];
            3'd6: if (k < 2)       pay = mz_q[8*mzf_b[1:0] +: 8];           // MAZEFRAME
                  else if (k < 6)  pay = mz_cyc[8*(k-2) +: 8];
                  else             pay = mz_q[8*mzf_b[1:0] +: 8];
            3'd7: if (k < 2)       pay = 8'd24;                              // MAZEMAP 24 x 24
                  else             pay = mz_q[8*mzm_b[1:0] +: 8];
        endcase

        if (pidx == 10'd0)                 b = 8'hA5;
        else if (pidx == 10'd1)            b = {5'd0, ptype};
        else if (pidx == 10'd2)            b = plen[7:0];
        else if (pidx == 10'd3)            b = {6'd0, plen[9:8]};
        else if (pidx == plen + 10'd4)     b = crc;
        else                               b = pay;
    end

    wire deq = (ps == P_IDLE) && !begin_pend && !frame_queued && !mz_map_pend && !mz_queued && (rq_n != 9'd0);
    assign uart_busy = (ps != P_IDLE) || begin_pend || stats_pend || frame_busy || mz_busy || mz_map_pend ||
                       (rq_n != 9'd0) || tx_busy;
    // maze shadow read: the bank not being written (the frozen frame), or the map
    always @(posedge clk) mz_q <= mzmem[(ptype == 3'd7) ? {1'b0, mzm_b[9:2]} : {1'b1, ~mz_wbank, mzf_b[8:2]}];

    always @(posedge clk) begin
        wr <= 1'b0;
        if (rst) begin
            copying <= 1'b0; frame_queued <= 1'b0; frame_sending <= 1'b0; frame_drain <= 1'b0;
            rq_n <= 9'd0; rq_w <= 8'd0; rq_r <= 8'd0;
            begin_pend <= 1'b0; stats_pend <= 1'b0; ps <= P_IDLE;
            mz_wbank <= 1'b0; mz_queued <= 1'b0; mz_sending <= 1'b0; mz_drain <= 1'b0; mz_map_pend <= 1'b0;
            ptype <= 3'd1; plen <= 10'd4; pidx <= 10'd0; crc <= 8'd0; cur <= 49'd0;
        end else begin
            // ---- events
            if (ev_run_start) begin_pend <= 1'b1;
            
            if (take_frame) begin
                copying <= 1'b1; cp_cnt <= 11'd0; cp_rd <= {gen_word[16], 10'd0};
                frame_gen <= gen_word[15:0]; frame_cyc <= cycles;
            end
            
            if (copying) begin
                fbuf[cp_cnt[9:0]] <= g_rbits;
                cp_rd  <= cp_rd + 11'd1;
                cp_cnt <= cp_cnt + 11'd1;
                if (cp_cnt == 11'd1023) begin 
                    copying <= 1'b0; frame_queued <= 1'b1; 
                end
            end
            
            if (frame_drain && !tx_busy) frame_drain <= 1'b0;
            if (take_maze) begin
                mz_wbank <= ~mz_wbank; mz_queued <= 1'b1; mz_cyc <= maze_cycles;
            end
            if (ev_maze_map) mz_map_pend <= 1'b1;
            if (mz_drain && !tx_busy) mz_drain <= 1'b0;
            if (row_ev && rq_n != 9'd256) begin
                rq[rq_w] <= {ev_mrow_done, ev_owner, row_mod[14:0], cycles};
                rq_w <= rq_w + 8'd1;
            end
            
            rq_n <= rq_n + ((row_ev && rq_n != 9'd256) ? 9'd1 : 9'd0) - (deq ? 9'd1 : 9'd0);
            
            if (ev_checksum) begin
                stats_pend <= 1'b1; 
                stats_cyc  <= cycles; 
                stats_sum  <= checksum; 
                stats_cnt  <= snap[479:32];
            end
            
            // ---- packet engine
            case (ps)
                P_IDLE: begin
                    pidx <= 10'd0; crc <= 8'd0;
                    if (begin_pend) begin
                        begin_pend <= 1'b0; ptype <= 3'd1; plen <= 10'd4; ps <= P_ADDR;
                    end else if (mz_map_pend) begin
                        mz_map_pend <= 1'b0; ptype <= 3'd7; plen <= 10'd578; ps <= P_ADDR;
                    end else if (frame_queued) begin
                        frame_queued <= 1'b0; frame_sending <= 1'b1; ptype <= 3'd2; plen <= 10'd518; ps <= P_ADDR;
                    end else if (mz_queued) begin
                        mz_queued <= 1'b0; mz_sending <= 1'b1; ptype <= 3'd6; plen <= 10'd332; ps <= P_ADDR;
                    end else if (deq) begin
                        cur <= rq[rq_r]; rq_r <= rq_r + 8'd1;
                        ptype <= rq[rq_r][48] ? 3'd4 : 3'd3; 
                        plen  <= rq[rq_r][48] ? 10'd38 : 10'd199;
                        ps <= P_ADDR;
                    end else if (stats_pend && !frame_busy && !mz_busy) begin
                        stats_pend <= 1'b0; ptype <= 3'd5; plen <= 10'd68; ps <= P_ADDR;
                    end
                end
                
                P_ADDR: ps <= P_DATA;
                
                P_DATA: if (!full) begin
                    wr <= 1'b1; wr_data <= b;
                    if (pidx != 10'd0 && pidx != plen + 10'd4) 
                        crc <= crc_step(crc, b);
                        
                    if (pidx == plen + 10'd4) begin
                        ps <= P_IDLE;
                        if (ptype == 3'd2) begin
                            frame_sending <= 1'b0; frame_drain <= 1'b1;
                        end
                        if (ptype == 3'd6) begin
                            mz_sending <= 1'b0; mz_drain <= 1'b1;
                        end
                    end else begin
                        pidx <= pidx + 10'd1; ps <= P_ADDR;
                    end
                end
                
                default: ps <= P_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire