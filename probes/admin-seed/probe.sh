#!/usr/bin/env bash
# Does a node joining an existing cluster take over the cluster-wide admin password?
#
# It does. This probe demonstrates it on demand. See README.md for the mechanism
# and for the result this produced against litevirt a44ee9d.
#
#   ./probe.sh baseline   # record the cluster's current admin credential
#   ./probe.sh join       # add node-5 and let its daemon seed
#   ./probe.sh verdict    # compare, and say plainly which way it went
#   ./probe.sh all        # all three
#
# Every phase appends to $EVIDENCE so a run stays reviewable afterwards rather
# than collapsing to a pass/fail line.
#
# Requires: a bootstrapped cluster on nodes 1..4 (see ../../BOOTSTRAP.md), and
# node-5 created, booted, and carrying the litevirt binary — but NOT yet joined.
# `./probe.sh prep5` does that last part.

set -uo pipefail

LAB="${LAB:-$(cd "$(dirname "$0")/../.." && pwd)}"
HERE="$(cd "$(dirname "$0")" && pwd)"
EVIDENCE="${EVIDENCE:-$HERE/evidence.txt}"
STATE="$HERE/.state"
BCHECK="$HERE/bcheck/bcheck"
DB=/var/lib/litevirt/state.db
PWFILE=/etc/litevirt/admin-password
JOINER="${JOINER:-5}"

SSH_OPTS=(-o IdentityAgent=none -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)

nssh() { local n="$1"; shift; ssh "${SSH_OPTS[@]}" -i "$LAB/cluster_key" -p "$((2230 + n))" root@127.0.0.1 "$@" 2>/dev/null; }
log()  { printf '%s\n' "$*" | tee -a "$EVIDENCE"; }
hr()   { log "----------------------------------------------------------------"; }

admin_row()  { nssh "$1" "sqlite3 -separator '|' $DB \"SELECT substr(password_hash,1,29), updated_at FROM users WHERE username='admin';\""; }
admin_hash() { nssh "$1" "sqlite3 $DB \"SELECT password_hash FROM users WHERE username='admin';\""; }
admin_pw()   { nssh "$1" "cat $PWFILE 2>/dev/null || echo '<none>'"; }

# `lv login` reads the password with term.ReadPassword, which needs a real tty.
#
# Two ways to do this are WRONG and both fail silently in the direction that
# looks like confirmation:
#   - a plain pipe dies with "inappropriate ioctl for device"
#   - `ssh -tt` echoes the piped input back into the password read, so a CORRECT
#     password fails exactly like a wrong one
# Either way every password reads as rejected, which is precisely the result this
# probe is looking for — so it would "confirm" the finding on a bug in itself.
#
# `script -qec` gives the command its own pty and actually discriminates. Do not
# swap this out without re-running `selftest`.
login_works() {
  local n="$1" pw="$2" out
  out=$(nssh "$n" "printf 'admin\n$pw\n' | script -qec 'lv login' /dev/null 2>&1 | tr -d '\r'")
  case "$out" in *"Logged in as admin"*) echo YES ;; *) echo NO ;; esac
}

# Offline cross-check against the stored hash, so a login failure caused by
# something else (daemon down, tty trouble) cannot be misread as a credential
# that was overwritten. The two must agree; verdict says so if they do not.
hash_accepts() {
  local h; h=$(admin_hash "$1")
  [ -z "$h" ] && { echo "NO-HASH"; return; }
  [ -x "$BCHECK" ] || { echo "NO-BCHECK"; return; }
  "$BCHECK" "$h" "$2" 2>/dev/null || true
}

need_bcheck() {
  [ -x "$BCHECK" ] && return 0
  echo "building bcheck..." >&2
  ( cd "$HERE/bcheck" && go build -o bcheck main.go ) || {
    echo "bcheck build failed — run it from a checkout with the litevirt module available" >&2
    return 1
  }
}

# A probe whose own instrument is broken is worse than no probe. Prove the login
# check can tell a right password from a wrong one before trusting any verdict.
phase_selftest() {
  need_bcheck || exit 1
  local pw h
  pw=$(admin_pw 1); h=$(admin_hash 1)
  echo "bcheck, wrong password:   $("$BCHECK" "$h" "definitely-not-it" || true)   (want NO)"
  echo "bcheck, stored-hash pair: $(hash_accepts 1 "$pw")   (want YES only if node-1 still owns the credential)"
  local good bad
  good=$(login_works 1 "$pw"); bad=$(login_works 1 "definitely-not-it")
  echo "login, node-1's own pw:   $good"
  echo "login, wrong password:    $bad   (want NO)"
  if [ "$bad" = "YES" ]; then
    echo "SELFTEST FAILED: a wrong password logged in. Do not trust a verdict." >&2; exit 1
  fi
  echo "selftest OK (a wrong password is rejected, so NO means something)"
}

phase_prep5() {
  local bin="${1:-$LAB/litevirt}"
  [ -f "$bin" ] || { echo "no binary at $bin — pass one: ./probe.sh prep5 /path/to/litevirt" >&2; exit 2; }
  echo "node-$JOINER must already be created and booted (NODES=5 ./lab.sh create 5 && ./lab.sh up 5)"
  scp "${SSH_OPTS[@]}" -i "$LAB/cluster_key" -P "$((2230 + JOINER))" "$bin" root@127.0.0.1:/usr/local/bin/litevirt.new
  nssh "$JOINER" "install -m 0755 /usr/local/bin/litevirt.new /usr/local/bin/litevirt && rm -f /usr/local/bin/litevirt.new
    ln -sf /usr/local/bin/litevirt /usr/local/bin/lv
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sqlite3 >/dev/null 2>&1
    echo -n 'lv=';      lv version 2>&1 | head -1
    echo -n 'sqlite3='; command -v sqlite3 >/dev/null && echo ok || echo MISSING
    echo -n 'config=';  ls /etc/litevirt/ >/dev/null 2>&1 && echo PRESENT || echo absent-good
    echo -n 'db=';      ls $DB          >/dev/null 2>&1 && echo PRESENT || echo absent-good"
}

phase_baseline() {
  need_bcheck || exit 1
  : > "$EVIDENCE"; mkdir -p "$STATE"
  log "=== BASELINE $(date -u +%FT%TZ) ==="
  hr
  log "admin row per node:"
  for n in 1 2 3 4; do log "  node-$n: $(admin_row "$n")"; done
  hr
  log "each node's own $PWFILE, and whether the CLUSTER accepts it:"
  local working=""
  for n in 1 2 3 4; do
    local p; p=$(admin_pw "$n")
    local hk lg; hk=$(hash_accepts 1 "$p"); lg=$(login_works 1 "$p")
    log "  node-$n  $p  hash=$hk  login-on-node-1=$lg"
    [ "$lg" = "YES" ] && { working="$p"; echo "$p" > "$STATE/working-password"; echo "$n" > "$STATE/working-node"; }
  done
  hr
  if [ -z "$working" ]; then
    log "NOTE: no node's own password file authenticates. That is already the"
    log "      finding — but it leaves nothing to watch change, so set the admin"
    log "      password by hand before running 'join'."
  else
    log "working cluster password is node-$(cat "$STATE/working-node")'s: $working"
  fi
  log "cluster:"; nssh 1 "lv host ls 2>&1" | tee -a "$EVIDENCE"
}

phase_join() {
  need_bcheck || exit 1
  local before; before=$(cat "$STATE/working-password" 2>/dev/null)
  [ -z "$before" ] && { echo "no baseline — run './probe.sh baseline' first" >&2; exit 2; }

  log ""; log "=== JOIN $(date -u +%FT%TZ) ==="
  log "CONTROL — node-$JOINER before it has ever run a daemon:"
  log "  $PWFILE: $(admin_pw $JOINER)"
  log "  state.db:       $(nssh $JOINER "ls $DB 2>&1 | tail -1")"
  hr
  log "-- lv host add root@10.77.0.1$JOINER --name node-$JOINER --"
  nssh 1 "lv host add root@10.77.0.1$JOINER --name node-$JOINER 2>&1 | tail -4" | tee -a "$EVIDENCE"
  hr
  log "-- starting node-$JOINER's daemon: this is when seedAdminUser runs --"
  nssh "$JOINER" "systemctl restart litevirt"
  local waited=0
  while [ $waited -lt 60 ]; do
    [ "$(nssh "$JOINER" 'systemctl is-active litevirt')" = "active" ] && break
    sleep 5; waited=$((waited + 5))
  done
  nssh "$JOINER" "journalctl -u litevirt --no-pager -o short-iso | grep -i 'seeded admin' | tail -2" | tee -a "$EVIDENCE"
  log "  node-$JOINER $PWFILE: $(admin_pw $JOINER)"
  log "  node-$JOINER admin row: $(admin_row $JOINER)"
  hr

  # Watch for the takeover rather than sleeping a guessed interval, and record
  # how long it took — "it converged" and "it converged in 47s" are different
  # claims and only one of them is evidence.
  local start; start=$(date +%s)
  local base; base=$(nssh 1 "sqlite3 $DB \"SELECT updated_at FROM users WHERE username='admin';\"")
  log "-- watching node-1's admin row (was $base) --"
  while [ $(( $(date +%s) - start )) -lt 300 ]; do
    local now; now=$(nssh 1 "sqlite3 $DB \"SELECT updated_at FROM users WHERE username='admin';\"")
    [ "$now" != "$base" ] && { log "  CHANGED after $(( $(date +%s) - start ))s -> $now"; break; }
    sleep 10
  done
}

phase_verdict() {
  need_bcheck || exit 1
  local before node_before after
  before=$(cat "$STATE/working-password" 2>/dev/null)
  node_before=$(cat "$STATE/working-node" 2>/dev/null)
  after=$(admin_pw "$JOINER")

  log ""; log "=== VERDICT $(date -u +%FT%TZ) ==="
  log "password that worked before the join (node-$node_before's): $before"
  log "node-$JOINER's own seeded password:                          $after"
  hr
  log "admin row on every node:"
  for n in 1 2 3 4 $JOINER; do log "  node-$n: $(admin_row "$n")"; done
  hr
  log "on node-1:"
  local b_login a_login
  b_login=$(login_works 1 "$before"); a_login=$(login_works 1 "$after")
  log "  the previously-working password: $b_login"
  log "  node-$JOINER's password:          $a_login"
  hr
  log "every password file vs the converged hash (login and offline bcrypt):"
  local disagree=0
  for n in 1 2 3 4 $JOINER; do
    local p hk lg; p=$(admin_pw "$n"); hk=$(hash_accepts 1 "$p"); lg=$(login_works 1 "$p")
    log "  node-$n  $p  hash=$hk  login=$lg"
    [ "$hk" = "YES" ] && [ "$lg" = "NO" ] && disagree=1
    [ "$hk" = "NO" ]  && [ "$lg" = "YES" ] && disagree=1
  done
  hr
  [ "$disagree" = "1" ] && log "WARNING: the login check and the bcrypt check disagree. Trust neither; investigate."
  if [ "$b_login" = "NO" ] && [ "$a_login" = "YES" ]; then
    log "RESULT: CONFIRMED — the joining node's seeded password replaced the cluster's."
    log "        Every other node's $PWFILE is now silently wrong."
  elif [ "$b_login" = "YES" ]; then
    log "RESULT: NOT REPRODUCED — the pre-join password still works."
    log "        Check the updated_at values above: if node-$JOINER adopted the cluster's"
    log "        row instead of publishing its own, the seed did not race replication."
  else
    log "RESULT: INCONCLUSIVE — neither password authenticates. Something else is wrong;"
    log "        run './probe.sh selftest' before reading anything into this."
  fi
  log ""; log "evidence: $EVIDENCE"
}

case "${1:-}" in
  selftest) phase_selftest ;;
  prep5)    shift; phase_prep5 "$@" ;;
  baseline) phase_baseline ;;
  join)     phase_join ;;
  verdict)  phase_verdict ;;
  all)      phase_baseline && phase_join && phase_verdict ;;
  *) echo "usage: $0 {selftest|prep5 [binary]|baseline|join|verdict|all}" >&2; exit 2 ;;
esac
