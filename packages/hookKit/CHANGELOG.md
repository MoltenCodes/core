# Changelog

## 0.2.5 — 2026-09-24

- Unhooking a `HookScript` or `RawHookScript` no longer compares a secret script handler. `GetScript` is flagged `ConstSecretAccessor` in the Retail 12.1.0 metadata, so while restrictions apply it may return a secret function, and comparing a secret with a value of its own type raises (measured on Retail 12.1.0 b69933). The handler is now asked about with `IsSecret` (or `issecretvalue`) first, and a secret one is treated as "someone hooked the target after HookKit": the closure stays, inert, forwarding to the previous script, `SetScript` is not called, and `Unhook` returns `true`. Documented under "Unhook: restore or go inert" in `docs/API.md`.
- Implementation revision 5, because the executed implementation changed. No state or scope layout changed: an upgrade over revision 4 replaces the methods, and scopes an older copy opened release by the new rule at once. `docs/API.md` states the implementation revision as 5 (it still said 3).
- Specs: 117 → 121. A secret current handler leaves the `HookScript` and `RawHookScript` closure in place, with ClientKit and with `issecretvalue` alone; a plain handler is still restored; a script hook installed by a revision 4 copy is released by the new rule after an in-place upgrade.

## 0.2.4 — 2026-09-24

- A secret `options.forceSecure` of `Hook`, `RawHook`, `HookScript` or `RawHookScript` is refused at the caller's line with `<method> options.forceSecure must not be a secret value`, before HookKit compares or tests it. A secret boolean passes the type check, and on Retail 12.1.0 (build 69933) testing a secret boolean raises in tainted code, so before this the call raised inside HookKit. Documented under "Refusals" in `docs/API.md`.
- Implementation revision 4, because the executed implementation changed. No state changed. Specs: the four methods refuse a secret `forceSecure` at the caller, with ClientKit and with `issecretvalue` alone, and a plain `forceSecure` is still accepted; the upgrade spec now runs from revision 2 and from the previous revision to the working file.

## 0.2.3 — 2026-09-24

- Secret values: the source comments on `maxHooks` validation and the facade check no longer claim that comparing a secret with anything, `nil` included, raises, or that a raw identity test is safe whatever the other side. They state what was measured on Retail 12.1.0 b69933 (2026-09-24): a secret compared with a value of its own type raises (`==`, `~=`, `<`, `<=` and `rawequal` alike) and a secret used as a table key raises, while a comparison with `nil` or with a value of another type answers without raising. The `type(value) == "nil"` rule stays, as the repository's uniform rule that never compares anything. Comments and documentation only: `luac -s -l` gives the same instruction listing before and after, so the implementation revision is unchanged.

## 0.2.2 — 2026-09-24

- Implementation revision 3 applies the repository nil rule: the absence of a caller's option table or option field (`options`, `options.forceSecure`, `options.maxHooks`) and of a caller object's raw field (the `__index` holder search and `_hadRaw`) is tested with `type(value) == "nil"`, never by comparing the value with `nil`. The Registry lookup, the results of `Registry:Bootstrap` and the optional ClientKit, LifecycleKit and EventKit that `Registry:Find` returns are tested the same way.
- `CreateScope` and `ForAddon` ask whether `options.maxHooks` is secret before comparing it with `HookKit.UNBOUNDED`; a secret is still refused with the same message at the caller. Before, the sentinel comparison came first.
- Specs: the secret probe asked before the sentinel comparison, an in-place upgrade from revision 2 to the working file, and the revision 1 logout-layout upgrade now loads the working file instead of a fixed revision 2.

## 0.2.1 — 2026-09-24

- Documentation only; the executed code is unchanged, so the implementation revision stays 2.
- `docs/API.md` states implementation revision 2 (it still said 1), lists `Frame:IsForbidden`, `Frame:CanBeAccessedInContext` (absent on Classic clients) and `geterrorhandler` among the optional facilities, and says which host functions are read at load and which at call time.
- `docs/INTERNALS.md` bounds the release sort by the scope's own `maxHooks` rather than `MAX_HOOKS`.
- `tests/README.md` describes the limit rule as the specs pin it: the first `ForAddon` fixes it.
- A spec pins the refusal of a frame whose `CanBeAccessedInContext` answers `false`; the fake frame gains an `accessible` option. 110 specs.

## 0.2.0 — 2026-09-23

- HookKit addon scopes are now closed at logout whenever the framework can observe logout, whichever revisions are paired. `HookKit:ForAddon(addonName)` finds LifecycleKit and EventKit with `Registry:Find` and leaves the scope to a LifecycleKit whose `CLOSES_ADDON_SCOPES` names `hookKit` (making sure the addon has a LifecycleKit instance), subscribes once to an older LifecycleKit's `OnShutdown`, or, without LifecycleKit, connects one package-level `PLAYER_LOGOUT` watcher in HookKit's own EventKit scope. With neither, nothing is subscribed and the consumer calls `CloseAddonScopes` on `PLAYER_LOGOUT`, as before. The decision is taken again by later `ForAddon` calls until LifecycleKit has taken the scope over. See "At logout" in `docs/API.md`.
- `Close` and `CloseAddonScopes` disconnect the `OnShutdown` subscription of a scope that closes before logout.
- LifecycleKit API 1 and EventKit API 1 are declared under `optionalDependencies`; HookKit still requires only Registry API 2.
- Implementation revision 2, scope layout 2 (`_logoutCloser`, `_shutdownSubscription`), and the `logoutWatch` state field. An upgrade over revision 1 migrates every addon scope in place and arranges the logout close of the open ones while it loads; a later revision keeps the subscriptions and the watcher without subscribing again. The executed code changed, so this is the first revision boundary of the 0.1.0 line: the upgrade specs now load the next revision instead of revision 2.
- 109 specs; `LogoutClose_spec.lua` covers the four cases, re-evaluation, a failure in another Kit, the subscription disconnected by an early close, and both upgrades.

## 0.1.0 — 2026-09-23

- Added HookKit API generation 1, implementation revision 1.
- Added `HookKit:CreateScope()`, `HookKit:ForAddon(addonName)` and `HookKit:CloseAddonScopes(addonName)`, mirroring the TimerKit and EventKit scope model; `HookKit.MAX_HOOKS` is 256 per scope, beyond which a hook method returns `nil, "full"`.
- Added the three hook semantics as scope methods: secure post-hooks (`SecureHook`, `SecureHookScript`) over `hooksecurefunc` and `Frame:HookScript`, made reversible by an active flag on a closure that stays installed; safe pre-hooks (`Hook`, `HookScript`) whose handler errors are reported and whose original always runs with its results untouched; raw replacements (`RawHook`, `RawHookScript`) whose handler receives the original as its first argument.
- Added `Unhook`, `UnhookAll`, `IsHooked`, `Original`, `Hooks`, `Close`, `IsClosed`, `GetActiveCount` and `GetAddonName`. `Unhook` restores the original only while the installed function is still HookKit's, deletes the field instead when the original came through `__index`, and otherwise leaves the closure inert and forwarding.
- Non-secure hooks of secure targets are refused unless `options.forceSecure` is passed; the secure status is read with `issecurevariable` and remembered from before HookKit's first non-secure hook. Replacing `OnClick`, `PreClick`, `PostClick`, `OnDoubleClick` or `OnAttributeChanged` on a protected frame is refused outright; other scripts of a protected frame need `forceSecure` and are refused during combat lockdown. Double hooks of one target in one scope are refused.
- Hook records live in a weak-keyed table per scope, never auto-vivified on reads. A hooked call allocates nothing; secret arguments pass through untouched.
- ClientKit API 1 is an optional dependency, found with `Registry:Find` when a name is validated, for `IsSecret`.
- `docs/API.md` leads with the taint each semantic causes.
- Bounded by default, opened on purpose: `HookKit:CreateScope(options)` and `HookKit:ForAddon(addonName, options)` accept `options.maxHooks`, a positive integer or the new `HookKit.UNBOUNDED` sentinel, and `scope:GetMaxHooks()` reads it back. The default stays `HookKit.MAX_HOOKS` (256); a hook beyond the limit is still refused with `nil, "full"`. An invalid value raises at the caller. The first `ForAddon` call for an addon fixes its limit (the default when it names none); a later call naming a different limit raises at the caller, and one naming the same limit or none returns the scope. `CreateScope` now requires the facade receiver. The `__index` walk bound (`MAX_INDEX_DEPTH`, 8) stays a hard ceiling because it guards a cyclic chain rather than retained memory. The sentinel lives in the package state (`_state.unbounded`), is part of the public-surface check, and survives an in-place upgrade together with every scope's limit. See "Limits" in `docs/API.md`.
- The secure-target check of a method inherited through `__index` asks `issecurevariable` about the table that holds it (up to 8 levels), because the client reports an absent raw key as secure; a method behind an `__index` function is treated as not secure-checkable.
- Only the click and attribute scripts are refused outright on a protected frame; the wording now says so, and that the combat-lockdown refusal is a conservative HookKit rule.
- A script pre-hook or replacement is refused while any HookKit scope holds a `SecureHookScript` post-hook on that script, since `SetScript` may drop it.
- Script hooks refuse a forbidden or inaccessible frame at the caller, and release leaves the closure inert on one.
- `CloseAddonScopes` records nothing for an addon without a scope and returns `false`; `ForAddon` and `CloseAddonScopes` refuse a receiver other than the facade.
- Releasing a script pre-hook or replacement leaves its closure in place, inert, while any HookKit scope holds a `SecureHookScript` post-hook on that script. That post-hook was installed after the pre-hook (the order HookKit allows), and restoring with `SetScript` could drop it. The test frame's `SetScript` now drops `HookScript` post-hooks, so the suite exercises that case.
- The facade receiver check compares by raw identity, so it never compares a caller-supplied value with `~=`.
- README and API.md resolve the package with `MoltenCodes.Registries[2]:Get`, the generation-pinned form `docs/EMBEDDING.md` recommends, instead of the `MoltenCodes.Registry` alias.
- 83 specs, including an allocation guard on hooked calls and an in-place upgrade spec.
