#!/usr/bin/env bash
# iscsi-target.sh — an iSCSI target (LIO, targetcli-fb) on the NFS storage VM.
#
# One block backstore on the extra 50G disk (virtio serial lviscsi), one IQN, one
# LUN (lun0), portal on the LAN IP only, ACLs for the lab nodes' initiator IQNs
# (tools/node-clients.sh gives node N the IQN `node_iqn N`) and NOTHING else,
# CHAP required. The CHAP credentials are generated on first run into
# $LAB/secrets/iscsi-chap (0600) and are never printed; re-runs reuse them.
# Idempotent. Ends with PASS/FAIL.
set -euo pipefail
# shellcheck source=storage-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/storage-lib.sh"

secrets_dir
if [[ ! -f "$ISCSI_CHAP" ]]; then
  # 16 chars: the RFC 3720 CHAP secret length every initiator accepts.
  ( umask 077
    printf 'CHAP_USER=lvchap\nCHAP_PASS=%s\n' "$(openssl rand -hex 8)" > "$ISCSI_CHAP" )
  say "generated CHAP credentials in $ISCSI_CHAP (not shown)"
fi
chmod 0600 "$ISCSI_CHAP"

acls=()
for n in $(seq 1 "$NODES"); do acls+=("$(node_iqn "$n")"); done

say "waiting for $(vm_name nfs)"
wait_ready vm nfs

say "provisioning iSCSI target $ISCSI_IQN on $(vm_name nfs) ($NFS_IP:$ISCSI_PORT)"
# The credentials go over stdin into a 0600 file on the VM, never through argv.
vmssh nfs 'umask 077; cat > /root/.lv-iscsi-chap' < "$ISCSI_CHAP"
rc=0
SSH_TIMEOUT=900 vmssh nfs 'bash -s' -- "$ISCSI_IQN" "$NFS_IP" "$ISCSI_PORT" "${acls[@]}" <<'REMOTE' || rc=$?
set -euo pipefail
IQN="$1"; IP="$2"; PORT="$3"; shift 3
ACLS=("$@")
DEV=/dev/disk/by-id/virtio-lviscsi
BS=lviscsi
export DEBIAN_FRONTEND=noninteractive
fails=0
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok:   $d"; else echo "FAIL: $d"; fails=$((fails+1)); fi; }
# shellcheck source=/dev/null
. /root/.lv-iscsi-chap   # CHAP_USER, CHAP_PASS

dpkg -s targetcli-fb >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y -qq targetcli-fb; }
[[ -b "$DEV" ]] || { echo "FAIL: $DEV missing (iSCSI disk not attached?)"; exit 1; }
# LIO's configfs is only there once the target modules are loaded.
modprobe target_core_mod 2>/dev/null || true
modprobe iscsi_target_mod 2>/dev/null || true

T="/sys/kernel/config/target/iscsi/$IQN/tpgt_1"
tc() { targetcli "$@" >/dev/null; }

bs_dir() { ls -d /sys/kernel/config/target/core/iblock_*/"$BS" 2>/dev/null | head -1; }
[[ -n "$(bs_dir)" ]] || tc /backstores/block create "name=$BS" "dev=$DEV"
[[ -d "/sys/kernel/config/target/iscsi/$IQN" ]] || tc /iscsi create "$IQN"
[[ -e "$T/lun/lun_0" ]] || tc "/iscsi/$IQN/tpg1/luns" create "/backstores/block/$BS" lun=0

# Portal: the LAN address only (a fresh target listens on 0.0.0.0).
[[ -d "$T/np/0.0.0.0:$PORT" ]] && tc "/iscsi/$IQN/tpg1/portals" delete 0.0.0.0 "$PORT"
[[ -d "$T/np/$IP:$PORT" ]] || tc "/iscsi/$IQN/tpg1/portals" create "$IP" "$PORT"

# ACLs: exactly the lab nodes' initiator IQNs; drop any other.
for have in "$T"/acls/iqn.*; do
  [[ -e "$have" ]] || continue
  name="$(basename "$have")"
  keep=0; for a in "${ACLS[@]}"; do [[ "$a" == "$name" ]] && keep=1; done
  [[ "$keep" -eq 1 ]] || tc "/iscsi/$IQN/tpg1/acls" delete "$name"
done
for a in "${ACLS[@]}"; do
  [[ -d "$T/acls/$a" ]] || tc "/iscsi/$IQN/tpg1/acls" create "$a"
  tc "/iscsi/$IQN/tpg1/acls/$a" set auth "userid=$CHAP_USER" "password=$CHAP_PASS"
done
# CHAP required, no auto-created ACLs for unknown initiators.
tc "/iscsi/$IQN/tpg1" set attribute authentication=1 generate_node_acls=0
tc / saveconfig
systemctl enable rtslib-fb-targetctl >/dev/null 2>&1 || systemctl enable target >/dev/null 2>&1 || true

chk "backstore $BS is on $DEV" test "$(readlink -f "$DEV")" = "$(readlink -f "$(cat "$(bs_dir)/udev_path")")"
chk "target $IQN exists with lun0" test -e "$T/lun/lun_0"
chk "portal is $IP:$PORT only" test "$(ls "$T/np")" = "$IP:$PORT"
chk "listening on $IP:$PORT" bash -c "ss -ltn | grep -q '$IP:$PORT '"
chk "ACL set is exactly the ${#ACLS[@]} lab node IQNs" test "$(ls "$T/acls" | sort | tr '\n' ' ')" = "$(printf '%s\n' "${ACLS[@]}" | sort | tr '\n' ' ')"
chk "CHAP required (authentication=1)" test "$(cat "$T/attrib/authentication")" = 1
chk "no dynamic ACLs (generate_node_acls=0)" test "$(cat "$T/attrib/generate_node_acls")" = 0
for a in "${ACLS[@]}"; do
  chk "CHAP userid set on $a" test "$(cat "$T/acls/$a/auth/userid")" = "$CHAP_USER"
done
chk "target config persisted" test -s /etc/rtslib-fb-target/saveconfig.json
exit "$fails"
REMOTE
# Don't leave the plaintext copy on the VM longer than the run.
vmssh nfs 'shred -u /root/.lv-iscsi-chap 2>/dev/null || rm -f /root/.lv-iscsi-chap' || true
finish iscsi-target "$((rc != 0))"
