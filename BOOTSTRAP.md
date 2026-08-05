# Bootstrapping the 4-node lab cluster

`lab.sh` only manages VMs (`destroy` / `create` / `up`). The cluster bootstrap is
below. Verified end to end against the fixed binary: the cluster forms with no
hand-seeding of host rows and no editing of join_peers.

    cd ~/litevirt-lab && ./lab.sh destroy && ./lab.sh create && ./lab.sh up

## SSH

`create` authorises both `$SSH_KEY` (default `~/.ssh/id_ed25519.pub`) and the
lab's own `cluster_key` (generated on the spot if absent), so `./lab.sh ssh`
works agent-free from the first boot.

Add `-o IdentityAgent=none -o IdentitiesOnly=yes` to every ssh/scp. Without it a
failing 1Password agent makes connections hang or fail on "Permission denied",
which looks like a broken VM.

## The sequence

Verified end to end: no host-row seeding, no config editing, no advertise_address
step. `init` and `add` write the address they already resolved into the config, so
every node registers correctly on its first start.

1. `netplan apply` on any node with no `10.77.0.x` address — the cluster NIC
   sometimes loses a first-boot race.

2. Deploy the binary to all four, and an ssh key on node-1 (the operator),
   authorised on all four.

3. node-1 — **`--address` is required for a multi-node cluster.** Without it the
   certificate covers 127.0.0.1 only and no peer can complete a handshake:

       lv host init --local --name node-1 --address 10.77.0.11
       systemctl restart litevirt

4. From node-1, add the others. Each gets its own advertise_address and a correct
   join_peers automatically:

       lv host add root@10.77.0.1X --name node-X
       # then on each: systemctl restart litevirt

5. Audit signing, appended to every config, then restart spaced ~13s:

       enforcement:
           audit_signature: true

   Adoption is deferred ~45s after the replicator starts; allow a minute.

## Traps

- **HA fences nodes that restart too quickly** — it powers them off over SSH.
  Space restarts, and expect to run `./lab.sh up` and `lv host undrain node-X`.
  `systemctl reset-failed litevirt` clears "Start request repeated too quickly".
- **A stale `/root/.config/litevirt/pki` on a non-operator node** makes its `lv`
  fail with "certificate signed by unknown authority" after the CA is regenerated.
  Delete it; the CLI then uses `/etc/litevirt/pki`.
- **A node cannot `host init` itself remotely** — the binary push is a same-file
  copy and exits 1. Use `--local --address`.

## Breaking the audit key on purpose

`chmod 000` does NOT work — the daemon runs as root and reads it anyway. Corrupt
the file contents instead.

Corrupt `audit-signing.key`, never `host.key`: on a fresh cluster
`dedicated_key=false`, so `host.key` is also the peer mTLS key and destroying it
kills replication cluster-wide. Run `lv host rotate-audit-key node-X --ssh
root@10.77.0.1X` first to give the node a dedicated audit key, then corrupt that.

`rotate-audit-key` needs `--ssh root@<ip>`; the lab has no DNS for node names.
