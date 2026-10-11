#!/usr/bin/env python3
"""qmp.py <socket> <command> [json-args] — run one QMP command against a lab VM.

Prints the command's "return" as JSON and exits 0, or prints the error and
exits 1. Stdlib only (the lab host has no qemu python bindings). Used by
tools/node-cycle.sh and the BMC power agent for an ACPI power button
(system_powerdown) and status queries (query-status).
"""
import json
import socket
import sys


def qmp(path, command, args=None, timeout=10.0):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(path)
    f = s.makefile("rw")
    try:
        f.readline()  # greeting
        for msg in ({"execute": "qmp_capabilities"},
                    {"execute": command, **({"arguments": args} if args else {})}):
            f.write(json.dumps(msg) + "\n")
            f.flush()
            while True:
                reply = json.loads(f.readline())
                if "event" in reply:  # asynchronous; not ours
                    continue
                break
            if "error" in reply:
                raise RuntimeError(reply["error"].get("desc", str(reply["error"])))
        return reply.get("return")
    finally:
        s.close()


def main():
    if len(sys.argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(2)
    args = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
    try:
        print(json.dumps(qmp(sys.argv[1], sys.argv[2], args)))
    except Exception as e:  # noqa: BLE001 — report any failure as exit 1
        print(f"qmp {sys.argv[2]}: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
