#!/usr/bin/env bash
# nfs-server.sh — turn the lab's NFS storage VM into an NFS server.
#
# Formats the 100G data disk (only if it is blank), mounts it at /srv/lv, and
# exports /srv/lv to the lab subnet ONLY with rw,sync,no_root_squash,
# no_subtree_check. Idempotent; re-run any time. Run on the lab host, from the
# lab dir, after `lab.sh storage up nfs`. Ends with PASS/FAIL.
set -euo pipefail
# shellcheck source=storage-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/storage-lib.sh"

say "waiting for $(vm_name nfs)"
wait_ready vm nfs

say "provisioning NFS on $(vm_name nfs) ($NFS_IP), exporting /srv/lv to $LAN_SUBNET"
rc=0
SSH_TIMEOUT=900 vmssh nfs 'bash -s' -- "$LAN_SUBNET" <<'REMOTE' || rc=$?
set -euo pipefail
SUBNET="$1"
DEV=/dev/disk/by-id/virtio-lvnfsdata
export DEBIAN_FRONTEND=noninteractive
fails=0
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok:   $d"; else echo "FAIL: $d"; fails=$((fails+1)); fi; }

dpkg -s nfs-kernel-server >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y -qq nfs-kernel-server; }
[[ -b "$DEV" ]] || { echo "FAIL: $DEV missing (data disk not attached?)"; exit 1; }
# Only a blank disk is formatted; anything with a signature is left alone.
blkid "$DEV" >/dev/null 2>&1 || mkfs.ext4 -q -L lvnfs "$DEV"
uuid="$(blkid -s UUID -o value "$DEV")"
mkdir -p /srv/lv
grep -q "^UUID=$uuid /srv/lv " /etc/fstab || echo "UUID=$uuid /srv/lv ext4 defaults,nofail 0 2" >> /etc/fstab
mountpoint -q /srv/lv || mount /srv/lv
chmod 0755 /srv/lv
mkdir -p /etc/exports.d
printf '/srv/lv %s(rw,sync,no_root_squash,no_subtree_check)\n' "$SUBNET" > /etc/exports.d/litevirt-lab.exports
systemctl enable --now nfs-server >/dev/null 2>&1
exportfs -ra

# exportfs -v wraps long lines; flatten so one regex sees the whole entry.
exp="$(exportfs -v | tr '\n\t' '  ' | tr -s ' ')"
chk "/srv/lv is a mountpoint" mountpoint -q /srv/lv
chk "nfs-server is active" systemctl is-active --quiet nfs-server
chk "/srv/lv is exported to $SUBNET" grep -q "/srv/lv $SUBNET(" <<<"$exp"
chk "exactly one client spec (no wildcard, no other host)" test "$(grep -o '(' <<<"$exp" | wc -l)" -eq 1
for o in rw sync no_root_squash no_subtree_check; do
  chk "export option $o" grep -Eq "[(,]$o[,)]" <<<"$exp"
done
exit "$fails"
REMOTE
finish nfs-server "$((rc != 0))"
