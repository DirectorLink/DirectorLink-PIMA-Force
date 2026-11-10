#!/usr/bin/env python3
"""Read-only test listener for a real PIMA FORCE panel (JSON interface).

Plays the Control4 driver's side of the link without Control4: listens for
the panel's CMS connection, ACKs every EVENT / DATA / null frame exactly like
the driver (kc:1, numeric account) and, when a user code is given, reads
zone count, exit time, partition state, zone status, zone names, outputs and
faults. It never arms, disarms, bypasses or switches outputs.

    python tools/force_probe.py                     # just listen and ACK
    python tools/force_probe.py --code 1234         # also read panel data
    PIMA_CODE=1234 python tools/force_probe.py      # same, code kept out of the command line

Point a panel CMS network path at this PC (IP of this PC, port 7780,
Protocol = JSON, encryption off). Every byte in both directions is written to
the capture file (user code redacted). Python 3 standard library only.
"""
import argparse
import json
import os
import queue
import socket
import sys
import threading
import time

ACK_GAP, WRITE_GAP, TIMEOUT = 0.10, 0.25, 8.0
KEY_NAMES = {1: "not defined", 2: "disarmed", 3: "armed Away", 4: "armed Home", 5: "armed Night",
             6: "armed Home 3", 7: "armed Home 4", 8: "armed Shabbat", 9: "armed Shabbat"}
ZONE_BITS = {0: "supervision", 1: "low battery", 2: "short", 3: "tamper", 4: "soak", 5: "chime",
             6: "anti-mask", 7: "bypassed", 8: "auto-bypassed", 9: "ALARM", 10: "armed", 11: "open",
             12: "duress", 13: "fire", 14: "medical", 15: "panic"}
FAULTS = {1: "AC loss", 2: "Low battery", 3: "Panel tamper 1", 4: "Panel tamper 2", 5: "Aux voltage",
          6: "PSTN fault (DC)", 7: "PSTN fault (dial tone)", 8: "Panel low DC", 24: "Keypad fault",
          25: "Keypad tamper", 30: "Station PSTN comm", 31: "Station GPRS", 32: "Station GSM voice",
          33: "Station network comm", 39: "GSM transmitter", 42: "GSM SIM 1", 50: "GSM no SIM 1",
          57: "Network", 60: "Zone tamper", 62: "Wireless zone loss", 64: "Wireless zone low battery",
          67: "External siren", 68: "Internal siren", 69: "Time not set"}
CID = {100: "Medical", 110: "Fire", 120: "Panic", 121: "Duress", 130: "Burglary", 137: "Panel tamper",
       301: "AC loss", 302: "Low battery", 305: "Power-up", 306: "Programming changed",
       350: "CMS comm trouble", 400: "Arm/disarm (master)", 401: "Arm/disarm (user)",
       403: "Auto arm", 407: "Arm/disarm (remote)", 408: "Fast arm", 441: "Home arm",
       570: "Zone bypass", 602: "Periodic test", 625: "Time changed", 760: "Zone open/close",
       770: "Output on/off"}


def text_of(raw):
    """Panel bytes -> str: UTF-8 if valid, otherwise Windows-1255 (Hebrew)."""
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("cp1255", errors="replace")


def split_frames(buf):
    """Top-level JSON objects from a byte buffer. Returns frames, rest, residue."""
    buf = buf.replace(b"\0", b"")
    frames, residue = [], bytearray()
    depth, start, in_str, esc, consumed = 0, None, False, False, 0
    for i, c in enumerate(buf):
        if start is None:
            if c == 0x7B:  # {
                start, depth, in_str, esc = i, 1, False, False
            else:
                if c not in b" \t\r\n":
                    residue.append(c)
                consumed = i + 1
        elif in_str:
            if esc:
                esc = False
            elif c == 0x5C:
                esc = True
            elif c == 0x22:
                in_str = False
        elif c == 0x22:
            in_str = True
        elif c == 0x7B:
            depth += 1
        elif c == 0x7D:
            depth -= 1
            if depth == 0:
                frames.append(buf[start:i + 1])
                start, consumed = None, i + 1
    return frames, buf[consumed:], bytes(residue)


def classify(residue):
    if not residue:
        return None
    if any(m in residue for m in (b"ADM-CID", b"SIA-DCS", b'"NULL"')):
        return "SIA DC-09 / Contact-ID (CMS path protocol is not JSON)"
    printable = sum(32 <= b < 127 for b in residue)
    if len(residue) >= 8 and printable < len(residue) * 0.7:
        return "binary / encrypted data (turn encryption off on the CMS path)"
    return None


class Session:
    def __init__(self, sock, addr, args, cap):
        self.sock, self.addr, self.args, self.cap = sock, addr, args, cap
        self.lock = threading.Lock()
        self.last_send = 0.0
        self.gap = 0.0
        self.counter = 0
        self.account = None
        self.responses = queue.Queue()
        self.ready = threading.Event()
        self.alive = True
        self.stats = {"frames": 0, "events": 0, "nulls": 0, "foreign": None, "naks": []}
        self.results = {}

    def log(self, msg):
        line = time.strftime("%H:%M:%S ") + msg
        print(line, flush=True)
        self.cap.write(line + "\n")
        self.cap.flush()

    def send(self, obj, gap):
        data = json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("cp1255")
        with self.lock:
            wait = self.last_send + self.gap - time.time()
            if wait > 0:
                time.sleep(wait)
            self.sock.sendall(data)
            self.last_send, self.gap = time.time(), gap
        shown = dict(obj)
        if "password" in shown:
            shown["password"] = "****"
        if obj.get("frame_type") != "ACK" or self.args.verbose:
            self.log("ha> " + json.dumps(shown, ensure_ascii=False))
        else:
            self.cap.write(time.strftime("%H:%M:%S ") + "ha> " + json.dumps(shown) + "\n")

    def ack(self, frame):
        account = int(frame.get("account") or 0) if str(frame.get("account", "")).isdigit() else 0
        self.send({"account": account, "counter": int(frame.get("counter") or 0),
                   "frame_type": "ACK", "kc": 1}, ACK_GAP)

    # ---- receive -------------------------------------------------------------
    def reader(self):
        buf = b""
        while self.alive:
            try:
                chunk = self.sock.recv(4096)
            except socket.timeout:
                continue
            except OSError:
                chunk = b""
            if not chunk:
                self.log("! panel closed the connection")
                break
            self.cap.write(time.strftime("%H:%M:%S ") + "raw< " + chunk.hex(" ") + "\n")
            buf += chunk
            frames, buf, residue = split_frames(buf)
            kind = classify(residue)
            if kind and not self.stats["foreign"]:
                self.stats["foreign"] = kind
                self.log(f"! NOT JSON: {kind}")
                self.log(f"  sample: {residue[:120]!r}")
            for raw in frames:
                self.on_frame(raw)
        self.alive = False
        self.ready.set()
        self.responses.put(None)

    def on_frame(self, raw):
        try:
            frame = json.loads(text_of(raw), strict=False)
        except ValueError as e:
            self.log(f"! unreadable frame ({e}): {raw[:160]!r}")
            return
        self.stats["frames"] += 1
        ftype = str(frame.get("frame_type", "")).upper()
        if self.account is None and frame.get("account") is not None:
            self.account = frame.get("account")
            self.log(f"panel account: {self.account!r} ({type(self.account).__name__})")
        if ftype in ("EVENT", "NULL", "DATA"):
            self.ack(frame)
        if ftype == "NULL":
            self.stats["nulls"] += 1
            self.log(f"pa< null heartbeat (counter {frame.get('counter')})")
            self.ready.set()
        elif ftype == "EVENT":
            self.stats["events"] += 1
            t, q = int(frame.get("type") or 0), int(frame.get("qualifier") or 0)
            self.log(f"pa< EVENT {t}-{q} zone {frame.get('zone')} partition {frame.get('partition')}"
                     f"  ({CID.get(t, 'CID ' + str(t))}{', restore/arm' if q == 3 else ''})")
        elif ftype in ("ACK", "NAK", "DATA"):
            if ftype == "NAK":
                reason = frame.get("DATA") or frame.get("data") or "?"
                self.stats["naks"].append(reason)
                self.log(f"pa< NAK counter {frame.get('counter')}: {reason}")
            elif ftype == "DATA":
                shown = json.dumps(frame, ensure_ascii=False)
                self.log("pa< " + (shown if len(shown) < 300 else shown[:300] + "..."))
            self.responses.put(frame)
        else:
            self.log("pa< (unhandled) " + json.dumps(frame, ensure_ascii=False))

    # ---- read-only requests ----------------------------------------------------
    def request(self, pid, start, stop=None):
        """DATA-REQ with paging. Returns list of parameters, or None."""
        collected, pages = [], 0
        while self.alive:
            self.counter = self.counter % 9999 + 1
            req = {"account": int(self.account) if str(self.account).isdigit() else 0,
                   "counter": self.counter, "frame_type": "DATA-REQ", "id": pid,
                   "password": self.args.code, "start_order": start}
            if stop is not None:
                req["stop_order"] = stop
            self.send(req, WRITE_GAP)
            deadline = time.time() + TIMEOUT
            frame = None
            while time.time() < deadline:
                try:
                    f = self.responses.get(timeout=max(0.05, deadline - time.time()))
                except queue.Empty:
                    break
                if f is None:
                    return None
                ft = str(f.get("frame_type", "")).upper()
                if ft == "DATA" and int(f.get("id") or -1) == pid:
                    frame = f
                    break
                if ft == "NAK":
                    return None
            if frame is None:
                self.log(f"! no answer to DATA-REQ {pid}")
                return None
            params = frame.get("parameters")
            if not isinstance(params, list):
                params = [] if params is None else [params]
            collected += params
            if str(frame.get("more", "")).lower() == "yes" and params and pages < 50:
                pages += 1
                start = int(frame.get("start_order") or start) + len(params)
                continue
            return collected
        return None

    def read_panel(self):
        r = self.results
        r["zone_count"] = self.request(2148, 1, 1)
        r["exit_time"] = self.request(180, 1, 1)
        r["system_key"] = self.request(2310, 1, 16)
        r["zone_status"] = self.request(2149, 1)
        r["outputs"] = self.request(2301, 1, 2)
        r["faults"] = self.request(2250, 1)
        n = int(r["zone_count"][0]) if r.get("zone_count") and str(r["zone_count"][0]).isdigit() else 0
        names = []
        for start in range(1, min(n, 144) + 1, 32):
            page = self.request(260, start, min(start + 31, n))
            if page is None:
                break
            names += page
        r["zone_names"] = names
        self.report()

    def report(self):
        r = self.results
        self.log("=" * 60)
        self.log("PANEL READ-BACK")
        self.log(f"  zones: {r.get('zone_count')}   exit time: {r.get('exit_time')} s")
        for p, v in enumerate(r.get("system_key") or [], 1):
            if str(v) != "1":
                self.log(f"  partition {p}: {KEY_NAMES.get(int(v), v) if str(v).isdigit() else v}")
        for i, name in enumerate(r.get("zone_names") or [], 1):
            self.log(f"  zone {i:>3}: {name}")
        for h in r.get("zone_status") or []:
            v = int(str(h), 16)
            bits = [n for b, n in ZONE_BITS.items() if (v >> 8) >> b & 1]
            self.log(f"  zone {v & 0xFF:>3} status: {', '.join(bits) or 'clear'}")
        self.log(f"  sirens/outputs 1-2: {r.get('outputs')}")
        for h in r.get("faults") or []:
            v = int(str(h), 16)
            self.log(f"  fault: {FAULTS.get(v & 0xFF, 'fault id ' + str(v & 0xFF))} (order {v >> 8})")
        if r.get("faults") == []:
            self.log("  faults: none")
        self.log("=" * 60)


def serve(args):
    os.makedirs(os.path.dirname(os.path.abspath(args.capture)), exist_ok=True)
    cap = open(args.capture, "a", encoding="utf-8")
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((args.bind, args.port))
    srv.listen(4)
    srv.settimeout(1)
    end = time.time() + args.duration if args.duration else None
    print(f"listening on {args.bind}:{args.port}  (capture: {args.capture})", flush=True)
    print("read-only: " + ("reads panel data with the given code" if args.code else "ACK only, no user code"), flush=True)
    while end is None or time.time() < end:
        try:
            sock, addr = srv.accept()
        except socket.timeout:
            continue
        sock.settimeout(1)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        s = Session(sock, addr, args, cap)
        s.log(f"connection from {addr[0]}:{addr[1]}")
        threading.Thread(target=s.reader, daemon=True).start()
        # the panel replays buffered events, then sends null; read after that
        s.ready.wait(timeout=10)
        if s.alive and args.code and not s.stats["foreign"]:
            s.read_panel()
        while s.alive and (end is None or time.time() < end):
            time.sleep(0.5)
        s.alive = False
        try:
            sock.close()
        except OSError:
            pass
        s.log(f"session summary: {json.dumps(s.stats, ensure_ascii=False)}")
        if args.once:
            break
    srv.close()


def main():
    ap = argparse.ArgumentParser(description="Read-only PIMA FORCE JSON test listener")
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=7780)
    ap.add_argument("--code", default=os.environ.get("PIMA_CODE", ""), help="panel user code (or env PIMA_CODE)")
    ap.add_argument("--duration", type=int, default=0, help="stop after N seconds (0 = run until Ctrl+C)")
    ap.add_argument("--once", action="store_true", help="stop after the first panel session ends")
    ap.add_argument("--capture", default="force_capture.log", help="file for the raw byte capture")
    ap.add_argument("--verbose", action="store_true", help="also print ACK frames")
    args = ap.parse_args()
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    try:
        serve(args)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
