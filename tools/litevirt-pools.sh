#!/usr/bin/env bash
# litevirt-pools.sh — create the shared-storage pools `nfs`, `iscsi`, `ceph` on
# every litevirt node, via `litevirt pool create` run on node-1.
#
# litevirt pools are per host: a pool row belongs to one host, so each pool is
# created once per node with --host node-N (the same name on every host is how a
# shared store is declared; docs/storage.md). Creation runs the driver's
# Prepare() on that host (NFS mount / iSCSI discovery+login / `rbd ls`), so a
# bad client setup fails here, not at first VM create.
#
#   nfs    --driver nfs   --source <nfs-ip>:/srv/lv  --option options=vers=4.2
#   iscsi  --driver iscsi --source <target IQN>
#                         --option portal=<nfs-ip>:3260 --option lun=0
#   ceph   --driver ceph  --source lv  --option id=litevirt
#                         --option conf=/etc/ceph/ceph.conf
#                         --option keyring=/etc/ceph/ceph.client.litevirt.keyring
#
# The iSCSI portal carries the port on purpose: the driver builds the LUN path
# /dev/disk/by-path/ip-<portal>-iscsi-<iqn>-lun-0 from it verbatim, and udev
# always writes ip-<addr>:3260-.... The iSCSI driver hands every disk the same
# LUN path, so one iSCSI-pool VM disk per LUN.
# `--option` is a comma-split slice flag: values here contain no commas.
#
# Needs the litevirt cluster up and node-clients.sh done. Pool creation takes
# `storage.hostpath` (Admin): if `litevirt` answers "session revoked" on node-1,
# see README "Lab CLI auth". Idempotent: a pool already listed is skipped.
# ONLY="nfs ceph" limits the pools. Ends with PASS/FAIL.
set -euo pipefail
# shellcheck source=storage-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/storage-lib.sh"

ONLY="${ONLY:-nfs iscsi ceph}"
LV="${LV_BIN:-litevirt}"

say "checking the cluster answers on node-1"
SSH_TIMEOUT=60 nodessh 1 "$LV host ls" >/dev/null || die "'$LV host ls' failed on node-1 (cluster down, or CLI session stale: README 'Lab CLI auth')"

listing() { SSH_TIMEOUT=60 nodessh 1 "$LV pool ls"; }
have() { awk -v h="$1" -v p="$2" '$1==h && $2==p {f=1} END{exit !f}' <<<"$3"; }

create() {   # create <node> <pool> <args...>
  local n="$1" pool="$2"; shift 2
  local cmd="$LV pool create $pool --host node-$n" a
  for a in "$@"; do cmd+=" $(printf '%q' "$a")"; done
  SSH_TIMEOUT=300 nodessh 1 "$cmd"
}

existing="$(listing)"
errs=0
for n in $(seq 1 "$NODES"); do
  for pool in $ONLY; do
    if have "node-$n" "$pool" "$existing"; then echo "node-$n: pool $pool already exists"; continue; fi
    echo "node-$n: creating pool $pool"
    case "$pool" in
      nfs)   args=(--driver nfs --source "$NFS_IP:/srv/lv" --option options=vers=4.2) ;;
      iscsi) args=(--driver iscsi --source "$ISCSI_IQN" --option "portal=$NFS_IP:$ISCSI_PORT" --option lun=0) ;;
      ceph)  args=(--driver ceph --source "$CEPH_POOL" --option "id=$CEPH_CLIENT"
                   --option conf=/etc/ceph/ceph.conf
                   --option "keyring=/etc/ceph/ceph.client.$CEPH_CLIENT.keyring") ;;
      *) die "unknown pool '$pool' in ONLY (want nfs iscsi ceph)" ;;
    esac
    create "$n" "$pool" "${args[@]}" || { echo "FAIL: node-$n pool $pool"; errs=$((errs + 1)); }
  done
done

say "verifying"
final="$(listing)"
echo "$final"
for n in $(seq 1 "$NODES"); do
  for pool in $ONLY; do
    if ! awk -v h="node-$n" -v p="$pool" '$1==h && $2==p && $NF=="active" {f=1} END{exit !f}' <<<"$final"; then
      echo "FAIL: node-$n pool $pool is not listed active"; errs=$((errs + 1))
    fi
  done
done
finish litevirt-pools "$errs"
