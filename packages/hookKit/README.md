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

Optional: ClientKit API 1, used only to recognise a secret value passed as a
method, script or addon name. HookKit looks it up with `Registry:Find` when it
validates a name, so it may load in any order; without it HookKit asks the
host's `issecretvalue` directly.

At logout an addon scope is closed by LifecycleKit, or by HookKit's own
`PLAYER_LOGOUT` watcher when only EventKit is loaded; with neither, call
`HookKit:CloseAddonScopes("MyAddon")` yourself (see "At logout" in
[`docs/API.md`](docs/API.md#at-logout)).
