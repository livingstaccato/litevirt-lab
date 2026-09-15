# admin-seed probe

Does a node joining an existing cluster take over the cluster-wide admin
password? **Yes — on every join, deterministically.**

Upstream issue: [colonelpanik/litevirt#186][issue].

[issue]: https://github.com/colonelpanik/litevirt/issues/186

## The mechanism

`seedAdminUser` (`daemon.go:397`) runs 163 lines before `repl.Start`
(`daemon.go:560`). A joining node therefore reads an empty `users` table, mints
an `admin` row with a current `updated_at`, and writes the plaintext to its own
`/etc/litevirt/admin-password`. Replication then starts and publishes that row.

`users` is anti-entropy-repaired and its resolver entry is `policyChain()`
(`resolver.go:354`) — `[ruleTombstone(), ruleUnresolved(TieCategoryPolicy)]`.
The AE lane would refuse to pick a winner and flag the conflict. But the WAL lane
never consults it: `InsertUser` emits a plain `INSERT INTO users (...)`, whose
ledger disposition is `DispPlainInsert`, and `replicator.go:1376` routes that to
`applyLWWGated`. Newest `updated_at` wins outright, and the conflict is never
surfaced as a tie.

So the last node to start its daemon owns the cluster's admin credential, and
every other node's password file keeps showing a password that no longer works.
No error, no warning, no audit row.

## Result against litevirt `a44ee9d`

It does not need an unusual join. An ordinary four-node bootstrap, following
`BOOTSTRAP.md` exactly, ends with three dead password files:

| node | `seeded admin user` at | outcome |
|---|---|---|
| node-1 | 06:07:51 | password file dead |
| node-2 | 06:08:49 | dead |
| node-3 | 06:09:44 | dead |
| node-4 | **06:10:29** | won |

All four converged on `updated_at = 2026-09-14T06:10:29.442434893Z` — node-4's
seed. On **node-1**, node-1's own password gave
`Unauthenticated: invalid credentials` while node-4's gave
`Logged in as admin (role: admin)`.

Adding a fifth node to that converged cluster did it again, on demand. node-5
seeded at 08:11:06 and within ~47 seconds all five nodes carried its row:

| password | before node-5 joined | after |
|---|---|---|
| node-4's `8eaccb34…` | `Logged in as admin` | `Unauthenticated: invalid credentials` |
| node-5's `e906d47a…` | n/a — node-5 had no config | `Logged in as admin (role: admin)` |

One control worth keeping: an earlier attempt left node-5 registered as a host
(`HOST_OFFLINE`) with its daemon never started, and the admin row did **not**
move. Admitting a host is not what does this — the joining daemon's seed is.

## Running it

Needs a bootstrapped 4-node cluster (`../../BOOTSTRAP.md`) and node-5 created and
booted but *not* joined:

```bash
NODES=5 ../../lab.sh create 5 && ../../lab.sh up 5   # wait for cloud-init
./probe.sh prep5 /path/to/litevirt                   # binary + lv symlink + sqlite3
./probe.sh selftest                                  # prove the checks discriminate
./probe.sh all                                       # baseline, join, verdict
```

`evidence.txt` gets every phase appended to it. It and `.state/` hold **real
admin passwords in plaintext** and are gitignored — keep them that way.

## Two traps that will fake a confirmation

**`lv login` needs a real tty**, and the two obvious ways to script it both fail
in the direction that looks like the bug:

- a plain pipe dies with `inappropriate ioctl for device`
- `ssh -tt` echoes the piped input back into the password read, so a **correct**
  password fails exactly like a wrong one

Either way every password reads as rejected — which is the result the probe is
looking for, so a broken instrument "confirms" the finding. `script -qec` gives
the command its own pty and actually discriminates. `./probe.sh selftest` checks
this by logging in with a deliberately wrong password and requiring it to fail;
run it before believing any verdict, and re-run it if you touch `login_works`.

**A hash comparison alone is not the operator-visible claim.** The probe also
checks each password against the stored bcrypt hash offline (`bcheck/`), and
`verdict` warns if the two methods disagree rather than silently preferring one.

## Layout

```
probe.sh        the probe
bcheck/main.go  bcrypt compare helper; probe.sh builds it on demand
evidence.txt    generated, gitignored (contains plaintext passwords)
.state/         generated, gitignored (contains plaintext passwords)
```
