# OptionsKit

OptionsKit describes what a World of Warcraft addon exposes as configurable — a tree of groups and typed options — and checks every value written through it against a SchemaKit schema. It draws nothing: a dialog (WidgetKit) and a command line (CommandKit) read the same tree.

```lua
local Registry = MoltenCodes.Registries[2]
local OptionsKit = Registry:Get("optionsKit", 1)

local options = OptionsKit:Define("MyAddon", {
    type = "group",
    name = "My Addon",
    args = {
        general = {
            type = "group",
            name = "General",
            order = 1,
            args = {
                enabled = { type = "toggle", name = "Enabled", bind = "profile.enabled" },
                scale = { type = "range", name = "Scale", min = 0.5, max = 2, step = 0.05, bind = "profile.frame.scale" },
                anchor = {
                    type = "select",
                    name = "Anchor",
                    values = { TOP = "Top", CENTER = "Center", BOTTOM = "Bottom" },
                    sorting = { "TOP", "CENTER", "BOTTOM" },
                    bind = "profile.frame.anchor",
                },
            },
        },
        advanced = {
            type = "group",
            name = "Advanced",
            order = 2,
            hidden = function()
                return not MyAddon.showAdvanced
            end,
            args = {
                label = {
                    type = "input",
                    name = "Label",
                    pattern = "^[%w ]*$",
                    get = function(info)
                        return MyAddon.label
                    end,
                    set = function(info, value)
                        MyAddon.label = value
                        MyAddon:RefreshLabel()
                    end,
                    validate = function(info, value)
                        if #value > 24 then
                            return false, "at most 24 characters"
                        end
                        return true
                    end,
                },
                resetPosition = {
                    type = "execute",
                    name = "Reset position",
                    confirm = "Move the frame back to the centre?",
                    func = function()
                        MyAddon:ResetPosition()
                    end,
                },
            },
        },
    },
}, { db = MyAddon.db }) -- a SettingsKit database, needed only for `bind`

options:Get("general.scale")          --> 1 (the SettingsKit default)
options:Set("general.scale", 1.25)    --> true
options:Set("general.scale", 3)       -- raises at this line: expected number <= 2
options:Set("advanced.label", "a label longer than the limit") --> false, "at most 24 characters"
options:Reset("general.scale")        --> 1
options:OnChange(function(tree, path, value) end)
options:Walk(function(path, kind, depth) end)
local description = options:Describe() -- a plain table for a renderer
```

What each piece promises:

- **Checked once, at your line.** `Define` checks the whole tree — every kind's fields, unknown fields, bind paths, bounds — and raises at the line that called it, naming the field (`OptionsKit:Define tree.args.general.args.scale.min must be a number`). The tree is copied: later edits to your tables have no effect.
- **Typed values.** Every value option gets a SchemaKit schema at `Define`: `toggle` a boolean, `range` a bounded number, `select` one of its keys, `multiselect` a map of keys to booleans, `input` a string matching its pattern, `color` `{ r, g, b[, a] }` in `0..1`, `keybinding` a string. `Set` asserts it at your line, then runs your `validate`, then writes, then fires `OnChange`.
- **Two ways to store a value.** Your own `get(info)` / `set(info, value)`, or `bind = "profile.path"` into a SettingsKit database; `Reset` restores a bound option's default.
- **Cheap where it is called often.** `Get`, `Set`, `Walk`, `IsDisabled` and `IsHidden` look paths up in a map built at `Define` and allocate nothing; `Describe` allocates by design.
- **Bounded.** At most 1024 options per tree and 8 keys per path by default, refused at `Define`; `maxOptions`, `maxDepth` (up to 32) and `maxDynamicEntries` open them per tree, and `OptionsKit.UNBOUNDED` lifts the first and last (see *Limits* in the API).
- **Secrets refused.** `Set` refuses a secret value at your line.

See [`docs/API.md`](docs/API.md) for every kind's fields and schema, the `Describe` shape and how a renderer consumes it, and [`docs/INTERNALS.md`](docs/INTERNALS.md) for the index, the sorted arrays and the reused `info` tables.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\signalKit\SignalKit.lua
Libs\MoltenCodes\schemaKit\SchemaKit.lua
Libs\MoltenCodes\optionsKit\OptionsKit.lua
```

Direct runtime dependencies: Registry API 2, SchemaKit API 1 and SignalKit API 1.
All four files above are required; omitting any of the first three makes this
package raise at load.

Optional: SettingsKit API 1, needed only when an option uses `bind`. OptionsKit
looks it up with `Registry:Find` when `Define` receives `options.db`, so it may
load in any order before that call; open the database first, then define the
tree:

```lua
local db = SettingsKit:Open("MyAddonDB", schema)
local options = OptionsKit:Define("MyAddon", tree, { db = db })
```

A tree lives for the session. Nothing needs closing at logout; `OptionsKit:Undefine(addonName)` exists for tests and for an addon that rebuilds its options.
