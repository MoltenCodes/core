# bindingKit records

Moved from `docs/ROADMAP.md` (Package M — the user-interface phase (last, by the owner's decision)).

## bindingKit

**bindingKit** — facade `BindingKit`

1. Package `bindingKit`, facade `BindingKit`, API generation 1.
2. Purpose: key bindings an addon sets at run time without touching the
   player's own: override bindings (`SetOverrideBinding`,
   `SetOverrideBindingClick`), which the client drops at logout and never
   saves, owned by a named scope so an addon clears only its own. A key can
   run a binding command (`"TOGGLEWORLDMAP"`), click a named button, or call
   a Lua function through a hidden named button of the package's own. The
   client refuses binding changes from addon code in combat, so a change made
   then is kept and applied when combat ends (`PLAYER_REGEN_ENABLED`); a
   scope says whether it waits. Non-goals: the player's saved bindings
   (`SetBinding`, `SaveBindings`), the Key Bindings panel, secure action
   buttons (a function key runs insecure code and cannot cast).
3. Dependencies: registry API 2 only. Host requirement: `CreateFrame`,
   `SetOverrideBinding`, `SetOverrideBindingClick`,
   `ClearOverrideBindings`, `InCombatLockdown`; without the binding
   functions `CreateScope` raises at the caller.
4. Surface: `BindingKit:CreateScope(name, options?)` → scope (the scope of
   that name when it exists; `priority` makes its bindings win over other
   override bindings); `scope:BindCommand(key, command)`,
   `scope:BindClick(key, buttonName, mouseButton?)`,
   `scope:BindFunction(key, func)`, `scope:Unbind(key)`, `scope:ClearAll()`,
   `scope:GetBinding(key)`, `scope:IsPending()`, `scope:GetName()`;
   `BindingKit:GetScope(name)`; `SetLimits{ maxScopes, maxFunctionKeys }` /
   `GetLimits()`.
5. Ownership: a scope lives for the session with one owner frame; its
   bindings are the client's until logout or until the scope clears them.
   A function key's hidden button goes back to a free list when the key is
   unbound, so buttons are reused.
6. Performance and memory: a change rebuilds the scope's override bindings
   (clear, then set each), never per frame; one event frame listens for the
   end of combat only while a scope waits. `maxScopes` defaults to 32
   (ceiling 256) and `maxFunctionKeys` to 64 (ceiling 512): both count
   frames the session keeps, so neither opens to `UNBOUNDED`.
7. Tests: stand-ins for the override binding functions and combat; each
   kind of binding set on the scope's owner with its priority, unbinding
   and clearing, a function key calling its function (one that raises
   reported) and its button reused, changes in combat kept and applied at
   the end of combat, scopes by name, limits and ceilings, secret values,
   upgrade, manifest, error levels. A client suite on Retail: a function key
   set, pressed through the button it binds, and cleared.
8. Docs: README, API.md, CHANGELOG, tests/README; EMBEDDING rows;
   ARCHITECTURE's package list.
9. Status: implemented 2026-11-15 under core decision 15, 0.1.0, revision
   1, 21 specs; the client suite (`tests/client/MoltenCodesTest_BindingKit`)
   is written and has not been run in a client.
   Reviewed 2026-11-15 under core decision 17: 0.1.1, revision 2, 23 specs
   (a function-key button given up in combat is not reused until combat
   ends).

