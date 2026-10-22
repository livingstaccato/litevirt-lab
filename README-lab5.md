# Lab 5 (kvm003-f3, ~/litevirt-lab5)

Built like lab 3 (README-lab3.md), with lab 5's own identity
(instances/kvm003-lab5.env, copied to lab.env):

| | lab 3 | lab 5 |
|---|---|---|
| cluster LAN | 10.79.0.11-15 | 10.81.0.11-15 |
| migration net | 10.79.1.11-15 | 10.81.1.11-15 |
| ssh | 127.0.0.1:2271-2275 | 127.0.0.1:2291-2295 |
| seed HTTP | 127.0.0.1:8079 | 127.0.0.1:8081 |
| MACs | 52:54:00:79:xx:xx | 52:54:00:81:xx:xx |
| qemu names | litevirt3-node-N | litevirt5-node-N |
| mcast (rollback only) | 230.0.{0,1}.79 | 230.0.{0,1}.81 |
| disks, images | /mnt/vmstore/litevirt-lab3 | /mnt/vmstore/litevirt-lab5 |

Same as lab 3: 5 nodes, hub mode, Ubuntu 26.04 (resolute), node-1 5 GiB and the
others 3 GiB, plain hardware (no LAB_NODE_HW, no storage or aux VMs, no witness,
no BMC). `tools/node-gaps.sh` applied (nft modules, per-lab fence key,
`migration.network`); sqlite3 installed on every node.

Differences from lab 3:

- Installed from the released tarball, not a lab build: litevirt v1.10.0-rc1
  (4b13deaf1), `litevirt-v1.10.0-rc1-linux-amd64.tar.gz` checked against
  `litevirt-v1.10.0-rc1-checksums.txt`. The extracted binary is in `rc1/` and
  copied to `./litevirt` for `lab.sh deploy`.
- Bootstrapped with the remote form only, never `--local`: from node-2,
  `lv host init root@10.81.0.11 --name node-1`, then `lv host add` for node-3..5;
  node-2 was added from node-1. `advertise_address` is set on every node.
- Operator CLI: node-2 and node-1 (both hold the cluster CA under
  /root/.config/litevirt/pki). `lv` is a symlink to /usr/local/bin/litevirt.
- `lv host init`/`add` take ssh credentials from an agent only. On a node:
  `eval $(ssh-agent -s); ssh-add /root/.ssh/id_ed25519_lvfence`.

## Start / stop

The VMs, LAN hubs and seed server run in a systemd user scope:

```bash
cd ~/litevirt-lab5 && export LAB_SSH_KEY=$PWD/cluster_key TMPDIR=/var/tmp/k/lab5
systemd-run --user --scope --unit=litevirt-lab5-up ./lab.sh up
./lab.sh status && ./lab.sh hub status
./lab.sh down          # stop the nodes; hubs keep running (./lab.sh hub down after)
```

Restart a stopped node one at a time; HA fences nodes that come back too fast.

## ssh

```bash
cd ~/litevirt-lab5 && export LAB_SSH_KEY=$PWD/cluster_key
./lssh 1 lv host ls
./lssh 1 lv health
```

## e2e (lab mode)

As lab 3, with `E2E_LAB_DIR=$HOME/litevirt-lab5 E2E_LAB_PORT_BASE=2290
E2E_LAB_PREFIX=10.81.0 E2E_LAB_MIGRATION_NET=10.81.1.0/24
E2E_LAB_SOCKET_DIR=$HOME/litevirt-lab5/ssh-cm`.
