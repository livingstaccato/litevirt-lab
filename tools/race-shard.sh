#!/usr/bin/env bash
# race-shard.sh — run one Go package's tests under -race in N parallel shards.
#
# A test binary runs its package's tests one after another, so a full -race
# run of a big package (internal/grpcapi: ~3 h) uses one core. This builds the
# race binary once, lists its tests, splits them round-robin into N shards and
# runs the shards side by side.
#
# Usage (on kvm003, in a source tree):
#   race-shard.sh <ABSOLUTE source tree> <package dir, e.g. internal/grpcapi> [shards=8] [timeout per shard=90m]
#
# Output: <tree>/race-shard-<pkg>/shard-N.log, and a last line
#   RACE-SHARD <pkg> PASS tests=<n> shards=<N> secs=<s>
#   RACE-SHARD <pkg> FAIL tests=<n> ran=<m> races=<r> fails=<f> timeouts=<t> ...
# A shard that times out prints `panic: test timed out` (a budget failure); a
# real race prints `WARNING: DATA RACE`. Both count as FAIL; read the shard log.
set -uo pipefail

TREE=${1:?usage: $0 <ABSOLUTE source tree> <package dir> [shards] [timeout]}
PKG=${2:?package dir}
N=${3:-8}
TMO=${4:-90m}
[[ $TREE == /* && -d $TREE/$PKG ]] || { echo "no package $TREE/$PKG" >&2; exit 2; }
[[ $N =~ ^[0-9]+$ && $N -ge 1 ]] || { echo "shards must be a positive number" >&2; exit 2; }

export PATH=$HOME/sdk/go1.26.0/bin:$PATH
OUT=$TREE/race-shard-${PKG//\//-}
rm -rf "$OUT" && mkdir -p "$OUT"
BIN=$OUT/pkg.race.test
start=$(date +%s)

cd "$TREE" || exit 2
# NORACE=1 builds without the race detector (for sharding a slow plain suite
# such as tests/fleet); the verdict lines still say RACE-SHARD.
RACEFLAG=-race
[[ ${NORACE:-0} == 1 ]] && RACEFLAG=
go test $RACEFLAG -c -o "$BIN" "./$PKG" >"$OUT/build.log" 2>&1 || { cat "$OUT/build.log"; echo "RACE-SHARD $PKG FAIL build"; exit 1; }

# Top-level tests, examples and fuzz targets (fuzz seeds run as tests).
cd "$TREE/$PKG" || exit 2
"$BIN" -test.list '.*' 2>/dev/null | grep -E '^(Test|Example|Fuzz)[A-Za-z0-9_]*$' | sort >"$OUT/tests.txt"
total=$(wc -l <"$OUT/tests.txt")
[[ $total -gt 0 ]] || { echo "RACE-SHARD $PKG FAIL no tests listed"; exit 1; }

# With SHARD_DURATIONS (lines "<seconds> <TestName>", e.g. from a previous
# run's durations.txt), deal the slowest tests first, each to the least-loaded
# shard; a test with no recorded time counts 1s. Without it, round-robin.
if [[ -n ${SHARD_DURATIONS:-} && -s $SHARD_DURATIONS ]]; then
  awk -v n="$N" -v out="$OUT" '
    NR == FNR { d[$2] = $1; next }
    { t = ($1 in d) ? d[$1] : 1; print t, $1 }
  ' "$SHARD_DURATIONS" "$OUT/tests.txt" | sort -rn | awk -v n="$N" -v out="$OUT" '
    BEGIN { for (i = 0; i < n; i++) load[i] = 0 }
    { m = 0; for (i = 1; i < n; i++) if (load[i] < load[m]) m = i
      load[m] += $1; print $2 > (out "/shard-" m ".txt") }
  '
else
  for ((i = 0; i < N; i++)); do
    awk -v n="$N" -v i="$i" 'NR % n == i' "$OUT/tests.txt" >"$OUT/shard-$i.txt"
  done
fi

pids=()
for ((i = 0; i < N; i++)); do
  [[ -s $OUT/shard-$i.txt ]] || continue
  re="^($(paste -sd'|' "$OUT/shard-$i.txt"))\$"
  # Run from the package dir, as go test does, so testdata paths resolve.
  ( "$BIN" -test.v -test.count=1 -test.timeout "$TMO" -test.run "$re" >"$OUT/shard-$i.log" 2>&1
    echo "SHARD-RC=$?" >>"$OUT/shard-$i.log" ) &
  pids+=($!)
done
wait "${pids[@]}"

ran=$(cat "$OUT"/shard-*.log | grep -cE '^=== RUN   [A-Za-z0-9_]+$')
races=$(cat "$OUT"/shard-*.log | grep -c 'WARNING: DATA RACE')
fails=$(cat "$OUT"/shard-*.log | grep -cE '^--- FAIL: ')
tmo=$(cat "$OUT"/shard-*.log | grep -c 'panic: test timed out')
badrc=$(grep -L '^SHARD-RC=0$' "$OUT"/shard-*.log | wc -l)
secs=$(( $(date +%s) - start ))

# Per-test times for the next run's SHARD_DURATIONS.
cat "$OUT"/shard-*.log | grep -E '^--- (PASS|FAIL|SKIP): (Test|Example|Fuzz)[A-Za-z0-9_]+ \(' |
  sed -E 's/^--- [A-Z]+: ([A-Za-z0-9_]+) \(([0-9.]+)s\)/\2 \1/' | sort -rn >"$OUT/durations.txt"

# Examples print no "=== RUN" line under -v when they have no output check, so
# compare against tests only.
want=$(grep -c '^Test' "$OUT/tests.txt")
if [[ $races -eq 0 && $fails -eq 0 && $tmo -eq 0 && $badrc -eq 0 && $ran -ge $want ]]; then
  echo "RACE-SHARD $PKG PASS tests=$total shards=$N secs=$secs"
  exit 0
fi
grep -h -E '^--- FAIL: ' "$OUT"/shard-*.log | head -40
grep -l -E 'WARNING: DATA RACE|panic: test timed out' "$OUT"/shard-*.log | sed 's/^/race-or-timeout in: /'
echo "RACE-SHARD $PKG FAIL tests=$total ran=$ran want>=$want races=$races fails=$fails timeouts=$tmo badrc=$badrc secs=$secs (logs: $OUT)"
exit 1
