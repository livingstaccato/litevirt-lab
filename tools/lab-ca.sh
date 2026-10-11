#!/usr/bin/env bash
# lab-ca.sh — a small private CA for the lab's own TLS services (the Redfish
# simulator, kanidm), and its installation on the nodes. Run on the lab host.
#
#   lab-ca.sh init                      secrets/lab-ca/ca.{key,crt} (P-256, 10 years), once
#   lab-ca.sh issue <name> <san,...>    secrets/lab-ca/<name>.{key,crt}, e.g.
#                                       issue idm DNS:idm.lab,IP:10.77.0.50 (825 days)
#   lab-ca.sh trust [node...]           install ca.crt in each node's system trust
#                                       store (update-ca-certificates), default 1..N
#
# The CA key never leaves secrets/ (0700); only certificates and service keys
# are copied out, by the scripts that need them. Ends with PASS/FAIL.
set -euo pipefail
# shellcheck source=storage-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/storage-lib.sh"

CA_DIR="$SECRETS/lab-ca"
CA_KEY="$CA_DIR/ca.key"
CA_CRT="$CA_DIR/ca.crt"
CA_NAME="litevirt-$(basename "$LAB")"   # e.g. litevirt-litevirt-lab: one CA per lab

init() {
  secrets_dir; mkdir -p "$CA_DIR"; chmod 0700 "$CA_DIR"
  if [[ -f "$CA_KEY" && -f "$CA_CRT" ]]; then echo "CA exists: $CA_CRT"; return; fi
  ( umask 077; openssl ecparam -name prime256v1 -genkey -noout -out "$CA_KEY" )
  openssl req -x509 -new -key "$CA_KEY" -sha256 -days 3650 -subj "/CN=$CA_NAME lab CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" -out "$CA_CRT"
  echo "CA created: $CA_CRT ($(openssl x509 -in "$CA_CRT" -noout -fingerprint -sha256 | cut -d= -f2))"
}

issue() {
  local name="${1:?name}" sans="${2:?san list}"
  [[ "$name" =~ ^[a-z0-9-]+$ ]] || die "bad name $name"
  need_file "$CA_KEY" "run: tools/lab-ca.sh init"
  local cn="${sans%%,*}"; cn="${cn#*:}"
  ( umask 077; openssl ecparam -name prime256v1 -genkey -noout -out "$CA_DIR/$name.key" )
  openssl req -new -key "$CA_DIR/$name.key" -subj "/CN=$cn" -out "$CA_DIR/$name.csr"
  openssl x509 -req -in "$CA_DIR/$name.csr" -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
    -days 825 -sha256 -out "$CA_DIR/$name.crt" \
    -extfile <(printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature\nbasicConstraints=critical,CA:FALSE\n' "$sans") 2>/dev/null
  rm -f "$CA_DIR/$name.csr"
  echo "issued $CA_DIR/$name.crt for $sans"
}

trust() {
  need_file "$CA_CRT" "run: tools/lab-ca.sh init"
  local targets fails=0 n
  if [[ $# -gt 0 ]]; then targets=("$@"); else mapfile -t targets < <(seq 1 "$NODES"); fi
  for n in "${targets[@]}"; do
    if SSH_TIMEOUT=120 nodessh "$n" "cat > /usr/local/share/ca-certificates/$CA_NAME.crt && update-ca-certificates >/dev/null 2>&1 && openssl verify -CApath /etc/ssl/certs /usr/local/share/ca-certificates/$CA_NAME.crt >/dev/null" < "$CA_CRT"; then
      echo "ok:   node-$n trusts $CA_NAME"
    else
      echo "FAIL: node-$n trust store"; fails=$((fails + 1))
    fi
  done
  finish "lab-ca trust (${targets[*]})" "$fails"
}

case "${1:-}" in
  init)  init ;;
  issue) shift; issue "$@" ;;
  trust) shift; trust "$@" ;;
  *) echo "usage: $0 {init|issue <name> <san,...>|trust [node...]}" >&2; exit 2 ;;
esac
