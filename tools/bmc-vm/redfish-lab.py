#!/usr/bin/env python3
"""redfish-lab.py — sushy-tools' Redfish emulator, powering real lab nodes.

sushy-tools ships a libvirt driver (which would need the lab host's libvirt —
never: that host runs other people's VMs) and a fake driver that only flips a
field in memory. This keeps the fake driver's inventory (one ComputerSystem
per node, named `node-N`, from SUSHY_EMULATOR_FAKE_SYSTEMS) and replaces its
power state with the real one: reads and ComputerSystem.Reset go to the lab
host's power agent through labpower.py, so a Reset actually stops and starts
the node's qemu process.

    On / ForceOn                      -> on
    ForceOff                          -> off (power cut)
    GracefulShutdown                  -> soft (ACPI power button)
    ForceRestart / GracefulRestart / PowerCycle -> cycle (a new qemu process)
    PushPowerButton                   -> soft when on, on when off
    Nmi                               -> not supported

Run with the venv's python: redfish-lab.py --config /etc/lab-bmc/sushy.conf
"""
import re
import sys

sys.path.insert(0, "/usr/local/lib/lab-bmc")

import labpower  # noqa: E402
from sushy_tools import error  # noqa: E402
from sushy_tools.emulator.resources.systems import fakedriver  # noqa: E402

NODE = re.compile(r"^node-(\d+)$")
ACTIONS = {
    "On": "on", "ForceOn": "on", "ForceOff": "off", "GracefulShutdown": "soft",
    "ForceRestart": "cycle", "GracefulRestart": "cycle", "PowerCycle": "cycle",
}


class LabDriver(fakedriver.FakeDriver):
    """The fake driver's inventory with the lab's real power."""

    def _node(self, identity):
        system = self._get(identity)
        m = NODE.match(system["name"])
        if not m:
            raise error.NotFound(f"{system['name']} is not a lab node")
        return m.group(1)

    def get_power_state(self, identity):
        try:
            return "On" if labpower.call(self._node(identity))["power"] == "on" else "Off"
        except error.FishyError:
            raise
        except Exception as e:  # noqa: BLE001 — agent unreachable: say so, do not guess
            raise error.FishyError(f"power agent: {e}") from e

    def set_power_state(self, identity, state):
        n = self._node(identity)
        if state == "PushPowerButton":
            action = "soft" if labpower.call(n)["power"] == "on" else "on"
        elif state in ACTIONS:
            action = ACTIONS[state]
        else:
            raise error.NotSupportedError(f"Power state {state} is not supported")
        self._logger.info("lab node-%s: Reset %s -> agent %s", n, state, action)
        try:
            labpower.call(n, action)
        except Exception as e:  # noqa: BLE001
            raise error.FishyError(f"power agent refused {action}: {e}") from e


fakedriver.FakeDriver = LabDriver

from sushy_tools.emulator import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main.main())
