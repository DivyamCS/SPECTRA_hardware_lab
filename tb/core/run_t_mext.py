"""run_t_mext.py - regression entry: tb/core/run.py t_mext 0093 0092 0013, FWD = 1 and 0, IC = 0."""
import os
import sys

sys.argv = [sys.argv[0], "t_mext"] + "0093 0092 0013".split()
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run  # noqa: E402

run.main()
