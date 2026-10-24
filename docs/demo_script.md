# SPECTRA demo script v1

v1, 17 Oct 2026. Every number below was **measured on the board** with the release bitstream
(tag fpga-v1, build/releases/fpga-v1/top_fpga.bit; docs/results/numbers.md gives each number's
source row). v0 (16 Oct) used simulator estimates. Target length: under 10 minutes.

Set-up before the audience arrives: program the board with build/releases/fpga-v1/top_fpga.bit,
laptop running `python host/spectra_host.py --port COMn`, dashboard (http://localhost:8000) open
on the Live tab, Playback "slow: about 5 s". The Demo guide tab lists every case with its switch
positions. Switches not listed in a step stay down (0). Common to every step: SW0 FWD = 1,
SW4:3 LAT = 10 (L = 8), SW7 IC = 1, SW8 = 0 (reserved), SW9 write-back, SW13:10 = 0000 (all 4 ways).

After every run the 7-segment display tours the results, 3 s per item, with labels: **Cy**
cycles in thousands, then per core **IH** I-cache hit %, **dH** D-cache hit %, **CPI**; with two
cores the core number and a dot follow the label ("IH1. 99.99") and the tour ends with **Ar**
arbiter wait %. LED10 = tour on, LED1 = checksum golden. BTNC (reset) starts the next run with the
switches as they are.

| # | What | Switches up | CONFIG | Then | Board (fpga-v1) | Say |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Game of Life, 1 core, **D-cache off** | SW0, SW4, SW7 | 0x0091 | press BTNC | `Cy193212` (3.86 s), `CPI  4.12`; LED1 on; the grid evolves on the dashboard | "Every data access goes to slow memory." |
| 2 | Game of Life, 1 core, **D-cache on** | + SW1 | 0x0093 | BTNC | `Cy 70337` (1.41 s): **2.75x** faster; `dH  98.57`, `CPI  1.50` | "Same program, same checksum, only the cache switch changed." |
| 3 | Game of Life, **2 cores** | + SW2 | 0x0097 | BTNC | `Cy 38660` (0.77 s): **1.82x** over 1 core; `Ar0.  8.98`; Compare tab plays rows 1-3 side by side | "The second core takes half the rows; the shared cache and the arbiter cost some of the 2x." |
| 4 | MatMul 32x32, 1 core | SW0, SW1, SW4, SW5, SW6, SW7 | 0x00F3 | BTNC | `Cy   535` (10.7 ms), `CPI  1.99` | "i-k-j order, so B and C stream through the cache." |
| 5 | MatMul, 2 cores | + SW2 | 0x00F7 | BTNC | `Cy   297` (5.9 ms): **1.80x**; tour `IH0. 99.99`, `dH0. 99.25`, `CPI0. 2.20`, `dH1. 96.86`, `Ar0. 14.20` | "Both cores share one D-cache: core 1 sees more misses." |
| 6 | The browser on that run | SW15:14 = 01, then 10 | (live) | BTNR = core 1, BTNL = rate mode, BTNU = tour again | `dH0.49300` hits, `dn0.  368` misses; BTNR: `dH1.48109`; BTNL: `dH1. 96.86` | "The counters are in hardware; the display reads them after the run." |
| 7 | Mandelbrot, halves, 2 cores | SW0, SW1, SW2, SW4, SW5, SW7 | 0x00B7 | BTNC | `Cy  6209` (124.2 ms): **1.97x** over 1 core | "Each core gets one half of the picture." |
| 8 | Mandelbrot, interleaved, 2 cores | SW0, SW1, SW2, SW4, SW6, SW7 | 0x00D7 | BTNC | `Cy  6131` (122.6 ms): **1.99x** | "Alternate rows balance the work. The view is symmetric, so the gain over halves is small." |
| 9 | Optional: everything off | SW4 only (MatMul: + SW5, SW6) | 0x0010 / 0x0070 | BTNC | `CPI 12.90` / `CPI 12.19`: 15.6x / 11.1x slower than all on | "Without caches every instruction waits 9 cycles to be fetched. That is why caches exist." |

Numbers: docs/results/numbers.md (board, fpga-v1). Ablation (what each feature is worth): docs/results/ablation.md.

Fallback (if the board or the link fails on the day): the 7-segment display and LEDs show every
result without the laptop; recorded board runs replay in the dashboard offline with
`python host/spectra_host.py --replay build/releases/fpga-v1/board/demo_uart.bin --source board`.

Open for v2: the Mandelbrot halves view is symmetric, so halves vs interleaved differ by 1.3 %;
shifting the view (Y0 in fw/mandel.c, MB_Y0 in tools/golden.py) would show load imbalance
(open question).
