"""uart_packets.py - capture the board's UART for a while and list the SPECTRA packets in it.

    python host/uart_packets.py --port COM8 [--seconds 5] [--expect BEGIN [STATS ...]] [--out FILE]

Reads at 1,000,000 baud for the given time (start it before the board sends: the port is opened
first), splits the bytes into packets (0xA5 | type | len | payload | crc8, PROTOCOL.md section 5)
and prints one line per packet with its decoded fields. Exit status 0 only if every packet has
a valid CRC and every --expect type was seen. --out saves the raw bytes.
"""
import argparse
import os
import sys
import time

import serial

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import protocol  # noqa: E402


def split(data):
    out, bad, i = [], 0, 0
    while i + 5 <= len(data):
        if data[i] != protocol.SYNC:
            i += 1
            bad += 1
            continue
        t, n = data[i + 1], data[i + 2] | (data[i + 3] << 8)
        if i + 5 + n > len(data):
            break
        ok = protocol.crc8(data[i + 1:i + 4 + n]) == data[i + 4 + n]
        out.append((t, bytes(data[i + 4:i + 4 + n]), ok))
        i += 5 + n
    return out, bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--seconds", type=float, default=5.0)
    ap.add_argument("--expect", nargs="*", default=[])
    ap.add_argument("--out")
    a = ap.parse_args()
    s = serial.Serial(a.port, 1000000, timeout=0.2)
    if hasattr(s, "set_buffer_size"):
        s.set_buffer_size(rx_size=1 << 20)
    s.reset_input_buffer()
    data = bytearray()
    t_end = time.time() + a.seconds
    while time.time() < t_end:
        data += s.read(65536)
    s.close()
    if a.out:
        open(a.out, "wb").write(data)
    pk, skipped = split(data)
    seen = set()
    for t, p, ok in pk:
        name = protocol.NAMES.get(t, "type%d" % t)
        seen.add(name)
        try:
            fields = protocol.decode(t, p)
        except Exception as e:                       # malformed payload
            fields = "undecodable: %s" % e
        print("%-6s len %4d crc %s  %s" % (name, len(p), "ok " if ok else "BAD", str(fields)[:150]))
    bad = sum(1 for _, _, ok in pk if not ok)
    missing = [e for e in a.expect if e not in seen]
    print("uart_packets: %d bytes, %d packets, %d CRC errors, %d bytes outside packets%s" % (
        len(data), len(pk), bad, skipped, (", missing " + " ".join(missing)) if missing else ""))
    sys.exit(1 if bad or missing else 0)


if __name__ == "__main__":
    main()
