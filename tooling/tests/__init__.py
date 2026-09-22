"""Unit tests for the repository tooling.

This package exists so that `tooling/tests` and `tooling/test` cannot be
confused for each other. `tooling/test` is the Busted orchestration package that
`python3 -m tooling.test.run` imports; `tooling/tests` is this test suite, run
with `python3 -m unittest discover -s tooling/tests -p "test_*.py"`. The two
names differ by one letter, so the marker file spells out which is which rather
than leaving the reader to guess. The directories are deliberately not renamed:
both names appear in `docs/TOOLING.md`, `docs/DEVELOPMENT.md`, the editor tasks
and the CI workflow.
"""
