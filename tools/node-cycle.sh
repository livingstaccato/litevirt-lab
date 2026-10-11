#!/usr/bin/env bash
# node-cycle.sh <n> [via] — power-cycle node N onto its CURRENT lab.sh qemu
# options (new devices/NICs from lab.env), and wait until the cluster sees it
# HOST_ACTIVE again. One node at a time: never run two of these at once.
#
#   0. Set node N's fence strategy to manual for the duration (restored at the
#      end, also on failure): with ssh/best-effort fencing, a coordinator that
#      saw N offline SSH-powers it off again as soon as its sshd answers, which
#      on the lab is ~25 s into every boot, so N never comes back.
#   1. ACPI shutdown: the QMP power button when the node has a QMP socket, else
#      `systemctl poweroff` over ssh. The daemon stops cleanly either way.
#   2. Wait up to 240 s for qemu to exit; then kill it (a power cut) as a fallback.
#   3. `lab.sh up N` with whatever lab.env says now.
#   4. Wait for ssh, for litevirt active on the node, and for node `via`
#      (default node-1, or node-2 when cycling node-1) to list node-N HOST_ACTIVE.
#
# Run on the lab host, from the lab dir. Ends with PASS/FAIL.
set -euo pipefail
# shellcheck source=storage-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/storage-lib.sh"

n="${1:?usage: node-cycle.sh <n> [via]}"
via="${2:-}"; [[ -n "$via" ]] || { via=1; [[ "$n" == 1 ]] && via=2; }
[[ "$via" != "$n" ]] || die "via must be another node"
qmp="$(readlink -f "$LAB/nodes")/node-$n/qmp.sock"

old="$("$LAB/lab.sh" pid "$n" || true)"
strategy="$(SSH_TIMEOUT=20 nodessh "$via" "litevirt host inspect node-$n" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("fenceStrategy",""))')"
[[ -n "$strategy" ]] || die "cannot read node-$n's fence strategy through node-$via"
restore() {
  [[ "$strategy" == manual ]] && return 0
  SSH_TIMEOUT=30 nodessh "$via" "litevirt host config node-$n --fence-strategy $strategy" >/dev/null &&
    echo "node-$n: fence strategy restored to $strategy" || echo "WARN: restore node-$n's fence strategy to $strategy by hand"
}
trap restore EXIT
if [[ "$strategy" != manual ]]; then
  SSH_TIMEOUT=30 nodessh "$via" "litevirt host config node-$n --fence-strategy manual" >/dev/null 2>&1 ||
    die "cannot set node-$n's fence strategy to manual"
  echo "node-$n: fence strategy $strategy -> manual for the cycle"
fi
if [[ -z "$old" ]]; then
  say "node-$n: already off; just booting it"
elif [[ -S "$qmp" ]]; then
  say "node-$n: shutdown (qemu pid $old) at $(date -u +%T)"
  python3 -I "$LAB/tools/qmp.py" "$qmp" system_powerdown >/dev/null
else
  say "node-$n: shutdown (qemu pid $old) at $(date -u +%T)"
  SSH_TIMEOUT=20 nodessh "$n" 'systemctl poweroff' || true
fi
for _ in $(seq 1 120); do "$LAB/lab.sh" pid "$n" >/dev/null || break; sleep 2; done
if "$LAB/lab.sh" pid "$n" >/dev/null; then
  echo "node-$n did not power off in 240 s; cutting power"
  "$LAB/lab.sh" down "$n"
fi
say "node-$n: off at $(date -u +%T); booting"
"$LAB/lab.sh" up "$n"

for _ in $(seq 1 60); do SSH_TIMEOUT=8 nodessh "$n" true 2>/dev/null && break; sleep 5; done
SSH_TIMEOUT=8 nodessh "$n" true || die "node-$n: no ssh 5 min after boot"
for _ in $(seq 1 60); do
  [[ "$(SSH_TIMEOUT=10 nodessh "$n" 'systemctl is-active litevirt' 2>/dev/null)" == active ]] && break; sleep 5
done
say "node-$n: ssh up, litevirt $(SSH_TIMEOUT=10 nodessh "$n" 'systemctl is-active litevirt' 2>/dev/null) at $(date -u +%T)"
# A HOST_ACTIVE read straight after a quick reboot can be the cluster's view
# from BEFORE it noticed the node go: the coordinator may only now be deciding
# to fence it. So the node must read HOST_ACTIVE continuously for STABLE_SECS
# (default 120) before the fence strategy is restored.
hs() { SSH_TIMEOUT=20 nodessh "$via" "litevirt host ls 2>/dev/null | awk '\$1==\"node-$n\"{print \$3}'" 2>/dev/null || true; }
state=""; since=0
for _ in $(seq 1 120); do
  state="$(hs)"
  if [[ "$state" == HOST_ACTIVE ]]; then
    [[ $since -gt 0 ]] || since=$(date +%s)
    (( $(date +%s) - since >= ${STABLE_SECS:-120} )) && break
  else
    since=0
  fi
  sleep 5
done
"$LAB/lab.sh" pid "$n" >/dev/null || { state="qemu gone (powered off during the wait: fenced?)"; }
SSH_TIMEOUT=20 nodessh "$via" 'litevirt host ls' || true
fails=0
[[ "$state" == HOST_ACTIVE ]] || { echo "FAIL: node-$n is '$state' on node-$via 6 min after boot"; fails=1; }
finish "node-cycle node-$n (now qemu pid $("$LAB/lab.sh" pid "$n" || echo none))" "$fails"
