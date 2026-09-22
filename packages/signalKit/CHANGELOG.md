# Changelog

## 0.1.1 — 2026-09-22

- No runtime behaviour change. Revision 1 still describes the shipped implementation.
- Annotated every deliberate `_G` access with the reason it crosses into the global table, so Selene reports the package clean without the `global_usage` lint being disabled repository-wide.
- Reformatted the package with StyLua 2.5.2. Whitespace, wrapping and quote style only; the compiled Lua is unchanged.

## 0.1.0

- Renamed the package identity and Lua facade from `signal` / `Signal` to `signalKit` / `SignalKit` as part of the framework-wide Kit naming convention.

- Added SignalKit API generation 1, implementation revision 1.
- Added deterministic connection-order dispatch.
- Added `Connect`, `Once`, `Fire`, and `DisconnectAll`.
- Added connection handles with idempotent `Disconnect` and `IsConnected`.
- Defined mutation-safe and recursive dispatch semantics.
- Added fixed-boundary dispatch with `O(1)` listener append and copy-on-write disconnect so `Fire()` does not allocate a listener snapshot.
- Added Registry API 2 bootstrap and duplicate-embedding behavior.
