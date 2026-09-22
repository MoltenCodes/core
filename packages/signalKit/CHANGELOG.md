# Changelog

## 0.2.1 — 2026-09-22

- Normalised every LuaCATS annotation to the canonical `---@` form and completed the public surface: 35 annotation lines became 49. Every public function, method, facade table, class, field, alias and callback signature is now typed, so editors and `lua-language-server` describe the package instead of guessing.
- Renamed the LuaCATS types to `SignalKit.Signal` and `SignalKit.Connection`, and annotated the receiver of every public method so `signal:Connect(...)` autocompletes.
- Added `src/.luarc.json`. `lua-language-server --check <dir>` treats the directory it is given as its workspace root and ignores parent configuration, so each package source directory now points at the shared `meta/` definitions and at its own runtime dependencies. `packages/<name>/src` type-checks clean at `--checklevel=Warning`.
- Added the now-required `license` field (`MIT`) to `package.manifest.json`, matching the repository `LICENSE` that the release builder copies into every artifact.
- Added an "Embedding" section to the README with this package's load order and direct dependencies, pointing at the new `docs/EMBEDDING.md`.
- No runtime behaviour change. `IMPLEMENTATION_REVISION` is unchanged, and `luac -s -l` produces an identical instruction listing before and after, so no embedded copy carrying these edits displaces an equivalent copy.

## 0.2.0 — 2026-09-22

- `Connect`, `Once`, `Fire` and `DisconnectAll` now validate that they were called on a signal, and `Disconnect`/`IsConnected` that they were called on a connection handle. A dot call such as `SignalKit.Connect(callback)` raises a SignalKit error naming the misuse at the calling line instead of a raw `attempt to index a function value` from inside the package.
- `Disconnect` is now amortized `O(1)` and allocation-free. It marks a tombstone instead of copying the listener array, and the array is compacted once at least half of its slots are tombstones, so the array never retains more than twice the live listener count. Tearing down 4000 listeners one handle at a time went from 97.6 ms and 168 MB of garbage to 1.4 ms and 65 KB.
- `Fire` remains allocation-free; a spec now guards that with `collectgarbage("count")` deltas.
- Documented the measured complexity and allocation numbers in `docs/API.md`.
- Added specs for `Once` connected during a dispatch, `DisconnectAll` inside a nested `Fire`, compaction order and retention, and the in-place upgrade path for signals created by revision 1.
- Annotated the public surface with LuaCATS types.

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
