# ToastKit

ToastKit shows short notifications that appear, stay a few seconds and fade: "profile copied", "a new version is out", an addon's achievement-style note. A toast has a title, an optional text and icon, and an optional click handler. Toasts stack at one anchor on the screen, growing down or up; when the screen holds as many as it may, the rest wait in a queue.

```lua
local ToastKit = MoltenCodes.Registries[2]:Get("toastKit", 1)

-- Bottom right, growing up.
ToastKit:SetAnchor("BOTTOMRIGHT", -40, 160, "UP")

ToastKit:Show({
  title = "My Addon 2.3 is out",
  text = "Click to see what changed.",
  icon = [[Interface\AddOns\MyAddon\Icon]],
  duration = 8,
  onClick = function()
    MyAddon:ShowChangelog()
  end,
})

-- The same key updates the toast instead of stacking a second one.
ToastKit:Show({ key = "MyAddonSync", title = "Syncing", text = "2 of 5" })
```

What each piece promises:

- **Frames of its own.** Blizzard's alert system (`AlertFrame`) is never touched. Toasts come from a PoolKit pool that keeps every released frame, because the client never frees one.
- **Out of the way.** A toast lives its `duration` (5 seconds by default), fades over its last half second and is gone; while the cursor rests on it, it holds and stays opaque. A click runs `onClick(data)` and dismisses it.
- **Keyed.** A `key` updates the toast shown or waiting under it and starts its time again; what the new options leave out is cleared.
- **Callbacks cannot break it.** `onClick` runs protected; one that raises is reported through the error handler.
- **Bounded.** At most 5 toasts on screen (up to 20 with `SetLimits`), and 32 waiting (`ToastKit.UNBOUNDED` lifts that).

Non-goals: Blizzard's alerts, chat messages, sounds (call `PlaySound` yourself).

See [`docs/API.md`](docs/API.md) for the complete contract.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\poolKit\PoolKit.lua
Libs\MoltenCodes\toastKit\ToastKit.lua
```

Minimum footprint: embed 3 files: `registry/Registry.lua`, `poolKit/PoolKit.lua`, `toastKit/ToastKit.lua`.

Direct runtime dependencies: Registry API 2, PoolKit API 1.
Every file above is required; omitting one makes this package raise at
load.

ToastKit makes its frames when a toast is shown, never at load.
