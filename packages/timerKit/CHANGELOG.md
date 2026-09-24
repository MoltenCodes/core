# Changelog

## 0.6.2 — 2026-09-24

- Nil rule (decision of 2026-09-24): absence of a value that comes from outside the Kit (the `repeating` option, the Registry lookups, the optional LifecycleKit and EventKit facades, the host timer handle) is tested with `type(value) == "nil"`, never by comparing it with `nil`, because comparing a secret value raises inside the Kit instead of at the caller.
- A secret delay or interval (`After`, `Every`, `New`), a secret `repeating` option, a secret addon name (`ForAddon`, `CloseAddonScopes`) and a secret receiver of `CloseAddonScopes` are refused at the caller's line before any comparison, instead of raising inside TimerKit. `issecretvalue` is read once at load; a host without it has no secret values. `docs/API.md` lists the messages under "Errors".
- Implementation revision 9, because the executed implementation changed. No state changed. The upgrade specs compare with the working revision instead of a fixed number, and a new one upgrades the previous revision in place; new `SecretValues_spec.lua`.

## 0.6.1 — 2026-09-24

- Cancelling a running timer and starting one no longer allocate a closure to read the host handle's `Cancel` method: the protected read calls a file-level function. 2000 cancellations allocated about 170 KiB before and allocate nothing now; `CancelAll()` and `Close()` also stop allocating a sort comparator per call.
- Implementation revision 8. No state changed: an in-place upgrade from revision 7 keeps its timers, their host handles, the addon scopes and their logout routes, and the upgrade from older revisions is unchanged.
- `docs/API.md` gains "Errors", listing every message TimerKit raises and where it points, and "Cost", what each operation allocates. The README names `TimerKit:New` beside the other package-level convenience methods.
- Specs: new `Allocation_spec.lua` (a repeating tick and a cancellation allocate nothing); `Bootstrap_spec.lua` covers the revision-7 upgrade with running timers and a `PLAYER_LOGOUT` route. The test environment gains `AllocatedKilobytes`.
- `Property_spec.lua` draws its random operations from the high bits of an exact Park-Miller generator. The previous power-of-two-modulus generator overflowed double precision and its low bits, which picked the operation, cycled within a few steps.
- `TimerKit` API generation 1 is unchanged.

## 0.6.0 — 2026-09-23

- An addon scope now closes at logout whenever LifecycleKit or EventKit is loaded, whatever revisions are paired; 0.5.0 left it open when paired with a LifecycleKit older than 0.5.0 or loaded without LifecycleKit. The first `TimerKit:ForAddon(addonName)` decides who calls `CloseAddonScopes`, finding the optional Kits through `Registry:Find`: a LifecycleKit that lists `"timerKit"` in `CLOSES_ADDON_SCOPES` (LifecycleKit 0.6.0) makes the call itself; the Kit subscribes nothing and only calls `LifecycleKit:ForAddon(addonName)` once, so an addon that never used LifecycleKit is still closed, and nothing else is subscribed; an older LifecycleKit gets one `OnShutdown` subscription per addon, kept on the scope and disconnected when the scope closes, and it steps aside if a capable LifecycleKit replaced it before logout; without LifecycleKit, one package-level EventKit `PLAYER_LOGOUT` one-shot, in an EventKit scope of TimerKit's own, closes every addon scope neither LifecycleKit route covers; with neither, nothing is subscribed and the addon makes the call. The last outcome is examined again at the next `ForAddon`. Documented under "At logout" in `docs/API.md`, including the ordering each case gives.
- LifecycleKit and EventKit are declared under `optionalDependencies`. TimerKit still embeds as two files and depends on Registry alone.
- `Scope:Close()` on an addon scope, and `CloseAddonScopes`, release the scope's LifecycleKit subscription.
- Implementation revision 7. Package state gains `logoutConnection` and `logoutEventScope` without a schema change, and the shared dispatch table gains `closeOnShutdown` and `closeOnLogout`, which the subscriptions and the connection resolve when they fire. An in-place upgrade from revision 6 or older routes every carried addon scope as a first `ForAddon` would (after releasing revision 5's own subscriptions, as before); a scope already routed keeps its subscription or connection.
- Specs: new `LogoutCoverage_spec.lua` (the four cases against the real LifecycleKit and EventKit, a LifecycleKit with its capability field removed, subscription release on `CloseAddonScopes` and `Close`, a capable LifecycleKit replacing an older one, connection order against scoped `PLAYER_LOGOUT` listeners, a failing close, re-examination after EventKit or LifecycleKit loads, and upgrades that route, or carry the routes of, an older copy). The test environment gains `LoadEventKit`, `LoadLifecycleKit` and `LoadRevision`.
- `TimerKit` API generation 1 is unchanged.

## 0.5.0 — 2026-09-23

- TimerKit no longer requires LifecycleKit (design constitution, principle 4b). The manifest lists Registry API 2 only, the load-time LifecycleKit facade check is gone, and TimerKit embeds as two files: Registry and TimerKit.
- `TimerKit:ForAddon(addonName)` still returns one canonical scope per addon, but no longer subscribes to the addon's shutdown. Added `TimerKit:CloseAddonScopes(addonName)`, the second half of the two-step EventKit, HookKit, CommandKit and CommKit already use: it cancels every timer of the addon's scope and closes it terminally, returns `false` when the addon never had a scope (recording nothing) or it was already closed, and must be called on the facade. LifecycleKit 0.5.0 makes the call at shutdown; without LifecycleKit an addon calls it on `PLAYER_LOGOUT`.
- Behaviour change for an addon that asks for its scope after its lifecycle already shut down: revision 5 handed back a closed scope, this revision hands back an open one until `CloseAddonScopes` is called.
- Implementation revision 6. An in-place upgrade from revision 5 or older disconnects the LifecycleKit shutdown subscription each carried addon scope held (best-effort; one that cannot be disconnected only closes an already closed scope at shutdown) and keeps the scopes and their timers working. `CloseAddonScopes` joins the public-surface check.
- Specs: the module chain is Registry and TimerKit. `Lifecycle_spec.lua` became `AddonScopes_spec.lua` (the two-step by hand, terminal closure, unknown addons, facade receiver, self-close from a callback, cancellation failures); the logout integration specs moved to LifecycleKit's suite, where both Kits load. New bootstrap specs cover loading with Registry alone and the revision-5 upgrade; `ErrorLevels_spec.lua` covers the new method's argument and receiver errors.
- `docs/API.md` gains a "Limits" section: TimerKit holds no cap to open (design constitution, principle 4a), and names what it retains.
- `TimerKit` API generation 1 is unchanged; the addition is compatible.

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
