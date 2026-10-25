"""run_matmul_dual.py - regression entry: tb/top/run.py demo 00f7 (the whole SoC, two cores,
MatMul: checksum, both harts' traces, every UART packet under the two-core rules and the C shadow
against rv32sim / golden.py; tb_top also writes dc_trace.txt for tb/top/check_counters.py)."""
import os
import sys

sys.argv = [sys.argv[0], "demo", "00f7"]
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run  # noqa: E402

run.main()
