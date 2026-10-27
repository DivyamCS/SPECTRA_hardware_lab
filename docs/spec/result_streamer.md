# result_streamer (spec v1.0.1)

| Item | Value |
| --- | --- |
| File | rtl/io/result_streamer.v |
| Testbench | in the SoC: tb/tb_top.v (tb/top/run.py, UART line decoded with `host/protocol.py`); alone: tb/tb_result_streamer.v (tb/streamer/run.py) |
| Vectors | reference UART streams tb/ref/*.bin from `rv32sim -u`; shadow contents from `tools/golden.py` |
| Interfaces | snoops the IF-A master port of rr_arbiter (stores with `owner`); IF-D (`cfg`) |
| Removal parameter | none |

## Purpose
Streams each run's results to the laptop over the UART as the packets of PROTOCOL.md section 5
(BEGIN, FRAME, ROW, MROW, STATS), without ever making a core wait.

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 each | |
| `cfg`, `ncores` | in | 16, 2 | for BEGIN and STATS |
| `snoop_we`, `snoop_addr`, `snoop_wdata`, `snoop_be`, `snoop_done` | in | 1,32,32,4,1 | a store completing on the data port (`ready` of a write) |
| `ev_run_start` | in | 1 | RUN_START write: send BEGIN, start the cycle stamp |
| `ev_gen_done`, `gen_word` | in | 1, 32 | GEN_DONE write: {buffer << 16 or generation} |
| `ev_row_done`, `ev_mrow_done`, `ev_owner`, `ev_row` | in | 1,1,1,32 | ROW_DONE / MROW_DONE writes |
| `ev_checksum`, `checksum` | in | 1, 32 | CHECKSUM write: send STATS |
| `snap` | in | 32 x 15 | counters from perf_counters for STATS |
| to uart_top | out/in | - | `wr`, `wr_data`, `full` -> and `tx_busy` <- (uart_top's `busy`) |
| `uart_busy` | out | 1 | still sending (VIO probe) |

## Behaviour
1. Shadow buffers, written only from snooped stores: GRID0/GRID1 as 1 bit per cell (2 x 4096
   bits), IMAGE as bytes (27,648 B), MatMul C as min(255, value >> 5) (1,024 B).
   The grid shadows are distributed (LUT) RAM read without a clock: a store to the cell being
   copied in the same cycle leaves the frame with the old cell, as in the RTL. (A block RAM
   there gave a read-during-write result that simulation does not show.)
2. ROW_DONE and MROW_DONE push {core, row, cycle} into a 256-entry FIFO; the row's bytes are read
   from the shadow when its packet is sent.
3. GEN_DONE copies the selected grid's 4096 bits into a frame buffer only if the previous FRAME
   has finished sending; otherwise that frame is skipped (cycle counts are unaffected).
4. Packets: `0xA5 | type | length u16 LE | payload | crc8` (polynomial 0x07, initial 0, over type,
   length and payload); all fields little-endian; cycle stamps count from RUN_START.
5. Never stalls a core: no back-pressure exists from the streamer to the data port.

## Reset values
FIFOs empty, no packet in progress, shadows not cleared by reset (each program writes its whole
output). Shadows start at 0 at configuration (initial values = the FPGA's power-up contents, so
simulation and board agree on cells never written).

## Tests
Shadow contents equal `golden.py` data at the end of each program; the decoded UART stream equals
the reference packet for packet with valid CRCs (cycle stamps aside). Alone
(tb/streamer/run.py): every packet = a Python model, with same-cycle stores during frame copies,
a GEN_DONE skipped while busy, all 144 rows and rows >= 144, partial-word C stores ignored, and a
random UART side. PASS = all checks.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version |
| 1.0.1 | 16 Oct 2026 | Grid shadows forced to distributed RAM (Vivado had used block RAM: board read-during-write differed from RTL); shadows start at 0; ROW address row * 192 as shifts (no DSP); unit testbench. |
