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

    def write_required_root_files(self) -> None:
        """Create every file `REQUIRED_ROOT_FILES` names, with placeholder content."""
        for relative in module.REQUIRED_ROOT_FILES:
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("placeholder\n", encoding="utf-8")

    def write_language_server_config(self, name: str, library: list[str]) -> Path:
        path = self.packages / name / "src" / module.LANGUAGE_SERVER_CONFIG_NAME
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps({"workspace": {"library": library}}), encoding="utf-8"
        )
        return path

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
            "license": "MIT",
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

    def test_required_root_files_are_accepted_when_present(self):
        self.write_required_root_files()

        self.assertEqual([], module.validate_required_root_files())

    def test_missing_required_root_file_is_reported(self):
        self.write_required_root_files()
        (self.root / "docs" / "EMBEDDING.md").unlink()

        errors = module.validate_required_root_files()

        self.assertEqual(1, len(errors))
        self.assertIn("docs/EMBEDDING.md", errors[0])

    def test_required_root_files_cover_the_consumer_surface(self):
        for relative in (
            Path(".pkgmeta"),
            Path("docs/EMBEDDING.md"),
            Path("examples/Core.lua"),
            Path("examples/ExampleAddon.toc"),
            Path("examples/embeds.xml"),
        ):
            self.assertIn(relative, module.REQUIRED_ROOT_FILES)

    def test_language_server_config_must_list_meta_and_dependencies(self):
        manifests = {
            "registry": {"dependencies": {}},
            "signalKit": {"dependencies": {"registry": {"api": 2}}},
        }
        self.write_language_server_config("registry", [module.SHARED_META_LIBRARY])
        self.write_language_server_config(
            "signalKit", [module.SHARED_META_LIBRARY, "../../registry/src"]
        )

        self.assertEqual([], module.validate_language_server_configs(manifests))

    def test_language_server_config_missing_a_dependency_is_reported(self):
        manifests = {
            "registry": {"dependencies": {}},
            "signalKit": {"dependencies": {"registry": {"api": 2}}},
        }
        self.write_language_server_config("registry", [module.SHARED_META_LIBRARY])
        self.write_language_server_config("signalKit", [module.SHARED_META_LIBRARY])

        errors = module.validate_language_server_configs(manifests)

        self.assertEqual(1, len(errors))
        self.assertIn("../../registry/src", errors[0])

    def test_missing_language_server_config_is_reported(self):
        manifests = {"registry": {"dependencies": {}}}

        errors = module.validate_language_server_configs(manifests)

        self.assertEqual(1, len(errors))
        self.assertIn("lua-language-server configuration is missing", errors[0])

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
