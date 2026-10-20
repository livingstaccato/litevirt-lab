#!/usr/bin/env bash
# kvm003:race slot accounting for board.log, shared by Claude and Codex.
#   race-claim.sh list                          open claims, one per line
#   race-claim.sh claim   <owner> <label> <text> claim a slot (exit 1 if none free)
#   race-claim.sh release <owner> <label> <text>
#   race-claim.sh reserve   <owner> <label>      queue a reservation (FIFO)
#   race-claim.sh unreserve <owner> <label>      drop your own reservation
#   race-claim.sh reserved                       the reservation queue
# A claim is identified by owner + label (the first word after kvm003:race).
# A RELEASE closes the oldest open CLAIM with the same owner and label; a
# RELEASE with no open claim is ignored, so orphan lines cannot drive the count
# negative. A claim never expires by age: it stays open until released.
#
# Reservations: while the queue is not empty, its HEAD label may claim whenever
# open < MAX; any other claim is allowed only while open == 0, so the waiter
# behind the head always finds open <= 1 within one running job. A reserved
# label leaves the queue when it claims. Every read-count-append, including
# reserve and unreserve, runs under race.lock.
#
# Global-2: while any claim by an owner listed in GLOBAL2_OWNERS is open, the
# total of open claims (all owners) may not exceed 2, until that claim is
# released. The reservation head is matched by owner AND label.
set -euo pipefail
D=${RACE_CLAIM_DIR:-$HOME/litevirt-coord}
B=$D/board.log
LOCK=$D/race.lock
R=$D/race-reserve
MAX=4
GLOBAL2_OWNERS="codex"

open_claims() {
  { grep -E '^[^ ]+ [^ ]+ (CLAIM|RELEASE) kvm003:race ' "$B" || true; } | awk '
    {
      key = $2 " " $5
      if ($3 == "CLAIM") { n[key]++; q[key, n[key]] = $0 }
      else if (h[key] < n[key]) { h[key]++ }
    }
    END { for (k in n) for (i = h[k] + 1; i <= n[k]; i++) print "OPEN " q[k, i] }' | sort -k2
}

head_reserved() { [ -s "$R" ] && grep -m1 -v '^[[:space:]]*$' "$R" || true; }

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

case "${1:-}" in
  list) open_claims ;;
  reserved) [ -s "$R" ] && cat "$R" || true ;;
  claim|release|reserve|unreserve)
    [ $# -ge 3 ] || { echo "usage: $0 $1 <owner> <label> [text]" >&2; exit 2; }
    verb=$1 owner=$2 label=$3; shift 3
    exec 9>"$LOCK"; flock 9
    touch "$R"
    list=$(open_claims)
    open=$(printf '%s\n' "$list" | grep -c '^OPEN ' || true)
    mine=$(printf '%s\n' "$list" | grep -c "^OPEN [^ ]* $owner CLAIM kvm003:race $label " || true)
    head=$(head_reserved)
    cap=$MAX
    for g in $GLOBAL2_OWNERS; do
      printf '%s\n' "$list" | grep -q "^OPEN [^ ]* $g CLAIM kvm003:race " && cap=2
    done
    case "$verb" in
      reserve)
        if grep -q "^[^ ]* $label$" "$R"; then echo "$label already reserved" >&2; exit 1; fi
        echo "$owner $label" >> "$R"
        echo "$(now) $owner RESERVE kvm003:race $label (queue: $(awk '{print $2}' "$R" | paste -sd, -); race-claim.sh)" >> "$B"
        echo "reserve ok: $owner $label"; exit 0 ;;
      unreserve)
        grep -q "^$owner $label$" "$R" || { echo "no reservation $owner $label" >&2; exit 1; }
        grep -v "^$owner $label$" "$R" > "$R.tmp" || true; mv "$R.tmp" "$R"
        echo "$(now) $owner UNRESERVE kvm003:race $label (race-claim.sh)" >> "$B"
        echo "unreserve ok: $owner $label"; exit 0 ;;
      claim)
        if [ "$mine" -gt 0 ]; then echo "label $label already open for $owner; release it or pick a new label" >&2; exit 1; fi
        if [ -n "$head" ] && [ "$owner $label" != "$head" ] && [ "$open" -ge 1 ]; then
          echo "slot held for reserved $head (open $open; others may claim only at open 0); retry later" >&2; exit 1
        fi
        for g in $GLOBAL2_OWNERS; do [ "$owner" = "$g" ] && cap=2; done
        if [ "$open" -ge "$cap" ]; then printf 'no slot: %s open (cap %s)\n%s\n' "$open" "$cap" "$list" >&2; exit 1; fi
        echo "$(now) $owner CLAIM kvm003:race $label $* (open before: $open; race-claim.sh)" >> "$B"
        if [ "$owner $label" = "$head" ]; then
          awk -v o="$owner" -v l="$label" 'done || $1 != o || $2 != l { print; next } { done = 1 }' "$R" > "$R.tmp"; mv "$R.tmp" "$R"
        fi ;;
      release)
        if [ "$mine" -eq 0 ]; then echo "no open claim $owner $label" >&2; exit 1; fi
        echo "$(now) $owner RELEASE kvm003:race $label $*" >> "$B" ;;
    esac
    echo "$verb ok: $owner $label (open before: $open)"
    ;;
  *) sed -n '2,18p' "$0"; exit 2 ;;
esac
