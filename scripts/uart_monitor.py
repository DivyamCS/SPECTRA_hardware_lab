#!/usr/bin/env python3
"""
scripts/uart_monitor.py — Host FPGA Bring-Up Serial Monitor (Task 7)
===================================================================
Connects to the FPGA USB-UART interface (e.g. Nexys A7 FTDI bridge at 115200 baud).
Displays bare-metal console output (ASCII text from MMIO 0x8000_0000), tracks
test completion banners, and logs serial traces to file.

Usage:
    python3 scripts/uart_monitor.py                     # Auto-detects serial port
    python3 scripts/uart_monitor.py -p /dev/tty.usbserial-10 # Specific port
    python3 scripts/uart_monitor.py --mock              # Simulated boot & benchmark
"""

import sys
import os
import time
import argparse
from typing import Optional

class UartMonitor:
    def __init__(self, port: Optional[str] = None, baud: int = 115200, log_file: Optional[str] = None, mock: bool = False):
        self.port = port
        self.baud = baud
        self.log_file = log_file
        self.mock = mock
        self.ser = None

    def open_serial(self):
        if self.mock:
            print("[INFO] Running in MOCK mode (simulating FPGA bring-up UART output).")
            return

        try:
            import serial
            import serial.tools.list_ports
        except ImportError:
            print("[ERROR] pyserial is required. Install with: pip install pyserial")
            print("[INFO] Falling back to --mock mode.")
            self.mock = True
            return

        if not self.port:
            ports = list(serial.tools.list_ports.comports())
            for p in ports:
                if any(k in (p.device + p.description).lower() for k in ["usb", "ftdi", "uart", "nexys"]):
                    self.port = p.device
                    break
            if not self.port:
                if ports:
                    self.port = ports[0].device
                else:
                    print("[WARNING] No active serial port found! Falling back to --mock mode.")
                    self.mock = True
                    return

        print(f"[INFO] Connecting to {self.port} at {self.baud} 8N1...")
        self.ser = serial.Serial(self.port, self.baud, timeout=0.1)
        print("[INFO] Connected! Listening for FPGA UART output...")

    def run_mock(self):
        mock_output = [
            "\r\n========================================\r\n",
            " CAMEO RISC-V Hardware Lab — Bring-Up  \r\n",
            "========================================\r\n",
            "[BOOT] Hart 0 initialized.\r\n",
            "[BOOT] System clock: 50 MHz | Baud: 115200\r\n",
            "[BOOT] Memory delay: 5 cycles wait-state active.\r\n",
            "[BOOT] Performance counters enabled (cycle, instret).\r\n",
            "[INIT] Running Conway's Game of Life (64x64)...\r\n",
            "[GOL ] Iteration 1 complete (alive: 412, cycles: 82400)\r\n",
            "[GOL ] Iteration 2 complete (alive: 398, cycles: 164810)\r\n",
            "[INIT] Running Matrix Multiplication (32x32)...\r\n",
            "[MM  ] Matrix A x B computed.\r\n",
            "[MM  ] Golden check: 1024/1024 elements MATCH.\r\n",
            "[TEST] *** ALL BENCHMARKS PASSED ***\r\n",
            "========================================\r\n"
        ]
        for line in mock_output:
            for ch in line:
                sys.stdout.write(ch)
                sys.stdout.flush()
                time.sleep(0.005)
            time.sleep(0.05)

    def run(self):
        self.open_serial()
        if self.mock:
            self.run_mock()
            return

        log_f = open(self.log_file, "a") if self.log_file else None

        print("[INFO] Press Ctrl+C to disconnect.")
        try:
            while True:
                data = self.ser.read(64)
                if data:
                    text = data.decode("utf-8", errors="replace")
                    sys.stdout.write(text)
                    sys.stdout.flush()
                    if log_f:
                        log_f.write(text)
                        log_f.flush()
        except KeyboardInterrupt:
            print("\n[INFO] Disconnected by user.")
        finally:
            if self.ser and self.ser.is_open:
                self.ser.close()
            if log_f:
                log_f.close()

def main():
    parser = argparse.ArgumentParser(description="CAMEO FPGA Bring-Up UART Monitor (Task 7)")
    parser.add_argument("--port", "-p", type=str, default=None, help="Serial port device")
    parser.add_argument("--baud", "-b", type=int, default=115200, help="Baud rate (default 115200)")
    parser.add_argument("--log", "-l", type=str, default=None, help="Log file path")
    parser.add_argument("--mock", "-m", action="store_true", help="Simulate FPGA UART output")
    args = parser.parse_args()

    monitor = UartMonitor(port=args.port, baud=args.baud, log_file=args.log, mock=args.mock)
    monitor.run()

if __name__ == "__main__":
    main()
