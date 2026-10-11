#!/usr/bin/env bash
# node-extras.sh [node...] — the guest side of lab.sh's opt-in node extras
# (default: every node 1..N). Run on the lab host, from the lab dir.
#
# What lab.sh can only give a node from OUTSIDE (qemu devices, NICs) needs the
# matching setup INSIDE it, and on an existing node cloud-init never runs again.
# This writes that setup; it changes nothing that needs a reboot to take effect
# until the node's next boot (which `lab.sh down N; lab.sh up N` gives it, with
# the new qemu devices):
#
#   LAB_NODE_HW nodes   kernel cmdline intel_iommu=on iommu=pt; pciutils, usbutils,
#                       smartmontools, nvme-cli; LAB_SRIOV_VFS (default 2) igb VFs
#                       made at boot by lab-sriov-vfs.service
#   every node          /etc/netplan/61-lab-extras.yaml (`lab.sh netplan-extras N`)
#                       and the cluster NIC's ULA (LAB_LAN6_PREFIX) in 60-cluster.yaml;
#                       /srv/lv-e2e-mounts/data for containers.bind_mount_paths;
#                       ipmitool, tcpdump
#   LAB_CGROUP_V1_NODES systemd.unified_cgroup_hierarchy=0 (legacy cgroup v1)
#
# Nothing is applied live: no `netplan apply` (litevirt's own bridges and the ssh
# NIC are on the same netplan), no reboot. CHECK=1 only reports what a node has.
# Idempotent. Ends with PASS/FAIL.
set -euo pipefail
# shellcheck source=storage-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/storage-lib.sh"

if [[ $# -gt 0 ]]; then targets=("$@"); else mapfile -t targets < <(seq 1 "$NODES"); fi
hw_on() { [[ "${LAB_NODE_HW:-0}" == 1 ]] && [[ -z "${LAB_NODE_HW_NODES:-}" || " $LAB_NODE_HW_NODES " == *" $1 "* ]]; }
cg1_on() { [[ " ${LAB_CGROUP_V1_NODES:-} " == *" $1 "* ]]; }

total=0
for n in "${targets[@]}"; do
  say "node-$n"
  extras="$("$LAB/lab.sh" netplan-extras "$n")"
  lanip="$LAN_PREFIX.$((10 + n))"
  lan6=""; [[ -n "${LAB_LAN6_PREFIX:-}" ]] && lan6="${LAB_LAN6_PREFIX}$((10 + n))"
  hw=0; hw_on "$n" && hw=1
  cg1=0; cg1_on "$n" && cg1=1
  rc=0
  ex64="$(printf '%s' "$extras" | base64 -w0)"
  SSH_TIMEOUT=900 nodessh "$n" 'bash -s' -- "${CHECK:-0}" "$hw" "$cg1" "$lanip" "$lan6" "${LAB_SRIOV_VFS:-2}" "${ex64:--}" <<'REMOTE' || rc=$?
set -euo pipefail
CHECK="$1"; HW="$2"; CG1="$3"; LANIP="$4"; LAN6="$5"; VFS="$6"
EXTRAS=""; [[ "$7" == - ]] || EXTRAS="$(printf '%s' "$7" | base64 -d)"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1
fails=0
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok:   $d"; else echo "FAIL: $d"; fails=$((fails+1)); fi; }

if [[ "$CHECK" != 1 ]]; then
  pk=(ipmitool tcpdump)
  [[ "$HW" == 1 ]] && pk+=(pciutils usbutils smartmontools nvme-cli)
  missing=(); for p in "${pk[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if [[ ${#missing[@]} -gt 0 ]]; then
    apt-get update -qq
    # smartmontools recommends an MTA; keep postfix off the node.
    apt-get install -y -qq --no-install-recommends "${missing[@]}" >/dev/null
  fi

  # Kernel command line. 50-cloudimg-settings.cfg sets the console; this file
  # sorts after it and appends, so the console stays.
  args=""
  [[ "$HW" == 1 ]] && args+=" intel_iommu=on iommu=pt"
  [[ "$CG1" == 1 ]] && args+=" systemd.unified_cgroup_hierarchy=0 SYSTEMD_CGROUP_ENABLE_LEGACY_FORCE=1"
  cfg=/etc/default/grub.d/90-lab-extras.cfg
  want=""
  [[ -n "$args" ]] && want="GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT$args\""
  have="$(cat "$cfg" 2>/dev/null || true)"
  if [[ "$want" != "$have" ]]; then
    if [[ -n "$want" ]]; then printf '%s\n' "$want" > "$cfg"; else rm -f "$cfg"; fi
    update-grub >/dev/null 2>&1
    echo "grub: kernel args now:${args:- (none extra)} (takes effect at next boot)"
  fi

  # Netplan: the extra NICs, and the ULA on the cluster NIC. Written only; the
  # next boot applies them (the NICs do not exist before it anyway).
  if [[ -n "$EXTRAS" ]]; then
    umask 077; printf '%s\n' "$EXTRAS" > /etc/netplan/61-lab-extras.yaml.new
    mv -f /etc/netplan/61-lab-extras.yaml.new /etc/netplan/61-lab-extras.yaml
  fi
  if [[ -n "$LAN6" ]] && ! grep -qF "\"$LAN6/64\"" /etc/netplan/60-cluster.yaml; then
    sed -i "s#addresses: \[$LANIP/24\]#addresses: [$LANIP/24, \"$LAN6/64\"]#" /etc/netplan/60-cluster.yaml
  fi
  netplan generate

  # igb VFs at boot. litevirt's pci.sriov.managed is off on this lab, so the VFs
  # are the operator's; this unit is that operator.
  if [[ "$HW" == 1 ]]; then
    cat > /etc/systemd/system/lab-sriov-vfs.service <<UNIT
[Unit]
Description=lab: create $VFS SR-IOV VFs on the igb NIC (sriov0)
After=systemd-networkd.service
Wants=systemd-networkd.service
ConditionPathExists=/sys/class/net/sriov0/device/sriov_totalvfs

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'cur=\$(cat /sys/class/net/sriov0/device/sriov_numvfs); [ "\$cur" = "$VFS" ] || { echo 0 > /sys/class/net/sriov0/device/sriov_numvfs; echo $VFS > /sys/class/net/sriov0/device/sriov_numvfs; }; ip link set sriov0 up'

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable lab-sriov-vfs.service >/dev/null 2>&1
  fi

  # A directory for containers.bind_mount_paths (LV_E2E_MOUNT_DIR).
  install -d -m 0755 /srv/lv-e2e-mounts/data
  [[ -f /srv/lv-e2e-mounts/data/README ]] || echo "lab: bind-mount test dir (containers.bind_mount_paths: [/srv/lv-e2e-mounts])" > /srv/lv-e2e-mounts/data/README
fi

# ── report what the node has now ────────────────────────────────────────────
chk "bind-mount dir /srv/lv-e2e-mounts/data" test -d /srv/lv-e2e-mounts/data
chk "ipmitool installed" command -v ipmitool
if [[ -n "$EXTRAS" ]]; then chk "netplan 61-lab-extras.yaml" test -s /etc/netplan/61-lab-extras.yaml; fi
if [[ -n "$LAN6" ]]; then chk "ULA $LAN6/64 in 60-cluster.yaml" grep -qF "\"$LAN6/64\"" /etc/netplan/60-cluster.yaml; fi
if [[ "$HW" == 1 ]]; then
  chk "grub has intel_iommu=on iommu=pt" grep -q 'intel_iommu=on iommu=pt' /boot/grub/grub.cfg
  chk "lab-sriov-vfs.service enabled" systemctl is-enabled lab-sriov-vfs.service
  for t in lspci lsusb smartctl nvme; do chk "$t installed" command -v "$t"; done
  if grep -qw intel_iommu=on /proc/cmdline; then
    chk "running: IOMMU groups present" sh -c 'ls /sys/kernel/iommu_groups | grep -q .'
    chk "running: igb VFs ($VFS)" sh -c "[ \"\$(cat /sys/class/net/sriov0/device/sriov_numvfs)\" = $VFS ]"
    chk "running: spare disk virtio-lvspare0" test -b /dev/disk/by-id/virtio-lvspare0
    chk "running: nvme0 SMART" smartctl -H /dev/nvme0
    chk "running: a USB device beyond the root hubs" sh -c 'lsusb | grep -v "root hub" | grep -q .'
  else
    echo "note: intel_iommu not on the running cmdline yet (needs the next boot)"
  fi
fi
if [[ "$CG1" == 1 ]]; then
  chk "grub has systemd.unified_cgroup_hierarchy=0" grep -q 'systemd.unified_cgroup_hierarchy=0' /boot/grub/grub.cfg
  if grep -q 'systemd.unified_cgroup_hierarchy=0' /proc/cmdline; then
    chk "running: /sys/fs/cgroup is v1 (tmpfs)" sh -c '[ "$(stat -fc %T /sys/fs/cgroup)" = tmpfs ]'
  fi
fi
[[ $fails -eq 0 ]]
REMOTE
  [[ $rc -eq 0 ]] || total=$((total + 1))
done
finish "node-extras (${targets[*]})" "$total"
