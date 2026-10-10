#!/usr/bin/env bash
# node-clients.sh [node...] — storage clients on the litevirt nodes (default 1..N).
#
#   nfs    nfs-common
#   iscsi  open-iscsi, a UNIQUE initiator IQN per node (node_iqn N), CHAP in
#          iscsid.conf from $LAB/secrets/iscsi-chap; test login + logout
#   ceph   ceph-common, /etc/ceph/ceph.conf and the RESTRICTED client.litevirt
#          keyring (0600). The admin keyring is never installed, and a stray one
#          already on a node is reported as a failure.
#
# Run after nfs-server.sh, iscsi-target.sh and ceph.sh (it checks against them).
# CLIENTS="nfs iscsi" limits what is installed/checked (default "nfs iscsi ceph").
# Idempotent. Ends with PASS/FAIL.
set -euo pipefail
# shellcheck source=storage-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/storage-lib.sh"

CLIENTS="${CLIENTS:-nfs iscsi ceph}"
if [[ $# -gt 0 ]]; then targets=("$@"); else mapfile -t targets < <(seq 1 "$NODES"); fi
want() { [[ " $CLIENTS " == *" $1 "* ]]; }

want iscsi && need_file "$ISCSI_CHAP" "run tools/iscsi-target.sh first"
if want ceph; then
  need_file "$CEPH_KEYRING" "run tools/ceph.sh first"
  need_file "$CEPH_CONF" "run tools/ceph.sh first"
fi

total=0
for n in "${targets[@]}"; do
  say "node-$n: waiting"
  wait_ready node "$n"

  # Credentials are installed by stdin into 0600 files, never through argv.
  if want iscsi; then
    nodessh "$n" 'umask 077; cat > /root/.lv-iscsi-chap' < "$ISCSI_CHAP"
  fi
  if want ceph; then
    nodessh "$n" 'umask 077; mkdir -p /etc/ceph; cat > /etc/ceph/ceph.client.litevirt.keyring.new && chmod 0600 /etc/ceph/ceph.client.litevirt.keyring.new && mv -f /etc/ceph/ceph.client.litevirt.keyring.new /etc/ceph/ceph.client.litevirt.keyring' < "$CEPH_KEYRING"
    nodessh "$n" 'cat > /etc/ceph/ceph.conf.new && chmod 0644 /etc/ceph/ceph.conf.new && mv -f /etc/ceph/ceph.conf.new /etc/ceph/ceph.conf' < "$CEPH_CONF"
  fi

  say "node-$n: provisioning ($CLIENTS)"
  rc=0
  SSH_TIMEOUT=900 nodessh "$n" 'bash -s' -- "$CLIENTS" "$(node_iqn "$n")" "$ISCSI_IQN" "$NFS_IP" "$ISCSI_PORT" "$CEPH_POOL" "$CEPH_CLIENT" <<'REMOTE' || rc=$?
set -euo pipefail
CLIENTS="$1"; MYIQN="$2"; TIQN="$3"; NFS_IP="$4"; PORT="$5"; POOL="$6"; CLIENT="$7"
export DEBIAN_FRONTEND=noninteractive
# The plaintext CHAP copy never outlives the run, whatever fails.
trap 'shred -u /root/.lv-iscsi-chap 2>/dev/null || rm -f /root/.lv-iscsi-chap' EXIT
fails=0
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok:   $d"; else echo "FAIL: $d"; fails=$((fails+1)); fi; }
want() { [[ " $CLIENTS " == *" $1 "* ]]; }
install_pkgs() {
  local missing=() p
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  [[ ${#missing[@]} -eq 0 ]] || { apt-get update -qq; apt-get install -y -qq "${missing[@]}"; }
}
# setconf <file> <key> <value> — replace "key = ..." (commented or not), else append.
setconf() {
  if grep -qE "^[#[:space:]]*$2[[:space:]]*=" "$1"; then sed -i -E "s|^[#[:space:]]*$2[[:space:]]*=.*|$2 = $3|" "$1"
  else echo "$2 = $3" >> "$1"; fi
}

if want nfs; then
  install_pkgs nfs-common
  chk "nfs-common installed" dpkg -s nfs-common
  chk "$NFS_IP exports /srv/lv" bash -c "showmount -e $NFS_IP | grep -q '^/srv/lv '"
fi

if want iscsi; then
  install_pkgs open-iscsi
  # shellcheck source=/dev/null
  . /root/.lv-iscsi-chap
  want_line="InitiatorName=$MYIQN"
  if [[ "$(cat /etc/iscsi/initiatorname.iscsi 2>/dev/null | grep '^InitiatorName=' || true)" != "$want_line" ]]; then
    if iscsiadm -m session >/dev/null 2>&1; then
      echo "FAIL: initiator IQN differs but iSCSI sessions are live; log them out first"; fails=$((fails+1))
    else
      printf '## DO NOT EDIT OR REMOVE THIS FILE!\n%s\n' "$want_line" > /etc/iscsi/initiatorname.iscsi
      systemctl restart iscsid
    fi
  fi
  setconf /etc/iscsi/iscsid.conf node.session.auth.authmethod CHAP
  setconf /etc/iscsi/iscsid.conf node.session.auth.username "$CHAP_USER"
  setconf /etc/iscsi/iscsid.conf node.session.auth.password "$CHAP_PASS"
  chmod 0600 /etc/iscsi/iscsid.conf
  systemctl enable --now iscsid >/dev/null 2>&1 || true
  chk "initiator IQN is $MYIQN" grep -qx "$want_line" /etc/iscsi/initiatorname.iscsi
  chk "iscsid.conf uses CHAP" grep -qE '^node.session.auth.authmethod = CHAP$' /etc/iscsi/iscsid.conf
  chk "iscsid.conf is 0600" test "$(stat -c %a /etc/iscsi/iscsid.conf)" = 600
  chk "discovery of $NFS_IP:$PORT lists $TIQN" bash -c "iscsiadm -m discovery -t st -p $NFS_IP:$PORT | grep -qF '$TIQN'"
  # Prove ACL + CHAP end to end: log in, see the LUN, log out again — unless a
  # session (litevirt's pool) already exists, which is left alone.
  by_path="/dev/disk/by-path/ip-$NFS_IP:$PORT-iscsi-$TIQN-lun-0"
  had=0; iscsiadm -m session 2>/dev/null | grep -qF "$TIQN" && had=1
  if [[ "$had" -eq 0 ]]; then iscsiadm -m node -T "$TIQN" -p "$NFS_IP:$PORT" --login >/dev/null 2>&1 || true; fi
  for _ in $(seq 1 20); do [[ -b "$by_path" ]] && break; sleep 1; done
  chk "login succeeds and LUN 0 appears at $by_path" test -b "$by_path"
  if [[ "$had" -eq 0 ]]; then iscsiadm -m node -T "$TIQN" -p "$NFS_IP:$PORT" --logout >/dev/null 2>&1 || true; fi
fi

if want ceph; then
  install_pkgs ceph-common
  chk "ceph.conf present" test -s /etc/ceph/ceph.conf
  chk "client keyring is 0600" test "$(stat -c %a /etc/ceph/ceph.client.$CLIENT.keyring)" = 600
  chk "no admin keyring on this node" bash -c "! ls /etc/ceph/*admin* >/dev/null 2>&1"
  chk "client.$CLIENT can rbd ls $POOL" rbd --id "$CLIENT" --conf /etc/ceph/ceph.conf --keyring "/etc/ceph/ceph.client.$CLIENT.keyring" ls "$POOL"
fi
exit "$fails"
REMOTE
  [[ "$rc" -eq 0 ]] || total=$((total + 1))
done
finish node-clients "$total"
