#!/usr/bin/env bash
# lease-term-roll.sh on|off [nodes...] — set enforcement.lease_term on lab nodes
# and roll their daemons, one node at a time. Run on the lab host, from the lab
# dir (lab 1: ~/litevirt-lab). Ends with PASS/FAIL.
#
# Per node:
#   1. Back up /etc/litevirt/config.yaml to /root/config.yaml.pre-lease-term
#      (first run only; never overwritten).
#   2. Set `lease_term: true|false` under `enforcement:` (replaces an existing
#      lease_term line; otherwise adds one directly under `enforcement:`).
#   3. `systemctl restart litevirt`, wait for it to be active.
#   4. Wait until another node lists this node HOST_ACTIVE continuously for
#      STABLE_SECS (default 60) before touching the next node.
# Stops at the first node that does not come back; nodes after it are untouched.
#
# `off` is the way back: lease_term_v1 stops being advertised and enforced once
# every node runs with the flag off (the latch itself stays recorded).
set -euo pipefail
# shellcheck source=storage-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/storage-lib.sh"

mode="${1:?usage: lease-term-roll.sh on|off [nodes...]}"; shift
case "$mode" in on) val=true ;; off) val=false ;; *) die "mode must be on or off" ;; esac
nodes=("$@"); [[ ${#nodes[@]} -gt 0 ]] || mapfile -t nodes < <(seq 1 "$NODES")
cfg=/etc/litevirt/config.yaml

host_state() { # host_state <n> <via>
  SSH_TIMEOUT=20 nodessh "$2" "litevirt host ls 2>/dev/null | awk '\$1==\"node-$1\"{print \$3}'" 2>/dev/null || true
}

for n in "${nodes[@]}"; do
  via=1; [[ "$n" == 1 ]] && via=2
  say "node-$n: enforcement.lease_term=$val at $(date -u +%T)"
  SSH_TIMEOUT=30 nodessh "$n" "set -e
    test -f $cfg
    cp -n $cfg /root/config.yaml.pre-lease-term
    grep -q '^enforcement:' $cfg || printf 'enforcement:\n' >> $cfg
    if awk '/^enforcement:/{f=1;next} /^[^ ]/{f=0} f && /^  lease_term:/{found=1} END{exit !found}' $cfg; then
      sed -i '/^enforcement:/,/^[^ ]/ s/^  lease_term:.*/  lease_term: $val/' $cfg
    else
      sed -i '/^enforcement:/a\\  lease_term: $val' $cfg
    fi
    awk '/^enforcement:/{f=1;print;next} /^[^ ]/{f=0} f' $cfg" ||
    die "node-$n: could not edit $cfg"
  SSH_TIMEOUT=60 nodessh "$n" 'systemctl restart litevirt' || die "node-$n: restart failed"
  for _ in $(seq 1 60); do
    [[ "$(SSH_TIMEOUT=10 nodessh "$n" 'systemctl is-active litevirt' 2>/dev/null)" == active ]] && break; sleep 5
  done
  [[ "$(SSH_TIMEOUT=10 nodessh "$n" 'systemctl is-active litevirt' 2>/dev/null)" == active ]] ||
    die "node-$n: litevirt not active 5 min after restart (backup: /root/config.yaml.pre-lease-term)"
  since=0; ok=""
  for _ in $(seq 1 120); do
    if [[ "$(host_state "$n" "$via")" == HOST_ACTIVE ]]; then
      [[ $since -gt 0 ]] || since=$(date +%s)
      (( $(date +%s) - since >= ${STABLE_SECS:-60} )) && { ok=1; break; }
    else
      since=0
    fi
    sleep 5
  done
  [[ -n "$ok" ]] || die "node-$n: not HOST_ACTIVE for ${STABLE_SECS:-60}s through node-$via; stopping the roll here"
  say "node-$n: HOST_ACTIVE, stable at $(date -u +%T)"
done

say "lease_term_v1 in upgrade-status (latches once every node advertises it; may take a minute):"
SSH_TIMEOUT=30 nodessh 1 'litevirt cluster upgrade-status 2>/dev/null | grep -i lease_term' || true
echo "PASS: enforcement.lease_term=$val on node(s) ${nodes[*]}"
