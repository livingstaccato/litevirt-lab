#!/usr/bin/env bash
# Run a build/test command on kvm003-f3 against a worktree's CURRENT files
# (committed, staged, unstaged and untracked-not-ignored), never on the laptop.
#   kbuild.sh <worktree> '<command>'
# The remote copy is a fresh `git init` with every file added, so ci-guards
# (tracked files only) sees all files present in the worktree. Exit status is
# the command's. Output is also kept in ~/kb-<name>.log on kvm003.
set -euo pipefail
WT=$1; CMD=$2
case "$WT" in /*) ;; *) echo "kbuild.sh: worktree path must be absolute" >&2; exit 2 ;; esac
NAME=$(basename "$WT")
SSH="timeout 3600 ssh -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=4 kvm003-f3"
cd "$WT"
git ls-files -co --exclude-standard -z | tar --null -T - -cf - 2>/dev/null \
  | $SSH "rm -rf ~/kb-$NAME && mkdir -p ~/kb-$NAME && tar -x -C ~/kb-$NAME"
$SSH "c=\$(du -sm ~/.cache/go-build 2>/dev/null | cut -f1); [ \"\${c:-0}\" -gt 30720 ] && find ~/.cache/go-build -type f -mmin +120 -delete 2>/dev/null; cd ~/kb-$NAME && export PATH=\$HOME/sdk/go1.26.0/bin:\$HOME/go/bin:\$PATH && \
  git init -q && git add -A >/dev/null 2>&1 && git -c user.name=kb -c user.email=kb@localhost commit -qm snapshot --no-gpg-sign >/dev/null 2>&1; \
  ( $CMD ) > ~/kb-$NAME.log 2>&1; rc=\$?; tail -60 ~/kb-$NAME.log; echo \"[kbuild rc=\$rc log=~/kb-$NAME.log]\"; exit \$rc"
