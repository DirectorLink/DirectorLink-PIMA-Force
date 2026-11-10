#!/usr/bin/env python3
"""PIMA FORCE panel simulator (JSON interface) for testing the Control4 driver.

Connects to the driver like a real FORCE panel dialling a monitoring station,
answers its DATA-REQ / OPERATION / DATA frames and lets you create events
from the console. Python 3 standard library only.

    python tools/force_sim.py --host <controller IP> --port 7780 --account 654321 --code 1234

Console commands (type 'help'):
    open N / close N          zone N opens / closes (CID 760)
    alarm N                   burglary alarm on zone N (CID 130)
    fire N                    fire alarm on zone N (CID 110)
    arm away|home|night [P]   keypad arm of partition P (default 1)
    disarm [P]                keypad disarm
    fault ac|battery|tamper   add a panel fault (CID 301/302/137 + fault list)
    clear                     clear all faults
    siren on|off              siren output 1 (CID 770)
    status                    print the simulated panel state
    drop                      close the TCP connection (the sim reconnects)
    quit
"""
import argparse
import json
import socket
import sys
import threading
import time

ARM_KEYS = {12: "3", 13: "4", 14: "5", 15: "6", 16: "7", 43: "8"}
KEY_NAMES = {"1": "not defined", "2": "disarmed", "3": "Away", "4": "Home1", "5": "Home2"}
FAULTS = {"ac": ("1", 301), "battery": ("2", 302), "tamper": ("3", 137)}
OPEN_BIT, BYPASS_BIT, ALARM_BIT = 11, 7, 9


class Panel:
    def __init__(self, args):
        self.args = args
        self.account = args.account
        self.code = args.code
        self.counter = 0
        self.keys = ["2"] + ["1"] * 15
        for p in range(1, args.partitions):
            self.keys[p] = "2"
        self.zones = {}
        self.names = {z: f"Zone {z}" for z in range(1, args.zones + 1)}
        self.names[1] = "דלת כניסה"  # Hebrew, sent as Windows-1255 like a real panel
        self.faults = []
        self.sirens = ["0", "0"]
        self.sock = None
        self.lock = threading.Lock()
        self.buf = b""
        self.running = True

    # ---- wire -------------------------------------------------------------
    def next_counter(self):
        self.counter = self.counter % 9999 + 1
        return self.counter

    def send(self, frame, pad=0):
        frame.setdefault("account", self.account)
        data = json.dumps(frame, ensure_ascii=False, separators=(",", ":")).encode("cp1255", errors="replace")
        data += b"\0" * pad
        with self.lock:
            if self.sock:
                try:
                    self.sock.sendall(data)
                except OSError as e:
                    print(f"! send failed: {e}")
                    return
        if frame.get("frame_type") not in ("ACK",) or self.args.verbose:
            print(f"panel> {json.dumps(frame, ensure_ascii=False)}")

    def event(self, cid, q, zone, partition=1):
        self.send({"frame_type": "event", "counter": self.next_counter(), "type": cid,
                   "qualifier": q, "zone": zone, "partition": partition})

    def heartbeat(self):
        self.send({"frame_type": "null", "counter": self.next_counter()}, pad=180)

    # ---- state helpers ------------------------------------------------------
    def bit(self, z, b):
        return (self.zones.get(z, 0) >> b) & 1 == 1

    def set_bit(self, z, b, on):
        v = self.zones.get(z, 0)
        self.zones[z] = (v | (1 << b)) if on else (v & ~(1 << b))

    def zone_status(self):
        return [format((bits << 8) | z, "X") for z, bits in sorted(self.zones.items()) if bits]

    # ---- requests from the driver -------------------------------------------
    def handle(self, frame):
        ftype = str(frame.get("frame_type", "")).upper()
        shown = dict(frame)
        if "password" in shown:
            shown["password"] = "****"
        if ftype != "ACK" or self.args.verbose:
            print(f"   c4> {json.dumps(shown, ensure_ascii=False)}")
        if ftype == "ACK":
            if frame.get("kc") != 1:
                print("! ACK without kc:1 - a real panel would hang up")
            if not isinstance(frame.get("account"), int):
                print("! ACK account is not a number - a real panel would NAK")
            return
        counter = frame.get("counter")
        if frame.get("password") != self.code:
            self.send({"frame_type": "NAK", "counter": counter, "DATA": "Wrong User Code"})
            return
        if ftype == "DATA-REQ":
            self.data_request(frame)
        elif ftype == "OPERATION":
            self.operation(frame)
        elif ftype == "DATA":
            zone, value = frame.get("start_order"), (frame.get("parameters") or ["0"])[0]
            self.send({"frame_type": "ACK", "counter": counter})
            self.set_bit(zone, BYPASS_BIT, value == "1")
            self.event(570, 1 if value == "1" else 3, zone)
        else:
            self.send({"frame_type": "NAK", "counter": counter, "DATA": "Invalid Frame Type"})

    def data_request(self, req):
        pid, start, stop = req.get("id"), req.get("start_order", 1), req.get("stop_order")
        more, params = "no", []
        if pid == 2148:
            params = [str(len(self.names))]
        elif pid == 180:
            params = [str(self.args.exit_time)]
        elif pid == 2310:
            params = self.keys[start - 1:(stop or 16)]
        elif pid == 2149:
            params = self.zone_status()
        elif pid == 2250:
            params = list(self.faults)
        elif pid == 2301:
            params = self.sirens[start - 1:(stop or 2)]
        elif pid == 260:
            last = min(stop or len(self.names), start + 8)  # a real panel pages ~9 names
            params = [self.names.get(z, "") for z in range(start, last + 1)]
            more = "yes" if last < (stop or len(self.names)) else "no"
        else:
            self.send({"frame_type": "NAK", "counter": req.get("counter"), "DATA": "Parameter Not Exist"})
            return
        self.send({"frame_type": "DATA", "counter": req.get("counter"), "id": pid,
                   "start_order": start, "parameters": params, "more": more})

    def operation(self, op):
        counter, optype, p = op.get("counter"), op.get("optype"), op.get("partition", 1)
        parts = range(1, self.args.partitions + 1) if p == 0 else [p]
        if optype in ARM_KEYS:
            open_zones = [z for z in self.names if self.bit(z, OPEN_BIT) and not self.bit(z, BYPASS_BIT)]
            if open_zones:
                self.send({"frame_type": "NAK", "counter": counter, "DATA": "סגור/בטל אזורים!"})
                return
            self.send({"frame_type": "ACK", "counter": counter})
            for pp in parts:
                self.event(441 if optype != 12 else 407, 3, 1, pp)
            threading.Timer(self.args.exit_time, self.finish_arm, (list(parts), ARM_KEYS[optype])).start()
        elif optype == 17:
            if all(self.keys[pp - 1] == "2" for pp in parts):
                self.send({"frame_type": "NAK", "counter": counter, "DATA": "כל המדורים מנוטרלים"})
                return
            self.send({"frame_type": "ACK", "counter": counter})
            for pp in parts:
                self.keys[pp - 1] = "2"
                self.event(407, 1, 1, pp)
            for z in self.zones:
                self.set_bit(z, ALARM_BIT, False)
        elif optype in (35, 36):
            self.send({"frame_type": "ACK", "counter": counter})
            print(f"   (output order {op.get('order')} {'on' if optype == 35 else 'off'})")
        else:
            self.send({"frame_type": "NAK", "counter": counter, "DATA": "Parameter Not Exist"})

    def finish_arm(self, parts, key):
        for pp in parts:
            self.keys[pp - 1] = key
        print(f"   (exit delay over: partition(s) {parts} armed {KEY_NAMES.get(key, key)})")

    # ---- connection loop ----------------------------------------------------
    def reader(self):
        while self.running:
            try:
                sock = socket.create_connection((self.args.host, self.args.port), timeout=10)
            except OSError as e:
                print(f"! cannot connect to {self.args.host}:{self.args.port}: {e} (retrying in 5 s)")
                time.sleep(5)
                continue
            sock.settimeout(1)
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            with self.lock:
                self.sock, self.buf = sock, b""
            print(f"connected to {self.args.host}:{self.args.port} as account {self.account}")
            self.heartbeat()
            last_beat = time.time()
            while self.running:
                if time.time() - last_beat >= self.args.heartbeat:
                    self.heartbeat()
                    last_beat = time.time()
                try:
                    chunk = sock.recv(4096)
                except socket.timeout:
                    continue
                except OSError:
                    chunk = b""
                if not chunk:
                    print("! connection closed by the driver (reconnecting in 5 s)")
                    break
                self.buf += chunk
                for frame in self.split():
                    try:
                        self.handle(frame)
                    except Exception as e:  # keep the simulator alive
                        print(f"! error handling {frame}: {e}")
            with self.lock:
                self.sock = None
            sock.close()
            time.sleep(5)

    def split(self):
        """Complete JSON objects from the receive buffer (brace depth, string aware)."""
        frames, depth, start, in_str, esc = [], 0, None, False, False
        text = self.buf.decode("cp1255", errors="replace")
        for i, c in enumerate(text):
            if start is None:
                if c == "{":
                    start, depth, in_str, esc = i, 1, False, False
                continue
            if in_str:
                if esc:
                    esc = False
                elif c == "\\":
                    esc = True
                elif c == '"':
                    in_str = False
            elif c == '"':
                in_str = True
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    try:
                        frames.append(json.loads(text[start:i + 1]))
                    except ValueError:
                        print(f"! driver sent invalid JSON: {text[start:i + 1]}")
                    start = None
        if start is None:
            self.buf = b""
        else:
            self.buf = text[start:].encode("cp1255", errors="replace")
        return frames

    def drop(self):
        with self.lock:
            if self.sock:
                self.sock.close()


def console(panel):
    print(__doc__.split("Console commands")[1])
    while True:
        try:
            words = input().strip().lower().split()
        except EOFError:
            words = ["quit"]
        if not words:
            continue
        cmd, arg = words[0], words[1:]
        num = int(arg[0]) if arg and arg[0].isdigit() else None
        if cmd in ("open", "close") and num:
            panel.set_bit(num, OPEN_BIT, cmd == "open")
            panel.event(760, 1 if cmd == "open" else 3, num)
        elif cmd in ("alarm", "fire") and num:
            panel.set_bit(num, ALARM_BIT, True)
            panel.event(130 if cmd == "alarm" else 110, 1, num)
        elif cmd == "arm" and arg:
            p = int(arg[1]) if len(arg) > 1 else 1
            key = {"away": "3", "home": "4", "night": "5"}.get(arg[0], "3")
            panel.keys[p - 1] = key
            panel.event(401 if key == "3" else 441, 3, 1, p)
        elif cmd == "disarm":
            p = num or 1
            panel.keys[p - 1] = "2"
            for z in panel.zones:
                panel.set_bit(z, ALARM_BIT, False)
            panel.event(401, 1, 1, p)
        elif cmd == "fault" and arg and arg[0] in FAULTS:
            code, cid = FAULTS[arg[0]]
            if code not in panel.faults:
                panel.faults.append(code)
            panel.event(cid, 1, 0, 0)
        elif cmd == "clear":
            panel.faults = []
            panel.event(301, 3, 0, 0)
        elif cmd == "siren" and arg:
            on = arg[0] == "on"
            panel.sirens[0] = "1" if on else "0"
            panel.event(770, 1 if on else 3, 1)
        elif cmd == "status":
            print(f"partitions: {[KEY_NAMES.get(k, k) for k in panel.keys[:panel.args.partitions]]}")
            print(f"zones (non-zero): {panel.zone_status()}  faults: {panel.faults}  sirens: {panel.sirens}")
        elif cmd == "drop":
            panel.drop()
        elif cmd in ("quit", "exit"):
            panel.running = False
            panel.drop()
            return
        else:
            print("? unknown command, type 'help'" if cmd != "help" else __doc__.split("Console commands")[1])


def main():
    ap = argparse.ArgumentParser(description="PIMA FORCE JSON panel simulator")
    ap.add_argument("--host", required=True, help="Control4 controller IP")
    ap.add_argument("--port", type=int, default=7780)
    ap.add_argument("--account", default="654321", help="CMS account (sent as a string, like the panel)")
    ap.add_argument("--code", default="1234", help="user code the simulated panel accepts")
    ap.add_argument("--zones", type=int, default=8)
    ap.add_argument("--partitions", type=int, default=1)
    ap.add_argument("--exit-time", type=int, default=10)
    ap.add_argument("--heartbeat", type=int, default=60, help="seconds between null frames")
    ap.add_argument("--verbose", action="store_true", help="also print ACK frames")
    args = ap.parse_args()
    # Hebrew zone names: never let the Windows console encoding crash the sim
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    panel = Panel(args)
    threading.Thread(target=panel.reader, daemon=True).start()
    console(panel)


if __name__ == "__main__":
    main()
