# seg7_bcd (spec v1.1)

| Item | Value |
| --- | --- |
| File | rtl/io/seg7_bcd.v |
| Testbench | tb/tb_seg7_bcd.v |
| Vectors | 0, 9, 10, 99,999,999 and 1,000 random values; expected digits and blanking from a Python model |
| Interfaces | none (driven by mmio_bus SEG7 / SEG7_DP) |
| Removal parameter | none |

## Purpose
Shows a number 0-99,999,999 in decimal on the eight 7-segment digits, with leading-zero blanking
and decimal points.

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 each | |
| `value` | in | 27 | binary value (values above 99,999,999 are clamped to it) |
| `dp` | in | 8 | decimal-point mask, bit n = digit n (0 = rightmost) |
| `an` | out | 8 | digit enables, active low (Nexys A7) |
| `seg` | out | 7 | segments CA-CG, active low |
| `dp_n` | out | 1 | decimal point, active low |

## Behaviour
1. Binary to 8 BCD digits with a sequential double-dabble (one bit per cycle, 27 cycles), started
   whenever `value` changes; the display keeps the previous digits until the conversion ends.
2. Digits are multiplexed one at a time, each lit for 2^13 cycles (164 us), so every digit is
   refreshed at 763 Hz (target: about 1 kHz per digit).
3. Blanking (PROTOCOL.md section 3): leading zeros are blank, except digit 0 and every digit at
   or right of the highest decimal point that is on (73 with dp = 0x04 shows "0.73").

## Reset values
All digits blank, conversion idle.

## Tests
The listed values: BCD digits, blanking and decimal points against the Python model; scan
order and period. PASS = 0 mismatches. Board check: the switch value is readable.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version |
| 1.1 | 17 Oct 2026 | Input `txt` (SEG7_TXT): per digit, 0 = the number's digit, 1-15 = a letter (C y I H d n P A r - 0 1 t E blank), always lit; a decimal point on a letter does not change the blanking. tools/seg7_model.py and tb/seg7/run.py cover every code on every digit. For the labelled 7-segment tour (labels such as IH 99.98) |
