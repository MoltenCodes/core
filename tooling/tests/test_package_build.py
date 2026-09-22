"""Tests for the release-artifact builder."""

from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
import zipfile
from pathlib import Path

from tooling.package import build as module
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


class BuildTests(unittest.TestCase):
    """Every build runs against a temporary repository, never the real one."""

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
        (package_dir / "package.manifest.json").write_text(
            json.dumps(manifest), encoding="utf-8"
        )
        return package_dir

    def write_minimal_repository(self):
        self.write_package("registry", facade="Registry")
        self.write_package(
            "signalKit", facade="SignalKit", dependencies={"registry": {"api": 1}}
        )

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

        bundle = self.output / "MoltenCodes-signalKit"
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


class PkgmetaTests(unittest.TestCase):
    """`.pkgmeta` and the builder must describe the same shipped layout."""

    def test_pkgmeta_moves_every_package_source_directory(self):
        manifests, errors = validate_manifests.load_manifests()
        self.assertEqual([], errors)

        text = (validate_manifests.ROOT / ".pkgmeta").read_text(encoding="utf-8")
        for name in manifests:
            self.assertIn(
                f"MoltenCodes/packages/{name}/src: MoltenCodes/{name}",
                text,
                f'.pkgmeta does not move "{name}" into the embeddable layout',
            )


if __name__ == "__main__":
    unittest.main()
