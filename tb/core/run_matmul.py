"""run_matmul.py - regression entry: tb/core/run.py demo 00f3 00f2 (MatMul, one core, FWD = 1, FWD = 0 and IC = 0). Game of Life and Mandelbrot take 3-20 minutes each in xsim, so they are
not run on every check_all."""
import os
import sys

sys.argv = [sys.argv[0], "demo", "00f3", "00f2", "0073"]
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run  # noqa: E402

run.main()
