#!/usr/bin/env bash
# Run a litevirt git ref's tests on kvm003-f3 (128 cores), off the laptop.
#   race-sweep.sh [ref]            full -race sweep (default ref: main)
#   SUITE=1 race-sweep.sh [ref]    full suite without -race (~4 min)
#   RUN='TestX|TestY' PKGS='./internal/corrosion/ ./tests/fleet/' race-sweep.sh ref
# The ref must be COMMITTED: the tree is sent with `git archive`, so uncommitted
# work is not tested. Exit status is the test run's.
set -euo pipefail
REF=${1:-main}
REPO=${REPO:-$HOME/code/github/livingstaccato/litevirt}
SHA=$(git -C "$REPO" rev-parse --short=8 "$REF")
PKGS=${PKGS:-./...}
if [ -n "${SUITE:-}" ]; then MODE=suite; FLAGS="-p 16 -timeout 30m"; else MODE=race; FLAGS="-race -p 16 -timeout 90m"; fi
[ -n "${RUN:-}" ] && FLAGS="$FLAGS -run '$RUN'"
TAG=$MODE-$SHA-$$
echo "$MODE of $REF ($SHA) on kvm003-f3: go test $FLAGS $PKGS"
git -C "$REPO" archive --format=tar "$SHA" | ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=4 kvm003-f3 "rm -rf ~/src-$TAG && mkdir -p ~/src-$TAG && tar -x -C ~/src-$TAG"
ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=4 kvm003-f3 "cd ~/src-$TAG && export PATH=\$HOME/sdk/go1.26.0/bin:\$PATH && \
  start=\$(date +%s); go test -count=1 $FLAGS $PKGS > ~/$TAG.log 2>&1; rc=\$?; \
  echo \"rc=\$rc seconds=\$((\$(date +%s)-start)) ok=\$(grep -c '^ok' ~/$TAG.log) races=\$(grep -c 'WARNING: DATA RACE' ~/$TAG.log) timeouts=\$(grep -c 'panic: test timed out' ~/$TAG.log) log=~/$TAG.log\"; \
  grep -E '^(FAIL|--- FAIL|panic:)' ~/$TAG.log | head -20; rm -rf ~/src-$TAG; exit \$rc"
