#!/usr/bin/env bash
# bmc.sh — simulated out-of-band management for the lab's nodes. Run on the lab
# host, from the lab dir, with LAB_AUX_ROLES containing "bmc" in lab.env.
#
#   bmc.sh secrets           secrets/bmc/: agent token, IPMI and Redfish
#                            credentials (generated once, 0600, never printed)
#   bmc.sh agent start|stop|status
#                            the host-side power agent (tools/bmc-agent.py) on
#                            127.0.0.1:LAB_BMC_AGENT_PORT; the only thing that
#                            touches a node's qemu (lab.sh up/down, QMP)
#   bmc.sh provision         the `bmc` aux VM: an ipmi_sim (OpenIPMI lanserv) per
#                            node on <lan>.(LAB_BMC_IPMI_BASE+N):623, lanplus, and a
#                            sushy-tools Redfish service on https://LAB_BMC_IP:8000
#                            with one ComputerSystem per node (`node-N`)
#   bmc.sh nodes [n...]      on the nodes: ipmitool, /etc/lab-bmc/ipmi.env (0600) and
#                            /usr/local/sbin/lab-host-power (E2E_HOST_DOWN/UP_CMD)
#   bmc.sh check             read-only: power status of every node through IPMI and
#                            Redfish, from node-1 (or CHECK_VIA=n)
#
# Both simulators call the agent at 10.0.2.2:LAB_BMC_AGENT_PORT with the token;
# the agent refuses any node outside LAB_BMC_NODES. Ends with PASS/FAIL.
set -euo pipefail
# shellcheck source=storage-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/storage-lib.sh"

[[ " ${LAB_AUX_ROLES:-} " == *" bmc "* ]] || die "bmc is not in LAB_AUX_ROLES (lab.env)"
AGENT_PORT="${LAB_BMC_AGENT_PORT:?LAB_BMC_AGENT_PORT unset in lab.env}"
BMC_IP="${LAB_BMC_IP:-$LAN_PREFIX.40}"
IPMI_BASE="${LAB_BMC_IPMI_BASE:-40}"
BMC_NODES="${LAB_BMC_NODES:-$(seq -s ' ' 1 "$NODES")}"
BMC_DIR="$SECRETS/bmc"
TOKEN="$BMC_DIR/agent-token"
IPMI_ENV="$BMC_DIR/ipmi.env"          # IPMI_USER= IPMI_PASS=
REDFISH_ENV="$BMC_DIR/redfish.env"    # REDFISH_USER= REDFISH_PASS=
AGENT_PIDF="$LAB/bmc-agent.pid"
AGENT_LOG="$LAB/bmc-agent.log"
bmc_ip() { echo "$LAN_PREFIX.$((IPMI_BASE + $1))"; }
bmcssh() { SSH_TIMEOUT="${SSH_TIMEOUT:-900}" "$LAB/lab.sh" aux ssh bmc "$@"; }

secrets() {
  secrets_dir; mkdir -p "$BMC_DIR"; chmod 0700 "$BMC_DIR"
  ( umask 077
    [[ -s "$TOKEN" ]] || openssl rand -hex 32 > "$TOKEN"
    # 16 characters at most: ipmi_sim keeps IPMI 1.5-sized user passwords, and
    # a longer one silently fails every lanplus login (RAKP 2 HMAC invalid).
    [[ -s "$IPMI_ENV" ]] || printf 'IPMI_USER=labadmin\nIPMI_PASS=%s\n' "$(openssl rand -base64 48 | tr -dc A-Za-z0-9 | head -c 16)" > "$IPMI_ENV"
    [[ -s "$REDFISH_ENV" ]] || printf 'REDFISH_USER=labadmin\nREDFISH_PASS=%s\n' "$(openssl rand -hex 12)" > "$REDFISH_ENV" )
  echo "secrets in $BMC_DIR (agent-token, ipmi.env, redfish.env)"
}

# agent_pid — the running agent's pid, only if that process is THIS lab's agent
# (its argv names this lab's agent script and port), like lab.sh's qemu_pid.
agent_pid() {
  [[ -f "$AGENT_PIDF" ]] || return 1
  local pid; pid="$(cat "$AGENT_PIDF")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  local argv; argv="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" || return 1
  [[ "$argv" == *"$LAB/tools/bmc-agent.py"* && "$argv" == *"--port $AGENT_PORT "* ]] || return 1
  echo "$pid"
}

agent() {
  case "${1:-status}" in
    start)
      need_file "$TOKEN" "run: tools/bmc.sh secrets"
      if p="$(agent_pid)"; then echo "agent running (pid $p) on 127.0.0.1:$AGENT_PORT"; return; fi
      ( cd "$LAB" && exec nohup python3 -I "$LAB/tools/bmc-agent.py" --lab "$LAB" --port "$AGENT_PORT" \
          --token-file "$TOKEN" --nodes "$BMC_NODES" --log "$AGENT_LOG" \
          >>"$AGENT_LOG.stderr" 2>&1 </dev/null ) &
      echo $! > "$AGENT_PIDF"
      sleep 1
      agent_pid >/dev/null || die "agent did not start: $AGENT_LOG.stderr"
      echo "agent started (pid $(cat "$AGENT_PIDF")) on 127.0.0.1:$AGENT_PORT, nodes: $BMC_NODES" ;;
    stop)
      if p="$(agent_pid)"; then kill "$p"; echo "agent stopped (pid $p)"; fi
      rm -f "$AGENT_PIDF" ;;
    status)
      if p="$(agent_pid)"; then echo "agent running (pid $p) on 127.0.0.1:$AGENT_PORT"; tail -3 "$AGENT_LOG" 2>/dev/null
      else echo "agent not running"; return 1; fi ;;
    *) die "usage: bmc.sh agent start|stop|status" ;;
  esac
}

provision() {
  need_file "$TOKEN" "run: tools/bmc.sh secrets"
  need_file "$SECRETS/lab-ca/ca.crt" "run: tools/lab-ca.sh init"
  [[ -f "$SECRETS/lab-ca/bmc.crt" ]] || "$LAB/tools/lab-ca.sh" issue bmc "IP:$BMC_IP,DNS:bmc.lab"
  wait_ready_aux bmc
  local addrs="$BMC_IP/24" n
  for n in $BMC_NODES; do addrs+=",$(bmc_ip "$n")/24"; done
  # Credentials and TLS material go in over stdin into 0600 files, never argv.
  { echo "AGENT_URL=http://10.0.2.2:$AGENT_PORT"; echo "AGENT_TOKEN=$(cat "$TOKEN")"; cat "$IPMI_ENV" "$REDFISH_ENV"; } |
    bmcssh 'umask 077; mkdir -p /etc/lab-bmc && cat > /etc/lab-bmc/bmc.env'
  bmcssh 'umask 077; mkdir -p /etc/lab-bmc/tls && cat > /etc/lab-bmc/tls/bmc.key' < "$SECRETS/lab-ca/bmc.key"
  bmcssh 'cat > /etc/lab-bmc/tls/bmc.crt' < "$SECRETS/lab-ca/bmc.crt"
  tar -C "$LAB/tools/bmc-vm" -cf - . | bmcssh 'mkdir -p /usr/local/lib/lab-bmc && tar -C /usr/local/lib/lab-bmc -xf - && chmod 0755 /usr/local/lib/lab-bmc/*'
  local rc=0
  SSH_TIMEOUT=1800 bmcssh 'bash -s' -- "$addrs" "${BMC_NODES// /,}" "$IPMI_BASE" "$LAN_PREFIX" "$BMC_IP" <<'REMOTE' || rc=$?
set -euo pipefail
# ssh joins argv with spaces, so lists arrive comma-separated.
ADDRS="${1//,/, }"; NODES="${2//,/ }"; BASE="$3"; PREFIX="$4"; BMC_IP="$5"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1
fails=0
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok:   $d"; else echo "FAIL: $d"; fails=$((fails+1)); fi; }
missing=(); for p in openipmi ipmitool python3-venv curl; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
if [[ ${#missing[@]} -gt 0 ]]; then apt-get update -qq; apt-get install -y -qq --no-install-recommends "${missing[@]}" >/dev/null; fi

# Every BMC address on the LAN NIC (rewritten whole, so a changed node list is
# picked up), applied live: this VM runs nothing else on its network.
sed -i "s#addresses: \[.*\]#addresses: [$ADDRS]#" /etc/netplan/60-cluster.yaml
netplan apply

set -a; . /etc/lab-bmc/bmc.env; set +a
# ── IPMI: one ipmi_sim per node ──────────────────────────────────────────────
install -d -m 0700 /etc/lab-bmc/ipmi /var/lib/lab-bmc
for n in $NODES; do
  d=/etc/lab-bmc/ipmi/node-$n
  # ipmi_sim prefers its persisted user table over lan.conf; start it fresh so
  # the credentials in lan.conf are the ones that work.
  rm -rf "/var/lib/lab-bmc/node-$n"; install -d -m 0700 "$d" "/var/lib/lab-bmc/node-$n"
  ip="$PREFIX.$((BASE + n))"
  umask 077
  cat > "$d/lan.conf" <<CONF
name "node-$n-bmc"
set_working_mc 0x20
  startlan 1
    addr $ip 623
    priv_limit admin
    allowed_auths_callback none md5 straight
    allowed_auths_user md5 straight
    allowed_auths_operator md5 straight
    allowed_auths_admin md5 straight
    guid $(printf 'lab-node-%02d-bmc-' "$n" | od -An -tx1 | tr -d ' \n')
  endlan
  chassis_control "/usr/local/lib/lab-bmc/chassis $n"
  user 1 false ""            "unused"      user  10 md5 straight
  user 2 true  "$IPMI_USER"  "$IPMI_PASS"  admin 10 md5 straight
CONF
  cat > "$d/sim.emu" <<EMU
mc_setbmc 0x20
mc_add 0x20 0 no-device-sdrs 0x23 9 8 0x9f 0x1291 0xf02 persist_sdr
sel_enable 0x20 1000 0x0a
mc_enable 0x20
EMU
done
cat > /etc/systemd/system/lab-ipmi-sim@.service <<'UNIT'
[Unit]
Description=lab: simulated IPMI BMC for node-%i
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/ipmi_sim -n -c /etc/lab-bmc/ipmi/node-%i/lan.conf -f /etc/lab-bmc/ipmi/node-%i/sim.emu -s /var/lib/lab-bmc/node-%i
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
# ── Redfish: sushy-tools with the lab driver ─────────────────────────────────
# sushy-tools pinned to the version this was verified with; bcrypt comes with it
# (its auth file accepts bcrypt digests only).
[[ -x /opt/sushy/bin/sushy-emulator ]] || { python3 -m venv /opt/sushy; /opt/sushy/bin/pip install -q 'sushy-tools==2.2.0'; }
python3 - "$NODES" > /etc/lab-bmc/redfish-systems.json <<'PY'
import json, sys, uuid
print(json.dumps([{"uuid": str(uuid.uuid5(uuid.NAMESPACE_DNS, f"node-{n}.litevirt-lab")),
                   "name": f"node-{n}", "power_state": "Off", "nics": []}
                  for n in sys.argv[1].split()]))
PY
( umask 077; /opt/sushy/bin/python -c 'import os,bcrypt;print(os.environ["REDFISH_USER"]+":"+bcrypt.hashpw(os.environ["REDFISH_PASS"].encode(),bcrypt.gensalt()).decode())' > /etc/lab-bmc/redfish.htpasswd )
cat > /etc/lab-bmc/sushy.conf <<CONF
SUSHY_EMULATOR_LISTEN_IP = "$BMC_IP"
SUSHY_EMULATOR_LISTEN_PORT = 8000
SUSHY_EMULATOR_SSL_CERT = "/etc/lab-bmc/tls/bmc.crt"
SUSHY_EMULATOR_SSL_KEY = "/etc/lab-bmc/tls/bmc.key"
SUSHY_EMULATOR_AUTH_FILE = "/etc/lab-bmc/redfish.htpasswd"
SUSHY_EMULATOR_FAKE_DRIVER = True
SUSHY_EMULATOR_FAKE_SYSTEMS = $(cat /etc/lab-bmc/redfish-systems.json)
SUSHY_EMULATOR_VMEDIA_VERIFY_SSL = False
SUSHY_EMULATOR_STATE_DIR = "/var/lib/lab-bmc/sushy"
CONF
cat > /etc/systemd/system/lab-redfish.service <<'UNIT'
[Unit]
Description=lab: sushy-tools Redfish simulator for the lab nodes
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/lab-bmc/bmc.env
ExecStart=/opt/sushy/bin/python /usr/local/lib/lab-bmc/redfish-lab.py --config /etc/lab-bmc/sushy.conf
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
for n in $NODES; do systemctl enable -q lab-ipmi-sim@"$n"; systemctl restart lab-ipmi-sim@"$n"; done
systemctl enable -q lab-redfish; systemctl restart lab-redfish
sleep 3
for n in $NODES; do
  chk "ipmi_sim node-$n active on $PREFIX.$((BASE + n)):623" systemctl is-active lab-ipmi-sim@"$n"
  chk "ipmi_sim node-$n answers (local lanplus)" sh -c "IPMI_PASSWORD='$IPMI_PASS' ipmitool -I lanplus -H $PREFIX.$((BASE + n)) -U '$IPMI_USER' -E -N 1 -R 2 chassis power status"
done
chk "redfish active" systemctl is-active lab-redfish
chk "redfish answers with auth" curl -sf --cacert /etc/lab-bmc/tls/bmc.crt -u "$REDFISH_USER:$REDFISH_PASS" "https://$BMC_IP:8000/redfish/v1/Systems"
chk "redfish refuses without auth" sh -c "! curl -sf --cacert /etc/lab-bmc/tls/bmc.crt https://$BMC_IP:8000/redfish/v1/Systems"
[[ $fails -eq 0 ]]
REMOTE
  finish "bmc provision" "$rc"
}

# wait_ready_aux <role> — sshd and cloud-init done on an aux VM.
wait_ready_aux() {
  for _ in $(seq 1 60); do
    if SSH_TIMEOUT=20 "$LAB/lab.sh" aux ssh "$1" 'test -f /var/lib/cloud/lab-ready' 2>/dev/null; then return 0; fi
    sleep 5
  done
  die "aux $1 not ready after 5 min: $LAB/lab.sh aux status"
}

nodes() {
  need_file "$IPMI_ENV" "run: tools/bmc.sh secrets"
  local targets n fails=0
  if [[ $# -gt 0 ]]; then targets=("$@"); else mapfile -t targets < <(seq 1 "$NODES"); fi
  for n in "${targets[@]}"; do
    say "node-$n"
    { cat "$IPMI_ENV"; echo "BMC_PREFIX=$LAN_PREFIX"; echo "BMC_BASE=$IPMI_BASE"; echo "BMC_NODES=\"$BMC_NODES\""; } |
      SSH_TIMEOUT=60 nodessh "$n" 'umask 077; mkdir -p /etc/lab-bmc && cat > /etc/lab-bmc/ipmi.env'
    SSH_TIMEOUT=60 nodessh "$n" 'cat > /usr/local/sbin/lab-host-power && chmod 0755 /usr/local/sbin/lab-host-power' < "$LAB/tools/lab-host-power"
    if SSH_TIMEOUT=600 nodessh "$n" 'export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1; command -v ipmitool >/dev/null || { apt-get update -qq && apt-get install -y -qq --no-install-recommends ipmitool >/dev/null; }; lab-host-power '"$n"' status'; then
      echo "ok:   node-$n has lab-host-power and reaches its own BMC"
    else echo "FAIL: node-$n"; fails=$((fails + 1)); fi
  done
  finish "bmc nodes (${targets[*]})" "$fails"
}

check() {
  local via="${CHECK_VIA:-1}" n fails=0
  # shellcheck source=/dev/null
  . "$REDFISH_ENV"
  for n in $BMC_NODES; do
    local agent ipmi rf
    agent="$(curl -sf -H "Authorization: Bearer $(cat "$TOKEN")" "http://127.0.0.1:$AGENT_PORT/v1/nodes/$n/power" || echo unreachable)"
    ipmi="$(SSH_TIMEOUT=30 nodessh "$via" "lab-host-power $n status" 2>&1 || true)"
    rf="$(printf 'url = "https://%s:8000/redfish/v1/Systems/%s"\nuser = "%s:%s"\n' "$BMC_IP" \
          "$(python3 -c "import uuid;print(uuid.uuid5(uuid.NAMESPACE_DNS,'node-$n.litevirt-lab'))")" "$REDFISH_USER" "$REDFISH_PASS" |
          SSH_TIMEOUT=30 nodessh "$via" 'curl -sf --config - | python3 -c "import json,sys;print(json.load(sys.stdin)[\"PowerState\"])"' 2>&1 || echo unreachable)"
    echo "node-$n  agent=$agent  ipmi='$ipmi'  redfish=$rf"
    [[ "$agent" == *'"power"'* && "$ipmi" == *"Chassis Power is"* && ( "$rf" == On || "$rf" == Off ) ]] || fails=$((fails + 1))
  done
  finish "bmc check (via node-$via)" "$fails"
}

case "${1:-}" in
  secrets)   secrets ;;
  agent)     shift; agent "$@" ;;
  provision) provision ;;
  nodes)     shift; nodes "$@" ;;
  check)     check ;;
  *) echo "usage: $0 {secrets|agent start|stop|status|provision|nodes [n...]|check}" >&2; exit 2 ;;
esac
