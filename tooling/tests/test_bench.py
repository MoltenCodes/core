"""Tests for the host benchmark tooling (`tooling/bench/`).

Nothing here touches the network or runs Lua: the Ace3 fetch is given an
in-memory archive through its `transport` argument, the runner is given a fake
Lua process through its `runner` argument, and the report is fed synthetic
results. The Lua workloads themselves are exercised by running the benchmark
(`python3 -m tooling.bench.run`), which is deliberately not a unit test: it
needs the pinned Ace3 source and measures time.
"""

from __future__ import annotations

import datetime
import io
import json
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tooling.bench import ace3, host, report, run, workloads


def archive_bytes(files: dict[str, bytes], top: str = "Ace3-abc") -> bytes:
    """A `.tar.gz` holding `files` under one top directory, like a GitHub archive."""
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
        directory = tarfile.TarInfo(top)
        directory.type = tarfile.DIRTYPE
        archive.addfile(directory)
        for name, data in files.items():
            member = tarfile.TarInfo(f"{top}/{name}")
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
    return buffer.getvalue()


def ace3_files() -> dict[str, bytes]:
    """Every file the benchmark loads, with placeholder contents."""
    return {name: f"-- {name}\n".encode() for name in ace3.LOADED_FILES}


def digest_of(files: dict[str, bytes]) -> str:
    """The content digest `fetch_ace3` expects for `files`."""
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        for name, data in files.items():
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            (root / name).write_bytes(data)
        return ace3.content_digest(root)


class FakeTransport:
    """Serves one archive and records every URL requested."""

    def __init__(self, data: bytes) -> None:
        self.data = data
        self.urls: list[str] = []

    def __call__(self, url: str) -> bytes:
        self.urls.append(url)
        return self.data


class Ace3FetchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.cache = Path(self.temporary.name)
        self.files = ace3_files()
        self.digest = digest_of(self.files)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def fetch(self, transport: FakeTransport, digest: str | None = None) -> ace3.Ace3Source:
        return ace3.fetch_ace3(
            self.cache,
            transport=transport,
            expected_digest=digest or self.digest,
            today=datetime.date(2026, 9, 25),
        )

    def test_downloads_the_pinned_commit_and_records_where_it_came_from(self) -> None:
        transport = FakeTransport(archive_bytes(self.files))

        source = self.fetch(transport)

        self.assertEqual([ace3.archive_url(ace3.ACE3_COMMIT)], transport.urls)
        self.assertEqual(self.cache / "ace3" / ace3.ACE3_COMMIT, source.directory)
        self.assertTrue((source.directory / "AceTimer-3.0" / "AceTimer-3.0.lua").is_file())
        recorded = json.loads((source.directory / ace3.PROVENANCE_NAME).read_text(encoding="utf-8"))
        self.assertEqual(ace3.ACE3_COMMIT, recorded["commit"])
        self.assertEqual(self.digest, recorded["contentDigest"])
        self.assertEqual("2026-09-25", recorded["fetched"])
        self.assertNotIn("directory", source.as_json())

    def test_reuses_a_verified_cache_without_downloading(self) -> None:
        self.fetch(FakeTransport(archive_bytes(self.files)))
        second = FakeTransport(b"never read")

        source = self.fetch(second)

        self.assertEqual([], second.urls)
        self.assertEqual(self.digest, source.content_digest)

    def test_downloads_again_when_a_cached_file_changed(self) -> None:
        source = self.fetch(FakeTransport(archive_bytes(self.files)))
        (source.directory / "LibStub" / "LibStub.lua").write_text("-- edited\n", encoding="utf-8")
        transport = FakeTransport(archive_bytes(self.files))

        self.fetch(transport)

        self.assertEqual(1, len(transport.urls))
        self.assertEqual(
            b"-- LibStub/LibStub.lua\n", (source.directory / "LibStub" / "LibStub.lua").read_bytes()
        )

    def test_refuses_an_archive_that_is_not_the_pinned_source(self) -> None:
        changed = dict(self.files, **{"AceDB-3.0/AceDB-3.0.lua": b"-- something else\n"})

        with self.assertRaisesRegex(ace3.FetchError, "not the pinned source"):
            self.fetch(FakeTransport(archive_bytes(changed)))

        self.assertFalse((self.cache / "ace3" / ace3.ACE3_COMMIT).exists())
        self.assertFalse((self.cache / "ace3" / (ace3.ACE3_COMMIT + ".partial")).exists())

    def test_refuses_an_archive_missing_a_loaded_file(self) -> None:
        missing = {name: data for name, data in self.files.items() if name != "LICENSE.txt"}

        with self.assertRaisesRegex(ace3.FetchError, "lacks LICENSE.txt"):
            self.fetch(FakeTransport(archive_bytes(missing)))

    def test_refuses_a_path_outside_the_archive_top_directory(self) -> None:
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
            top = tarfile.TarInfo("Ace3-abc")
            top.type = tarfile.DIRTYPE
            archive.addfile(top)
            escape = tarfile.TarInfo("Ace3-abc/../escape.lua")
            escape.size = 1
            archive.addfile(escape, io.BytesIO(b"x"))

        with self.assertRaisesRegex(ace3.FetchError, "unsafe path"):
            self.fetch(FakeTransport(buffer.getvalue()))

    def test_refuses_a_link_in_the_archive(self) -> None:
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
            top = tarfile.TarInfo("Ace3-abc")
            top.type = tarfile.DIRTYPE
            archive.addfile(top)
            link = tarfile.TarInfo("Ace3-abc/link.lua")
            link.type = tarfile.SYMTYPE
            link.linkname = "/etc/passwd"
            archive.addfile(link)

        with self.assertRaisesRegex(ace3.FetchError, "link or special file"):
            self.fetch(FakeTransport(buffer.getvalue()))

    def test_refuses_a_cache_inside_the_repository(self) -> None:
        with self.assertRaisesRegex(ace3.FetchError, "outside the repository"):
            ace3.fetch_ace3(ace3.ROOT / "cache", transport=FakeTransport(b""))

    def test_reports_a_failed_download(self) -> None:
        def failing(url: str) -> bytes:
            raise OSError("no route to host")

        with self.assertRaisesRegex(ace3.FetchError, "no route to host"):
            ace3.fetch_ace3(self.cache, transport=failing, expected_digest=self.digest)

    def test_cache_root_prefers_the_explicit_variable_then_xdg(self) -> None:
        self.assertEqual(
            Path("/explicit"),
            ace3.default_cache_root(
                {"MOLTENCODES_BENCH_CACHE": "/explicit", "XDG_CACHE_HOME": "/xdg"}
            ),
        )
        self.assertEqual(
            Path("/xdg/moltencodes-bench"), ace3.default_cache_root({"XDG_CACHE_HOME": "/xdg"})
        )
        self.assertEqual(Path.home() / ".cache" / "moltencodes-bench", ace3.default_cache_root({}))

    def test_the_pinned_digest_is_a_sha256(self) -> None:
        self.assertRegex(ace3.EXPECTED_CONTENT_DIGEST, r"^[0-9a-f]{64}$")
        self.assertRegex(ace3.ACE3_COMMIT, r"^[0-9a-f]{40}$")


class HostTests(unittest.TestCase):
    def test_reads_the_cpu_model_on_macos(self) -> None:
        calls = []

        def runner(command):
            calls.append(list(command))
            return "Apple M5 Pro"

        self.assertEqual("Apple M5 Pro", host.cpu_model("Darwin", runner))
        self.assertEqual([["sysctl", "-n", "machdep.cpu.brand_string"]], calls)

    def test_reads_the_cpu_model_from_lscpu_on_linux(self) -> None:
        output = "Architecture:  x86_64\nModel name:    AMD EPYC 9654 96-Core Processor\n"

        self.assertEqual(
            "AMD EPYC 9654 96-Core Processor", host.cpu_model("Linux", lambda command: output)
        )

    def test_parses_proc_cpuinfo(self) -> None:
        text = "processor\t: 0\nmodel name\t: Intel(R) Xeon(R)\nflags\t: fpu\n"

        self.assertEqual("Intel(R) Xeon(R)", host.parse_cpuinfo_model(text))
        self.assertIsNone(host.parse_lscpu_model("Architecture: arm64\n"))

    def test_an_unknown_system_has_no_cpu_model(self) -> None:
        self.assertIsNone(host.cpu_model("Plan9", lambda command: "never"))

    def test_describes_the_repository_with_read_only_git_commands(self) -> None:
        commands = []

        def runner(command):
            commands.append(list(command))
            return "abc123" if command[1] == "rev-parse" else ""

        described = host.describe_repository(["timerKit"], runner)

        self.assertEqual("abc123", described["commit"])
        self.assertFalse(described["packagesModified"])
        self.assertRegex(described["packageVersions"]["timerKit"], r"^\d+\.\d+\.\d+$")
        self.assertEqual(
            [["git", "rev-parse", "HEAD"], ["git", "status", "--porcelain", "--", "packages"]],
            commands,
        )

    def test_an_unreadable_git_state_is_recorded_as_unknown(self) -> None:
        described = host.describe_repository([], lambda command: None)

        self.assertIsNone(described["commit"])
        self.assertIsNone(described["packagesModified"])


class WorkloadCatalogueTests(unittest.TestCase):
    def test_every_workload_has_its_lua_module(self) -> None:
        for workload in workloads.WORKLOADS:
            with self.subTest(workload=workload.name):
                self.assertTrue(workload.lua_file.is_file(), workload.lua_file)

    def test_the_lua_entry_point_names_exactly_the_catalogued_workloads(self) -> None:
        main = (workloads.LUA_ROOT / "main.lua").read_text(encoding="utf-8")
        table = main[
            main.index("local WORKLOADS = {") : main.index("}", main.index("local WORKLOADS = {"))
        ]
        named = dict(
            (line.split("=")[0].strip(), line.split("=")[1].strip().strip(",").strip('"'))
            for line in table.splitlines()[1:]
            if "=" in line
        )

        self.assertEqual(
            {workload.name: workload.module for workload in workloads.WORKLOADS}, named
        )

    def test_every_measured_package_exists(self) -> None:
        for workload in workloads.WORKLOADS:
            for package in workload.packages:
                with self.subTest(workload=workload.name, package=package):
                    self.assertTrue((run.PACKAGES / package / "package.manifest.json").is_file())


def case_document(name: str, samples: list[float], equivalent: bool = True, **extra) -> dict:
    """One case result as a Lua process prints it."""
    ordered = sorted(samples)
    middle = len(ordered) // 2
    median = ordered[middle] if len(ordered) % 2 else (ordered[middle - 1] + ordered[middle]) / 2
    document = {
        "name": name,
        "operation": f"do {name}",
        "equivalent": equivalent,
        "iterations": 10,
        "warmup": 0,
        "repetitions": len(samples),
        "nanosecondsPerOperation": samples,
        "medianNanoseconds": median,
        "minimumNanoseconds": min(samples),
        "allocatedBytesPerOperation": 0,
    }
    document.update(extra)
    return document


class FakeLua:
    """Answers the runner's Lua processes from canned documents."""

    def __init__(self) -> None:
        self.commands: list[list[str]] = []

    def __call__(self, command, environment):
        command = list(command)
        self.commands.append(command)
        if "-e" in command:
            return 0, "0.8000", ""
        options = dict(zip(command[2::2], command[3::2]))
        side, mode = options["--side"], options["--mode"]
        libraries = [{"name": f"{side}-library", "revision": 1}]
        if mode == "list":
            document = {"cases": ["alpha", "beta"], "libraries": libraries}
        elif mode == "checks":
            document = {
                "checks": [{"name": "ok", "passed": True, "detail": "", "promised": True}],
                "libraries": libraries,
            }
        else:
            document = case_document(options["--case"], [100.0, 110.0, 105.0])
            document["libraries"] = libraries
        return 0, json.dumps(document) + "\n", ""


class RunnerTests(unittest.TestCase):
    def session(self, fake: FakeLua) -> run.Session:
        return run.Session(
            Path("/fake/lua"),
            Path("/cache/ace3"),
            warmup=1,
            repetitions=3,
            runner=fake,
            environment={"LUA_PATH": "x"},
            progress=lambda message: None,
        )

    def test_runs_one_process_per_case_and_side(self) -> None:
        fake = FakeLua()

        result = self.session(fake).run_workload(workloads.BY_NAME["timers"])

        self.assertEqual(["moltencodes", "ace3"], list(result["sides"]))
        side = result["sides"]["ace3"]
        self.assertEqual(["alpha", "beta"], [case["name"] for case in side["cases"]])
        self.assertNotIn("libraries", side["cases"][0])
        self.assertEqual([{"name": "ace3-library", "revision": 1}], side["libraries"])
        case_commands = [command for command in fake.commands if "--case" in command]
        self.assertEqual(4, len(case_commands))
        self.assertIn("--repetitions", case_commands[0])
        self.assertEqual("3", case_commands[0][case_commands[0].index("--repetitions") + 1])

    def test_interleaves_the_sides_and_alternates_which_goes_first(self) -> None:
        fake = FakeLua()

        self.session(fake).run_workload(workloads.BY_NAME["timers"])

        order = [
            (command[command.index("--case") + 1], command[command.index("--side") + 1])
            for command in fake.commands
            if "--case" in command
        ]
        self.assertEqual(
            [
                ("alpha", "moltencodes"),
                ("alpha", "ace3"),
                ("beta", "ace3"),
                ("beta", "moltencodes"),
            ],
            order,
        )

    def test_rounds_pool_their_batches_and_alternate_the_first_side(self) -> None:
        fake = FakeLua()
        session = self.session(fake)
        session.rounds = 2

        result = session.run_workload(workloads.BY_NAME["timers"])

        alpha = result["sides"]["moltencodes"]["cases"][0]
        self.assertEqual(2, alpha["rounds"])
        self.assertEqual([100.0, 110.0, 105.0, 100.0, 110.0, 105.0], alpha["nanosecondsPerOperation"])
        self.assertEqual(105.0, alpha["medianNanoseconds"])
        firsts = [
            command[command.index("--side") + 1]
            for command in fake.commands
            if "--case" in command and command[command.index("--case") + 1] == "alpha"
        ]
        self.assertEqual(["moltencodes", "ace3", "ace3", "moltencodes"], firsts)

    def test_merging_rounds_takes_the_median_allocation_and_the_first_metrics(self) -> None:
        rounds = [
            case_document("x", [1.0, 9.0], allocatedBytesPerOperation=10, metrics={"m": 1}),
            case_document("x", [5.0], allocatedBytesPerOperation=30, metrics={"m": 2}),
            case_document("x", [3.0], allocatedBytesPerOperation=20, metrics={"m": 3}),
        ]

        merged = run.merge_rounds(rounds)

        self.assertEqual([1.0, 9.0, 5.0, 3.0], merged["nanosecondsPerOperation"])
        self.assertEqual(4.0, merged["medianNanoseconds"])
        self.assertEqual(1.0, merged["minimumNanoseconds"])
        self.assertEqual(20, merged["allocatedBytesPerOperation"])
        self.assertEqual({"m": 1}, merged["metrics"])
        self.assertEqual(3, merged["rounds"])

    def test_a_case_one_side_lacks_is_measured_on_the_other_only(self) -> None:
        fake = FakeLua()

        def runner(command, environment):
            status, stdout, stderr = fake(command, environment)
            if "list" in command and "moltencodes" in command:
                document = json.loads(stdout)
                document["cases"].append("kit-only")
                stdout = json.dumps(document) + "\n"
            return status, stdout, stderr

        result = self.session(runner).run_workload(workloads.BY_NAME["timers"])

        self.assertEqual(
            ["alpha", "beta", "kit-only"],
            [case["name"] for case in result["sides"]["moltencodes"]["cases"]],
        )
        self.assertEqual(
            ["alpha", "beta"], [case["name"] for case in result["sides"]["ace3"]["cases"]]
        )
        self.assertNotIn("listed", result["sides"]["ace3"])

    def test_a_failing_process_names_the_workload_side_and_case(self) -> None:
        session = self.session(lambda command, environment: (1, "", "lua: boom"))

        with self.assertRaisesRegex(run.BenchError, "timers/moltencodes/list failed: lua: boom"):
            session.run_workload(workloads.BY_NAME["timers"])

    def test_output_must_be_exactly_one_json_object(self) -> None:
        with self.assertRaisesRegex(run.BenchError, "expected one JSON line"):
            run.parse_document("{}\n{}\n", "context")
        with self.assertRaisesRegex(run.BenchError, "not JSON"):
            run.parse_document("not json\n", "context")
        with self.assertRaisesRegex(run.BenchError, "not a JSON object"):
            run.parse_document("[1]\n", "context")

    def test_selects_workloads_in_catalogue_order(self) -> None:
        selected = run.select_workloads(["comm", "timers"])

        self.assertEqual(["timers", "comm"], [workload.name for workload in selected])
        self.assertEqual(list(workloads.WORKLOADS), run.select_workloads([]))
        with self.assertRaisesRegex(run.BenchError, "unknown workload nope"):
            run.select_workloads(["nope"])

    def test_the_lua_path_starts_with_the_bench_modules_then_every_kit_and_the_fixture(
        self,
    ) -> None:
        environment = run.lua_environment({"PATH": "/bin"})
        segments = environment["LUA_PATH"].split(";")

        self.assertEqual(str(workloads.LUA_ROOT / "?.lua"), segments[0])
        self.assertIn(str(run.PACKAGES / "timerKit" / "src" / "?.lua"), segments)
        self.assertIn(str(run.ROOT / "tests" / "support" / "?.lua"), segments)

    def test_refuses_a_missing_interpreter(self) -> None:
        with self.assertRaisesRegex(run.BenchError, "no Lua 5.1 interpreter"):
            run.resolve_lua(Path("/definitely/not/lua"))

    def test_assembles_the_results_document(self) -> None:
        fake = FakeLua()
        source = ace3.Ace3Source(
            Path("/cache"), ace3.ACE3_COMMIT, "https://example", "aa", "bb", "2026-09-25"
        )

        with (
            mock.patch.object(host, "describe_host", return_value={"cpu": "Test CPU"}),
            mock.patch.object(
                host, "describe_repository", return_value={"commit": "abc"}
            ) as repository,
        ):
            document = run.run(
                [workloads.BY_NAME["codec"]],
                self.session(fake),
                source,
                "Lua 5.1.5",
                "python3 -m tooling.bench.run",
                today=datetime.date(2026, 9, 25),
            )

        self.assertEqual(run.RESULTS_SCHEMA, document["schema"])
        self.assertEqual("host", document["kind"])
        self.assertEqual({"cpu": "Test CPU"}, document["host"])
        self.assertEqual(0.8, document["settings"]["loopOverheadNanoseconds"])
        self.assertEqual(3, document["settings"]["timedBatches"])
        self.assertEqual(ace3.ACE3_COMMIT, document["ace3"]["commit"])
        repository.assert_called_once_with(["codecKit", "poolKit", "registry"])
        self.assertEqual(["codec"], [workload["name"] for workload in document["workloads"]])

    def test_rejects_a_repeat_count_below_one(self) -> None:
        for option in ("--repeat", "--rounds"):
            with self.subTest(option=option):
                with mock.patch("sys.stderr", io.StringIO()), self.assertRaises(SystemExit):
                    run.parse_args([option, "0"])


def results_document() -> dict:
    """A small results file with every kind of row the report prints."""
    return {
        "schema": run.RESULTS_SCHEMA,
        "kind": "host",
        "date": "2026-09-25",
        "command": "python3 -m tooling.bench.run",
        "host": {
            "cpu": "Test CPU",
            "logicalCpus": 8,
            "memoryBytes": 2**34,
            "os": "TestOS 1",
            "architecture": "arm64",
        },
        "lua": {"version": "Lua 5.1.5"},
        "settings": {
            "warmupBatches": 2,
            "timedBatches": 3,
            "clock": "os.clock",
            "loopOverheadNanoseconds": 0.8,
            "loadAverageAtStart": [1.0, 2.0, 3.0],
        },
        "moltencodes": {"commit": "abc", "packagesModified": False},
        "ace3": {"repository": "WoWUIDev/Ace3", "commit": "def"},
        "workloads": [
            {
                "name": "timers",
                "title": "Timers",
                "compares": "TimerKit against AceTimer-3.0",
                "sides": {
                    "moltencodes": {
                        "libraries": [{"name": "TimerKit", "revision": 9}],
                        "checks": [
                            {"name": "order", "passed": True, "detail": "ok", "promised": True}
                        ],
                        "cases": [
                            case_document("faster", [10.0, 11.0, 12.0]),
                            case_document("slower", [200.0, 210.0, 220.0], metrics={"pending": 0}),
                            case_document("noise", [100.0, 120.0, 110.0]),
                            case_document(
                                "different",
                                [5.0, 5.0, 5.0],
                                equivalent=False,
                                note="not the same work",
                            ),
                            case_document("kit-only", [7.0, 7.0, 7.0]),
                        ],
                    },
                    "ace3": {
                        "libraries": [{"name": "AceTimer-3.0", "minor": 17}],
                        "checks": [
                            {"name": "order", "passed": False, "detail": "1 3 2", "promised": False}
                        ],
                        "cases": [
                            case_document("faster", [20.0, 21.0, 22.0]),
                            case_document(
                                "slower", [100.0, 101.0, 102.0], metrics={"pending": 1000}
                            ),
                            case_document("noise", [105.0, 115.0, 110.0]),
                            case_document("different", [9.0, 9.0, 9.0], equivalent=False),
                        ],
                    },
                },
            }
        ],
    }


class ReportTests(unittest.TestCase):
    def test_prints_ratio_and_verdict_only_for_comparable_cases(self) -> None:
        text = report.render(results_document())

        self.assertIn(
            "| `faster` | do faster | 11.0 [10.0–12.0] | 21.0 [20.0–22.0] | 0.52× (min 0.50×, faster) |", text
        )
        self.assertIn("2.08× (min 2.00×, slower)", text)
        self.assertIn("1.00× (min 0.95×, within noise)", text)
        self.assertIn(
            "| `different` | do different | 5.0 [5.0–5.0] | 9.0 [9.0–9.0] | different work |", text
        )
        self.assertIn("one side only", text)
        self.assertIn("- `different`: not the same work", text)

    def test_summarises_verdicts_and_failed_promises(self) -> None:
        text = report.render(results_document())

        self.assertIn("MoltenCodes faster in 1, slower in 1, within noise in 1.", text)
        self.assertIn("Every check of promised behaviour passed on both sides.", text)
        self.assertIn("fail (not promised): 1 3 2", text)

        document = results_document()
        document["workloads"][0]["sides"]["ace3"]["checks"][0]["promised"] = True
        self.assertIn(
            "Failed checks of promised behaviour: timers / Ace3 / `order`.", report.render(document)
        )

    def test_prints_the_environment_and_the_extra_measurements(self) -> None:
        text = report.render(results_document())

        self.assertIn("| CPU | Test CPU (8 logical CPUs) |", text)
        self.assertIn("1.00 / 2.00 / 3.00 at the start, — at the end", text)
        self.assertIn("| Memory | 16 GiB |", text)
        self.assertIn("commit `abc`, packages/ unmodified", text)
        self.assertIn("| `slower` | pending | 0 | 1,000 |", text)
        self.assertIn(
            "Libraries: MoltenCodes: TimerKit revision 9; Ace3: AceTimer-3.0 minor 17.", text
        )

    def test_refuses_another_schema(self) -> None:
        document = results_document()
        document["schema"] = 99

        with self.assertRaisesRegex(report.ReportError, "unsupported results schema 99"):
            report.render(document)

    def test_main_writes_the_report_to_a_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory) / "results.json"
            results.write_text(json.dumps(results_document()), encoding="utf-8")
            output = Path(directory) / "report.md"

            status = report.main([str(results), "--out", str(output)])

            self.assertEqual(0, status)
            self.assertTrue(output.read_text(encoding="utf-8").startswith("### Environment"))

    def test_main_reports_an_unreadable_file(self) -> None:
        with mock.patch("sys.stderr", io.StringIO()) as errors:
            status = report.main(["/definitely/missing.json"])

        self.assertEqual(1, status)
        self.assertIn("missing.json", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
