#!/usr/bin/env bash
# guest-agent-image.sh — bake a litevirt image with qemu-guest-agent installed,
# for the e2e tests whose guests need the agent. Run on the lab host, from the
# lab dir.
#
# The e2e guests install qemu-guest-agent through cloud-init at first boot, and
# the lab's guest bridges have no route out, so the install never happens and
# every agent test skips. The nodes themselves are online (slirp), so the debs
# are fetched ON a node with `apt-get download` (nothing is installed on the
# node, nothing at all on the lab host), served to a throwaway guest over a
# throwaway litevirt bridge, installed there, and the guest's root disk,
# flattened with the node's qemu-img, becomes the image (`lv image import`).
# Not `lv image build`: at int-03fe9868 its compressed convert writes L2 tables
# at 512-byte offsets, and `qemu-img check` finds the result corrupt (the guest
# then cannot read its own disk). Run the tests with E2E_IMAGE=<the new image>;
# their own `packages: [qemu-guest-agent]` then finds it already installed.
#
#   BUILD_NODE   node that builds it (default 1)
#   BASE_IMAGE   litevirt image to start from (default ubuntu)
#   IMAGE_NAME   image to create (default ubuntu-ga)
#   REBUILD=1    replace an existing IMAGE_NAME
#   PUSH_TO      nodes that get a copy after the build (default: every other
#                node that holds BASE_IMAGE)
#
# Leaves nothing behind on the node but the image: the bake VM, its stack,
# bridge, HTTP server and work dir are removed on exit, pass or fail.
# Ends with PASS/FAIL.
set -euo pipefail
# shellcheck source=storage-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/storage-lib.sh"

N="${BUILD_NODE:-1}"
BASE="${BASE_IMAGE:-ubuntu}"
IMG="${IMAGE_NAME:-ubuntu-ga}"
REBUILD="${REBUILD:-0}"
NET=gabake                     # bridge network; also the bridge's name
SUBNET=10.236.250.0/24
PORT=8199
STACK=gabake
VM=gabake-vm
WORK=/root/ga-image            # on the node

say "node-$N: bake $IMG from $BASE"
rc=0
SSH_TIMEOUT=1500 nodessh "$N" 'bash -s' -- "$BASE" "$IMG" "$REBUILD" "$NET" "$SUBNET" "$PORT" "$STACK" "$VM" "$WORK" "node-$N" <<'REMOTE' || rc=$?
set -euo pipefail
BASE="$1" IMG="$2" REBUILD="$3" NET="$4" SUBNET="$5" PORT="$6" STACK="$7" VM="$8" WORK="$9" HOST="${10}"
log() { echo "$(date -u +%T) $*"; }

cleanup() {
  set +e
  lv compose down -f "$WORK/stack.yaml" -y >/dev/null 2>&1 || lv rm "$VM" --force >/dev/null 2>&1
  for _ in $(seq 1 30); do lv inspect "$VM" >/dev/null 2>&1 || break; sleep 2; done
  lv network rm "$NET" --force >/dev/null 2>&1
  [[ -f "$WORK/http.pid" ]] && kill "$(cat "$WORK/http.pid")" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

lv image ls | awk -v b="$BASE" '$1==b' | grep -q "$HOST" || { echo "FAIL: $BASE is not on $HOST"; exit 1; }
if lv image ls | awk '{print $1}' | grep -qx "$IMG"; then
  [[ "$REBUILD" == 1 ]] || { echo "FAIL: $IMG exists (REBUILD=1 replaces it)"; exit 1; }
  log "removing the old $IMG"; lv image rm "$IMG" >/dev/null
fi
! lv inspect "$VM" >/dev/null 2>&1 || { echo "FAIL: a VM named $VM exists"; exit 1; }

# The root disk keeps the base image's virtual size, so the new image is no
# larger than the base and any root size the base accepts still fits.
base_file="$(ls -t /var/lib/litevirt/images/"$BASE"@*.qcow2 2>/dev/null | head -1)"
[[ -n "$base_file" ]] || { echo "FAIL: no file for $BASE in /var/lib/litevirt/images"; exit 1; }
vsize="$(qemu-img info --output=json "$base_file" | python3 -c 'import json,sys; print(json.load(sys.stdin)["virtual-size"])')"
root_mib=$(( (vsize + 1048575) / 1048576 ))
log "$BASE: $base_file, virtual size $vsize bytes -> root ${root_mib}M"

# The debs: the agent and the two libraries a noble cloud image lacks (libc6,
# libglib2.0-0t64, libudev1, init-system-helpers are in it). Downloaded only.
rm -rf "$WORK"; mkdir -p "$WORK/debs"; cd "$WORK/debs"
# /root is closed to _apt, so the download runs as root.
apt-get -o APT::Sandbox::User=root download qemu-guest-agent libnuma1 liburing2 >/dev/null
mv qemu-guest-agent_*.deb qga.deb; mv libnuma1_*.deb libnuma1.deb; mv liburing2_*.deb liburing2.deb
sha256sum qga.deb libnuma1.deb liburing2.deb > SHA256SUMS
log "debs:"; sed 's/^/  /' SHA256SUMS

lv network create "$NET" --type bridge --subnet "$SUBNET" --dhcp >/dev/null
for _ in $(seq 1 30); do ip -4 -o addr show "$NET" 2>/dev/null | grep -q inet && break; sleep 2; done
GW="$(ip -4 -o addr show "$NET" | awk '{print $4; exit}' | cut -d/ -f1)"
[[ -n "$GW" ]] || { echo "FAIL: bridge $NET has no address"; exit 1; }
setsid timeout 1200 python3 -m http.server "$PORT" --bind "$GW" --directory "$WORK/debs" \
  >"$WORK/http.log" 2>&1 < /dev/null & echo $! > "$WORK/http.pid"
log "serving the debs on http://$GW:$PORT/"

cat > "$WORK/stack.yaml" <<EOF
name: $STACK
networks:
  $NET:
    external: true
vms:
  $VM:
    image: $BASE
    cpu: 1
    memory: 1024
    guest-agent: true
    disks: {root: ${root_mib}M}
    network: [{name: $NET}]
    placement: {host: $HOST}
    cloud-init:
      userdata: |
        #cloud-config
        package_update: false
        package_upgrade: false
        runcmd:
          - [sh, -c, 'set -e; d=/var/lib/ga-debs; mkdir -p \$d; cd \$d; for f in SHA256SUMS qga.deb libnuma1.deb liburing2.deb; do curl -fsS --retry 10 --retry-connrefused --retry-delay 3 -o \$f http://$GW:$PORT/\$f; done; sha256sum -c SHA256SUMS; dpkg -i libnuma1.deb liburing2.deb qga.deb; systemctl start qemu-guest-agent; cd /; rm -rf \$d']
EOF
lv compose up -f "$WORK/stack.yaml" -y >/dev/null
log "compose up; waiting for the agent"
ok=0
for _ in $(seq 1 60); do
  if lv exec "$VM" true >/dev/null 2>&1; then ok=1; break; fi
  sleep 10
done
if [[ $ok != 1 ]]; then
  echo "FAIL: the agent never answered in $VM; the HTTP log:"; cat "$WORK/http.log"; exit 1
fi
log "agent answered"
lv exec "$VM" sh -c 'cloud-init status --wait >/dev/null 2>&1; dpkg-query -W -f "\${Package} \${Version} \${Status}\n" qemu-guest-agent libnuma1 liburing2; systemctl is-active qemu-guest-agent; ls /var/lib/ga-debs 2>&1 | head -1'

# Make the disk a clean first-boot image: cloud-init runs again for every VM
# made from it, with a fresh machine-id.
lv exec "$VM" sh -c 'cloud-init clean --logs --machine-id && rm -f /var/lib/systemd/random-seed && sync' >/dev/null
lv stop "$VM" >/dev/null
for _ in $(seq 1 60); do lv ls | awk -v v="$VM" '$1==v {print $3}' | grep -q STOPPED && break; sleep 3; done
lv ls | awk -v v="$VM" '$1==v {print $3}' | grep -q STOPPED || { echo "FAIL: $VM did not stop"; exit 1; }
disk="$(virsh -c qemu:///system domblklist "$VM" | awk '$1=="vda" {print $2}')"
[[ -f "$disk" ]] || { echo "FAIL: no root disk for $VM (got '$disk')"; exit 1; }
log "stopped; flattening $disk"
qemu-img convert -c -O qcow2 "$disk" "$WORK/$IMG.qcow2"
qemu-img check "$WORK/$IMG.qcow2" | tail -1
lv image import "$WORK/$IMG.qcow2" --name "$IMG" | tail -1
f="$(readlink -f /var/lib/litevirt/images/"$IMG".current)"
qemu-img check -U "$f" >/dev/null || { echo "FAIL: $f fails qemu-img check"; exit 1; }
echo "BUILT $IMG on $HOST: $f, qemu-img check clean"
REMOTE
[[ $rc == 0 ]] || die "node-$N: the bake failed (rc=$rc)"

if [[ -n "${PUSH_TO:-}" ]]; then
  read -ra push <<<"$PUSH_TO"
else
  mapfile -t push < <(SSH_TIMEOUT=60 nodessh "$N" "lv image ls" |
    awk -v b="$BASE" '$1==b' | grep -o 'node-[0-9]*' | sed 's/node-//' | grep -vx "$N" || true)
fi
for m in "${push[@]}"; do
  say "push $IMG to node-$m"
  SSH_TIMEOUT=900 nodessh "$N" "set -o pipefail; lv image push $IMG --to node-$m | tail -1" || die "push to node-$m failed"
  SSH_TIMEOUT=120 nodessh "$m" "set -o pipefail; qemu-img check -U \$(readlink -f /var/lib/litevirt/images/$IMG.current) | tail -1" ||
    die "$IMG on node-$m fails qemu-img check"
done
SSH_TIMEOUT=60 nodessh "$N" "lv image ls" | awk -v i="$IMG" 'NR==1 || $1==i'
echo "PASS: E2E_IMAGE=$IMG"
