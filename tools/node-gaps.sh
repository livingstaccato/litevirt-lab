#!/usr/bin/env bash
# node-gaps.sh [node...]        — in-node setup the litevirt test suite needs
# node-gaps.sh roll [node...]   — rolling daemon restart (explicit, separate)
# (default nodes: every node 1..N). Run on the lab host, from the lab dir.
#
#   mods    linux-modules-extra for the running kernel, plus linux-image-extra-virtual
#           (-> linux-image-generic), the metapackage that brings each future
#           kernel's modules-extra with it, so a kernel unattended-upgrades
#           installs does not boot without qemu_fw_cfg; qemu_fw_cfg loaded now
#           and at every boot (/etc/modules-load.d/qemu_fw_cfg.conf).
#           unattended-upgrades stays on (reported, never changed).
#   fence   a per-lab SSH fence key, so a node's root can ssh-fence its peers:
#           the private key as /root/.ssh/id_ed25519_lvfence, its public half in
#           authorized_keys, and `Host <LAN prefix>.*` + IdentityFile in
#           /root/.ssh/config. The key lives in $LAB/secrets/lvfence_key
#           (gitignored, generated on first apply, never printed).
#   config  `migration: {network: <LAB_MIG_PREFIX>.0/24}` appended to
#           /etc/litevirt/config.yaml, only on nodes that have a mignet NIC
#           (LAB_MIG_MCAST set). An existing `migration:` block is never edited.
#
# Editing config.yaml does not reach the running daemon: apply, then `roll`.
# roll restarts one node at a time (witness first, node 1 last), waits for the
# unit to be active and greps its journal for config/quarantine errors. It is
# its own step on purpose; HA fences a node that restarts too quickly, so the
# gap between nodes is deliberate (ROLL_GAP, default 15s).
#
# CHECK=1 only reports (read-only; no key is generated, nothing is written).
# Idempotent. Ends with PASS/FAIL.
set -euo pipefail
# shellcheck source=storage-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/storage-lib.sh"

mode=apply
if [[ "${1:-}" == roll ]]; then mode=roll; shift; fi
if [[ $# -gt 0 ]]; then targets=("$@"); else mapfile -t targets < <(seq 1 "$NODES"); fi

if [[ "$mode" == roll ]]; then
  [[ "${CHECK:-0}" != 1 ]] || die "roll restarts daemons; it has no CHECK mode"
  total=0
  mapfile -t order < <(printf '%s\n' "${targets[@]}" | sort -rn)
  for n in "${order[@]}"; do
    say "restart node-$n"
    rc=0
    SSH_TIMEOUT=120 nodessh "$n" 'systemctl restart litevirt; sleep 8; systemctl is-active litevirt
      echo "cfg-err-lines=$(journalctl -u litevirt --since "-20s" --no-pager | grep -ciE "yaml|config.*error|quarantine" || true)"' || rc=$?
    [[ $rc -eq 0 ]] || total=$((total + 1))
    sleep "${ROLL_GAP:-15}"
  done
  finish "node-gaps roll (${targets[*]})" "$total"
fi

CHECK="${CHECK:-0}"
FENCE_KEY="$SECRETS/lvfence_key"
MIG_CIDR=""
[[ -n "${LAB_MIG_MCAST:-}" && -n "${LAB_MIG_PREFIX:-}" ]] && MIG_CIDR="$LAB_MIG_PREFIX.0/24"

fence_priv=""; fence_pub=""
if [[ "$CHECK" != 1 ]]; then
  secrets_dir
  [[ -f "$FENCE_KEY" ]] || ssh-keygen -q -t ed25519 -N '' -C "lvfence-$STORAGE_PREFIX" -f "$FENCE_KEY"
  fence_priv="$(base64 -w0 < "$FENCE_KEY")"
  # base64 like the private half: ssh joins remote args into one command line,
  # so a key with spaces would arrive split into words.
  fence_pub="$(base64 -w0 < "$FENCE_KEY.pub")"
fi

total=0
for n in "${targets[@]}"; do
  say "node-$n"
  rc=0
  SSH_TIMEOUT=900 nodessh "$n" 'bash -s' -- "$CHECK" "$LAN_PREFIX" "${MIG_CIDR:--}" "${fence_priv:--}" "${fence_pub:--}" <<'REMOTE' || rc=$?
set -euo pipefail
CHECK="$1"; LANP="$2"; MIG=""; [[ "$3" == - ]] || MIG="$3"
PRIV=""; [[ "$4" == - ]] || PRIV="$(printf '%s' "$4" | base64 -d)"
PUB="";  [[ "$5" == - ]] || PUB="$(printf '%s' "$5" | base64 -d)"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1
fails=0
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok:   $d"; else echo "FAIL: $d"; fails=$((fails+1)); fi; }
k="$(uname -r)"
cfg=/etc/litevirt/config.yaml
has_mig() { ip -4 -o addr show mignet >/dev/null 2>&1; }

if [[ "$CHECK" != 1 ]]; then
  # mods
  dpkg -s "linux-modules-extra-$k" >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y -qq "linux-modules-extra-$k" >/dev/null; }
  dpkg -s linux-image-extra-virtual >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y -qq --no-install-recommends linux-image-extra-virtual >/dev/null; }
  modprobe qemu_fw_cfg
  echo qemu_fw_cfg > /etc/modules-load.d/qemu_fw_cfg.conf

  # fence
  umask 077; mkdir -p /root/.ssh
  printf '%s\n' "$PRIV" > /root/.ssh/id_ed25519_lvfence.new; mv -f /root/.ssh/id_ed25519_lvfence.new /root/.ssh/id_ed25519_lvfence
  sed -i '/^ssh-ed25519$/d' /root/.ssh/authorized_keys 2>/dev/null || true  # a bare key type the split-arg bug left
  grep -qxF "$PUB" /root/.ssh/authorized_keys 2>/dev/null || echo "$PUB" >> /root/.ssh/authorized_keys
  grep -q '^# lvfence' /root/.ssh/config 2>/dev/null || \
    printf '%s\n' "# lvfence (lab SSH fence drills)" "Host $LANP.*" "    IdentityFile ~/.ssh/id_ed25519_lvfence" >> /root/.ssh/config
  chmod 600 /root/.ssh/config /root/.ssh/id_ed25519_lvfence /root/.ssh/authorized_keys

  # config: migration network, only where the NIC exists, never over an existing block
  if [[ -n "$MIG" ]] && has_mig && [[ -f $cfg ]] && ! grep -q '^migration:' $cfg; then
    cp -n $cfg /root/config.yaml.pre-node-gaps
    printf 'migration:\n  network: %s\n' "$MIG" >> $cfg
    echo "config: migration.network set to $MIG (daemon picks it up at the next 'node-gaps.sh roll')"
  fi
fi

# ── report ──────────────────────────────────────────────────────────────────
chk "linux-modules-extra-$k installed" dpkg -s "linux-modules-extra-$k"
chk "linux-image-extra-virtual installed (future kernels bring modules-extra)" dpkg -s linux-image-extra-virtual
chk "every installed kernel has its modules-extra" sh -c 'for m in /lib/modules/*/; do v=$(basename "$m"); [ -f "/boot/vmlinuz-$v" ] || continue; dpkg -s "linux-modules-extra-$v" >/dev/null 2>&1 || exit 1; done'
chk "unattended-upgrades enabled" sh -c 'systemctl is-enabled -q unattended-upgrades && grep -q "Unattended-Upgrade \"1\"" /etc/apt/apt.conf.d/20auto-upgrades'
chk "qemu_fw_cfg loaded" sh -c 'lsmod | grep -q "^qemu_fw_cfg"'
chk "qemu_fw_cfg persistent (modules-load.d)" grep -qx qemu_fw_cfg /etc/modules-load.d/qemu_fw_cfg.conf
chk "fence key /root/.ssh/id_ed25519_lvfence (0600)" sh -c '[ "$(stat -c %a /root/.ssh/id_ed25519_lvfence)" = 600 ]'
chk "fence key public half in authorized_keys" sh -c 'p="$(ssh-keygen -y -f /root/.ssh/id_ed25519_lvfence | cut -d" " -f1,2)"; [ -n "$p" ] && grep -qF "$p" /root/.ssh/authorized_keys'
chk "ssh config: Host $LANP.* uses the fence key" sh -c "grep -qF 'Host $LANP.*' /root/.ssh/config && grep -qF id_ed25519_lvfence /root/.ssh/config"
if [[ -n "$MIG" ]]; then
  if has_mig; then
    chk "config.yaml migration.network $MIG" sh -c "awk '/^migration:/{f=1;next} /^[^ ]/{f=0} f' $cfg | grep -qE 'network:[ ]+\"?$MIG\"?'"
  else
    echo "skip: no mignet NIC on this node (migration.network not set)"
  fi
else
  echo "skip: lab has no migration network (LAB_MIG_MCAST unset)"
fi
[[ $fails -eq 0 ]]
REMOTE
  [[ $rc -eq 0 ]] || total=$((total + 1))
done

if [[ "$CHECK" != 1 && $total -eq 0 && ${#targets[@]} -gt 1 ]]; then
  say "cross check: node-${targets[0]} -> node-${targets[1]} over the fence key"
  peer="$LAN_PREFIX.$((10 + targets[1]))"
  SSH_TIMEOUT=30 nodessh "${targets[0]}" "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@$peer hostname" || total=$((total + 1))
fi
finish "node-gaps (${targets[*]})" "$total"
