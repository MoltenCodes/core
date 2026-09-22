import json
import tempfile
import unittest
from pathlib import Path

from tooling.validation import validate_manifests as module


class ManifestValidatorUnitTests(unittest.TestCase):
    def test_name_pattern(self):
        self.assertIsNotNone(module.NAME_RE.fullmatch("registry"))
        self.assertIsNotNone(module.NAME_RE.fullmatch("signalKit"))
        self.assertIsNone(module.NAME_RE.fullmatch("Registry"))
        self.assertIsNone(module.NAME_RE.fullmatch("signal-kit"))
        self.assertEqual("Kit", module.PUBLIC_PACKAGE_SUFFIX)

    def test_semver(self):
        self.assertIsNotNone(module.SEMVER_RE.fullmatch("1.0.0"))
        self.assertIsNotNone(module.SEMVER_RE.fullmatch("1.2.3-beta.1"))
        self.assertIsNotNone(module.SEMVER_RE.fullmatch("1.2.3+build.001"))
        self.assertIsNone(module.SEMVER_RE.fullmatch("1.0"))
        self.assertIsNone(module.SEMVER_RE.fullmatch("1.0.0-01"))

    def test_positive_integer(self):
        self.assertTrue(module.positive_integer(1))
        self.assertFalse(module.positive_integer(0))
        self.assertFalse(module.positive_integer(True))


class ManifestRepositoryTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.packages = self.root / "packages"
        self.packages.mkdir()
        self.original_root = module.ROOT
        self.original_packages = module.PACKAGES
        module.ROOT = self.root
        module.PACKAGES = self.packages

    def tearDown(self):
        module.ROOT = self.original_root
        module.PACKAGES = self.original_packages
        self.tempdir.cleanup()

    def write_manifest(
        self,
        name: str,
        *,
        api: int | None = 1,
        revision: int | None = 1,
        dependencies=None,
    ) -> None:
        package_dir = self.packages / name
        package_dir.mkdir()
        data = {
            "name": name,
            "displayName": name.title(),
            "description": f"{name} package",
            "version": "1.0.0",
            "dependencies": dependencies or {},
        }
        if api is not None:
            data["api"] = api
        if revision is not None:
            data["revision"] = revision
        (package_dir / "package.manifest.json").write_text(
            json.dumps(data), encoding="utf-8"
        )

    def validate(self):
        manifests, errors = module.load_manifests()
        errors.extend(module.validate_graph(manifests))
        return errors

    def test_valid_repository(self):
        self.write_manifest("baseKit")
        self.write_manifest("eventKit", dependencies={"baseKit": {"api": 1}})

        self.assertEqual([], self.validate())

    def test_public_package_requires_kit_suffix(self):
        self.write_manifest("utility")

        errors = self.validate()

        self.assertTrue(any('must end with "Kit"' in error for error in errors))

    def test_package_directory_without_manifest_is_reported(self):
        (self.packages / "orphan").mkdir()

        errors = self.validate()

        self.assertTrue(any("missing required file" in error for error in errors))

    def test_malformed_dependency_contract_is_reported_without_crashing(self):
        self.write_manifest("baseKit")
        self.write_manifest("eventKit", dependencies={"baseKit": "api-1"})

        errors = self.validate()

        self.assertTrue(
            any('dependency "baseKit" must contain exactly "api"' in error for error in errors)
        )

    def test_dependency_must_expose_an_api_generation(self):
        self.write_manifest("utilityKit", api=None, revision=None)
        self.write_manifest("eventKit", dependencies={"utilityKit": {"api": 1}})

        errors = self.validate()

        self.assertTrue(
            any(
                'dependency "utilityKit" does not expose an API generation' in error
                for error in errors
            )
        )

    def test_api_mismatch_is_reported(self):
        self.write_manifest("baseKit", api=2, revision=1)
        self.write_manifest("eventKit", dependencies={"baseKit": {"api": 1}})

        errors = self.validate()

        self.assertTrue(any("requires API 1, but exposes API 2" in error for error in errors))

    def test_dependency_cycle_is_reported(self):
        self.write_manifest("alphaKit", dependencies={"betaKit": {"api": 1}})
        self.write_manifest("betaKit", dependencies={"alphaKit": {"api": 1}})

        errors = self.validate()

        self.assertTrue(any("dependency cycle detected" in error for error in errors))

    def test_self_dependency_is_reported_once_without_cycle_noise(self):
        self.write_manifest("alphaKit", dependencies={"alphaKit": {"api": 1}})

        errors = self.validate()

        self.assertEqual(1, len([error for error in errors if "depend on itself" in error]))
        self.assertFalse(any("dependency cycle detected" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
