"""The committed flavour files bind exactly what their metadata says.

For every flavour whose metadata is committed under `packages/apiKit/metadata/`,
this suite builds a stub host from that metadata (every Blizzard namespace with
every documented function, every global function, `Enum` and `Constants`
tables), loads the committed `src/flavours/<Flavour>.lua` under Lua 5.1 with a
stand-in facade, runs the installer against the stub and checks that every
binding resolves to the stub function it names and that nothing else was
bound. It is the "sampled generated-output spec" the roadmap asks for, made
exhaustive because the check is cheap.

The suite needs a Lua 5.1 interpreter on the path and is skipped without one.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

from tooling.api import flavours, model, render_runtime
from tooling.validation.validate_manifests import ROOT


PACKAGE_DIR = ROOT / "packages" / "apiKit"

#: Runs the committed flavour file against the stub host and reports mismatches.
HARNESS = textwrap.dedent(
    """\
    local runtimeFile, hostFile, expectedFile = arg[1], arg[2], arg[3]
    local installers, infos = {}, {}
    local ApiKit = {
        API = 1,
        RegisterFlavor = function(_, flavour, install, info)
            installers[flavour] = install
            infos[flavour] = info
        end,
    }
    MoltenCodes = { Registries = { [2] = { API = 2, Get = function() return ApiKit end } } }
    assert(loadfile(runtimeFile))()
    local host = assert(loadfile(hostFile))()
    local expected = assert(loadfile(expectedFile))()

    local flavour, install = next(installers)
    assert(flavour == expected.flavour, "registered " .. tostring(flavour))
    assert(infos[flavour].build == expected.build, "build")
    local api = {}
    install(api, host)

    local problems = {}
    local bound = 0
    for _, entry in ipairs(expected.bindings) do
        local namespace = api[entry.namespace]
        local value = namespace and namespace[entry.wrapper]
        local wanted = entry.global and host[entry.name] or host[entry.source][entry.name]
        if value ~= wanted then
            problems[#problems + 1] = entry.namespace .. "." .. entry.wrapper
        else
            bound = bound + 1
        end
    end
    for _, alias in ipairs(expected.aliases) do
        if api[alias.alias] ~= api[alias.namespace] then
            problems[#problems + 1] = "alias " .. alias.alias
        end
    end
    for _, event in ipairs(expected.events) do
        if api.events[event.wrapper] ~= event.literal then
            problems[#problems + 1] = "event " .. event.wrapper
        end
    end
    for _, enum in ipairs(expected.enums) do
        if api.enums[enum.wrapper] ~= host.Enum[enum.name] then
            problems[#problems + 1] = "enum " .. enum.wrapper
        end
    end
    local extra = 0
    for name, value in pairs(api) do
        if type(value) == "table" and not expected.namespaces[name] then
            extra = extra + 1
            problems[#problems + 1] = "unexpected api." .. name
        end
    end
    if #problems > 0 then
        error(#problems .. " problem(s): " .. table.concat(problems, ", ", 1, math.min(#problems, 10)), 0)
    end
    print("ok " .. bound)
    """
)


def _lua_string(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def stub_host_lua(metadata: model.FlavourMetadata) -> str:
    """A Lua chunk returning a host table with a distinct function for every binding."""
    lines = ["local host = {}", "local function stub() end"]
    for namespace in metadata.namespaces:
        if namespace.kind == "namespace":
            assert namespace.blizzard_namespace is not None
            lines.append(f"host[{_lua_string(namespace.blizzard_namespace)}] = {{}}")
            for function in namespace.functions:
                lines.append(
                    f"host[{_lua_string(namespace.blizzard_namespace)}][{_lua_string(function.name)}] = function() end"
                )
        elif namespace.kind == "global":
            for function in namespace.functions:
                lines.append(f"host[{_lua_string(function.name)}] = function() end")
    lines.append("host.Enum = {}")
    for enum in metadata.enums:
        lines.append(f"host.Enum[{_lua_string(enum.name)}] = {{}}")
    lines.append("host.Constants = {}")
    for table in metadata.constants:
        lines.append(f"host.Constants[{_lua_string(table.name)}] = {{}}")
    lines.append("return host")
    return "\n".join(lines) + "\n"


def expected_lua(metadata: model.FlavourMetadata) -> str:
    """A Lua chunk returning what the installer must have bound."""
    bindings = []
    aliases = []
    namespaces = {"events", "enums", "constants"}
    for namespace in metadata.namespaces:
        if namespace.kind == "object":
            continue
        namespaces.add(namespace.wrapper)
        if namespace.alias is not None:
            namespaces.add(namespace.alias)
            aliases.append(f"{{ alias = {_lua_string(namespace.alias)}, namespace = {_lua_string(namespace.wrapper)} }}")
        for function in namespace.functions:
            source = _lua_string(namespace.blizzard_namespace or "")
            is_global = "true" if namespace.kind == "global" else "false"
            bindings.append(
                f"{{ namespace = {_lua_string(namespace.wrapper)}, wrapper = {_lua_string(function.wrapper)}, "
                f"name = {_lua_string(function.name)}, source = {source}, global = {is_global} }}"
            )
    events = [f"{{ wrapper = {_lua_string(event.wrapper)}, literal = {_lua_string(event.literal_name)} }}" for event in metadata.events]
    enums = [f"{{ wrapper = {_lua_string(enum.wrapper)}, name = {_lua_string(enum.name)} }}" for enum in metadata.enums]
    namespace_set = ", ".join(f"[{_lua_string(name)}] = true" for name in sorted(namespaces))
    build = metadata.provenance.build if metadata.provenance.build is not None else "nil"
    return (
        "return {\n"
        f"    flavour = {_lua_string(metadata.provenance.flavour)},\n"
        f"    build = {build},\n"
        f"    namespaces = {{ {namespace_set} }},\n"
        "    bindings = {\n        " + ",\n        ".join(bindings) + "\n    },\n"
        "    aliases = {\n        " + ",\n        ".join(aliases) + "\n    },\n"
        "    events = {\n        " + ",\n        ".join(events) + "\n    },\n"
        "    enums = {\n        " + ",\n        ".join(enums) + "\n    },\n"
        "}\n"
    )


def committed_flavours() -> list[flavours.Flavour]:
    table = flavours.load_flavours()
    return [
        flavour
        for flavour in table.flavours
        if (PACKAGE_DIR / "metadata" / flavour.id / model.PROVENANCE_FILE).is_file()
    ]


class CommittedFlavourTests(unittest.TestCase):
    def setUp(self):
        self.lua = shutil.which("lua") or shutil.which("lua5.1")
        if self.lua is None:
            self.skipTest("no Lua interpreter on PATH")
        self.flavours = committed_flavours()
        if not self.flavours:
            self.skipTest("no flavour metadata is committed yet")

    def test_every_committed_flavour_has_its_runtime_file(self):
        for flavour in self.flavours:
            runtime = PACKAGE_DIR / "src" / render_runtime.runtime_file_name(flavour)
            self.assertTrue(runtime.is_file(), f"{runtime} is missing; run tooling.api.generate")

    def test_committed_runtime_files_bind_exactly_their_metadata(self):
        for flavour in self.flavours:
            with self.subTest(flavour=flavour.id):
                metadata = model.read_metadata(PACKAGE_DIR / "metadata" / flavour.id)
                runtime = PACKAGE_DIR / "src" / render_runtime.runtime_file_name(flavour)
                with tempfile.TemporaryDirectory() as directory:
                    host = Path(directory) / "host.lua"
                    expected = Path(directory) / "expected.lua"
                    harness = Path(directory) / "harness.lua"
                    host.write_text(stub_host_lua(metadata), encoding="utf-8")
                    expected.write_text(expected_lua(metadata), encoding="utf-8")
                    harness.write_text(HARNESS, encoding="utf-8")
                    completed = subprocess.run(
                        [self.lua, str(harness), str(runtime), str(host), str(expected)],
                        capture_output=True,
                        text=True,
                        check=False,
                    )
                self.assertEqual(0, completed.returncode, completed.stderr)
                bound = int(completed.stdout.split()[1])
                documented = sum(
                    len(namespace.functions) for namespace in metadata.namespaces if namespace.kind != "object"
                )
                self.assertEqual(documented, bound)

    def test_committed_outputs_are_current(self):
        """`tooling.api.generate --check` agrees with what is committed."""
        from tooling.api import generate

        for flavour in self.flavours:
            with self.subTest(flavour=flavour.id):
                result = generate.plan_flavour(flavour, package_dir=PACKAGE_DIR)
                self.assertTrue(
                    result.up_to_date,
                    "stale generated files: " + ", ".join(str(path) for path in [*result.changed, *result.removed]),
                )


if __name__ == "__main__":
    unittest.main()
