"""Tests for the release-artifact builder."""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

from tooling.package import build as module
from tooling.package import toc
from tooling.validation import validate_manifests


LICENSE_TEXT = "MIT License\n"


class LoadOrderTests(unittest.TestCase):
    def test_dependencies_come_before_their_dependants(self):
        manifests = {
            "registry": {"dependencies": {}},
            "signalKit": {"dependencies": {"registry": {"api": 2}}},
            "eventKit": {"dependencies": {"registry": {"api": 2}, "signalKit": {"api": 1}}},
        }

        self.assertEqual(
            ["registry", "signalKit", "eventKit"],
            module.load_order(["eventKit"], manifests),
        )

    def test_every_package_appears_once(self):
        manifests = {
            "registry": {"dependencies": {}},
            "signalKit": {"dependencies": {"registry": {"api": 2}}},
            "poolKit": {"dependencies": {"registry": {"api": 2}}},
        }

        ordered = module.load_order(["signalKit", "poolKit"], manifests)

        self.assertEqual(sorted(ordered), sorted(set(ordered)))
        self.assertEqual("registry", ordered[0])


class TemporaryRepositoryTests(unittest.TestCase):
    """Fixture for every builder test: a repository made for one test, never the real one."""

    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name) / "repository"
        self.packages = self.root / "packages"
        self.packages.mkdir(parents=True)
        (self.root / "LICENSE").write_text(LICENSE_TEXT, encoding="utf-8")

        self.output = Path(self.tempdir.name) / "out"
        self.output.mkdir()

        self.original_root = validate_manifests.ROOT
        self.original_packages = validate_manifests.PACKAGES
        self.original_build_root = module.ROOT
        validate_manifests.ROOT = self.root
        validate_manifests.PACKAGES = self.packages
        module.ROOT = self.root

    def tearDown(self):
        validate_manifests.ROOT = self.original_root
        validate_manifests.PACKAGES = self.original_packages
        module.ROOT = self.original_build_root
        self.tempdir.cleanup()

    def write_package(
        self,
        name: str,
        *,
        facade: str,
        dependencies=None,
        optional_dependencies=None,
        distribution=None,
        license_name: str | None = "MIT",
        with_api_doc: bool = True,
    ) -> Path:
        package_dir = self.packages / name
        (package_dir / "src").mkdir(parents=True)
        (package_dir / "docs").mkdir()
        (package_dir / "tests").mkdir()
        (package_dir / "src" / f"{facade}.lua").write_text("return {}\n", encoding="utf-8")
        (package_dir / "src" / ".luarc.json").write_text("{}\n", encoding="utf-8")
        (package_dir / "README.md").write_text(f"# {facade}\n", encoding="utf-8")
        (package_dir / "CHANGELOG.md").write_text("# Changelog\n", encoding="utf-8")
        (package_dir / "tests" / f"{name}_spec.lua").write_text("", encoding="utf-8")
        if with_api_doc:
            (package_dir / "docs" / "API.md").write_text("# API\n", encoding="utf-8")

        manifest = {
            "name": name,
            "displayName": facade,
            "description": f"{facade} package",
            "version": "1.2.3",
            "dependencies": dependencies or {},
            "api": 1,
            "revision": 4,
        }
        if license_name is not None:
            manifest["license"] = license_name
        if optional_dependencies is not None:
            manifest["optionalDependencies"] = optional_dependencies
        if distribution is not None:
            manifest["distribution"] = distribution
        (package_dir / "package.manifest.json").write_text(
            json.dumps(manifest), encoding="utf-8"
        )
        return package_dir

    def write_minimal_repository(self):
        self.write_package("registry", facade="Registry")
        self.write_package(
            "signalKit", facade="SignalKit", dependencies={"registry": {"api": 1}}
        )


class BuildTests(TemporaryRepositoryTests):
    """What the builder puts in a bundle, and what it refuses to build."""

    def test_builds_every_package_by_default(self):
        self.write_minimal_repository()

        manifest = module.build(self.output)

        bundle = self.output / "MoltenCodes"
        self.assertTrue((bundle / "registry" / "Registry.lua").is_file())
        self.assertTrue((bundle / "signalKit" / "SignalKit.lua").is_file())
        self.assertTrue((bundle / "LICENSE").is_file())
        self.assertEqual(
            ["registry/Registry.lua", "signalKit/SignalKit.lua"], manifest["loadOrder"]
        )
        self.assertIsNone(manifest["subject"])

    def test_copies_package_documentation_beside_the_source(self):
        self.write_minimal_repository()

        module.build(self.output)

        package = self.output / "MoltenCodes" / "registry"
        self.assertTrue((package / "README.md").is_file())
        self.assertTrue((package / "CHANGELOG.md").is_file())
        self.assertTrue((package / "API.md").is_file())

    def test_excludes_editor_configuration_from_the_artifact(self):
        self.write_minimal_repository()

        module.build(self.output)

        self.assertFalse((self.output / "MoltenCodes" / "registry" / ".luarc.json").exists())

    def test_single_package_build_includes_its_dependencies(self):
        self.write_minimal_repository()

        manifest = module.build(self.output, package_name="signalKit")

        bundle = self.output / "MoltenCodes-SignalKit"
        self.assertEqual("MoltenCodes-SignalKit", manifest["bundle"])
        self.assertIn("MoltenCodes-SignalKit", [path.name for path in self.output.iterdir()])
        self.assertTrue((bundle / "registry" / "Registry.lua").is_file())
        self.assertEqual("signalKit", manifest["subject"])
        self.assertEqual("subject", manifest["packages"]["signalKit"]["role"])
        self.assertEqual("dependency", manifest["packages"]["registry"]["role"])

    def test_manifest_records_versions_revisions_and_licences(self):
        self.write_minimal_repository()

        manifest = module.build(self.output)

        entry = manifest["packages"]["signalKit"]
        self.assertEqual("1.2.3", entry["version"])
        self.assertEqual(1, entry["api"])
        self.assertEqual(4, entry["revision"])
        self.assertEqual("MIT", entry["license"])

    def write_repository_with_an_optional_dependency(self):
        self.write_minimal_repository()
        self.write_package(
            "cacheKit",
            facade="CacheKit",
            dependencies={"registry": {"api": 1}},
            optional_dependencies={"signalKit": {"api": 1}},
        )

    def test_single_package_build_does_not_ship_optional_dependencies(self):
        self.write_repository_with_an_optional_dependency()

        manifest = module.build(self.output, package_name="cacheKit")

        bundle = self.output / "MoltenCodes-CacheKit"
        self.assertFalse((bundle / "signalKit").exists())
        self.assertEqual(["cacheKit", "registry"], sorted(manifest["packages"]))
        self.assertEqual(
            ["registry/Registry.lua", "cacheKit/CacheKit.lua"], manifest["loadOrder"]
        )

    def test_load_order_ignores_optional_dependencies(self):
        manifests = {
            "registry": {"dependencies": {}},
            "cacheKit": {
                "dependencies": {"registry": {"api": 1}},
                "optionalDependencies": {"zetaKit": {"api": 1}},
            },
            "zetaKit": {"dependencies": {"registry": {"api": 1}}},
        }

        self.assertEqual(["registry", "cacheKit"], module.load_order(["cacheKit"], manifests))

    def test_manifest_records_optional_dependencies_for_information(self):
        self.write_repository_with_an_optional_dependency()

        manifest = module.build(self.output)

        self.assertEqual(
            {"signalKit": {"api": 1}}, manifest["packages"]["cacheKit"]["optionalDependencies"]
        )
        self.assertEqual({}, manifest["packages"]["registry"]["optionalDependencies"])

    def write_repository_with_a_development_package(self):
        self.write_minimal_repository()
        self.write_package(
            "testKit",
            facade="TestKit",
            dependencies={"signalKit": {"api": 1}},
            distribution="development",
        )

    def test_all_skips_development_packages_and_records_them(self):
        self.write_repository_with_a_development_package()

        manifest = module.build(self.output)

        self.assertNotIn("testKit", manifest["packages"])
        self.assertFalse((self.output / "MoltenCodes" / "testKit").exists())
        self.assertEqual(["testKit"], manifest["skipped"])
        written = json.loads((self.output / "MoltenCodes" / "manifest.json").read_text())
        self.assertEqual(["testKit"], written["skipped"])

    def test_all_without_development_packages_skips_nothing(self):
        self.write_minimal_repository()

        self.assertEqual([], module.build(self.output)["skipped"])

    def test_building_a_development_package_is_refused(self):
        self.write_repository_with_a_development_package()

        with self.assertRaisesRegex(module.BuildError, "development packages are tested but never bundled"):
            module.build(self.output, package_name="testKit")

    def test_command_line_reports_skipped_packages(self):
        self.write_repository_with_a_development_package()

        with mock.patch("sys.stdout", io.StringIO()) as output:
            status = module.main(["--all", "--out", str(self.output)])

        self.assertEqual(0, status)
        self.assertIn("testKit skipped (development package, never bundled)", output.getvalue())

    def test_checksums_cover_every_artifact_file(self):
        self.write_minimal_repository()

        module.build(self.output)

        checksums = (self.output / "CHECKSUMS.txt").read_text(encoding="utf-8").splitlines()
        recorded = {line.split("  ", 1)[1]: line.split("  ", 1)[0] for line in checksums}

        bundle = self.output / "MoltenCodes"
        expected = {
            path.relative_to(self.output).as_posix()
            for path in bundle.rglob("*")
            if path.is_file()
        }
        self.assertEqual(expected, set(recorded))

        digest = hashlib.sha256((bundle / "LICENSE").read_bytes()).hexdigest()
        self.assertEqual(digest, recorded["MoltenCodes/LICENSE"])

    def test_checksums_are_sorted(self):
        self.write_minimal_repository()

        module.build(self.output)

        paths = [
            line.split("  ", 1)[1]
            for line in (self.output / "CHECKSUMS.txt").read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual(sorted(paths), paths)

    def test_zip_is_reproducible(self):
        self.write_minimal_repository()

        module.build(self.output, create_zip=True)
        first = (self.output / "MoltenCodes.zip").read_bytes()
        module.build(self.output, create_zip=True)
        second = (self.output / "MoltenCodes.zip").read_bytes()

        self.assertEqual(first, second)
        with zipfile.ZipFile(self.output / "MoltenCodes.zip") as archive:
            self.assertIn("MoltenCodes/registry/Registry.lua", archive.namelist())

    def test_rebuild_replaces_the_previous_bundle(self):
        self.write_minimal_repository()
        module.build(self.output)
        stale = self.output / "MoltenCodes" / "registry" / "Stale.lua"
        stale.write_text("stale\n", encoding="utf-8")

        module.build(self.output)

        self.assertFalse(stale.exists())

    def test_missing_licence_is_reported(self):
        self.write_package("registry", facade="Registry", license_name=None)

        with self.assertRaises(module.BuildError) as failure:
            module.build(self.output)

        self.assertIn("license", str(failure.exception))

    def test_unknown_package_is_reported(self):
        self.write_minimal_repository()

        with self.assertRaises(module.BuildError) as failure:
            module.build(self.output, package_name="ghostKit")

        self.assertIn("ghostKit", str(failure.exception))

    def test_invalid_metadata_fails_the_build(self):
        self.write_minimal_repository()
        (self.packages / "orphan").mkdir()

        with self.assertRaises(module.BuildError) as failure:
            module.build(self.output)

        self.assertIn("package metadata is invalid", str(failure.exception))

    def test_missing_repository_licence_file_is_reported(self):
        self.write_minimal_repository()
        (self.root / "LICENSE").unlink()

        with self.assertRaises(module.BuildError) as failure:
            module.build(self.output)

        self.assertIn("LICENSE", str(failure.exception))


class TocModuleTests(unittest.TestCase):
    """The rendering and reading rules in `tooling.package.toc`."""

    def test_addon_names(self):
        self.assertEqual("MoltenCodes", toc.addon_name())
        self.assertEqual("MoltenCodes-TimerKit", toc.addon_name("TimerKit"))

    def test_entries_use_backslashes_and_convert_back(self):
        entry = toc.toc_entry("timerKit", "TimerKit.lua")

        self.assertEqual("timerKit\\TimerKit.lua", entry)
        self.assertEqual("timerKit/TimerKit.lua", toc.entry_to_bundle_path(entry))

    def test_notes_name_the_kit_of_a_single_kit_addon(self):
        self.assertTrue(toc.addon_notes().startswith("The MoltenCodes framework"))
        self.assertTrue(toc.addon_notes("TimerKit").startswith("TimerKit from the MoltenCodes"))

    def test_render_puts_the_interface_first_and_the_files_last(self):
        text = toc.render_toc(
            name="MoltenCodes",
            notes="Notes.",
            interface_line="## Interface: 1, 2",
            entries=["registry\\Registry.lua", "signalKit\\SignalKit.lua"],
        )
        lines = text.splitlines()

        self.assertEqual("## Interface: 1, 2", lines[0])
        self.assertEqual(["registry\\Registry.lua", "signalKit\\SignalKit.lua"], lines[-2:])
        self.assertTrue(text.endswith("\n"))

    def test_listed_files_skip_fields_comments_and_blank_lines(self):
        text = "## Title: X\n# comment\n\n  a\\A.lua  \nb\\B.lua\n"

        self.assertEqual(["a\\A.lua", "b\\B.lua"], toc.listed_files(text))


class BundleTocTests(TemporaryRepositoryTests):
    """Every bundle is an installable addon with a generated `.toc`."""

    def test_all_writes_moltencodes_toc_into_the_bundle_root(self):
        self.write_minimal_repository()

        manifest = module.build(self.output)

        path = self.output / "MoltenCodes" / "MoltenCodes.toc"
        self.assertTrue(path.is_file())
        self.assertEqual("MoltenCodes.toc", manifest["toc"])
        text = path.read_text(encoding="utf-8")
        self.assertIn("## Title: MoltenCodes", text.splitlines())
        self.assertEqual(
            ["registry\\Registry.lua", "signalKit\\SignalKit.lua"], toc.listed_files(text)
        )

    def test_package_writes_a_toc_named_after_the_facade(self):
        self.write_minimal_repository()

        manifest = module.build(self.output, package_name="signalKit")

        path = self.output / "MoltenCodes-SignalKit" / "MoltenCodes-SignalKit.toc"
        self.assertEqual("MoltenCodes-SignalKit.toc", manifest["toc"])
        text = path.read_text(encoding="utf-8")
        self.assertIn("## Title: MoltenCodes-SignalKit", text.splitlines())
        self.assertIn("## Notes: SignalKit from the MoltenCodes framework", text)

    def test_the_toc_leaves_out_development_packages(self):
        self.write_package("registry", facade="Registry")
        self.write_package(
            "testKit",
            facade="TestKit",
            dependencies={"registry": {"api": 1}},
            distribution="development",
        )

        module.build(self.output)

        text = (self.output / "MoltenCodes" / "MoltenCodes.toc").read_text(encoding="utf-8")
        self.assertEqual(["registry\\Registry.lua"], toc.listed_files(text))

    def test_the_toc_is_checksummed_and_recorded(self):
        self.write_minimal_repository()

        module.build(self.output)

        checksums = (self.output / "CHECKSUMS.txt").read_text(encoding="utf-8")
        self.assertIn("  MoltenCodes/MoltenCodes.toc\n", checksums)
        written = json.loads((self.output / "MoltenCodes" / "manifest.json").read_text())
        self.assertEqual("MoltenCodes.toc", written["toc"])

    def test_the_toc_carries_the_supported_interface_line(self):
        from tooling.validation.interface_numbers import load_supported_clients

        self.write_minimal_repository()
        module.build(self.output)

        text = (self.output / "MoltenCodes" / "MoltenCodes.toc").read_text(encoding="utf-8")
        self.assertEqual(load_supported_clients().toc_line(), text.splitlines()[0])

    def test_a_fresh_bundle_verifies(self):
        self.write_minimal_repository()
        module.build(self.output)

        self.assertEqual([], module.verify_toc(self.output / "MoltenCodes"))

    def test_verify_reports_a_lua_file_the_toc_does_not_load(self):
        self.write_minimal_repository()
        module.build(self.output)
        (self.output / "MoltenCodes" / "registry" / "Extra.lua").write_text("", encoding="utf-8")

        problems = module.verify_toc(self.output / "MoltenCodes")

        self.assertEqual(1, len(problems))
        self.assertIn("does not load registry/Extra.lua", problems[0])

    def test_verify_reports_a_listed_file_that_is_missing(self):
        self.write_minimal_repository()
        module.build(self.output)
        (self.output / "MoltenCodes" / "signalKit" / "SignalKit.lua").unlink()

        problems = module.verify_toc(self.output / "MoltenCodes")

        self.assertEqual(1, len(problems))
        self.assertIn(
            "loads signalKit/SignalKit.lua, which the bundle does not contain", problems[0]
        )

    def test_verify_reports_a_toc_out_of_load_order(self):
        self.write_minimal_repository()
        module.build(self.output)
        path = self.output / "MoltenCodes" / "MoltenCodes.toc"
        lines = path.read_text(encoding="utf-8").splitlines()
        lines[-2], lines[-1] = lines[-1], lines[-2]
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")

        problems = module.verify_toc(self.output / "MoltenCodes")

        self.assertEqual(1, len(problems))
        self.assertIn("but the load order is", problems[0])

    def test_verify_reports_a_missing_toc(self):
        self.write_minimal_repository()
        module.build(self.output)
        (self.output / "MoltenCodes" / "MoltenCodes.toc").unlink()

        self.assertIn("missing from the bundle", module.verify_toc(self.output / "MoltenCodes")[0])

    def test_verify_reports_a_toc_named_unlike_the_folder(self):
        self.write_minimal_repository()
        module.build(self.output)
        manifest_path = self.output / "MoltenCodes" / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["toc"] = "Other.toc"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

        problems = module.verify_toc(self.output / "MoltenCodes")

        self.assertEqual(1, len(problems))
        self.assertIn("the client only loads MoltenCodes.toc", problems[0])

    def test_verify_reports_a_missing_manifest(self):
        self.write_minimal_repository()
        module.build(self.output)
        (self.output / "MoltenCodes" / "manifest.json").unlink()

        self.assertIn("cannot find the .toc", module.verify_toc(self.output / "MoltenCodes")[0])

    def test_command_line_verify_fails_on_a_toc_problem(self):
        self.write_minimal_repository()

        errors = io.StringIO()
        with mock.patch.object(module, "verify_toc", return_value=["broken toc"]):
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(errors):
                status = module.main(["--all", "--out", str(self.output), "--verify"])

        self.assertEqual(1, status)
        self.assertIn(".toc verification failed", errors.getvalue())
        self.assertIn("broken toc", errors.getvalue())

    def test_command_line_verify_reports_the_toc(self):
        self.write_minimal_repository()

        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = module.main(["--package", "signalKit", "--out", str(self.output), "--verify"])

        self.assertEqual(0, status)
        self.assertIn("addon: MoltenCodes-SignalKit/MoltenCodes-SignalKit.toc", output.getvalue())
        self.assertIn(".toc verified: 2 file(s) in load order", output.getvalue())


class ChecksumVerificationTests(TemporaryRepositoryTests):
    """`--verify` reads `CHECKSUMS.txt` back and holds it against the build."""

    def build_and_verify(self) -> list[str]:
        module.build(self.output)
        return module.verify_checksums(self.output)

    def test_a_fresh_build_verifies(self):
        self.write_minimal_repository()

        self.assertEqual([], self.build_and_verify())

    def test_modified_contents_are_reported(self):
        self.write_minimal_repository()
        module.build(self.output)
        (self.output / "MoltenCodes" / "registry" / "Registry.lua").write_text(
            "return { tampered = true }\n", encoding="utf-8"
        )

        problems = module.verify_checksums(self.output)

        self.assertEqual(1, len(problems))
        self.assertIn("do not match the digest", problems[0])
        self.assertIn("MoltenCodes/registry/Registry.lua", problems[0])

    def test_a_recorded_file_that_disappeared_is_reported(self):
        self.write_minimal_repository()
        module.build(self.output)
        (self.output / "MoltenCodes" / "registry" / "Registry.lua").unlink()

        problems = module.verify_checksums(self.output)

        self.assertEqual(1, len(problems))
        self.assertIn("missing from the build", problems[0])

    def test_an_unrecorded_file_in_the_bundle_is_reported(self):
        self.write_minimal_repository()
        module.build(self.output)
        (self.output / "MoltenCodes" / "registry" / "Smuggled.lua").write_text(
            "return {}\n", encoding="utf-8"
        )

        problems = module.verify_checksums(self.output)

        self.assertEqual(1, len(problems))
        self.assertIn("not recorded in CHECKSUMS.txt", problems[0])

    def test_a_bundle_the_checksums_do_not_describe_is_ignored(self):
        """An output directory may hold an earlier build; only the newest is described."""
        self.write_minimal_repository()
        module.build(self.output)

        module.build(self.output, package_name="signalKit")

        self.assertTrue((self.output / "MoltenCodes").is_dir())
        self.assertEqual([], module.verify_checksums(self.output))

    def test_a_missing_checksum_file_is_reported(self):
        self.write_minimal_repository()
        module.build(self.output)
        (self.output / "CHECKSUMS.txt").unlink()

        problems = module.verify_checksums(self.output)

        self.assertEqual(1, len(problems))
        self.assertIn("nothing to verify", problems[0])

    def test_a_malformed_checksum_line_is_reported(self):
        self.write_minimal_repository()
        module.build(self.output)
        (self.output / "CHECKSUMS.txt").write_text("not a checksum line\n", encoding="utf-8")

        with self.assertRaises(module.BuildError) as failure:
            module.verify_checksums(self.output)

        self.assertIn("sha256sum format", str(failure.exception))

    def test_command_line_verify_succeeds_on_a_clean_build(self):
        self.write_minimal_repository()

        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = module.main(["--all", "--out", str(self.output), "--verify"])

        self.assertEqual(0, status)
        self.assertIn("checksums verified", output.getvalue())

    def test_command_line_verify_fails_the_command_on_a_problem(self):
        """A problem must fail the command, not merely be printed under a success."""
        self.write_minimal_repository()
        problem = "MoltenCodes/LICENSE: contents do not match the digest in CHECKSUMS.txt"

        output = io.StringIO()
        errors = io.StringIO()
        with mock.patch.object(module, "verify_checksums", return_value=[problem]):
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                status = module.main(["--all", "--out", str(self.output), "--verify"])

        self.assertEqual(1, status)
        self.assertIn("checksum verification failed", errors.getvalue())
        self.assertIn(problem, errors.getvalue())


class PkgmetaTests(unittest.TestCase):
    """`.pkgmeta` and the builder must describe the same shipped layout."""

    def test_pkgmeta_moves_every_release_package_source_directory(self):
        """Development packages are ignored instead; validate_repository checks that."""
        manifests, errors = validate_manifests.load_manifests()
        self.assertEqual([], errors)

        text = (validate_manifests.ROOT / ".pkgmeta").read_text(encoding="utf-8")
        for name, data in manifests.items():
            if validate_manifests.is_development(data):
                continue
            self.assertIn(
                f"MoltenCodes/packages/{name}/src: MoltenCodes/{name}",
                text,
                f'.pkgmeta does not move "{name}" into the embeddable layout',
            )


if __name__ == "__main__":
    unittest.main()
