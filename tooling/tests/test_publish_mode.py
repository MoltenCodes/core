"""Tests for the release workflow's dry-run and draft-release rules."""

import io
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

from tooling.release import publish_mode


SITES = {"CURSEFORGE_PROJECT_ID": "101", "WAGO_ID": "abc", "WOWI_ID": "202"}


class PackagerModeTests(unittest.TestCase):
    def test_a_bundle_tag_with_every_variable_uploads(self):
        args, reason = publish_mode.packager_mode("bundle", "", SITES)

        self.assertEqual("-p 101 -a abc -w 202", args)
        self.assertIn("uploading", reason)

    def test_a_hand_run_with_dry_run_off_uploads_a_bundle(self):
        args, _ = publish_mode.packager_mode("bundle", "false", SITES)

        self.assertEqual("-p 101 -a abc -w 202", args)

    def test_the_dry_run_input_forces_a_dry_run(self):
        self.assertEqual(
            ("-d", "dry_run input is on"), publish_mode.packager_mode("bundle", "true", SITES)
        )

    def test_a_missing_site_variable_forces_a_dry_run(self):
        for name in SITES:
            variables = dict(SITES, **{name: ""})
            with self.subTest(missing=name):
                args, reason = publish_mode.packager_mode("bundle", "", variables)
                self.assertEqual("-d", args)
                self.assertIn(name, reason)

    def test_a_package_tag_never_uploads(self):
        for dry_run_input in ("", "false", "true"):
            with self.subTest(dry_run_input=dry_run_input):
                self.assertEqual(
                    "-d", publish_mode.packager_mode("package", dry_run_input, SITES)[0]
                )
        self.assertIn("package tag", publish_mode.packager_mode("package", "", SITES)[1])

    def test_an_unknown_kind_is_refused(self):
        with self.assertRaises(ValueError):
            publish_mode.packager_mode("nightly", "", SITES)


class DraftReleaseTests(unittest.TestCase):
    def test_a_pushed_or_hand_started_tag_ref_drafts(self):
        self.assertTrue(publish_mode.draft_release("tag", "v0.1.0", "v0.1.0"))

    def test_a_branch_ref_never_drafts(self):
        self.assertFalse(publish_mode.draft_release("branch", "main", "v0.1.0"))

    def test_a_tag_ref_other_than_the_released_tag_does_not_draft(self):
        self.assertFalse(publish_mode.draft_release("tag", "v0.1.0", "timerKit-v0.6.0"))

    def test_no_tag_never_drafts(self):
        self.assertFalse(publish_mode.draft_release("tag", "", ""))


class CommandLineTests(unittest.TestCase):
    def test_writes_args_and_draft(self):
        with tempfile.TemporaryDirectory() as directory:
            output_file = Path(directory) / "github_output"
            with redirect_stdout(io.StringIO()) as printed:
                status = publish_mode.main(
                    [
                        "--kind=package",
                        "--ref-type=tag",
                        "--ref-name=timerKit-v0.6.0",
                        "--tag=timerKit-v0.6.0",
                        f"--github-output={output_file}",
                    ],
                    environ=SITES,
                )

            self.assertEqual(0, status)
            self.assertEqual("args=-d\ndraft=true\n", output_file.read_text(encoding="utf-8"))
        self.assertIn("Dry run: a package tag never uploads", printed.getvalue())

    def test_reports_an_upload(self):
        with redirect_stdout(io.StringIO()) as printed:
            publish_mode.main(["--kind", "bundle"], environ=SITES)

        self.assertIn("Upload:", printed.getvalue())
        self.assertIn("Draft GitHub release: no", printed.getvalue())

    def test_mode_reports_dry_run(self):
        mode = publish_mode.publish_mode(
            kind="bundle",
            dry_run_input="true",
            variables=SITES,
            ref_type="tag",
            ref_name="v1.0.0",
            tag="v1.0.0",
        )

        self.assertTrue(mode.dry_run)
        self.assertEqual("args=-d\ndraft=true\n", publish_mode.github_outputs(mode))


if __name__ == "__main__":
    unittest.main()
