# Lab 3 (kvm003-f3, ~/litevirt-lab3)

5 nodes, 10.79.0.11-15 (migration net 10.79.1.11-15), ssh 127.0.0.1:2271-2275,
hub mode, nodes on /mnt/vmstore/litevirt-lab3. Identity: instances/kvm003-lab3.env.
node-3 fences over ssh, the others best-effort. Operator CLI: node-1 (and node-5).

## Boot / stop

```bash
cd ~/litevirt-lab3 && export LAB_SSH_KEY=$PWD/cluster_key
./lab.sh up && ./lab.sh status && ./lab.sh hub status
./lssh 1 lv host ls
```

## Build and deploy a litevirt ref

```bash
# laptop
git -C ~/code/github/livingstaccato/litevirt archive <sha> | ssh kvm003-f3 'mkdir -p ~/lab-build-<sha>-l3 && tar -x -C ~/lab-build-<sha>-l3'
# kvm003
cd ~/lab-build-<sha>-l3 && export PATH=/usr/local/go/bin:$PATH
make vendor-js && make build-litevirt VERSION=int-<sha> COMMIT=<sha>
CGO_ENABLED=0 go test -c -tags e2e -o bin/e2e.test ./tests/e2e/
cp bin/litevirt ~/litevirt-lab3/litevirt && cp bin/e2e.test ~/litevirt-lab3/e2e-<sha>.test
cd ~/litevirt-lab3 && export LAB_SSH_KEY=$PWD/cluster_key
./lab.sh deploy                      # installs on every node, no restart
tools/node-gaps.sh roll              # rolling restart, node-5 first, 15 s apart
./lssh 1 'lv host ls; lv cluster upgrade-status | head -3'
```

## e2e (local mode, on node-1)

```bash
cd ~/litevirt-lab3 && export LAB_SSH_KEY=$PWD/cluster_key
./lssh 1 'cat > /root/e2e.test && chmod +x /root/e2e.test' < e2e-<sha>.test
./lssh 1 'cd /root && LITEVIRT_E2E=1 LV_BIN=/usr/local/bin/litevirt E2E_HOSTS=node-1,node-2,node-3,node-4,node-5 \
  ./e2e.test -test.v -test.timeout 240m -test.run "^(TestSetup|TestCluster_Health)$"' > runs/e2e-<sha>.log 2>&1
```

Keep `TestSetup` in any `-test.run` selection: tests such as `TestCluster_Health`
read the host list it discovers.

## e2e (lab mode, drills, on kvm003)

Needs an e2e.test built from a ref with `E2E_LAB_PREFIX` (litevirt 5e6fbfad,
in 9537a720 and later); older binaries hard-code 10.77.0.x.

```bash
cd ~/litevirt-lab3 && export LAB_SSH_KEY=$PWD/cluster_key
env LITEVIRT_E2E=1 LV_BIN=/usr/local/bin/litevirt E2E_LAB_DIR=$HOME/litevirt-lab3 E2E_LAB_NODES=5 \
  E2E_LAB_PORT_BASE=2270 E2E_LAB_PREFIX=10.79.0 E2E_LAB_MIGRATION_NET=10.79.1.0/24 \
  E2E_DRILL_MEMORY=256M E2E_LAB_SOCKET_DIR=$HOME/litevirt-lab3/ssh-cm \
  ./e2e-<sha>.test -test.v -test.timeout 30m -test.run '^TestDrill2_FrozenLeaseHolderWhileAHostFails$'
```

No witness and no BMC: witness drills (W*) skip, and node-3 (ssh fence) is
never picked as a power-off victim. sqlite3 is installed on every node for
read-only state queries (`sqlite3 -readonly /var/lib/litevirt/state.db`).
