#!/usr/bin/env bash
# ceph.sh — a single-node Ceph on the ceph storage VM (cephadm).
#
#   * `cephadm bootstrap` on the LAN IP; monitoring stack and dashboard skipped
#   * one OSD on each of the three 50G disks (virtio serials lvceph0..2)
#   * CRUSH rule lv_osd (failure domain = osd; one host cannot spread by host)
#   * rbd pool `lv` on that rule, size 3 / min_size 2, rbd-initialised
#   * client.litevirt with `mon 'profile rbd'` and `osd 'profile rbd pool=lv'`
#
# Writes $LAB/secrets/ceph.client.litevirt.keyring (0600) and ceph.conf (a
# minimal client conf). The ADMIN keyring stays on the ceph VM and is never
# copied anywhere. Idempotent. Needs outbound internet on the VM (container
# image from quay.io); bootstrap takes ~5-10 min. Ends with PASS/FAIL.
set -euo pipefail
# shellcheck source=storage-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/storage-lib.sh"

say "waiting for $(vm_name ceph)"
wait_ready vm ceph

say "provisioning ceph on $(vm_name ceph) ($CEPH_IP) — this takes several minutes"
rc=0
SSH_TIMEOUT=3000 vmssh ceph 'bash -s' -- "$CEPH_IP" "$CEPH_POOL" "$CEPH_CLIENT" <<'REMOTE' || rc=$?
set -euo pipefail
IP="$1"; POOL="$2"; CLIENT="$3"
RULE=lv_osd
export DEBIAN_FRONTEND=noninteractive
fails=0
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok:   $d"; else echo "FAIL: $d"; fails=$((fails+1)); fi; }

pkgs=(cephadm ceph-common podman lvm2 chrony)
missing=(); for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
if [[ ${#missing[@]} -gt 0 ]]; then apt-get update -qq; apt-get install -y -qq "${missing[@]}"; fi
systemctl enable --now chrony >/dev/null 2>&1 || true

if ! { [[ -f /etc/ceph/ceph.client.admin.keyring ]] && timeout 60 ceph -s >/dev/null 2>&1; }; then
  cephadm bootstrap --mon-ip "$IP" --single-host-defaults \
    --skip-monitoring-stack --skip-dashboard --skip-firewalld
fi

# OSDs, one per data disk. The device is found by virtio serial, and skipped
# when it already carries an LVM volume (an OSD).
for ser in lvceph0 lvceph1 lvceph2; do
  dev="$(readlink -f "/dev/disk/by-id/virtio-$ser")"
  [[ -b "$dev" ]] || { echo "FAIL: /dev/disk/by-id/virtio-$ser missing"; exit 1; }
  if lsblk -rn -o TYPE "$dev" | grep -qx lvm; then echo "ok:   $dev already an OSD"; continue; fi
  # The orchestrator's device inventory lags bootstrap by a minute or two.
  added=0
  for _ in $(seq 1 12); do
    if ceph orch daemon add osd "$(hostname -s):$dev" >/dev/null 2>&1; then added=1; break; fi
    sleep 15
  done
  [[ "$added" -eq 1 ]] || { echo "FAIL: could not add an OSD on $dev"; exit 1; }
done
for _ in $(seq 1 40); do
  up="$(ceph osd stat -f json 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("num_up_osds",0))' 2>/dev/null || echo 0)"
  [[ "$up" -ge 3 ]] && break; sleep 10
done

ceph osd crush rule ls | grep -qx "$RULE" || ceph osd crush rule create-replicated "$RULE" default osd
ceph osd pool ls | grep -qx "$POOL" || ceph osd pool create "$POOL" 32 32 replicated "$RULE"
ceph osd pool set "$POOL" crush_rule "$RULE" >/dev/null
ceph osd pool set "$POOL" size 3 >/dev/null
ceph osd pool set "$POOL" min_size 2 >/dev/null
rbd pool init "$POOL"

# Restricted client: rbd on the one pool, nothing else. Caps are re-asserted on
# every run, so a hand-widened key is narrowed again.
ceph auth get-or-create "client.$CLIENT" mon 'profile rbd' osd "profile rbd pool=$POOL" >/dev/null
ceph auth caps "client.$CLIENT" mon 'profile rbd' osd "profile rbd pool=$POOL" >/dev/null

# Verify with the client's own key, from a throwaway keyring.
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
ceph auth get "client.$CLIENT" > "$tmp"
probe="_lv_probe_$$"
chk "3 OSDs up" test "$(ceph osd stat -f json | python3 -c 'import sys,json; print(json.load(sys.stdin)["num_up_osds"])')" -ge 3
chk "crush rule $RULE has failure domain osd" bash -c "ceph osd crush rule dump $RULE | grep -q '\"type\": \"osd\"'"
chk "pool $POOL uses rule $RULE" bash -c "ceph osd pool get $POOL crush_rule | grep -q ' $RULE\$'"
chk "pool $POOL has application rbd" bash -c "ceph osd pool application get $POOL | grep -q rbd"
chk "client.$CLIENT caps are rbd on $POOL only" bash -c "grep -q 'osd = \"profile rbd pool=$POOL\"' $tmp && grep -q 'mon = \"profile rbd\"' $tmp && ! grep -q 'mgr = ' $tmp"
chk "client.$CLIENT can create+remove an image in $POOL" bash -c "rbd --id $CLIENT --keyring $tmp create --size 1M $POOL/$probe && rbd --id $CLIENT --keyring $tmp rm $POOL/$probe"
chk "client.$CLIENT is not an admin (auth ls refused)" bash -c "! ceph --id $CLIENT --keyring $tmp auth ls >/dev/null 2>&1"
echo "info: ceph health: $(ceph health 2>&1 | head -1)"
chk "cluster is not HEALTH_ERR" bash -c "! ceph health | grep -q HEALTH_ERR"
exit "$fails"
REMOTE
[[ "$rc" -eq 0 ]] || finish ceph 1

# Pull ONLY the restricted key and a minimal conf. `ceph auth get client.litevirt`
# is the one key printed; client.admin is never read.
secrets_dir
( umask 077
  vmssh ceph "ceph auth get client.$CEPH_CLIENT" > "$CEPH_KEYRING.new"
  mv -f "$CEPH_KEYRING.new" "$CEPH_KEYRING"
  vmssh ceph 'ceph config generate-minimal-conf' > "$CEPH_CONF.new"
  mv -f "$CEPH_CONF.new" "$CEPH_CONF" )
chmod 0600 "$CEPH_KEYRING"; chmod 0644 "$CEPH_CONF"

fails=0
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok:   $d"; else echo "FAIL: $d"; fails=$((fails+1)); fi; }
chk "keyring is 0600" test "$(stat -c %a "$CEPH_KEYRING")" = 600
chk "keyring is client.$CEPH_CLIENT" grep -q "^\[client.$CEPH_CLIENT\]" "$CEPH_KEYRING"
chk "keyring does not hold client.admin" bash -c "! grep -q 'client.admin' '$CEPH_KEYRING'"
chk "ceph.conf names the mon at $CEPH_IP" grep -q "$CEPH_IP" "$CEPH_CONF"
finish ceph "$fails"
