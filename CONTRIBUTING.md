# Contributing

Thank you for helping. The full guide, with the annotation rules, the taint
checklist and the rules for new packages, is
[`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md). This page is the short path.

## The five-minute path

1. **Install the toolchain** from [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md):
   Python 3.10 or newer, Lua 5.1.5 with LuaRocks and Busted, StyLua, Selene,
   lua-language-server, and Node.js for the spell check.
2. **Make one change to one Kit.** A pull request touches one package under
   `packages/`, plus the documentation and tooling that change with it. Work on
   two Kits is two pull requests, unless one cannot land without the other; say
   why in the description when that is the case.
3. **Run the gates** before you push; CI runs the same commands and more:

   ```bash
   python3 -m tooling.validation.validate_repository
   python3 -m unittest discover -s tooling/tests -p "test_*.py"
   python3 -m tooling.test.run
   python3 -m tooling.lint
   stylua --check .
   python3 -m tooling.spell
   python3 -m tooling.test.coverage   # slow; CI gates on per-package floors
   lua-language-server --check packages/<name>/src --checklevel=Warning
   actionlint
   ```

4. **Write conventional commit subjects**, `type(scope): subject`, with a type
   from `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `build`, `ci`,
   `perf`, `style` and the Kit or area as the scope:
   `fix(timerKit): cancel repeating timers at logout`. CI checks every commit
   and the pull request title; check yours with
   `python3 -m tooling.ci.check_commits origin/main..HEAD`.
5. **Keep assistant and editor-tool configuration out of the repository.** Do
   not commit personal configuration directories or instruction files for
   coding assistants; keep them in your home directory. The repository carries
   only the shared editor settings under `.vscode/`.

Then open the pull request and fill in its template. A changed Kit needs a
dated changelog entry and a `version` bump, and a `revision` bump when the
executed code changed; the template lists every check.

## Policies

- [Code of Conduct](CODE_OF_CONDUCT.md): everyone taking part follows it.
- [Security policy](SECURITY.md): report vulnerabilities privately.
- [Support](SUPPORT.md): where to ask questions and what to include.
- Contributions are accepted under the repository's [MIT licence](LICENSE).
