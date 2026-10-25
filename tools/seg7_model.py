"""seg7_model.py - reference model of the 7-segment display (PROTOCOL.md section 3).

    python tools/seg7_model.py VALUE [DP_HEX [TXT_HEX]]   print what the 8 digits show
    python tools/seg7_model.py --check                     self-test

display(value, dp, txt) -> list of 8 (seg, dp_on) for digits 0 (rightmost) .. 7, where seg is
the 7-bit active-high pattern {g,f,e,d,c,b,a} (bit 0 = segment a = CA) or 0 for a blank digit.
Values above 99,999,999 are clamped. Blanking: leading zeros are blank, except digit 0 and
every digit at or right of the highest decimal point that is on (73 with dp 0x04 = "0.73").
txt (SEG7_TXT): nibble n = digit n; 0 shows the number's digit, 1-15 the letter GLYPH[code]
instead, always lit (PROTOCOL.md section 3).
"""
import sys

# segments a..g for 0-9 (bit 0 = a, ..., bit 6 = g)
SEG = [0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F]
# SEG7_TXT codes 1-15: C y I H d n P A r - 0 1 t E blank
GLYPH = [None, 0x39, 0x6E, 0x30, 0x76, 0x5E, 0x54, 0x73, 0x77, 0x50, 0x40, 0x3F, 0x06, 0x78, 0x79, 0x00]
GLYPH_CHARS = " CyIHdnPAr-01tE "


def display(value, dp, txt=0):
    value = min(value, 99999999)
    digits = [(value // 10 ** i) % 10 for i in range(8)]
    top = max([i for i in range(8) if digits[i]] + [0])
    dps = [i for i in range(8) if (dp >> i) & 1 and not (txt >> (4 * i)) & 15]   # a dp on a letter does not count
    keep = max([top] + dps)
    out = []
    for i in range(8):
        code = (txt >> (4 * i)) & 15
        seg = GLYPH[code] if code else (SEG[digits[i]] if i <= keep else 0)
        out.append((seg, bool((dp >> i) & 1)))
    return out


def text(value, dp, txt=0):
    cells = display(value, dp, txt)
    out = ""
    for i in reversed(range(8)):
        seg, d = cells[i]
        code = (txt >> (4 * i)) & 15
        ch = GLYPH_CHARS[code] if code else (str(SEG.index(seg)) if seg else " ")
        out += ch + ("." if d else "")
    return out


def self_test():
    assert text(0, 0) == "       0"
    assert text(73, 0x04) == "     0.73"
    assert text(99999999, 0) == "99999999"
    assert text(123456789, 0) == "99999999"
    assert text(1000, 0) == "    1000"
    assert text(5, 0x80) == "0.0000005"
    assert text(9998, 0x04, 0x34000000) == "IH  99.98"
    assert text(220, 0x04, 0x17300000) == "CPI  2.20"
    assert text(70337, 0, 0x12000000) == "Cy 70337"
    assert display(0, 0, 0xF0000000)[7][0] == 0
    assert text(368, 0x20, 0x56B00000) == "dn0.  368"
    assert text(9998, 0x24, 0x34C00000) == "IH1. 99.98"
    return True


if __name__ == "__main__":
    if sys.argv[1:] == ["--check"]:
        print("seg7_model self-test:", "PASS" if self_test() else "FAIL")
    elif len(sys.argv) in (2, 3, 4):
        print(repr(text(int(sys.argv[1]), int(sys.argv[2], 16) if len(sys.argv) > 2 else 0,
                        int(sys.argv[3], 16) if len(sys.argv) > 3 else 0)))
    else:
        sys.exit(__doc__)
