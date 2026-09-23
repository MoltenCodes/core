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

    def test_license_is_required_and_fixed(self):
        self.assertIn("license", module.REQUIRED)
        self.assertEqual("MIT", module.REPOSITORY_LICENSE)


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
        optional_dependencies=None,
        distribution=None,
        license_name: str | None = "MIT",
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
        if license_name is not None:
            data["license"] = license_name
        if api is not None:
            data["api"] = api
        if revision is not None:
            data["revision"] = revision
        if optional_dependencies is not None:
            data["optionalDependencies"] = optional_dependencies
        if distribution is not None:
            data["distribution"] = distribution
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

    def test_missing_license_is_reported(self):
        self.write_manifest("baseKit", license_name=None)

        errors = self.validate()

        self.assertTrue(any('missing required field "license"' in error for error in errors))

    def test_license_must_match_the_repository_license(self):
        self.write_manifest("baseKit", license_name="Apache-2.0")

        errors = self.validate()

        self.assertTrue(
            any('"license" must be "MIT"' in error for error in errors),
            errors,
        )

    def test_blank_license_is_reported(self):
        self.write_manifest("baseKit", license_name="   ")

        errors = self.validate()

        self.assertTrue(
            any('"license" must be a non-empty string' in error for error in errors),
            errors,
        )

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



class OptionalDependencyTests(ManifestRepositoryTests):
    """`optionalDependencies`: same shape as `dependencies`, checked in one graph."""

    def test_optional_dependency_is_accepted(self):
        self.write_manifest("baseKit")
        self.write_manifest("eventKit", dependencies={"baseKit": {"api": 1}})
        self.write_manifest(
            "cacheKit",
            dependencies={"baseKit": {"api": 1}},
            optional_dependencies={"eventKit": {"api": 1}},
        )

        self.assertEqual([], self.validate())

    def test_empty_optional_dependencies_is_accepted(self):
        self.write_manifest("baseKit", optional_dependencies={})

        self.assertEqual([], self.validate())

    def test_missing_optional_package_is_reported(self):
        self.write_manifest("baseKit", optional_dependencies={"ghostKit": {"api": 1}})

        errors = self.validate()

        self.assertEqual(1, len(errors))
        self.assertIn('optional dependency "ghostKit" does not exist', errors[0])

    def test_package_in_both_fields_is_reported(self):
        self.write_manifest("baseKit")
        self.write_manifest(
            "cacheKit",
            dependencies={"baseKit": {"api": 1}},
            optional_dependencies={"baseKit": {"api": 1}},
        )

        errors = self.validate()

        self.assertEqual(1, len(errors))
        self.assertIn("listed in both", errors[0])

    def test_optional_self_dependency_is_reported(self):
        self.write_manifest("baseKit", optional_dependencies={"baseKit": {"api": 1}})

        errors = self.validate()

        self.assertEqual(1, len(errors))
        self.assertIn('must not optionally depend on itself', errors[0])

    def test_cycle_closed_by_an_optional_edge_is_accepted(self):
        """The eventKit -> schedulerKit case: a required chain back, found at call time."""
        self.write_manifest("registryKit")
        self.write_manifest(
            "eventKit",
            dependencies={"registryKit": {"api": 1}},
            optional_dependencies={"schedulerKit": {"api": 1}},
        )
        self.write_manifest("lifecycleKit", dependencies={"eventKit": {"api": 1}})
        self.write_manifest("timerKit", dependencies={"lifecycleKit": {"api": 1}})
        self.write_manifest("schedulerKit", dependencies={"timerKit": {"api": 1}})

        self.assertEqual([], self.validate())

    def test_cycle_of_optional_edges_only_is_accepted(self):
        self.write_manifest("baseKit", optional_dependencies={"cacheKit": {"api": 1}})
        self.write_manifest("cacheKit", optional_dependencies={"baseKit": {"api": 1}})

        self.assertEqual([], self.validate())

    def test_required_cycle_is_still_reported_beside_optional_edges(self):
        self.write_manifest(
            "baseKit",
            dependencies={"cacheKit": {"api": 1}},
            optional_dependencies={"eventKit": {"api": 1}},
        )
        self.write_manifest("cacheKit", dependencies={"baseKit": {"api": 1}})
        self.write_manifest("eventKit")

        errors = self.validate()

        self.assertEqual(1, len(errors))
        self.assertIn("baseKit -> cacheKit -> baseKit", errors[0])

    def test_optional_api_mismatch_is_reported(self):
        self.write_manifest("baseKit", api=2, revision=1)
        self.write_manifest("cacheKit", optional_dependencies={"baseKit": {"api": 1}})

        errors = self.validate()

        self.assertEqual(1, len(errors))
        self.assertIn('optional dependency "baseKit" requires API 1', errors[0])

    def test_malformed_optional_contract_is_reported(self):
        self.write_manifest("baseKit")
        self.write_manifest("cacheKit", optional_dependencies={"baseKit": {"api": 1, "x": 2}})

        errors = self.validate()

        self.assertEqual(1, len(errors))
        self.assertIn('optional dependency "baseKit" must contain exactly "api"', errors[0])

    def test_optional_dependencies_must_be_an_object(self):
        self.write_manifest("baseKit", optional_dependencies=["eventKit"])

        errors = self.validate()

        self.assertTrue(any('"optionalDependencies" must be an object' in e for e in errors))

    def test_optional_dependencies_above_the_api_field_are_reported(self):
        """Manifest specs read the first `"api"`; a nested one above it would win."""
        package_dir = self.packages / "cacheKit"
        package_dir.mkdir()
        (package_dir / "package.manifest.json").write_text(
            json.dumps(
                {
                    "name": "cacheKit",
                    "displayName": "CacheKit",
                    "description": "cache",
                    "version": "1.0.0",
                    "license": "MIT",
                    "optionalDependencies": {},
                    "api": 1,
                    "revision": 1,
                    "dependencies": {},
                }
            ),
            encoding="utf-8",
        )

        errors = self.validate()

        self.assertEqual(1, len(errors))
        self.assertIn('must come after the top-level "api"', errors[0])


class DistributionTests(ManifestRepositoryTests):
    """`distribution`: release packages are bundled, development ones never are."""

    def test_both_values_and_the_default_are_accepted(self):
        self.write_manifest("baseKit")
        self.write_manifest("releaseKit", distribution="release")
        self.write_manifest("testKit", distribution="development")

        self.assertEqual([], self.validate())
        self.assertFalse(module.is_development({}))
        self.assertTrue(module.is_development({"distribution": "development"}))

    def test_unknown_value_is_reported(self):
        self.write_manifest("baseKit", distribution="internal")

        errors = self.validate()

        self.assertEqual(1, len(errors))
        self.assertIn('"distribution" must be one of release, development', errors[0])

    def test_release_package_may_not_require_a_development_package(self):
        self.write_manifest("testKit", distribution="development")
        self.write_manifest("cacheKit", dependencies={"testKit": {"api": 1}})

        errors = self.validate()

        self.assertEqual(1, len(errors))
        self.assertIn('release package "cacheKit" must not use development package', errors[0])

    def test_release_package_may_not_optionally_use_a_development_package(self):
        self.write_manifest("testKit", distribution="development")
        self.write_manifest("cacheKit", optional_dependencies={"testKit": {"api": 1}})

        errors = self.validate()

        self.assertEqual(1, len(errors))
        self.assertIn("as an optional dependency", errors[0])

    def test_development_package_may_depend_on_anything(self):
        self.write_manifest("baseKit")
        self.write_manifest("fixtureKit", distribution="development")
        self.write_manifest(
            "testKit",
            distribution="development",
            dependencies={"baseKit": {"api": 1}, "fixtureKit": {"api": 1}},
        )

        self.assertEqual([], self.validate())

if __name__ == "__main__":
    unittest.main()
