# Single-core results in simulation

Reads every tb_core_dc run under build/*/core_dc/<image>_<config>/xsim/xsim.log (for each image and config the newest run), and prints a Markdown table: run cycles and instructions inside RUN_START..RUN_STOP, CPI, D-cache hits, misses and hit rate. These are xsim cycle counts of the RTL (one core, ideal 2-cycle MMIO stub), not board measurements.

CONFIG bits: DC = bit 1, LAT = bits 4:3, PROGRAM = bits 6:5 (demo image);
FWD and IC are on in every row (bits 0 and 7); the D-cache is write-back with PLRU, the I-cache FIFO.

| Image / program | CONFIG | DC | L | Run cycles | Instructions | CPI | D hits | D misses | D hit rate |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Game of Life | 0091 | 0 | 8 | 193,211,983 | 46,847,217 | 4.124 | - | - | - |
| Game of Life | 0093 | 1 | 8 | 70,337,751 | 46,847,217 | 1.501 | 13,852,343 | 201,604 | 98.57 % |
| Mandelbrot halves | 00B1 | 0 | 8 | 12,434,873 | 7,612,643 | 1.633 | - | - | - |
| Mandelbrot halves | 00B3 | 1 | 8 | 12,224,499 | 7,612,643 | 1.606 | 25,923 | 1,730 | 93.74 % |
| Mandelbrot interleaved | 00D1 | 0 | 8 | 12,434,783 | 7,612,640 | 1.633 | - | - | - |
| Mandelbrot interleaved | 00D3 | 1 | 8 | 12,224,409 | 7,612,640 | 1.606 | 25,923 | 1,730 | 93.74 % |
| MatMul | 00E1 | 0 | 5 | 1,096,168 | 269,595 | 4.066 | - | - | - |
| MatMul | 00E3 | 1 | 5 | 526,715 | 269,595 | 1.954 | 96,888 | 2,444 | 97.54 % |
| MatMul | 00E9 | 0 | 6 | 1,195,512 | 269,595 | 4.434 | - | - | - |
| MatMul | 00EB | 1 | 6 | 529,676 | 269,595 | 1.965 | 96,888 | 2,444 | 97.54 % |
| MatMul | 00F1 | 0 | 8 | 1,394,200 | 269,595 | 5.171 | - | - | - |
| MatMul | 00F3 | 1 | 8 | 535,598 | 269,595 | 1.987 | 96,888 | 2,444 | 97.54 % |
| MatMul | 00F9 | 0 | 10 | 1,592,888 | 269,595 | 5.908 | - | - | - |
| MatMul | 00FB | 1 | 10 | 541,520 | 269,595 | 2.009 | 96,888 | 2,444 | 97.54 % |
| t_barrier | 0081 | 0 | 5 | 14,695 | 4,533 | 3.242 | - | - | - |
| t_barrier | 0083 | 1 | 5 | 8,695 | 4,533 | 1.918 | 1,002 | 2 | 99.80 % |
| t_barrier | 0089 | 0 | 6 | 15,713 | 4,533 | 3.466 | - | - | - |
| t_barrier | 008B | 1 | 6 | 8,712 | 4,533 | 1.922 | 1,002 | 2 | 99.80 % |
| t_barrier | 0091 | 0 | 8 | 17,749 | 4,533 | 3.916 | - | - | - |
| t_barrier | 0093 | 1 | 8 | 8,746 | 4,533 | 1.929 | 1,002 | 2 | 99.80 % |
| t_barrier | 0099 | 0 | 10 | 19,785 | 4,533 | 4.365 | - | - | - |
| t_barrier | 009B | 1 | 10 | 8,780 | 4,533 | 1.937 | 1,002 | 2 | 99.80 % |
| t_cache | 0081 | 0 | 5 | 162,817 | 54,464 | 2.989 | - | - | - |
| t_cache | 0083 | 1 | 5 | 127,056 | 54,464 | 2.333 | 8,947 | 2,266 | 79.79 % |
| t_cache | 0089 | 0 | 6 | 174,059 | 54,464 | 3.196 | - | - | - |
| t_cache | 008B | 1 | 6 | 130,589 | 54,464 | 2.398 | 8,947 | 2,266 | 79.79 % |
| t_cache | 0091 | 0 | 8 | 196,543 | 54,464 | 3.609 | - | - | - |
| t_cache | 0093 | 1 | 8 | 137,655 | 54,464 | 2.527 | 8,947 | 2,266 | 79.79 % |
| t_cache | 0099 | 0 | 10 | 219,027 | 54,464 | 4.022 | - | - | - |
| t_cache | 009B | 1 | 10 | 144,721 | 54,464 | 2.657 | 8,947 | 2,266 | 79.79 % |
| t_hazard | 0081 | 0 | 5 | 1,921 | 423 | 4.541 | - | - | - |
| t_hazard | 0083 | 1 | 5 | 1,831 | 423 | 4.329 | 18 | 2 | 90.00 % |
| t_hazard | 0089 | 0 | 6 | 2,076 | 423 | 4.908 | - | - | - |
| t_hazard | 008B | 1 | 6 | 1,970 | 423 | 4.657 | 18 | 2 | 90.00 % |
| t_hazard | 0091 | 0 | 8 | 2,386 | 423 | 5.641 | - | - | - |
| t_hazard | 0093 | 1 | 8 | 2,248 | 423 | 5.314 | 18 | 2 | 90.00 % |
| t_hazard | 0099 | 0 | 10 | 2,696 | 423 | 6.374 | - | - | - |
| t_hazard | 009B | 1 | 10 | 2,526 | 423 | 5.972 | 18 | 2 | 90.00 % |
| t_lock | 0081 | 0 | 5 | 430,151 | 170,024 | 2.530 | - | - | - |
| t_lock | 0083 | 1 | 5 | 310,148 | 170,024 | 1.824 | 20,001 | 1 | 100.00 % |
| t_lock | 0089 | 0 | 6 | 450,165 | 170,024 | 2.648 | - | - | - |
| t_lock | 008B | 1 | 6 | 310,161 | 170,024 | 1.824 | 20,001 | 1 | 100.00 % |
| t_lock | 0091 | 0 | 8 | 490,193 | 170,024 | 2.883 | - | - | - |
| t_lock | 0093 | 1 | 8 | 310,187 | 170,024 | 1.824 | 20,001 | 1 | 100.00 % |
| t_lock | 0099 | 0 | 10 | 530,221 | 170,024 | 3.119 | - | - | - |
| t_lock | 009B | 1 | 10 | 310,213 | 170,024 | 1.825 | 20,001 | 1 | 100.00 % |
| t_mext | 0081 | 0 | 5 | 257,440 | 45,151 | 5.702 | - | - | - |
| t_mext | 0083 | 1 | 5 | 241,412 | 45,151 | 5.347 | 2,675 | 4 | 99.85 % |
| t_mext | 0089 | 0 | 6 | 260,136 | 45,151 | 5.761 | - | - | - |
| t_mext | 008B | 1 | 6 | 241,435 | 45,151 | 5.347 | 2,675 | 4 | 99.85 % |
| t_mext | 0091 | 0 | 8 | 265,528 | 45,151 | 5.881 | - | - | - |
| t_mext | 0093 | 1 | 8 | 241,481 | 45,151 | 5.348 | 2,675 | 4 | 99.85 % |
| t_mext | 0099 | 0 | 10 | 270,920 | 45,151 | 6.000 | - | - | - |
| t_mext | 009B | 1 | 10 | 241,527 | 45,151 | 5.349 | 2,675 | 4 | 99.85 % |

54 runs. Recorded before the I-cache moved to FIFO and the D-cache to the write-back-only design; the current RTL gives the same cycles and hit / miss counts (rv32sim for the I-cache, the cycle-exact D-cache tests against tools/cache_model.py for the D-cache). Every one gave rv32sim's checksum (golden OK) with 0 trace differences (docs/results/merge3.md).
