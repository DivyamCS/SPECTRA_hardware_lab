"""check_all.py - the one gate before every commit.

    python scripts/check_all.py

Runs tests/run_all.py (software checks), tools/check_maps.py (spec = header) and
scripts/regress.py (every RTL testbench in sim/tests.txt). Exit 0 only if all pass.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
steps = [["tests/run_all.py"], ["tools/check_maps.py"]]
if os.path.exists(os.path.join(ROOT, "scripts", "regress.py")):
    steps.append(["scripts/regress.py"])
failed = []
for s in steps:
    print("==", " ".join(s))
    r = subprocess.run([sys.executable] + [os.path.join(ROOT, s[0])] + s[1:], cwd=ROOT)
    if r.returncode:
        failed.append(s[0])
print("\ncheck_all:", "PASS" if not failed else "FAIL (" + ", ".join(failed) + ")")
sys.exit(1 if failed else 0)
