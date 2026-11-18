# ToastKit API

ToastKit API generation **1** shows short, pooled notifications stacked at one anchor, held under the cursor, fading out, with click handlers, keys and a bounded queue.

Implementation revision: **1**.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
PoolKit.lua
ToastKit.lua
```

Portable WoW code resolves the package through Registry:

```lua
local ToastKit = MoltenCodes.Registries[2]:Get("toastKit", 1)
```

ToastKit does not rely on `require()` at runtime.

### Host facilities

| Facility | Used by | Without it |
|---|---|---|
| `CreateFrame`, `UIParent` | `Show` | `Show` raises at the caller: `ToastKit:Show needs the client's CreateFrame and UIParent, which this host does not have`. |
| `issecretvalue` | every check; read once at load, and again on each check only when it was absent at load | Nothing is treated as secret. |
| `geterrorhandler` | an `onClick` that raises | The failure is printed. A handler that itself raises is not propagated either: the failure is printed instead. |

A toast counts its own time from the `elapsed` its `OnUpdate` receives, so ToastKit needs no clock.

## Public surface

| Member | Purpose |
|---|---|
| `Show(options)` | Show a toast, or queue it; return it. |
| `DismissAll()` | End every toast, the waiting ones first; return how many ended. |
| `SetAnchor(point, x, y, direction?)` | Where the stack starts on `UIParent`, and whether it grows `"DOWN"` (the default) or `"UP"`. |
| `SetLimits(limits)` / `GetLimits()` | Change or read `maxVisible` and `maxQueued`; `GetLimits` returns a fresh table. |
| `MAX_VISIBLE`, `VISIBLE_CEILING`, `MAX_QUEUED` | `5`, `20`, `32`. |
| `UNBOUNDED` | Sentinel `maxQueued` accepts to lift the bound. |
| `API`, `REVISION` | `1`, `1`. |

A toast:

| Method | Purpose |
|---|---|
| `Dismiss()` | End it now: `true`, or `false` when it already ended. |
| `IsShown()` | Whether it is on screen. |
| `IsQueued()` | Whether it waits for a place on screen. |

## `ToastKit:Show(options)`

| Option | Meaning |
|---|---|
| `title` | The first line, a non-empty string or a number; required. |
| `text` | A second, smaller line. |
| `icon` | A texture path or a FileDataID, shown on the left. |
| `duration` | Seconds on screen, above 0; default `5`. |
| `onClick` | `onClick(data)`, when the toast is clicked; the toast is dismissed first. |
| `data` | Any value, handed to `onClick`. |
| `key` | A non-empty string: a toast shown or waiting under it is updated with these options and starts its time again. |
| `allowSecret` | `true` draws a secret `title` or `text` instead of refusing it. |

Any other field is refused at the caller. A toast is a 260 by 48 frame at the `HIGH` strata. The first toast sits at the anchor (`"TOP"`, 0, -120 until `SetAnchor` moves it); each next one 54 pixels further in the stack's direction, and the stack closes up when one ends. With `maxVisible` toasts on screen, a new one waits; at most `maxQueued` wait: `ToastKit:Show holds at most 32 waiting toasts; raise maxQueued with ToastKit:SetLimits`.

## A toast's life

Each frame on screen, a toast adds the frame's `elapsed` to its age, unless the cursor rests on it (`IsMouseOver`), which holds it fully opaque. In its last half second its alpha falls to 0; at its `duration` it ends. A click ends it and then runs `onClick(data)`, protected. Toasts are children of `UIParent`, so while the player hides the interface (Alt+Z) they are hidden too, their `OnUpdate` does not run and their time stands still. When a toast ends, its frame goes back to the pool (hidden, opaque, no texts, no icon, no anchor) and the first waiting toast takes the free place.

## Secret values

A secret `title` or `text` is refused unless `allowSecret` is `true`; every other option, the anchor, the limits and the receivers are checked with `issecretvalue` first and refused at the caller. A secret `elapsed` or mouse-over answer is ignored for that frame.

## Limits

| Limit | Default | How to open | `UNBOUNDED` allowed? | Ceiling and reason |
|---|---|---|---|---|
| `maxVisible`, toasts on screen | `5` | `ToastKit:SetLimits({ maxVisible = n })` | no | `20`: each is a frame the session keeps |
| `maxQueued`, toasts waiting | `32` | `ToastKit:SetLimits({ maxQueued = n })` | yes | none: a waiting toast is a Lua table |

Raising `maxVisible` shows waiting toasts at once; lowering a limit keeps every toast and applies to the next. The limits are shared by every addon in the session.

## Error behaviour

A failure of a toast's `onClick` goes to the host error handler (`geterrorhandler()`), called under `pcall`. When the client has no handler, or the handler itself raises (an error-display addon with a bug), the failure is printed instead, so reporting it never raises into the client's script call (revision 2; earlier revisions let a raising handler's error through).

Argument errors raise at the caller's line: `ToastKit:Show options.duration must be a number above 0`; methods called on anything but a toast raise `ToastKit.Toast:Dismiss must be called on a ToastKit toast; use toast:Dismiss(...)`. What the client calls (the frames' updates and clicks) never raises.

Every message, raised at the caller's line. `<method>` is the public name called, such as `ToastKit:Show` or `ToastKit.Toast:Dismiss`.

| Message | Raised by |
|---|---|
| `<method> must be called on the ToastKit facade; use <method>(...)` | a facade method called on anything but `ToastKit` |
| `<method> must be called on a ToastKit toast; use toast:<name>(...)` | a toast method called on anything but a toast handle |
| `ToastKit:Show options must be a table` | |
| `ToastKit:Show options holds an unknown field; it accepts title, text, icon, duration, onClick, data, key and allowSecret` | |
| `ToastKit:Show options.allowSecret must be a boolean` | |
| `ToastKit:Show options.<title or text> must not be a secret value; pass allowSecret = true to draw one` | |
| `ToastKit:Show options.<title or text> must be a non-empty string or a number` | a missing `title`, or a text that is neither |
| `ToastKit:Show options.icon must be a texture path, a FileDataID or nil` | also a secret icon |
| `ToastKit:Show options.duration must be a number above 0` | also NaN and infinity |
| `ToastKit:Show options.onClick must be a function or nil` | |
| `ToastKit:Show options.key must be a non-empty string` | |
| `ToastKit:Show needs the client's CreateFrame and UIParent, which this host does not have` | |
| `ToastKit:Show holds at most <n> waiting toasts; raise maxQueued with ToastKit:SetLimits` | a full screen and a full queue |
| `ToastKit:SetAnchor point must be an anchor point such as "TOP" or "BOTTOMRIGHT"` | a point other than the nine anchor points |
| `ToastKit:SetAnchor <x or y> must be a finite number` | |
| `ToastKit:SetAnchor direction must be "UP", "DOWN" or nil` | |
| `ToastKit:SetLimits limits must be a table` | |
| `ToastKit:SetLimits limits holds an unknown field; it accepts maxVisible and maxQueued` | |
| `ToastKit:SetLimits limits.<name> must not be a secret value` | |
| `ToastKit:SetLimits limits.maxVisible must be an integer from 1 to 20` | |
| `ToastKit:SetLimits limits.maxQueued must be a positive integer or ToastKit.UNBOUNDED` | |

`ToastKit needs the client's UIParent` is raised without a position only by a host that removed `UIParent` after `Show` checked it.

Loading raises `MoltenCodes ToastKit requires Registry API 2 to be loaded first`, `MoltenCodes ToastKit requires a valid Registry API 2 facade`, `MoltenCodes ToastKit requires PoolKit API 1 to be loaded first` or `MoltenCodes ToastKit package state is corrupted or incomplete`.

## Performance

| Path | Cost |
|---|---|
| A toast on screen | One `OnUpdate`: an addition and, at the end, an alpha. |
| A waiting toast | One Lua table, nothing per frame. |
| `Show`, a toast ending | One pool operation and a restack of the shown toasts. |

## Embedded copies and upgrades

Several addons may embed ToastKit; Registry selects the newest compatible revision and every copy shares one facade and one state: the shown and waiting toasts, the anchor, the pool, the limits and the `UNBOUNDED` sentinel. The pool's factory and reset and every frame's scripts call through a dispatch table in the shared state that every loading revision rewrites, so toasts an older copy showed run the newest copy's code.
