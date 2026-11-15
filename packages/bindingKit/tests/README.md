# BindingKit Tests

The BindingKit suite covers:

- scopes: each kind of binding set on the scope's owner with its priority, `GetBinding` and `GetName`, a scope returned by name keeping its first priority, scopes kept apart, a function key called through its hidden named button with the key and one that raises reported, a function key's button freed by `Unbind` and reused, changes in combat kept, applied only when combat has ended and the event frame unregistered, `ClearAll` counting and freeing, both limits, and a host without the override binding functions;
- arguments and secrets: every argument failure reported at the caller's line, secret names, keys, targets, options, limits and receivers refused, and a missing or secret `InCombatLockdown` counted as out of combat;
- Registry publication, a duplicate embedded load keeping scopes, yielding to a newer revision, an in-place upgrade keeping scopes, function keys, waiting changes and the limits while the end of combat and a function key run the new code, a refusal of state holding an invalid limit, missing Registry, and an incomplete facade;
- manifest/runtime API and revision consistency, and the declared dependency.

`support/BindingKitTestEnv.lua` provides stand-ins for `SetOverrideBinding`, `SetOverrideBindingClick` and `ClearOverrideBindings` keeping each owner's bindings (`Bindings(owner)`), `InCombatLockdown` with `SetCombat` and `EndCombat` (which emits `PLAYER_REGEN_ENABLED`), `TakeReportedValues`, the secret probe and `LoadRevision`.

| Spec | Covers |
|---|---|
| `Scope_spec.lua` | bindings, function keys, combat, limits |
| `Arguments_spec.lua` | argument errors at the caller's line, secrets, combat answers |
| `Bootstrap_spec.lua` | publication, duplicate loads, load order, upgrades |
| `Manifest_spec.lua` | manifest and runtime `API` / `REVISION` agreement, declared dependency |
