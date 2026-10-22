# Lab 4 (kvm003-f3, ~/litevirt-lab4)

Built 2026-10-22 the way lab 3 was (README-lab3.md): a separate clone of this
repo, `instances/kvm003-lab4.env` copied to `lab.env`, hub mode, 5 nodes on
Ubuntu 26.04 (resolute), node-1 5 GiB and the others 3 GiB, plain hardware (no
storage VMs, no emulated PCI, no witness, no BMC). Only the identity differs
from lab 3:

| | lab 3 | lab 4 |
|---|---|---|
| cluster LAN | 10.79.0.11-15 | 10.80.0.11-15 |
| migration net | 10.79.1.11-15 | 10.80.1.11-15 |
| ssh (127.0.0.1) | 2271-2275 | 2281-2285 |
| seed HTTP | 8079 | 8080 |
| MACs | 52:54:00:79:* | 52:54:00:80:* |
| qemu -name | litevirt3-node-N | litevirt4-node-N |
| mcast (rollback only) | 230.0.{0,1}.79 | 230.0.{0,1}.80 |
| hubs | ~/litevirt-lab3/hub | ~/litevirt-lab4/hub |
| disks | /mnt/vmstore/litevirt-lab3 | /mnt/vmstore/litevirt-lab4 |

Bootstrapped with the remote form only, from node-1 with the operator binary at
`/root/rc1/litevirt` (a copy, so pushing to `/usr/local/bin/litevirt` is not a
same-file copy and node-1 can init itself remotely):

```bash
lv host init root@10.80.0.11 --name node-1     # on node-1, via /root/rc1/litevirt
lv host add  root@10.80.0.1N --name node-N     # N = 2..5, ~20 s apart
tools/node-gaps.sh && tools/node-gaps.sh roll  # fence key, nft modules, migration.network
```

init/add write `advertise_address` (10.80.0.1N) and `join_peers` themselves.
Operator CLI: node-1 (`/root/.config/litevirt`).

Do not populate node-1's `/root/.ssh/known_hosts` with OpenSSH
(`StrictHostKeyChecking=accept-new`): `lv` keeps its own pinned entries there and
refuses an OpenSSH-recorded ed25519 key as a CHANGED host key. Reach nodes from
kvm003 with `./lssh N`.

## Boot / stop

Lab processes run in a user scope:

```bash
cd ~/litevirt-lab4 && export LAB_SSH_KEY=$PWD/cluster_key
systemd-run --user --scope ./lab.sh up && ./lab.sh status && ./lab.sh hub status
./lssh 1 lv host ls
./lab.sh down                   # power-cut every node, stop the seed server
```

Deploying another build, e2e and drills work as in README-lab3.md with lab 4's
values: `E2E_LAB_DIR=$HOME/litevirt-lab4 E2E_LAB_PORT_BASE=2280
E2E_LAB_PREFIX=10.80.0 E2E_LAB_MIGRATION_NET=10.80.1.0/24
E2E_LAB_SOCKET_DIR=$HOME/litevirt-lab4/ssh-cm`.
