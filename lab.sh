#!/usr/bin/env bash
# litevirt nested test lab — 4 node VMs on plain qemu, no libvirt or root on the host.
#
# Each node is an Ubuntu cloud image booted with -cpu host, so KVM is available
# INSIDE the node and litevirt can run real guest VMs (nested virt is enabled on
# this host). Two NICs per node:
#
#   net0  user-mode NAT + hostfwd  -> outbound apt, and ssh from the host
#   net1  a lanhub LAN (qemu dgram) -> the 10.77.0.0/24 cluster LAN between nodes
#         (or a qemu multicast socket with LAB_NET_MODE=mcast; see "virtual LANs")
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
# LAB_NET_MODE is the one exception: an exported value beats lab.env, so the
# multicast rollback is one variable (see "virtual LANs").
_LAB_NET_MODE_ENV="${LAB_NET_MODE:-}"
unset LAB_NET_MODE
unset LAB_NODES LAB_SEEDPORT LAB_MCAST LAB_SSH_PORT_BASE LAB_LAN_PREFIX LAB_MAC_PREFIX LAB_QEMU_NAME
unset LAB_STORAGE_PREFIX LAB_STORAGE_SSH_PORT_BASE LAB_STORAGE_NFS_IP LAB_STORAGE_CEPH_IP
# Opt-in node hardware, extra networks and aux VMs (see "lab extras" below and
# the README). Every one is off unless the instance's lab.env sets it.
unset LAB_NODE_HW LAB_NODE_HW_NODES LAB_NODE_MEM LAB_NODE_QMP LAB_IGB_MCAST \
      LAB_MIG_MCAST LAB_MIG_PREFIX LAB_TRUNK_MCAST LAB_LAN6_PREFIX LAB_CGROUP_V1_NODES \
      LAB_AUX_ROLES LAB_AUX_SSH_PORT_BASE LAB_BMC_IP LAB_BMC_IPMI_BASE LAB_BMC_NODES \
      LAB_BMC_AGENT_PORT LAB_IDM_IP LAB_IDM_DOMAIN
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

# ── virtual LANs: a user-space hub (default) or host multicast (rollback) ───
# Every LAN the VMs share — the cluster LAN, plus the opt-in migration, trunk and igb segments — is one of
# two things, picked by LAB_NET_MODE:
#
#   hub    (default) one lanhub process per LAN (source in lanhub/): a learning
#          Ethernet hub on Unix datagram sockets. Each VM NIC is a qemu
#          `-netdev dgram` whose local socket is hub/<lan>/peers/<vm>.sock and
#          whose remote is hub/<lan>/hub.sock. Nothing leaves the host: the LAN
#          is sockets in this lab's directory, so two labs cannot merge into
#          one segment either.
#   mcast  the original `-netdev socket,mcast=<group:port>`. Every frame then
#          leaves the host as UDP multicast on its default-route interface — on
#          kvm003-f3 that is bond0.209, the physical VLAN 209 — so this is the
#          rollback only.
#
# The environment wins over lab.env, so a rollback is one variable
# (`LAB_NET_MODE=mcast ./lab.sh up`); otherwise lab.env, otherwise hub. In hub
# mode a *_MCAST value only switches its network on; its group:port is unused.
# One lab must never run VMs in both modes at once: a hub NIC and a multicast
# NIC cannot hear each other, so the lab would split in two. Starting a VM in
# one mode while any of the lab's VMs runs in the other is refused.
#
# Each hub runs under a restart loop (back within ~0.5 s if lanhub exits),
# detached like the VMs (setsid nohup, parent pid 1), so it survives the ssh
# session that started it. Pid files and logs are in hub/<lan>/.
#
#   lab.sh hub status [-v]     loop/hub pids, peers, frame counters (-v: per peer)
#   lab.sh hub up | down [lan...]   start / stop hubs (down refuses while VMs run)
NET_MODE="${_LAB_NET_MODE_ENV:-${LAB_NET_MODE:-hub}}"
case "$NET_MODE" in
  hub|mcast) ;;
  *) echo "LAB_NET_MODE must be hub or mcast, not '$NET_MODE'" >&2; exit 2 ;;
esac
HUB_DIR="$LAB/hub"
LANHUB="$LAB/lanhub/lanhub"

# lab_lans — the LANs this instance's VMs are on.
lab_lans() {
  local l=cluster
  [[ -n "${LAB_MIG_MCAST:-}" ]] && l+=" mig"
  [[ -n "${LAB_TRUNK_MCAST:-}" ]] && l+=" trunk"
  [[ "${LAB_NODE_HW:-0}" == 1 && -n "${LAB_IGB_MCAST:-}" ]] && l+=" igb"
  echo "$l"
}

# lab_vm_pids — every running qemu of this lab: nodes (strays too), storage, aux.
lab_vm_pids() {
  local i r
  for i in $({ seq 1 "$NODES"; ls "$LAB/nodes" 2>/dev/null | sed -n 's/^node-\([0-9][0-9]*\)$/\1/p'; } | sort -nu); do
    qemu_pid "$i" || true
  done
  for r in $STORAGE_ROLES; do st_pid "$r" || true; done
  for r in $AUX_ROLES; do aux_pid "$r" || true; done
}

# lan_netdev <id> <lan> <group:port> <vm> — the -netdev value for one VM NIC.
lan_netdev() {
  if [[ "$NET_MODE" == mcast ]]; then echo "socket,id=$1,mcast=$3"; return; fi
  echo "dgram,id=$1,local.type=unix,local.path=$HUB_DIR/$2/peers/$4.sock,remote.type=unix,remote.path=$HUB_DIR/$2/hub.sock"
}

# proc_args <pid> — the process's argv, one per line; fails if it is gone.
proc_args() { { tr '\0' '\n' < "/proc/$1/cmdline"; } 2>/dev/null; }

# hub_sup_pid / hub_pid <lan> — the LAN's restart loop / its lanhub, printed
# only while the pid in the pid file is still that process (its argv names this
# LAN's directory), so a recycled pid is never taken for a hub.
hub_sup_pid() {
  local d="$HUB_DIR/$1" pid args
  pid="$(cat "$d/supervisor.pid" 2>/dev/null)" && [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  args="$(proc_args "$pid")" || return 1
  grep -qxF lanhub-supervisor <<<"$args" && grep -qxF -- "$d" <<<"$args" || return 1
  echo "$pid"
}
hub_pid() {
  local d="$HUB_DIR/$1" pid args
  pid="$(cat "$d/hub.pid" 2>/dev/null)" && [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  args="$(proc_args "$pid")" || return 1
  grep -qxF -- "$d/hub.sock" <<<"$args" || return 1
  echo "$pid"
}

hub_build() {
  local go; go="$(command -v go || echo "$HOME/sdk/go1.26.0/bin/go")"
  [[ -x "$go" ]] || { echo "$LANHUB missing and no go toolchain to build it" >&2; exit 1; }
  (cd "$LAB/lanhub" && CGO_ENABLED=0 "$go" build -trimpath -o lanhub .)
  echo "built $LANHUB"
}

# hub_ensure <lan> — start the LAN's hub unless its loop already runs.
hub_ensure() {
  local lan="$1" d="$HUB_DIR/$1" pid
  hub_sup_pid "$lan" >/dev/null && return 0
  [[ -x "$LANHUB" ]] || hub_build
  mkdir -p "$d/peers"
  chmod 700 "$HUB_DIR" "$d"   # the LAN is these sockets: only the lab user may join it
  # A lanhub whose loop was killed still serves; replace it, not run two.
  if pid="$(hub_pid "$lan")"; then kill "$pid" 2>/dev/null || true; fi
  rm -f "$d/hub.pid"
  # shellcheck disable=SC2016  # expanded by the loop's own shell
  setsid nohup bash -c '
    echo $$ > "$2/supervisor.pid"
    while :; do
      "$1" -sock "$2/hub.sock" -pidfile "$2/hub.pid"
      echo "lanhub-supervisor[$$]: lanhub exited with status $? at $(date -u +%FT%TZ); restarting"
      sleep 0.5
    done' lanhub-supervisor "$LANHUB" "$d" >>"$d/hub.log" 2>&1 </dev/null &
  local _
  for _ in $(seq 1 50); do
    if hub_sup_pid "$lan" >/dev/null && hub_pid "$lan" >/dev/null && [[ -S "$d/hub.sock" ]]; then
      echo "hub $lan started (loop pid $(hub_sup_pid "$lan"), lanhub pid $(hub_pid "$lan"))"
      return 0
    fi
    sleep 0.1
  done
  echo "hub $lan did not come up; see $d/hub.log" >&2
  exit 1
}

# hubs_up [lan...] — every hub this lab needs (in hub mode), before any VM boots.
hubs_up() {
  [[ "$NET_MODE" == hub ]] || return 0
  local lan lans=("$@")
  [[ ${#lans[@]} -gt 0 ]] || read -ra lans <<<"$(lab_lans)"
  for lan in "${lans[@]}"; do hub_ensure "$lan"; done
}

hubs_down() {
  local running; running="$(lab_vm_pids | head -1)"
  if [[ -n "$running" && "${FORCE:-0}" != 1 ]]; then
    echo "refusing: lab VMs are running (qemu pid $running) and would lose their LANs; stop them first, or FORCE=1" >&2
    exit 2
  fi
  local lan pid lans=("$@")
  [[ ${#lans[@]} -gt 0 ]] || read -ra lans <<<"$(lab_lans)"
  for lan in "${lans[@]}"; do
    if pid="$(hub_sup_pid "$lan")"; then kill "$pid"; fi   # the loop first, or it restarts the hub
    if pid="$(hub_pid "$lan")"; then kill "$pid"; fi
    rm -f "$HUB_DIR/$lan/supervisor.pid" "$HUB_DIR/$lan/hub.pid"
    echo "hub $lan stopped"
  done
}

# hubs_status [-v] — one row per LAN from the hub's stats file (rewritten every
# second); -v adds a row per peer (one per VM NIC: frames in, out, dropped).
hubs_status() {
  local verbose=0; [[ "${1:-}" == -v ]] && verbose=1
  echo "net mode $NET_MODE  ($HUB_DIR)"
  printf "%-8s %-8s %-5s %-8s %-5s %-6s %-5s %-10s %-10s %-9s %-9s %-9s %s\n" \
    LAN LOOP PPID LANHUB PPID PEERS MACS RX_FRAMES FLOODED UNICAST DROP_FULL DROP_GONE UPDATED
  local lan
  for lan in $( { lab_lans | tr ' ' '\n'; ls "$HUB_DIR" 2>/dev/null; } | awk '!seen[$0]++'); do
    [[ -d "$HUB_DIR/$lan" ]] || { printf "%-8s %s\n" "$lan" "(no hub dir)"; continue; }
    local sup="-" sppid="-" hub="-" hppid="-" p f="$HUB_DIR/$lan/stats"
    if p="$(hub_sup_pid "$lan")"; then sup="$p"; sppid="$(ps -o ppid= -p "$p" | tr -d ' ')"; fi
    if p="$(hub_pid "$lan")"; then hub="$p"; hppid="$(ps -o ppid= -p "$p" | tr -d ' ')"; fi
    st() { awk -v k="$1" '$1==k{print $2}' "$f" 2>/dev/null || true; }
    printf "%-8s %-8s %-5s %-8s %-5s %-6s %-5s %-10s %-10s %-9s %-9s %-9s %s\n" "$lan" "$sup" "$sppid" "$hub" "$hppid" \
      "$(st peers)" "$(st macs)" "$(st rx_frames)" "$(st flooded)" "$(st unicast)" "$(st drop_full)" "$(st drop_gone)" "$(st updated)"
    [[ $verbose == 1 && -f "$f" ]] && sed -n 's/^peer /    /p' "$f"
  done
  return 0
}

# net_mode_guard — refuse to start a VM in one mode while any of this lab's
# VMs runs in the other (see above: the lab would split in two).
net_mode_guard() {
  local pid args other=""
  for pid in $(lab_vm_pids); do
    args="$(proc_args "$pid")" || continue
    if [[ "$NET_MODE" == hub && "$args" == *",mcast="* ]]; then other=mcast; break; fi
    if [[ "$NET_MODE" == mcast && "$args" == *"remote.type=unix"* ]]; then other=hub; break; fi
  done
  [[ -z "$other" ]] && return 0
  echo "refusing: qemu pid $pid of this lab runs with LAB_NET_MODE=$other; a $NET_MODE NIC cannot reach it," >&2
  echo "so the lab would split in two. Stop the lab's VMs first, or run with LAB_NET_MODE=$other." >&2
  exit 2
}

# ── lab extras (all opt-in through lab.env) ─────────────────────────────────
# With none of these set, every qemu argv and every seed file is exactly what it
# was before they existed, so an instance that does not opt in (lab 2) is
# unchanged.
#
#   LAB_NODE_MEM="1:5120 3:4096"   per-node memory, overriding $MEM
#   LAB_NODE_QMP=1                 a QMP socket per node (nodes/node-N/qmp.sock), so
#                                  the BMC simulators can ask for an ACPI shutdown
#   LAB_NODE_HW=1                  emulated hardware on the nodes: q35 + intel-iommu
#                                  (caching-mode, intremap), an igb NIC with SR-IOV on
#                                  its own segment, an xhci controller with a USB
#                                  tablet + keyboard, an NVMe disk (SMART), and a
#                                  spare virtio disk (serial lvspare0)
#   LAB_NODE_HW_NODES="1 2"        ...only on these nodes (default: every node)
#   LAB_IGB_MCAST=g:p              the igb NIC's segment (needed with LAB_NODE_HW)
#   LAB_MIG_MCAST=g:p              a migration network NIC per node (set-name mignet)
#   LAB_MIG_PREFIX=10.77.1         ...node N is <prefix>.(10+N)/24
#   LAB_TRUNK_MCAST=g:p            a VLAN trunk NIC per node (set-name trunk0, no IP)
#   LAB_LAN6_PREFIX=fd00:77::      a ULA on the cluster NIC: node N is <prefix><10+N>/64
#                                  (guest/firewall tests only: litevirt's cluster
#                                  transport and advertise_address stay IPv4)
#   LAB_CGROUP_V1_NODES="2"        read by tools/node-extras.sh, which boots these
#                                  nodes with the legacy (v1) cgroup hierarchy
node_mem() {
  local kv
  for kv in ${LAB_NODE_MEM:-}; do [[ "${kv%%:*}" == "$1" ]] && { echo "${kv#*:}"; return; }; done
  echo "$MEM"
}
node_hw() {
  [[ "${LAB_NODE_HW:-0}" == 1 ]] || return 1
  [[ -z "${LAB_NODE_HW_NODES:-}" || " $LAB_NODE_HW_NODES " == *" $1 "* ]]
}
migmac()   { printf "$MAC_PREFIX:04:%02x" "$1"; }
trunkmac() { printf "$MAC_PREFIX:05:%02x" "$1"; }
igbmac()   { printf "$MAC_PREFIX:06:%02x" "$1"; }
migip()    { echo "${LAB_MIG_PREFIX:-}.$((10 + $1))"; }
lan6ip()   { echo "${LAB_LAN6_PREFIX:-}$((10 + $1))"; }

# node_qemu_extras <n> — fill the arrays ex_pre (machine, IOMMU), ex_disk (OS +
# extra disks + USB; empty = the classic if=virtio drive), ex_net (extra NICs)
# and ex_tail (QMP) for node N. All empty unless opted in.
node_qemu_extras() {
  local i="$1" d; d="$(nodedir "$i")"
  ex_pre=(); ex_disk=(); ex_net=(); ex_tail=()
  if node_hw "$i"; then
    [[ -n "${LAB_IGB_MCAST:-}" ]] || { echo "LAB_NODE_HW=1 needs LAB_IGB_MCAST in lab.env" >&2; exit 2; }
    # intel-iommu must precede the PCI devices it translates for; intremap needs
    # the split irqchip; caching-mode lets a vfio user inside the node (an L2
    # guest given a VF) work against an emulated IOMMU.
    ex_pre=(-machine q35,kernel-irqchip=split
            -device intel-iommu,intremap=on,caching-mode=on)
    [[ -f "$d/nvme0.qcow2" ]]  || qemu-img create -f qcow2 "$d/nvme0.qcow2" 8G >/dev/null
    [[ -f "$d/spare0.qcow2" ]] || qemu-img create -f qcow2 "$d/spare0.qcow2" 4G >/dev/null
    # The OS disk keeps bootindex 0: SeaBIOS boots only the first disk it finds,
    # and a blank NVMe or spare disk ahead of it is an empty console.
    ex_disk=(-drive file="$d/disk.qcow2",if=none,id=osdisk,format=qcow2
             -device virtio-blk-pci,drive=osdisk,bootindex=0
             -drive file="$d/spare0.qcow2",if=none,id=spare0,format=qcow2
             -device virtio-blk-pci,drive=spare0,serial=lvspare0
             -drive file="$d/nvme0.qcow2",if=none,id=nvme0,format=qcow2
             -device nvme,drive=nvme0,serial=lvnvme0
             -device qemu-xhci,id=xhci
             -device usb-tablet,bus=xhci.0
             -device usb-kbd,bus=xhci.0)
    # igb (82576) behind its own root port: the PF exposes SR-IOV, the node makes
    # VFs with sriov_numvfs, and each VF is an assignable PCI function.
    ex_net+=(-device pcie-root-port,id=rp-igb,chassis=10,slot=10
             -netdev "$(lan_netdev net4 igb "$LAB_IGB_MCAST" "node-$i")"
             -device igb,bus=rp-igb,netdev=net4,mac="$(igbmac "$i")")
  fi
  if [[ -n "${LAB_MIG_MCAST:-}" ]]; then
    ex_net+=(-netdev "$(lan_netdev net2 mig "$LAB_MIG_MCAST" "node-$i")"
             -device virtio-net-pci,netdev=net2,mac="$(migmac "$i")")
  fi
  if [[ -n "${LAB_TRUNK_MCAST:-}" ]]; then
    ex_net+=(-netdev "$(lan_netdev net3 trunk "$LAB_TRUNK_MCAST" "node-$i")"
             -device virtio-net-pci,netdev=net3,mac="$(trunkmac "$i")")
  fi
  if [[ "${LAB_NODE_QMP:-0}" == 1 ]]; then
    ex_tail=(-qmp unix:"$d/qmp.sock",server=on,wait=off)
  fi
}

# netplan_extras <n> — the netplan document for node N's extra NICs, or nothing
# when no extra network is configured. Matched by MAC, like the cluster NIC.
netplan_extras() {
  local i="$1" out=""
  if [[ -n "${LAB_MIG_MCAST:-}" ]]; then
    [[ -n "${LAB_MIG_PREFIX:-}" ]] || { echo "LAB_MIG_MCAST needs LAB_MIG_PREFIX" >&2; exit 2; }
    out+="    mignet:
      match:
        macaddress: \"$(migmac "$i")\"
      set-name: mignet
      addresses: [$(migip "$i")/24]
"
  fi
  if [[ -n "${LAB_TRUNK_MCAST:-}" ]]; then
    out+="    trunk0:
      match:
        macaddress: \"$(trunkmac "$i")\"
      set-name: trunk0
      dhcp4: false
      dhcp6: false
      accept-ra: false
      link-local: []
"
  fi
  if node_hw "$i"; then
    out+="    sriov0:
      match:
        macaddress: \"$(igbmac "$i")\"
      set-name: sriov0
      dhcp4: false
      dhcp6: false
      accept-ra: false
      link-local: []
"
  fi
  [[ -n "$out" ]] || return 0
  printf 'network:\n  version: 2\n  ethernets:\n%s' "$out"
}

# lan_addresses <n> — the cluster NIC's address list (plus the ULA when set).
lan_addresses() {
  if [[ -n "${LAB_LAN6_PREFIX:-}" ]]; then echo "[$(nodeip "$1")/24, \"$(lan6ip "$1")/64\"]"
  else echo "[$(nodeip "$1")/24]"; fi
}

# extras_write_file <n> — a cloud-init write_files entry for netplan_extras,
# starting with a newline so it can follow the previous line directly, or
# nothing at all (so a lab without extras gets byte-identical user-data).
extras_write_file() {
  local doc; doc="$(netplan_extras "$1")"
  [[ -n "$doc" ]] || return 0
  printf "\n  - path: /etc/netplan/61-lab-extras.yaml\n    permissions: '0600'\n    content: |\n"
  printf '%s\n' "$doc" | sed 's/^/      /'
}

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
            addresses: $(lan_addresses "$i")$(extras_write_file "$i")
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
  net_mode_guard
  hubs_up                  # every LAN up before any VM boots onto it
  serve
  for i in $(nodes_arg "$@"); do
    local d; d="$(nodedir "$i")"
    local running
    if running="$(qemu_pid "$i")"; then
      echo "node-$i already running (pid $running)"; continue
    fi
    # Opt-in extras (lab.env); every array is empty without them, so the argv is
    # the classic one.
    local ex_pre ex_disk ex_net ex_tail
    node_qemu_extras "$i"
    local disk=(-drive file="$d/disk.qcow2",if=virtio,format=qcow2)
    [[ ${#ex_disk[@]} -gt 0 ]] && disk=("${ex_disk[@]}")
    qemu-system-x86_64 \
      -name "$QEMU_NAME-$i" \
      -enable-kvm -cpu host -smp "$VCPUS" -m "$(node_mem "$i")" \
      "${ex_pre[@]}" \
      -smbios "type=1,serial=ds=nocloud-net;s=http://10.0.2.2:$SEEDPORT/node-$i/" \
      "${disk[@]}" \
      -netdev user,id=net0,hostfwd=tcp:127.0.0.1:$(sshport "$i")-:22 \
      -device virtio-net-pci,netdev=net0,mac=$(natmac "$i") \
      -netdev "$(lan_netdev net1 cluster "$MCAST" "node-$i")" \
      -device virtio-net-pci,netdev=net1,mac=$(lanmac "$i") \
      "${ex_net[@]}" \
      "${ex_tail[@]}" \
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
  echo "net mode   $NET_MODE  (LANs: $(lab_lans); hubs in $HUB_DIR)"
  echo "mcast      $MCAST$([[ "$NET_MODE" == mcast ]] || echo "  (unused: LAB_NET_MODE=mcast only)")"
  echo "ssh        127.0.0.1:$(sshport 1)..$(sshport "$NODES")"
  echo "lan        $(nodeip 1)..$(nodeip "$NODES")/24"
  echo "macs       $(natmac 1) (nat), $(lanmac 1) (lan) .. node $NODES"
  echo "qemu name  $QEMU_NAME-1..$QEMU_NAME-$NODES"
  echo "nodes dir  $(readlink -f "$LAB/nodes" 2>/dev/null || echo "$LAB/nodes")"
  # Extras are listed only when this instance opts in to them.
  [[ -n "${LAB_NODE_MEM:-}" ]]   && echo "node mem   $LAB_NODE_MEM (others $MEM)"
  [[ "${LAB_NODE_QMP:-0}" == 1 ]] && echo "qmp        nodes/node-N/qmp.sock"
  [[ "${LAB_NODE_HW:-0}" == 1 ]] && echo "node hw    q35+intel-iommu, igb ($LAB_IGB_MCAST, $(igbmac 1)..), nvme, spare disk, xhci  on: ${LAB_NODE_HW_NODES:-all}"
  [[ -n "${LAB_MIG_MCAST:-}" ]]  && echo "migration  $LAB_MIG_MCAST  $(migip 1)..$(migip "$NODES")/24  macs $(migmac 1).."
  [[ -n "${LAB_TRUNK_MCAST:-}" ]] && echo "trunk      $LAB_TRUNK_MCAST  macs $(trunkmac 1).."
  [[ -n "${LAB_LAN6_PREFIX:-}" ]] && echo "lan ipv6   $(lan6ip 1)..$(lan6ip "$NODES")/64"
  [[ -n "${LAB_CGROUP_V1_NODES:-}" ]] && echo "cgroup v1  nodes $LAB_CGROUP_V1_NODES"
  if [[ -n "${LAB_AUX_ROLES:-}" ]]; then
    local r; for r in $LAB_AUX_ROLES; do
      echo "aux $r    $(aux_ip "$r")  ssh 127.0.0.1:$(aux_sshport "$r")  macs $(aux_natmac "$r")/$(aux_lanmac "$r")  qemu $QEMU_NAME-aux-$r"
    done
  fi
  [[ -n "${LAB_BMC_AGENT_PORT:-}" ]] && echo "bmc agent  127.0.0.1:$LAB_BMC_AGENT_PORT (guests: 10.0.2.2:$LAB_BMC_AGENT_PORT)"
  return 0
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
  net_mode_guard
  hubs_up cluster
  serve
  local r
  for r in "$@"; do
    local n d running; n="$(st_name "$r")"; d="$(st_dir "$r")"
    if running="$(st_pid "$r")"; then echo "$n already running (pid $running)"; continue; fi
    [[ -f "$d/disk.qcow2" ]] || storage_create "$r"
    local drives=() spec
    for spec in $(st_data "$r"); do
      # serial= is a -device property: qemu 8 refuses it on -drive.
      drives+=(-drive "file=$d/${spec%%:*}.qcow2,if=none,id=${spec%%:*},format=qcow2"
               -device "virtio-blk-pci,drive=${spec%%:*},serial=${spec%%:*}")
    done
    qemu-system-x86_64 \
      -name "$QEMU_NAME-storage-$r" \
      -enable-kvm -cpu host -smp "$(st_vcpus "$r")" -m "$(st_mem "$r")" \
      -smbios "type=1,serial=ds=nocloud-net;s=http://10.0.2.2:$SEEDPORT/$n/" \
      -drive file="$d/disk.qcow2",if=none,id=osdisk,format=qcow2 \
      -device virtio-blk-pci,drive=osdisk,bootindex=0 \
      "${drives[@]}" \
      -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"$(st_sshport "$r")"-:22 \
      -device virtio-net-pci,netdev=net0,mac="$(st_natmac "$r")" \
      -netdev "$(lan_netdev net1 cluster "$MCAST" "$n")" \
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

# ── aux VMs (opt-in: LAB_AUX_ROLES) ─────────────────────────────────────────
# Non-litevirt helper VMs on the cluster LAN, built like the storage VMs above:
#
#   bmc  simulated BMCs for every node — one ipmi_sim (OpenIPMI lanserv) per node
#        on its own LAN address (LAB_BMC_IPMI_BASE+N, UDP 623) and a sushy-tools
#        Redfish service (LAB_BMC_IP:8000). They power nodes through the host-side
#        power agent (tools/bmc-agent.py), which runs lab.sh up/down. Provisioned
#        by tools/bmc.sh.
#   idm  kanidm (OIDC provider) and Mailpit (SMTP sink), provisioned by tools/idm.sh.
#
#   lab.sh aux up|down|status|create|destroy [bmc|idm|all]   |   lab.sh aux ssh <role> [cmd]
#
# Disk files live in aux/<role>/ (symlink aux/ to /mnt/vmstore first, like nodes/).
AUX_ROLES="${LAB_AUX_ROLES:-}"
AUX_SSH_BASE="${LAB_AUX_SSH_PORT_BASE:-2260}"
aux_idx()    { case "$1" in bmc) echo 1;; idm) echo 2;; *) return 1;; esac; }
aux_dir()    { echo "$LAB/aux/$1"; }
aux_ip()     { case "$1" in bmc) echo "${LAB_BMC_IP:-$LAN_PREFIX.40}";; idm) echo "${LAB_IDM_IP:-$LAN_PREFIX.50}";; esac; }
aux_vcpus()  { case "$1" in bmc) echo 1;; idm) echo 2;; esac; }
aux_mem()    { case "$1" in bmc) echo 1024;; idm) echo 2048;; esac; }
aux_osdisk() { case "$1" in bmc) echo 8G;; idm) echo 16G;; esac; }
aux_sshport(){ echo $((AUX_SSH_BASE + $(aux_idx "$1"))); }
aux_natmac() { printf "$MAC_PREFIX:07:%02x" "$(aux_idx "$1")"; }
aux_lanmac() { printf "$MAC_PREFIX:08:%02x" "$(aux_idx "$1")"; }
aux_pid()    { pidfile_pid "$(aux_dir "$1")/qemu.pid"; }

# aux_roles <arg...> — enabled roles named, or all of them; refuses a role the
# instance did not enable, so lab 2 cannot boot lab 1's helpers by accident.
aux_roles() {
  [[ -n "$AUX_ROLES" ]] || { echo "no aux VMs enabled for this lab (set LAB_AUX_ROLES in lab.env)" >&2; exit 2; }
  if [[ $# -eq 0 ]]; then echo $AUX_ROLES; return; fi
  local a
  for a in "$@"; do
    [[ "$a" == all ]] && { echo $AUX_ROLES; continue; }
    [[ " $AUX_ROLES " == *" $a "* ]] || { echo "aux VM $a not enabled (LAB_AUX_ROLES=\"$AUX_ROLES\")" >&2; exit 2; }
    echo "$a"
  done
}

aux_ssh() {
  local r="$1"; shift
  timeout "${AUX_SSH_TIMEOUT:-120}" ssh -q -i "$SSH_PRIV" -o IdentityAgent=none -o IdentitiesOnly=yes \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o LogLevel=ERROR \
      -p "$(aux_sshport "$r")" root@127.0.0.1 "$@"
}

aux_create() {
  [[ -f "$BASE" ]] || { echo "base image missing: $BASE (run: $0 image)" >&2; exit 1; }
  [[ -f "$SSH_KEY" ]] || { echo "ssh key missing: $SSH_KEY" >&2; exit 1; }
  local pub; pub="$(cat "$SSH_KEY")"
  [[ -f "$SSH_PRIV" ]] || ssh-keygen -q -t ed25519 -N '' -f "$SSH_PRIV" -C litevirt-lab
  [[ -f "$SSH_PRIV.pub" ]] || ssh-keygen -y -f "$SSH_PRIV" > "$SSH_PRIV.pub"
  local cpub; cpub="$(cat "$SSH_PRIV.pub")"
  local r
  for r in "$@"; do
    local d; d="$(aux_dir "$r")"
    mkdir -p "$d" "$LAB/seed-http/aux-$r"
    [[ -f "$d/disk.qcow2" ]] || \
      qemu-img create -f qcow2 -F qcow2 -b "$BASE" "$d/disk.qcow2" "$(aux_osdisk "$r")" >/dev/null
    cat > "$LAB/seed-http/aux-$r/meta-data" <<EOF
instance-id: litevirt-aux-$r
local-hostname: $r
EOF
    cat > "$LAB/seed-http/aux-$r/user-data" <<EOF
#cloud-config
hostname: $r
fqdn: $r.lab
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
              macaddress: "$(aux_lanmac "$r")"
            set-name: net1
            addresses: [$(aux_ip "$r")/24]
runcmd:
  - [ netplan, apply ]
  - [ sh, -c, "echo lab-ready > /var/lib/cloud/lab-ready" ]
EOF
    echo "aux-$r  ip=$(aux_ip "$r")  ssh=127.0.0.1:$(aux_sshport "$r")  $d"
  done
}

aux_up() {
  net_mode_guard
  hubs_up cluster
  serve
  local r
  for r in "$@"; do
    local d running; d="$(aux_dir "$r")"
    if running="$(aux_pid "$r")"; then echo "aux-$r already running (pid $running)"; continue; fi
    [[ -f "$d/disk.qcow2" ]] || aux_create "$r"
    qemu-system-x86_64 \
      -name "$QEMU_NAME-aux-$r" \
      -enable-kvm -cpu host -smp "$(aux_vcpus "$r")" -m "$(aux_mem "$r")" \
      -smbios "type=1,serial=ds=nocloud-net;s=http://10.0.2.2:$SEEDPORT/aux-$r/" \
      -drive file="$d/disk.qcow2",if=none,id=osdisk,format=qcow2 \
      -device virtio-blk-pci,drive=osdisk,bootindex=0 \
      -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"$(aux_sshport "$r")"-:22 \
      -device virtio-net-pci,netdev=net0,mac="$(aux_natmac "$r")" \
      -netdev "$(lan_netdev net1 cluster "$MCAST" "aux-$r")" \
      -device virtio-net-pci,netdev=net1,mac="$(aux_lanmac "$r")" \
      -display none -daemonize \
      -pidfile "$d/qemu.pid" \
      -serial file:"$d/console.log"
    echo "aux-$r started (pid $(cat "$d/qemu.pid"))  ip=$(aux_ip "$r")  ssh 127.0.0.1:$(aux_sshport "$r")"
  done
}

aux_down() {
  local r pid
  for r in "$@"; do
    local d; d="$(aux_dir "$r")"
    [[ -f "$d/qemu.pid" ]] || continue
    if pid="$(aux_pid "$r")"; then kill "$pid"; echo "aux-$r stopped"; fi
    rm -f "$d/qemu.pid"
  done
}

aux_status() {
  printf "%-10s %-8s %-14s %-22s %s\n" NAME PID IP SSH CLOUDINIT
  local r
  for r in "$@"; do
    local pid="-" ci="-" live
    if live="$(aux_pid "$r")"; then
      pid="$live"
      ci="$(AUX_SSH_TIMEOUT=20 aux_ssh "$r" 'cloud-init status 2>/dev/null | head -1' 2>/dev/null || echo unreachable)"
    fi
    printf "%-10s %-8s %-14s %-22s %s\n" "aux-$r" "$pid" "$(aux_ip "$r")" "127.0.0.1:$(aux_sshport "$r")" "$ci"
  done
}

aux_destroy() {
  aux_down "$@"
  local r; for r in "$@"; do
    rm -rf -- "$(aux_dir "$r")" "$LAB/seed-http/aux-$r"
    echo "aux-$r destroyed"
  done
}

aux_cmd() {
  local verb="${1:-}"; shift || true
  if [[ "$verb" == ssh ]]; then
    local r; r="$(aux_roles "${1:?usage: $0 aux ssh <role> [cmd]}")" || exit $?
    shift
    aux_ssh "$r" "$@"; return
  fi
  local roles; roles="$(aux_roles "$@")" || exit $?
  # shellcheck disable=SC2086
  set -- $roles
  case "$verb" in
    create)  aux_create "$@" ;;
    up)      aux_up "$@" ;;
    down)    aux_down "$@" ;;
    status)  aux_status "$@" ;;
    destroy) aux_destroy "$@" ;;
    *) echo "usage: $0 aux {up|down|status|create|destroy} [bmc|idm|all]   |   $0 aux ssh <role> [cmd]" >&2; exit 2 ;;
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
  pid)    shift; qemu_pid "${1:?usage: $0 pid <n>}" ;;
  netplan-extras) shift; netplan_extras "${1:?usage: $0 netplan-extras <n>}" ;;
  ssh)    shift; nssh "$@" ;;
  deploy) shift; deploy "$@" ;;
  storage) shift; storage_cmd "$@" ;;
  aux)    shift; aux_cmd "$@" ;;
  hub)    shift; case "${1:-status}" in
            status) shift || true; hubs_status "$@" ;;
            up)     shift; NET_MODE=hub; hubs_up "$@" ;;
            down)   shift; hubs_down "$@" ;;
            *) echo "usage: $0 hub {status [-v]|up [lan...]|down [lan...]}" >&2; exit 2 ;;
          esac ;;
  hub-status) shift; hubs_status "$@" ;;
  destroy) shift; destroy "$@" ;;
  *) echo "usage: $0 {image|create|up|down|status|info|ssh <n> [cmd]|deploy [binary]|destroy|storage ...|aux ...|hub ...|hub-status|pid <n>|netplan-extras <n>} [n...]  (no numbers = all)" >&2; exit 2 ;;
esac
