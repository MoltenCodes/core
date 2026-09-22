# Tooling

Repository tooling lives under `tooling/` and is never a runtime dependency.

## Current tooling

```text
tooling/
├── lint.py                         # recursively discovers and lints runtime Lua
├── test/
│   └── run.py                     # package-aware Busted orchestration
├── tests/                         # Python unit tests for repository tooling
└── validation/
    ├── validate_manifests.py      # manifest schema and dependency graph checks
    └── validate_repository.py     # repository structure and Markdown link checks
```

The canonical commands are documented in [`DEVELOPMENT.md`](DEVELOPMENT.md).

## Design rules

- Tooling discovers packages from repository structure and manifests.
- Runtime code never imports or depends on tooling.
- CI and editor tasks call repository tooling instead of duplicating package lists.
- Tooling should be deterministic and produce actionable repository-relative errors.
- Prefer the Python standard library for repository tooling until a third-party dependency provides clear value.
- New tooling must have focused unit tests when its behavior is more than a trivial command wrapper.

## Future tooling

Build and release tooling will be added only when implemented. Empty placeholder directories are intentionally avoided because they imply capabilities that do not yet exist.

Likely future responsibilities include:

- dependency-aware build ordering;
- package artifact generation;
- reproducibility checks;
- release validation;
- checksums and publication metadata.
