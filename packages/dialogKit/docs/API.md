# DialogKit API

DialogKit API generation **1** shows confirmation and input dialogs on one frame of its own, one at a time, with a bounded queue, Escape through `UISpecialFrames`, timeouts and callbacks that run exactly once.

Implementation revision: **1**.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
DialogKit.lua
```

Portable WoW code resolves the package through Registry:

```lua
local DialogKit = MoltenCodes.Registries[2]:Get("dialogKit", 1)
```

DialogKit does not rely on `require()` at runtime.

### Host facilities

| Facility | Used by | Without it |
|---|---|---|
| `CreateFrame`, `UIParent`; the templates `UIPanelButtonTemplate` and `InputBoxTemplate` | the dialog frame, made by the first `Show` | `Show` raises at the caller: `DialogKit:Show needs the client's CreateFrame and UIParent, which this host does not have`. |
| `UISpecialFrames` | Escape | The dialog closes only through its buttons, `Hide`, `HideAll` and its timeout. |
| `GetTime` | timeouts | A timeout never runs out. |
| `issecretvalue` | every check | Nothing is treated as secret. |
| `geterrorhandler` | callbacks that raise | The failure is printed. |

Every promised client defines `UISpecialFrames` the same way, as the list of frame names `CloseSpecialWindows` hides on Escape (Blizzard's `UIParentPanelManager.lua`, branches `live`, `classic` and `classic_era`, read 2026-11-15).

## Public surface

| Member | Purpose |
|---|---|
| `Show(options)` | Show a dialog, or queue it behind the one shown; return it. |
| `HideAll()` | End every dialog with `onCancel(data, "hidden")`, the waiting ones first; return how many ended. |
| `SetLimits(limits)` / `GetLimits()` | Change or read `maxQueued`; `GetLimits` returns a fresh table. |
| `MAX_QUEUED` | `16`, the default `maxQueued`. |
| `FRAME_NAME` | `"MoltenCodesDialogKitFrame"`, the dialog frame's global name. |
| `UNBOUNDED` | Sentinel `maxQueued` accepts to lift the bound. |
| `API`, `REVISION` | `1`, `1`. |

A dialog:

| Method | Purpose |
|---|---|
| `Hide()` | End it with `onCancel(data, "hidden")`: the shown dialog makes way for the next, a waiting one leaves the queue. `false` when it already ended. |
| `IsShown()` | Whether it is the dialog on screen. |
| `IsQueued()` | Whether it waits behind the shown one. |
| `GetInput()` | The input line's text while it is shown with one, else `nil`. |

## `DialogKit:Show(options)`

| Option | Meaning |
|---|---|
| `text` | The dialog's text, a non-empty string or a number; required. |
| `accept` | The accept button's text; default `"OK"`. |
| `cancel` | The cancel button's text; default `"Cancel"`; `false` for a dialog with one button. |
| `onAccept` | `onAccept(data, inputText)`, when the accept button or Enter in the input line is pressed. `inputText` is `nil` without an input line. |
| `onCancel` | `onCancel(data, reason)`, when the dialog ends any other way. |
| `data` | Any value, handed to both callbacks. |
| `input` | `true` shows an input line, focused, below the text. |
| `inputText` | The input line's starting text; default empty. |
| `maxLetters` | The input line's letter limit, a positive integer; default none. |
| `timeout` | Seconds; the dialog is cancelled with `"timeout"` once shown that long. |
| `key` | A non-empty string; while a dialog shown or waiting has this key, `Show` returns it instead of a second one. |
| `allowSecret` | `true` draws a secret `text` instead of refusing it. |

Any other field is refused at the caller. When no dialog is shown, the new one is shown at once: the frame is placed near the top of the screen at the `DIALOG` strata, sized to the text, the input line and the buttons. Otherwise it waits; at most `maxQueued` dialogs wait: `DialogKit:Show holds at most 16 waiting dialogs; raise maxQueued with DialogKit:SetLimits`.

## How a dialog ends

| What happened | Callback | Reason |
|---|---|---|
| The accept button, or Enter in the input line | `onAccept(data, inputText)` | — |
| The cancel button | `onCancel(data, reason)` | `"cancel"` |
| Escape in the input line, or Escape through `UISpecialFrames` (the frame hidden by anything but DialogKit) | `onCancel` | `"escape"` |
| The timeout | `onCancel` | `"timeout"` |
| `dialog:Hide()`, `DialogKit:HideAll()` | `onCancel` | `"hidden"` |

A dialog ends once; afterwards `Hide` answers `false` and the callbacks are never called again. The frame is hidden before the callback runs, so a callback may show another dialog: it is shown at once, ahead of the queue. Then the next waiting dialog is shown. A callback that raises is reported through `geterrorhandler`, and the next dialog is still shown.

## Secret values

A secret `text` is refused unless `allowSecret` is `true`; every other option, the limits and the receivers are checked with `issecretvalue` first and refused at the caller. `data` is never inspected.

## Limits

| Limit | Default | How to open | `UNBOUNDED` allowed? | Ceiling and reason |
|---|---|---|---|---|
| `maxQueued`, dialogs waiting behind the shown one | `16` | `DialogKit:SetLimits({ maxQueued = n })` | yes | none: a waiting dialog is a Lua table |

Lowering `maxQueued` keeps every waiting dialog and refuses the next. The limit is shared by every addon in the session.

## Error behaviour

Argument errors raise at the caller's line: `DialogKit:Show options.timeout must be a number above 0`; methods called on anything but a dialog raise `DialogKit.Dialog:Hide must be called on a DialogKit dialog; use dialog:Hide(...)`. What the client calls (the buttons, Enter, Escape, the timeout) never raises.

## Performance

| Path | Cost |
|---|---|
| A dialog on screen | Nothing per frame, unless it has a timeout: one clock read per frame. |
| `Show` | One record; the first also builds the frame. |
| A waiting dialog | One Lua table. |

## Embedded copies and upgrades

Several addons may embed DialogKit; Registry selects the newest compatible revision and every copy shares one facade and one state: the frame, the shown and waiting dialogs, the limit and the `UNBOUNDED` sentinel. The frame's scripts call through a dispatch table in the shared state that every loading revision rewrites, so a dialog an older copy showed is ended by the newest copy's code, and the frame's name is added to `UISpecialFrames` only once.
