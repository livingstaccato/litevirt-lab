#!/usr/bin/env python3
"""bmc-agent.py — the lab host's power agent behind the simulated BMCs.

The BMC simulators (ipmi_sim and sushy-tools in the `bmc` aux VM) cannot reach
a node's qemu process: it lives on the lab host. This agent is the only piece
that does. It runs on the lab host as the lab user, listens on 127.0.0.1 only
(guests on qemu user networking reach it at 10.0.2.2:<port>), and turns an
authenticated request into `lab.sh up/down <n>` or a QMP command for that one
node — nothing else. Stdlib only.

    GET  /v1/nodes/<n>/power            -> {"node": n, "power": "on"|"off", "pid": ...}
    POST /v1/nodes/<n>/power/<action>   action: on | off (power cut) | soft (ACPI
                                        power button) | cycle (off, then on: a new
                                        qemu process) | reset (warm reset, same qemu)
                                        on and cycle answer 202 at once and boot in
                                        the background (poll GET for the result)

Every request needs `Authorization: Bearer <token>` (the token file is 0600 in
the lab's secrets/). Node numbers outside LAB_BMC_NODES are refused, so the
agent can never touch an aux VM, another lab, or anything else on the host.
Every action is logged with its caller to the log file.

Usage: bmc-agent.py --lab <dir> --port <p> --token-file <f> --nodes "1 2 3" --log <f>
"""
import argparse
import hmac
import json
import os
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROUTE = re.compile(r"^/v1/nodes/(\d+)/power(?:/(on|off|soft|cycle|reset))?$")


class Agent:
    def __init__(self, lab, token, nodes, log):
        self.lab = lab
        self.token = token
        self.nodes = nodes
        self.logf = log
        self.lock = threading.Lock()  # one power action at a time, lab-wide

    def log(self, msg):
        line = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + " " + msg
        with open(self.logf, "a", encoding="utf-8") as f:
            f.write(line + "\n")

    def labsh(self, *args, timeout=120):
        return subprocess.run([os.path.join(self.lab, "lab.sh"), *args], cwd=self.lab,
                              stdin=subprocess.DEVNULL, capture_output=True, text=True,
                              timeout=timeout)

    def pid(self, n):
        r = self.labsh("pid", str(n), timeout=20)
        out = r.stdout.strip()
        return int(out) if r.returncode == 0 and out.isdigit() else None

    def qmp(self, n, command):
        sock = os.path.join(os.path.realpath(os.path.join(self.lab, "nodes")), f"node-{n}", "qmp.sock")
        r = subprocess.run([sys.executable, "-I", os.path.join(self.lab, "tools", "qmp.py"), sock, command],
                           stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20)
        if r.returncode != 0:
            raise RuntimeError(r.stderr.strip() or f"qmp {command} failed")

    def status(self, n):
        p = self.pid(n)
        return {"node": n, "power": "on" if p else "off", "pid": p}

    def act(self, n, action):
        with self.lock:
            before = self.pid(n)
            if action == "on":
                if not before:
                    r = self.labsh("up", str(n))
                    if r.returncode != 0:
                        raise RuntimeError(r.stderr.strip() or r.stdout.strip())
            elif action == "off":
                if before:
                    self.labsh("down", str(n))
            elif action == "soft":
                if before:
                    self.qmp(n, "system_powerdown")
            elif action == "reset":
                if not before:
                    raise RuntimeError("node is off; reset needs power")
                self.qmp(n, "system_reset")
            elif action == "cycle":
                if before:
                    self.labsh("down", str(n))
                    for _ in range(50):
                        if not self.pid(n):
                            break
                        time.sleep(0.2)
                r = self.labsh("up", str(n))
                if r.returncode != 0:
                    raise RuntimeError(r.stderr.strip() or r.stdout.strip())
            after = self.pid(n)
            return {"node": n, "action": action, "pid_before": before, "pid_after": after,
                    "power": "on" if after else "off"}


class Handler(BaseHTTPRequestHandler):
    server_version = "lab-bmc-agent/1"
    agent: Agent = None  # set in main

    def log_message(self, fmt, *args):  # quiet stderr; we keep our own log
        pass

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        got = self.headers.get("Authorization", "")
        want = "Bearer " + self.agent.token
        return hmac.compare_digest(got.encode(), want.encode())

    def route(self, method):
        peer = self.client_address[0]
        if not self.authorized():
            self.agent.log(f"DENY {peer} {method} {self.path} (bad or missing token)")
            return self.reply(401, {"error": "unauthorized"})
        m = ROUTE.match(self.path)
        if not m:
            return self.reply(404, {"error": "no such route"})
        n, action = int(m.group(1)), m.group(2)
        if n not in self.agent.nodes:
            self.agent.log(f"DENY {peer} {method} {self.path} (node {n} not in LAB_BMC_NODES)")
            return self.reply(403, {"error": f"node {n} is not managed by this agent"})
        try:
            if method == "GET" and action is None:
                return self.reply(200, self.agent.status(n))
            if method == "POST" and action in ("on", "cycle"):
                # Booting takes lab.sh several seconds (it scans /proc for the
                # seed server), longer than an IPMI client waits for a chassis
                # command, which then retries and reports failure. Accept now
                # and boot in the background, like a real BMC; status follows.
                def run():
                    try:
                        res = self.agent.act(n, action)
                        self.agent.log(f"{peer} node-{n} {action}: pid {res['pid_before']} -> {res['pid_after']}")
                    except Exception as e:  # noqa: BLE001
                        self.agent.log(f"ERROR {peer} node-{n} {action}: {e}")
                threading.Thread(target=run, daemon=True).start()
                return self.reply(202, {"node": n, "action": action, "accepted": True})
            if method == "POST" and action:
                res = self.agent.act(n, action)
                self.agent.log(f"{peer} node-{n} {action}: pid {res['pid_before']} -> {res['pid_after']}")
                return self.reply(200, res)
            return self.reply(405, {"error": "method not allowed"})
        except Exception as e:  # noqa: BLE001 — every failure is a 500 with its reason
            self.agent.log(f"ERROR {peer} {method} {self.path}: {e}")
            return self.reply(500, {"error": str(e)})

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lab", required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--token-file", required=True)
    ap.add_argument("--nodes", required=True, help='space-separated node numbers, e.g. "1 2 3"')
    ap.add_argument("--log", required=True)
    a = ap.parse_args()
    with open(a.token_file, encoding="utf-8") as f:
        token = f.read().strip()
    if len(token) < 32:
        sys.exit("token too short")
    agent = Agent(os.path.realpath(a.lab), token, {int(x) for x in a.nodes.split()}, a.log)
    Handler.agent = agent
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    agent.log(f"agent up on 127.0.0.1:{a.port} for nodes {sorted(agent.nodes)}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
