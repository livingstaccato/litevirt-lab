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
(removes node state, keeps the base image and binary).

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
