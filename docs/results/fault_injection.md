# Fault injection on the simulated board

rv32sim's `-F` faults inject the three pipeline bugs the tests must catch, between RUN_START and
RUN_STOP: `stale1` (no forwarding), `stale2` (register file not write-through), `nosquash` (the
instruction after a taken branch executes). Cycle cap `-n 50000000`.
"Caught" = the run does not end with the golden result.

| Image (CONFIG) | No fault | stale1 | stale2 | nosquash |
| --- | --- | --- | --- | --- |
| t_hazard (0x0093) | golden | caught (cycle limit) | caught (cycle limit) | caught (illegal instruction) |
| t_mext (0x0093) | golden | caught (fetch outside IMEM) | caught (misaligned store) | caught (wrong checksum) |
| t_cache (0x0093) | golden | caught (misaligned store) | caught (misaligned store) | caught (cycle limit) |
| t_lock (0x0097, 2 cores) | golden | caught (fetch outside IMEM) | caught (misaligned load) | **not caught** |
| t_barrier (0x0097, 2 cores) | golden | caught (misaligned load) | caught (misaligned load) | **not caught** |

The check (run_all.py section 10: t_hazard, t_mext and t_cache each fail under every
fault) passes: "caught by 3 of 3 images" for all three faults in every check_all run.

t_lock and t_barrier survive `nosquash`: the instructions behind their taken branches happen to
be harmless when executed. They test the lock and the barrier, not the squash; squash coverage
comes from t_hazard, where `nosquash` fails checks 19, 21, 24 and 26 (taken branch, branch on a
computed value, JAL, JALR).

Per-check result on t_hazard (which CHECK failure paths executed):

| Fault | Failed checks |
| --- | --- |
| none | none |
| stale1 | not observable: the suite's own code is corrupted before check 1 (cycle limit at pc 0x74) |
| stale2 | 2, 4, 7, 8, 9, 10, 11, 12, 13, 14, 15, 17, 21, 23 |
| nosquash | 19, 21, 24, 26 (then an illegal instruction) |
