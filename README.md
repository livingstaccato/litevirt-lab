# litevirt-lab

A 4-node nested-virtualization test cluster for
[litevirt](https://github.com/livingstaccato/litevirt), on plain qemu — no
libvirt and no root on the host. Each node boots an Ubuntu cloud image with
`-cpu host`, so KVM works *inside* the node and litevirt can run real guest VMs.

This is the live environment behind the repo's `tests/e2e/` tier; the fleet
tests (`tests/fleet/`) don't need it.

## Host requirements

- `qemu-system-x86_64` and `qemu-img`, with nested virt enabled on the host
- `python3` (cloud-init seed is served with `http.server` — no ISO tooling needed)
- `curl`, `ssh`

## Quickstart

```bash
./lab.sh image      # fetch the Ubuntu noble cloud image (once)
./lab.sh create     # write per-node seed data + qcow2 overlays
./lab.sh up         # boot all nodes (starts the seed HTTP server)
./lab.sh status     # per-node pid / IP / ssh port / cloud-init state
```

First boot installs qemu, libvirt, dnsmasq, nftables etc. via cloud-init —
give it a few minutes, then bootstrap the litevirt cluster per
[BOOTSTRAP.md](BOOTSTRAP.md).

Other verbs: `ssh <n> [cmd]`, `deploy [binary]` (installs to every node,
**never restarts** — HA fences simultaneous restarts), `down`, `destroy`
(removes node state, keeps the base image and binary). With no node numbers,
`destroy` stops and removes every `nodes/node-N` present — strays beyond
`NODES` too — but keeps `nodes/` itself, so a `nodes` symlink to another volume
survives and the next `create` writes there again.

`create` / `up` / `down` / `destroy` take explicit node numbers; with none
they act on all of `1..NODES`. So a kill/revive/replace loop is:

```bash
./lab.sh down 3            # crash just node-3 (seed server stays up)
./lab.sh up 3              # revive it, disk intact
./lab.sh destroy 3         # or scrap it entirely...
./lab.sh create 3 && ./lab.sh up 3   # ...and rebuild it fresh
NODES=5 ./lab.sh create 5 && ./lab.sh up 5   # grow the cluster
```

`status` also lists leftover node dirs beyond `NODES`, so strays stay
visible. Removing a *joined* node still needs the cluster-side drain/remove
first — `lab.sh` only manages the VMs.

## How it works

- **Two NICs per node.** `net0` is user-mode NAT with an ssh hostfwd
  (`127.0.0.1:2230+N`); `net1` is a qemu multicast socket forming the
  `10.77.0.0/24` cluster LAN (node N is `10.77.0.10+N`).
- **cloud-init over HTTP, not a seed disk.** The SMBIOS DMI serial carries
  `ds=nocloud-net;s=http://10.0.2.2:PORT/node-N/`. A VVFAT seed disk silently
  fails: the synthesized FAT volume has no `CIDATA` blkid label, so
  `ds-identify` disables cloud-init with no error.
- **The cluster NIC is configured via a netplan file in user-data**, not
  cloud-init `network-config` — the HTTP NoCloud datasource never fetches
  `network-config`, so serving one is silently ignored.

## Knobs (env vars)

| Var | Default | |
|---|---|---|
| `NODES` | `4` | node count |
| `VCPUS` / `MEM` / `DISK` | `4` / `3072` / `40G` | per-node sizing |
| `SEEDPORT` | `8077` | cloud-init HTTP seed port |
| `SSH_KEY` | `~/.ssh/id_ed25519.pub` | pubkey authorized on every node at `create` |
| `SSH_PRIV` | `./cluster_key` | key `lab.sh ssh` / `deploy` use |
| `LAB_SSH_KEY` | `~/.ssh/id_ed25519` | key `lssh` / `lscp` use |
| `IMG_URL` | Ubuntu noble current | base cloud image |

`./lab.sh info` prints the instance's identity (below) and everything it
occupies on the host.

## A second lab on the same host

What a running lab occupies on the host — ssh hostfwd ports, the multicast
cluster LAN, the seed HTTP port — plus its cluster subnet, MACs and qemu process
names is the lab's *identity*. It comes from an optional `lab.env` beside
`lab.sh`, and only from there: `lab.sh`, `lssh` and `lscp` clear the `LAB_*`
names before reading it, so a value exported for one lab cannot leak into
another lab's scripts. Without a `lab.env` every value is the original lab's,
and `lab.sh` behaves exactly as before.

| `lab.env` var | lab 1 default | |
|---|---|---|
| `LAB_NODES` | `4` | node count (`$NODES` still wins) |
| `LAB_SEEDPORT` | `8077` | seed HTTP port (beats `$SEEDPORT`) |
| `LAB_MCAST` | `230.0.0.77:11877` | cluster LAN. **Never share it**: two labs on one group:port silently become one L2 segment |
| `LAB_SSH_PORT_BASE` | `2230` | node N's ssh is `127.0.0.1:(base+N)` |
| `LAB_LAN_PREFIX` | `10.77.0` | node N is `<prefix>.(10+N)` |
| `LAB_MAC_PREFIX` | `52:54:00:77` | NICs are `<prefix>:00:N` (NAT) and `<prefix>:01:N` (LAN) |
| `LAB_QEMU_NAME` | `litevirt-node` | qemu `-name <name>-N` |
| `LAB_STORAGE_PREFIX` | `lab` | storage VMs are `<prefix>-nfs` / `<prefix>-ceph` (see Shared storage) |
| `LAB_STORAGE_SSH_PORT_BASE` | `2250` | nfs is `127.0.0.1:(base+1)`, ceph `(base+2)` |
| `LAB_STORAGE_NFS_IP` / `LAB_STORAGE_CEPH_IP` | `<prefix>.21` / `.22` | the storage VMs on the cluster LAN |

Each lab is its own directory, with its own `cluster_key`, `nodes/`, `images/`
and seed server. On kvm003-f3, lab 2 is `~/litevirt-lab2` with
`instances/kvm003-lab2.env` copied to `lab.env`:

```bash
git clone <this repo> ~/litevirt-lab2 && cd ~/litevirt-lab2
cp instances/kvm003-lab2.env lab.env
./lab.sh info                       # check every value against the other lab first
ssh-keygen -q -t ed25519 -N '' -f cluster_key -C litevirt-lab2
SSH_KEY=$PWD/cluster_key.pub ./lab.sh create && ./lab.sh up
LAB_SSH_KEY=$PWD/cluster_key ./lssh 1 hostname
```

The e2e drills find a lab by directory and port base, so pointing them at
lab 2 is `E2E_LAB_DIR=~/litevirt-lab2 E2E_LAB_PORT_BASE=2240`.

## Shared storage (lab 2)

Two non-litevirt VMs give a lab shared storage for NFS, iSCSI and Ceph pools
and for fence drills. They are plain qemu like the nodes (`-cpu host`, the
cluster LAN as the same multicast socket, cloud-init over the same HTTP seed),
sit on the instance's LAN at a static IP from `lab.env`, and never join the
litevirt cluster.

| VM | Sizing | Disks | LAN IP | ssh |
|---|---|---|---|---|
| `lab2-nfs` | 1 vCPU, 2 GB | 10G OS, 100G `lvnfsdata`, 50G `lviscsi` | `LAB_STORAGE_NFS_IP` (10.78.0.21) | 127.0.0.1:2251 |
| `lab2-ceph` | 4 vCPU, 8 GB | 20G OS, 3 x 50G `lvceph0..2` | `LAB_STORAGE_CEPH_IP` (10.78.0.22) | 127.0.0.1:2252 |

Data disks carry a virtio serial, so guests find them at
`/dev/disk/by-id/virtio-<serial>`. Disk files live in `storage/<name>/` (put a
symlink to `/mnt/vmstore` there first, as for `nodes/`, and mind the lab 1 / lab
2 split on that volume). The `lab.env` additions are in
`instances/kvm003-lab2.env` (`LAB_STORAGE_*`).

### Order of operations: clean lab 2 to three healthy pools

All of it runs on kvm003-f3, in `~/litevirt-lab2`, with
`export LAB_SSH_KEY=$PWD/cluster_key`. Every script ends in `PASS:` or `FAIL:`
and is safe to re-run.

```bash
# 0. the 5 litevirt nodes are up and the cluster formed (BOOTSTRAP.md), 5 hosts
#    in `litevirt host ls`. The storage steps need only the VMs, but step 5 needs the cluster.

# 1. the storage VMs
mkdir -p /mnt/vmstore/litevirt-lab2-storage && ln -s /mnt/vmstore/litevirt-lab2-storage storage   # once, like nodes/
./lab.sh image                      # no-op if the base image is there
./lab.sh storage up                 # creates (first time) and boots lab2-nfs, lab2-ceph
./lab.sh storage status             # wait for CLOUDINIT "status: done" on both

# 2. services on the VMs
tools/nfs-server.sh                 # nfs-kernel-server, /srv/lv exported to 10.78.0.0/24
tools/iscsi-target.sh               # LIO target on the 50G disk; writes secrets/iscsi-chap
tools/ceph.sh                       # cephadm, 3 OSDs, pool lv; writes secrets/ceph.client.litevirt.keyring

# 3. clients on the 5 litevirt nodes
tools/node-clients.sh               # nfs-common, open-iscsi (unique IQN, CHAP), ceph-common

# 4. the litevirt pools, on every node
tools/litevirt-pools.sh             # nfs, iscsi, ceph  x  node-1..5

# 5. confirm
./lssh 1 litevirt pool ls           # 15 rows (3 pools x 5 hosts), all active
```

`iscsi-target.sh`, `ceph.sh` and `nfs-server.sh` are independent of each other
(any order, or in parallel); `node-clients.sh` needs all three done, because it
checks against them (`CLIENTS="nfs iscsi"` skips ceph); `litevirt-pools.sh` needs
`node-clients.sh` and a cluster whose CLI works as admin on node-1 (the
"session revoked" trap: move `/root/.config/litevirt/credentials.json` aside on
node-1 so the CLI falls back to mTLS-as-admin).
`ceph.sh` pulls a container image from quay.io through the VM's NAT NIC and takes
5-10 minutes.

Secrets: everything sensitive is under `secrets/` (0700, gitignored): the iSCSI
CHAP credentials (`iscsi-chap`, 0600, generated on first run, never echoed) and
the restricted Ceph key `ceph.client.litevirt.keyring` (0600, caps
`mon 'profile rbd'`, `osd 'profile rbd pool=lv'`). The Ceph admin keyring never
leaves `lab2-ceph`. Nodes get `ceph.conf` and the restricted keyring only.

Ceph on one host: `tools/ceph.sh` puts pool `lv` on CRUSH rule `lv_osd`, whose
failure domain is **osd**, not host, so the three OSDs on the single `lab2-ceph`
VM hold all 3 replicas (size 3, min_size 2). It tolerates the loss of one disk,
not of the VM: this is a lab cluster, not a model of a production layout. The
bootstrap pins the container image to the VM's own `ceph --version`, because a
newer squid image mints keys the distro 19.2.3 client cannot parse.

Pool details worth knowing: litevirt pools are per host, so each pool is created
once per node with `--host node-N`; the iSCSI portal is given as `ip:3260` (the
driver builds the by-path name from it verbatim); an iSCSI pool hands every disk
the same LUN, so use one VM disk per LUN. Pool creation runs the driver's
`Prepare()` on the node, so a client misconfiguration fails at step 4.

### Fault hooks for fence drills

```bash
tools/storage-fault.sh lab2-nfs stop      # power-cut the storage VM (kills qemu)
tools/storage-fault.sh lab2-nfs start     # boot it again, disks intact
tools/storage-fault.sh cut 3              # node-3 loses every storage IP (nft, output drop)
tools/storage-fault.sh cut 3 ceph         # ...or just one storage VM
BOTH=1 tools/storage-fault.sh cut 3       # also drop the replies
tools/storage-fault.sh heal 3             # remove the drop rules
```

`cut` adds one nft table, `inet lv_storage_fault`, to that node and touches
nothing else; the node's ssh runs on the NAT NIC, so the cut never locks you out.
A `cut` left in place survives until `heal` (or a node reboot).

### Teardown

`./lab.sh storage down` powers the VMs off (disks kept); `./lab.sh storage destroy`
removes their disks. Pools are removed with `litevirt pool delete <name> --host node-N`.

## SSH and the 1Password agent trap

All ssh here forces `-o IdentityAgent=none -o IdentitiesOnly=yes`. Without it,
a locked 1Password agent makes every connection fail with "agent refused
operation" — which reads exactly like the nodes having died.

`cluster_key` is the lab's own throwaway keypair (gitignored, never commit
it). `create` generates it if absent and authorizes it on every node
alongside `$SSH_KEY`, so `lab.sh ssh` / `deploy` work with the agent locked.

## Layout

Everything except the scripts and docs is runtime state and gitignored:
`images/` (base image), `nodes/` (overlays, pids, console logs), `seed-http/`
(generated cloud-init data), `litevirt` (the binary under test).

## Running litevirt's e2e suite against this lab

```bash
export LITEVIRT_E2E=1
export LV_BIN=$PWD/litevirt   # the binary under test
go test ./tests/e2e/...       # from the litevirt repo
```

## Running litevirt's tests on kvm003-f3

`race-sweep.sh` runs a litevirt ref's tests on kvm003-f3 (128 cores) instead
of the laptop. It sends the committed tree with `git archive`, so commit first.

```bash
./race-sweep.sh main                  # full -race sweep, ~65 min (grpcapi is the long pole)
SUITE=1 ./race-sweep.sh main          # full suite without -race, ~4 min
RUN='TestX' PKGS='./tests/fleet/' ./race-sweep.sh <ref>
REPO=<worktree> ./race-sweep.sh <sha> # a ref from another worktree
```

It prints one summary line (`rc= ok= races= timeouts= log=`) and keeps the
full log on kvm003. Go lives in `~/sdk/go1.26.0` there. The ssh calls use
keepalives, so a dropped connection fails the run instead of hanging on it.
