# HookKit

HookKit hooks global functions, object methods and frame scripts in World of Warcraft addons, reversibly, under three named semantics whose taint consequences are spelled out — and refuses the hooks that break the client's secure code.

```lua
local HookKit = MoltenCodes.Registries[2]:Get("hookKit", 1)
local hooks = HookKit:ForAddon("MyAddon")

-- Secure post-hook: runs after the original, taints nothing but your handler.
hooks:SecureHook(GameTooltip, "SetUnit", function(tooltip, unit)
  -- ...
end)
hooks:SecureHookScript(PlayerFrame, "OnShow", function(frame) end)

-- Safe pre-hook of addon code: runs first, cannot change arguments or results.
hooks:Hook(OtherAddon, "Refresh", function(self, reason) end)

-- Raw replacement: runs instead of the original, which it receives first.
hooks:RawHook(OtherAddon, "Format", function(original, self, value)
  return original(self, value or "")
end)

hooks:Unhook(OtherAddon, "Refresh") -- restores the original if it is still ours
hooks:UnhookAll()                   -- undoes everything; the scope stays usable
```

What each piece promises:

- **Secure first.** `SecureHook` and `SecureHookScript` wrap `hooksecurefunc` and `Frame:HookScript`, so the target stays secure. They are reversible: the installed closure stays in the host's chain and reads one flag before calling you.
- **Refusals at your line.** A non-secure hook of a secure target raises unless you pass `{ forceSecure = true }`, and HookKit remembers that the target was secure before anyone tainted it. On a protected frame, replacing `OnClick`, `PreClick`, `PostClick`, `OnDoubleClick` or `OnAttributeChanged` is refused outright, and every other script needs `forceSecure`. Methods inherited through `__index` are checked on the table that holds them. A second hook of one target in one scope is refused: `Unhook` first.
- **Unhooking never breaks someone else's hook.** The original is restored only while HookKit's function is still the installed one; otherwise, or when `GetScript` hands back a secret handler that cannot be compared, HookKit's closure stays where it is, inert, forwarding every argument and result.
- **Handler errors stay visible and contained.** A post-hook or pre-hook handler that raises is reported to the host error handler; the original still runs.
- **Bounded and cheap.** At most 256 hooks per scope (`nil, "full"` beyond), opened on purpose with `CreateScope({ maxHooks = n })` or `HookKit.UNBOUNDED`; a hooked call allocates nothing; records sit in a weak-keyed table and lookups create nothing.
- **Secrets untouched.** Arguments and results pass through as they came; HookKit never inspects them.
- **Owned by a scope.** `HookKit:CreateScope()` for manual ownership, `HookKit:ForAddon(name)` for the addon's canonical scope, closed by `HookKit:CloseAddonScopes(name)`.

See [`docs/API.md`](docs/API.md) for the complete contract, which leads with the taint each semantic causes, and [`docs/INTERNALS.md`](docs/INTERNALS.md) for the record layout.

### Moving from AceHook-3.0

| AceHook-3.0 | HookKit |
|---|---|
| `LibStub("AceAddon-3.0"):NewAddon("MyAddon", "AceHook-3.0")`, hooks on the addon object | `local hooks = HookKit:ForAddon("MyAddon")`, hooks on the addon's scope |
| `self:SecureHook(object, "Method", handler)`, `self:SecureHook("GlobalName", handler)` | `hooks:SecureHook(object, "Method", handler)`, `hooks:SecureHook("GlobalName", handler)`, reversible with `Unhook` |
| `self:SecureHookScript(frame, "OnShow", handler)` | `hooks:SecureHookScript(frame, "OnShow", handler)` |
| `self:Hook(object, "Method", handler, hookSecure)` | `hooks:Hook(object, "Method", handler, { forceSecure = true })`; without the option a secure target is refused at your line |
| `self:RawHook(object, "Method", handler)`, the original read from `self.hooks[object].Method` | `hooks:RawHook(object, "Method", function(original, ...) end)`: the original is the handler's first argument, and `hooks:Original(object, "Method")` |
| `self:HookScript(frame, "OnUpdate", handler)`, `self:RawHookScript(...)` | `hooks:HookScript(frame, "OnUpdate", handler)`, `hooks:RawHookScript(...)` |
| A handler given as a method name: `self:SecureHook(GameTooltip, "SetUnit", "OnTooltipSetUnit")` | The receiver, then the name: `hooks:SecureHook(GameTooltip, "SetUnit", MyAddon, "OnTooltipSetUnit")`. The method must exist when you hook, and is looked up at every call, as in AceHook |
| The default handler: `self:Hook(object, "Method")` calls `self:Method(...)` | `hooks:Hook(object, "Method", MyAddon)`: the receiver's method of the hooked name |
| `self:Unhook(object, "Method")`, `self:UnhookAll()` | `hooks:Unhook(object, "Method")`, `hooks:UnhookAll()`; a closed manual scope comes back with `hooks:Reopen()` |
| `self:IsHooked(object, "Method")`, answering `true` and the handler | `hooks:IsHooked(object, "Method")`, answering `true` and the kind (`"secure"`, `"hook"`, ...) |
| Hooks undone when the addon is disabled (`OnEmbedDisable` calls `UnhookAll`) | `hooks:UnhookAll()` in your own disable code; the scope stays usable. The addon scope is closed at logout for you (see "At logout" in the API). |

Every hook method returns `true`, or `nil, "full"` past the scope's 256 hooks. [`docs/MIGRATING_FROM_ACE3.md`](../../docs/MIGRATING_FROM_ACE3.md#acehook-30) walks through a whole addon.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\hookKit\HookKit.lua
```

Minimum footprint: embed 2 files: `registry/Registry.lua`, `hookKit/HookKit.lua`.

Direct runtime dependency: Registry API 2.
Both files above are required; omitting Registry makes this package raise at
load.

Secret values passed as a method, script or addon name are recognised with the
host's `issecretvalue`; a client without it makes no secret values. HookKit
does not use ClientKit (since revision 7), whose `IsSecret` answers from that
same host function.

At logout an addon scope is closed by LifecycleKit, or by HookKit's own
`PLAYER_LOGOUT` watcher when only EventKit is loaded; with neither, call
`HookKit:CloseAddonScopes("MyAddon")` yourself (see "At logout" in
[`docs/API.md`](docs/API.md#at-logout)).
