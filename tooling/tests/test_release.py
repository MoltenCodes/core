import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from tooling.release import check_tag, history, library_toc, notes
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
        self.write_releases(RELEASES)

    def tearDown(self):
        validate_manifests.ROOT, validate_manifests.PACKAGES, history.ROOT = self.originals
        self.tempdir.cleanup()

    def write_manifest(self, name, version, *, api, dependencies):
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


class CheckTagTests(ReleaseRepository):
    def test_a_consistent_tag_passes(self):
        self.assertEqual([], check_tag.check_tag("v1.1.0"))

    def test_a_per_package_tag_is_rejected(self):
        errors = check_tag.check_tag("registry-v0.6.1")

        self.assertEqual(1, len(errors))
        self.assertIn("not a bundle release tag", errors[0])

    def test_a_tag_without_v_prefix_is_rejected(self):
        self.assertEqual(1, len(check_tag.check_tag("1.1.0")))

    def test_a_prerelease_tag_is_accepted_when_documented(self):
        self.write_releases("## Release history\n\n### v1.2.0-beta.1\n\n- `registry` 0.6.1\n")

        self.assertEqual([], check_tag.check_tag("v1.2.0-beta.1"))

    def test_a_tag_without_a_section_is_rejected(self):
        errors = check_tag.check_tag("v2.0.0")

        self.assertEqual(1, len(errors))
        self.assertIn('no "### v2.0.0" section', errors[0])

    def test_a_section_listing_no_packages_is_rejected(self):
        self.write_releases("## Release history\n\n### v1.0.0\n\nNothing listed.\n")

        errors = check_tag.check_tag("v1.0.0")

        self.assertEqual(1, len(errors))
        self.assertIn("lists no", errors[0])

    def test_a_version_that_differs_from_the_manifest_is_rejected(self):
        errors = check_tag.check_tag("v1.0.0")

        self.assertEqual(1, len(errors))
        self.assertIn('"registry" is listed at 0.6.0, but its manifest says 0.6.1', errors[0])
        self.assertIn("docs/RELEASES.md:", errors[0])

    def test_an_unknown_package_is_rejected(self):
        self.write_releases("## Release history\n\n### v1.0.0\n\n- `ghostKit` 1.0.0\n")

        errors = check_tag.check_tag("v1.0.0")

        self.assertEqual(1, len(errors))
        self.assertIn('package "ghostKit" does not exist', errors[0])

    def test_a_package_listed_twice_is_rejected(self):
        self.write_releases(
            "## Release history\n\n### v1.0.0\n\n- `registry` 0.6.1\n- `registry` 0.6.1\n"
        )

        errors = check_tag.check_tag("v1.0.0")

        self.assertEqual(1, len(errors))
        self.assertIn("listed more than once", errors[0])

    def test_main_reports_success_and_failure(self):
        with mock.patch.object(check_tag, "check_tag", return_value=[]):
            with redirect_stdout(io.StringIO()) as output:
                self.assertEqual(0, check_tag.main(["v1.1.0"]))
        self.assertIn("releasable", output.getvalue())

        with mock.patch.object(check_tag, "check_tag", return_value=["broken"]):
            with redirect_stderr(io.StringIO()) as output:
                self.assertEqual(1, check_tag.main(["v1.1.0"]))
        self.assertIn("broken", output.getvalue())


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
    def test_carries_the_supported_interface_line_and_no_files(self):
        from tooling.validation.interface_numbers import load_supported_clients

        text = library_toc.library_toc()
        lines = text.splitlines()

        self.assertEqual(load_supported_clients().toc_line(), lines[0])
        self.assertIn("## Title: MoltenCodes", lines)
        self.assertIn("## Version: @project-version@", lines)
        listed_files = [line for line in lines if line and not line.startswith("#")]
        self.assertEqual([], listed_files)

    def test_name_matches_package_as_in_pkgmeta(self):
        pkgmeta = (history.ROOT / ".pkgmeta").read_text(encoding="utf-8")

        self.assertIn(f"package-as: {library_toc.PACKAGE_NAME}", pkgmeta)

    def test_main_writes_the_toc(self):
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(0, library_toc.main([]))

        self.assertEqual(library_toc.library_toc(), output.getvalue())

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


class RepositoryReleaseHistoryTests(unittest.TestCase):
    """Every release already recorded in the real docs/RELEASES.md still checks out."""

    def test_recorded_releases_have_a_valid_tag_format(self):
        for tag in history.release_sections(history.read_releases()):
            self.assertEqual([], check_tag.validate_tag_format(tag), tag)


if __name__ == "__main__":
    unittest.main()
