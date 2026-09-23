# Changelog

## 0.4.1 — 2026-09-23

- TimerKit no longer fails to load on a host without `GetTimePreciseSec`. 0.4.0 made the clock a load requirement, which contradicted the documented host requirements and added a client facility inside API generation 1. The clock is optional again: without it every timer behaves as before and `GetRemaining()` / `GetDeadline()` return `nil`, documented in `docs/API.md` and the README.
- Implementation revision 5. The bootstrap spec that required the clock now loads TimerKit with the clock stub removed and checks that timers still fire and report `nil`.

## 0.4.0 — 2026-09-23

- Added `Timer:GetRemaining()` and `Timer:GetDeadline()`. While a timer is `running` they return the seconds until its next fire and the instant of that fire on the `GetTimePreciseSec()` clock; in every other state they return `nil`, never `0`, so "about to fire" and "will not fire" stay distinguishable. A repeating timer reports its next tick, and `Start`/`Restart` compute a fresh deadline.
- The deadline is TimerKit's own record of when it asked `C_Timer` to fire, so the remaining time is documented as an estimate: the host delivers on the first frame at or after it. An overdue timer reports `0` rather than a negative number.
- TimerKit reads `GetTimePreciseSec` once per start and once per repeating tick; nothing else on the dispatch path changed. (0.4.0 required the clock at load; 0.4.1 makes it optional again.)
- Timer handles carry one more private field, created as `false` with the handle so the first start does not rehash it.
- Implementation revision 4. Timers started by an older embedded revision keep running after the upgrade and report `nil` until their next start or tick; bootstrap specs cover both cases and the new load requirement. Twelve new specs cover running, repeating, cancelled, completed, idle, restarted, overdue and rolled-back timers and the caller's line for receiver errors.
- Added a table-of-contents header to `src/TimerKit.lua`, which exceeds 400 lines.
- `TimerKit` API generation 1 is unchanged; the additions are compatible.

## 0.3.0 — 2026-09-22

- Moved the bootstrap handshake onto `Registry:Bootstrap`. The package lookup, the refusal to reinterpret a newer revision's private state, the registration and the inherited-revision reporting now live in Registry; what stays here is the dependency check, the public-surface predicate, the state predicate and the migration itself.
- Registry is now resolved as `MoltenCodes.Registries[2]` with the `MoltenCodes.Registry` alias as the fallback. The alias belongs to the newest Registry generation loaded, so an eventual API 3 would otherwise hand this file a contract it was not written against.
- Implementation revision 3. The executed bootstrap changed, and an older embedded copy upgrades in place exactly as before; the package's bootstrap specs cover the upgrade, the retired-state and corrupted-facade refusals, and the load-order cases.
- No public API change. `TimerKit` API generation 1 is unchanged.

## 0.2.1 — 2026-09-22

- Normalised every LuaCATS annotation to the canonical `---@` form and completed the public surface: 91 annotation lines became 187. Every public function, method, facade table, class, field, alias and callback signature is now typed, so editors and `lua-language-server` describe the package instead of guessing.
- Renamed the LuaCATS types to `TimerKit`, `TimerKit.Timer`, `TimerKit.Scope`, `TimerKit.TimerState` and `TimerKit.TimerOptions`, and added the `TimerKit.Callback` alias.
- Annotated every internal helper, including the stack-level arguments that decide which line an argument error points at.
- Added `src/.luarc.json`. `lua-language-server --check <dir>` treats the directory it is given as its workspace root and ignores parent configuration, so each package source directory now points at the shared `meta/` definitions and at its own runtime dependencies. `packages/<name>/src` type-checks clean at `--checklevel=Warning`.
- Added the now-required `license` field (`MIT`) to `package.manifest.json`, matching the repository `LICENSE` that the release builder copies into every artifact.
- Added an "Embedding" section to the README with this package's load order and direct dependencies, pointing at the new `docs/EMBEDDING.md`.
- No runtime behaviour change. `IMPLEMENTATION_REVISION` is unchanged, and `luac -s -l` produces an identical instruction listing before and after, so no embedded copy carrying these edits displaces an equivalent copy.

## 0.2.0 — 2026-09-22

- Added `Timer:SetUserData(value)` and `Timer:GetUserData()`, a documented public seam for attaching one opaque owner-defined value to a timer. Consumers that need to associate their own state with a timer no longer have to write private fields onto a TimerKit handle. Attaching a value allocates nothing and survives cancel/restart; TimerKit never reads or clears it.
- Normalised every `error` level so argument failures report the line that called the public method. Previously `scope:After(1, "nope")`, `TimerKit:After(...)`, timer/scope receiver checks, option-table fields, and closed-scope rejections reported one stack level too deep, which stripped the `file:line` prefix from the message or pointed it at the wrong frame.
- Made `New()` option validation allocation-free. The allowed-field set is now a file-local constant instead of a table built per call, and the first unknown field is found by tracking the smallest key rather than collecting and sorting every offender.
- Removed a dead counter update in bulk cancellation: a failed native cancel incremented the cancelled total on a path that always re-raises before returning it.
- Documented same-instant timer ordering as host-defined, and documented that argument errors point at the caller.
- Added LuaCATS annotations for the package facade, `Timer`, `Scope`, and the option table.

## 0.1.1 — 2026-09-22

- No runtime behaviour change. Revision 1 still describes the shipped implementation.
- Pointed the test-support helpers at luassert explicitly and made the `CreateFrame` stub raise a plain error when asked for a frame type it does not model. Busted injects luassert into spec chunks only, so the support module previously failed on Lua's own `assert` global.
- Annotated every deliberate `_G` access with the reason it crosses into the global table, so Selene reports the package clean without the `global_usage` lint being disabled repository-wide.
- Reformatted the package with StyLua 2.5.2. Whitespace, wrapping and quote style only; the compiled Lua is unchanged.

## 0.1.0

- Added TimerKit API generation 1.
- Added cancelable one-shot and repeating timers.
- Added idle/start/cancel/restart/completion state management.
- Added generation guards that suppress stale native callbacks after cancel/restart.
- Added manual timer scopes with deterministic bulk cancellation and terminal close.
- Added addon-owned scopes that close automatically through LifecycleKit shutdown.
- Added native creation rollback and best-effort cleanup after cancellation errors.
- Added strict input validation and runtime/manifest consistency tests.
