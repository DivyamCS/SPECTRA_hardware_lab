# Fallback kit for the demo

What to do on the day if something fails. Every command runs from the repository root
(`C:\fpga\spectra`, or a copy of it on another laptop). Tested: tests/run_all.py section 11
replays the board recording and serves it from the dashboard with no board connected.

## On the USB stick (Divyam copies these; nothing else is needed)

| File | Why |
| --- | --- |
| `build/releases/fpga-v1/top_fpga.bit` | the release bitstream (tag fpga-v1): demo firmware, 7-segment tour |
| `build/releases/fpga-v1/top_fpga.ltx` | VIO probes (only for scripts/board.tcl) |
| `build/releases/fpga-v1/board/demo_uart.bin` | a recording of the board's UART: all 51 demo and latency runs (2.9 MB) |
| `backups/spectra_s2*.bundle` (newest) | the whole repository: `git clone spectra_s2x.bundle spectra` on any laptop |
| `docs/demo_script.md`, `docs/results/numbers.md` | the script and the measured numbers |

The laptop needs Python 3.9+ (standard library only; `pyserial` only for a live board) and, to
program the board, Vivado or Vivado Lab Edition (free).

## Case 1: the board lost its configuration (power cycled)

Since 17 Oct the demo is in the board's QSPI flash (JP1 on QSPI): after power-on the board loads
it by itself in about a second (DONE LED on). Only if that fails, or JP1 is on JTAG, program it
from the laptop:

```bash
vivado -mode batch -nojournal -nolog -notrace -source scripts/program.tcl -tclargs build/releases/fpga-v1/top_fpga.bit
```

or in Vivado's Hardware Manager: Open Target, Auto Connect, Program Device, choose
`top_fpga.bit`. The board then boots once on its switches; press BTNC to start a run.

## Case 2: the board works, the laptop link does not

The board needs no laptop: set the switches, press BTNC, and the 7-segment display tours the
results (cycles, I-cache and D-cache hit %, CPI; LED1 = checksum golden). Run the script from the
display alone. If the COM port changed, find it in Device Manager (USB Serial Port) and start
`python host/spectra_host.py --port COMn`.

## Case 3: no board at all

Show the recorded board runs in the dashboard, offline:

```bash
python host/spectra_host.py --replay build/releases/fpga-v1/board/demo_uart.bin --source board --runs host/runs_fallback
```

```bash
python host/spectra_host.py --runs host/runs_fallback
```

Open http://localhost:8000: the runs are marked "board" (they are the board's own bytes). The
Compare tab plays any of them side by side (Pick latest of each config, then Play); the Live tab
replays one at a chosen speed. The Simulate tab still runs the simulated board.

## Case 4: no Vivado on the laptop

Programming needs Vivado (Case 1). Everything else (dashboard, replay, simulator) is Python only.

## The demo in the QSPI flash: power-on without a laptop (programmed 17 Oct, Divyam's go-ahead)

The board loads the demo from its QSPI flash at every power-on: switches, BTNC and the 7-segment
tour work with no laptop at all. Programmed and verified on 17 Oct (flash/program_flash.log); with
JP1 on QSPI the board booted from it (DONE = 1 over JTAG, nothing programmed) and the flash-booted
design passed all 51 demo and latency settings (identical 2,904,746 UART bytes) and the 7-segment
tour and browser checks (flash/boot_check/).

Prepared and checked (17 Oct):
* `build/releases/fpga-v1/flash/top_fpga.mcs` (+ `.prm`): the fpga-v1 design with the demo
  program, made by `python scripts/updatemem.py swap build/releases/fpga-v1/post_route.dcp
  fw/build/demo build/releases/fpga-v1/flash --flash` (SPI x4 at 33 MHz, compressed: 2.0 MB;
  write_cfgmem for the 16 MB S25FL128S, image at 0x000000-0x1E1DFB, 0 errors, 0 warnings);
* that same bitstream loaded over JTAG (not the flash) passed 8 settings on the board (all four
  programs, 1 and 2 cores: golden, packets = the reference; flash/check/board_regress.csv).

To program the flash again (e.g. with a new release; about 1-2 minutes, the board on USB):

```bash
vivado -mode batch -nojournal -nolog -notrace -source scripts/program_flash.tcl -tclargs build/releases/fpga-v1/flash/top_fpga.mcs --yes-program-the-flash
```

It erases the image's range, programs, verifies, then reboots the FPGA from the flash. For
power-on boot set the mode jumper **JP1 to QSPI**. JTAG programming (Case 1) still works at any
time and overrides the flash until the next power-on; to change the flash, run the script with
another image.
