# HookKit Tests

The HookKit suite covers:

- secure post-hooks: the handler after the original with the same arguments and the original's results returned, the global form, the target staying secure, `Unhook` leaving the closure installed and inert, a re-hook with a new closure, a handler error reported without breaking the host call, `SecureHookScript` (also of a protected script on a protected frame), and a host without `hooksecurefunc` or a frame without `HookScript`;
- safe pre-hooks: handler first, original always, results (including `nil`s and their count) untouched, a handler error reported while the original still runs, restoration on `Unhook`, deleting the field when the original came through `__index`, a later foreign hook that keeps working after our `Unhook`, the inert closure forwarding every argument and result, the global form, and two scopes chaining on one target;
- raw replacements: the original passed first, the handler's results returned, the handler calling the original, errors propagating to the caller, restoration and inert forwarding;
- script hooks: pre-hook order and result, a script with no previous handler, restoration with `SetScript`, staying inert under a later `SetScript`, `RawHookScript`, the protected-script refusal (even with `forceSecure`), the `forceSecure` requirement for other scripts of a protected frame, the combat-lockdown refusal, inert release in lockdown, a host `SetScript` that raises, the refusal of a pre-hook on a script HookKit secure-hooked in any scope (and the pre-hook-first order that is allowed, whose post-hook survives the pre-hook's release), and forbidden frames and frames not accessible in this context;
- secure-target refusal and `forceSecure` for methods and globals, inherited methods checked on the table that holds them (addon mixins allowed, secure tables refused, `__index` functions and chains deeper than eight not checkable), the secure status remembered from before the first non-secure hook, a host without `issecurevariable`, and option validation;
- limits: the default of 256 enforced with `"full"`, `options.maxHooks` smaller and larger, `HookKit.UNBOUNDED` holding 600 hooks, the first `ForAddon` fixing the limit (a later call that agrees or names none returns the scope, one naming a different limit is refused at the caller and changes nothing), invalid, unknown and secret values refused at the caller with nothing changed (also for an existing addon scope), the secret probe asked before the value meets `UNBOUNDED`, and the sentinel and every scope's limit kept across an upgrade;
- scopes: double-hook refusal, targets that are not functions, `MAX_HOOKS` and `"full"`, `Hooks()` order and kinds, no records created by lookups, `UnhookAll` (also when one release raises), terminal `Close` refusing every hook method at the caller, `ForAddon` and `CloseAddonScopes` (nothing recorded for an addon without a scope, facade receiver required), and a hooked table that is garbage-collected;
- secret values: arguments and results passing through every semantic untouched without a single `issecretvalue` probe on the call path, a secret error object reaching the host unchanged, and secret names refused with and without ClientKit;
- allocation guards (`collectgarbage("count")` with the collector stopped) on a hooked call of every semantic, on an inert closure, and on `IsHooked`, `Original` and `GetActiveCount`;
- closing addon scopes at logout: a LifecycleKit that names `hookKit` in `CLOSES_ADDON_SCOPES` left to close the scope after the shutdown callbacks (also for an addon without its own LifecycleKit instance), an older LifecycleKit's `OnShutdown` subscription (made once, disconnected by an early `CloseAddonScopes` or `Close`, and also used for a list that does not name `hookKit`), the one `PLAYER_LOGOUT` watcher through EventKit, nothing arranged without either, the decision taken again when LifecycleKit loads later, a failure in another Kit reported, the upgrade of a revision-1 scope layout to the working file, and the subscription and watcher kept across an upgrade;
- duplicate embedded loading, Registry publication, loading without ClientKit, yielding to a newer revision, a missing Registry, an incomplete facade, and an in-place upgrade to the next revision that keeps every kind of hook active and releasable, one that keeps `UNBOUNDED` and each scope's `maxHooks`, and one from revision 2 to the working file;
- `error` levels: every argument failure and refusal reports the caller's own line;
- manifest/runtime API and revision consistency.

The shared fixture does not model `hooksecurefunc`, `issecurevariable`, `InCombatLockdown` or frame scripts, so `support/HookKitTestEnv.lua` stubs them for this suite only and removes the globals again in `Reset`. Its `hooksecurefunc` carries up to four results so a hooked call through it allocates nothing, and its `issecurevariable` follows the client: a raw field is secure when it holds a function a spec marked with `MarkSecure`, and an absent raw key is secure. `NewFrame` builds a fake frame whose methods live in its metatable, as a real frame's do, whose `SetScript` drops the script's `HookScript` post-hooks (the case HookKit must never cause), `NewFrame({ accessible = false })` gives it a `CanBeAccessedInContext` that answers `false`, and `RunScript` fires a script followed by its `HookScript` post-hooks.

ClientKit, EventKit and LifecycleKit are declared under `optionalDependencies`, so the runner puts them on `LUA_PATH`; `NewPackageWithoutClientKit` loads Registry and HookKit alone, and `LoadEventKit` and `LoadLifecycleKit` add the other two after HookKit. `SetClosesAddonScopes` writes `LifecycleKit.CLOSES_ADDON_SCOPES` onto the loaded facade with `rawset`, or removes it to model a LifecycleKit older than 0.6.0.

| Spec | Covers |
|---|---|
| `SecureHook_spec.lua` | secure post-hooks of methods, globals and scripts |
| `SecureTarget_spec.lua` | the secure-target refusal, inherited methods, `forceSecure` |
| `Hook_spec.lua` | safe pre-hooks and raw replacements of fields |
| `HookScript_spec.lua` | script pre-hooks, replacements and the protected-frame rules |
| `Scope_spec.lua` | scopes, capacity, `Hooks()`, `UnhookAll`, `Close`, addon scopes |
| `Limits_spec.lua` | `options.maxHooks`, `HookKit.UNBOUNDED`, `GetMaxHooks`, invalid values |
| `SecretValues_spec.lua` | secrets passing through; secret names refused |
| `Allocation_spec.lua` | allocation guards |
| `ErrorLevels_spec.lua` | errors reported at the caller's line |
| `LogoutClose_spec.lua` | who closes an addon scope at logout, in each of the four cases, and across upgrades |
| `Bootstrap_spec.lua` | publication, duplicate loads, upgrades |
| `Manifest_spec.lua` | manifest and runtime metadata |
