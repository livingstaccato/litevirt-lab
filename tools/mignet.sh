#!/usr/bin/env bash
# mignet.sh [node...] — give EXISTING nodes the guest side of the migration
# network (default: every node 1..N). Run on the lab host, from the lab dir.
#
# lab.env sets LAB_MIG_MCAST + LAB_MIG_PREFIX; lab.sh then adds a `mignet` NIC to
# a node's qemu argv and writes its netplan through cloud-init user-data. On a
# node that already booted, neither happens by itself: the NIC needs a qemu
# restart (no monitor socket to hot-plug through), and cloud-init never runs
# again, so the netplan file has to be written here.
#
#   apply   writes /etc/netplan/61-lab-extras.yaml (`lab.sh netplan-extras N`) when
#           the node has none, runs `netplan generate` to validate it, and nothing
#           else. No `netplan apply` (litevirt's bridges and the ssh NIC share the
#           netplan), no reboot, no packages. A file that exists but differs is
#           reported and left alone.
#   boot    `tools/node-cycle.sh N` (one node at a time) boots the node onto the
#           new qemu argv; netplan matches the NIC by MAC and addresses it.
#   verify  CHECK=1: the file, the NIC (by MAC), `mignet` and its address, and a
#           ping of every other target's migration address over mignet.
#
# Order: `lab.sh hub up mig` (only if LAB_NET_MODE is hub, the default), this
# script, `tools/node-cycle.sh N` per node, `CHECK=1 tools/mignet.sh`, then
# `tools/node-gaps.sh` + `tools/node-gaps.sh roll` for migration.network.
#
# CHECK=1 is read-only. Idempotent. Ends with PASS/FAIL.
set -euo pipefail
# shellcheck source=storage-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/storage-lib.sh"

[[ -n "${LAB_MIG_MCAST:-}" && -n "${LAB_MIG_PREFIX:-}" ]] ||
  die "lab.env sets no migration network (LAB_MIG_MCAST and LAB_MIG_PREFIX)"
CHECK="${CHECK:-0}"
MAC_PREFIX="${LAB_MAC_PREFIX:-52:54:00:77}"
migmac() { printf "$MAC_PREFIX:04:%02x" "$1"; }
migip()  { echo "$LAB_MIG_PREFIX.$((10 + $1))"; }
if [[ $# -gt 0 ]]; then targets=("$@"); else mapfile -t targets < <(seq 1 "$NODES"); fi

total=0
declare -A up=()
for n in "${targets[@]}"; do
  say "node-$n"
  doc="$("$LAB/lab.sh" netplan-extras "$n")"
  [[ -n "$doc" ]] || die "lab.sh netplan-extras $n printed nothing"
  doc64="$(printf '%s\n' "$doc" | base64 -w0)"
  rc=0
  out="$(SSH_TIMEOUT=120 nodessh "$n" 'bash -s' -- "$CHECK" "$(migmac "$n")" "$(migip "$n")" "$doc64" <<'REMOTE'
set -euo pipefail
CHECK="$1"; MAC="$2"; IP="$3"; DOC="$(printf '%s' "$4" | base64 -d)"
f=/etc/netplan/61-lab-extras.yaml
fails=0
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok:   $d"; else echo "FAIL: $d"; fails=$((fails+1)); fi; }
if [[ "$CHECK" != 1 ]]; then
  if [[ ! -e $f ]]; then
    umask 077; printf '%s\n' "$DOC" > $f.new; mv -f $f.new $f
    echo "netplan: wrote $f (takes effect at the node's next boot, once the NIC exists)"
  elif [[ "$(cat $f)" != "$DOC" ]]; then
    echo "note: $f exists and differs from lab.sh netplan-extras; left alone"
  fi
  netplan generate
fi
chk "$f matches lab.sh netplan-extras" sh -c "[ \"\$(cat $f 2>/dev/null)\" = \"\$1\" ]" _ "$DOC"
chk "NIC $MAC present (qemu restarted with the mig netdev)" sh -c "ip -o link | grep -qi 'link/ether $MAC'"
chk "interface named mignet" ip link show mignet
chk "mignet has $IP/24" sh -c "ip -4 -o addr show mignet | grep -qF ' $IP/24'"
ip -4 -o addr show mignet 2>/dev/null | grep -qF " $IP/24" && echo "MIGUP=1"
[[ $fails -eq 0 ]]
REMOTE
)" || rc=$?
  printf '%s\n' "$out" | grep -v '^MIGUP=1$'
  grep -qx 'MIGUP=1' <<<"$out" && up[$n]=1
  [[ $rc -eq 0 ]] || total=$((total + 1))
done

# Reachability over mignet between every pair that has it up.
for a in "${targets[@]}"; do
  [[ -n "${up[$a]:-}" ]] || continue
  for b in "${targets[@]}"; do
    [[ "$a" != "$b" && -n "${up[$b]:-}" ]] || continue
    if SSH_TIMEOUT=20 nodessh "$a" "ping -c2 -W2 -I mignet $(migip "$b") >/dev/null 2>&1"; then
      echo "ok:   node-$a -> node-$b over mignet ($(migip "$b"))"
    else
      echo "FAIL: node-$a -> node-$b over mignet ($(migip "$b"))"; total=$((total + 1))
    fi
  done
done
finish "mignet (${targets[*]})" "$total"
