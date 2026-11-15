# 0002. Secret-value checks only where the client answers

- Status: Accepted
- Date: 2026-11-15

## Context

On Retail 12.x the client hands addons secret values: values an addon may
store and pass on but not compare, test or use as a table key. The Kits ask
`issecretvalue` before they act on a value, so a secret never reaches an
operation that would raise inside the Kit.

Some of those checks guard what the client already refuses on its own.
Measured on Retail 12.1.0 build 69933 (the table in `docs/EMBEDDING.md`,
"Secret values"), indexing a table with a secret key raises at the indexing
line, before any `__index` metamethod runs, with the message
`attempted to index a table that cannot be indexed with secret keys`. A check
in front of such an index adds a call on a hot path and protects nothing: the
error already names the caller's line.

## Decision

1. Secret-value checks that guard only what the client already refuses, such
   as a secret used as a table key, are removed.
2. Every other check stays: on arguments a caller passes to a Kit, and on
   values the client answers that a Kit then compares, tests or stores as a
   key.
3. The client suites assert the client's own refusal, so a client that
   stopped refusing would be noticed.

## Consequences

- Hot paths that only index tables with caller-supplied keys lose a call per
  operation.
- The error for a secret key is the client's message at the caller's line
  rather than a Kit's message; each Kit's `docs/API.md` says so in its
  "Secret values" section.
- This is the one documented guarantee the 2026-11-15 performance work
  drops; every other guarantee stays.
