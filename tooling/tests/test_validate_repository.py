import json
import tempfile
import unittest
from pathlib import Path

from tooling.validation import validate_manifests
from tooling.validation import validate_repository as module


class RepositoryValidatorTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.packages = self.root / "packages"
        self.packages.mkdir()

        self.original_repo_root = module.ROOT
        self.original_manifest_root = validate_manifests.ROOT
        self.original_manifest_packages = validate_manifests.PACKAGES

        module.ROOT = self.root
        validate_manifests.ROOT = self.root
        validate_manifests.PACKAGES = self.packages

    def tearDown(self):
        module.ROOT = self.original_repo_root
        validate_manifests.ROOT = self.original_manifest_root
        validate_manifests.PACKAGES = self.original_manifest_packages
        self.tempdir.cleanup()

    def create_package(self, name: str, *, api: bool = True) -> Path:
        package = self.packages / name
        (package / "src").mkdir(parents=True)
        (package / "tests").mkdir()
        (package / "docs").mkdir()
        (package / "README.md").write_text(f"# {name}\n", encoding="utf-8")
        (package / "CHANGELOG.md").write_text("# Changelog\n", encoding="utf-8")
        (package / "src" / f"{name}.lua").write_text("return {}\n", encoding="utf-8")
        (package / "tests" / f"{name}_spec.lua").write_text("", encoding="utf-8")

        manifest = {
            "name": name,
            "displayName": name.title(),
            "description": f"{name} package",
            "version": "1.0.0",
            "dependencies": {},
        }
        if api:
            manifest["api"] = 1
            manifest["revision"] = 1
            (package / "docs" / "API.md").write_text("# API\n", encoding="utf-8")

        (package / "package.manifest.json").write_text(
            json.dumps(manifest), encoding="utf-8"
        )
        return package

    def test_package_layout_accepts_complete_package(self):
        self.create_package("registry")

        self.assertEqual([], module.validate_package_layout())

    def test_api_package_requires_api_documentation(self):
        package = self.create_package("registry")
        (package / "docs" / "API.md").unlink()

        errors = module.validate_package_layout()

        self.assertTrue(any("API package is missing docs/API.md" in error for error in errors))

    def test_package_requires_busted_specs(self):
        package = self.create_package("registry")
        (package / "tests" / "registry_spec.lua").unlink()

        errors = module.validate_package_layout()

        self.assertTrue(any("no Busted *_spec.lua tests" in error for error in errors))

    def test_markdown_relative_link_must_exist(self):
        readme = self.root / "README.md"
        readme.write_text("[Missing](docs/missing.md)\n", encoding="utf-8")

        errors = module.validate_markdown_links()

        self.assertTrue(any("broken relative link" in error for error in errors))

    def test_markdown_relative_link_cannot_escape_repository(self):
        readme = self.root / "README.md"
        readme.write_text("[Outside](../outside.md)\n", encoding="utf-8")

        errors = module.validate_markdown_links()

        self.assertTrue(any("relative link escapes repository" in error for error in errors))

    def test_markdown_external_link_is_ignored(self):
        readme = self.root / "README.md"
        readme.write_text("[External](https://example.com/docs)\n", encoding="utf-8")

        self.assertEqual([], module.validate_markdown_links())


if __name__ == "__main__":
    unittest.main()
