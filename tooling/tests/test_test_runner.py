import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from tooling.test import run as module
from tooling.validation import validate_manifests


def fake_process(returncode: int, stdout: str = "", stderr: str = ""):
    """Model the completed Busted process the runner captures."""
    return SimpleNamespace(returncode=returncode, stdout=stdout, stderr=stderr)


class PackageFixture(unittest.TestCase):
    """Redirects the runner and manifest validator at a throwaway package tree."""

    def setUp(self):
        self.printed = ""
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.packages = self.root / "packages"
        self.packages.mkdir()

        self.shared_support = self.root / "tests" / "support"
        self.shared_support.mkdir(parents=True)
        self.examples_tests = self.root / "examples" / "tests"

        self.original_runner_root = module.ROOT
        self.original_runner_packages = module.PACKAGES
        self.original_shared_support = module.SHARED_SUPPORT
        self.original_examples_tests = module.EXAMPLES_TESTS
        self.original_validator_root = validate_manifests.ROOT
        self.original_validator_packages = validate_manifests.PACKAGES

        module.ROOT = self.root
        module.PACKAGES = self.packages
        module.SHARED_SUPPORT = self.shared_support
        module.EXAMPLES_TESTS = self.examples_tests
        validate_manifests.ROOT = self.root
        validate_manifests.PACKAGES = self.packages

    def tearDown(self):
        module.ROOT = self.original_runner_root
        module.PACKAGES = self.original_runner_packages
        module.SHARED_SUPPORT = self.original_shared_support
        module.EXAMPLES_TESTS = self.original_examples_tests
        validate_manifests.ROOT = self.original_validator_root
        validate_manifests.PACKAGES = self.original_validator_packages
        self.tempdir.cleanup()

    def create_examples(self) -> None:
        """Create the example-addon spec directory the runner also targets."""
        self.examples_tests.mkdir(parents=True, exist_ok=True)
        (self.examples_tests / "Example_spec.lua").write_text("", encoding="utf-8")

    def create_package(self, name: str, *, dependencies=None, optional_dependencies=None) -> None:
        package = self.packages / name
        (package / "src").mkdir(parents=True)
        (package / "tests" / "support").mkdir(parents=True)
        (package / "tests" / f"{name}_spec.lua").write_text("", encoding="utf-8")
        manifest = {
            "name": name,
            "displayName": name,
            "description": "test",
            "version": "1.0.0",
            "license": "MIT",
            "api": 1,
            "revision": 1,
            "dependencies": dependencies or {},
        }
        if optional_dependencies is not None:
            manifest["optionalDependencies"] = optional_dependencies
        (package / "package.manifest.json").write_text(
            json.dumps(manifest), encoding="utf-8"
        )


class TestRunnerTests(PackageFixture):
    def test_selects_all_packages_in_deterministic_order(self):
        self.create_package("zetaKit")
        self.create_package("alphaKit")
        manifests, errors = module.load_valid_manifests()
        self.assertEqual([], errors)

        selected, errors = module.select_test_packages([], manifests)

        self.assertEqual([], errors)
        self.assertEqual(["alphaKit", "zetaKit", "examples"], selected)

    def test_accepts_examples_as_an_explicit_target(self):
        self.create_package("registry")
        manifests, errors = module.load_valid_manifests()
        self.assertEqual([], errors)

        selected, errors = module.select_test_packages(["examples"], manifests)

        self.assertEqual([], errors)
        self.assertEqual(["examples"], selected)

    def test_rejects_unknown_requested_package(self):
        self.create_package("registry")
        manifests, errors = module.load_valid_manifests()
        self.assertEqual([], errors)

        selected, errors = module.select_test_packages(["missing"], manifests)

        self.assertEqual([], selected)
        self.assertTrue(any("unknown package" in error for error in errors))

    def test_resolves_transitive_runtime_dependencies(self):
        self.create_package("baseKit")
        self.create_package("signalKit", dependencies={"baseKit": {"api": 1}})
        self.create_package("eventKit", dependencies={"signalKit": {"api": 1}})
        manifests, errors = module.load_valid_manifests()
        self.assertEqual([], errors)

        packages = module.dependency_closure("eventKit", manifests)

        self.assertEqual(["baseKit", "signalKit", "eventKit"], packages)

    def test_builds_lua_path_for_source_and_support(self):
        self.create_package("registry")

        lua_path = module.build_lua_path(
            ["registry"], ["registry"], inherited="existing-path"
        )

        self.assertIn(str(self.packages / "registry" / "src" / "?.lua"), lua_path)
        self.assertIn(
            str(self.packages / "registry" / "tests" / "support" / "?.lua"),
            lua_path,
        )
        self.assertTrue(lua_path.endswith("existing-path"))

    def test_dependency_test_support_is_not_required(self):
        self.create_package("baseKit")
        self.create_package("eventKit", dependencies={"baseKit": {"api": 1}})

        lua_path = module.build_lua_path(
            ["eventKit", "baseKit"], support_packages=["eventKit"]
        )

        self.assertIn(str(self.packages / "baseKit" / "src" / "?.lua"), lua_path)
        self.assertNotIn(
            str(self.packages / "baseKit" / "tests" / "support" / "?.lua"),
            lua_path,
        )
        self.assertIn(
            str(self.packages / "eventKit" / "tests" / "support" / "?.lua"),
            lua_path,
        )

    def test_preserves_lua_default_path_when_environment_is_unset(self):
        self.create_package("registry")

        lua_path = module.build_lua_path(["registry"], ["registry"])

        self.assertTrue(lua_path.endswith(";;"))

    def test_run_uses_one_busted_process_per_selected_package(self):
        self.create_package("baseKit")
        self.create_package("eventKit", dependencies={"baseKit": {"api": 1}})

        with (
            mock.patch.object(module.shutil, "which", return_value="/fake/busted"),
            mock.patch.object(
                module.subprocess,
                "run",
                return_value=fake_process(0, "1 success / 0 failures / 0 errors / 0 pending"),
            ) as run_process,
            mock.patch("sys.stdout", io.StringIO()),
        ):
            result = module.run(["baseKit", "eventKit"])

        self.assertEqual(0, result)
        self.assertEqual(2, run_process.call_count)
        first_command = run_process.call_args_list[0].args[0]
        second_command = run_process.call_args_list[1].args[0]
        self.assertEqual(["/fake/busted", "packages/baseKit/tests"], first_command)
        self.assertEqual(["/fake/busted", "packages/eventKit/tests"], second_command)

        events_env = run_process.call_args_list[1].kwargs["env"]
        self.assertIn(str(self.packages / "eventKit" / "src" / "?.lua"), events_env["LUA_PATH"])
        self.assertIn(str(self.packages / "baseKit" / "src" / "?.lua"), events_env["LUA_PATH"])

    def test_finds_package_test_directory(self):
        self.create_package("registry")

        target, error = module.package_test_target("registry")

        self.assertIsNone(error)
        self.assertEqual(os.path.join("packages", "registry", "tests"), target)



class BustedSummaryParsingTests(unittest.TestCase):
    def test_parses_plural_summary_counts(self):
        output = "48 successes / 0 failures / 0 errors / 0 pending : 0.01 seconds"

        self.assertEqual((48, 0, 0, 0), module.parse_busted_summary(output))

    def test_parses_singular_summary_nouns(self):
        output = "1 success / 1 failure / 1 error / 1 pending : 0.01 seconds"

        self.assertEqual((1, 1, 1, 1), module.parse_busted_summary(output))

    def test_ignores_terminal_colour_codes(self):
        output = "\x1b[32m7 successes\x1b[0m / 2 failures / 1 error / 3 pending"

        self.assertEqual((7, 2, 1, 3), module.parse_busted_summary(output))

    def test_returns_none_when_no_summary_line_is_present(self):
        self.assertIsNone(module.parse_busted_summary("busted crashed before reporting"))


class AggregateRunTests(PackageFixture):
    def run_two_packages(self, first_process, second_process, examples_process=None):
        """Run two packages against fake Busted processes, capturing what is printed.

        The examples target always runs too, so a third fake process stands in
        for it unless a test wants to describe its result.
        """
        self.create_package("alphaKit")
        self.create_package("zetaKit")
        self.create_examples()

        if examples_process is None:
            examples_process = fake_process(
                0, "0 successes / 0 failures / 0 errors / 0 pending"
            )

        stdout = io.StringIO()
        with (
            mock.patch.object(module.shutil, "which", return_value="/fake/busted"),
            mock.patch.object(
                module.subprocess,
                "run",
                side_effect=[first_process, second_process, examples_process],
            ) as run_process,
            mock.patch("sys.stdout", stdout),
            mock.patch("sys.stderr", io.StringIO()),
        ):
            result = module.run([])

        self.printed = stdout.getvalue()
        return result, run_process

    def test_runs_every_package_even_after_a_failing_package(self):
        result, run_process = self.run_two_packages(
            fake_process(1, "3 successes / 2 failures / 0 errors / 0 pending"),
            fake_process(0, "5 successes / 0 failures / 0 errors / 0 pending"),
        )

        self.assertEqual(1, result)
        self.assertEqual(3, run_process.call_count)
        self.assertEqual(
            ["/fake/busted", os.path.join("packages", "alphaKit", "tests")],
            run_process.call_args_list[0].args[0],
        )
        self.assertEqual(
            ["/fake/busted", os.path.join("packages", "zetaKit", "tests")],
            run_process.call_args_list[1].args[0],
        )
        self.assertEqual(
            ["/fake/busted", os.path.join("examples", "tests")],
            run_process.call_args_list[2].args[0],
        )

    def test_reports_zero_when_every_package_passes(self):
        result, _ = self.run_two_packages(
            fake_process(0, "3 successes / 0 failures / 0 errors / 0 pending"),
            fake_process(0, "5 successes / 0 failures / 0 errors / 0 pending"),
        )

        self.assertEqual(0, result)

    def test_prints_a_per_package_table_with_totals(self):
        self.run_two_packages(
            fake_process(1, "3 successes / 2 failures / 1 error / 0 pending"),
            fake_process(0, "5 successes / 0 failures / 0 errors / 4 pending"),
        )

        self.assertIn("alphaKit", self.printed)
        self.assertIn("zetaKit", self.printed)
        self.assertIn("FAILED", self.printed)
        self.assertRegex(self.printed, r"total\s+8\s+2\s+1\s+4")

    def test_keeps_lua_path_isolated_per_package(self):
        _, run_process = self.run_two_packages(
            fake_process(0, "1 success / 0 failures / 0 errors / 0 pending"),
            fake_process(0, "1 success / 0 failures / 0 errors / 0 pending"),
        )

        alpha_path = run_process.call_args_list[0].kwargs["env"]["LUA_PATH"]
        zeta_path = run_process.call_args_list[1].kwargs["env"]["LUA_PATH"]
        alpha_support = str(self.packages / "alphaKit" / "tests" / "support" / "?.lua")
        zeta_support = str(self.packages / "zetaKit" / "tests" / "support" / "?.lua")

        self.assertIn(alpha_support, alpha_path)
        self.assertNotIn(zeta_support, alpha_path)
        self.assertIn(zeta_support, zeta_path)
        self.assertNotIn(alpha_support, zeta_path)

    def test_puts_the_shared_fixture_on_every_target_path(self):
        _, run_process = self.run_two_packages(
            fake_process(0, "1 success / 0 failures / 0 errors / 0 pending"),
            fake_process(0, "1 success / 0 failures / 0 errors / 0 pending"),
        )

        shared = str(self.shared_support / "?.lua")
        for call in run_process.call_args_list:
            self.assertIn(shared, call.kwargs["env"]["LUA_PATH"])

    def test_gives_the_examples_target_every_package_source(self):
        _, run_process = self.run_two_packages(
            fake_process(0, "1 success / 0 failures / 0 errors / 0 pending"),
            fake_process(0, "1 success / 0 failures / 0 errors / 0 pending"),
        )

        examples_path = run_process.call_args_list[2].kwargs["env"]["LUA_PATH"]

        self.assertIn(str(self.packages / "alphaKit" / "src" / "?.lua"), examples_path)
        self.assertIn(str(self.packages / "zetaKit" / "src" / "?.lua"), examples_path)
        # The example addon is not a package, so no package-owned support
        # directory belongs on its path.
        self.assertNotIn(
            str(self.packages / "alphaKit" / "tests" / "support" / "?.lua"), examples_path
        )

    def test_counts_the_examples_target_in_the_totals(self):
        self.run_two_packages(
            fake_process(0, "3 successes / 0 failures / 0 errors / 0 pending"),
            fake_process(0, "5 successes / 0 failures / 0 errors / 0 pending"),
            examples_process=fake_process(
                0, "4 successes / 0 failures / 0 errors / 0 pending"
            ),
        )

        self.assertIn("examples", self.printed)
        self.assertRegex(self.printed, r"total\s+12\s+0\s+0\s+0")

    def test_falls_back_to_exit_status_when_the_summary_cannot_be_parsed(self):
        result, _ = self.run_two_packages(
            fake_process(0, "no recognisable summary"),
            fake_process(0, "2 successes / 0 failures / 0 errors / 0 pending"),
        )

        self.assertEqual(0, result)
        self.assertRegex(self.printed, r"alphaKit\s+-\s+-\s+-\s+-\s+ok")
        self.assertNotIn("FAILED", self.printed)

    def test_missing_busted_names_a_lua_51_toolchain_source(self):
        self.create_package("alphaKit")

        with (
            mock.patch.object(module.shutil, "which", return_value=None),
            mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
        ):
            result = module.run([])

        self.assertEqual(127, result)
        message = stderr.getvalue()
        self.assertIn("hererocks", message)
        self.assertIn("5.1", message)
        self.assertIn("docs/DEVELOPMENT.md", message)


if __name__ == "__main__":
    unittest.main()


class OptionalDependencyPathTests(PackageFixture):
    """Optional dependencies, and their own closure, reach the suite's LUA_PATH."""

    def create_graph(self) -> None:
        self.create_package("registry")
        self.create_package("signalKit", dependencies={"registry": {"api": 1}})
        self.create_package(
            "eventKit", dependencies={"registry": {"api": 1}, "signalKit": {"api": 1}}
        )
        self.create_package(
            "cacheKit",
            dependencies={"registry": {"api": 1}},
            optional_dependencies={"eventKit": {"api": 1}},
        )

    def test_suite_sources_add_the_optional_closure_after_the_required_one(self):
        self.create_graph()
        manifests, errors = module.load_valid_manifests()

        self.assertEqual([], errors)
        self.assertEqual(
            ["cacheKit", "registry", "signalKit", "eventKit"],
            module.suite_source_packages("cacheKit", manifests),
        )

    def test_required_closure_alone_does_not_follow_optional_edges(self):
        self.create_graph()
        manifests, _ = module.load_valid_manifests()

        self.assertEqual(["registry", "cacheKit"], module.dependency_closure("cacheKit", manifests))

    def test_package_without_optional_dependencies_is_unchanged(self):
        self.create_graph()
        manifests, _ = module.load_valid_manifests()

        self.assertEqual(
            ["eventKit", "registry", "signalKit"],
            module.suite_source_packages("eventKit", manifests),
        )

    def test_optional_edge_back_into_the_required_chain_adds_that_chain(self):
        """eventKit optionally uses schedulerKit, which requires eventKit's dependants."""
        self.create_package("registry")
        self.create_package("signalKit", dependencies={"registry": {"api": 1}})
        self.create_package(
            "eventKit",
            dependencies={"registry": {"api": 1}, "signalKit": {"api": 1}},
            optional_dependencies={"schedulerKit": {"api": 1}},
        )
        self.create_package("lifecycleKit", dependencies={"eventKit": {"api": 1}})
        self.create_package("timerKit", dependencies={"lifecycleKit": {"api": 1}})
        self.create_package("schedulerKit", dependencies={"timerKit": {"api": 1}})
        manifests, errors = module.load_valid_manifests()

        self.assertEqual([], errors)
        self.assertEqual(
            ["eventKit", "registry", "signalKit", "lifecycleKit", "timerKit", "schedulerKit"],
            module.suite_source_packages("eventKit", manifests),
        )

    def test_run_puts_optional_sources_on_the_suite_path(self):
        self.create_graph()
        manifests, _ = module.load_valid_manifests()

        with (
            mock.patch.object(
                module.subprocess,
                "run",
                return_value=fake_process(0, "1 success / 0 failures / 0 errors / 0 pending"),
            ) as run_process,
            mock.patch("sys.stdout", io.StringIO()),
        ):
            module.run_package_suite("cacheKit", manifests, "/fake/busted", [], None)

        lua_path = run_process.call_args.kwargs["env"]["LUA_PATH"]
        for name in ("cacheKit", "registry", "signalKit", "eventKit"):
            self.assertIn(str(self.packages / name / "src" / "?.lua"), lua_path)
        self.assertLess(
            lua_path.index(str(self.packages / "registry" / "src" / "?.lua")),
            lua_path.index(str(self.packages / "eventKit" / "src" / "?.lua")),
        )
        # Only the package under test contributes its own test support.
        self.assertNotIn(str(self.packages / "eventKit" / "tests" / "support"), lua_path)
