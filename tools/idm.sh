#!/usr/bin/env bash
# idm.sh — identity and mail for the lab, on the `idm` aux VM. Run on the lab
# host, from the lab dir, with LAB_AUX_ROLES containing "idm" in lab.env.
#
#   idm.sh provision     kanidm (OIDC provider, https://LAB_IDM_DOMAIN:8443) and
#                        Mailpit (SMTP sink, LAB_IDM_IP:1025, web/API :8025), both
#                        as pinned containers; groups, test users, the `litevirt`
#                        OIDC client; credentials into secrets/idm/ (0600)
#   idm.sh nodes [n...]  on the nodes: `<ip> <domain>` in /etc/hosts and the
#                        headless login helper (the lab CA: tools/lab-ca.sh trust)
#   idm.sh token <user>  an ID token's claims for a test user, from node-1 or
#                        TOKEN_VIA=n: the real auth-code + PKCE flow, headless
#   idm.sh check         discovery from every node, a token for every test user,
#                        and a mail sent from node-1 arriving in Mailpit
#
# Test users (all in litevirt_users, the group the OIDC scope map admits):
#   lvadmin  litevirt_admins     claim litevirt_groups: lv-admins
#   lvoper   litevirt_operators  claim litevirt_groups: lv-operators
#   lvview   litevirt_viewers    claim litevirt_groups: lv-viewers
#   lvmfa    litevirt_operators + litevirt_mfa (account policy: MFA required,
#            password + TOTP)
# Passwords and lvmfa's TOTP secret are in secrets/idm/ and never printed.
set -euo pipefail
# shellcheck source=storage-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/storage-lib.sh"

[[ " ${LAB_AUX_ROLES:-} " == *" idm "* ]] || die "idm is not in LAB_AUX_ROLES (lab.env)"
IDM_IP="${LAB_IDM_IP:-$LAN_PREFIX.50}"
DOMAIN="${LAB_IDM_DOMAIN:-idm.lab}"
IDM_DIR="$SECRETS/idm"
USERS="lvadmin lvoper lvview lvmfa"
# Pinned images (kanidm 1.11.2, Mailpit as of 2026-10-11).
KANIDM_IMG="kanidm/server@sha256:e45f00bd354c1fc1c06a4be484b4e87b094c431e78280f1d19e911815e63efb5"
KTOOLS_IMG="kanidm/tools@sha256:144783fc589ac9611f6149f54f95d0d9472c1bf6078e7ed5781be441bcca7d24"
MAILPIT_IMG="axllent/mailpit@sha256:94f6b70c1436defae6799d9ac7ff0eeff9540465b842026d5cdb018f1c0234ea"
idmssh() { SSH_TIMEOUT="${SSH_TIMEOUT:-900}" "$LAB/lab.sh" aux ssh idm "$@"; }
redirect() { echo "https://$LAN_PREFIX.11:8080/oidc/callback"; }

provision() {
  need_file "$SECRETS/lab-ca/ca.crt" "run: tools/lab-ca.sh init"
  [[ -f "$SECRETS/lab-ca/idm.crt" ]] || "$LAB/tools/lab-ca.sh" issue idm "DNS:$DOMAIN,IP:$IDM_IP"
  secrets_dir; mkdir -p "$IDM_DIR"; chmod 0700 "$IDM_DIR"
  local u
  for u in $USERS; do
    # Long random passwords: kanidm refuses weak ones.
    [[ -s "$IDM_DIR/$u.password" ]] || ( umask 077; openssl rand -base64 30 | tr -dc A-Za-z0-9 | head -c 28 > "$IDM_DIR/$u.password" )
  done
  # TLS material and the CA go in over stdin, never argv.
  cat "$SECRETS/lab-ca/idm.crt" "$SECRETS/lab-ca/ca.crt" | idmssh 'mkdir -p /srv/kanidm && chmod 0700 /srv/kanidm && cat > /srv/kanidm/chain.pem'
  idmssh 'umask 077; cat > /srv/kanidm/key.pem' < "$SECRETS/lab-ca/idm.key"
  idmssh 'cat > /usr/local/share/ca-certificates/litevirt-lab-ca.crt && update-ca-certificates >/dev/null 2>&1' < "$SECRETS/lab-ca/ca.crt"
  tar -C "$LAB/tools/idm-vm" -cf - . | idmssh 'mkdir -p /usr/local/lib/lab-idm && tar -C /usr/local/lib/lab-idm -xf - && chmod 0755 /usr/local/lib/lab-idm/*'
  local rc=0
  SSH_TIMEOUT=1800 idmssh 'bash -s' -- "$DOMAIN" "$IDM_IP" "$KANIDM_IMG" "$KTOOLS_IMG" "$MAILPIT_IMG" "$LAN_PREFIX" "$(redirect)" <<'REMOTE' || rc=$?
set -euo pipefail
DOMAIN="$1"; IP="$2"; KIMG="$3"; TIMG="$4"; MIMG="$5"; PREFIX="$6"; REDIRECT="$7"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1
dpkg -s docker.io >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y -qq docker.io >/dev/null; }
grep -q " $DOMAIN\$" /etc/hosts || echo "$IP $DOMAIN" >> /etc/hosts
cat > /srv/kanidm/server.toml <<EOF
version = "2"
bindaddress = "0.0.0.0:8443"
db_path = "/data/kanidm.db"
tls_chain = "/data/chain.pem"
tls_key = "/data/key.pem"
domain = "$DOMAIN"
origin = "https://$DOMAIN:8443"
EOF
if [[ "$(docker inspect -f '{{.Config.Image}}' kanidmd 2>/dev/null)" != "$KIMG" ]]; then
  docker rm -f kanidmd >/dev/null 2>&1 || true
  docker run -d --name kanidmd --restart unless-stopped --network host -v /srv/kanidm:/data "$KIMG" >/dev/null
fi
for _ in $(seq 1 30); do curl -sf "https://$DOMAIN:8443/status" >/dev/null && break; sleep 2; done
# Mailpit: SMTP on :1025 (no TLS, no auth: a sink), web UI + API on :8025.
if [[ "$(docker inspect -f '{{.Config.Image}}' mailpit 2>/dev/null)" != "$MIMG" ]]; then
  docker rm -f mailpit >/dev/null 2>&1 || true
  docker run -d --name mailpit --restart unless-stopped --network host -e MP_SMTP_BIND_ADDR="$IP:1025" \
    -e MP_UI_BIND_ADDR="$IP:8025" -e MP_MAX_MESSAGES=5000 "$MIMG" >/dev/null
fi
# The kanidm CLI, from the pinned tools image; its token cache stays in /root/.kanidm-cli.
mkdir -p /root/.kanidm-cli
cat > /usr/local/bin/kanidm <<EOF
#!/bin/sh
exec docker run --rm --network host -e KANIDM_PASSWORD -e KANIDM_URL=https://$DOMAIN:8443 -e KANIDM_CA_PATH=/ca.pem -v /usr/local/share/ca-certificates/litevirt-lab-ca.crt:/ca.pem:ro -v /root/.kanidm-cli:/root $TIMG kanidm "\$@"
EOF
chmod 0755 /usr/local/bin/kanidm
umask 077
if [[ ! -s /root/.kanidm-idm_admin.pw ]]; then
  for a in idm_admin admin; do
    docker exec kanidmd kanidmd recover-account "$a" 2>&1 | sed -nE 's/.*new_password: "([^"]+)".*/\1/p' > "/root/.kanidm-$a.pw"
  done
fi
KANIDM_PASSWORD="$(cat /root/.kanidm-idm_admin.pw)" kanidm login -D idm_admin >/dev/null 2>&1
K() { kanidm "$@" -D idm_admin </dev/null >/dev/null 2>&1 || true; }   # re-runs hit "exists": fine
for g in litevirt_users litevirt_admins litevirt_operators litevirt_viewers litevirt_mfa; do K group create "$g"; done
K person create lvadmin "litevirt lab admin";  K person create lvoper "litevirt lab operator"
K person create lvview "litevirt lab viewer";  K person create lvmfa "litevirt lab MFA operator"
for p in lvadmin lvoper lvview lvmfa; do K person update "$p" --mail "$p@$DOMAIN"; done
K group add-members litevirt_users lvadmin lvoper lvview lvmfa
K group add-members litevirt_admins lvadmin
K group add-members litevirt_operators lvoper lvmfa
K group add-members litevirt_viewers lvview
K group add-members litevirt_mfa lvmfa
# kanidm 1.11 requires MFA of every person by default (idm_all_persons). The lab
# wants both kinds: password-only users, and litevirt_mfa whose members must
# have a second factor.
K group account-policy credential-type-minimum idm_all_persons any
K group account-policy enable litevirt_mfa
K group account-policy credential-type-minimum litevirt_mfa mfa
K system oauth2 create litevirt "litevirt lab" "https://$PREFIX.11:8080"
for n in 1 2 3 4 5 6; do K system oauth2 add-redirect-url litevirt "https://$PREFIX.1$n:8080/oidc/callback"; done
K system oauth2 update-scope-map litevirt litevirt_users openid profile email groups
K system oauth2 update-claim-map litevirt litevirt_groups litevirt_admins lv-admins
K system oauth2 update-claim-map litevirt litevirt_groups litevirt_operators lv-operators
K system oauth2 update-claim-map litevirt litevirt_groups litevirt_viewers lv-viewers
K system oauth2 update-claim-map-join litevirt litevirt_groups array
K system oauth2 prefer-short-username litevirt
secret="$(kanidm system oauth2 show-basic-secret litevirt -D idm_admin </dev/null 2>/dev/null | tail -1)"
[[ -n "$secret" ]] || { echo "FAIL: no basic secret for the litevirt client"; exit 1; }
mkdir -p /etc/lab-idm
printf 'IDM_URL=https://%s:8443\nIDM_CA=/usr/local/share/ca-certificates/litevirt-lab-ca.crt\nOIDC_CLIENT_ID=litevirt\nOIDC_CLIENT_SECRET=%s\nOIDC_REDIRECT=%s\n' \
  "$DOMAIN" "$secret" "$REDIRECT" > /etc/lab-idm/oidc.env
fails=0
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok:   $d"; else echo "FAIL: $d"; fails=$((fails+1)); fi; }
chk "kanidm up (https://$DOMAIN:8443/status)" curl -sf "https://$DOMAIN:8443/status"
chk "OIDC discovery" curl -sf "https://$DOMAIN:8443/oauth2/openid/litevirt/.well-known/openid-configuration"
chk "mailpit SMTP $IP:1025" bash -c "exec 3<>/dev/tcp/$IP/1025"
chk "mailpit API $IP:8025" curl -sf "http://$IP:8025/api/v1/info"
[[ $fails -eq 0 ]]
REMOTE
  # Copy the client secret and the admin passwords to the lab's secrets (0600).
  idmssh 'cat /etc/lab-idm/oidc.env' > "$IDM_DIR/oidc.env.new" && mv -f "$IDM_DIR/oidc.env.new" "$IDM_DIR/oidc.env"
  idmssh 'grep ^OIDC_CLIENT_SECRET= /etc/lab-idm/oidc.env | cut -d= -f2-' > "$IDM_DIR/litevirt-client-secret"
  idmssh 'cat /root/.kanidm-idm_admin.pw' > "$IDM_DIR/kanidm-idm_admin.password"
  idmssh 'cat /root/.kanidm-admin.pw' > "$IDM_DIR/kanidm-admin.password"
  chmod 0600 "$IDM_DIR"/*
  # Set each user's password (and lvmfa's TOTP) once: a reset token per user,
  # used through the credential-update API.
  for u in $USERS; do
    [[ -f "$IDM_DIR/$u.set" ]] && continue
    local tok totp=""
    tok="$(idmssh "kanidm person credential create-reset-token $u -D idm_admin </dev/null 2>&1" | sed -nE 's/.*reset\?token=([A-Za-z0-9_-]+).*/\1/p' | head -1)"
    [[ -n "$tok" ]] || die "no reset token for $u"
    [[ "$u" == lvmfa ]] && totp="--totp /root/.lab-idm-$u.totp"
    # shellcheck disable=SC2086
    if { cat "$IDM_DIR/$u.password"; echo; } | idmssh "read -r LAB_USER_PASSWORD; export LAB_USER_PASSWORD; /usr/local/lib/lab-idm/kanidm-cred.py $u $tok $totp"; then
      if [[ -n "$totp" ]]; then idmssh "cat /root/.lab-idm-$u.totp" > "$IDM_DIR/$u.totp"; chmod 0600 "$IDM_DIR/$u.totp"; fi
      touch "$IDM_DIR/$u.set"
    else rc=1; fi
  done
  finish "idm provision" "$rc"
}

nodes() {
  local targets n fails=0
  if [[ $# -gt 0 ]]; then targets=("$@"); else mapfile -t targets < <(seq 1 "$NODES"); fi
  for n in "${targets[@]}"; do
    SSH_TIMEOUT=60 nodessh "$n" 'mkdir -p /usr/local/lib/lab-idm && cat > /usr/local/lib/lab-idm/oidc-login.py && chmod 0755 /usr/local/lib/lab-idm/oidc-login.py' < "$LAB/tools/idm-vm/oidc-login.py"
    if SSH_TIMEOUT=60 nodessh "$n" "grep -q ' $DOMAIN\$' /etc/hosts || echo '$IDM_IP $DOMAIN' >> /etc/hosts; curl -sf https://$DOMAIN:8443/oauth2/openid/litevirt/.well-known/openid-configuration >/dev/null"; then
      echo "ok:   node-$n resolves $DOMAIN and verifies its certificate"
    else echo "FAIL: node-$n"; fails=$((fails + 1)); fi
  done
  finish "idm nodes (${targets[*]})" "$fails"
}

# token <user> — run oidc-login.py (installed by `nodes`) on a node, with the
# client env and the user's credentials passed over stdin into a 0600 temp dir
# that is removed afterwards.
token() {
  local u="${1:?user}" via="${TOKEN_VIA:-1}"
  need_file "$IDM_DIR/$u.password" "run: tools/idm.sh provision"
  { cat "$IDM_DIR/oidc.env"; echo "LAB_USER_PASSWORD=$(cat "$IDM_DIR/$u.password")"
    if [[ -f "$IDM_DIR/$u.totp" ]]; then echo "LAB_USER_TOTP_B64=$(base64 -w0 < "$IDM_DIR/$u.totp")"; fi
  } | SSH_TIMEOUT=120 nodessh "$via" 'set -e; d=$(mktemp -d); trap "rm -rf $d" EXIT; umask 077; cat > $d/env
    set -a; . $d/env; set +a
    if [ -n "${LAB_USER_TOTP_B64:-}" ]; then printf "%s" "$LAB_USER_TOTP_B64" | base64 -d > $d/totp; export LAB_USER_TOTP=$d/totp; fi
    python3 -I /usr/local/lib/lab-idm/oidc-login.py '"$u"
}

check() {
  local fails=0 n u
  for n in $(seq 1 "$NODES"); do
    SSH_TIMEOUT=30 nodessh "$n" "curl -sf https://$DOMAIN:8443/oauth2/openid/litevirt/.well-known/openid-configuration | python3 -c 'import json,sys;d=json.load(sys.stdin);print(\"node-$n discovery: issuer\",d[\"issuer\"])'" || fails=$((fails + 1))
  done
  for u in $USERS; do
    if out="$(token "$u" 2>&1)"; then
      echo "$u: $(printf '%s' "$out" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("sub",d["sub"],"| preferred_username",d["preferred_username"],"| litevirt_groups",d["litevirt_groups"],"| login",d["login_mechanism"])')"
    else echo "FAIL: token for $u: $out"; fails=$((fails + 1)); fi
  done
  local subj="lab idm check $(date -u +%FT%TZ)"
  if SSH_TIMEOUT=60 nodessh 1 "python3 -c 'import smtplib;from email.message import EmailMessage as M;m=M();m[\"From\"]=\"node-1@lab\";m[\"To\"]=\"ops@$DOMAIN\";m[\"Subject\"]=\"$subj\";m.set_content(\"sent from node-1\");s=smtplib.SMTP(\"$IDM_IP\",1025,timeout=10);s.send_message(m);s.quit()'"; then
    sleep 2
    if idmssh "curl -sf 'http://$IDM_IP:8025/api/v1/search?query=subject:%22$(printf '%s' "$subj" | sed 's/ /%20/g')%22' | python3 -c 'import json,sys;d=json.load(sys.stdin);assert d[\"messages_count\"]>=1, d;print(\"mailpit received:\",d[\"messages\"][0][\"Subject\"],\"from\",d[\"messages\"][0][\"From\"][\"Address\"])'"; then :; else fails=$((fails + 1)); fi
  else echo "FAIL: SMTP from node-1"; fails=$((fails + 1)); fi
  finish "idm check" "$fails"
}

case "${1:-}" in
  provision) provision ;;
  nodes)     shift; nodes "$@" ;;
  token)     shift; token "$@" ;;
  check)     check ;;
  *) echo "usage: $0 {provision|nodes [n...]|token <user>|check}" >&2; exit 2 ;;
esac
