# Changelog

## 0.2.6 — 2026-09-25

- Performance. Installing and removing a hook, and calling a replacement, cost less. Measured with the host benchmark (`python3 -m tooling.bench.run --workload hooks --rounds 3`, before and after this change, median ns per operation with AceHook-3.0 measured in the same run; other agents' benchmarks and specs ran on the machine at the same time, load average about 2.6 before and 3.1 after, so compare the ratios and the allocation, which is deterministic):

  | Case | Before | After | AceHook (before / after) | Ratio before → after | Allocated before → after (AceHook) |
  |---|---:|---:|---:|---|---|
  | `hook-unhook-function` | 2,689 | 1,972 | 691 / 698 | 3.89× → 2.83× | 584 → 480 B (288 B) |
  | `hook-unhook-method` | 2,728 | 2,021 | 1,028 / 1,015 | 2.65× → 1.99× | 584 → 480 B (496 B) |
  | `rawhook-unhook-method` | 2,772 | 2,009 | 1,116 / 1,148 | 2.48× → 1.75× | 624 → 520 B (688 B) |
  | `hook-unhook-script` | 3,528 | 2,817 | 1,153 / 1,178 | 3.06× → 2.39× | 584 → 480 B (496 B) |
  | `securehook-unhook-method` | 2,475 | 1,990 | 1,024 / 1,050 | 2.42× → 1.90× | 720 → 720 B (640 B) |
  | `call-rawhooked-method` | 90.9 | 68.8 | 55.9 / 56.7 | 1.63× → 1.21× | 0 → 0 B (0 B) |
  | `call-prehooked-method` (different work: `pcall`) | 96.6 | 88.0 | 46.4 / 50.6 | — | 0 → 0 B |
  | `call-posthooked-method` (different work: `pcall`) | 112 | 102 | 62.7 / 61.6 | — | 0 → 0 B |

- How. The secret check asks the host's `issecretvalue` directly when HookKit found it at load, instead of looking ClientKit up through `Registry:Find` (about 230 ns) on every validated name: ClientKit's `IsSecret` answers from that same host function. A host without `issecretvalue` still asks ClientKit, as before. The install and lookup checks join their `"<method> <argument>"` labels only when they raise, the field-hook checks run inline, and scopes, records and HookKit's own tables are read and written by plain indexing instead of `rawget`/`rawset` (a record has no metatable; a scope's private fields all exist and its `__index` holds only the public methods). The dispatch functions behind every installed closure (`isolatedCall`, `replacementCall`) read the record the same way, which is the replacement call's gain. An object's method table in a scope now stays, empty, after its last hook goes, so hooking the same object again allocates only the record and its closure; the table is weak-keyed by the object and goes with it.
- What remains against AceHook is what HookKit promises and AceHook does not: the receiver, handler and secret checks, the secure-target memo and the protected-frame rules, the capacity check, the record that makes `Unhook`, `IsHooked`, `Original` and `Hooks()` work per scope, the restore-only-when-still-ours rule, the dispatch indirection that lets an upgrade replace installed closures, and `pcall` isolation on pre-hooks and post-hooks (kept: it is why the original still runs when a handler fails). On a host without `issecretvalue`, as the benchmark host is, each validated name still pays the ClientKit lookup, about 530 ns of a hook-and-unhook cycle.
- Guarantees are unchanged: the same messages at the same lines, secret names refused before any comparison, originals restored only while the installed function is still HookKit's, nothing created by a lookup.
- Implementation revision 6. No state, scope layout or record layout changed; hooks an older copy installed call the new dispatch functions, and an object whose method table an older copy deleted gets a new one at its next hook. `docs/API.md` ("Dependencies", "Cost", "Upgrades"), `docs/INTERNALS.md` and the README describe the change.
- Specs: new `FastPaths_spec.lua` (no ClientKit lookup when the host has `issecretvalue`, ClientKit still asked on a host that had none when HookKit loaded, nothing secret without either; re-hooking an object after its last hook went keeps `IsHooked`, `Original`, `Hooks()` order, the count and the restored originals right, and the empty method table goes with its object; a replacement of a script without a handler receives `nil` and every result of a handler reaches the caller; a re-hook cycle allocates at most 480 bytes). 121 → 129 specs.

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
