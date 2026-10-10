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

# ── instance ────────────────────────────────────────────────────────────────
# Several labs can share one host (kvm003-f3 runs lab 1 in ~/litevirt-lab and
# lab 2 in ~/litevirt-lab2). Everything a running lab occupies on the HOST —
# ssh hostfwd ports, the multicast cluster LAN, the seed HTTP port — plus its
# cluster subnet, MACs and qemu process names, is the instance's identity. It
# lives in an optional lab.env beside this script, and only there: the LAB_*
# names are cleared first, so a value exported for one lab can never leak into
# another lab's lab.sh and boot its nodes onto the first lab's LAN. Two labs on
# one multicast group:port silently merge into one L2 segment, so this is the
# value that must never be shared. With no lab.env every default is lab 1's.
unset LAB_NODES LAB_SEEDPORT LAB_MCAST LAB_SSH_PORT_BASE LAB_LAN_PREFIX LAB_MAC_PREFIX LAB_QEMU_NAME
unset LAB_STORAGE_PREFIX LAB_STORAGE_SSH_PORT_BASE LAB_STORAGE_NFS_IP LAB_STORAGE_CEPH_IP
# shellcheck source=/dev/null
[[ -f "$LAB/lab.env" ]] && . "$LAB/lab.env"

BASE="$LAB/images/noble-cloudimg-amd64.img"
IMG_URL="${IMG_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
NODES="${NODES:-${LAB_NODES:-4}}"
VCPUS="${VCPUS:-4}"
MEM="${MEM:-3072}"
DISK="${DISK:-40G}"
# An instance's seed port is part of its identity, so lab.env beats $SEEDPORT.
SEEDPORT="${LAB_SEEDPORT:-${SEEDPORT:-8077}}"
MCAST="${LAB_MCAST:-230.0.0.77:11877}"          # the virtual cluster LAN
SSH_PORT_BASE="${LAB_SSH_PORT_BASE:-2230}"      # node N's ssh is 127.0.0.1:(base+N)
LAN_PREFIX="${LAB_LAN_PREFIX:-10.77.0}"         # node N is <prefix>.(10+N)
MAC_PREFIX="${LAB_MAC_PREFIX:-52:54:00:77}"     # 4 octets; NICs add :00:N / :01:N
QEMU_NAME="${LAB_QEMU_NAME:-litevirt-node}"     # qemu -name <name>-N
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519.pub}"
# The lab's own throwaway key, generated on node-1 and authorized cluster-wide.
# Deliberately NOT the operator's personal key: that one lives in the 1Password
# agent, and when the agent locks, every lab ssh fails with "agent refused
# operation" — which reads exactly like the nodes having died.
SSH_PRIV="${SSH_PRIV:-$LAB/cluster_key}"

sshport() { echo $((SSH_PORT_BASE + $1)); }
nodeip()  { echo "$LAN_PREFIX.$((10 + $1))"; }
nodedir() { echo "$LAB/nodes/node-$1"; }
natmac()  { printf "$MAC_PREFIX:00:%02x" "$1"; }
lanmac()  { printf "$MAC_PREFIX:01:%02x" "$1"; }

# Verbs take explicit node numbers ("up 3 5"); with none given, act on 1..NODES.
nodes_arg() { [[ $# -gt 0 ]] && echo "$@" || seq 1 "$NODES"; }

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

  for i in $(nodes_arg "$@"); do
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

# seed_pids — the pids of THIS instance's seed server, and only its. A process
# qualifies when its argv is `... -m http.server <SEEDPORT> ...` AND its cwd is
# this lab's seed-http dir: the port and the directory are both per-instance, so
# another lab's server (or anything else on the host) can never match. Found by
# scanning /proc rather than trusting seed.pid, because seed.pid written by the
# old serve() held the backgrounded wrapper shell's pid, not python's, and a
# server orphaned that way (still listening, wrapper long gone) has no pid file
# pointing at it at all.
seed_pids() {
  local want p
  want="$(cd "$LAB/seed-http" 2>/dev/null && pwd -P)" || return 0
  for p in /proc/[0-9]*; do
    [[ "$(readlink "$p/cwd" 2>/dev/null)" == "$want" ]] || continue
    tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -qF -- "-m http.server $SEEDPORT " || continue
    echo "${p#/proc/}"
  done
}

serve() {
  local running; running="$(seed_pids | head -1)"
  if [[ -n "$running" ]]; then echo "$running" > "$LAB/seed.pid"; return 0; fi
  # exec, so the backgrounded subshell BECOMES python and $! is the server's own
  # pid; stdin from /dev/null, so a remote `ssh host lab.sh up` is not held open
  # by the server inheriting the session.
  ( cd "$LAB/seed-http" && exec nohup python3 -m http.server "$SEEDPORT" --bind 127.0.0.1 \
      >"$LAB/seed-http.log" 2>&1 </dev/null ) &
  echo $! > "$LAB/seed.pid"
  sleep 1
  echo "seed server on 127.0.0.1:$SEEDPORT (guests reach it at 10.0.2.2:$SEEDPORT)"
}

unserve() {
  local p
  for p in $(seed_pids); do kill "$p" 2>/dev/null && echo "seed server stopped (pid $p)"; done
  rm -f "$LAB/seed.pid"
}

# qemu_pid <n> — node N's qemu pid, printed only if that pid is still THIS
# node's qemu: the `-pidfile` in its argv must resolve to this node's pid file.
# A stale pid file whose pid the kernel has since handed to another process —
# another lab's qemu included — matches nothing, so down never kills it and up
# never mistakes it for a running node. Both sides are resolved (readlink -f),
# so a lab reached through a symlinked path still recognises its own qemus,
# while lab 2's node-1 (/mnt/vmstore/litevirt-lab2/...) can never resolve to
# lab 1's (/mnt/vmstore/litevirt-lab/...).
qemu_pid() { pidfile_pid "$(nodedir "$1")/qemu.pid"; }

# pidfile_pid <pidfile> — the pid in <pidfile>, only while it is still the qemu
# whose `-pidfile` is that file (see qemu_pid above). Storage VMs use it too.
pidfile_pid() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  local pid; pid="$(cat "$f")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  local arg; arg="$({ tr '\0' '\n' < "/proc/$pid/cmdline"; } 2>/dev/null | grep -A1 -xF -- -pidfile | tail -1)"
  [[ -n "$arg" && "$(readlink -f -- "$arg")" == "$(readlink -f -- "$f")" ]] || return 1
  echo "$pid"
}

# ── up ──────────────────────────────────────────────────────────────────────
up() {
  serve
  for i in $(nodes_arg "$@"); do
    local d; d="$(nodedir "$i")"
    local running
    if running="$(qemu_pid "$i")"; then
      echo "node-$i already running (pid $running)"; continue
    fi
    qemu-system-x86_64 \
      -name "$QEMU_NAME-$i" \
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
  for i in $(nodes_arg "$@"); do
    local d; d="$(nodedir "$i")"
    [[ -f "$d/qemu.pid" ]] || continue
    local pid
    if pid="$(qemu_pid "$i")"; then kill "$pid"; echo "node-$i stopped"; fi
    rm -f "$d/qemu.pid"
  done
}

status() {
  printf "%-8s %-8s %-14s %-22s %s\n" NODE PID IP SSH CLOUDINIT
  # 1..NODES plus any leftover node dirs beyond it, so strays stay visible.
  for i in $({ seq 1 "$NODES"; ls "$LAB/nodes" 2>/dev/null | sed -n 's/^node-//p'; } | sort -nu); do
    local d pid state ci; d="$(nodedir "$i")"; pid="-"; state="down"; ci="-"
    local live
    if live="$(qemu_pid "$i")"; then
      pid="$live"; state="up"
      ci="$(nssh "$i" 'cloud-init status 2>/dev/null | head -1' 2>/dev/null || echo unreachable)"
    fi
    printf "%-8s %-8s %-14s %-22s %s\n" "node-$i" "$pid" "$(nodeip "$i")" "127.0.0.1:$(sshport "$i")" "$ci"
  done
}

# info — this instance's identity: everything it occupies on the host, so two
# labs on one host can be checked for collisions before either boots.
info() {
  echo "lab        $LAB"
  echo "lab.env    $([[ -f "$LAB/lab.env" ]] && echo "$LAB/lab.env" || echo "none (lab 1 defaults)")"
  echo "nodes      $NODES"
  echo "seed       127.0.0.1:$SEEDPORT (pid file $LAB/seed.pid)"
  echo "mcast      $MCAST"
  echo "ssh        127.0.0.1:$(sshport 1)..$(sshport "$NODES")"
  echo "lan        $(nodeip 1)..$(nodeip "$NODES")/24"
  echo "macs       $(natmac 1) (nat), $(lanmac 1) (lan) .. node $NODES"
  echo "qemu name  $QEMU_NAME-1..$QEMU_NAME-$NODES"
  echo "nodes dir  $(readlink -f "$LAB/nodes" 2>/dev/null || echo "$LAB/nodes")"
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

destroy() {
  if [[ $# -gt 0 ]]; then
    down "$@"
    local i; for i in "$@"; do
      rm -rf "$(nodedir "$i")" "$LAB/seed-http/node-$i"
      echo "node-$i destroyed"
    done
  else
    # Every node dir present, strays beyond NODES included, is stopped and then
    # removed one by one. nodes/ itself stays: on kvm003 it is a symlink to the
    # vmstore volume, and removing it made the next create rebuild every disk on
    # the root filesystem.
    local all; all="$(ls "$LAB/nodes" 2>/dev/null | sed -n 's/^node-\([0-9][0-9]*\)$/\1/p' | sort -n || true)"
    # shellcheck disable=SC2086
    if [[ -n "$all" ]]; then down $all; fi
    unserve
    local i; for i in $all; do rm -rf -- "$(nodedir "$i")"; done
    echo "lab destroyed (base image + binary kept)"
  fi
}

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


# ── storage VMs ─────────────────────────────────────────────────────────────
# Non-litevirt VMs that give the lab shared storage: lab2-nfs (NFS + an iSCSI
# LIO target) and lab2-ceph (a single-node Ceph). They are plain qemu like the
# nodes, on the same cluster LAN (static IP), cloud-init over the same HTTP seed.
# They are NOT litevirt hosts and never join the cluster. The services inside
# them are provisioned by tools/*.sh (see README "Shared storage").
#
#   lab.sh storage up|down|status|create|destroy|ssh [nfs|ceph|<name>|all]
#
# Data disks carry a virtio serial, so a guest finds them at
# /dev/disk/by-id/virtio-<serial> whatever order they enumerate in.
STORAGE_PREFIX="${LAB_STORAGE_PREFIX:-lab}"          # VM names are <prefix>-nfs / -ceph
STORAGE_SSH_BASE="${LAB_STORAGE_SSH_PORT_BASE:-2250}" # role index 1/2 -> base+1/+2
STORAGE_ROLES="nfs ceph"

st_idx()    { case "$1" in nfs) echo 1;; ceph) echo 2;; *) return 1;; esac; }
st_name()   { echo "$STORAGE_PREFIX-$1"; }
st_dir()    { echo "$LAB/storage/$(st_name "$1")"; }
st_ip()     { case "$1" in nfs) echo "${LAB_STORAGE_NFS_IP:-$LAN_PREFIX.21}";; ceph) echo "${LAB_STORAGE_CEPH_IP:-$LAN_PREFIX.22}";; esac; }
st_vcpus()  { case "$1" in nfs) echo 1;; ceph) echo 4;; esac; }
st_mem()    { case "$1" in nfs) echo 2048;; ceph) echo 8192;; esac; }
st_osdisk() { case "$1" in nfs) echo 10G;; ceph) echo 20G;; esac; }
# serial:size pairs, in attach order
st_data()   { case "$1" in nfs) echo "lvnfsdata:100G lviscsi:50G";; ceph) echo "lvceph0:50G lvceph1:50G lvceph2:50G";; esac; }
st_sshport(){ echo $((STORAGE_SSH_BASE + $(st_idx "$1"))); }
st_natmac() { printf "$MAC_PREFIX:02:%02x" "$(st_idx "$1")"; }
st_lanmac() { printf "$MAC_PREFIX:03:%02x" "$(st_idx "$1")"; }
st_pid()    { pidfile_pid "$(st_dir "$1")/qemu.pid"; }

# st_roles <arg...> — roles named by role (nfs), full name (lab2-nfs) or all/none.
st_roles() {
  local a r
  if [[ $# -eq 0 ]]; then echo $STORAGE_ROLES; return; fi
  for a in "$@"; do
    [[ "$a" == all ]] && { echo $STORAGE_ROLES; continue; }
    for r in $STORAGE_ROLES; do
      if [[ "$a" == "$r" || "$a" == "$(st_name "$r")" ]]; then echo "$r"; continue 2; fi
    done
    echo "unknown storage VM: $a (want nfs, ceph, $(st_name nfs), $(st_name ceph) or all)" >&2
    exit 2
  done
}

# st_ssh <role> [cmd...] — root ssh into a storage VM. Bounded by timeout(1) and
# ConnectTimeout so a wedged VM fails the call instead of hanging the runner.
st_ssh() {
  local r="$1"; shift
  timeout "${ST_SSH_TIMEOUT:-120}" ssh -q -i "$SSH_PRIV" -o IdentityAgent=none -o IdentitiesOnly=yes \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o LogLevel=ERROR \
      -p "$(st_sshport "$r")" root@127.0.0.1 "$@"
}

storage_create() {
  [[ -f "$BASE" ]] || { echo "base image missing: $BASE (run: $0 image)" >&2; exit 1; }
  [[ -f "$SSH_KEY" ]] || { echo "ssh key missing: $SSH_KEY" >&2; exit 1; }
  local pub; pub="$(cat "$SSH_KEY")"
  [[ -f "$SSH_PRIV" ]] || ssh-keygen -q -t ed25519 -N '' -f "$SSH_PRIV" -C litevirt-lab
  [[ -f "$SSH_PRIV.pub" ]] || ssh-keygen -y -f "$SSH_PRIV" > "$SSH_PRIV.pub"
  local cpub; cpub="$(cat "$SSH_PRIV.pub")"
  local r
  for r in "$@"; do
    local n d; n="$(st_name "$r")"; d="$(st_dir "$r")"
    mkdir -p "$d" "$LAB/seed-http/$n"
    [[ -f "$d/disk.qcow2" ]] || \
      qemu-img create -f qcow2 -F qcow2 -b "$BASE" "$d/disk.qcow2" "$(st_osdisk "$r")" >/dev/null
    local spec
    for spec in $(st_data "$r"); do
      [[ -f "$d/${spec%%:*}.qcow2" ]] || qemu-img create -f qcow2 "$d/${spec%%:*}.qcow2" "${spec##*:}" >/dev/null
    done
    cat > "$LAB/seed-http/$n/meta-data" <<EOF
instance-id: litevirt-storage-$n
local-hostname: $n
EOF
    # Nothing is installed here: tools/*.sh install what each role needs, so a
    # re-run is the same as a first run. Only identity, keys and the LAN address.
    cat > "$LAB/seed-http/$n/user-data" <<EOF
#cloud-config
hostname: $n
fqdn: $n.lab
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
write_files:
  - path: /etc/netplan/60-cluster.yaml
    permissions: '0600'
    content: |
      network:
        version: 2
        ethernets:
          clusternet:
            match:
              macaddress: "$(st_lanmac "$r")"
            set-name: net1
            addresses: [$(st_ip "$r")/24]
runcmd:
  - [ netplan, apply ]
  - [ sh, -c, "echo lab-ready > /var/lib/cloud/lab-ready" ]
EOF
    echo "$n  ip=$(st_ip "$r")  ssh=127.0.0.1:$(st_sshport "$r")  $d"
  done
}

storage_up() {
  serve
  local r
  for r in "$@"; do
    local n d running; n="$(st_name "$r")"; d="$(st_dir "$r")"
    if running="$(st_pid "$r")"; then echo "$n already running (pid $running)"; continue; fi
    [[ -f "$d/disk.qcow2" ]] || storage_create "$r"
    local drives=() spec
    for spec in $(st_data "$r"); do
      drives+=(-drive "file=$d/${spec%%:*}.qcow2,if=virtio,format=qcow2,serial=${spec%%:*}")
    done
    qemu-system-x86_64 \
      -name "$QEMU_NAME-storage-$r" \
      -enable-kvm -cpu host -smp "$(st_vcpus "$r")" -m "$(st_mem "$r")" \
      -smbios "type=1,serial=ds=nocloud-net;s=http://10.0.2.2:$SEEDPORT/$n/" \
      -drive file="$d/disk.qcow2",if=virtio,format=qcow2 \
      "${drives[@]}" \
      -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"$(st_sshport "$r")"-:22 \
      -device virtio-net-pci,netdev=net0,mac="$(st_natmac "$r")" \
      -netdev socket,id=net1,mcast="$MCAST" \
      -device virtio-net-pci,netdev=net1,mac="$(st_lanmac "$r")" \
      -display none -daemonize \
      -pidfile "$d/qemu.pid" \
      -serial file:"$d/console.log"
    echo "$n started (pid $(cat "$d/qemu.pid"))  ip=$(st_ip "$r")  ssh 127.0.0.1:$(st_sshport "$r")"
  done
}

# storage_down kills qemu (a power cut, not a guest shutdown); disks are kept.
storage_down() {
  local r pid
  for r in "$@"; do
    local d; d="$(st_dir "$r")"
    [[ -f "$d/qemu.pid" ]] || continue
    if pid="$(st_pid "$r")"; then kill "$pid"; echo "$(st_name "$r") stopped"; fi
    rm -f "$d/qemu.pid"
  done
}

storage_status() {
  printf "%-12s %-8s %-14s %-22s %s\n" NAME PID IP SSH CLOUDINIT
  local r
  for r in "$@"; do
    local pid="-" ci="-" live
    if live="$(st_pid "$r")"; then
      pid="$live"
      ci="$(ST_SSH_TIMEOUT=20 st_ssh "$r" 'cloud-init status 2>/dev/null | head -1' 2>/dev/null || echo unreachable)"
    fi
    printf "%-12s %-8s %-14s %-22s %s\n" "$(st_name "$r")" "$pid" "$(st_ip "$r")" "127.0.0.1:$(st_sshport "$r")" "$ci"
  done
}

storage_destroy() {
  storage_down "$@"
  local r; for r in "$@"; do
    rm -rf -- "$(st_dir "$r")" "$LAB/seed-http/$(st_name "$r")"
    echo "$(st_name "$r") destroyed"
  done
}

storage_cmd() {
  local verb="${1:-}"; shift || true
  if [[ "$verb" == ssh ]]; then   # lab.sh storage ssh <role> [cmd...]  (one VM, not a list)
    local r; r="$(st_roles "${1:-}")" || exit $?
    [[ $# -gt 0 ]] && shift
    st_ssh "$r" "$@"; return
  fi
  local roles; roles="$(st_roles "$@")" || exit $?
  # shellcheck disable=SC2086
  set -- $roles
  case "$verb" in
    create)  storage_create "$@" ;;
    up)      storage_up "$@" ;;
    down)    storage_down "$@" ;;
    status)  storage_status "$@" ;;
    destroy) storage_destroy "$@" ;;
    *) echo "usage: $0 storage {up|down|status|create|destroy} [nfs|ceph|<name>|all]   |   $0 storage ssh <nfs|ceph> [cmd]" >&2; exit 2 ;;
  esac
}

case "${1:-}" in
  image)  image ;;
  create) shift; create "$@" ;;
  up)     shift; up "$@" ;;
  down)   shift; if [[ $# -gt 0 ]]; then down "$@"; else down; unserve; fi ;;
  serve)  serve ;;
  status) status ;;
  info)   info ;;
  ssh)    shift; nssh "$@" ;;
  deploy) shift; deploy "$@" ;;
  storage) shift; storage_cmd "$@" ;;
  destroy) shift; destroy "$@" ;;
  *) echo "usage: $0 {image|create|up|down|status|info|ssh <n> [cmd]|deploy [binary]|destroy|storage ...} [n...]  (no numbers = all)" >&2; exit 2 ;;
esac
