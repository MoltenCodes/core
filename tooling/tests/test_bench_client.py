"""Tests for the in-client benchmark tooling (`tooling/bench/client_*.py`).

Nothing here touches the network, runs Lua or touches a real game folder:
every install goes into a fake game folder in a temporary directory, with a
neighbouring addon and saved variables that must survive, and the Ace3 source
is a fake cache of placeholder files handed in as a verified `Ace3Source`. The
report is fed saved variables written in the client's format by the test
itself. The Lua side is exercised by running it in the client
(`docs/BENCHMARKS.md`, "In-client runner").
"""

from __future__ import annotations

import contextlib
import io
import json
import re
import tempfile
import unittest
from pathlib import Path
from typing import Any

from tooling.bench import ace3, client_install, client_report, client_workloads, report, workloads
from tooling.client import install as test_install
from tooling.validation.interface_numbers import load_supported_clients


def fake_ace3(root: Path) -> ace3.Ace3Source:
    """A verified-looking Ace3 checkout of placeholder files under `root`."""
    directory = root / "ace3" / ace3.ACE3_COMMIT
    for name in ace3.LOADED_FILES:
        path = directory / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"-- {name}\n", encoding="utf-8")
    return ace3.Ace3Source(
        directory=directory,
        commit=ace3.ACE3_COMMIT,
        archive_url=ace3.archive_url(),
        archive_sha256="0" * 64,
        content_digest=ace3.content_digest(directory),
        fetched="2026-09-25",
    )


def lua_value(value: Any) -> str:
    """A Lua literal in the client's saved-variables style, for fixtures."""
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        return json.dumps(value)
    if isinstance(value, list):
        items = [f"{lua_value(item)}, -- [{index}]\n" for index, item in enumerate(value, 1)]
    else:
        items = [f'["{key}"] = {lua_value(item)},\n' for key, item in value.items()]
    return "{\n" + "".join(items) + "}"


INSTALLATION = {
    "commit": "a" * 40,
    "dirty": False,
    "flavourDirectory": "_retail_",
    "installedAt": "2026-09-26T10:00:00Z",
}
CLIENT = {
    "version": "12.1.0",
    "build": "69933",
    "interface": 120100,
    "projectId": 1,
    "os": "macOS",
    "locale": "enUS",
    "testBuild": False,
    "date": "2026-09-26 10:05:00",
}
SESSION = {
    "addonsLoaded": ["MoltenCodesBench", "MoltenCodesBench_Kits"],
    "secondsSinceEnteringWorld": 10,
    "frameRateSettings": {"maxFPS": "144"},
    "errorsCaptured": True,
}


def entry(side: str, step: str, case: str | None = None, **fields: Any) -> dict[str, Any]:
    """One saved harness entry for the `codec` workload unless `fields` say otherwise."""
    value: dict[str, Any] = {
        "schema": 1,
        "workload": "codec",
        "side": side,
        "step": step,
        "installation": dict(INSTALLATION),
        "client": dict(CLIENT),
        "session": dict(SESSION),
        "libraries": [
            {"name": "CodecKit" if side == "moltencodes" else "AceSerializer-3.0", "revision": 3}
        ],
    }
    if case is not None:
        value["case"] = case
        value["round"] = 1
    value.update(fields)
    return value


def batch_result(name: str, samples: list[float]) -> dict[str, Any]:
    """A batch case result as ClientBench writes it."""
    return {
        "kind": "batch",
        "name": name,
        "operation": "encode a small payload",
        "equivalent": True,
        "iterations": 1000,
        "warmup": 2,
        "repetitions": len(samples),
        "nanosecondsPerOperation": samples,
        "medianNanoseconds": sorted(samples)[len(samples) // 2],
        "minimumNanoseconds": min(samples),
        "allocatedBytesPerOperation": 64,
    }


def small(samples: list[float]) -> dict[str, Any]:
    """A result of the `encode-small` case."""
    return batch_result("encode-small", samples)


class FakeGameFolder(unittest.TestCase):
    """A fake game folder per test, with a neighbour that must never be touched."""

    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.base = Path(self.tempdir.name).resolve()
        self.wow = self.base / "World of Warcraft"
        self.flavour = self.wow / "_retail_"
        self.addons = self.flavour / "Interface" / "AddOns"
        self.addons.mkdir(parents=True)
        self.neighbour = self.addons / "MoltenSession"
        self.neighbour.mkdir()
        (self.neighbour / "MoltenSession.toc").write_text("## Title: Mine\n", encoding="utf-8")
        self.layout = test_install.resolve_layout(self.wow, "_retail_")

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def saved_variables(self, *parts: str) -> Path:
        folder = self.flavour / "WTF" / "Account" / Path(*parts) / "SavedVariables"
        folder.mkdir(parents=True)
        return folder

    def assert_neighbour_untouched(self) -> None:
        self.assertEqual(
            "## Title: Mine\n", (self.neighbour / "MoltenSession.toc").read_text(encoding="utf-8")
        )


class CatalogueTests(unittest.TestCase):
    def test_every_host_workload_is_run_in_the_client_or_excluded_with_a_reason(self) -> None:
        shared = set(client_workloads.SHARED_IN_CLIENT)
        excluded = set(client_workloads.NOT_IN_CLIENT)
        self.assertEqual(set(), shared & excluded)
        self.assertEqual(set(workloads.BY_NAME), shared | excluded)
        for reason in client_workloads.NOT_IN_CLIENT.values():
            self.assertTrue(reason.strip())

    def test_every_client_workload_has_its_lua_module(self) -> None:
        for workload in client_workloads.CLIENT_WORKLOADS:
            with self.subTest(workload=workload.name):
                self.assertTrue(workload.lua_file.is_file(), workload.lua_file)

    def test_client_only_names_do_not_collide_with_host_names(self) -> None:
        names = [workload.name for workload in client_workloads.CLIENT_WORKLOADS]
        self.assertEqual(len(names), len(set(names)))
        for workload in client_workloads.CLIENT_ONLY:
            self.assertNotIn(workload.name, workloads.BY_NAME)

    def test_every_required_module_is_installed(self) -> None:
        installed = {name for name, _ in client_install.module_sources()}
        for name in client_workloads.CLIENT_SUPPORT_MODULES:
            self.assertIn(name, installed)
        pattern = re.compile(r'require\("([A-Za-z.]+)"\)')
        for name, path in client_install.module_sources():
            for required in pattern.findall(path.read_text(encoding="utf-8")):
                with self.subTest(module=name, requires=required):
                    self.assertIn(required, installed)

    def test_host_only_modules_are_not_installed(self) -> None:
        installed = {name for name, _ in client_install.module_sources()}
        for name in client_install.HOST_ONLY_MODULES:
            self.assertNotIn(name, installed)
        self.assertIn("Bench", installed)
        self.assertIn("workloads.Dispatch", installed)
        self.assertIn("clientWorkloads.Session", installed)


class GeneratedFileTests(unittest.TestCase):
    def test_a_wrapped_module_keeps_every_line_number(self) -> None:
        source = "--- A module.\nlocal M = {}\n\nreturn M\n"
        wrapped = client_install.wrap_module("workloads.Example", source)
        lines = wrapped.splitlines()
        self.assertTrue(lines[0].startswith("local _, private = ...; private.DefineModule("))
        self.assertTrue(lines[0].endswith("--- A module."))
        self.assertEqual(source.splitlines()[1:], lines[1:4])
        self.assertEqual("end)", lines[4])

    def test_a_source_without_a_final_newline_is_closed_on_its_own_line(self) -> None:
        wrapped = client_install.wrap_module("M", "return {}")
        self.assertTrue(wrapped.endswith("return {}\nend)\n"))

    def test_the_harness_toc_lists_the_modules_in_place_of_the_marker(self) -> None:
        template = "## Interface: 1\nInstallation.lua\nLoader.lua\n# @modules@\nHarness.lua\n"
        text = client_install.harness_toc(
            template, "## Interface: 120100", ["modules/Bench.lua", "modules/workloads/A.lua"]
        )
        self.assertEqual(
            "## Interface: 120100\nInstallation.lua\nLoader.lua\nmodules\\Bench.lua\n"
            "modules\\workloads\\A.lua\nHarness.lua\n",
            text,
        )

    def test_the_harness_toc_must_hold_the_marker_once(self) -> None:
        with self.assertRaises(client_install.BenchInstallError):
            client_install.harness_toc("Harness.lua\n", "## Interface: 1", [])

    def test_the_committed_harness_toc_has_the_marker_and_the_supported_interface_line(self):
        text = (client_workloads.HARNESS_SOURCE / "MoltenCodesBench.toc").read_text(
            encoding="utf-8"
        )
        self.assertEqual(1, text.splitlines().count(client_install.MODULES_MARKER))
        self.assertIn(load_supported_clients().toc_line() + "\n", text)
        self.assertIn("## SavedVariables: MoltenCodesBenchResults\n", text)
        self.assertNotIn("## Dependencies", text)

    def test_lua_literals_quote_keys_that_are_not_names(self) -> None:
        text = client_install.lua_literal({"plain": 1, "with-dash": "a\"b", "end": True})
        self.assertIn("plain = 1,", text)
        self.assertIn('["with-dash"] = "a\\"b",', text)
        self.assertIn('["end"] = true,', text)
        self.assertEqual("{}", client_install.lua_literal([]))
        self.assertEqual("nil", client_install.lua_literal(None))


class InstallTests(FakeGameFolder):
    def install(self, **overrides: Any) -> list[str]:
        lines: list[str] = []
        source = overrides.get("ace3_source")
        if source is None:
            fake = fake_ace3(self.base / "cache")
            source = lambda: fake  # noqa: E731 - a one-line stand-in for the fetch
        client_install.install(self.layout, source, report=lines.append)
        return lines

    def test_installs_the_harness_and_both_side_addons(self) -> None:
        lines = self.install()

        harness = self.addons / "MoltenCodesBench"
        self.assertTrue((harness / "Harness.lua").is_file())
        self.assertTrue((harness / "Loader.lua").is_file())
        self.assertTrue((harness / "Installation.lua").is_file())
        self.assertTrue((harness / "modules" / "workloads" / "Dispatch.lua").is_file())
        self.assertTrue((harness / "modules" / "ClientBench.lua").is_file())
        self.assertFalse((harness / "modules" / "BenchHost.lua").exists())
        kits = self.addons / "MoltenCodesBench_Kits"
        self.assertTrue((kits / "registry" / "Registry.lua").is_file())
        self.assertTrue((kits / "LibStub" / "LibStub.lua").is_file())
        self.assertFalse(list(kits.rglob("*.md")), "the Kits side carries Lua and the licence only")
        ace = self.addons / "MoltenCodesBench_Ace3"
        for name in ace3.LOADED_FILES:
            self.assertTrue((ace / name).is_file(), name)
        self.assertIn("installed", "\n".join(lines))
        self.assert_neighbour_untouched()

    def test_every_toc_carries_the_supported_interface_line(self) -> None:
        self.install()
        line = load_supported_clients().toc_line()
        for name in ("MoltenCodesBench", "MoltenCodesBench_Kits", "MoltenCodesBench_Ace3"):
            text = (self.addons / name / f"{name}.toc").read_text(encoding="utf-8")
            self.assertEqual(line, text.splitlines()[0], name)

    def test_the_sides_load_on_demand_after_the_harness(self) -> None:
        self.install()
        for name in ("MoltenCodesBench_Kits", "MoltenCodesBench_Ace3"):
            text = (self.addons / name / f"{name}.toc").read_text(encoding="utf-8")
            self.assertIn("## LoadOnDemand: 1\n", text)
            self.assertIn("## Dependencies: MoltenCodesBench\n", text)

    def test_every_toc_file_line_names_an_installed_file(self) -> None:
        self.install()
        for name in ("MoltenCodesBench", "MoltenCodesBench_Kits", "MoltenCodesBench_Ace3"):
            folder = self.addons / name
            listed = [
                line
                for line in (folder / f"{name}.toc").read_text(encoding="utf-8").splitlines()
                if line.strip() and not line.startswith("#")
            ]
            self.assertTrue(listed)
            for line in listed:
                self.assertTrue((folder / line.replace("\\", "/")).is_file(), f"{name}: {line}")

    def test_the_kits_side_loads_libstub_first_then_the_bundle_in_order(self) -> None:
        self.install()
        text = (self.addons / "MoltenCodesBench_Kits" / "MoltenCodesBench_Kits.toc").read_text(
            encoding="utf-8"
        )
        files = [line for line in text.splitlines() if line and not line.startswith("#")]
        self.assertEqual("LibStub\\LibStub.lua", files[0])
        self.assertEqual("registry\\Registry.lua", files[1])

    def test_the_ace3_side_is_the_verified_cache_copied_verbatim(self) -> None:
        source = fake_ace3(self.base / "cache")
        self.install(ace3_source=lambda: source)
        ace = self.addons / "MoltenCodesBench_Ace3"
        for name in ace3.LOADED_FILES:
            self.assertEqual((source.directory / name).read_bytes(), (ace / name).read_bytes())
        toc = (ace / "MoltenCodesBench_Ace3.toc").read_text(encoding="utf-8")
        self.assertNotIn("LICENSE.txt", toc)

    def test_refuses_an_ace3_cache_that_changed_after_it_was_verified(self) -> None:
        source = fake_ace3(self.base / "cache")
        (source.directory / "LibStub" / "LibStub.lua").write_text("-- changed\n", encoding="utf-8")
        with self.assertRaises(client_install.BenchInstallError):
            self.install(ace3_source=lambda: source)
        self.assertFalse((self.addons / "MoltenCodesBench_Ace3").exists())
        self.assert_neighbour_untouched()

    def test_installation_lua_records_the_sides_and_the_catalogue(self) -> None:
        self.install()
        text = (self.addons / "MoltenCodesBench" / "Installation.lua").read_text(encoding="utf-8")
        self.assertIn('flavourDirectory = "_retail_"', text)
        self.assertIn('addon = "MoltenCodesBench_Kits"', text)
        self.assertIn('addon = "MoltenCodesBench_Ace3"', text)
        self.assertIn('facade = "EventKit"', text)
        self.assertIn(f'commit = "{ace3.ACE3_COMMIT}"', text)
        for workload in client_workloads.CLIENT_WORKLOADS:
            self.assertIn(f'name = "{workload.name}"', text)
        for name in client_workloads.NOT_IN_CLIENT:
            self.assertIn(f'name = "{name}"', text)
        self.assertIn("private.installationDetails", text)

    def test_a_second_install_replaces_only_its_own_folders(self) -> None:
        self.install()
        stale = self.addons / "MoltenCodesBench" / "modules" / "Stale.lua"
        stale.write_text("-- left from an older install\n", encoding="utf-8")
        lines = self.install()
        self.assertFalse(stale.exists())
        self.assertIn("replaced", "\n".join(lines))
        self.assert_neighbour_untouched()

    def test_a_dry_run_changes_and_fetches_nothing(self) -> None:
        def refuse() -> ace3.Ace3Source:
            raise AssertionError("a dry run must not fetch Ace3")

        lines: list[str] = []
        client_install.install(self.layout, refuse, dry_run=True, report=lines.append)
        self.assertEqual(["MoltenSession"], sorted(path.name for path in self.addons.iterdir()))
        self.assertIn("would install", "\n".join(lines))

    def test_the_command_refuses_a_missing_addons_folder(self) -> None:
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), contextlib.redirect_stdout(io.StringIO()):
            status = client_install.main(["--wow-dir", str(self.base / "nowhere"), "--dry-run"])
        self.assertEqual(1, status)
        self.assertIn("does not exist", stderr.getvalue())


class RemoveTests(FakeGameFolder):
    def test_removes_the_bench_addons_their_saved_variables_and_addons_txt_lines(self) -> None:
        for name in ("MoltenCodesBench", "MoltenCodesBench_Kits", "MoltenCodesBench_Ace3"):
            (self.addons / name).mkdir()
        (self.addons / "MoltenCodesTest").mkdir()
        account = self.saved_variables("ACCOUNT")
        character = self.saved_variables("ACCOUNT", "Realm", "Hero")
        for folder in (account, character):
            (folder / "MoltenCodesBench.lua").write_text("x = 1\n", encoding="utf-8")
            (folder / "MoltenCodesBench.lua.bak").write_text("x = 1\n", encoding="utf-8")
            (folder / "MoltenSession.lua").write_text("x = 1\n", encoding="utf-8")
            (folder / "MoltenCodesTest.lua").write_text("x = 1\n", encoding="utf-8")
        addons_txt = self.flavour / "WTF" / "Account" / "ACCOUNT" / "Realm" / "Hero" / "AddOns.txt"
        addons_txt.write_text(
            "MoltenSession: enabled\r\nMoltenCodesBench: enabled\r\n"
            "MoltenCodesBench_Kits: enabled\r\nMoltenCodesTest: enabled\r\n",
            encoding="utf-8",
            newline="",
        )

        lines: list[str] = []
        client_install.remove(self.layout, report=lines.append)

        self.assertEqual(
            ["MoltenCodesTest", "MoltenSession"],
            sorted(path.name for path in self.addons.iterdir()),
        )
        for folder in (account, character):
            self.assertEqual(
                ["MoltenCodesTest.lua", "MoltenSession.lua"],
                sorted(path.name for path in folder.iterdir()),
            )
        with addons_txt.open(encoding="utf-8", newline="") as handle:
            self.assertEqual(
                "MoltenSession: enabled\r\nMoltenCodesTest: enabled\r\n", handle.read()
            )
        self.assertIn("removed", "\n".join(lines))
        self.assert_neighbour_untouched()

    def test_a_dry_run_removes_nothing(self) -> None:
        (self.addons / "MoltenCodesBench").mkdir()
        lines: list[str] = []
        client_install.remove(self.layout, dry_run=True, report=lines.append)
        self.assertTrue((self.addons / "MoltenCodesBench").is_dir())
        self.assertIn("would remove", "\n".join(lines))

    def test_nothing_to_remove_says_so(self) -> None:
        lines: list[str] = []
        client_install.remove(self.layout, report=lines.append)
        self.assertEqual(["nothing to remove"], lines)

    def test_only_bench_names_are_owned(self) -> None:
        self.assertTrue(client_install.is_owned_addon("MoltenCodesBench"))
        self.assertTrue(client_install.is_owned_addon("MoltenCodesBench_Ace3"))
        for name in ("MoltenCodes", "MoltenCodesTest", "MoltenCodesTest_EventKit", "MoltenSession"):
            self.assertFalse(client_install.is_owned_addon(name), name)


class ReportTests(FakeGameFolder):
    def write_saved(
        self, entries: list[dict[str, Any]], details: dict[str, Any] | None = None
    ) -> Path:
        folder = self.saved_variables("ACCOUNT")
        results: dict[str, Any] = {"schema": 1, "entries": entries}
        if details is not None:
            results["installationDetails"] = details
        path = folder / "MoltenCodesBench.lua"
        text = "\nMoltenCodesBenchResults = " + lua_value(results) + "\n"
        path.write_text(text, encoding="utf-8")
        return path

    def standard_entries(self) -> list[dict[str, Any]]:
        frames = {
            "kind": "frames",
            "name": "idle",
            "operation": "nothing",
            "equivalent": True,
            "metrics": {"frameMillisecondsP95": 7.5, "endedByTimeLimit": True},
        }
        return [
            entry("moltencodes", "checks", cases=["encode-small"], checks=[
                {"name": "round-trip", "passed": True, "detail": "ok", "promised": True}
            ]),
            entry("ace3", "checks", cases=["encode-small", "only-ace"], checks=[]),
            entry("moltencodes", "case", "encode-small", result=small([10, 11, 12])),
            entry("ace3", "case", "encode-small", result=small([20, 21, 22])),
            entry("moltencodes", "case", "encode-small", round=2, result=small([9, 10, 11])),
            entry("ace3", "case", "only-ace", skipped="the simulated clock (host.timers)"),
            entry("moltencodes", "case", "idle", workload="session", result=frames),
        ]

    def collect(
        self, entries: list[dict[str, Any]], **details: Any
    ) -> tuple[list[dict[str, Any]], list[str]]:
        path = self.write_saved(entries, details or None)
        warnings: list[str] = []
        return client_report.collect([path], "command", warnings.append), warnings

    def test_assembles_a_client_document_per_flavour(self) -> None:
        documents, warnings = self.collect(
            self.standard_entries(),
            **{
                "2026-09-26T10:00:00Z": {
                    "packageVersions": {"codecKit": "1.2.3"},
                    "ace3": {"commit": "c0ffee"},
                }
            },
        )
        self.assertEqual([], warnings)
        self.assertEqual(1, len(documents))
        document = documents[0]
        self.assertEqual("client", document["kind"])
        self.assertEqual("retail", document["flavour"])
        self.assertEqual("2026-09-26", document["date"])
        self.assertEqual({"codecKit": "1.2.3"}, document["moltencodes"]["packageVersions"])
        self.assertEqual("c0ffee", document["ace3"]["commit"])
        self.assertEqual(
            ["codec", "session"], [workload["name"] for workload in document["workloads"]]
        )

    def test_pools_the_rounds_of_a_batch_case(self) -> None:
        documents, _ = self.collect(self.standard_entries())
        codec = documents[0]["workloads"][0]
        kit_case = codec["sides"]["moltencodes"]["cases"][0]
        self.assertEqual(2, kit_case["rounds"])
        self.assertEqual([10, 11, 12, 9, 10, 11], kit_case["nanosecondsPerOperation"])
        self.assertEqual(10.5, kit_case["medianNanoseconds"])
        self.assertEqual("batch", kit_case["kind"])

    def test_keeps_a_skipped_case_with_its_reason(self) -> None:
        documents, _ = self.collect(self.standard_entries())
        ace = documents[0]["workloads"][0]["sides"]["ace3"]
        self.assertEqual(
            [
                {
                    "name": "only-ace",
                    "status": "skipped",
                    "reason": "the simulated clock (host.timers)",
                }
            ],
            ace["notRun"],
        )

    def test_leaves_out_older_installations_and_test_builds(self) -> None:
        older = entry(
            "moltencodes", "case", "encode-small", result=batch_result("encode-small", [1])
        )
        older["installation"]["installedAt"] = "2026-09-20T10:00:00Z"
        test_build = entry("ace3", "case", "encode-small", result=batch_result("encode-small", [2]))
        test_build["client"]["testBuild"] = True
        documents, warnings = self.collect([*self.standard_entries(), older, test_build])
        kit_case = documents[0]["workloads"][0]["sides"]["moltencodes"]["cases"][0]
        self.assertNotIn(1, kit_case["nanosecondsPerOperation"])
        self.assertTrue(any("older installations" in warning for warning in warnings))
        self.assertTrue(any("test build" in warning for warning in warnings))

    def test_renders_timing_frames_checks_and_not_run(self) -> None:
        documents, _ = self.collect(self.standard_entries())
        text = client_report.render(documents[0])
        self.assertIn("| Kind | client (inside the game; never mixed with host results) |", text)
        self.assertIn("| `encode-small` |", text)
        self.assertIn("frameMillisecondsP95", text)
        self.assertIn("`only-ace` on Ace3: skipped: the simulated clock (host.timers)", text)
        self.assertIn("### Host workloads not run in the client", text)

    def test_the_two_renderers_refuse_each_others_files(self) -> None:
        documents, _ = self.collect(self.standard_entries())
        with self.assertRaises(report.ReportError):
            report.render(documents[0])
        with self.assertRaises(client_report.ClientReportError):
            client_report.render({"schema": 1, "kind": "host", "workloads": []})

    def test_writes_a_dated_file_and_never_overwrites_one(self) -> None:
        self.write_saved(self.standard_entries())
        results = self.base / "results"
        document = {"date": "2026-09-26", "flavour": "retail"}
        first = client_report.results_path(document, results)
        self.assertEqual("2026-09-26-client-retail.json", first.name)
        results.mkdir()
        first.write_text("{}", encoding="utf-8")
        second = client_report.results_path(document, results)
        self.assertEqual("2026-09-26-client-retail-2.json", second.name)

    def test_the_command_reads_the_game_folder_and_writes_the_results(self) -> None:
        self.write_saved(self.standard_entries())
        out = self.base / "out.json"
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = client_report.main(["--wow-dir", str(self.wow), "--out", str(out)])
        self.assertEqual(0, status, stderr.getvalue())
        document = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual("client", document["kind"])
        self.assertIn("### Environment", stdout.getvalue())

        rendered = io.StringIO()
        with contextlib.redirect_stdout(rendered):
            self.assertEqual(0, client_report.main(["--render", str(out)]))
        self.assertEqual(stdout.getvalue(), rendered.getvalue())

    def test_a_dry_run_writes_no_results_file(self) -> None:
        self.write_saved(self.standard_entries())
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            status = client_report.main(
                ["--wow-dir", str(self.wow), "--out", str(self.base / "out.json"), "--dry-run"]
            )
        self.assertEqual(0, status)
        self.assertFalse((self.base / "out.json").exists())

    def test_the_command_reports_a_game_folder_without_results(self) -> None:
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), contextlib.redirect_stdout(io.StringIO()):
            status = client_report.main(["--wow-dir", str(self.wow)])
        self.assertEqual(1, status)
        self.assertIn("run /mcb run", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
