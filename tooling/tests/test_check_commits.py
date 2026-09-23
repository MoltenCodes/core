"""Tests for the conventional-commit subject check run on pull requests."""

import io
import subprocess
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

from tooling.ci import check_commits


class SubjectRuleTests(unittest.TestCase):
    def test_valid_subjects_pass(self):
        for subject in (
            "feat(timerKit): add GetRemaining",
            "fix(moduleKit): graph errors point at the caller; registry corruption found",
            "docs(repo): the roadmap names roles, not people",
            "chore(repo): tidy editor settings",
            "refactor(kits): one validation helper",
            "test(fixture): model frame scripts",
            "build(tooling): deterministic zips",
            "ci(deps): bump actions/checkout from 7.0.0 to 7.0.1",
            "perf(signalKit): no closure per Fire",
            "style(repo): StyLua 2.5.2",
            "feat(registry)!: API generation 3",
            "docs(kits,repo): minimum footprint in every README",
            "feat(timerKit): LifecycleKit is no longer required",
        ):
            with self.subTest(subject=subject):
                self.assertEqual([], check_commits.subject_problems(subject))

    def test_every_allowed_type_passes(self):
        for commit_type in check_commits.ALLOWED_TYPES:
            with self.subTest(commit_type=commit_type):
                self.assertEqual(
                    [], check_commits.subject_problems(f"{commit_type}(repo): a change")
                )

    def assertProblem(self, subject, fragment):
        problems = check_commits.subject_problems(subject)
        self.assertTrue(
            any(fragment in problem for problem in problems),
            f"{subject!r}: expected a problem containing {fragment!r}, got {problems!r}",
        )

    def test_an_unknown_type_is_refused(self):
        self.assertProblem("feature(timerKit): add GetRemaining", "allowed types")
        self.assertProblem("Feat(timerKit): add GetRemaining", "allowed types")

    def test_a_missing_scope_is_refused(self):
        self.assertProblem("feat: add GetRemaining", "no scope")

    def test_a_malformed_scope_is_refused(self):
        self.assertProblem("feat(): add GetRemaining", "scope `()`")
        self.assertProblem("feat(timer Kit): add GetRemaining", "scope")

    def test_the_colon_needs_exactly_one_space(self):
        self.assertProblem("feat(timerKit):add GetRemaining", "one space")
        self.assertProblem("feat(timerKit):  add GetRemaining", "one space")

    def test_an_empty_subject_text_is_refused(self):
        self.assertProblem("feat(timerKit): ", "whitespace")
        self.assertProblem("feat(timerKit):", "no text")

    def test_a_trailing_full_stop_is_refused(self):
        self.assertProblem("fix(timerKit): cancel on logout.", "full stop")

    def test_free_text_is_refused(self):
        self.assertProblem("Update README", "type(scope)")
        self.assertProblem("", "empty")

    def test_autosquash_commits_are_refused(self):
        for prefix in ("fixup!", "squash!", "amend!"):
            with self.subTest(prefix=prefix):
                self.assertProblem(f"{prefix} feat(timerKit): add GetRemaining", "squash it")


class RangeTests(unittest.TestCase):
    def completed(self, stdout="", returncode=0, stderr=""):
        return subprocess.CompletedProcess([], returncode, stdout=stdout, stderr=stderr)

    def test_reads_short_hashes_and_subjects_without_merges(self):
        output = "abc1234\x00feat(timerKit): add GetRemaining\ndef5678\x00Update README\n"
        with mock.patch.object(subprocess, "run", return_value=self.completed(output)) as run:
            commits = check_commits.read_commits("main..topic")

        command = run.call_args.args[0]
        self.assertIn("--no-merges", command)
        self.assertIn("main..topic", command)
        self.assertEqual(
            [
                check_commits.Commit("abc1234", "feat(timerKit): add GetRemaining"),
                check_commits.Commit("def5678", "Update README"),
            ],
            commits,
        )

    def test_a_git_failure_is_reported(self):
        failure = self.completed(returncode=128, stderr="fatal: bad revision 'x..y'")
        with mock.patch.object(subprocess, "run", return_value=failure):
            with self.assertRaisesRegex(RuntimeError, "bad revision"):
                check_commits.read_commits("x..y")


class CommandLineTests(unittest.TestCase):
    def run_main(self, argv):
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            status = check_commits.main(argv)
        return status, stdout.getvalue(), stderr.getvalue()

    def test_passing_subjects_exit_zero(self):
        status, stdout, _ = self.run_main(["--subject", "docs(repo): community files"])

        self.assertEqual(0, status)
        self.assertIn("1 subject(s)", stdout)

    def test_failing_subjects_exit_one_and_name_each(self):
        status, _, stderr = self.run_main(
            ["--subject", "docs(repo): fine", "--subject", "wip", "--subject", "feat: x"]
        )

        self.assertEqual(1, status)
        self.assertIn("'wip'", stderr)
        self.assertIn("'feat: x'", stderr)
        self.assertNotIn("'docs(repo): fine'", stderr)

    def test_an_unreadable_range_exits_two(self):
        with mock.patch.object(
            check_commits, "read_commits", side_effect=RuntimeError("shallow checkout")
        ):
            status, _, stderr = self.run_main(["a..b"])

        self.assertEqual(2, status)
        self.assertIn("shallow checkout", stderr)

    def test_the_range_and_the_title_are_checked_together(self):
        commits = [check_commits.Commit("abc1234", "fix(poolKit): release children")]
        with mock.patch.object(check_commits, "read_commits", return_value=commits):
            status, _, stderr = self.run_main(["a..b", "--subject", "Pool fixes"])

        self.assertEqual(1, status)
        self.assertIn("subject: 'Pool fixes'", stderr)

    def test_nothing_to_check_is_a_usage_error(self):
        with self.assertRaises(SystemExit) as raised, redirect_stderr(io.StringIO()):
            check_commits.main([])
        self.assertEqual(2, raised.exception.code)


if __name__ == "__main__":
    unittest.main()
