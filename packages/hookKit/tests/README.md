# HookKit Tests

The HookKit suite covers:

- secure post-hooks: the handler after the original with the same arguments and the original's results returned, the global form, the target staying secure, `Unhook` leaving the closure installed and inert, a re-hook with a new closure, a handler error reported without breaking the host call, `SecureHookScript` (also of a protected script on a protected frame), and a host without `hooksecurefunc` or a frame without `HookScript`;
- safe pre-hooks: handler first, original always, results (including `nil`s and their count) untouched, a handler error reported while the original still runs, restoration on `Unhook`, deleting the field when the original came through `__index`, a later foreign hook that keeps working after our `Unhook`, the inert closure forwarding every argument and result, the global form, and two scopes chaining on one target;
- raw replacements: the original passed first, the handler's results returned, the handler calling the original, errors propagating to the caller, restoration and inert forwarding;
- script hooks: pre-hook order and result, a script with no previous handler, restoration with `SetScript`, staying inert under a later `SetScript`, `RawHookScript`, the protected-script refusal (even with `forceSecure`), the `forceSecure` requirement for other scripts of a protected frame, the combat-lockdown refusal, inert release in lockdown, and a host `SetScript` that raises;
- secure-target refusal and `forceSecure` for methods and globals, the secure status remembered from before the first non-secure hook, a host without `issecurevariable`, and option validation;
- scopes: double-hook refusal, targets that are not functions, `MAX_HOOKS` and `"full"`, `Hooks()` order and kinds, no records created by lookups, `UnhookAll` (also when one release raises), terminal `Close` refusing every hook method at the caller, `ForAddon` and `CloseAddonScopes`, and a hooked table that is garbage-collected;
- secret values: arguments and results passing through every semantic untouched without a single `issecretvalue` probe on the call path, a secret error object reaching the host unchanged, and secret names refused with and without ClientKit;
- allocation guards (`collectgarbage("count")` with the collector stopped) on a hooked call of every semantic, on an inert closure, and on `IsHooked`, `Original` and `GetActiveCount`;
- duplicate embedded loading, Registry publication, loading without ClientKit, yielding to a newer revision, a missing Registry, an incomplete facade, and an in-place upgrade to revision 2 that keeps every kind of hook active and releasable;
- `error` levels: every argument failure and refusal reports the caller's own line;
- manifest/runtime API and revision consistency.

The shared fixture does not model `hooksecurefunc`, `issecurevariable`, `InCombatLockdown` or frame scripts, so `support/HookKitTestEnv.lua` stubs them for this suite only and removes the globals again in `Reset`. Its `hooksecurefunc` carries up to four results so a hooked call through it allocates nothing, and its `issecurevariable` reports a field secure when it holds, or inherits through `__index`, a function a spec marked with `MarkSecure`. `NewFrame` builds a fake frame whose methods live in its metatable, as a real frame's do, and `RunScript` fires a script followed by its `HookScript` post-hooks.

ClientKit is declared under `optionalDependencies`, so the runner puts it on `LUA_PATH`; `NewPackageWithoutClientKit` loads Registry and HookKit alone.
