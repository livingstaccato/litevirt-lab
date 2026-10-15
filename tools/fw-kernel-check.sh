#!/usr/bin/env bash
# fw-kernel-check.sh <ABSOLUTE litevirt worktree> [node N, default 1]
# fw-kernel-check.sh --parse-only <saved -test.v output file> [label]
#
# Kernel-proves internal/firewall's nft rules on a LAB 2 node (merge gate for
# firewall/NIC-guard/log/nat work). A SKIP is a FAILURE here: kvm003 cannot load
# modules, so a skip proves nothing.
#   1. builds the test binary on kvm003 (kbuild.sh, never the laptop) under a
#      unique name in ~/litevirt-lab2 so concurrent callers do not collide;
#   2. copies it to lab 2 node N, modprobes the union of modules the kernel
#      tests use (modprobe inside the lab VM only), runs it with
#      LITEVIRT_NFT_NETNS=1 LITEVIRT_NFT_REQUIRE=1 (children run under
#      `unshare -rnm`, nft -c: the node's ruleset and daemons are untouched);
#   3. parses -test.v: any SKIP/FAIL among kernel tests, or zero kernel tests,
#      exits non-zero. Last line: `fw-kernel-check: <sha> PASS n=<N>` or
#      `fw-kernel-check: <sha> FAIL skips=<names> fails=<names>`;
#   4. removes the binary from the node and kvm003 on exit.
# Env: KBUILD (path to kbuild.sh), KVM_HOST (default kvm003-f3),
#      LAB2_DIR (default ~/litevirt-lab2 on kvm003).
set -uo pipefail

KBUILD=${KBUILD:-$(dirname "$(readlink -f "$0")")/kbuild.sh}
KVM_HOST=${KVM_HOST:-kvm003-f3}
# Union of every module the kernel tests need (kernelTestModules,
# compatCorpusModules, log/limit forms). Add here when a test grows a need.
MODULES="nf_tables nf_conntrack nft_ct nf_conntrack_bridge nft_meta_bridge bridge veth \
nft_reject nft_reject_inet nf_reject_ipv4 nf_reject_ipv6 nf_nat nft_nat nft_masq nft_chain_nat \
nft_log nfnetlink_log nft_limit nft_counter nft_numgen nft_synproxy nf_synproxy_core"

# parse_output <file> <label>: prints the verdict line, returns 0 on PASS.
# Kernel tests = TestKernel*. The parent (TestKernel_*) runs at column 0 and its
# children's real results are the INDENTED lines (the namespace run is logged
# inside the parent). Column-0 TestKernelChild_*/TestKernelHelper_* lines are the
# same tests re-run outside the namespace, where they skip by design: ignored.
parse_output() {
  local f=$1 label=$2
  awk -v label="$label" '
    /^[ \t]*--- (PASS|SKIP|FAIL): TestKernel/ {
      indented = ($0 ~ /^[ \t]/)
      line = $0; sub(/^[ \t]*--- /, "", line)
      split(line, a, /: /); st = a[1]
      name = a[2]; sub(/ .*/, "", name)
      if (!indented && name ~ /^TestKernel(Child|Helper)_/) {
        if (st == "FAIL") fails = fails (fails ? "," : "") name
        next
      }
      if (name ~ /\//) {            # subtest: only a non-pass matters
        if (st == "SKIP") skips = skips (skips ? "," : "") name
        if (st == "FAIL") fails = fails (fails ? "," : "") name
        next
      }
      if (st == "PASS") n++
      else if (st == "SKIP") skips = skips (skips ? "," : "") name
      else fails = fails (fails ? "," : "") name
    }
    /^(--- FAIL|FAIL|panic:)/ { if (!($0 ~ /^--- FAIL: TestKernel/)) other = 1 }
    END {
      if (other && fails == "") fails = "(package FAIL/panic)"
      if (n == 0 && skips == "" && fails == "") fails = "(zero kernel tests ran)"
      if (skips != "" || fails != "") {
        printf "fw-kernel-check: %s FAIL skips=%s fails=%s\n", label, skips, fails; exit 1
      }
      printf "fw-kernel-check: %s PASS n=%d\n", label, n; exit 0
    }' "$f"
}

if [[ ${1:-} == --parse-only ]]; then
  [[ -f ${2:-} ]] || { echo "usage: $0 --parse-only <file> [label]" >&2; exit 2; }
  parse_output "$2" "${3:-parse-only}"; exit $?
fi

WT=${1:-}; N=${2:-1}
[[ $WT == /* && -d $WT ]] || { echo "usage: $0 <ABSOLUTE worktree> [node N]" >&2; exit 2; }
[[ $N =~ ^[0-9]+$ ]] || { echo "node must be a number" >&2; exit 2; }
SHA=$(git -C "$WT" rev-parse --short=8 HEAD) || exit 2
LABEL=$SHA
[[ -n $(git -C "$WT" status --porcelain --untracked-files=no) ]] && LABEL=$SHA-dirty
BASE=$(basename "$WT")
BIN=fwk-$BASE-$SHA-n$N-$$.test
LAB2=${LAB2_DIR:-litevirt-lab2}   # relative to $HOME on kvm003
OUT=$(mktemp)
SSHK() { timeout "${T:-120}" ssh -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=4 "$KVM_HOST" "$@"; }

cleanup() {
  T=60 SSHK "export LAB_SSH_KEY=\$HOME/$LAB2/cluster_key; ~/$LAB2/lssh $N 'rm -f /root/$BIN'; rm -f ~/$LAB2/$BIN" >/dev/null 2>&1 || true
  rm -f "$OUT"
}
trap cleanup EXIT

echo "fw-kernel-check: building $BIN on $KVM_HOST ($LABEL)" >&2
"$KBUILD" "$WT" "go test -c -o \$HOME/$LAB2/$BIN ./internal/firewall/" >&2 \
  || { echo "fw-kernel-check: $LABEL FAIL skips= fails=(build failed)"; exit 1; }

T=180 SSHK "export LAB_SSH_KEY=\$HOME/$LAB2/cluster_key; ~/$LAB2/lscp $N ~/$LAB2/$BIN /root/$BIN && ~/$LAB2/lssh $N 'chmod +x /root/$BIN'" >&2 \
  || { echo "fw-kernel-check: $LABEL FAIL skips= fails=(copy to node $N failed)"; exit 1; }

# Modules: a failed modprobe is reported, not fatal; the test then skips by
# itself naming the module, and that skip fails the gate.
T=120 SSHK "export LAB_SSH_KEY=\$HOME/$LAB2/cluster_key; ~/$LAB2/lssh $N 'for m in $MODULES; do modprobe \$m 2>/dev/null || echo \"modprobe \$m: no (ok if built in)\"; done; uname -r'" >&2

T=900 SSHK "export LAB_SSH_KEY=\$HOME/$LAB2/cluster_key; ~/$LAB2/lssh $N 'cd /root && LITEVIRT_NFT_NETNS=1 LITEVIRT_NFT_REQUIRE=1 ./$BIN -test.run TestKernel -test.v -test.count=1 -test.timeout 10m'" >"$OUT" 2>&1
rc=$?
# Keep a copy for diagnosis (path printed on failure).
if parse_output "$OUT" "$LABEL"; then
  [[ $rc -eq 0 ]] || { echo "fw-kernel-check: $LABEL FAIL skips= fails=(binary exit $rc)"; exit 1; }
  exit 0
fi
mkdir -p "${FWK_OUT_DIR:-$HOME/.cache/fw-kernel-check}" && cp "$OUT" "${FWK_OUT_DIR:-$HOME/.cache/fw-kernel-check}/fw-kernel-check-$SHA.out" 2>/dev/null && echo "fw-kernel-check: full output in ${FWK_OUT_DIR:-$HOME/.cache/fw-kernel-check}/fw-kernel-check-$SHA.out" >&2
exit 1
