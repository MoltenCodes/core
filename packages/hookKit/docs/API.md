# HookKit API

HookKit API generation **1** hooks global functions, object methods and frame scripts reversibly, under three named semantics, and refuses the hooks that break the client's secure code.

Implementation revision: **3**.

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
- **Unhooking does not remove taint.** Restoring the original writes it from addon code, so the field stays tainted until the next `/reload`. When the original came through `__index`, HookKit deletes the field instead, so no addon-written value stays in it; the host may still report the slot as tainted (see [Unhook](#unhook-restore-or-go-inert)). HookKit remembers that the target *was* secure, so later hooks are still refused.
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
local HookKit = MoltenCodes.Registries[2]:Get("hookKit", 1)
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
| `Frame:IsForbidden`, `Frame:CanBeAccessedInContext` | every script hook, and releasing a script pre-hook or replacement | A frame without them is accessible. Classic clients have no `CanBeAccessedInContext`; only `IsForbidden` is asked there. |
| `geterrorhandler` | reporting a handler error, and a failure in another Kit while arranging the logout close | The failure is passed to `print`. |
| ClientKit API 1 | `IsSecret`, to refuse a secret method, script or addon name | `issecretvalue` is asked directly; without it nothing is secret. |
| LifecycleKit API 1 | closing an addon scope at logout (see [At logout](#at-logout)) | EventKit's `PLAYER_LOGOUT` closes it instead. |
| EventKit API 1 | closing an addon scope at logout when LifecycleKit is absent | Without either, the consumer closes it (case d). |

`hooksecurefunc`, `issecurevariable`, `InCombatLockdown` and `issecretvalue` are read once when the file loads; `geterrorhandler` is read at each report, and the frame methods on the frame at hand. ClientKit is looked up with `Registry:Find("clientKit", 1)` when a name is validated, never on a hooked call, so it may load after HookKit. LifecycleKit and EventKit are looked up with `Registry:Find` by `ForAddon`, so they may load in any order too.

## Public surface

Package facade:

| Member | Purpose |
|---|---|
| `CreateScope([options])` | Create a manually owned hook scope. `options.maxHooks` opens its limit (see [Limits](#limits)). |
| `ForAddon(addonName[, options])` | Return the canonical scope of an addon, creating it on demand. The first call fixes its limit (`options.maxHooks` or the default); a later different one raises (see [Limits](#limits)). |
| `CloseAddonScopes(addonName)` | Close that addon's scope; returns `false` when it has none or it was already closed. |
| `MAX_HOOKS` | `256`, the default `maxHooks`: the most hooks one scope holds at once unless opened. |
| `UNBOUNDED` | Sentinel for `options.maxHooks`: the scope holds any number of hooks. |
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
| `GetMaxHooks()` | The scope's limit: a positive integer, or `HookKit.UNBOUNDED`. |

Every hook method returns `true` when it installed the hook and `nil, "full"` when the scope already holds its `maxHooks` hooks (256 unless opened). Everything else that stops a hook raises at the caller's line (see [Refusals](#refusals)).

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
| A non-secure script hook on a protected frame in combat lockdown | `cannot replace a script of a protected frame during combat lockdown` | none: a conservative HookKit rule, not a host restriction HookKit relies on |
| A non-secure script hook of a script HookKit already holds a `SecureHookScript` post-hook on, in any scope | `refuses to replace script "<script>": HookKit holds a SecureHookScript post-hook on it, which SetScript may drop; Unhook it first, or install the pre-hook before the post-hook` | none |
| Any script hook of a frame that is forbidden (`IsForbidden`) or not accessible in this context (`CanBeAccessedInContext`) | `frame is forbidden or not accessible in this context` | none |
| A target that is not a function | `target "<method>" is not a function` | — |
| A second hook of the same target in one scope | `"<method>" is already hooked in this scope; Unhook it first` | — |
| Any hook on a closed scope | `cannot hook in a closed scope` | — |

**Secure status is remembered.** "Secure" means `issecurevariable(object, method)` (or `issecurevariable(globalName)`) answered `true` the first time HookKit checked that target, which is always before HookKit's first non-secure write to it. A forced hook taints the field, after which the host answers `false`; HookKit keeps answering from its memo, so a second scope, or the same scope after `Unhook`, is still refused. The memo is weak-keyed by the hooked object.

**Inherited methods.** The client reports an absent raw key as secure, so asking about the object itself would refuse every method it inherits. When `object[method]` is not a raw field, HookKit follows the metatables' `__index` tables (at most 8 levels) to the table that actually holds the method and asks `issecurevariable` about that one. A method your addon's mixin provides can therefore be hooked without `forceSecure`, while a method a real frame inherits from the host's method table (`frame.Show`, say) is secure even on a frame your addon created, and needs `forceSecure`. A method behind an `__index` **function**, behind a protected metatable, or deeper than 8 levels cannot be located and is treated as not secure: HookKit cannot check it, so it does not refuse it.

**Scripts of protected frames.** A frame is protected when `frame:IsProtected()` answers `true`. Only the click and attribute scripts — `OnClick`, `PreClick`, `PostClick`, `OnDoubleClick` and `OnAttributeChanged`, from which secure action buttons, secure handlers and state drivers act — are refused outright. The secure handler templates drive further scripts (`OnEnter`/`OnLeave`, `OnShow`/`OnHide`, `OnMouseDown`/`OnMouseUp`, `OnMouseWheel`, `OnDragStart`/`OnReceiveDrag`); those, like every other script of a protected frame, are refused unless you pass `forceSecure`, and in combat lockdown not even then. Post-hooking any script with `SecureHookScript` is always allowed.

**Double hooks** are refused rather than silently replaced: an implicit unhook-then-hook would reorder the chain behind the caller's back. Two *different* scopes may hook the same target; their closures chain.

Argument errors name the parameter: `HookKit.Scope:Hook method must be a non-empty string`, `... handler must be a function`, `... options contains unknown field "<name>"`, `... options.forceSecure must be a boolean`, `HookKit.Scope:HookScript frame must have a GetScript method`. A method, script, global or addon name that is a secret value is refused with `... must not be a secret value`, before HookKit compares it or uses it as a key. A secret `options.forceSecure` (Retail 12.x; a secret boolean passes the type check) is refused the same way, with `... options.forceSecure must not be a secret value`, before HookKit compares or tests it; testing a secret boolean raises in tainted code (measured on Retail 12.1.0 b69933).

## Unhook: restore or go inert

`Unhook` always removes the scope's record and clears the closure's active flag. What happens to the installed function depends on who owns it now:

| Kind | The installed function is still HookKit's | Someone hooked the target after HookKit |
|---|---|---|
| `secure`, `secureScript` | The closure stays, inert. The host owns it. | The same. |
| `hook`, `rawHook` | The original is written back. When the original came through `__index` (the field was not a raw field before the hook), the field is **deleted** instead, so the inherited function shows through again and no addon-written value stays in the field (the host may still report the slot as tainted). | The closure stays in their chain, inert: it forwards every argument to the original and returns its results. Restoring under them would cut their hook out. |
| `hookScript`, `rawHookScript` | `frame:SetScript(script, previous)`, where `previous` may be `nil`. The closure stays, inert, instead while any HookKit scope holds a `SecureHookScript` post-hook on that script (restoring would drop it), on a protected frame in combat lockdown (a conservative HookKit rule), and on a frame that has become forbidden or inaccessible. | The closure stays, inert, forwarding to the previous script. |

"Still HookKit's" is `rawget(object, method) == installed` for a field and `frame:GetScript(script) == installed` for a script. **Install direction for scripts.** `HookScript` and `RawHookScript` install with `SetScript`. If the host drops the post-hooks added with `Frame:HookScript` when `SetScript` runs, installing a pre-hook after them would silently remove them — other addons' and HookKit's own — while `IsHooked` still answered `true` for HookKit's. HookKit therefore refuses a script pre-hook or replacement while any HookKit scope holds a `SecureHookScript` post-hook on that script, and the safe order is pre-hook first, post-hooks after. For the same reason, unhooking a pre-hook or replacement that has a HookKit post-hook installed after it leaves its closure in place, inert, rather than calling `SetScript`. It cannot see other addons' `HookScript` post-hooks; prefer `SecureHookScript`, which never calls `SetScript`.

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

`ForAddon` makes sure somebody takes the second step whenever the framework can observe logout; see [At logout](#at-logout).

Closing is terminal. The closed scope stays the addon's canonical scope, so a later `ForAddon("MyAddon")` returns it and refuses new hooks. Calling `CloseAddonScopes` for an addon that never asked for a scope records nothing and returns `false`, so the addon-scope map grows only with `ForAddon` calls. Manual scopes are never closed by `CloseAddonScopes`.

A scope does not keep a hooked table alive: its records are keyed by object in a weak-keyed table and never reference the object. In Lua 5.1 that only helps when your handler does not itself capture the object, because a weak-keyed table cannot collect a key its value references.

## At logout

An addon scope is closed at logout whenever the framework can observe logout at all, whichever LifecycleKit, EventKit and HookKit revisions an addon set pairs. HookKit never depends on LifecycleKit (design constitution, principle 4b); `ForAddon` finds the other two Kits with `Registry:Find` and decides who closes the scope:

| Case | Registered | Who closes the addon scope |
|---|---|---|
| (a) | LifecycleKit whose `LifecycleKit.CLOSES_ADDON_SCOPES` names `hookKit` (0.6.0 and later) | LifecycleKit, after the addon's shutdown callbacks. `ForAddon` only makes sure the addon has a LifecycleKit instance (`LifecycleKit:ForAddon(addonName)`), because LifecycleKit closes the scopes of the addons it tracks. |
| (b) | LifecycleKit without that field (older revisions) | HookKit subscribes once to `LifecycleKit:ForAddon(addonName):OnShutdown` and calls `CloseAddonScopes` there. The subscription is kept on the scope and disconnected when the scope closes first. |
| (c) | EventKit, no LifecycleKit | One package-level `EventKit` `Once("PLAYER_LOGOUT")` connection, in HookKit's own EventKit scope and made on the first `ForAddon` that needs it, closes every addon scope in cases (c) and (d), in addon-name order. |
| (d) | neither | Nothing is subscribed. The consumer closes the scope itself on `PLAYER_LOGOUT`: `HookKit:CloseAddonScopes("MyAddon")`. |

The decision is made at the first `ForAddon(addonName)` and taken again by every later `ForAddon` while it is (c) or (d), so a LifecycleKit that loads after the first call still takes the scope over: an addon's files each call `ForAddon`, and the first one usually runs before a later-loading addon embeds LifecycleKit. The (c) watcher leaves a scope that moved to (a) or (b) to LifecycleKit. A failure in another Kit while deciding goes to the host error handler; `ForAddon` still returns the scope, and the next call asks again.

In case (b) HookKit's `OnShutdown` subscription is made at the first `ForAddon`, so it runs before the addon's own shutdown callbacks subscribed later: those callbacks then find the hooks already undone. Only case (a) guarantees that shutdown callbacks can still rely on their hooks, which is why LifecycleKit 0.6.0 announces the list. Manual scopes are never closed at logout.

## Cost

- **A hooked call** reads one flag and one dispatch field, then calls: `pcall(handler, ...)` for a post-hook or pre-hook, a direct call for a replacement. It allocates nothing, whether active or inert.
- **One closure and one record per hook**, created when the hook is installed. A secure hook's closure lives for the session.
- **`IsHooked`, `Original` and `GetActiveCount`** allocate nothing. A lookup of an object the scope never hooked creates nothing.
- **`Hooks()`, `UnhookAll()` and `Close()`** allocate one array per call (plus one row per hook for `Hooks()`); they are for diagnostics and teardown.
- **`GetActiveCount()` and the `maxHooks` check count the records** rather than reading a stored counter, so the records of a garbage-collected object stop counting at once. The count walks every record, so it grows with the limit a scope was opened to; a scope opened with `HookKit.UNBOUNDED` skips the check entirely. `Hooks()`, `UnhookAll()` and `Close()` sort by insertion, which is quadratic in the hooks held; that is negligible at 256 and worth knowing at thousands.

## Limits

HookKit follows the framework rule "bounded by default, opened on purpose" (`docs/DESIGN_CONSTITUTION.md`, principle 4a).

| Limit | Default | How to open | UNBOUNDED allowed? |
|---|---|---|---|
| `maxHooks`, hooks one scope holds at once | `256` (`HookKit.MAX_HOOKS`) | `HookKit:CreateScope({ maxHooks = n })` or `HookKit:ForAddon(addonName, { maxHooks = n })` | Yes: `{ maxHooks = HookKit.UNBOUNDED }`. The hooks are the scope owner's own registrations. |

```lua
local hooks = HookKit:ForAddon("MyAddon", { maxHooks = 1024 })
local everything = HookKit:CreateScope({ maxHooks = HookKit.UNBOUNDED })
print(hooks:GetMaxHooks()) -- 1024
```

- **A hook beyond the limit is refused with `nil, "full"`**, never installed silently and never dropped; the target is left untouched.
- **`maxHooks` is a positive integer or `HookKit.UNBOUNDED`.** Zero, a negative, fractional, infinite or NaN number, any other type, a secret value and an unknown option field raise at the caller's line: `HookKit:CreateScope options.maxHooks must be a positive integer or HookKit.UNBOUNDED`. The secret check runs first, before the value is compared with `HookKit.UNBOUNDED` or a number. Nothing changes when the options are refused.
- **The limit is per scope and fixed when the scope is created.** A manual scope's limit is fixed at `CreateScope`. An addon's canonical scope is shared by every file of the addon, so the first `ForAddon` call fixes its limit: `options.maxHooks`, or `HookKit.MAX_HOOKS` when that call names none. A later call naming a different limit raises at the caller (`HookKit:ForAddon options.maxHooks differs from the limit this addon's scope was created with`) and changes nothing; a later call naming the same limit, or none, returns the scope. State the limit in the file that loads first and omit it elsewhere. This is the rule every Kit follows for limit options on a shared object (CommandKit's `ForAddon`, LocaleKit's `GetLocale`; SignalKit buses differ only in that a call stating no limit does not fix the default).
- **Why open it deliberately.** The limit is a guard against hooking in a loop by mistake, and every secure post-hook stays in the host's call chain for the session even after `Unhook`. Raising it costs only the owner's own memory and the counting described under [Cost](#cost).
- **`HookKit.UNBOUNDED` is one table shared by every embedded copy.** It lives in the package state, so a scope opened with it stays unbounded across an in-place upgrade.

One bound stays a hard ceiling. The secure-target check follows at most **8** `__index` tables (`MAX_INDEX_DEPTH`) to find the table that actually holds an inherited method. It bounds a walk, not retained memory, and exists so a cyclic `__index` chain cannot loop for ever; real frames and mixins are one or two levels deep. A method deeper than that cannot be located and is treated as not secure, so it is not refused (see [Refusals](#refusals)).

## Deviations from the planned contract

The nine-point plan in `docs/ROADMAP.md` is followed except where recorded here:

- **The replacement handler receives the original first**, not last; see [Raw replacement](#raw-replacement).
- **Scripts of protected frames:** only the click and attribute scripts are refused outright; every other script of a protected frame needs `forceSecure`, and none is replaced in combat lockdown. See [Refusals](#refusals).
- **A script pre-hook or replacement is refused while HookKit holds a `SecureHookScript` post-hook on that script**, because `SetScript` may drop it.
- **`CloseAddonScopes` records nothing for an addon without a scope** and returns `false`, as SignalKit's `CloseAddonBus` does, instead of recording a closed scope.
- **Additions:** `RawHookScript`; `Original`; `IsClosed`, `GetActiveCount`, `GetAddonName` and `HookKit:CloseAddonScopes` (the TimerKit and EventKit scope vocabulary); the global-name forms of the hook and lookup methods; the kind as `IsHooked`'s second result; `HookKit.MAX_HOOKS`; `options.maxHooks`, `HookKit.UNBOUNDED` and `GetMaxHooks` (see [Limits](#limits)).
- **`securecallfunction` is not used** and ClientKit supplies only `IsSecret`; see [The taint model](#the-taint-model-read-this-first).

## Upgrades

Every installed closure calls through the shared `_state.dispatch` table, and scopes keep their metatable across upgrades. A newer compatible revision therefore replaces the behaviour behind hooks an older copy installed — including the permanent secure closures — without touching the host's chain, and existing scopes gain the new methods in place. The `HookKit.UNBOUNDED` sentinel and each scope's `maxHooks` are kept, so a scope opened by an older copy stays open.

Revision 2 upgrades the addon scopes revision 1 built (scope layout 1) in place and arranges their [logout close](#at-logout) while it loads, for every open one, instead of waiting for a `ForAddon` the addon may never call again. A later revision keeps the `OnShutdown` subscriptions and the `PLAYER_LOGOUT` watcher it inherits: both call through the facade or `dispatch`, so they run the newest code, and nothing is subscribed twice.
