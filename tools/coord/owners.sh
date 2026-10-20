#!/usr/bin/env bash
# owners.md: one line per open item, shared by Claude and Codex.
#   owners.sh list [owner]                      print entries (optionally one owner's)
#   owners.sh set  <owner> <item> <branch> <state...>   add or replace YOUR entry for <item>
#   owners.sh done <owner> <item>               remove YOUR entry for <item>
# A line is: <item> | <owner> | <branch> | <state> | <updated UTC>
# <item> is a short unique key (e.g. projects-I2). An owner may change only its
# own lines: set/done on an item another owner holds is refused; disagree on
# the board with NEED/WARN. Every change runs under owners.lock.
set -euo pipefail
D=${RACE_CLAIM_DIR:-$HOME/litevirt-coord}
F=$D/owners.md
LOCK=$D/owners.lock

holder() { awk -F' [|] ' -v i="$1" '$1 == i { print $2; exit }' "$F"; }

case "${1:-}" in
  list) touch "$F"; if [ -n "${2:-}" ]; then awk -F' [|] ' -v o="$2" '$2 == o' "$F"; else cat "$F"; fi ;;
  set|done)
    [ $# -ge 3 ] || { echo "usage: $0 $1 <owner> <item> ..." >&2; exit 2; }
    verb=$1 owner=$2 item=$3; shift 3
    case "$item" in *"|"*|*" "*) echo "item key must have no spaces or |" >&2; exit 2 ;; esac
    exec 9>"$LOCK"; flock 9
    touch "$F"
    h=$(holder "$item")
    if [ -n "$h" ] && [ "$h" != "$owner" ]; then echo "$item is owned by $h; raise it on the board" >&2; exit 1; fi
    awk -F' [|] ' -v i="$item" '$1 != i' "$F" > "$F.tmp"
    if [ "$verb" = set ]; then
      [ $# -ge 2 ] || { rm -f "$F.tmp"; echo "usage: $0 set <owner> <item> <branch> <state...>" >&2; exit 2; }
      branch=$1; shift
      printf '%s | %s | %s | %s | %s\n' "$item" "$owner" "$branch" "$*" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$F.tmp"
    elif [ -z "$h" ]; then rm -f "$F.tmp"; echo "no entry $item" >&2; exit 1
    fi
    sort -o "$F.tmp" "$F.tmp"; mv "$F.tmp" "$F"
    echo "$verb ok: $owner $item" ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac
