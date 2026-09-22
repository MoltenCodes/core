# Changelog

## 0.1.1 — 2026-09-22

- No runtime behaviour change. Revision 1 still describes the shipped implementation.
- Made the test-support `CreateFrame` stub raise a plain error when asked for a frame type it does not model. It previously called a luassert matcher, which is unavailable inside a `require`d support module and reported a confusing indexing failure instead of the real misuse.
- Annotated every deliberate `_G` access with the reason it crosses into the global table, so Selene reports the package clean without the `global_usage` lint being disabled repository-wide.
- Reformatted the package with StyLua 2.5.2. Whitespace, wrapping and quote style only; the compiled Lua is unchanged.

## 0.1.0

- Renamed the package identity and Lua facade from `events` / `Events` to `eventKit` / `EventKit` as part of the framework-wide Kit naming convention.

- Added lazy regular WoW event subscriptions.
- Added unit-filtered event subscriptions.
- Added one-shot subscriptions.
- Added explicit, idempotent connection lifecycle.
- Added shared-frame grouping and automatic unregistration.
- Added Registry-backed embedded-copy reconciliation.
