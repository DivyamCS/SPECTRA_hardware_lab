"""run_matmul.py - regression entry: tb/top/run.py demo 00f3 (the whole SoC, one core, MatMul:
checksum, trace, every UART packet and the C shadow against rv32sim / golden.py)."""
import os
import sys

sys.argv = [sys.argv[0], "demo", "00f3"]
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run  # noqa: E402

run.main()
