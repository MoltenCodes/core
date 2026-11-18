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
    profiles = OptionsKit:ProfileOptions(MyAddon.db, { order = 90 }), -- choose, create, copy, reset, delete
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

- **Checked once, at your line.** `Define` checks the whole tree — every kind's fields, unknown fields, bind paths, bounds, method names — and raises at the line that called it, naming the field (`OptionsKit:Define tree.args.general.args.scale.min must be a number`). The tree is copied: later edits to your tables have no effect until `tree:NotifyChange()` (Dynamic part).
- **AceConfig's fields** (Presentation and Handlers parts since revision 16). `width`, `relWidth`, `descStyle`, `confirm` on every kind with `confirmText`, `arg`, images and icons, `tooltipHyperlink`, `dialogControl`, per-interface `guiHidden`/`dialogHidden`/`cmdHidden` and `*Inline`, `plugins`, `style = "radio"`, a `multiline` line count, multiselect `tristate`; `name`, `order`, `width` and the image fields may be functions, resolved by `Describe`. Method names of a `handler` (ADR 0003) are checked at `Define` and looked up on every call; `get`, `set`, `validate`, `func`, `handler` and `confirm` are inherited from groups as AceConfig inherits them (revision 14).
- **Typed values.** Every value option gets a SchemaKit schema at `Define`: `toggle` a boolean, `range` a bounded number, `select` one of its keys, `multiselect` a map of keys to booleans, `input` a string matching its pattern, `color` `{ r, g, b[, a] }` in `0..1`, `keybinding` a string. `Set` asserts it at your line, then runs your `validate`, then writes, then fires `OnChange`.
- **Two ways to store a value.** Your own `get(info)` / `set(info, value)`, or `bind = "profile.path"` into a SettingsKit database (Bind part); `Reset` restores a bound option's default.
- **Cheap where it is called often.** `Get`, `Set`, `Walk`, `IsDisabled` and `IsHidden` look paths up in a map built at `Define` and allocate nothing (the profile group's options aside, which ask the database for its profiles); `Describe` allocates by design, and `DescribeOption(path)` describes one option or group when that is all a caller needs. Options of one kind with the same inputs share one schema, and each option's record keeps to 8 fields (revision 13): a toggle with a name, getter and setter holds 477 bytes, strings included, and the fields of revision 14 cost nothing to an option that does not set them.
- **Trees that change** (Dynamic part, revision 15). `Define` takes a builder function; `tree:NotifyChange()` only marks the tree, and the next method that reads it rebuilds it once, keeping the handle and its listeners; `Replace` and `Remove` change one subtree; `OnStructureChanged` tells a renderer to redraw.
- **Bounded.** At most 1024 options per tree and 8 keys per path by default, refused at `Define`; `maxOptions`, `maxDepth` (up to 32) and `maxDynamicEntries` open them per tree, and `OptionsKit.UNBOUNDED` lifts the first and last (see *Limits* in the API).
- **Secrets refused.** `Set` refuses a secret value at your line.
- **Profiles, ready-made.** `ProfileOptions(db)` returns a group over a SettingsKit database's profiles — choose the current one (the existing profiles and this character's own), create one by name, copy another into it, reset it, delete one, with confirmations and the current profile's name in the descriptions — built from the kinds above, so every renderer shows it. With SettingsKit's spec profiles it also offers one profile per specialization (or talent group), as LibDualSpec-1.0's `EnhanceOptions` does for AceDBOptions. One group per database and options: later calls return the same table, as AceDBOptions does. The tree fires `OnChange` when the database's profile changes anywhere. Every string goes through a `localize(key, default)` hook.

See [`docs/API.md`](docs/API.md) for every kind's fields and schema, the `Describe` shape and how a renderer consumes it, and [`docs/INTERNALS.md`](docs/INTERNALS.md) for the index, the sorted arrays, the shared schemas and the reused `info` tables.

## Migrating from AceConfig-3.0 and AceDBOptions-3.0

| Ace3 | OptionsKit |
|---|---|
| `AceConfig:RegisterOptionsTable(name, options)` | `OptionsKit:Define(addonName, tree, { db = db })`: the tree is checked and copied at your line. |
| `AceConfigRegistry:GetOptionsTable(name)` | `OptionsKit:Get(addonName)` returns the tree; `tree:Describe()` gives a renderer its plain description. |
| `AceConfigRegistry:NotifyChange(name)` | `tree:NotifyChange()` (Dynamic part): the tree is read again from the table you passed or the builder, once, at the next read; `OnStructureChanged` tells renderers. Value changes fire `tree:OnChange` on every `Set` and `Reset`. |
| `RegisterOptionsTable(name, function)` | `OptionsKit:Define(addonName, builder)` (Dynamic part). |
| `args` assigned after registration | Assign them in the table you passed (and keep it) or the builder, then `tree:NotifyChange()`; or `tree:Replace(path, option)` and `tree:Remove(path)` for one subtree. |
| `IterateOptionsTables()` | `OptionsKit:GetTrees()`, a sorted array of addon names. |
| `AceConfigDialog:Open(name)`, `AddToBlizOptions` | WidgetKit's `RenderOptions` and PanelKit, which read the tree. |
| `AceConfigCmd` | CommandKit's `BindOptions`. |
| `get = "Method"`, `handler`, inherited `get`/`set` | The same, with the Handlers part (revision 16; revision 14 in the core): a method name is checked at `Define` and looked up per call; `get`, `set`, `validate`, `func` and `handler` on a group apply below it. `confirm = "Method"` is the exception: a `confirm` string is the question, so write a function. |
| `width`, `relWidth`, `arg`, `descStyle`, `image`, `icon`, `tooltipHyperlink`, `dialogControl`, `style = "radio"`, `plugins`, function `name` and `order`, per-interface `guiHidden`/`dialogHidden`/`cmdHidden` | The same fields; `arg` is the core's, `plugins` the Handlers part's, the rest the Presentation part's (revision 16); `info.arg` and `info.handler` as in Ace3. `dropdownHidden`, `dropdownInline` and `dropdownControl` are refused: no Ace3 interface reads them. |
| `name` and `order` as functions | The same; `Describe` calls them before it sorts, while `Walk` keeps the order of `Define`. |
| `confirm` on a toggle or select | The same; a renderer asks `tree:GetConfirmation(path, value)` before `Set`. |
| `guiHidden`, `dialogHidden`, `cmdHidden`, `*Inline` | The same; `tree:IsHidden(path, "dialog")` and `Describe("cmd")` answer per interface. |
| `childGroups = "tab"`, `"tree"`, `"select"` | The same hint on a `group` (revision 10); WidgetKit draws it. |
| `AceDBOptions:GetOptionsTable(db)` | `OptionsKit:ProfileOptions(db)` (Profiles part), one cached group per database and options. |
| An AceDB namespace's settings | `bind = "ns:<name>.profile.key"` into SettingsKit's namespaces (SettingsKit revision 15), with the Bind part. |
| Converting an existing AceConfig table | BridgeKit's `DefineAceConfig`. |

The full guide, with every difference, is in [`docs/MIGRATING_FROM_ACE3.md`](../../docs/MIGRATING_FROM_ACE3.md).

## Migrating from LibDualSpec-1.0's options

| LibDualSpec-1.0 | OptionsKit |
|---|---|
| `LibDualSpec:EnhanceOptions(AceDBOptions:GetOptionsTable(db), db)` | `OptionsKit:ProfileOptions(db)`: the group already holds the spec-profile selects when SettingsKit has spec profiles (SettingsKit 0.4.0). |
| The "Enable spec profiles" toggle | None: choosing a profile for a specialization enables switching for it, `None` disables it. |
| One select per specialization, named after it | `profiles.spec1` to `profiles.spec8`, shown for the character's specializations (or talent groups) only. |

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\signalKit\SignalKit.lua
Libs\MoltenCodes\schemaKit\SchemaKit.lua
Libs\MoltenCodes\schemaKit\parts\SchemaKit-Rules.lua
Libs\MoltenCodes\optionsKit\OptionsKit.lua
Libs\MoltenCodes\optionsKit\parts\OptionsKit-Presentation.lua
Libs\MoltenCodes\optionsKit\parts\OptionsKit-Handlers.lua
Libs\MoltenCodes\optionsKit\parts\OptionsKit-Bind.lua
Libs\MoltenCodes\optionsKit\parts\OptionsKit-Profiles.lua
Libs\MoltenCodes\optionsKit\parts\OptionsKit-Dynamic.lua
```

Minimum footprint: embed 5 files: `registry/Registry.lua`, `signalKit/SignalKit.lua`, `schemaKit/SchemaKit.lua`, `schemaKit/parts/SchemaKit-Rules.lua` (OptionsKit's manifest names SchemaKit's Rules part, for input patterns and values functions), `optionsKit/OptionsKit.lua`.

OptionsKit is a core and five optional parts (ADR 0001; revision 16). Embed a part only when the addon uses it; `python3 -m tooling.package.embeds` writes the lines for you. An Ace3 port embeds Presentation and Handlers; the example above, which binds every option, embeds Bind:

| Part | Embed it for | Resident (host Lua 5.1, debug information kept, 2026-11-18) |
|---|---|---:|
| core `OptionsKit.lua` | every tree | 134.1 KB |
| `parts/OptionsKit-Presentation.lua` | `width`, `relWidth`, `descStyle`, icons, images, `dialogControl`, `control`, `itemControl`, `style`, function `name`/`order`/`fontSize`, `sorting` functions, per-interface flags | 30.1 KB |
| `parts/OptionsKit-Handlers.lua` | `handler`, method names, accessors inherited from groups, `plugins` | 8.2 KB |
| `parts/OptionsKit-Bind.lua` | `bind` and `ns:` binds into `options.db` | 10.9 KB |
| `parts/OptionsKit-Profiles.lua` | `OptionsKit:ProfileOptions` | 41.2 KB |
| `parts/OptionsKit-Dynamic.lua` | builder trees, `NotifyChange`, `Replace`, `Remove` | 17.4 KB |

Without a part, its members raise at your line and name the file to add (`OptionsKit:ProfileOptions is in OptionsKit's Profiles part, which is not loaded: add optionsKit\parts\OptionsKit-Profiles.lua to embeds.xml ...`), and `Define` refuses its fields the same way (`OptionsKit:Define tree.args.general.args.scale.width needs OptionsKit's Presentation part: add optionsKit\parts\OptionsKit-Presentation.lua to embeds.xml ...`).

Direct runtime dependencies: Registry API 2, SchemaKit API 1 and SignalKit API 1.
The first five files above are required; omitting any of the first three
makes this package raise at load, and without SchemaKit's Rules part an input
`pattern` or a values function is refused at `Define`.

Optional: SettingsKit API 1, needed only when an option uses `bind` or the tree
holds `ProfileOptions`. OptionsKit looks it up with `Registry:Find` when
`Define` receives `options.db` and when `ProfileOptions` is called, so it may
load in any order before those calls; open the database first, then define the
tree:

```lua
local db = SettingsKit:Open("MyAddonDB", schema)
local options = OptionsKit:Define("MyAddon", tree, { db = db })
```

A tree lives for the session. Nothing needs closing at logout; `OptionsKit:Undefine(addonName)` exists for tests and for an addon that rebuilds its options.
