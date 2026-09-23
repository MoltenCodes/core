# HookKit API

HookKit API generation **1** hooks global functions, object methods and frame scripts reversibly, under three named semantics, and refuses the hooks that break the client's secure code.

Implementation revision: **1**.

## The taint model: read this first

World of Warcraft runs Blizzard's code **secure** and every addon's code **tainted**. Execution becomes tainted the moment it runs a function an addon wrote or reads a value an addon wrote. Tainted execution may not call protected functions (casting, targeting, moving protected frames in combat); when it reaches one, the client blocks the action and blames the addon whose taint got there. [`docs/EMBEDDING.md` → Taint](../../../docs/EMBEDDING.md#taint) describes the model and the host calls involved.

A hook puts addon code into someone else's call path, so the choice of semantic decides what gets tainted:

| Semantic | Methods | How it installs | What becomes tainted |
|---|---|---|---|
| **Secure post-hook** (the default choice) | `SecureHook`, `SecureHookScript` | `hooksecurefunc(object, method, closure)`, `frame:HookScript(script, closure)` | **Nothing but your handler.** The host calls the original first, in whatever security state the caller had, then calls your handler; the taint your handler picks up does not flow back into the caller. The field keeps a secure value: `issecurevariable` still answers `true`. |
| **Safe pre-hook** | `Hook`, `HookScript` | Writes HookKit's closure over the field (`rawset`), or `frame:SetScript` | **The field and every call through it.** The field now holds addon code, so every caller that reaches it — Blizzard's included — runs tainted from that point on, and so does the original, called from the closure. `issecurevariable` answers `false` for the field. |
| **Raw replacement** | `RawHook`, `RawHookScript` | The same writes as a pre-hook | **The same as a pre-hook**, and the original runs only if your handler calls it. |

Consequences worth knowing before choosing:

- **Post-hook whenever you only need to react.** It is the only semantic that cannot cause "action blocked" errors elsewhere in the UI. HookKit makes it reversible, which `hooksecurefunc` alone is not.
- **A pre-hook or replacement of a function Blizzard calls during combat can block actions for the rest of the session.** Everything downstream of the tainted field runs tainted. This is why HookKit refuses it on a secure target unless you pass `options.forceSecure`.
- **Unhooking does not remove taint.** Restoring the original writes it from addon code, so the field stays tainted until the next `/reload`. When the original came through `__index`, HookKit deletes the field instead, which leaves no addon-written value behind (see [Unhook](#unhook-restore-or-go-inert)). HookKit remembers that the target *was* secure, so later hooks are still refused.
- **Running the handler through `securecallfunction` would change nothing** and HookKit does not do it. A post-hook handler is already isolated by `hooksecurefunc`; a pre-hook handler runs inside HookKit's closure, which is tainted anyway because it is addon code. Handler errors are caught with `pcall` and reported to the host error handler.
- **Secret values pass through untouched.** Arguments and results travel through HookKit's closures as `...`; HookKit never compares, indexes, stores or formats them. Your handler receives exactly what the caller passed, secrets included, and inherits the rules in [`EMBEDDING.md` → Secret values](../../../docs/EMBEDDING.md#secret-values-retail-12x).

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
HookKit.lua
```

HookKit depends only on Registry API 2. Portable WoW code resolves the package through Registry:

```lua
local HookKit = MoltenCodes.Registry:Get("hookKit", 1)
```

HookKit does not rely on `require()` at runtime. Loading it without Registry raises `MoltenCodes HookKit requires Registry API 2 to be loaded first`.

### Optional facilities

| Facility | Used by | Without it |
|---|---|---|
| `hooksecurefunc` | `SecureHook` | `SecureHook` raises at the caller: `HookKit.Scope:SecureHook requires the host's hooksecurefunc`. Everything else works. |
| `issecurevariable` | the secure-target refusal | Nothing is considered secure, so no hook is refused for that reason. |
| `InCombatLockdown` | script replacement on protected frames | Never in combat. |
| `Frame:IsProtected` | the protected-frame refusals | A frame without it is not protected. |
| `Frame:HookScript` | `SecureHookScript` | Refused at the caller for that frame. |
| `Frame:GetScript`, `Frame:SetScript` | `HookScript`, `RawHookScript` | Refused at the caller for that frame. |
| ClientKit API 1 | `IsSecret`, to refuse a secret method, script or addon name | `issecretvalue` is asked directly; without it nothing is secret. |

The host functions are read once when the file loads. ClientKit is looked up with `Registry:Find("clientKit", 1)` when a name is validated, never on a hooked call, so it may load after HookKit.

## Public surface

Package facade:

| Member | Purpose |
|---|---|
| `CreateScope()` | Create a manually owned hook scope. |
| `ForAddon(addonName)` | Return the canonical scope of an addon, creating it on demand. |
| `CloseAddonScopes(addonName)` | Close that addon's scope; returns `false` when it was already closed. |
| `MAX_HOOKS` | `256`, the most hooks one scope holds at once. |
| `API`, `REVISION` | API generation and implementation revision. |

Scope methods:

| Method | Purpose |
|---|---|
| `SecureHook(object, method, handler)` / `SecureHook(globalName, handler)` | Secure post-hook of a method or global. |
| `SecureHookScript(frame, script, handler)` | Secure post-hook of a frame script. |
| `Hook(object, method, handler[, options])` / `Hook(globalName, handler[, options])` | Safe pre-hook. |
| `RawHook(object, method, handler[, options])` / `RawHook(globalName, handler[, options])` | Raw replacement. |
| `HookScript(frame, script, handler[, options])` | Safe pre-hook of a frame script. |
| `RawHookScript(frame, script, handler[, options])` | Raw replacement of a frame script. |
| `Unhook(object, method)` / `Unhook(globalName)` | Undo this scope's hook of that target; `false` when there is none. Also undoes a script hook: `Unhook(frame, script)`. |
| `UnhookAll()` | Undo every hook, newest first; return how many. The scope stays usable. |
| `IsHooked(object, method)` / `IsHooked(globalName)` | `true` and the kind, or `false`. |
| `Original(object, method)` / `Original(globalName)` | The function this scope's hook wraps or replaces, or `nil`. |
| `Hooks()` | Array of `{ object, method, kind }` rows in creation order, for diagnostics. |
| `Close()` | Undo every hook and refuse new ones. Terminal; `false` if already closed. |
| `IsClosed()` | Whether the scope is closed. |
| `GetActiveCount()` | The number of hooks the scope holds. |
| `GetAddonName()` | The owning addon name, or `nil` for a manual scope. |

Every hook method returns `true` when it installed the hook and `nil, "full"` when the scope already holds `MAX_HOOKS` hooks. Everything else that stops a hook raises at the caller's line (see [Refusals](#refusals)).

A kind is one of `"secure"`, `"secureScript"`, `"hook"`, `"rawHook"`, `"hookScript"` and `"rawHookScript"`. For a global, `object` in a `Hooks()` row is `_G`.

## The three semantics

### Secure post-hook

```lua
local hooks = HookKit:ForAddon("MyAddon")

hooks:SecureHook(GameTooltip, "SetUnit", function(tooltip, unit)
    -- runs after the original, with the same arguments
end)
hooks:SecureHook("ToggleWorldMap", function() end)
hooks:SecureHookScript(PlayerFrame, "OnShow", function(frame) end)
```

The handler is called after the original with the same arguments; its return values are ignored, and the original's results reach the caller as the host returns them. A handler error is caught and reported to the host error handler.

`hooksecurefunc` and `HookScript` cannot be undone, so HookKit installs a closure that stays in the host's chain for the rest of the session and reads one flag, the record's `_active`, before calling your handler. `Unhook` clears the flag. The closure then does nothing, which is as cheap as a hook can be, but it is still there: **hooking and unhooking the same target in a loop grows the chain by one closure each time.** Hook once, and unhook at teardown.

### Safe pre-hook

```lua
hooks:Hook(MyOtherAddon, "Refresh", function(self, reason)
    -- runs first; cannot change the arguments or the results
end)
hooks:HookScript(myFrame, "OnUpdate", function(frame, elapsed) end)
```

The handler runs first with the call's arguments. Its errors are reported to the host error handler and never stop the original. The original then always runs, with the same arguments, and its results are returned to the caller unchanged, including `nil`s and their count. `HookScript` calls the script that was set before (if any) the same way.

### Raw replacement

```lua
hooks:RawHook(MyOtherAddon, "Format", function(original, self, value)
    if value == nil then
        return ""
    end
    return original(self, value)
end)
```

The handler runs **instead of** the original and its results are what the caller gets. The original is passed as the handler's **first** argument, before the call's own arguments, and is also available as `scope:Original(object, method)`. A handler error propagates to the caller, as an error in the original would. `RawHookScript` passes the previous script, or `nil` when there was none.

**Deviation from the package plan.** The plan allowed the original as the handler's last argument. Appending a value after `...` in Lua 5.1 needs a table per call, which the hooked path must not allocate, so the first-argument form is the only one.

## Refusals

Every refusal raises at the caller's line and installs nothing.

| Refused | Message (prefix `HookKit.Scope:<Method>`) | Override |
|---|---|---|
| A non-secure hook (`Hook`, `RawHook`) of a secure target | `refuses to hook secure "<method>" non-securely; use SecureHook, or pass options.forceSecure` | `options.forceSecure = true` |
| A non-secure script hook of a **protected script** on a protected frame | `refuses to replace protected script "<script>" of a protected frame; use SecureHookScript` | none |
| A non-secure script hook of any other script on a protected frame | `refuses to replace script "<script>" of a protected frame; use SecureHookScript, or pass options.forceSecure` | `options.forceSecure = true` |
| A non-secure script hook on a protected frame in combat lockdown | `cannot replace a script of a protected frame during combat lockdown` | none (`SetScript` is blocked there) |
| A target that is not a function | `target "<method>" is not a function` | — |
| A second hook of the same target in one scope | `"<method>" is already hooked in this scope; Unhook it first` | — |
| Any hook on a closed scope | `cannot hook in a closed scope` | — |

**Secure status is remembered.** "Secure" means `issecurevariable(object, method)` (or `issecurevariable(globalName)`) answered `true` the first time HookKit checked that target, which is always before HookKit's first non-secure write to it. A forced hook taints the field, after which the host answers `false`; HookKit keeps answering from its memo, so a second scope, or the same scope after `Unhook`, is still refused. The memo is weak-keyed by the hooked object.

A method a frame inherits from its metatable (`frame.Show`, say) is secure on the live client even on a frame your addon created, so a non-secure hook of one needs `forceSecure`.

**Protected scripts** are the scripts the secure environment drives on a protected frame: `OnClick`, `PreClick`, `PostClick`, `OnDoubleClick` and `OnAttributeChanged`. A frame is protected when `frame:IsProtected()` answers `true`. Post-hooking any of them with `SecureHookScript` is always allowed.

**Double hooks** are refused rather than silently replaced: an implicit unhook-then-hook would reorder the chain behind the caller's back. Two *different* scopes may hook the same target; their closures chain.

Argument errors name the parameter: `HookKit.Scope:Hook method must be a non-empty string`, `... handler must be a function`, `... options contains unknown field "<name>"`, `... options.forceSecure must be a boolean`, `HookKit.Scope:HookScript frame must have a GetScript method`. A method, script, global or addon name that is a secret value is refused with `... must not be a secret value`, before HookKit compares it or uses it as a key.

## Unhook: restore or go inert

`Unhook` always removes the scope's record and clears the closure's active flag. What happens to the installed function depends on who owns it now:

| Kind | The installed function is still HookKit's | Someone hooked the target after HookKit |
|---|---|---|
| `secure`, `secureScript` | The closure stays, inert. The host owns it. | The same. |
| `hook`, `rawHook` | The original is written back. When the original came through `__index` (the field was not a raw field before the hook), the field is **deleted** instead, so the inherited function shows through again and no addon-written value is left. | The closure stays in their chain, inert: it forwards every argument to the original and returns its results. Restoring under them would cut their hook out. |
| `hookScript`, `rawHookScript` | `frame:SetScript(script, previous)`, where `previous` may be `nil`. On a protected frame in combat lockdown, the closure stays, inert, instead. | The closure stays, inert, forwarding to the previous script. |

"Still HookKit's" is `rawget(object, method) == installed` for a field and `frame:GetScript(script) == installed` for a script. Whether the host keeps `HookScript` post-hooks other addons added to a script across a `SetScript` is host behaviour HookKit does not control; prefer `SecureHookScript`, which never calls `SetScript`.

`UnhookAll` and `Close` release every hook, newest first. A host failure in one release (a `SetScript` that raises) does not stop the others: every hook is released and leaves the scope, and the first error object is re-raised unchanged afterwards.

## Scopes and ownership

```lua
local scope = HookKit:CreateScope()
scope:SecureHook("ToggleWorldMap", onToggle)

scope:UnhookAll() -- every hook undone; the scope stays usable
scope:Close()     -- terminal; later hooks raise at the caller
```

The scope model is the one TimerKit and EventKit share. `ForAddon(addonName)` is idempotent. HookKit does not observe addon shutdown, so closing an addon's scope is a separate step taken by whoever does:

1. The addon hooks through `HookKit:ForAddon("MyAddon")`.
2. On that addon's shutdown, the observer calls `HookKit:CloseAddonScopes("MyAddon")`.

A consumer that does not use LifecycleKit wires the second step itself:

```lua
EventKit:Once("PLAYER_LOGOUT", function()
    HookKit:CloseAddonScopes("MyAddon")
end)
```

Closing is terminal. The closed scope stays the addon's canonical scope, so a later `ForAddon("MyAddon")` returns it and refuses new hooks. Calling `CloseAddonScopes` for an addon that never asked for a scope records one that is already closed. Manual scopes are never closed by `CloseAddonScopes`.

A scope does not keep a hooked table alive: its records are keyed by object in a weak-keyed table and never reference the object. In Lua 5.1 that only helps when your handler does not itself capture the object, because a weak-keyed table cannot collect a key its value references.

## Cost

- **A hooked call** reads one flag and one dispatch field, then calls: `pcall(handler, ...)` for a post-hook or pre-hook, a direct call for a replacement. It allocates nothing, whether active or inert.
- **One closure and one record per hook**, created when the hook is installed. A secure hook's closure lives for the session.
- **`IsHooked`, `Original` and `GetActiveCount`** allocate nothing. A lookup of an object the scope never hooked creates nothing.
- **`Hooks()`, `UnhookAll()` and `Close()`** allocate one array per call (plus one row per hook for `Hooks()`); they are for diagnostics and teardown.
- **`GetActiveCount()` and the `MAX_HOOKS` check count the records** (at most 256) rather than reading a stored counter, so the records of a garbage-collected object stop counting at once.

## Upgrades

Every installed closure calls through the shared `_state.dispatch` table, and scopes keep their metatable across upgrades. A newer compatible revision therefore replaces the behaviour behind hooks an older copy installed — including the permanent secure closures — without touching the host's chain, and existing scopes gain the new methods in place.
