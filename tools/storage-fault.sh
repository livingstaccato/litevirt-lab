#!/usr/bin/env bash
# storage-fault.sh — fault hooks for fence / partition drills on shared storage.
#
#   storage-fault.sh <storage-vm> stop      power-cut the storage VM (kills its qemu)
#   storage-fault.sh <storage-vm> start     boot it again, disks intact
#   storage-fault.sh cut  <lab-node> [<storage-vm>|all]
#                                           drop ONE node's traffic to the storage
#                                           VM IP(s) with nft (default: all)
#   storage-fault.sh heal <lab-node>        remove that node's drop rules
#
# <storage-vm> is nfs | ceph | <prefix>-nfs | <prefix>-ceph; <lab-node> is N or
# node-N. `cut` installs its own nft table (inet lv_storage_fault) on that node
# and touches nothing else: output to the storage IP is dropped, so the node's
# other traffic — and the node's ssh, which rides the NAT NIC, not the LAN —
# keeps working. BOTH=1 also drops the replies (input from the storage IP).
# Idempotent. Ends with PASS/FAIL.
set -euo pipefail
# shellcheck source=storage-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/storage-lib.sh"

TABLE=lv_storage_fault
usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
node_num() { local n="${1#node-}"; [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 && "$n" -le "$NODES" ]] || die "no lab node '$1' (1..$NODES)"; echo "$n"; }

[[ $# -ge 2 ]] || usage
case "$1" in
  cut|heal) action="$1"; node="$(node_num "$2")"; target="${3:-all}" ;;
  *)        action="$2"; role="$(storage_role "$1")" || usage ;;
esac

fails=0
rule_present() { SSH_TIMEOUT=30 nodessh "$node" "nft list table inet $TABLE" | grep -q "daddr.*$1"; }
unreachable()  { ! SSH_TIMEOUT=30 nodessh "$node" "ping -c1 -W2 $1" >/dev/null 2>&1; }
table_gone()   { ! SSH_TIMEOUT=30 nodessh "$node" "nft list table inet $TABLE" >/dev/null 2>&1; }
vm_is_down()   { "$LAB/lab.sh" storage status "$role" | awk -v n="$(vm_name "$role")" '$1==n && $2=="-" {f=1} END{exit !f}'; }
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok:   $d"; else echo "FAIL: $d"; fails=$((fails+1)); fi; }

case "$action" in
  stop)
    "$LAB/lab.sh" storage down "$role"
    chk "$(vm_name "$role") has no running qemu" vm_is_down
    finish "storage-fault stop $(vm_name "$role")" "$fails" ;;
  start)
    "$LAB/lab.sh" storage up "$role"
    wait_ready vm "$role"
    chk "$(vm_name "$role") answers ssh" vmssh "$role" true
    echo "note: services return on their own (nfs-server, rtslib-fb-targetctl, ceph daemons); give ceph ~1 min to go active+clean"
    finish "storage-fault start $(vm_name "$role")" "$fails" ;;
  cut)
    ips=()
    case "$target" in
      all)  ips=("$NFS_IP" "$CEPH_IP") ;;
      *)    r="$(storage_role "$target")" || die "unknown storage VM '$target'"; ips=("$(vm_ip "$r")") ;;
    esac
    list="$(IFS=,; echo "${ips[*]}")"
    in_rule=""; [[ "${BOTH:-0}" == 1 ]] && in_rule="chain input { type filter hook input priority -10; policy accept; ip saddr { $list } drop; }"
    say "node-$node: dropping traffic to $list"
    nodessh "$node" "nft delete table inet $TABLE 2>/dev/null || true; nft -f -" <<NFT
table inet $TABLE {
  chain output { type filter hook output priority -10; policy accept; ip daddr { $list } drop; }
  $in_rule
}
NFT
    for ip in "${ips[@]}"; do
      chk "node-$node has a drop rule for $ip" rule_present "$ip"
      chk "node-$node cannot reach $ip" unreachable "$ip"
    done
    finish "storage-fault cut node-$node" "$fails" ;;
  heal)
    say "node-$node: removing $TABLE"
    nodessh "$node" "nft delete table inet $TABLE 2>/dev/null || true"
        chk "node-$node has no $TABLE table" table_gone
    finish "storage-fault heal node-$node" "$fails" ;;
  *) usage ;;
esac
