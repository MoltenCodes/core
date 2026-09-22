# Repository Tooling

`tooling/` contains repository automation. Nothing in this directory is shipped as a World of Warcraft runtime dependency.

## Commands

Validate the repository:

```bash
python3 -m tooling.validation.validate_repository
```

Run all package tests:

```bash
python3 -m tooling.test.run
```

Run one package's tests:

```bash
python3 -m tooling.test.run registry
```

Lint runtime Lua:

```bash
python3 -m tooling.lint
```

Run tooling unit tests:

```bash
python3 -m unittest discover -s tooling/tests -p "test_*.py"
```

Build a distributable bundle:

```bash
python3 -m tooling.package.build --all --out dist
python3 -m tooling.package.build --package signalKit --out dist --zip
```

See [`../docs/TOOLING.md`](../docs/TOOLING.md) for architecture and [`../docs/DEVELOPMENT.md`](../docs/DEVELOPMENT.md) for local setup.
