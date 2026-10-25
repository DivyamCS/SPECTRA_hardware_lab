"""spectra_host.py - SPECTRA laptop side: collects runs and serves the dashboard.

    python host/spectra_host.py                      dashboard only (simulated board available)
    python host/spectra_host.py --port COM5          + live runs from the board (needs pyserial)
    python host/spectra_host.py --sim 0x00f7         one simulator run, print a summary, exit
    python host/spectra_host.py --replay FILE [--source rtl|board]
                                                     load a UART stream (raw bytes, or one hex byte per
                                                     line as tb_top's uart_rtl.hex) as source "rtl" (RTL
                                                     simulation, default) or "board" (a recording of the
                                                     board's UART, e.g. scripts/board_regress.py's
                                                     board_uart.bin), print the runs, exit
    Options: --http 8000 (dashboard port), --baud 1000000, --runs DIR (default host/runs)

Open http://localhost:8000 . Every run (board or simulator) is saved as runs/<id>.json.
Runs from the board are marked "board"; runs from rv32sim are marked "sim" and their cycle
counts come from the simulator's approximate timing model, not from hardware; runs replayed
from an RTL simulation (tb_top) are marked "rtl": RTL cycle counts in xsim, not measurements.
"""
import base64
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "tools"))
import protocol  # noqa: E402

CLOCK_HZ = 50_000_000
LAT = [5, 6, 8, 10]
_golden = None
_glock = threading.Lock()


def golden_checksums():
    global _golden
    with _glock:
        if _golden is None:
            import golden
            _golden = {"gol": golden.gol_checksum(), "matmul": golden.mm_checksum()}
            mb = golden.mb_checksum()
            _golden["mandel_halves"] = _golden["mandel_interleaved"] = mb
        return _golden


def complete_gol(r):
    """The streamer skips a FRAME while the previous one is still on the UART, so with two cores the last
    generation's frame often never arrives. Step the last frame received to the final generation with the
    firmware's rule (tools/golden.py) and add it, marked "derived", only if its checksum equals the
    run's own STATS checksum: the picture then ends on the grid the board computed."""
    import golden
    fr, s = r.get("frames"), r.get("stats")
    if r.get("program") != "gol" or not fr or not s or fr[-1]["gen"] >= golden.GOL_GENS:
        return
    bits = base64.b64decode(fr[-1]["bits"])
    g = bytearray((bits[i >> 3] >> (i & 7)) & 1 for i in range(golden.GOL_W * golden.GOL_H))
    for _ in range(golden.GOL_GENS - fr[-1]["gen"]):
        g = golden.gol_step(g)
    if golden.fnv1a(bytes(g)) != s["checksum"]:
        return
    out = bytearray(len(bits))
    for i, v in enumerate(g):
        out[i >> 3] |= v << (i & 7)
    fr.append({"gen": golden.GOL_GENS, "cycle": s["cycles"], "bits": base64.b64encode(bytes(out)).decode(), "derived": True})


def describe(cfg):
    return {"fwd": cfg & 1, "dc": (cfg >> 1) & 1, "dual": (cfg >> 2) & 1, "L": LAT[(cfg >> 3) & 3],
            "program": protocol.PROGRAMS[(cfg >> 5) & 3], "ic": (cfg >> 7) & 1,
}


class Store:
    """All runs, plus the run currently arriving."""

    def __init__(self, folder):
        self.folder = folder
        os.makedirs(folder, exist_ok=True)
        self.lock = threading.Lock()
        self.runs = {}
        self.version = 0
        self.live = {}                     # source ("board" / "sim") -> run being received
        self.status = "idle"
        for f in sorted(os.listdir(folder)):
            if f.endswith(".json"):
                try:
                    r = json.load(open(os.path.join(folder, f)))
                    complete_gol(r)
                    self.runs[r["id"]] = r
                except (ValueError, KeyError):
                    pass

    def _new_id(self):
        return time.strftime("%Y%m%d-%H%M%S") + "-%03d" % (len(self.runs) % 1000)

    def _cut_off(self, source):
        """A new BEGIN while a run from this source is unfinished: BTNC cut that run off. It has no
        result and is never saved, so it leaves the list instead of showing "running" for ever."""
        r = self.live.pop(source, None)
        if r is not None:
            self.runs.pop(r["id"], None)

    def packet(self, pk, source):
        with self.lock:
            t = pk["type"]
            if t == "BEGIN":
                self._cut_off(source)
                rid = self._new_id()
                while rid in self.runs:
                    rid += "x"
                self.live[source] = {"id": rid, "source": source, "config": pk["config"], "ncores": pk["ncores"],
                             "program": pk["program"], "cfg": describe(pk["config"]), "frames": [], "rows": [],
                             "mrows": [], "stats": None, "created": time.strftime("%Y-%m-%d %H:%M:%S")}
                self.runs[rid] = self.live[source]
            elif source not in self.live:
                return
            elif t == "FRAME":
                self.live[source]["frames"].append({"gen": pk["gen"], "cycle": pk["cycle"],
                                            "bits": base64.b64encode(pk["bits"]).decode()})
            elif t in ("ROW", "MROW"):
                self.live[source]["rows" if t == "ROW" else "mrows"].append(
                    {"core": pk["core"], "row": pk["row"], "cycle": pk["cycle"],
                     "data": base64.b64encode(pk["data"]).decode()})
            elif t == "STATS":
                r = self.live.pop(source)
                r["stats"] = {k: pk[k] for k in ("cycles", "checksum", "cores")}
                gold = golden_checksums().get(r["program"])
                r["golden"] = gold
                r["ok"] = gold is not None and pk["checksum"] == gold
                r["seconds"] = pk["cycles"] / CLOCK_HZ
                complete_gol(r)
                with open(os.path.join(self.folder, r["id"] + ".json"), "w") as f:
                    json.dump(r, f)
            self.version += 1

    def summary(self):
        with self.lock:
            out = []
            for r in self.runs.values():
                s = r.get("stats")
                out.append({"id": r["id"], "source": r["source"], "config": r["config"], "cfg": r["cfg"],
                             "program": r["program"], "ncores": r["ncores"], "created": r["created"],
                             "done": s is not None, "cycles": s and s["cycles"], "ok": r.get("ok"),
                             "checksum": s and s["checksum"], "cores": s and s["cores"]})
            live = self.live.get("board") or self.live.get("sim")
            return {"version": self.version, "live": live and live["id"], "status": self.status,
                    "runs": sorted(out, key=lambda x: x["id"])}

    def delete(self, rid):
        with self.lock:
            if rid in self.runs and self.runs[rid].get("stats"):
                del self.runs[rid]
                p = os.path.join(self.folder, rid + ".json")
                if os.path.exists(p):
                    os.remove(p)
                self.version += 1


# ---------------- sources ----------------
def sim_binary():
    from simpath import find_sim
    return find_sim()


def run_sim(store, cfg, image="demo"):
    exe = sim_binary()
    img = os.path.join(ROOT, "fw", "build", image)
    if not os.path.exists(os.path.join(img, "imem.hex")):
        raise RuntimeError("firmware not built: run python fw/build.py")
    fd, path = tempfile.mkstemp(suffix=".bin")
    os.close(fd)
    try:
        r = subprocess.run([exe, "-c", "%04x" % cfg, "-u", path, img], capture_output=True, text=True)
        if r.returncode not in (0, 1):
            raise RuntimeError(r.stderr.strip() or "rv32sim failed")
        p = protocol.Parser()
        for pk in p.feed(open(path, "rb").read()):
            store.packet(pk, "sim")
    finally:
        os.remove(path)


def serial_reader(store, port, baud):
    import serial  # pyserial
    while True:
        try:
            with serial.Serial(port, baud, timeout=0.1) as s:
                store.status = "board connected on %s" % port
                p = protocol.Parser()
                while True:
                    data = s.read(4096)
                    if data:
                        for pk in p.feed(data):
                            store.packet(pk, "board")
        except Exception as e:  # unplugged, wrong port, ...
            store.status = "board: %s (retrying)" % e
            time.sleep(1.0)


# ---------------- HTTP ----------------
class Handler(BaseHTTPRequestHandler):
    store = None
    jobs = None

    def log_message(self, *a):
        pass

    def _json(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            b = open(os.path.join(HERE, "dashboard.html"), "rb").read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
        elif self.path == "/api/runs":
            self._json(self.store.summary())
        elif self.path.startswith("/api/run/"):
            r = self.store.runs.get(self.path[9:])
            self._json(r if r else {"error": "no such run"}, 200 if r else 404)
        else:
            self._json({"error": "not found"}, 404)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        if self.path == "/api/sim":
            cfgs = [int(c) for c in body.get("configs", [])][:64]
            self.jobs.extend(cfgs)
            self._json({"queued": len(cfgs)})
        elif self.path == "/api/delete":
            self.store.delete(body.get("id", ""))
            self._json({"ok": True})
        else:
            self._json({"error": "not found"}, 404)


def sim_worker(store, jobs):
    while True:
        if jobs:
            cfg = jobs.pop(0)
            store.status = "simulating config 0x%04x (%d more queued)" % (cfg, len(jobs))
            try:
                run_sim(store, cfg)
                store.status = "idle"
            except Exception as e:
                store.status = "simulator error: %s" % e
            store.version += 1
        else:
            time.sleep(0.1)


def main():
    a = sys.argv
    opt = lambda k, d=None: a[a.index(k) + 1] if k in a else d  # noqa: E731
    store = Store(opt("--runs", os.path.join(HERE, "runs")))
    if "--sim" in a:
        cfg = int(opt("--sim"), 16)
        run_sim(store, cfg)
        r = store.summary()["runs"][-1]
        cyc = r["cycles"]
        print("%s config=0x%04x cycles=%d (%.3f ms at 50 MHz) checksum=%08x %s" % (
            r["program"], cfg, cyc, cyc / CLOCK_HZ * 1e3, r["checksum"], "OK" if r["ok"] else "WRONG"))
        sys.exit(0 if r["ok"] else 1)
    if "--replay" in a:
        path = opt("--replay")
        raw = open(path, "rb").read()
        if path.endswith(".hex"):
            raw = bytes(int(x, 16) for x in raw.split())
        src = opt("--source", "rtl")
        if src not in ("rtl", "board"):
            sys.exit("--source must be rtl or board")
        p = protocol.Parser()
        before = set(store.runs)
        for pk in p.feed(raw):
            store.packet(pk, src)
        new = [r for r in store.summary()["runs"] if r["id"] not in before]
        for r in new:
            print("%s run %s: %s config=0x%04x cores=%d cycles=%s checksum=%s %s" % (
                src, r["id"], r["program"], r["config"], r["ncores"], r["cycles"],
                "%08x" % r["checksum"] if r["checksum"] is not None else "-",
                "OK" if r["ok"] else ("incomplete" if not r["done"] else "WRONG")))
        print("replay: %d bytes, %d dropped, %d run(s) saved to %s" % (len(raw), p.dropped, len(new), store.folder))
        sys.exit(0 if new and all(r["ok"] for r in new) and p.dropped == 0 else 1)
    if opt("--port"):
        threading.Thread(target=serial_reader, args=(store, opt("--port"), int(opt("--baud", "1000000"))),
                         daemon=True).start()
    jobs = []
    threading.Thread(target=sim_worker, args=(store, jobs), daemon=True).start()
    Handler.store, Handler.jobs = store, jobs
    port = int(opt("--http", "8000"))
    print("SPECTRA dashboard on http://localhost:%d  (Ctrl+C to stop)" % port)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
