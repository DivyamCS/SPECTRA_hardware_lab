"""make.py - writes tb/dmem_init/dmem.hex for tb_dmem_bram: 8,192 words, word i =
(i * 0x9E3779B9) xor 0x5A5A0000 xor i, so no word is 0 and every word differs. The firmware
images' dmem.hex files are all zero (no initialised data), which would not test loading."""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, "dmem.hex"), "w", newline="\n") as f:
    for i in range(8192):
        f.write("%08x\n" % (((i * 0x9E3779B9) ^ 0x5A5A0000 ^ i) & 0xFFFFFFFF))
