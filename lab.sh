#!/usr/bin/env bash
# litevirt nested test lab — 4 node VMs on plain qemu, no libvirt or root on the host.
#
# Each node is an Ubuntu cloud image booted with -cpu host, so KVM is available
# INSIDE the node and litevirt can run real guest VMs (nested virt is enabled on
# this host). Two NICs per node:
#
#   net0  user-mode NAT + hostfwd  -> outbound apt, and ssh from the host
#   net1  qemu multicast socket    -> the 10.77.0.0/24 cluster LAN between nodes
#
# cloud-init is seeded over HTTP, pointed at by the SMBIOS DMI product serial
# (`ds=nocloud-net;s=http://10.0.2.2:PORT/node-N/`), which ds-identify detects
# reliably. A VVFAT seed disk was tried first and silently failed: the synthesized
# FAT volume does not carry a blkid LABEL of CIDATA, so ds-identify found no
# datasource and disabled cloud-init outright — no output, default hostname, no
# SSH key. The HTTP seed needs no ISO tooling on the host either (this box has no
# genisoimage/mkisofs/xorriso/mcopy), just python3 -m http.server, reachable from
# every guest at 10.0.2.2 through user-mode networking.
#
# The cluster NIC is configured by a netplan file written through user-data, NOT
# by cloud-init's network-config: the HTTP NoCloud datasource only ever fetches
# meta-data/user-data/vendor-data, so a served network-config is silently ignored
# and the second NIC comes up unconfigured.
set -euo pipefail

LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$LAB/images/noble-cloudimg-amd64.img"
IMG_URL="${IMG_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
NODES="${NODES:-4}"
VCPUS="${VCPUS:-4}"
MEM="${MEM:-3072}"
DISK="${DISK:-40G}"
SEEDPORT="${SEEDPORT:-8077}"
MCAST="230.0.0.77:11877"          # the virtual cluster LAN
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519.pub}"
# The lab's own throwaway key, generated on node-1 and authorized cluster-wide.
# Deliberately NOT the operator's personal key: that one lives in the 1Password
# agent, and when the agent locks, every lab ssh fails with "agent refused
# operation" — which reads exactly like the nodes having died.
SSH_PRIV="${SSH_PRIV:-$LAB/cluster_key}"

sshport() { echo $((2230 + $1)); }
nodeip()  { echo "10.77.0.$((10 + $1))"; }
nodedir() { echo "$LAB/nodes/node-$1"; }
natmac()  { printf '52:54:00:77:00:%02x' "$1"; }
lanmac()  { printf '52:54:00:77:01:%02x' "$1"; }

# ── image ───────────────────────────────────────────────────────────────────
image() {
  [[ -f "$BASE" ]] && { echo "base image already present: $BASE"; return 0; }
  mkdir -p "$LAB/images"
  echo "fetching $IMG_URL"
  curl -fL --progress-bar -o "$BASE.part" "$IMG_URL" && mv "$BASE.part" "$BASE"
  echo "base image ready: $BASE"
}

# ── create ──────────────────────────────────────────────────────────────────
create() {
  [[ -f "$BASE" ]] || { echo "base image missing: $BASE" >&2; exit 1; }
  [[ -f "$SSH_KEY" ]] || { echo "ssh key missing: $SSH_KEY" >&2; exit 1; }
  local pub; pub="$(cat "$SSH_KEY")"
  # The lab's throwaway key, generated here if absent and authorized alongside
  # the operator key so `lab.sh ssh`/`deploy` survive a locked 1Password agent.
  [[ -f "$SSH_PRIV" ]] || ssh-keygen -q -t ed25519 -N '' -f "$SSH_PRIV" -C litevirt-lab
  [[ -f "$SSH_PRIV.pub" ]] || ssh-keygen -y -f "$SSH_PRIV" > "$SSH_PRIV.pub"
  local cpub; cpub="$(cat "$SSH_PRIV.pub")"

  for i in $(seq 1 "$NODES"); do
    local d; d="$(nodedir "$i")"
    mkdir -p "$d" "$LAB/seed-http/node-$i"

    # Overlay so the base image stays pristine and each node is throwaway.
    [[ -f "$d/disk.qcow2" ]] || {
      qemu-img create -f qcow2 -F qcow2 -b "$BASE" "$d/disk.qcow2" "$DISK" >/dev/null
    }

    cat > "$LAB/seed-http/node-$i/meta-data" <<EOF
instance-id: litevirt-node-$i
local-hostname: node-$i
EOF

    # litevirt's host prerequisites, installed on first boot in parallel across
    # nodes. qemu-system-x86 + libvirt are what actually run the guest VMs;
    # genisoimage builds cloud-init ISOs for them.
    cat > "$LAB/seed-http/node-$i/user-data" <<EOF
#cloud-config
hostname: node-$i
fqdn: node-$i.lab
ssh_authorized_keys:
  - $pub
  - $cpub
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $pub
      - $cpub
  - name: root
    ssh_authorized_keys:
      - $pub
      - $cpub
disable_root: false
package_update: true
packages:
  - qemu-system-x86
  - libvirt-daemon-system
  - libvirt-clients
  - genisoimage
  - bridge-utils
  - dnsmasq-base
  - nftables
write_files:
  - path: /etc/netplan/60-cluster.yaml
    permissions: '0600'
    content: |
      network:
        version: 2
        ethernets:
          clusternet:
            match:
              macaddress: "$(lanmac "$i")"
            set-name: net1
            addresses: [$(nodeip "$i")/24]
runcmd:
  - [ netplan, apply ]
  - [ systemctl, enable, --now, libvirtd ]
  - [ sh, -c, "echo lab-ready > /var/lib/cloud/lab-ready" ]
EOF
    echo "node-$i  ip=$(nodeip "$i")  ssh=127.0.0.1:$(sshport "$i")  $d"
  done
}

serve() {
  [[ -f "$LAB/seed.pid" ]] && kill -0 "$(cat "$LAB/seed.pid")" 2>/dev/null && return 0
  ( cd "$LAB/seed-http" && nohup python3 -m http.server "$SEEDPORT" --bind 127.0.0.1 \
      >"$LAB/seed-http.log" 2>&1 & echo $! > "$LAB/seed.pid" )
  sleep 1
  echo "seed server on 127.0.0.1:$SEEDPORT (guests reach it at 10.0.2.2:$SEEDPORT)"
}

unserve() {
  [[ -f "$LAB/seed.pid" ]] || return 0
  kill "$(cat "$LAB/seed.pid")" 2>/dev/null || true
  rm -f "$LAB/seed.pid"
}

# ── up ──────────────────────────────────────────────────────────────────────
up() {
  serve
  for i in $(seq 1 "$NODES"); do
    local d; d="$(nodedir "$i")"
    if [[ -f "$d/qemu.pid" ]] && kill -0 "$(cat "$d/qemu.pid")" 2>/dev/null; then
      echo "node-$i already running (pid $(cat "$d/qemu.pid"))"; continue
    fi
    qemu-system-x86_64 \
      -name "litevirt-node-$i" \
      -enable-kvm -cpu host -smp "$VCPUS" -m "$MEM" \
      -smbios "type=1,serial=ds=nocloud-net;s=http://10.0.2.2:$SEEDPORT/node-$i/" \
      -drive file="$d/disk.qcow2",if=virtio,format=qcow2 \
      -netdev user,id=net0,hostfwd=tcp:127.0.0.1:$(sshport "$i")-:22 \
      -device virtio-net-pci,netdev=net0,mac=$(natmac "$i") \
      -netdev socket,id=net1,mcast="$MCAST" \
      -device virtio-net-pci,netdev=net1,mac=$(lanmac "$i") \
      -display none -daemonize \
      -pidfile "$d/qemu.pid" \
      -serial file:"$d/console.log"
    echo "node-$i started (pid $(cat "$d/qemu.pid"))  ssh 127.0.0.1:$(sshport "$i")"
  done
}

down() {
  for i in $(seq 1 "$NODES"); do
    local d; d="$(nodedir "$i")"
    [[ -f "$d/qemu.pid" ]] || continue
    local pid; pid="$(cat "$d/qemu.pid")"
    if kill -0 "$pid" 2>/dev/null; then kill "$pid"; echo "node-$i stopped"; fi
    rm -f "$d/qemu.pid"
  done
}

status() {
  printf "%-8s %-8s %-14s %-22s %s\n" NODE PID IP SSH CLOUDINIT
  for i in $(seq 1 "$NODES"); do
    local d pid state ci; d="$(nodedir "$i")"; pid="-"; state="down"; ci="-"
    if [[ -f "$d/qemu.pid" ]] && kill -0 "$(cat "$d/qemu.pid")" 2>/dev/null; then
      pid="$(cat "$d/qemu.pid")"; state="up"
      ci="$(nssh "$i" 'cloud-init status 2>/dev/null | head -1' 2>/dev/null || echo unreachable)"
    fi
    printf "%-8s %-8s %-14s %-22s %s\n" "node-$i" "$pid" "$(nodeip "$i")" "127.0.0.1:$(sshport "$i")" "$ci"
  done
}

# nssh <n> [cmd...] — ssh into a node as root
nssh() {
  local i="$1"; shift
  # IdentitiesOnly stops ssh from offering every agent key first and exhausting
  # MaxAuthTries before it ever reaches -i.
  ssh -q -i "$SSH_PRIV" -o IdentitiesOnly=yes \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 -o LogLevel=ERROR \
      -p "$(sshport "$i")" root@127.0.0.1 "$@"
}

destroy() { down; unserve; rm -rf "$LAB/nodes"; echo "lab destroyed (base image + binary kept)"; }

# deploy [binary] — copy a litevirt binary to /usr/local/bin on every node.
# Deliberately does NOT restart the daemons: HA fences nodes that restart too
# quickly (it powers them off over SSH). Restart by hand, spaced ~13s apart.
deploy() {
  local bin="${1:-$LAB/litevirt}"
  [[ -f "$bin" ]] || { echo "binary missing: $bin" >&2; exit 1; }
  for i in $(seq 1 "$NODES"); do
    scp -q -i "$SSH_PRIV" -o IdentityAgent=none -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -o LogLevel=ERROR \
        -P "$(sshport "$i")" "$bin" root@127.0.0.1:/usr/local/bin/litevirt.new
    nssh "$i" 'install -m 0755 /usr/local/bin/litevirt.new /usr/local/bin/litevirt && rm -f /usr/local/bin/litevirt.new'
    echo "node-$i: binary installed (daemon NOT restarted)"
  done
  echo "restart litevirt on each node yourself, spaced ~13s — simultaneous restarts get fenced by HA"
}

case "${1:-}" in
  image)  image ;;
  create) create ;;
  up)     up ;;
  down)   down; unserve ;;
  serve)  serve ;;
  status) status ;;
  ssh)    shift; nssh "$@" ;;
  deploy) shift; deploy "$@" ;;
  destroy) destroy ;;
  *) echo "usage: $0 {image|create|up|down|status|ssh <n> [cmd]|deploy [binary]|destroy}" >&2; exit 2 ;;
esac
