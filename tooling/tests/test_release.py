import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from tooling.package import build
from tooling.release import check_tag, history, library_toc, notes, pkgmeta
from tooling.validation import validate_manifests


RELEASES = """\
# Releases

## Tags

```text
### v9.9.9
- `registry` 9.9.9
```

## Release history

### v1.1.0 — 2026-10-01

- `registry` 0.6.1
- `signalKit` 0.3.0

Adds the signal bus.

### v1.0.0

- `registry` 0.6.0

## Next section

### v2.0.0

- `registry` 0.6.1
"""


class ReleaseRepository(unittest.TestCase):
    """A throwaway repository with two packages and a release history."""

    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.packages = self.root / "packages"
        self.packages.mkdir()
        self.originals = (validate_manifests.ROOT, validate_manifests.PACKAGES, history.ROOT)
        validate_manifests.ROOT = self.root
        validate_manifests.PACKAGES = self.packages
        history.ROOT = self.root

        self.write_manifest("registry", "0.6.1", api=2, dependencies={})
        self.write_manifest("signalKit", "0.3.0", api=1, dependencies={"registry": {"api": 2}})
        self.write_manifest(
            "testKit",
            "0.2.0",
            api=1,
            dependencies={"signalKit": {"api": 1}},
            distribution="development",
        )
        self.write_releases(RELEASES)

    def tearDown(self):
        validate_manifests.ROOT, validate_manifests.PACKAGES, history.ROOT = self.originals
        self.tempdir.cleanup()

    def write_manifest(self, name, version, *, api, dependencies, distribution=None):
        directory = self.packages / name
        directory.mkdir()
        manifest = {
            "name": name,
            "displayName": name,
            "description": name,
            "version": version,
            "license": "MIT",
            "api": api,
            "revision": 1,
            "dependencies": dependencies,
        }
        if distribution is not None:
            manifest["distribution"] = distribution
        (directory / "package.manifest.json").write_text(json.dumps(manifest), encoding="utf-8")

    def write_releases(self, text):
        path = self.root / history.RELEASES_DOCUMENT
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")


class HistoryTests(unittest.TestCase):
    def test_sections_are_only_read_under_the_history_heading(self):
        sections = history.release_sections(RELEASES)

        self.assertEqual(["v1.1.0", "v1.0.0"], list(sections))

    def test_section_body_ends_at_the_next_release(self):
        _, body = history.release_section(RELEASES, "v1.1.0")

        self.assertIn("Adds the signal bus.", body)
        self.assertNotIn("0.6.0", body)

    def test_package_lines_are_parsed_with_line_numbers(self):
        first_line, body = history.release_section(RELEASES, "v1.1.0")

        entries = history.package_versions(body, first_line)

        self.assertEqual(
            [("registry", "0.6.1"), ("signalKit", "0.3.0")],
            [(entry.package, entry.version) for entry in entries],
        )
        self.assertEqual("- `registry` 0.6.1", RELEASES.splitlines()[entries[0].line_number - 1])

    def test_missing_section_is_none(self):
        self.assertIsNone(history.release_section(RELEASES, "v3.0.0"))

    def test_history_heading_line_skips_fenced_code(self):
        text = "```text\n## Release history\n```\n\n## Release history\n"

        self.assertEqual(5, history.history_heading_line(text))
        self.assertIsNone(history.history_heading_line("# Releases\n"))

    def test_section_heading_line_points_at_the_heading(self):
        line = history.section_heading_line(RELEASES, "v1.0.0")

        self.assertEqual("### v1.0.0", RELEASES.splitlines()[line - 1])
        self.assertIsNone(history.section_heading_line(RELEASES, "v3.0.0"))

    def test_package_sections_are_read_like_bundle_sections(self):
        text = "## Release history\n\n### timerKit-v0.6.0\n\nFixes a leak.\n"

        self.assertEqual((5, "Fixes a leak."), history.release_section(text, "timerKit-v0.6.0"))


BOTH = "- `registry` 0.6.1\n- `signalKit` 0.3.0\n"


class ParseTagTests(unittest.TestCase):
    def test_a_bundle_tag_has_no_package(self):
        self.assertEqual(("bundle", None, "0.1.0"), check_tag.parse_tag("v0.1.0"))

    def test_a_package_tag_names_its_package(self):
        parsed = check_tag.parse_tag("timerKit-v0.6.0")

        self.assertEqual(("package", "timerKit", "0.6.0"), parsed)
        self.assertEqual("timerKit", parsed.package)

    def test_a_prerelease_with_hyphens_keeps_the_package_id_whole(self):
        self.assertEqual(
            ("package", "timerKit", "1.0.0-beta-2"), check_tag.parse_tag("timerKit-v1.0.0-beta-2")
        )
        self.assertEqual(("bundle", None, "1.2.0-rc.1"), check_tag.parse_tag("v1.2.0-rc.1"))

    def test_malformed_tags_are_rejected(self):
        for tag in (
            "1.1.0",
            "v1.0",
            "V1.0.0",
            "TimerKit-v1.0.0",
            "timerKit-1.0.0",
            "timerKit-v1.0",
            "-v1.0.0",
            "timer-kit-v1.0.0",
            "timerKit-v01.0.0",
        ):
            with self.subTest(tag=tag), self.assertRaises(check_tag.TagError):
                check_tag.parse_tag(tag)

    def test_parse_tag_names_both_forms_when_it_refuses(self):
        self.assertEqual(check_tag.BUNDLE, check_tag.parse_tag("v1.0.0").kind)
        self.assertEqual(check_tag.PACKAGE, check_tag.parse_tag("registry-v0.6.1").kind)
        with self.assertRaisesRegex(check_tag.TagError, "neither"):
            check_tag.parse_tag("latest")

    def test_github_outputs_lists_every_key(self):
        self.assertEqual(
            "tag=timerKit-v0.6.0\nkind=package\npackage=timerKit\nversion=0.6.0\n",
            check_tag.github_outputs("timerKit-v0.6.0", check_tag.parse_tag("timerKit-v0.6.0")),
        )
        bundle = check_tag.github_outputs("v1.0.0", check_tag.parse_tag("v1.0.0"))
        self.assertIn("package=\n", bundle)


class CheckBundleTagTests(ReleaseRepository):
    def test_a_consistent_tag_passes(self):
        self.assertEqual([], check_tag.check_tag("v1.1.0"))

    def test_a_tag_without_v_prefix_is_rejected(self):
        self.assertEqual(1, len(check_tag.check_tag("1.1.0")))

    def test_a_prerelease_tag_is_accepted_when_documented(self):
        self.write_releases("## Release history\n\n### v1.2.0-beta.1\n\n" + BOTH)

        self.assertEqual([], check_tag.check_tag("v1.2.0-beta.1"))

    def test_a_tag_without_a_section_cites_the_history_heading(self):
        errors = check_tag.check_tag("v2.0.0")

        self.assertEqual(1, len(errors))
        self.assertIn('no "### v2.0.0" section', errors[0])
        heading_line = RELEASES.splitlines().index("## Release history") + 1
        self.assertTrue(errors[0].startswith(f"docs/RELEASES.md:{heading_line}: "), errors[0])

    def test_a_document_without_a_history_heading_says_so(self):
        self.write_releases("# Releases\n")

        errors = check_tag.check_tag("v1.0.0")

        self.assertEqual(['docs/RELEASES.md: no "## Release history" heading'], errors)

    def test_a_section_listing_no_packages_is_rejected(self):
        self.write_releases("## Release history\n\n### v1.0.0\n\nNothing listed.\n")

        errors = check_tag.check_tag("v1.0.0")

        self.assertEqual(1, len(errors))
        self.assertIn("lists no", errors[0])
        self.assertIn("docs/RELEASES.md:3:", errors[0])

    def test_a_version_that_differs_from_the_manifest_is_rejected(self):
        self.write_releases(
            "## Release history\n\n### v1.0.0\n\n- `registry` 0.6.0\n- `signalKit` 0.3.0\n"
        )

        errors = check_tag.check_tag("v1.0.0")

        self.assertEqual(1, len(errors))
        self.assertIn('"registry" is listed at 0.6.0, but its manifest says 0.6.1', errors[0])
        self.assertIn("docs/RELEASES.md:5:", errors[0])

    def test_a_release_package_left_out_is_rejected_at_the_heading(self):
        self.write_releases("## Release history\n\n### v1.0.0\n\n- `registry` 0.6.1\n")

        errors = check_tag.check_tag("v1.0.0")

        self.assertEqual(1, len(errors))
        self.assertIn('does not list release package "signalKit"', errors[0])
        self.assertIn("(manifest version 0.3.0)", errors[0])
        self.assertTrue(errors[0].startswith("docs/RELEASES.md:3: "), errors[0])

    def test_a_development_package_is_neither_required_nor_allowed(self):
        self.assertEqual([], check_tag.check_tag("v1.1.0"))

        self.write_releases(
            "## Release history\n\n### v1.0.0\n\n" + BOTH + "- `testKit` 0.2.0\n"
        )

        errors = check_tag.check_tag("v1.0.0")

        self.assertEqual(1, len(errors))
        self.assertIn('"testKit" is a development package', errors[0])
        self.assertIn("docs/RELEASES.md:7:", errors[0])

    def test_an_unknown_package_is_rejected(self):
        self.write_releases(
            "## Release history\n\n### v1.0.0\n\n" + BOTH + "- `ghostKit` 1.0.0\n"
        )

        errors = check_tag.check_tag("v1.0.0")

        self.assertEqual(1, len(errors))
        self.assertIn('package "ghostKit" does not exist', errors[0])

    def test_a_package_listed_twice_is_rejected(self):
        self.write_releases(
            "## Release history\n\n### v1.0.0\n\n" + BOTH + "- `registry` 0.6.1\n"
        )

        errors = check_tag.check_tag("v1.0.0")

        self.assertEqual(1, len(errors))
        self.assertIn("listed more than once", errors[0])


class CheckPackageTagTests(ReleaseRepository):
    def write_package_section(self, tag, body="Fixes a timer leak.\n"):
        self.write_releases(f"# Releases\n\n## Release history\n\n### {tag}\n\n{body}")

    def test_a_consistent_package_tag_passes(self):
        self.write_package_section("signalKit-v0.3.0")

        self.assertEqual([], check_tag.check_tag("signalKit-v0.3.0"))

    def test_a_package_section_may_list_versions_that_match(self):
        self.write_package_section("signalKit-v0.3.0", "- `signalKit` 0.3.0\n")

        self.assertEqual([], check_tag.check_tag("signalKit-v0.3.0"))

    def test_listed_versions_in_a_package_section_are_checked(self):
        self.write_package_section("signalKit-v0.3.0", "- `registry` 0.5.0\n")

        errors = check_tag.check_tag("signalKit-v0.3.0")

        self.assertEqual(1, len(errors))
        self.assertIn("docs/RELEASES.md:7:", errors[0])
        self.assertIn("manifest says 0.6.1", errors[0])

    def test_a_package_tag_without_a_section_cites_the_history_heading(self):
        errors = check_tag.check_tag("signalKit-v0.3.0")

        self.assertEqual(1, len(errors))
        heading_line = RELEASES.splitlines().index("## Release history") + 1
        self.assertIn(
            f'docs/RELEASES.md:{heading_line}: no "### signalKit-v0.3.0" section', errors[0]
        )

    def test_a_bundle_section_does_not_satisfy_a_package_tag(self):
        errors = check_tag.check_tag("registry-v0.6.1")

        self.assertEqual(1, len(errors))
        self.assertIn('no "### registry-v0.6.1" section', errors[0])

    def test_an_unknown_package_is_rejected(self):
        self.write_package_section("ghostKit-v1.0.0")

        errors = check_tag.check_tag("ghostKit-v1.0.0")

        self.assertEqual(1, len(errors))
        self.assertIn('package "ghostKit" does not exist', errors[0])

    def test_a_development_package_is_rejected(self):
        self.write_package_section("testKit-v0.2.0")

        errors = check_tag.check_tag("testKit-v0.2.0")

        self.assertEqual(1, len(errors))
        self.assertIn("development package", errors[0])

    def test_a_version_other_than_the_manifest_is_rejected(self):
        self.write_package_section("signalKit-v0.4.0")

        errors = check_tag.check_tag("signalKit-v0.4.0")

        self.assertEqual(1, len(errors))
        self.assertIn("packages/signalKit/package.manifest.json", errors[0])
        self.assertIn("version is 0.3.0, but the tag says 0.4.0", errors[0])

    def test_every_problem_is_reported_together(self):
        errors = check_tag.check_tag("signalKit-v0.4.0")

        self.assertEqual(2, len(errors))
        self.assertIn("the tag says 0.4.0", errors[0])
        self.assertIn('no "### signalKit-v0.4.0" section', errors[1])


class CheckTagCommandLineTests(ReleaseRepository):
    def test_main_reports_success_and_failure(self):
        with mock.patch.object(check_tag, "check_tag", return_value=[]):
            with redirect_stdout(io.StringIO()) as output:
                self.assertEqual(0, check_tag.main(["v1.1.0"]))
        self.assertIn("releasable", output.getvalue())

        with mock.patch.object(check_tag, "check_tag", return_value=["broken"]):
            with redirect_stderr(io.StringIO()) as output:
                self.assertEqual(1, check_tag.main(["v1.1.0"]))
        self.assertIn("broken", output.getvalue())

    def test_github_output_is_appended_on_success(self):
        output_file = self.root / "github_output"
        output_file.write_text("earlier=1\n", encoding="utf-8")

        with redirect_stdout(io.StringIO()):
            status = check_tag.main(["v1.1.0", "--github-output", str(output_file)])

        self.assertEqual(0, status)
        self.assertEqual(
            "earlier=1\ntag=v1.1.0\nkind=bundle\npackage=\nversion=1.1.0\n",
            output_file.read_text(encoding="utf-8"),
        )

    def test_github_output_is_untouched_on_failure(self):
        output_file = self.root / "github_output"

        with redirect_stderr(io.StringIO()):
            status = check_tag.main(["v9.0.0", "--github-output", str(output_file)])

        self.assertEqual(1, status)
        self.assertFalse(output_file.exists())


class NotesTests(ReleaseRepository):
    def test_prints_the_section_body(self):
        with redirect_stdout(io.StringIO()) as output:
            status = notes.main(["v1.1.0"])

        self.assertEqual(0, status)
        self.assertTrue(output.getvalue().startswith("- `registry` 0.6.1"))
        self.assertIn("Adds the signal bus.", output.getvalue())

    def test_missing_section_exits_non_zero(self):
        with redirect_stderr(io.StringIO()):
            self.assertEqual(1, notes.main(["v3.0.0"]))


class LibraryTocTests(unittest.TestCase):
    """The standalone addon's .toc, generated from the real repository."""

    def release_load_order(self):
        manifests = build.load_valid_manifests()
        return build.select_packages(manifests).ordered

    def test_carries_the_supported_interface_line_and_the_fields(self):
        from tooling.validation.interface_numbers import load_supported_clients

        lines = library_toc.standalone_toc().text.splitlines()

        self.assertEqual(load_supported_clients().toc_line(), lines[0])
        for field in (
            "## Title: MoltenCodes",
            "## Author: MoltenCodes",
            "## Version: @project-version@",
            "## IconTexture: Interface\\Icons\\INV_Misc_Gear_01",
            "## X-Category: Libraries",
            "## X-License: MIT",
            "## X-Website: https://github.com/MoltenCodes/core",
        ):
            self.assertIn(field, lines)
        notes = [line for line in lines if line.startswith("## Notes: ")]
        self.assertEqual(1, len(notes))
        self.assertIn("instead of embedding it", notes[0])

    def test_lists_every_release_package_in_load_order(self):
        from tooling.package import toc

        text = library_toc.standalone_toc().text
        ordered = self.release_load_order()

        expected = [
            toc.toc_entry(name, relative) for name in ordered for relative in build.runtime_files(name)
        ]
        self.assertEqual(expected, toc.listed_files(text))
        self.assertEqual("registry\\Registry.lua", toc.listed_files(text)[0])

    def test_leaves_out_development_packages(self):
        from tooling.package import toc

        listed = toc.listed_files(library_toc.standalone_toc().text)

        self.assertFalse([entry for entry in listed if entry.startswith("testKit\\")])

    def test_a_single_package_toc_lists_its_closure(self):
        from tooling.package import toc

        addon = library_toc.standalone_toc("timerKit")

        self.assertEqual("MoltenCodes-TimerKit", addon.name)
        self.assertEqual("MoltenCodes-TimerKit.toc", addon.file_name)
        self.assertIn("## Title: MoltenCodes-TimerKit", addon.text.splitlines())
        self.assertEqual(
            ["registry\\Registry.lua", "timerKit\\TimerKit.lua"], toc.listed_files(addon.text)
        )

    def test_matches_what_the_builder_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            build.build(Path(directory), package_name="signalKit")
            written = (
                Path(directory) / "MoltenCodes-SignalKit" / "MoltenCodes-SignalKit.toc"
            ).read_text(encoding="utf-8")

        self.assertEqual(library_toc.standalone_toc("signalKit").text, written)

    def test_name_matches_package_as_in_pkgmeta(self):
        text = (history.ROOT / ".pkgmeta").read_text(encoding="utf-8")

        self.assertIn(f"package-as: {library_toc.standalone_toc().name}", text)

    def test_main_writes_the_toc(self):
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(0, library_toc.main([]))

        self.assertEqual(library_toc.standalone_toc().text, output.getvalue())

    def test_main_writes_a_file_with_the_addon_name(self):
        with tempfile.TemporaryDirectory() as directory:
            with redirect_stdout(io.StringIO()) as output:
                status = library_toc.main(["--package", "timerKit", "--write", directory])
            target = Path(directory) / "MoltenCodes-TimerKit.toc"

            self.assertEqual(0, status)
            self.assertEqual(str(target), output.getvalue().strip())
            self.assertEqual(
                library_toc.standalone_toc("timerKit").text, target.read_text(encoding="utf-8")
            )

    def test_main_refuses_unknown_and_development_packages(self):
        for package in ("ghostKit", "testKit"):
            with self.subTest(package=package), redirect_stderr(io.StringIO()) as errors:
                self.assertEqual(1, library_toc.main(["--package", package]))
            self.assertIn(package, errors.getvalue())

    def test_help_prints_usage_instead_of_the_toc(self):
        output = io.StringIO()
        with redirect_stdout(output), self.assertRaises(SystemExit) as raised:
            library_toc.main(["--help"])

        self.assertEqual(0, raised.exception.code)
        self.assertIn("usage:", output.getvalue())
        self.assertNotIn("## Interface", output.getvalue())

    def test_rejects_unknown_arguments(self):
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
            library_toc.main(["--bogus"])

        self.assertEqual(2, raised.exception.code)


PKGMETA = """\
# A comment.
package-as: MoltenCodes

enable-nolib-creation: no # trailing comment

ignore:
  - packages/testKit
  - docs

move-folders:
  MoltenCodes/packages/registry/src: MoltenCodes/registry
  MoltenCodes/packages/registry/docs: MoltenCodes/registry/docs
  MoltenCodes/packages/signalKit/src: MoltenCodes/signalKit
  MoltenCodes/packages/timerKit/src: MoltenCodes/timerKit
"""


class PkgmetaTests(unittest.TestCase):
    def test_parses_scalars_lists_and_maps_in_order(self):
        data = pkgmeta.parse_pkgmeta(PKGMETA)

        self.assertEqual(
            ["package-as", "enable-nolib-creation", "ignore", "move-folders"], list(data)
        )
        self.assertEqual("no", data["enable-nolib-creation"])
        self.assertEqual(["packages/testKit", "docs"], data["ignore"])
        self.assertEqual(
            ("MoltenCodes/packages/registry/src", "MoltenCodes/registry"), data["move-folders"][0]
        )

    def test_rendering_round_trips(self):
        data = pkgmeta.parse_pkgmeta(PKGMETA)

        self.assertEqual(data, pkgmeta.parse_pkgmeta(pkgmeta.render_pkgmeta(data, ["Header."])))

    def test_unreadable_shapes_fail_closed(self):
        for text in (
            "no colon here\n",
            "  - orphan entry\n",
            "ignore:\n  - a\n  b: c\n",
            "move-folders:\n  a: b\n  - c\n",
        ):
            with self.subTest(text=text), self.assertRaises(pkgmeta.PkgmetaError):
                pkgmeta.parse_pkgmeta(text)

    def test_narrows_to_the_closure_under_the_new_name(self):
        data = pkgmeta.parse_pkgmeta(PKGMETA)

        narrowed = pkgmeta.package_pkgmeta(
            data,
            addon="MoltenCodes-SignalKit",
            closure=["registry", "signalKit"],
            all_packages=["registry", "signalKit", "testKit", "timerKit"],
            extra_ignores=[".pkgmeta-package"],
        )

        self.assertEqual("MoltenCodes-SignalKit", narrowed["package-as"])
        self.assertEqual("no", narrowed["enable-nolib-creation"])
        self.assertEqual(
            ["packages/testKit", "docs", "packages/timerKit", ".pkgmeta-package"],
            narrowed["ignore"],
        )
        self.assertEqual(
            [
                ("MoltenCodes-SignalKit/packages/registry/src", "MoltenCodes-SignalKit/registry"),
                (
                    "MoltenCodes-SignalKit/packages/registry/docs",
                    "MoltenCodes-SignalKit/registry/docs",
                ),
                ("MoltenCodes-SignalKit/packages/signalKit/src", "MoltenCodes-SignalKit/signalKit"),
            ],
            narrowed["move-folders"],
        )

    def test_missing_keys_fail_closed(self):
        for text in (
            "ignore:\n  - a\nmove-folders:\n  a: b\n",
            "package-as: X\nmove-folders:\n  a: b\n",
            "package-as: X\nignore:\n  - a\n",
        ):
            with self.subTest(text=text), self.assertRaises(pkgmeta.PkgmetaError):
                pkgmeta.package_pkgmeta(
                    pkgmeta.parse_pkgmeta(text), addon="Y", closure=[], all_packages=[]
                )

    def test_the_repository_pkgmeta_narrows_to_one_kit(self):
        text = pkgmeta.single_package_pkgmeta("timerKit", ".pkgmeta-package")
        data = pkgmeta.parse_pkgmeta(text)

        self.assertEqual("MoltenCodes-TimerKit", data["package-as"])
        moved = {source for source, _ in data["move-folders"]}
        self.assertEqual(
            {
                "MoltenCodes-TimerKit/packages/registry/src",
                "MoltenCodes-TimerKit/packages/registry/docs",
                "MoltenCodes-TimerKit/packages/timerKit/src",
                "MoltenCodes-TimerKit/packages/timerKit/docs",
            },
            moved,
        )
        manifests = build.load_valid_manifests()
        for name in manifests:
            if name not in ("registry", "timerKit"):
                self.assertIn(f"packages/{name}", data["ignore"])
        self.assertNotIn("packages/timerKit", data["ignore"])
        self.assertIn(".pkgmeta-package", data["ignore"])
        self.assertIn(".pkgmeta", data["ignore"])
        self.assertTrue(text.startswith("# Generated by"))

    def test_every_release_package_narrows(self):
        manifests = build.load_valid_manifests()
        for name in build.select_packages(manifests).ordered:
            with self.subTest(package=name):
                data = pkgmeta.parse_pkgmeta(pkgmeta.single_package_pkgmeta(name))
                closure = build.select_packages(manifests, name).ordered
                moved = {source.split("/")[2] for source, _ in data["move-folders"]}
                self.assertEqual(set(closure), moved)

    def test_main_writes_the_file(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / ".pkgmeta-package"
            with redirect_stdout(io.StringIO()):
                status = pkgmeta.main(["--package", "timerKit", "--output", str(target)])

            self.assertEqual(0, status)
            self.assertIn("  - .pkgmeta-package", target.read_text(encoding="utf-8"))

    def test_main_prints_without_output(self):
        with redirect_stdout(io.StringIO()) as output:
            self.assertEqual(0, pkgmeta.main(["--package", "registry"]))

        self.assertIn("package-as: MoltenCodes-Registry", output.getvalue())

    def test_main_refuses_a_development_package(self):
        with redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(1, pkgmeta.main(["--package", "testKit"]))

        self.assertIn("development", errors.getvalue())


class RepositoryReleaseHistoryTests(unittest.TestCase):
    """Every release already recorded in the real docs/RELEASES.md still checks out."""

    def test_recorded_releases_have_a_valid_tag_format(self):
        for tag in history.release_sections(history.read_releases()):
            with self.subTest(tag=tag):
                check_tag.parse_tag(tag)


if __name__ == "__main__":
    unittest.main()
