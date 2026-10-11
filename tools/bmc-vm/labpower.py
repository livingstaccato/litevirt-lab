#!/usr/bin/env python3
"""labpower.py <n> get|on|off|soft|cycle|reset — talk to the lab host's power agent.

Runs inside the `bmc` aux VM (installed to /usr/local/lib/lab-bmc by
tools/bmc.sh provision). Reads AGENT_URL and AGENT_TOKEN from
/etc/lab-bmc/bmc.env. `get` prints "on" or "off"; the actions print the
agent's JSON. Exit 1 on any failure. Also imported by redfish-lab.py.
"""
import json
import sys
import urllib.request

ENV = "/etc/lab-bmc/bmc.env"


def _env():
    out = {}
    with open(ENV, encoding="utf-8") as f:
        for line in f:
            k, sep, v = line.strip().partition("=")
            if sep:
                out[k] = v
    return out


def call(n, action=None, timeout=60):
    e = _env()
    url = f"{e['AGENT_URL']}/v1/nodes/{int(n)}/power" + (f"/{action}" if action else "")
    req = urllib.request.Request(url, method="POST" if action else "GET",
                                 headers={"Authorization": "Bearer " + e["AGENT_TOKEN"]})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def main():
    if len(sys.argv) != 3 or sys.argv[2] not in ("get", "on", "off", "soft", "cycle", "reset"):
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(2)
    n, op = sys.argv[1], sys.argv[2]
    try:
        if op == "get":
            print(call(n)["power"])
        else:
            print(json.dumps(call(n, op)))
    except Exception as e:  # noqa: BLE001
        print(f"labpower {n} {op}: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
