"""Execute the real UtilsSystem/network helpers against Luau fixtures.

The game's UtilsSystem export is a registry: supported builds expose it as an
invocable function, while older/mirrored builds may expose a table. NetWork's
FireServer/InvokeServer functions are static wrappers whose first argument is
the opaque descriptor returned by NetMsg; using ``:`` inserts an invalid extra
``self`` argument. These smokes exercise both contracts from the shipped
helper bodies rather than merely matching source strings.
"""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from tools.ensure_luau import run_binary as luau_runner  # noqa: E402


def helper_source(start: str, end: str) -> str:
    source = (REPO_ROOT / "games" / "magicloot.lua").read_text(encoding="utf-8")
    left = source.index(start)
    right = source.index(end, left)
    return source[left:right]


def run_luau(source: str) -> subprocess.CompletedProcess:
    with tempfile.NamedTemporaryFile(
        "w", suffix=".luau", delete=False, encoding="utf-8", newline="\n"
    ) as handle:
        handle.write(source)
        path = Path(handle.name)
    try:
        return subprocess.run(
            [str(luau_runner()), str(path)],
            capture_output=True,
            text=True,
            timeout=30,
        )
    finally:
        path.unlink(missing_ok=True)


NETWORK_HELPERS = helper_source(
    "    local net = {",
    "    -- Player data",
)

RUNTIME_MODULE_HELPER = helper_source(
    "    local runtimeModules = {}",
    "    local function resolveGetData()",
)


def fixture(registry_expression: str) -> str:
    return f"""
local fireRemote = "fire-message-descriptor"
local invokeRemote = "训练点屏"
local fireCalls = {{}}
local invokeCalls = {{}}
local registryReads = {{}}

local network = {{
    FireServer = function(...)
        local count = select("#", ...)
        local remote, payload = ...
        assert(count == 1 or count == 2, "FireServer received " .. tostring(count) .. " args")
        assert(remote == fireRemote, "FireServer first arg was not the remote")
        table.insert(fireCalls, payload or "empty")
    end,
    InvokeServer = function(...)
        local count = select("#", ...)
        local remote, payload = ...
        assert(count == 1 or count == 2, "InvokeServer received " .. tostring(count) .. " args")
        assert(remote == invokeRemote, "InvokeServer first arg was not the remote")
        table.insert(invokeCalls, payload or "empty")
        return {{ accepted = payload and payload.value or "empty" }}
    end,
}}

local modules = {{
    NetWork = network,
    NetMsg = {{
        FIRE = fireRemote,
        FIRE_EMPTY = fireRemote,
        INVOKE = invokeRemote,
        INVOKE_EMPTY = invokeRemote,
        TRAIN_MANUAL_CLICK = invokeRemote,
        DUNGEON_RETURN_TOWN = fireRemote,
    }},
    GetData = {{ marker = "get-data" }},
}}

local utilsRegistry = {registry_expression}
local utilsModule = {{ payload = utilsRegistry }}
local allSideCode = {{
    WaitForChild = function(_, name)
        assert(name == "UtilsSystem", "unexpected AllSideCode child " .. tostring(name))
        return utilsModule
    end,
}}
local primaryContainer = {{
    WaitForChild = function(_, name)
        assert(name == "AllSideCode", "unexpected container child " .. tostring(name))
        return allSideCode
    end,
}}
local fallbackContainer = {{
    WaitForChild = function()
        return nil
    end,
}}

local ReplicatedFirst = primaryContainer
local ReplicatedStorage = fallbackContainer
local function require(module)
    return module.payload
end
{NETWORK_HELPERS}
{RUNTIME_MODULE_HELPER}

local savedMessages = modules.NetMsg
modules.NetMsg = nil
assert(remoteFor("FIRE") == nil, "missing NetMsg unexpectedly resolved")
assert(net.network == network and net.messages == nil,
    "half-resolved network state was not reproduced")
modules.NetMsg = savedMessages
assert(remoteFor("FIRE") == fireRemote,
    "NetMsg was not retried after becoming available")

local sent, sendError = sendAction("FIRE", {{ value = 17 }})
assert(sent, "sendAction failed: " .. tostring(sendError))
assert(#fireCalls == 1 and fireCalls[1].value == 17, "wrong FireServer payload")
sent, sendError = sendAction("FIRE_EMPTY")
assert(sent, "payload-free sendAction failed: " .. tostring(sendError))
assert(#fireCalls == 2 and fireCalls[2] == "empty", "wrong payload-free FireServer call")

sent, sendError = sendAction("DUNGEON_RETURN_TOWN")
assert(sent, "dungeon return FireServer failed: " .. tostring(sendError))
assert(#fireCalls == 3 and fireCalls[3] == "empty",
    "dungeon return did not send only its descriptor")

local invoked, result, invokeError = invokeAction("INVOKE", {{ value = 23 }})
assert(invoked, "invokeAction failed: " .. tostring(invokeError))
assert(result.accepted == 23, "wrong InvokeServer result")
assert(#invokeCalls == 1 and invokeCalls[1].value == 23, "wrong InvokeServer payload")
invoked, result, invokeError = invokeAction("INVOKE_EMPTY")
assert(invoked, "payload-free invokeAction failed: " .. tostring(invokeError))
assert(result.accepted == "empty", "wrong payload-free InvokeServer result")
assert(#invokeCalls == 2 and invokeCalls[2] == "empty", "wrong payload-free InvokeServer call")

invoked, result, invokeError = invokeAction("TRAIN_MANUAL_CLICK", {{}})
assert(invoked, "power-click invoke failed: " .. tostring(invokeError))
assert(#invokeCalls == 3, "power-click descriptor was rejected")
assert(type(invokeCalls[3]) == "table" and next(invokeCalls[3]) == nil,
    "power-click payload was not empty")

local getData = resolveRuntimeModule("GetData")
assert(getData == modules.GetData, "runtime module did not use UtilsSystem registry")
assert(net.status == "ready", "network status was " .. tostring(net.status))
print("network_registry_smoke=ok")
"""


class NetworkFlowSmokeTests(unittest.TestCase):
    def assert_fixture_passes(self, registry_expression: str):
        completed = run_luau(fixture(registry_expression))
        self.assertEqual(
            completed.returncode,
            0,
            f"network smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("network_registry_smoke=ok", completed.stdout)

    def test_callable_utils_registry_and_static_network_methods(self):
        self.assert_fixture_passes(
            "function(name) "
            "table.insert(registryReads, name); "
            "return modules[name] "
            "end"
        )

    def test_table_utils_registry_keeps_compatibility(self):
        self.assert_fixture_passes("modules")


if __name__ == "__main__":
    unittest.main()
