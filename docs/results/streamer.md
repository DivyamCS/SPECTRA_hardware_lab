# Result streamer in the whole SoC

`python tb/top/run.py demo CFG`: soc_top (one core: DUAL = 0) in tb_top; the UART line decoded in
the testbench, packets split and CRC-checked in Python (host/protocol.py rules), compared with
rv32sim -u. For these configs rv32sim's stream is byte-identical to the references
tb/ref/uart_<program>_1c.bin. Cycles are xsim counts, not board measurements.

| Program | CONFIG | Checksum | RTL cycles | Packets (RTL / reference) | FRAMEs | Shadow check |
| --- | --- | --- | --- | --- | --- | --- |
| MatMul | 00F3 | 0xC063A00F | 794,062 | 34 / 34 | - | C heat map = golden.mm_heat(mm_result()) |
| Mandelbrot, halves | 00B3 | 0x22B8E929 | 14,740,319 | 146 / 146 | - | IMAGE = golden.mb_image() |
| Mandelbrot, interleaved | 00D3 | 0x22B8E929 | 14,740,243 | 146 / 146 | - | IMAGE = golden.mb_image() |
| Game of Life | 0093 | 0xA556EEC3 | 70,727,426 | 203 / 203 | 201 / 201 | final grid = golden.gol_frames()[400] |

Every packet has a valid CRC. BEGIN, ROW and MROW equal the reference packet for packet
(cycle stamps aside); STATS equal it except the cycle count, ARB_WAIT / BAR_WAIT and I_HIT /
I_MISS - the RTL counts every fetch, also the one squashed after a taken branch (MatMul: 302,349
hits against rv32sim's 269,583 per-instruction count); INSTRET, D_HIT and D_MISS are exact.
Every FRAME equals the reference frame of the same generation; for GoL the RTL sent the same
201 frames as rv32sim (frame skipping depends on timing, so this could legitimately differ).
Checksums and commit traces also equal rv32sim's. No compile or elaboration warnings.

Found on the way: INSTRET was one less than rv32sim's (the RUN_START store itself); fixed in
perf_counters (spec 1.0.1).
