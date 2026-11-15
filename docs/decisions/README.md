# Decisions

This directory records the project's architecture decisions, one short file
per decision. A decision record (often called an ADR, architecture decision
record) says what was decided, why, and what follows from it, so a
contributor who meets a rule in the code can find the reason without asking.

## When to write one

Write a record when a choice shapes how Kits are built, shipped or used and a
reasonable contributor could have chosen otherwise: the layout of a Kit, what
the framework guarantees, which checks stay, what an addon author must do.
Bug fixes, naming and anything one Kit decides for itself do not need one;
they belong in that Kit's documentation.

## Numbering

Records are numbered in sequence from `0001`, in the order they are accepted,
and a number is never reused. The file name is the number and a short title
in lower case words joined by hyphens:
`0001-kit-core-and-parts.md`. Refer to a record as "ADR 0001" with a link to
its file.

A record is never deleted or rewritten once accepted. When a later decision
changes it, the new record says what it replaces, and the old one's status
becomes "Superseded by ADR NNNN"; nothing else in it changes, so the history
stays readable.

## Template

```markdown
# NNNN. Title in plain words

- Status: Accepted (or: Superseded by ADR NNNN)
- Date: YYYY-MM-DD

## Context

What problem or question forced a choice, with the facts and measurements
it rests on.

## Decision

What was decided, stated so that code and reviews can be held to it.

## Consequences

What becomes easier, what becomes harder, what other documents and tools
change, and what is deliberately left for later.
```

Keep a record under about 60 lines. Link to the measured evidence and to the
documents that carry the details rather than repeating them.

## Records

| ADR | Title | Status |
|---|---|---|
| [0001](0001-kit-core-and-parts.md) | A Kit is a core file plus optional parts | Accepted |
| [0002](0002-secret-checks-only-where-the-client-answers.md) | Secret-value checks only where the client answers | Accepted |
| [0003](0003-method-name-callbacks.md) | Method-name callbacks, checked at registration | Accepted |
| [0004](0004-addon-kit-entry-point.md) | AddonKit, the single entry point | Accepted |
