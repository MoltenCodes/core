# BindingKit Tests

The BindingKit suite covers:

- scopes: each kind of binding set on the scope's owner with its priority, `GetBinding` and `GetName`, a scope returned by name keeping its first priority, scopes kept apart, a function key called through its hidden named button with the key and one that raises reported, a function key's button freed by `Unbind` and reused, a button given up in combat kept out of reuse until combat ends, changes in combat kept, applied only when combat has ended and the event frame unregistered, `ClearAll` counting and freeing, both limits, and a host without the override binding functions;
- arguments and secrets: every argument failure reported at the caller's line, secret names, keys, targets, options, limits and receivers refused, and a missing or secret `InCombatLockdown` counted as out of combat;
- Registry publication, a duplicate embedded load keeping scopes, yielding to a newer revision, an upgrade from revision 1 retiring buttons given up in combat, an in-place upgrade keeping scopes, function keys, waiting changes and the limits while the end of combat and a function key run the new code, a refusal of state holding an invalid limit, missing Registry, and an incomplete facade;
- the shared helper blocks: the secret probe kept from load and a probe installed after load asked, the facade message, a function key's function printed when the host error handler raises, and the in-place upgrade over the committed revision 2 file (`fixtures/BindingKit-revision2.lua`);
- the repository conformance suite (`tests/support/KitConformance.lua`): manifest, receivers, arguments and upgrade; its limits group is pending, with the reason in the spec;
- manifest/runtime API and revision consistency, and the declared dependency.

`support/BindingKitTestEnv.lua` provides stand-ins for `SetOverrideBinding`, `SetOverrideBindingClick` and `ClearOverrideBindings` keeping each owner's bindings (`Bindings(owner)`), `InCombatLockdown` with `SetCombat` and `EndCombat` (which emits `PLAYER_REGEN_ENABLED`), `TakeReportedValues`, the secret probe and `LoadRevision`.

| Spec | Covers |
|---|---|
| `Scope_spec.lua` | bindings, function keys, combat, limits |
| `Arguments_spec.lua` | argument errors at the caller's line, secrets, combat answers |
| `Bootstrap_spec.lua` | publication, duplicate loads, load order, upgrades |
| `SharedHelpers_spec.lua` | the shared `isSecret`, `reportError` and `validateFacade` blocks, the upgrade from revision 2 |
| `Conformance_spec.lua` | the conformance suite on a mainline-profile environment |
| `Manifest_spec.lua` | manifest and runtime `API` / `REVISION` agreement, declared dependency |
