"""protocol.py - SPECTRA UART packets (board or simulator -> laptop), docs/PROTOCOL.md section 5.

Frame:  0xA5 | type | len (u16 LE) | payload[len] | crc8
crc8:   polynomial 0x07, init 0x00, over type, both len bytes and the payload.
All multi-byte fields are little-endian. Cycle stamps count from RUN_START.
"""
import struct

SYNC = 0xA5
BEGIN, FRAME, ROW, MROW, STATS = 1, 2, 3, 4, 5
MAZEFRAME = 6                                            # maze mode (PROTOCOL.md section 11)
MAZEMAP = 7
NAMES = {BEGIN: "BEGIN", FRAME: "FRAME", ROW: "ROW", MROW: "MROW", STATS: "STATS",
         MAZEFRAME: "MAZEFRAME", MAZEMAP: "MAZEMAP"}
LENGTHS = {BEGIN: 4, FRAME: 518, ROW: 199, MROW: 38, STATS: 68, MAZEFRAME: 332, MAZEMAP: 578}
PROGRAMS = ["gol", "mandel_halves", "mandel_interleaved", "matmul"]
COUNTERS = ["instret", "dhit", "dmiss", "ihit", "imiss", "arbwait", "barwait"]


def crc8(data):
    c = 0
    for b in data:
        c ^= b
        for _ in range(8):
            c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c


def encode(ptype, payload):
    body = bytes([ptype]) + struct.pack("<H", len(payload)) + payload
    return bytes([SYNC]) + body + bytes([crc8(body)])


def decode(ptype, p):
    """Payload bytes -> dict."""
    if ptype == BEGIN:
        cfg, n, prog = struct.unpack("<HBB", p)
        return {"type": "BEGIN", "config": cfg, "ncores": n, "program": PROGRAMS[prog & 3]}
    if ptype == FRAME:
        gen, cyc = struct.unpack_from("<HI", p)
        return {"type": "FRAME", "gen": gen, "cycle": cyc, "bits": p[6:518]}
    if ptype == ROW:
        core, row, cyc = struct.unpack_from("<BHI", p)
        return {"type": "ROW", "core": core, "row": row, "cycle": cyc, "data": p[7:199]}
    if ptype == MROW:
        core, row, cyc = struct.unpack_from("<BBI", p)
        return {"type": "MROW", "core": core, "row": row, "cycle": cyc, "data": p[6:38]}
    if ptype == STATS:
        cfg, n, prog, cyc, cs = struct.unpack_from("<HBBII", p)
        vals = struct.unpack_from("<14I", p, 12)
        cores = [dict(zip(COUNTERS, vals[7 * k:7 * k + 7])) for k in range(2)]
        return {"type": "STATS", "config": cfg, "ncores": n, "program": PROGRAMS[prog & 3],
                "cycles": cyc, "checksum": cs, "cores": cores}
    if ptype == MAZEFRAME:
        seq, ncols, cyc, x, y, a = struct.unpack_from("<BBIHHH", p)
        cols = [(p[12 + 2 * c], p[13 + 2 * c]) for c in range(ncols)]
        return {"type": "MAZEFRAME", "seq": seq, "ncols": ncols, "cycles": cyc,
                "x": x / 256.0, "y": y / 256.0, "angle": a, "cols": cols}
    if ptype == MAZEMAP:
        w, h = p[0], p[1]
        return {"type": "MAZEMAP", "w": w, "h": h, "cells": bytes(p[2:2 + w * h])}
    raise ValueError("unknown packet type %d" % ptype)


class Parser:
    """Feed raw bytes, get decoded packets. Bad CRC or unknown type: drop one byte, resync."""

    def __init__(self):
        self.buf = bytearray()
        self.dropped = 0

    def feed(self, data):
        self.buf += data
        out = []
        while True:
            i = self.buf.find(bytes([SYNC]))
            if i < 0:
                self.dropped += len(self.buf)
                self.buf.clear()
                break
            if i:
                self.dropped += i
                del self.buf[:i]
            if len(self.buf) < 4:
                break
            ptype = self.buf[1]
            n = struct.unpack_from("<H", self.buf, 2)[0]
            if ptype not in LENGTHS or LENGTHS[ptype] != n:
                self.dropped += 1
                del self.buf[0]
                continue
            if len(self.buf) < n + 5:
                break
            if crc8(self.buf[1:4 + n]) != self.buf[4 + n]:
                self.dropped += 1
                del self.buf[0]
                continue
            out.append(decode(ptype, bytes(self.buf[4:4 + n])))
            del self.buf[:n + 5]
        return out


def self_test():
    stats = struct.pack("<HBBII", 0x97, 2, 0, 1234, 0xDEADBEEF) + struct.pack("<14I", *range(14))
    pkts = [encode(BEGIN, struct.pack("<HBB", 0x97, 2, 0)), encode(STATS, stats)]
    stream = b"\x00\xA5\x09" + pkts[0] + pkts[1]
    bad = bytearray(pkts[1])
    bad[20] ^= 0xFF
    stream += bytes(bad) + pkts[0]
    p = Parser()
    got = []
    for i in range(0, len(stream), 7):                 # arrives in small pieces
        got += p.feed(stream[i:i + 7])
    assert [g["type"] for g in got] == ["BEGIN", "STATS", "BEGIN"], got
    assert got[1]["checksum"] == 0xDEADBEEF and got[1]["cores"][1]["instret"] == 7
    return True


if __name__ == "__main__":
    print("protocol self-test:", "PASS" if self_test() else "FAIL")
