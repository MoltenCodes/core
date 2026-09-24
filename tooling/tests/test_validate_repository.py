import json
import tempfile
import unittest
from pathlib import Path

from tooling.validation import interface_numbers, validate_manifests
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

    def write_example_embeds(self, *facades: str) -> Path:
        """Write an `examples/embeds.xml` that loads the given Lua facades, in order."""
        references = "\n".join(
            f'    <Script file="Libs\\MoltenCodes\\{module.package_id_for(facade)}\\{facade}" />'
            for facade in facades
        )
        path = self.root / module.EXAMPLE_EMBEDS
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"<Ui>\n{references}\n</Ui>\n", encoding="utf-8")
        return path

    def write_example_language_server_config(self, library: list[str]) -> Path:
        path = self.root / "examples" / module.LANGUAGE_SERVER_CONFIG_NAME
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps({"workspace": {"library": library}}), encoding="utf-8"
        )
        return path

    def create_package(self, name: str, *, api: bool = True) -> Path:
        """Write a complete package whose facade is `src/<DisplayName>.lua`."""
        package = self.packages / name
        display_name = name[0].upper() + name[1:]
        (package / "src").mkdir(parents=True)
        (package / "tests").mkdir()
        (package / "docs").mkdir()
        (package / "README.md").write_text(f"# {name}\n", encoding="utf-8")
        (package / "CHANGELOG.md").write_text("# Changelog\n", encoding="utf-8")
        (package / "src" / f"{display_name}.lua").write_text("return {}\n", encoding="utf-8")
        (package / "tests" / f"{name}_spec.lua").write_text("", encoding="utf-8")

        manifest = {
            "name": name,
            "displayName": display_name,
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

    def test_embedded_package_names_follow_the_embed_order(self):
        embeds = self.write_example_embeds("Registry.lua", "SignalKit.lua", "EventKit.lua")

        self.assertEqual(
            ["registry", "signalKit", "eventKit"], module.embedded_package_names(embeds)
        )

    def test_example_config_must_list_meta_and_the_embedded_packages(self):
        self.write_example_embeds("Registry.lua", "SignalKit.lua")
        self.write_example_language_server_config(
            [
                module.EXAMPLE_SHARED_META_LIBRARY,
                "../packages/registry/src",
                "../packages/signalKit/src",
            ]
        )

        self.assertEqual([], module.validate_example_language_server_config())

    def test_example_config_listing_an_unembedded_package_is_reported(self):
        self.write_example_embeds("Registry.lua", "SignalKit.lua")
        self.write_example_language_server_config(
            [
                module.EXAMPLE_SHARED_META_LIBRARY,
                "../packages/registry/src",
                "../packages/signalKit/src",
                "../packages/poolKit/src",
            ]
        )

        errors = module.validate_example_language_server_config()

        self.assertEqual(1, len(errors))
        self.assertIn(f"examples/{module.LANGUAGE_SERVER_CONFIG_NAME}", errors[0])
        self.assertNotIn("poolKit", errors[0])

    def test_example_config_must_follow_the_embed_order(self):
        self.write_example_embeds("Registry.lua", "SignalKit.lua")
        self.write_example_language_server_config(
            [
                module.EXAMPLE_SHARED_META_LIBRARY,
                "../packages/signalKit/src",
                "../packages/registry/src",
            ]
        )

        errors = module.validate_example_language_server_config()

        self.assertEqual(1, len(errors))
        self.assertIn("workspace.library must be", errors[0])

    def test_missing_example_config_is_reported(self):
        self.write_example_embeds("Registry.lua")

        errors = module.validate_example_language_server_config()

        self.assertEqual(1, len(errors))
        self.assertIn("lua-language-server configuration is missing", errors[0])

    def test_example_config_is_not_checked_without_embeds(self):
        """A missing `embeds.xml` is `validate_required_root_files`' error to report."""
        self.assertEqual([], module.validate_example_language_server_config())

    def test_package_layout_accepts_complete_package(self):
        self.create_package("registry")

        self.assertEqual([], module.validate_package_layout())

    def test_package_layout_accepts_further_runtime_files_in_subdirectories(self):
        package = self.create_package("registry")
        (package / "src" / "flavours").mkdir()
        (package / "src" / "flavours" / "Retail.lua").write_text("return {}\n", encoding="utf-8")

        self.assertEqual([], module.validate_package_layout())

    def test_package_layout_refuses_a_second_top_level_lua_file(self):
        package = self.create_package("registry")
        (package / "src" / "Second.lua").write_text("return {}\n", encoding="utf-8")

        errors = module.validate_package_layout()

        self.assertTrue(
            any("expected one top-level Lua facade, found Registry.lua, Second.lua" in error
                for error in errors),
            errors,
        )

    def test_package_layout_requires_the_facade_to_carry_the_display_name(self):
        package = self.create_package("registry")
        (package / "src" / "Registry.lua").rename(package / "src" / "Other.lua")

        errors = module.validate_package_layout()

        self.assertTrue(any('"Registry.lua"' in error for error in errors), errors)

    def test_generated_package_documentation_is_not_link_checked(self):
        package = self.create_package("apiKit")
        for directory in ("reference", "changes"):
            generated = package / "docs" / directory / "retail"
            generated.mkdir(parents=True)
            (generated / "index.md").write_text("[Broken](missing.md)\n", encoding="utf-8")
        (package / "docs" / "API.md").write_text("[Broken](missing.md)\n", encoding="utf-8")

        errors = module.validate_markdown_links()

        self.assertEqual(1, len(errors), errors)
        self.assertIn("docs/API.md", errors[0])

    def test_missing_api_flavour_table_is_reported(self):
        errors = module.validate_api_flavours()

        self.assertEqual(1, len(errors), errors)
        self.assertIn("flavours.json", errors[0])

    def test_malformed_api_flavour_table_is_reported(self):
        path = self.root / module.flavours.FLAVOURS_PATH
        path.parent.mkdir(parents=True)
        path.write_text('{"verified": "2026-09-24"}', encoding="utf-8")

        errors = module.validate_api_flavours()

        self.assertEqual(1, len(errors), errors)
        self.assertIn("exactly the keys", errors[0])

    def test_a_path_outside_the_repository_is_not_generated_documentation(self):
        with tempfile.TemporaryDirectory() as elsewhere:
            outside = Path(elsewhere) / "packages" / "apiKit" / "docs" / "reference" / "a.md"

            self.assertFalse(module.is_generated_documentation(outside))

    def test_facade_check_is_skipped_when_the_manifest_is_unreadable(self):
        """The manifest checks report a broken manifest; the facade rule stays quiet."""
        package = self.create_package("registry")
        (package / "package.manifest.json").write_text("{ not json", encoding="utf-8")
        (package / "src" / "Registry.lua").rename(package / "src" / "Other.lua")

        self.assertEqual([], module.validate_facade_file(package))

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



class RepositoryApiFlavourTests(unittest.TestCase):
    """The committed flavour table passes the validator's check."""

    def test_repository_flavour_table_is_valid(self):
        self.assertEqual([], module.validate_api_flavours())


class PythonFloorTests(unittest.TestCase):
    """The declared Python floor is enforced rather than merely documented."""

    def test_accepts_the_floor_itself(self):
        self.assertEqual([], module.validate_python_version(module.PYTHON_FLOOR))

    def test_rejects_an_interpreter_below_the_floor(self):
        major, minor = module.PYTHON_FLOOR
        errors = module.validate_python_version((major, minor - 1))

        self.assertEqual(1, len(errors))
        self.assertIn("older than the supported floor", errors[0])
        self.assertIn("pyproject.toml", errors[0])

    def test_matches_requires_python_in_pyproject(self):
        declared = module.REQUIRES_PYTHON_RE.search(
            (module.ROOT / "pyproject.toml").read_text(encoding="utf-8")
        )

        self.assertIsNotNone(declared)
        self.assertEqual(
            module.PYTHON_FLOOR, (int(declared.group(1)), int(declared.group(2)))
        )


class InterfaceNumberTests(unittest.TestCase):
    """Every quoted `## Interface` line and the documented table follow one source."""

    EXPECTED = module.SupportedClients(
        verified="2026-09-23",
        source="https://example.invalid/patches",
        clients=(
            interface_numbers.SupportedClient("Retail", 120100, "12.1.0", "_Mainline", True),
            interface_numbers.SupportedClient(
                "Classic Era", 11509, "1.15.9", "_Vanilla", True
            ),
        ),
    )

    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.original_root = module.ROOT
        module.ROOT = self.root

    def tearDown(self):
        module.ROOT = self.original_root
        self.tempdir.cleanup()

    def write(self, relative: str, text: str) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def embedding_document(self, *, rows=None, verified="2026-09-23") -> str:
        rows = self.EXPECTED.markdown_rows() if rows is None else rows
        return "\n".join(
            [
                "# Embedding",
                "",
                "```toc",
                "## Interface: 120100, 11509",
                "```",
                "",
                "## Supported client versions",
                "",
                f"Verified on {verified}.",
                "",
                "```toc",
                "## Interface: 120100, 11509",
                "```",
                "",
                "| Flavour | `## Interface` | Patch | Suffix |",
                "|---|---|---|---|",
                *rows,
                "",
                "## Next section",
                "",
                "| Old | `40402` | 4.4.2 | `_Cata` |",
                "",
            ]
        )

    def write_consistent_repository(self) -> None:
        self.write("examples/ExampleAddon.toc", "## Interface: 120100, 11509\n## Title: Example\n")
        self.write("docs/EMBEDDING.md", self.embedding_document())
        self.write(
            "packages/registry/docs/API.md", "```toc\n## Interface: 120100, 11509\n```\n"
        )

    def test_consistent_repository_is_accepted(self):
        self.write_consistent_repository()

        self.assertEqual([], module.validate_interface_numbers(self.EXPECTED))

    def test_number_order_does_not_matter(self):
        self.write_consistent_repository()
        self.write("examples/ExampleAddon.toc", "## Interface: 11509, 120100\n")

        self.assertEqual([], module.validate_interface_numbers(self.EXPECTED))

    def test_drifted_example_toc_is_reported_with_the_line_to_paste(self):
        self.write_consistent_repository()
        self.write("examples/ExampleAddon.toc", "## Interface: 120001, 11509\n")

        errors = module.validate_interface_numbers(self.EXPECTED)

        self.assertEqual(1, len(errors))
        self.assertIn("examples/ExampleAddon.toc", errors[0])
        self.assertIn('expected "## Interface: 120100, 11509"', errors[0])

    def test_multi_number_line_with_a_wrong_number_is_reported(self):
        self.write_consistent_repository()
        self.write("packages/registry/docs/API.md", "## Interface: 120100, 50504\n")

        errors = module.validate_interface_numbers(self.EXPECTED)

        self.assertEqual(1, len(errors))
        self.assertIn("packages/registry/docs/API.md", errors[0])

    def test_extra_number_is_reported(self):
        self.write_consistent_repository()
        self.write("examples/ExampleAddon.toc", "## Interface: 120100, 50504, 11509\n")

        self.assertEqual(1, len(module.validate_interface_numbers(self.EXPECTED)))

    def test_repeated_number_is_reported(self):
        self.write_consistent_repository()
        self.write("examples/ExampleAddon.toc", "## Interface: 120100, 11509, 11509\n")

        self.assertEqual(1, len(module.validate_interface_numbers(self.EXPECTED)))

    def test_single_supported_number_is_accepted_as_a_per_flavour_example(self):
        self.write_consistent_repository()
        self.write(
            "packages/registry/docs/API.md",
            "```toc\n## Interface: 120100, 11509\n```\n\n```toc\n## Interface: 120100\n```\n",
        )

        self.assertEqual([], module.validate_interface_numbers(self.EXPECTED))

    def test_single_unsupported_number_is_reported(self):
        self.write_consistent_repository()
        self.write("packages/registry/docs/API.md", "```toc\n## Interface: 110207\n```\n")

        errors = module.validate_interface_numbers(self.EXPECTED)

        self.assertEqual(1, len(errors))
        self.assertIn("is not a supported client", errors[0])

    def test_malformed_line_is_reported(self):
        self.write_consistent_repository()
        self.write("examples/ExampleAddon.toc", "## Interface: 120100, eleven\n")

        self.assertEqual(1, len(module.validate_interface_numbers(self.EXPECTED)))

    def test_required_document_without_an_interface_line_is_reported(self):
        self.write_consistent_repository()
        self.write("packages/registry/docs/API.md", "No example here.\n")

        errors = module.validate_interface_numbers(self.EXPECTED)

        self.assertEqual(1, len(errors))
        self.assertIn('no "## Interface" line', errors[0])

    def test_per_flavour_interface_field_is_not_mistaken_for_the_line(self):
        self.write_consistent_repository()
        self.write(
            "examples/ExampleAddon.toc",
            "## Interface: 120100, 11509\n## Interface-Vanilla: 11508\n",
        )

        self.assertEqual([], module.validate_interface_numbers(self.EXPECTED))

    def test_readme_without_an_interface_line_is_accepted(self):
        self.write_consistent_repository()
        self.write("README.md", "# Project\n")

        self.assertEqual([], module.validate_interface_numbers(self.EXPECTED))

    def test_readme_with_a_drifted_interface_line_is_reported(self):
        self.write_consistent_repository()
        self.write("README.md", "```toc\n## Interface: 110207\n```\n")

        errors = module.validate_interface_numbers(self.EXPECTED)

        self.assertEqual(1, len(errors))
        self.assertIn("README.md", errors[0])

    def test_example_directory_without_a_toc_is_reported(self):
        self.write_consistent_repository()
        (self.root / "examples" / "ExampleAddon.toc").unlink()

        errors = module.validate_interface_numbers(self.EXPECTED)

        self.assertEqual(1, len(errors))
        self.assertIn("no .toc file", errors[0])

    def test_drifted_documentation_table_is_reported_with_the_rows_to_paste(self):
        self.write_consistent_repository()
        rows = self.EXPECTED.markdown_rows()
        rows[0] = rows[0].replace("12.1.0", "12.0.7")
        self.write("docs/EMBEDDING.md", self.embedding_document(rows=rows))

        errors = module.validate_interface_numbers(self.EXPECTED)

        self.assertEqual(1, len(errors))
        self.assertIn("supported-client table does not match", errors[0])
        self.assertIn(self.EXPECTED.markdown_rows()[0], errors[0])

    def test_documentation_table_row_missing_is_reported(self):
        self.write_consistent_repository()
        rows = self.EXPECTED.markdown_rows()[:1]
        self.write("docs/EMBEDDING.md", self.embedding_document(rows=rows))

        self.assertEqual(1, len(module.validate_interface_numbers(self.EXPECTED)))

    def test_rows_after_the_section_are_not_part_of_the_table(self):
        """The `## Interface` line in a fenced block does not end the section early."""
        self.write_consistent_repository()

        section = module.markdown_section(
            self.embedding_document(), module.SUPPORTED_CLIENTS_HEADING
        )

        self.assertIsNotNone(section)
        self.assertIn("_Vanilla", section)
        self.assertNotIn("40402", section)

    def test_a_tilde_line_does_not_close_a_backtick_fence(self):
        text = "\n".join(
            [
                "## Supported client versions",
                "",
                "```text",
                "~~~",
                "## Not a heading",
                "```",
                "",
                "inside the section",
                "",
                "## Next section",
                "",
                "outside",
            ]
        )

        section = module.markdown_section(text, module.SUPPORTED_CLIENTS_HEADING)

        self.assertIn("inside the section", section)
        self.assertNotIn("outside", section)

    def test_stale_verification_date_is_reported(self):
        self.write_consistent_repository()
        self.write("docs/EMBEDDING.md", self.embedding_document(verified="2026-06-01"))

        errors = module.validate_interface_numbers(self.EXPECTED)

        self.assertEqual(1, len(errors))
        self.assertIn("verification date 2026-09-23", errors[0])

    def test_missing_section_is_reported(self):
        self.write_consistent_repository()
        self.write("docs/EMBEDDING.md", "## Interface: 120100, 11509\n")

        errors = module.validate_interface_numbers(self.EXPECTED)

        self.assertEqual(1, len(errors))
        self.assertIn("Supported client versions", errors[0])

    def test_unreadable_table_is_reported(self):
        self.write_consistent_repository()
        self.write(str(module.SUPPORTED_CLIENTS), "{ not json")

        errors = module.validate_interface_numbers()

        self.assertEqual(1, len(errors))
        self.assertIn("unable to read the supported-client table", errors[0])


class RepositoryInterfaceNumberTests(unittest.TestCase):
    """The real repository agrees with its own supported-client table."""

    def test_repository_quotes_only_the_supported_numbers(self):
        self.assertEqual([], module.validate_interface_numbers())


class DevelopmentPackagePkgmetaTests(unittest.TestCase):
    """Every development package must be in `.pkgmeta`'s `ignore:` list."""

    PKGMETA = """\
package-as: MoltenCodes

# Development files.
ignore:
  - docs
  # The test tooling package is never shipped.
  - packages/testKit/
  - "packages/benchKit"
move-folders:
  MoltenCodes/packages/registry/src: MoltenCodes/registry
"""

    MANIFESTS = {
        "registry": {"dependencies": {}},
        "testKit": {"dependencies": {}, "distribution": "development"},
        "benchKit": {"dependencies": {}, "distribution": "development"},
    }

    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.original_root = module.ROOT
        module.ROOT = self.root

    def tearDown(self):
        module.ROOT = self.original_root
        self.tempdir.cleanup()

    def write_pkgmeta(self, text: str) -> None:
        (self.root / module.PKGMETA).write_text(text, encoding="utf-8")

    def test_ignore_entries_are_read_from_the_block_list_only(self):
        self.assertEqual(
            ["docs", "packages/testKit", "packages/benchKit"],
            module.pkgmeta_ignore_entries(self.PKGMETA),
        )

    def test_ignore_entries_drop_a_trailing_comment(self):
        text = "ignore:\n  - packages/testKit  # development only\n  - docs\n"

        self.assertEqual(["packages/testKit", "docs"], module.pkgmeta_ignore_entries(text))

    def test_ignored_development_packages_are_accepted(self):
        self.write_pkgmeta(self.PKGMETA)

        self.assertEqual([], module.validate_development_packages_ignored(self.MANIFESTS))

    def test_missing_ignore_line_is_reported_with_the_line_to_add(self):
        self.write_pkgmeta(self.PKGMETA.replace('  - "packages/benchKit"\n', ""))

        errors = module.validate_development_packages_ignored(self.MANIFESTS)

        self.assertEqual(1, len(errors))
        self.assertIn('development package "benchKit" is not ignored', errors[0])
        self.assertIn('"  - packages/benchKit"', errors[0])

    def test_a_move_folders_mention_does_not_count_as_ignored(self):
        self.write_pkgmeta(
            "ignore:\n  - docs\nmove-folders:\n  - packages/testKit\n  - packages/benchKit\n"
        )

        errors = module.validate_development_packages_ignored(self.MANIFESTS)

        self.assertEqual(2, len(errors))

    def test_release_packages_need_no_ignore_line(self):
        self.write_pkgmeta("ignore:\n  - docs\n")

        self.assertEqual(
            [], module.validate_development_packages_ignored({"registry": {"dependencies": {}}})
        )


if __name__ == "__main__":
    unittest.main()
