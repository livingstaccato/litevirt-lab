#!/usr/bin/env python3
"""kanidm-cred.py <user> <reset-token> [--totp <secret-file>] — set a kanidm
person's password (from $LAB_USER_PASSWORD), and optionally enrol a TOTP, through
kanidm's credential-update API: the same calls the web UI's reset page makes.
Runs inside the idm aux VM. Stdlib only.

With --totp, the TOTP shared secret (base32, the otpauth form) is written to
<secret-file> (0600) so the lab can compute codes later (tools/idm-vm/oidc-login.py).
Prints nothing secret. Exit 1 on failure.
"""
import base64
import hashlib
import hmac
import json
import os
import ssl
import struct
import sys
import time
import urllib.request

URL = os.environ.get("KANIDM_URL", "https://idm.lab:8443")
CTX = ssl.create_default_context(cafile=os.environ.get("KANIDM_CA", "/usr/local/share/ca-certificates/litevirt-lab-ca.crt"))


def post(path, body):
    req = urllib.request.Request(URL + path, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, context=CTX, timeout=30) as r:
        return json.loads(r.read() or b"null")


def totp(secret: bytes, step=30, digits=6, algo="sha1", at=None):
    counter = int((at or time.time()) // step)
    mac = hmac.new(secret, struct.pack(">Q", counter), getattr(hashlib, algo)).digest()
    off = mac[-1] & 0x0F
    code = (struct.unpack(">I", mac[off:off + 4])[0] & 0x7FFFFFFF) % (10 ** digits)
    return code


def main():
    if len(sys.argv) not in (3, 5):
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(2)
    user, token = sys.argv[1], sys.argv[2]
    totp_file = sys.argv[4] if len(sys.argv) == 5 and sys.argv[3] == "--totp" else None
    session, status = post("/v1/credential/_exchange_intent", token)
    st = post("/v1/credential/_update", [{"password": os.environ["LAB_USER_PASSWORD"]}, session])
    if totp_file:
        st = post("/v1/credential/_update", ["totpgenerate", session])
        reg = st.get("mfaregstate", {})
        sec = reg.get("TotpCheck") if isinstance(reg, dict) else None
        if not sec:
            raise SystemExit(f"no TOTP secret offered: {json.dumps(reg)[:200]}")
        secret = bytes(sec["secret"])
        algo = str(sec.get("algo", "Sha1")).lower()
        step = int(sec.get("step", 30))
        digits = int(sec.get("digits", 6))
        st = post("/v1/credential/_update", [{"totpverify": [totp(secret, step, digits, algo), "lab"]}, session])
        fd = os.open(totp_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(json.dumps({"secret_b32": base64.b32encode(secret).decode().rstrip("="),
                                "algo": algo, "step": step, "digits": digits}) + "\n")
    if st.get("can_commit") is False:
        raise SystemExit(f"kanidm will not commit: {json.dumps(st.get('warnings') or st)[:300]}")
    post("/v1/credential/_commit", session)
    print(f"{user}: password set" + (", TOTP enrolled" if totp_file else ""))


if __name__ == "__main__":
    main()
