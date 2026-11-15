# BindingKit API

BindingKit API generation **1** keeps an addon's key bindings as override bindings in named scopes: binding commands, button clicks and Lua functions, applied after combat when set during it, never saved over the player's own.

Implementation revision: **2**.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
BindingKit.lua
```

Portable WoW code resolves the package through Registry:

```lua
local BindingKit = MoltenCodes.Registries[2]:Get("bindingKit", 1)
```

BindingKit does not rely on `require()` at runtime.

### Host facilities

| Facility | Used by | Without it |
|---|---|---|
| `CreateFrame`, `SetOverrideBinding`, `SetOverrideBindingClick`, `ClearOverrideBindings` | every binding | `CreateScope` raises at the caller: `BindingKit:CreateScope needs the client's override binding functions, which this host does not have`. |
| `InCombatLockdown` | every change | Never in combat: changes apply at once. A secret answer counts as out of combat. |
| `issecretvalue` | every check | Nothing is treated as secret. |
| `geterrorhandler` | a function key that raises | The failure is printed. |

The client's documentation tables do not describe the override binding functions; they are the old global functions Blizzard's own restricted frames call (`Blizzard_RestrictedAddOnEnvironment/RestrictedFrames.lua`, read 2026-11-15). What they do in combat when called from addon code is measured by the client suite, not assumed: BindingKit never calls them in combat.

## Public surface

| Member | Purpose |
|---|---|
| `CreateScope(name, options?)` | The scope named `name`, made on first use. `options.priority` makes its bindings win over other override bindings; it is read only when the scope is made. |
| `GetScope(name)` | The scope named `name`, or `nil`. |
| `SetLimits(limits)` / `GetLimits()` | Change or read `maxScopes` and `maxFunctionKeys`; `GetLimits` returns a fresh table. |
| `MAX_SCOPES`, `SCOPES_CEILING` | `32`, `256`. |
| `MAX_FUNCTION_KEYS`, `FUNCTION_KEYS_CEILING` | `64`, `512`. |
| `API`, `REVISION` | `1`, `2`. |

A scope:

| Method | Purpose |
|---|---|
| `BindCommand(key, command)` | Run the binding command `command` (a name from the client's binding list, such as `"TOGGLEWORLDMAP"`) on `key`. |
| `BindClick(key, buttonName, mouseButton?)` | Click the button whose global name is `buttonName` with `mouseButton` (default `"LeftButton"`) on `key`. |
| `BindFunction(key, func)` | Call `func(key)` on `key`, through a hidden named button. |
| `Unbind(key)` | Remove the key: `true`, or `false` when the scope had none. |
| `ClearAll()` | Remove every key of the scope; return how many there were. |
| `GetBinding(key)` | `"command"` and the command, `"click"` and the button name, `"function"` and the function, or `nil`. |
| `IsPending()` | Whether the scope's last change waits for the end of combat. |
| `GetName()` | The scope's name. |

A key is a non-empty string in the client's binding notation (`"CTRL-SHIFT-T"`, `"F5"`, `"BUTTON4"`); the client decides what it accepts. Binding a key the scope already has replaces it.

## How a change reaches the client

Every change rebuilds the scope's override bindings: `ClearOverrideBindings(owner)`, then one `SetOverrideBinding` or `SetOverrideBindingClick` per key, with the scope's priority. The owner is a frame BindingKit made for the scope, so other scopes and other addons' override bindings are untouched.

While `InCombatLockdown()` answers `true`, the change is recorded but not applied: `IsPending()` answers `true`, and one event frame waits for `PLAYER_REGEN_ENABLED`. When combat ends, every waiting scope is rebuilt as above and the event frame stops listening. `GetBinding` answers what the scope holds, applied or waiting.

## Function keys

`BindFunction` takes a hidden `Button` named `MoltenCodesBindingKitButton<n>` from a free list (making one when the list is empty), gives it to the key through `SetOverrideBindingClick`, and calls `func(key)` when it is clicked, protected: a function that raises is reported through `geterrorhandler`. Unbinding or replacing the key puts the button back on the free list, so out of combat the number of buttons never grows past the most function keys bound at once. A button given up in combat is not reused until combat ends: until its scope is rebuilt the client still clicks it on the old key, which then does nothing, and handing it to another key would run that key's function there. It is retired with its scope and goes back on the free list when the scope is rebuilt (revision 2). So in combat the buttons can number up to the function keys bound plus those given up since combat began. A function key runs insecure addon code: protected actions (casting, targeting, using items) are blocked by the client.

## Secret values

Every name, key, command, button name, option, limit and receiver is checked with `issecretvalue` first and refused at the caller.

## Limits

| Limit | Default | How to open | `UNBOUNDED` allowed? | Ceiling and reason |
|---|---|---|---|---|
| `maxScopes`, scopes in the session | `32` | `BindingKit:SetLimits({ maxScopes = n })` | no | `256`: each scope owns a frame the session keeps |
| `maxFunctionKeys`, function keys bound at once | `64` | `BindingKit:SetLimits({ maxFunctionKeys = n })` | no | `512`: each is a button the session keeps |

Lowering a limit keeps what exists and refuses the next. The limits are shared by every addon in the session.

## Error behaviour

Argument errors raise at the caller's line: `BindingKit.Scope:BindFunction func must be a function`; methods called on anything but a scope raise `BindingKit.Scope:ClearAll must be called on a BindingKit scope; use scope:ClearAll(...)`. What the client calls (a function key's button, the end of combat) never raises.

Every message, raised at the caller's line. `<method>` is the public name called, such as `BindingKit:CreateScope` or `BindingKit.Scope:BindCommand`.

| Message | Raised by |
|---|---|
| `<method> must be called on the BindingKit facade; use <method>(...)` | a facade method called on anything but `BindingKit` |
| `<method> must be called on a BindingKit scope; use scope:<name>(...)` | a scope method called on anything but a scope handle |
| `<method> <argument> must not be a secret value` | a secret name, key, command, button name or mouse button |
| `<method> <argument> must be a non-empty string` | the same arguments, of another type or empty |
| `BindingKit.Scope:BindFunction func must be a function` | |
| `BindingKit.Scope:BindFunction holds at most <n> function keys; raise maxFunctionKeys with BindingKit:SetLimits` | a new function key past `maxFunctionKeys` (replacing one does not count) |
| `BindingKit:CreateScope options must be a table or nil` | |
| `BindingKit:CreateScope options holds an unknown field; it accepts priority` | |
| `BindingKit:CreateScope options.priority must be a boolean` | also a secret one |
| `BindingKit:CreateScope holds at most <n> scopes; raise maxScopes with BindingKit:SetLimits` | a new scope past `maxScopes` |
| `BindingKit:CreateScope needs the client's override binding functions, which this host does not have` | |
| `BindingKit:SetLimits limits must be a table` | |
| `BindingKit:SetLimits limits holds an unknown field; it accepts maxScopes and maxFunctionKeys` | |
| `BindingKit:SetLimits limits.<name> must not be a secret value` | |
| `BindingKit:SetLimits limits.<name> must be an integer from 1 to <ceiling>` | `256` for `maxScopes`, `512` for `maxFunctionKeys` |

Loading raises `MoltenCodes BindingKit requires Registry API 2 to be loaded first`, `MoltenCodes BindingKit requires a valid Registry API 2 facade` or `MoltenCodes BindingKit package state is corrupted or incomplete`.

## Performance

| Path | Cost |
|---|---|
| A change | One clear and one set per key of the scope. |
| A function key pressed | One protected call. |
| Idle | Nothing; the event frame listens only while a scope waits. |

## Embedded copies and upgrades

Several addons may embed BindingKit; Registry selects the newest compatible revision and every copy shares one facade and one state: the scopes and their owners, the function keys and their buttons, the waiting changes and the limits. The buttons' and the event frame's scripts call through a dispatch table in the shared state that every loading revision rewrites, so keys an older copy bound, and changes it left waiting, run the newest copy's code.
