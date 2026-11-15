# DialogKit

DialogKit shows confirmation and input dialogs without `StaticPopupDialogs`. An addon that adds its own entries to Blizzard's `StaticPopupDialogs` table and calls `StaticPopup_Show` runs its code inside Blizzard's popup system and can taint it. DialogKit draws its dialogs on one frame of its own, with the client's button and input-box templates: a text, one or two buttons, an optional input line and an optional timeout.

```lua
local DialogKit = MoltenCodes.Registries[2]:Get("dialogKit", 1)

DialogKit:Show({
  key = "MyAddonResetProfile",
  text = "Reset the current profile to its defaults?",
  accept = "Reset",
  onAccept = function()
    db:ResetProfile()
  end,
})

DialogKit:Show({
  text = "Name the new profile:",
  input = true,
  maxLetters = 32,
  onAccept = function(_, name)
    if name ~= "" then
      db:SetProfile(name)
    end
  end,
})
```

What each piece promises:

- **Blizzard's popups untouched.** Nothing is added to `StaticPopupDialogs`; the only shared table DialogKit writes is `UISpecialFrames`, once, with its own frame's name, so Escape closes the dialog as it closes the client's windows.
- **One at a time, in order.** A dialog shown while another is on screen waits in a queue and is shown when the first ends. A `key` returns the dialog already shown or waiting under it, so a button clicked twice never asks twice.
- **Ends exactly once.** The accept button and Enter call `onAccept(data, inputText)`; the cancel button, Escape, the timeout, `dialog:Hide()` and `DialogKit:HideAll()` call `onCancel(data, reason)` with `"cancel"`, `"escape"`, `"timeout"` or `"hidden"`. Each runs protected; one that raises is reported through the error handler.
- **Bounded by default, opened on purpose.** 16 dialogs may wait; `DialogKit:SetLimits({ maxQueued = n })` changes it, `DialogKit.UNBOUNDED` lifts it.

Non-goals: changing Blizzard's own popups, arbitrary widgets in a dialog (build a WidgetKit window), several dialogs on screen at once.

### Moving from StaticPopup_Show

| StaticPopup | DialogKit |
|---|---|
| `StaticPopupDialogs["MYADDON_RESET"] = { text = ..., button1 = ..., button2 = ..., OnAccept = ... }` then `StaticPopup_Show("MYADDON_RESET")` | `DialogKit:Show({ key = "MYADDON_RESET", text = ..., accept = ..., cancel = ..., onAccept = ... })` |
| `hasEditBox = true`, `self.editBox:GetText()` in `OnAccept` | `input = true`; the text is `onAccept`'s second argument |
| `OnCancel(self, data, reason)` | `onCancel(data, reason)` |
| `timeout = 30` | `timeout = 30` |
| `StaticPopup_Hide("MYADDON_RESET")` | `dialog:Hide()` |

See [`docs/API.md`](docs/API.md) for the complete contract.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\dialogKit\DialogKit.lua
```

Minimum footprint: embed 2 files: `registry/Registry.lua`, `dialogKit/DialogKit.lua`.

Direct runtime dependencies: Registry API 2.
Every file above is required; omitting one makes this package raise at
load.

DialogKit makes its frame the first time a dialog is shown, never at load.
