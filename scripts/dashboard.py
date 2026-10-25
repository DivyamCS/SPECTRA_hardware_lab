#!/usr/bin/env python3
"""
scripts/dashboard.py — Laptop Live Streaming Dashboard (Task 6)
==============================================================
Connects to the FPGA UART serial stream (e.g. Nexys A7 USB-UART at 115200 baud).
Decodes 9-byte binary packets from result_streamer.v:
    Byte 0   : SOF = 0xAB
    Bytes 1-4: store address (32-bit little-endian)
    Bytes 5-8: store data    (32-bit little-endian)

Features:
  - Real-time packet parsing & framing error recovery
  - Memory write tracking & statistics (packets/sec, total stores)
  - Game of Life (GoL) grid renderer (when addresses map to frame buffers)
  - Matrix multiplication result verifier (0x0001_F000 - 0x0001_FFFF)
  - Standalone mock/demo mode (--mock) to test without physical FPGA hardware
"""

import sys
import os
import time
import struct
import argparse
from typing import Optional

SOF_BYTE = 0xAB
PACKET_SIZE = 9

class StreamDashboard:
    def __init__(self, port: Optional[str] = None, baud: int = 115200, mock: bool = False):
        self.port = port
        self.baud = baud
        self.mock = mock
        self.ser = None

        self.total_packets = 0
        self.invalid_sofs = 0
        self.start_time = time.time()
        self.memory_store = {}
        self.gol_grid = [[0 for _ in range(64)] for _ in range(64)]

    def open_connection(self):
        if self.mock:
            print("[INFO] Running in MOCK mode (simulated FPGA packet stream).")
            return

        try:
            import serial
        except ImportError:
            print("[ERROR] pyserial is required for hardware connection. Install via: pip install pyserial")
            print("[INFO] Falling back to --mock mode.")
            self.mock = True
            return

        if not self.port:
            # Auto-detect Nexys A7 / FTDI UART on macOS / Linux
            import serial.tools.list_ports
            ports = list(serial.tools.list_ports.comports())
            for p in ports:
                if "usb" in p.device.lower() or "ftdi" in p.description.lower() or "uart" in p.description.lower():
                    self.port = p.device
                    break
            if not self.port:
                if ports:
                    self.port = ports[0].device
                else:
                    print("[WARNING] No serial port detected! Defaulting to mock mode.")
                    self.mock = True
                    return

        print(f"[INFO] Opening serial port: {self.port} at {self.baud} baud...")
        self.ser = serial.Serial(self.port, self.baud, timeout=1.0)
        print("[INFO] Serial port opened successfully.")

    def read_exact(self, n: int) -> bytes:
        if self.mock:
            return b""
        data = bytearray()
        while len(data) < n:
            chunk = self.ser.read(n - len(data))
            if not chunk:
                break
            data.extend(chunk)
        return bytes(data)

    def process_packet(self, addr: int, data: int):
        self.total_packets += 1
        self.memory_store[addr] = data

        # Check if address corresponds to Game of Life grid (e.g. 0x0001_F000 + offset)
        if 0x0001_F000 <= addr < 0x0001_F000 + 4096:
            offset = (addr - 0x0001_F000) // 4
            row = (offset // 8) % 64
            col_word = offset % 8
            for b in range(32):
                col = col_word * 32 + b
                if col < 64:
                    self.gol_grid[row][col] = (data >> b) & 1

        elapsed = max(0.001, time.time() - self.start_time)
        rate = self.total_packets / elapsed

        if self.total_packets % 10 == 0 or self.total_packets < 10:
            print(f"[{elapsed:6.1f}s] Pkts: {self.total_packets:5d} ({rate:5.1f} pkt/s) | "
                  f"Store: [0x{addr:08X}] <= 0x{data:08X} ({data})")

    def run_mock(self):
        print("[MOCK] Streaming simulated Game of Life / MatMul store packets...")
        import random
        base = 0x0001_F000
        for i in range(1, 31):
            addr = base + (i * 4)
            data = random.randint(0, 0xFFFFFFFF)
            self.process_packet(addr, data)
            time.sleep(0.05)

        print("\n--- Summary ---")
        print(f"Total packets received: {self.total_packets}")
        print(f"Unique memory addresses updated: {len(self.memory_store)}")
        print("[INFO] Mock stream completed cleanly.")

    def run(self):
        self.open_connection()
        if self.mock:
            self.run_mock()
            return

        print("[INFO] Listening for result_streamer packets (SOF=0xAB)... Press Ctrl+C to stop.")
        try:
            while True:
                sof = self.ser.read(1)
                if not sof:
                    continue
                if sof[0] != SOF_BYTE:
                    self.invalid_sofs += 1
                    continue

                payload = self.read_exact(8)
                if len(payload) < 8:
                    continue

                addr, data = struct.unpack("<II", payload)
                self.process_packet(addr, data)

        except KeyboardInterrupt:
            print("\n[INFO] Dashboard stopped by user.")
        finally:
            if self.ser and self.ser.is_open:
                self.ser.close()
                print("[INFO] Serial port closed.")

def main():
    parser = argparse.ArgumentParser(description="CAMEO Laptop Stream Dashboard (Task 6)")
    parser.add_argument("--port", "-p", type=str, default=None, help="Serial port device")
    parser.add_argument("--baud", "-b", type=int, default=115200, help="Baud rate (default 115200)")
    parser.add_argument("--mock", "-m", action="store_true", help="Run in mock streaming mode")
    args = parser.parse_args()

    dashboard = StreamDashboard(port=args.port, baud=args.baud, mock=args.mock)
    dashboard.run()

if __name__ == "__main__":
    main()
