#!/usr/bin/env python3
"""oidc-login.py <user> — obtain an OIDC ID token for a kanidm test user, headless.

Drives the authorization-code flow with PKCE (S256) and a nonce, as litevirt's
OIDC realm does, but in place of a browser it uses kanidm's JSON API: log the
user in (password, plus a TOTP code when their account policy demands one),
ask /oauth2/authorise for the code as that user, then redeem it at the token
endpoint as the confidential client. Prints the verified ID token's claims as
JSON (never the token itself). Stdlib only.

Environment (written by tools/idm.sh into /etc/lab-idm/oidc.env, 0600):
  IDM_URL            https://idm.lab:8443
  IDM_CA             the lab CA certificate
  OIDC_CLIENT_ID     litevirt
  OIDC_CLIENT_SECRET the client's basic secret
  OIDC_REDIRECT      a redirect URL registered for the client
  LAB_USER_PASSWORD  the user's password
  LAB_USER_TOTP      optional: path to the user's TOTP secret file (kanidm-cred.py)
"""
import base64
import hashlib
import hmac
import http.client
import json
import os
import secrets
import ssl
import struct
import sys
import time
import urllib.parse
import urllib.request

E = os.environ
URL = E.get("IDM_URL", "https://idm.lab:8443")
# The lab CA: IDM_CA when that file exists here, else the system trust store
# (tools/lab-ca.sh trust puts the lab CA there on the nodes).
_ca = E.get("IDM_CA", "")
CTX = ssl.create_default_context(cafile=_ca if _ca and os.path.exists(_ca) else None)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


OPENER = urllib.request.build_opener(urllib.request.HTTPSHandler(context=CTX), NoRedirect)


def req(method, path, body=None, headers=None, form=False):
    h = dict(headers or {})
    data = None
    if body is not None:
        if form:
            data = urllib.parse.urlencode(body).encode()
            h["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            data = json.dumps(body).encode()
            h["Content-Type"] = "application/json"
    r = urllib.request.Request(URL + path, data=data, method=method, headers=h)
    try:
        resp = OPENER.open(r, timeout=30)
    except urllib.error.HTTPError as e:  # 3xx land here too (NoRedirect)
        resp = e
    raw = resp.read()
    return resp.status, resp.headers, raw


def totp_now(path):
    with open(path, encoding="utf-8") as f:
        t = json.load(f)
    s = t["secret_b32"]
    secret = base64.b32decode(s + "=" * (-len(s) % 8))
    counter = int(time.time() // t["step"])
    mac = hmac.new(secret, struct.pack(">Q", counter), getattr(hashlib, t["algo"])).digest()
    off = mac[-1] & 0x0F
    return (struct.unpack(">I", mac[off:off + 4])[0] & 0x7FFFFFFF) % (10 ** t["digits"])


def login(user):
    """kanidm's auth state machine; returns the user's session bearer token."""
    st, hd, raw = req("POST", "/v1/auth", {"step": {"init2": {"username": user, "issue": "token", "privileged": False}}})
    sid = hd.get("X-KANIDM-AUTH-SESSION-ID")
    hdr = {"X-KANIDM-AUTH-SESSION-ID": sid}
    choose = json.loads(raw)["state"]["choose"]
    mech = "passwordmfa" if "passwordmfa" in choose else "password"
    if mech == "passwordmfa" and not E.get("LAB_USER_TOTP"):
        raise SystemExit(f"{user} needs a second factor (kanidm offers {choose}); set LAB_USER_TOTP")
    st, hd, raw = req("POST", "/v1/auth", {"step": {"begin": mech}}, hdr)
    steps = []
    if mech == "passwordmfa":
        steps.append({"totp": totp_now(E["LAB_USER_TOTP"])})
    steps.append({"password": E["LAB_USER_PASSWORD"]})
    for cred in steps:
        st, hd, raw = req("POST", "/v1/auth", {"step": {"cred": cred}}, hdr)
        state = json.loads(raw).get("state", {})
        if "denied" in state:
            raise SystemExit(f"kanidm denied {user}: {state['denied']}")
    if "success" not in state:
        raise SystemExit(f"login for {user} did not finish: {state}")
    return state["success"], mech


def b64u(b):
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def claims_of(jwt):
    p = jwt.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(2)
    user = sys.argv[1]
    client, secret, redirect = E["OIDC_CLIENT_ID"], E["OIDC_CLIENT_SECRET"], E["OIDC_REDIRECT"]
    bearer, mech = login(user)
    verifier = b64u(secrets.token_bytes(32))
    challenge = b64u(hashlib.sha256(verifier.encode()).digest())
    state, nonce = b64u(secrets.token_bytes(12)), b64u(secrets.token_bytes(12))
    auth = {"response_type": "code", "client_id": client, "state": state,
            "code_challenge": challenge, "code_challenge_method": "S256",
            "redirect_uri": redirect, "scope": "openid profile email groups", "nonce": nonce}
    st, hd, raw = req("POST", "/oauth2/authorise", auth, {"Authorization": "Bearer " + bearer})
    if st != 200:
        raise SystemExit(f"/oauth2/authorise: HTTP {st}: {raw[:300]!r}")
    res = json.loads(raw)
    if isinstance(res, dict) and "ConsentRequested" in res:
        tok = res["ConsentRequested"]["consent_token"]
        st, hd, raw = req("POST", "/oauth2/authorise/permit", tok, {"Authorization": "Bearer " + bearer})
        loc = hd.get("Location")
    elif res == "Permitted" or (isinstance(res, dict) and "Permitted" in res):
        # A client the user already consented to: kanidm answers "Permitted"
        # with the redirect (code and state) in the Location header.
        loc = hd.get("Location")
    else:
        raise SystemExit(f"/oauth2/authorise: unexpected {json.dumps(res)[:300]}")
    if not loc:
        raise SystemExit(f"no redirect from kanidm (HTTP {st}): {raw[:300]!r}")
    q = urllib.parse.parse_qs(urllib.parse.urlparse(loc).query)
    if q.get("state", [""])[0] != state:
        raise SystemExit("state mismatch on the redirect")
    code = q["code"][0]
    basic = base64.b64encode(f"{client}:{secret}".encode()).decode()
    st, hd, raw = req("POST", "/oauth2/token", {"grant_type": "authorization_code", "code": code,
                                                 "redirect_uri": redirect, "code_verifier": verifier,
                                                 "client_id": client},
                      {"Authorization": "Basic " + basic}, form=True)
    if st != 200:
        raise SystemExit(f"/oauth2/token: HTTP {st}: {raw[:300]!r}")
    tok = json.loads(raw)
    c = claims_of(tok["id_token"])
    if c.get("nonce") != nonce:
        raise SystemExit("ID token nonce does not echo the request's")
    out = {k: c.get(k) for k in ("iss", "aud", "sub", "preferred_username", "email", "name", "litevirt_groups", "groups", "amr", "acr")}
    out["login_mechanism"] = mech
    out["token_type"] = tok.get("token_type")
    out["expires_in"] = tok.get("expires_in")
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
