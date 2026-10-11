#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are consumed by the scripts that source this
# Shared helpers for the shared-storage scripts (tools/*.sh). Sourced, not run.
#
# Same rules as lab.sh: the instance identity comes from the lab.env beside
# lab.sh and only from there (LAB_* names are cleared first), and every ssh is
# agent-free (-o IdentityAgent=none -o IdentitiesOnly=yes) and bounded by
# timeout(1) + ConnectTimeout, so a wedged VM fails the step instead of hanging
# the runner. These scripts run on the lab host (kvm003-f3), from the lab dir.

LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset LAB_NODES LAB_SEEDPORT LAB_MCAST LAB_SSH_PORT_BASE LAB_LAN_PREFIX LAB_MAC_PREFIX LAB_QEMU_NAME
unset LAB_STORAGE_PREFIX LAB_STORAGE_SSH_PORT_BASE LAB_STORAGE_NFS_IP LAB_STORAGE_CEPH_IP
unset LAB_NODE_HW LAB_NODE_HW_NODES LAB_NODE_MEM LAB_NODE_QMP LAB_IGB_MCAST \
      LAB_MIG_MCAST LAB_MIG_PREFIX LAB_TRUNK_MCAST LAB_LAN6_PREFIX LAB_CGROUP_V1_NODES \
      LAB_AUX_ROLES LAB_AUX_SSH_PORT_BASE LAB_BMC_IP LAB_BMC_IPMI_BASE LAB_BMC_NODES \
      LAB_BMC_AGENT_PORT LAB_IDM_IP LAB_IDM_DOMAIN
# shellcheck source=/dev/null
[[ -f "$LAB/lab.env" ]] && . "$LAB/lab.env"

NODES="${NODES:-${LAB_NODES:-4}}"
LAN_PREFIX="${LAB_LAN_PREFIX:-10.77.0}"
SSH_PORT_BASE="${LAB_SSH_PORT_BASE:-2230}"
STORAGE_PREFIX="${LAB_STORAGE_PREFIX:-lab}"
STORAGE_SSH_BASE="${LAB_STORAGE_SSH_PORT_BASE:-2250}"
NFS_IP="${LAB_STORAGE_NFS_IP:-$LAN_PREFIX.21}"
CEPH_IP="${LAB_STORAGE_CEPH_IP:-$LAN_PREFIX.22}"
LAN_SUBNET="$LAN_PREFIX.0/24"
# The lab's own throwaway key (lab.sh create authorizes it everywhere).
LAB_SSH_KEY="${LAB_SSH_KEY:-$LAB/cluster_key}"

SECRETS="$LAB/secrets"           # 0700; CHAP credentials and the ceph client key
ISCSI_CHAP="$SECRETS/iscsi-chap" # 0600; CHAP_USER=... / CHAP_PASS=...
CEPH_KEYRING="$SECRETS/ceph.client.litevirt.keyring"  # 0600
CEPH_CONF="$SECRETS/ceph.conf"   # minimal conf, no secrets
CEPH_POOL=lv
CEPH_CLIENT=litevirt

ISCSI_PORT=3260
ISCSI_IQN="iqn.2026-10.lab.litevirt.$STORAGE_PREFIX:$STORAGE_PREFIX-nfs.lun0"
node_iqn() { echo "iqn.2026-10.lab.litevirt.$STORAGE_PREFIX:node-$1"; }

say()  { echo "== $*"; }
die()  { echo "FAIL: $*" >&2; exit 1; }

# vm_ip / vm_port <nfs|ceph>
vm_ip()   { case "$1" in nfs) echo "$NFS_IP";; ceph) echo "$CEPH_IP";; *) return 1;; esac; }
vm_port() { case "$1" in nfs) echo $((STORAGE_SSH_BASE + 1));; ceph) echo $((STORAGE_SSH_BASE + 2));; *) return 1;; esac; }
vm_name() { echo "$STORAGE_PREFIX-$1"; }
# storage_role <nfs|ceph|<name>> -> role, or fails
storage_role() {
  case "$1" in
    nfs|"$(vm_name nfs)") echo nfs ;;
    ceph|"$(vm_name ceph)") echo ceph ;;
    *) return 1 ;;
  esac
}

_ssh_base=( -i "$LAB_SSH_KEY" -o IdentityAgent=none -o IdentitiesOnly=yes
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
            -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4
            -o LogLevel=ERROR )

# vmssh <role> [cmd...]  /  nodessh <n> [cmd...] — root ssh, stdin passes through.
# SSH_TIMEOUT (seconds, default 600) bounds the whole call.
vmssh() {
  local r="$1"; shift
  timeout "${SSH_TIMEOUT:-600}" ssh "${_ssh_base[@]}" -p "$(vm_port "$r")" root@127.0.0.1 "$@"
}
nodessh() {
  local n="$1"; shift
  timeout "${SSH_TIMEOUT:-600}" ssh "${_ssh_base[@]}" -p "$((SSH_PORT_BASE + n))" root@127.0.0.1 "$@"
}

# wait_ready <vm|node> <id> — wait (up to ~5 min) for sshd AND cloud-init to finish.
wait_ready() {
  local kind="$1" id="$2"
  for _ in $(seq 1 60); do
    if SSH_TIMEOUT=20 "${kind}ssh" "$id" 'test -f /var/lib/cloud/lab-ready' 2>/dev/null; then return 0; fi
    sleep 5
  done
  die "$kind $id not ready after 5 min (cloud-init unfinished?): $LAB/lab.sh storage status"
}

# need_file <path> <hint>
need_file() { [[ -f "$1" ]] || die "missing $1 — $2"; }

# secrets_dir — create the 0700 dir that holds credentials.
secrets_dir() { mkdir -p "$SECRETS"; chmod 0700 "$SECRETS"; }

# finish <name> <failures> — the final PASS/FAIL line every script ends with.
finish() {
  if [[ "$2" -eq 0 ]]; then echo "PASS: $1"; exit 0; fi
  echo "FAIL: $1 ($2 check(s) failed)"; exit 1
}
