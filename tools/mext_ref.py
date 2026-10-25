"""mext_ref.py - RISC-V M-extension reference (RV32), straight from the ISA manual.

Used by golden.py (t_mext checksum) and gen_vectors.py (MUL/DIV testbench vectors).
Division by zero and signed overflow follow the spec: no trap,
  x / 0 = -1 (all ones), x % 0 = x, INT_MIN / -1 = INT_MIN, INT_MIN % -1 = 0.
"""
M32 = 0xFFFFFFFF
INT_MIN = 0x80000000


def s32(x):
    x &= M32
    return x - (1 << 32) if x & 0x80000000 else x


def u32(x):
    return x & M32


def mul(a, b):
    return u32(s32(a) * s32(b))


def mulh(a, b):
    return u32((s32(a) * s32(b)) >> 32)


def mulhsu(a, b):
    return u32((s32(a) * u32(b)) >> 32)


def mulhu(a, b):
    return u32((u32(a) * u32(b)) >> 32)


def _trunc_div(a, b):
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q


def div(a, b):
    a, b = s32(a), s32(b)
    if b == 0:
        return M32
    if a == s32(INT_MIN) and b == -1:
        return INT_MIN
    return u32(_trunc_div(a, b))


def divu(a, b):
    a, b = u32(a), u32(b)
    return M32 if b == 0 else a // b


def rem(a, b):
    a, b = s32(a), s32(b)
    if b == 0:
        return u32(a)
    if a == s32(INT_MIN) and b == -1:
        return 0
    return u32(a - b * _trunc_div(a, b))


def remu(a, b):
    a, b = u32(a), u32(b)
    return a if b == 0 else a % b


OPS = {"mul": mul, "mulh": mulh, "mulhsu": mulhsu, "mulhu": mulhu,
       "div": div, "divu": divu, "rem": rem, "remu": remu}
ORDER = ["mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]

# funct3 encodings (opcode 0110011, funct7 0000001)
FUNCT3 = {"mul": 0, "mulh": 1, "mulhsu": 2, "mulhu": 3, "div": 4, "divu": 5, "rem": 6, "remu": 7}


def self_test():
    assert div(5, 0) == M32 and rem(5, 0) == 5
    assert divu(5, 0) == M32 and remu(5, 0) == 5
    assert div(INT_MIN, M32) == INT_MIN and rem(INT_MIN, M32) == 0
    assert div(u32(-7), 2) == u32(-3) and rem(u32(-7), 2) == u32(-1)
    assert div(7, u32(-2)) == u32(-3) and rem(7, u32(-2)) == 1
    assert mulh(M32, M32) == 0 and mul(M32, M32) == 1
    assert mulhu(M32, M32) == 0xFFFFFFFE
    assert mulhsu(M32, M32) == M32
    assert mulh(INT_MIN, INT_MIN) == 0x40000000
    return True


if __name__ == "__main__":
    print("mext_ref self-test:", "PASS" if self_test() else "FAIL")
