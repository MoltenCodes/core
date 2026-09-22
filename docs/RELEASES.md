# Releases

Packages are independently versioned and will be released independently.

## Current status

Automated build and publication tooling is not implemented yet. This document defines the release contract that future tooling must enforce; it does not imply that a release command currently exists.

## Versioning

Package versions use Semantic Versioning.

A release artifact must match the `version` in its package manifest. Runtime `api` and `revision` have separate meanings described in [`PACKAGE_MANIFEST.md`](PACKAGE_MANIFEST.md) and must not be inferred from the SemVer release number.

## Tags

The intended tag convention is:

```text
<package>-v<version>
```

Example:

```text
registry-v1.0.0
```

## Artifacts

Release artifacts should be generated from source and package metadata rather than assembled manually.

Generated artifacts are not sources of truth and should not be committed back into runtime source directories.

SHA-256 checksums should be generated automatically for release artifacts.

Future release tooling should fail closed when repository validation, tests, linting, formatting, or package metadata consistency checks fail.
