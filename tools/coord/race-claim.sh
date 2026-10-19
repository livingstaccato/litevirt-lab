#!/usr/bin/env bash
# kvm003:race slot accounting for board.log, shared by Claude and Codex.
#   race-claim.sh list                         open claims, one per line
#   race-claim.sh claim <owner> <label> <text> claim a slot (exit 1 if none free)
#   race-claim.sh release <owner> <label> <text>
# A claim is identified by owner + label (the first word after kvm003:race).
# A RELEASE closes the oldest open CLAIM with the same owner and label; a
# RELEASE with no open claim is ignored, so old orphan lines cannot drive the
# count negative. Claims older than 6 h are reported as STALE and not counted.
# claim and release run under race.lock, so count-and-append is atomic.
set -euo pipefail
B=$HOME/litevirt-coord/board.log
LOCK=$HOME/litevirt-coord/race.lock
MAX=4
STALE_SECS=$((6 * 3600))

open_claims() {
  local cutoff; cutoff=$(date -u -d "@$(( $(date -u +%s) - STALE_SECS ))" +%Y-%m-%dT%H:%M:%SZ)
  grep -E '^[^ ]+ [^ ]+ (CLAIM|RELEASE) kvm003:race ' "$B" | awk -v cutoff="$cutoff" '
    {
      key = $2 " " $5
      if ($3 == "CLAIM") { n[key]++; q[key, n[key]] = $0 }
      else if (h[key] < n[key]) { h[key]++ }
    }
    END {
      for (k in n) for (i = h[k] + 1; i <= n[k]; i++) {
        split(q[k, i], f, " ")
        print ((f[1] < cutoff) ? "STALE " : "OPEN ") q[k, i]
      }
    }' | sort -k2
}

case "${1:-}" in
  list) open_claims ;;
  claim|release)
    [ $# -ge 4 ] || { echo "usage: $0 $1 <owner> <label> <text>" >&2; exit 2; }
    verb=$1 owner=$2 label=$3; shift 3
    exec 9>"$LOCK"; flock 9
    list=$(open_claims)
    open=$(printf '%s\n' "$list" | grep -c '^OPEN ' || true)
    mine=$(printf '%s\n' "$list" | grep -c "^OPEN [^ ]* $owner CLAIM kvm003:race $label " || true)
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [ "$verb" = claim ]; then
      if [ "$mine" -gt 0 ]; then echo "label $label already open for $owner; release it or pick a new label" >&2; exit 1; fi
      R=$(dirname "$B")/race-reserve
      # a reservation holds back only the last free slot, so idle slots are never wasted
      if [ -s "$R" ] && ! grep -qx "$label" "$R" && [ "$open" -ge $((MAX - 1)) ]; then
        while read -r want; do
          [ -z "$want" ] && continue
          printf '%s\n' "$list" | grep -q "^OPEN [^ ]* [^ ]* CLAIM kvm003:race $want " && continue
          echo "slot reserved for $want (see $R); retry later" >&2; exit 1
        done < "$R"
      fi
      if [ "$open" -ge "$MAX" ]; then printf 'no slot: %s open\n%s\n' "$open" "$list" >&2; exit 1; fi
      echo "$now $owner CLAIM kvm003:race $label $* (open before: $open; race-claim.sh)" >> "$B"
    else
      if [ "$mine" -eq 0 ]; then echo "no open claim $owner $label" >&2; exit 1; fi
      echo "$now $owner RELEASE kvm003:race $label $*" >> "$B"
    fi
    echo "$verb ok: $owner $label (open before: $open)"
    ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac
