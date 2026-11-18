# OptionsKit API

OptionsKit API generation **1** provides a typed, validated, introspectable options tree with no renderer: what an addon exposes as configurable, how each option is read and written, and what a dialog or a command line needs to present it.

Implementation revision: **16**. OptionsKit is a core file and five optional parts ([ADR 0001](../../../docs/decisions/0001-kit-core-and-parts.md)): **Presentation** (AceConfig's presentation fields), **Handlers** (handlers, method names, inherited accessors, plugins), **Bind** (`bind` into a SettingsKit database), **Profiles** (`ProfileOptions`) and **Dynamic** (trees that change shape). The field tables below name the part each field needs. See [Parts](#parts).

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
SignalKit.lua
SchemaKit.lua
SchemaKit-Rules.lua                 (SchemaKit's part: input patterns, values functions)
OptionsKit.lua
parts/OptionsKit-Presentation.lua   (optional: widths, icons, images, controls, styles, function names and orders, per-interface flags)
parts/OptionsKit-Handlers.lua       (optional: handler, method names, inherited accessors, plugins)
parts/OptionsKit-Bind.lua           (optional: bind and ns: binds)
parts/OptionsKit-Profiles.lua       (optional: ProfileOptions)
parts/OptionsKit-Dynamic.lua        (optional: builders, NotifyChange, Replace, Remove)
```

A part loads after the core; `python3 -m tooling.package.embeds` writes the lines. An Ace3 port embeds Presentation and Handlers together; a tree bound to a SettingsKit database embeds Bind. OptionsKit's manifest names SchemaKit's Rules part: an `input` with a `pattern` and a `select` or `multiselect` over a values function build SchemaKit nodes only that part provides, and `Define` refuses them without it (`OptionsKit:Define tree.args.name.pattern needs SchemaKit's Rules part: add schemaKit\parts\SchemaKit-Rules.lua to embeds.xml (or rebuild it with python3 -m tooling.package.embeds)`).

Portable WoW code resolves the package through Registry:

```lua
local OptionsKit = MoltenCodes.Registries[2]:Get("optionsKit", 1)
```

OptionsKit does not rely on `require()` at runtime.

### Optional dependencies and host facilities

| Facility | Used by | Without it |
|---|---|---|
| SettingsKit API 1, through `Registry:Find` | `Define` with `options.db`, which every `bind` needs; `ProfileOptions` | `Define` with `options.db` and `ProfileOptions` raise; options with `get`/`set` work as usual. |
| `UnitName("player")`, `GetRealmName()` | `ProfileOptions`, for the per-character profile choice `"<name> - <realm>"` | The choice is left out; the group works otherwise. Read when the group is built, and again by each later call returning it until the client answers both. |
| `issecretvalue` | `Set`, `Validate`, `Describe`'s copy of a value, every path and addon-name argument, the `Define` limit options, and the results of `validate` and `db:Validate` | Nothing is treated as secret, which is correct on clients without secret values. |
| `geterrorhandler()` | The Dynamic part, to report a rebuild it refused (Blizzard's own `Blizzard_SharedXMLBase/ErrorUtil.lua` calls it on every flavour) | The report is dropped; the structure is kept either way. |
| SettingsKit revision 15's `db:GetNamespace` | `bind = "ns:<name>..."` | Such a bind is refused at `Define`. |

`issecretvalue` is read through the shared probe (revision 16, `tooling/shared/lua/isSecret.lua`): the probe present at load is kept, and only when none was present at load is the global read again on each call, so a probe that appears later is still used. Every client defines it before any addon runs.

## Public surface

Package facade:

| Field | Purpose |
|---|---|
| `Define(addonName, tree, options?)` | Check and copy an options tree; return its handle. |
| `Get(addonName)` | The tree defined for `addonName`, or `nil`. |
| `Undefine(addonName)` | Forget the tree and disconnect its listeners. `true` when there was one. |
| `ProfileOptions(db, options?)` | A ready-made `group` over a SettingsKit database's profiles, to place in a tree; one group per database and options, built on the first call (see [Profile options](#profile-options-optionskitprofileoptionsdb-options)). Profiles part. |
| `GetFields(kind)` | Every field `kind` accepts, each mapped to a fresh set of its forms (`string`, `number`, `boolean`, `table`, `function`, `method`, `any`). A fresh table per call, for converters (BridgeKit). Revision 14. Since revision 16 it reports what the loaded parts accept: without Presentation no presentation field and no `function` form of `name`, `order`, `fontSize` or `sorting`; without Handlers no `method` form, no `handler` and no group accessors or `plugins`; without Bind no `bind`. |
| `GetTrees()` | The addon names that have a tree, a fresh sorted array (AceConfigRegistry's `IterateOptionsTables`). Revision 15. It takes no argument and reads no receiver, so it answers the same however it is called. |
| `IsPartLoaded(partName)` | Whether the part `"Presentation"`, `"Handlers"`, `"Bind"` (revision 16), `"Profiles"` or `"Dynamic"` is loaded. Revision 15. |
| `MAX_OPTIONS` | `1024`: the default `maxOptions`, the most options one tree holds. |
| `CHILD_GROUPS` | `{ tab = true, tree = true, select = true }`: the `childGroups` values `Define` accepts. A fresh table each revision: writing to it changes nothing. Revision 10. |
| `MAX_DEPTH` | `8`: the default `maxDepth`, the most keys one option path has. |
| `UNBOUNDED` | Sentinel `maxOptions` and `maxDynamicEntries` accept to lift the bound (see [Limits](#limits)). |
| `Tree` | The shared prototype of tree handles. |

Tree handle:

| Method | Purpose | Allocates |
|---|---|---|
| `Get(path)` | The option's current value. | no |
| `Set(path, value)` | Check, validate, write, fire `OnChange`. `true`, or `false, message` when `validate` refuses. | no, for a valid value |
| `Validate(path, value)` | `true`, or `false, message`, without writing. | only the message of a refusal |
| `Reset(path)` | Restore a bound option's default; return it. | no |
| `Execute(path)` | Run an `execute` option's `func`. | no |
| `IsDisabled(path)`, `IsHidden(path, interface?)` | The effective flag, a group's included; `IsHidden` for `"dialog"` or `"cmd"` when given (revision 14, [Per interface](#per-interface)). | no |
| `GetConfirmation(path, value?)` | The question to ask before `Set(path, value)` or `Execute(path)`, or `nil` (revision 14, [Confirmation](#confirmation)). | the answer of a `confirm` function |
| `Walk(visitor)` | Visit every option in order. Returns the count. | no |
| `Describe(interface?)` | A fresh plain description of the whole tree; `hidden` and `inline` for `interface` when given (revision 14). | yes, by design |
| `DescribeOption(path, interface?)` | A fresh plain description of one option, or of a group and everything below it; `nil` when the tree has no such path. Revision 7. | yes, that option's part |
| `OnChange(callback)` | Connect `callback(tree, path, value)` to every `Set`, `Reset` and, while the tree holds a profile group, its database's profile signals; return a SignalKit connection. | one connection |
| `OnStructureChanged(callback)` | Connect `callback(tree, path)` to every change of the tree's shape (revision 15, [Dynamic trees](#dynamic-trees)); the signal is created on the first connection. A static tree never fires it. | the signal, once; one connection |
| `NotifyChange()`, `Replace(path, option)`, `Remove(path)` | Read the tree's source again at the next read; put one option at a path; remove one. Dynamic part ([Dynamic trees](#dynamic-trees)). | no for `NotifyChange`; the subtree for `Replace` |

The options of a [profile group](#profile-options-optionskitprofileoptionsdb-options) are the exception to the "no" column: their getters, predicates and values functions call `db:GetProfiles()`, which allocates (see [Performance](#performance)).

## `OptionsKit:Define(addonName, tree, options?)`

`addonName` is a non-empty string; one tree per addon name (a second `Define` raises until `Undefine`). `tree` is the root, or (Dynamic part) a builder `fun(addonName): table` that returns it, called now and at every rebuild; a builder's own error propagates, and one that returns no table raises `OptionsKit:Define tree function must return the root group table`. Without the part a function raises `OptionsKit:Define tree is a function, which needs OptionsKit's Dynamic part: add optionsKit\parts\OptionsKit-Dynamic.lua to embeds.xml (or rebuild it with python3 -m tooling.package.embeds)`. The root is a `group` whose `name` is optional and defaults to `addonName`. `options` accepts these fields:

| Option | Meaning |
|---|---|
| `db` | A SettingsKit API 1 database (the `db` `SettingsKit:Open` returns). Required when any option uses `bind`. |
| `maxOptions` | The most options below the root; default `1024`. A positive integer or `OptionsKit.UNBOUNDED`. |
| `maxDepth` | The most keys an option path has; default `8`. An integer from `1` to `32`. |
| `maxDynamicEntries` | The most entries of a `values` table, and the map bound of a `multiselect` over a values function; default `1024`. A positive integer or `OptionsKit.UNBOUNDED`. |

[Limits](#limits) says why `maxDepth` has a ceiling and the other two do not.

`Define` checks the whole tree before it registers anything and raises at the line that called it, naming the field by its path from the root:

```text
MyAddon.lua:40: OptionsKit:Define tree.args.general.args.scale.min must not be greater than max
MyAddon.lua:40: OptionsKit:Define tree.args.general contains unknown field "witdh" for type "group"
```

What it refuses:

- a root that is not a `group`; an option that is not a table or has no known `type`;
- any field its kind does not accept (a misspelling fails at once instead of being ignored);
- a key in `args` that is not an identifier (`[%a_][%w_]*`), so a dotted path is never ambiguous;
- more than `maxOptions` options below the root (groups count), and an option path longer than `maxDepth` keys — which also turns a cyclic tree into an error, whatever the limits;
- a limit option out of range: `OptionsKit:Define options.maxDepth must be an integer from 1 to 32`, `OptionsKit:Define options.maxOptions must be a positive integer or OptionsKit.UNBOUNDED`; a secret limit option, refused before it is compared with `OptionsKit.UNBOUNDED`: `OptionsKit:Define options.maxOptions must not be a secret value` (likewise `maxDepth` and `maxDynamicEntries`);
- a value option with neither `get` and `set` nor `bind`, or with both; a `bind` without `options.db`;
- `options.db` when `Registry:Find("settingsKit", 1)` finds nothing, or when it is not a table with `OnChange` and `Validate` methods; a `bind` whose scope the database did not declare or cannot provide on this client (`OptionsKit:Define tree.args.x.bind scope "realm" is not an available scope of options.db`). The scope is read with `rawget`, so SettingsKit's own error for an undeclared scope never escapes from inside OptionsKit.

The tree is **copied**: labels, values tables, sorting arrays and coordinates are read once, and later edits to the tables you passed have no effect until `tree:NotifyChange()` (Dynamic part), which reads the table again while you still hold it. Functions (`get`, `set`, `validate`, `disabled`, `hidden`, `values`, `func`, and every presentation function) and `arg` are kept by reference.

## A complete options tree

An addon with saved settings in SettingsKit, one option with its own accessors, and every kind of option. The SettingsKit schema declares what is stored; the options tree declares what is configurable and how it is presented. Where the two declare bounds for one value, both are checked: the option's by OptionsKit, the stored field's by SettingsKit.

```lua
local Registry = MoltenCodes.Registries[2]
local SchemaKit = Registry:Get("schemaKit", 1)
local SettingsKit = Registry:Get("settingsKit", 1)
local OptionsKit = Registry:Get("optionsKit", 1)
local S = SchemaKit

local db = SettingsKit:Open("MyAddonDB", {
  profile = S.table({
    fields = {
      enabled = S.optional(S.boolean(), true),
      frame = S.optional(S.table({
        fields = {
          scale = S.optional(S.number({ min = 0.5, max = 2 }), 1),
          anchor = S.optional(S.enum({ "TOP", "CENTER", "BOTTOM" }), "CENTER"),
          color = S.optional(S.table({
            fields = {
              r = S.optional(S.number({ min = 0, max = 1 })),
              g = S.optional(S.number({ min = 0, max = 1 })),
              b = S.optional(S.number({ min = 0, max = 1 })),
            },
          })),
        },
      }), {}),
      channels = S.optional(S.map({ keys = S.string(), values = S.boolean(), max = 8 }), {}),
      label = S.optional(S.string({ max = 24 }), ""),
      toggleKey = S.optional(S.string(), ""),
    },
  }),
  global = S.table({ fields = { debug = S.optional(S.boolean()) } }),
})

local options = OptionsKit:Define("MyAddon", {
  type = "group",
  name = "My Addon",
  args = {
    intro = { type = "description", name = "Settings for My Addon.", fontSize = "medium", order = 0 },
    enabled = { type = "toggle", name = "Enabled", order = 1, bind = "profile.enabled" },
    frame = {
      type = "group",
      name = "Frame",
      order = 2,
      disabled = function(info)
        return not info.tree:Get("enabled")
      end,
      args = {
        layout = { type = "header", name = "Layout", order = 1 },
        scale = {
          type = "range",
          name = "Scale",
          desc = "Size of the main frame.",
          order = 2,
          min = 0.5,
          max = 2,
          step = 0.05,
          bigStep = 0.25,
          isPercent = true,
          bind = "profile.frame.scale",
        },
        anchor = {
          type = "select",
          name = "Anchor",
          order = 3,
          values = { TOP = "Top", CENTER = "Centre", BOTTOM = "Bottom" },
          sorting = { "TOP", "CENTER", "BOTTOM" },
          bind = "profile.frame.anchor",
        },
        color = { type = "color", name = "Border colour", order = 4, bind = "profile.frame.color" },
        resetPosition = {
          type = "execute",
          name = "Reset position",
          order = 5,
          confirm = "Move the frame back to the centre?",
          func = function()
            MyAddon:ResetPosition()
          end,
        },
      },
    },
    chat = {
      type = "group",
      name = "Chat",
      order = 3,
      inline = true,
      args = {
        channels = {
          type = "multiselect",
          name = "Announce in",
          values = function()
            return MyAddon:AvailableChannels() -- { SAY = "Say", PARTY = "Party", ... }
          end,
          bind = "profile.channels",
        },
        label = {
          type = "input",
          name = "Label",
          usage = "<letters, digits and spaces>",
          pattern = "^[%w ]*$",
          bind = "profile.label",
          validate = function(_, value)
            if #value > 24 then
              return false, "at most 24 characters"
            end
            return true
          end,
        },
      },
    },
    toggleKey = { type = "keybinding", name = "Toggle key", order = 4, bind = "profile.toggleKey" },
    debug = {
      type = "toggle",
      name = "Debug output",
      order = 5,
      tristate = true,
      hidden = function()
        return not MyAddon.developerMode
      end,
      bind = "global.debug",
    },
    sessionOnly = {
      type = "toggle",
      name = "Show the frame this session",
      order = 6,
      get = function()
        return MyAddon.frame:IsShown()
      end,
      set = function(_, shown)
        MyAddon.frame:SetShown(shown)
      end,
    },
  },
}, { db = db })

options:OnChange(function(_, path, value)
  MyAddon:ApplySetting(path, value)
end)

options:Set("frame.scale", 1.25)          --> true
options:Set("chat.label", "Raid alerts")   --> true
options:Set("frame.anchor", "LEFT")        -- raises here: expected one of "BOTTOM", "CENTER", "TOP"
options:Validate("frame.scale", 3)         --> false, "expected number <= 2, found larger number"
options:Reset("frame.scale")               --> 1
options:Execute("frame.resetPosition")     -- runs func; asking `confirm` is the renderer's job
```

## Option kinds

### Fields every option accepts

| Field | Type | Meaning | Part |
|---|---|---|---|
| `type` | string | The kind, below. | core |
| `name` | string, or `fun(info): string` | The label. Required, except on the root. A function (revision 14) is called by `Describe` before it sorts; at `Define`, and so in `Walk`, such an option sorts by its key. | core; a function: Presentation |
| `desc` | string, or `fun(info): string` | Longer help text. A function is called by `Describe`, with the option's `info`, and must return a string. | core |
| `order` | number, function or method name | Sort position among siblings; default `100`. Ties sort by `name`, then by key. A function or method (revision 14) is called by `Describe`, which then sorts the described siblings on the plain results, so no code of yours runs inside a sort; at `Define`, and in `Walk`, it sorts as `100`. | core; a function: Presentation; a method name: Handlers and Presentation |
| `disabled` | boolean, function or method name | Shown but not editable. A disabled group disables everything below it. | core; a method name: Handlers |
| `hidden` | boolean, function or method name | Not shown. A hidden group hides everything below it. | core; a method name: Handlers |
| `guiHidden`, `dialogHidden`, `cmdHidden` | boolean, function or method name | `hidden` for one interface, AceConfig's flags; see [Per interface](#per-interface). Revision 14. | Presentation |
| `descStyle` | `"inline"` or `"tooltip"` | Where a renderer shows `desc`. Revision 14. | Presentation |
| `confirm` | boolean, the question as a string, or `fun(info, value): string\|boolean` | Ask before a change; a group's applies below it. See [Confirmation](#confirmation). Every kind since revision 14 (`execute` before). | core |
| `confirmText` | string | The question when `confirm` is `true`. Revision 14. | core |
| `arg` | any value but a secret | Kept by reference, handed to every callback as `info.arg`; never described. Revision 14. | core |
| `handler` | table | The object method names are looked up on; a group's applies below it. See [Method names and inheritance](#method-names-and-inheritance). Revision 14. | Handlers |
| `icon`, `iconCoords` | texture path or file ID, or a function; an array of 4 or 8 numbers, a function or a method name | A tree renderer's icon. Revision 14. | Presentation |
| `tooltipHyperlink` | string, or a function | A hyperlink a renderer's tooltip shows instead of `desc`. Revision 14. | Presentation |
| `width` (all but `group`) | `"normal"`, `"half"`, `"double"`, `"full"`, a positive number (units of 170 px) or a function | How wide a renderer draws the control. Revision 14. | Presentation |
| `relWidth` (all but `group`) | number, `0 < relWidth <= 1` | A share of the row. Revision 14. | Presentation |
| `dialogControl`, `control` (all but `group`) | non-empty string | A widget type name for a renderer to use instead of its default. Revision 14. | Presentation |

Every presentation field is a hint for renderers, kept in the option's hints table: an option that sets none of them holds nothing more than it did in revision 13. `dropdownHidden`, `dropdownInline` and `dropdownControl` are refused: Ace3 has no dropdown interface that reads them.

A predicate's answer is tested for truth only after `issecretvalue` says it is not a secret: a secret answer (Retail 12.x) counts as `false`, so the option stays enabled and shown rather than an error being raised inside OptionsKit. `disabled` and `hidden` are renderer concerns: `Get`, `Set` and `Execute` work on hidden and disabled options exactly as on any other, so an addon can still change a value its UI hides. A renderer, or CommandKit, asks `IsDisabled` / `IsHidden` before offering an option.

### Fields every value option accepts

Value options are `toggle`, `range`, `select`, `multiselect`, `input`, `color` and `keybinding`.

| Field | Type | Meaning | Part |
|---|---|---|---|
| `get` | `fun(info): any`, a method name, or `false` | Returns the current value. With `set`; both may come from a group above ([inheritance](#method-names-and-inheritance)). | core; a method name or a group's: Handlers |
| `set` | `fun(info, value)`, a method name, or `false` | Stores a value that passed the schema and `validate`. With `get`. | core; a method name or a group's: Handlers |
| `bind` | string | `"<scope>.<key>[.<key>...]"` into `options.db`, instead of `get` and `set`. `<scope>` is `global`, `char`, `realm`, `class`, `faction`, `profile`, or (SettingsKit revision 15, revision 14 here) `race`, `factionrealm`, `factionrealmregion` or `locale`; every segment is an identifier. `"ns:<name>.<scope>.<key>..."` binds into the SettingsKit namespace `<name>` of `options.db` ([Namespaces](#namespaces)). | Bind |
| `validate` | `fun(info, value): boolean, string?`, a method name, or `false` | Runs after the schema accepted the value. Anything but `true` refuses, a secret result included (it is never compared); the second result is the message (`"refused by validate"` when there is none). | core; a method name or a group's: Handlers |

### Kinds and their schemas

| Kind | Own fields | Schema built at `Define` |
|---|---|---|
| `group` | `args` (table of key → option, required), `inline` (boolean: draw inside the parent), `childGroups` (`"tab"`, `"tree"` or `"select"`: how a renderer shows the group's non-inline child groups, Ace3's three layouts), `plugins` (`{ [pluginName] = { [key] = option } }`, merged into `args`; a key defined twice is refused), `guiInline`, `dialogInline`, `cmdInline` (booleans, [Per interface](#per-interface)), and `get`, `set`, `validate`, `func` passed down ([inheritance](#method-names-and-inheritance)) | none |
| `toggle` | `tristate` (boolean: `nil` is a third state), `image`, `imageCoords` | `SchemaKit.boolean()`, wrapped in `optional` when `tristate` |
| `range` | `min`, `max` (required numbers, `min <= max`), `step`, `bigStep` (numbers `> 0`), `softMin`, `softMax` (between `min` and `max`, `softMin <= softMax`), `isPercent` (boolean) | `SchemaKit.number{ min = min, max = max }` |
| `select` | `values` (table of key → label, a function or a method name), `sorting` (array of keys: display order; or a function or method name returning one, checked by `Describe`), `style` (`"dropdown"` or `"radio"`), `itemControl` (a widget type name for the items) | table: `SchemaKit.enum` of its keys; function: `SchemaKit.custom` accepting a string or number key of the table the function returns at check time |
| `multiselect` | `values`, `sorting`, as `select`; `tristate` (boolean: a key's absence is a third state, which the map schema already accepts) | `SchemaKit.map{ keys = <the select key schema>, values = SchemaKit.boolean(), max = <number of keys> }`; with a values function `max` is the tree's `maxDynamicEntries` (1024 by default; 2147483647 when unbounded, since the map needs an integer and the function's own table is then the bound) |
| `input` | `pattern` (Lua pattern the text must contain; anchor it with `^`/`$`), `multiline` (boolean, or a positive integer: the line count), `usage` (string: what to type, for a command line) | `SchemaKit.string{ pattern = pattern }`, or `SchemaKit.string()` |
| `color` | `hasAlpha` (boolean) | `SchemaKit.table{ fields = { r, g, b = number 0..1 } }`, plus a required `a` when `hasAlpha`; a closed table, so `a` is refused without `hasAlpha` |
| `keybinding` | none | `SchemaKit.string()`; `""` is "unbound" |
| `execute` | `func` (`fun(info)` or a method name, required, or from a group above), `image` (texture path, file ID or a function, which may also return a width and a height), `imageCoords`, `imageWidth`, `imageHeight` (positive numbers) | none |
| `header` | none | none |
| `description` | `fontSize` (`"small"`, `"medium"`, `"large"` or a function returning one); the image fields, as `execute`; the text is `name` | none |

`values` tables have string or number keys and string labels, at least one entry and at most `maxDynamicEntries` (1024 by default). `sorting` entries must be keys of a `values` table.

Part of the kinds' own fields (revision 16): a group's `plugins` and its `get`, `set`, `validate` and `func` need the Handlers part; `guiInline`, `dialogInline`, `cmdInline`, `image`, `imageCoords`, `imageWidth`, `imageHeight`, `style`, `itemControl`, a function `fontSize` and a `sorting` function need the Presentation part; a `values` or `sorting` method name needs Handlers. Every other field in the table is the core's.

`step`, `bigStep`, `softMin`, `softMax`, `isPercent`, `multiline`, `usage`, `inline`, `childGroups`, `confirm` and `fontSize` are hints for renderers: nothing in OptionsKit enforces them. In particular `step` is not part of the schema: a slider snaps to it, and a value typed on a command line only has to lie between `min` and `max`.

## `info`

Every callback — `get`, `set`, `validate`, `disabled`, `hidden`, a `values` function and `func` — receives the option's `info`:

| Field | Meaning |
|---|---|
| `info[1]` … `info[#info]` | The option's keys from the root: `"general"`, `"scale"`. |
| `info.path` | The dotted path, `"general.scale"`; `""` for the root group. |
| `info.kind` | The option's kind. |
| `info.tree` | The tree handle, so a callback can `Get` a sibling. |
| `info.arg` | The option's own `arg`, when it has one (revision 14). |
| `info.handler` | The handler in force, when there is one (revision 14). |

AceConfig's `info.option`, `info.options`, `info.appName` and `info.uiType` are not provided: OptionsKit keeps no copy of your table and does not know which interface called. BridgeKit's converted callbacks receive them.

**One `info` table per option, built at `Define` and reused for every call.** That is what keeps `Get` and `Set` free of allocation. Do not keep it after the callback returns and do not modify it: the next call for that option receives the very same table. Copy what you need (`local path = info.path`).

## Reading and writing

### `tree:Get(path)`

`path` is the dotted path of a value option (`"general.scale"`). Returns what `get(info)` returns, or the value at the bind path. The value is returned as it is, not checked against the schema — a getter may return anything, including a secret.

### `tree:Set(path, value)`

In this order:

1. `value` must not be a secret (`OptionsKit.Tree:Set value must not be a secret value`, raised at your line);
2. the option's schema is asserted **at your line**: `OptionsKit.Tree:Set general.scale: expected number <= 2, found larger number`;
3. `validate(info, value)` runs; a refusal returns `false, message` and writes nothing;
4. `set(info, value)` runs, or the value is written at the bind path; a refusal by SettingsKit (its schema is narrower, or the profile view is detached) is raised again **at your line** with SettingsKit's message kept: `OptionsKit.Tree:Set frame.x refused by the database: SettingsKit (MyAddonDB) profile.frame.x: expected number <= 3, found larger number`. An error raised by one of the database's own `OnChange` listeners, after SettingsKit stored the value, is not a refusal and propagates unchanged;
5. `OnChange` listeners run with `(tree, path, value)`;
6. `Set` returns `true`.

The two kinds of refusal are deliberately different. A value of the wrong type or out of the schema's bounds is a programming error in the caller — a renderer knows the bounds from `Describe` — so it raises. `validate` expresses a rule the user can break with a well-typed value ("that name is taken"), so its refusal comes back as a message a renderer can show. `Set` does not compare the new value with the old one: setting the same value fires `OnChange` again.

A table value (`multiselect`, `color`) is handed to `set`, or stored at the bind path, as it is, not copied.

### `tree:Validate(path, value)`

Runs steps 1 to 3 without raising for the value and without writing: `true`, or `false` and a message such as `expected number <= 2, found larger number`, `r: expected number <= 1, found larger number`, `secret value`, or `validate`'s own message. Command lines and edit boxes use it to answer the user before calling `Set`.

**For a bound option, `Validate` also asks the database.** After the option's own schema and `validate` accept the value, it calls `db:Validate(scope, keys, value)` with the key array split at `Define` (which SettingsKit checks without allocating) and returns SettingsKit's answer. `Validate` and `Set` therefore agree: when the SettingsKit schema at the bind path is narrower than the option's (a `range` of `0..10` bound to a field declared `0..3`), `Validate` returns `false, "SettingsKit (MyAddonDB) profile.frame.x: expected number <= 3, found larger number"` and `Set` raises the same text after `OptionsKit.Tree:Set frame.x refused by the database: `. The database checks a path through a record that does not exist yet without creating it.

### `tree:Reset(path)`

For a bound option: clears the stored value at the bind path, so SettingsKit's default fallback answers again, fires `OnChange` with the value read back, and returns that value. When a record on the bind path does not exist (below), there is nothing to clear and `Reset` returns `nil`. Neither the schema nor `validate` runs: the default is the database's.

An option with `get`/`set` has no default OptionsKit could know, so `Reset` raises at your line: `OptionsKit.Tree:Reset path "general.label" is not bound to a database and has no default`. Keep defaults in SettingsKit, or reset such options yourself.

### `tree:Execute(path)`

Calls the `execute` option's `func(info)`. `confirm` is a renderer's concern; `Execute` does not ask. Any other kind raises at your line.

### `tree:IsDisabled(path)` and `tree:IsHidden(path)`

The option's own flag or predicate, then each ancestor's, up to the root: `true` as soon as one says so. Predicates run on every call, with their own option's `info`. Any option path is accepted, groups included. An option bound to a database path is also disabled while the database is read-only (see [Bound options](#bound-options)); `IsHidden` is unaffected.

### Bound options

The Bind part (revision 16). A bind path is split once, at `Define`. At every `Get`, `Set` and `Reset` the scope view is read from the database afresh (`rawget(db, "profile")`), so a profile switch is seen at once, and the keys are walked through the views SettingsKit returns, so its default fallback answers for anything the user never changed. The last write goes through SettingsKit's own validated write.

SettingsKit reads a record that has no default and no saved data as `nil`. OptionsKit treats such a gap on the bind path as an unset value rather than an error:

| Call | Record on the path missing |
|---|---|
| `Get`, `Describe` | `nil` (a default declared on the leaf field inside that record is not reachable until the record exists) |
| `Set` | writes the missing records as one nested table holding the value (`frame = { x = 1 }`), which SettingsKit validates like any write; this is the only `Set` that allocates |
| `Reset` | nothing to clear; returns `nil` |

Give the record a default (`S.optional(S.table{...}, {})`) when its leaf defaults should be visible before the first write.

If the walk meets something that is not a table, the call raises at your line: `OptionsKit.Tree:Get bind path "profile.frame.anchor" does not lead to a table`. A scope the database no longer provides raises `OptionsKit.Tree:Get bind scope "profile" is not an available scope of the database`.

**A read-only database disables its bound options.** SettingsKit opens data a newer version of the addon saved read-only (`db:IsReadOnly()`, SettingsKit revision 5 and later). While `db:IsReadOnly()` answers `true`, `IsDisabled` and `Describe` report every bound option as disabled, so a renderer greys it out; options with `get`/`set`, and groups, are unaffected. `Get` and `Describe` still read the value. As for any `disabled` option, `Set` and `Reset` still run and SettingsKit then refuses the write: `Validate` answers `false` with SettingsKit's read-only message and `Set` raises `OptionsKit.Tree:Set scale refused by the database: SettingsKit (MyAddonDB) profile is read-only: ...` at your line. A database without `IsReadOnly` (an older SettingsKit, or a stand-in) or answering with a secret counts as writable.

OptionsKit does not listen to the database for bound values. A value changed by SettingsKit directly fires SettingsKit's `OnChange`, not the tree's, so a renderer that shows bound options listens to `db:OnChange` as well. A profile switch, copy, reset or deletion reaches the tree's `OnChange` only while the tree holds a [profile group](#refresh) over that database; otherwise listen to `db:OnProfileChanged` too.

### Paths

A path is the option's keys joined with dots. Every path is indexed in one map at `Define`, so a lookup is one table read; nothing is split per call. An unknown path raises at your line (`OptionsKit.Tree:Get unknown path "general.size"`), as does a path naming an option without a value (`OptionsKit.Tree:Set path "general" is a group, not a value option`). The root group has no path.

## `tree:Walk(visitor)`

Calls `visitor(path, kind, depth)` for every option below the root, depth-first, a group before its children, siblings sorted by `order`, then `name`, then key. `depth` is `1` for the root's children. Returns the number of options visited. The order is fixed at `Define`, so `Walk` allocates nothing; an error raised by the visitor propagates to the caller of `Walk`.

## `tree:OnChange(callback)`

Connects `callback(tree, path, value)` to every successful `Set` and every `Reset` — and, while the tree holds a profile group, to its database's profile signals ([Refresh](#refresh)) — and returns the SignalKit connection (`connection:Disconnect()`). Dispatch follows SignalKit's rules: listeners run in connection order, and a listener error propagates to the caller of `Set` after the value was written. `Undefine` disconnects every listener.

## `tree:Describe()`

A fresh plain table describing the whole tree, built on every call and safe to edit. Each node:

| Field | Present for | Meaning |
|---|---|---|
| `kind` | every node | The option kind. |
| `key` | every node but the root | The option's key. |
| `path` | every node | The dotted path; `""` for the root. |
| `depth` | every node | `0` for the root. |
| `name`, `order` | every node | As defined; the root's `name` defaults to the addon name, `order` to `100`. |
| `desc` | when defined | A `desc` function's result; `Describe` raises at your line when it returns no string. |
| `disabled`, `hidden` | every node | Effective booleans, evaluated now (`IsDisabled` / `IsHidden`); a bound option is also disabled while its database is read-only. |
| `addonName` | the root | |
| `children` | `group` | Child nodes, sorted as `Walk` visits them. |
| `inline` | `group` | When defined; for `interface`, the first of its flags that is set ([Per interface](#per-interface)). |
| `childGroups` | `group` | When defined. |
| `value` | value kinds | The current value, as `Get` returns it, except that a table is copied: a bound value that SettingsKit returns as a view is copied through `db:Pairs`, defaults included, so the description never holds the getter's table or a view that writes through to the saved variable. A table nested deeper than 8 levels appears as the string `"<depth exceeded>"`, and a table that contains itself as `"<cycle>"`. A secret value is passed through without being copied (see [Secret values](#secret-values)). |
| `schema` | value kinds | `schema:Describe()` of the option's SchemaKit schema. |
| `bind` | bound options | The bind path. |
| `values` | `select`, `multiselect` | A copy of the values table; a values function is called and its result copied. |
| `sorting` | `select`, `multiselect` | A copy, when defined. |
| `tristate` · `min`, `max`, `step`, `bigStep`, `softMin`, `softMax`, `isPercent` · `pattern`, `multiline`, `usage` · `hasAlpha` · `fontSize` | their kinds | As defined; a `fontSize` function resolved. |
| `confirm` | when one is in force | The option's or the nearest group's; `true` for a function. |
| `confirmText`, `descStyle`, `width`, `relWidth`, `dialogControl`, `control`, `itemControl`, `style`, `image`, `imageCoords`, `imageWidth`, `imageHeight`, `icon`, `iconCoords`, `tooltipHyperlink` | when defined | As defined, a function resolved with the option's `info` (a result of the wrong type raises at the caller: `OptionsKit.Tree:Describe width function of "frame.scale" returned no string or number`), a table copied. An `image` function's second and third results become `imageWidth` and `imageHeight`. Revision 14. |

`arg`, `handler`, a group's `get`, `set`, `validate` and `func`, and the per-interface flags never appear in a node. With a function `name` or `order` among siblings, `Describe` sorts their nodes again on the resolved values.

Functions never appear in a description. Everything a renderer does goes back through the tree by `path`.

## `tree:DescribeOption(path)`

The node `Describe` would build for the option at `path`, built alone: the same fields, a `group` with its `children`, and `path` `""` answering exactly what `Describe` answers (the root, with `addonName`). Only the callbacks of that option, or of that group and everything below it, run: its getter, `desc`, values function, and the `disabled` and `hidden` predicates of it and its ancestors. A path the tree does not have answers `nil`; a path that is not a string, or is secret, raises at your line (`OptionsKit.Tree:DescribeOption path must be a string`). A `desc` function that returns no string and a values function that returns no table raise as they do in `Describe`, naming `OptionsKit.Tree:DescribeOption`. Added in revision 7 (version 0.3.0) for a command line that works on one option and for a renderer that refreshes one widget; a caller that must also work with an older OptionsKit tests `type(tree.DescribeOption) == "function"` and falls back to `Describe`, as CommandKit's `BindOptions` does.

### Per interface

The per-interface flags are the Presentation part's (revision 16); the `interface` argument is the core's, so a renderer may always pass it: without the part no tree can carry such a flag, and the answer is the plain `hidden` and `inline`. AceConfig lets an option hide from one interface only. `tree:IsHidden(path, interface)`, `tree:Describe(interface)` and `tree:DescribeOption(path, interface)` take `"dialog"` (WidgetKit, PanelKit) or `"cmd"` (CommandKit). For each option on the way to the root, the first of the interface's own flags that is set replaces `hidden`: `dialogHidden`, then `guiHidden`, for `"dialog"`; `cmdHidden` for `"cmd"`. A group's `inline` for the interface is likewise the first set of `dialogInline`, `guiInline`, `inline`, or of `cmdInline`, `inline`. Without an interface every answer is the one of revision 13. Any other value raises `OptionsKit.Tree:IsHidden interface must be "dialog" or "cmd"`.

### Confirmation

`tree:GetConfirmation(path, value?)` answers the question a renderer asks before `Set(path, value)` or `Execute(path)`, or `nil` for none: the option's `confirm`, else the nearest group's. A string is the question; `true` gives `confirmText`, else the resolved `name` followed by `" - "` and the resolved `desc` when there is one (AceConfigDialog's question); a function is called with `(info, value)`, and a string it returns is the question, `true` gives the question above, anything else asks nothing (a secret that is not a string included). `Set` and `Execute` never ask. A `confirm` string is the question, not a method name, as it has been since revision 1; write a function to ask a method.

### How a renderer consumes `Describe`

This is the contract WidgetKit's `RenderOptions` and CommandKit's `BindOptions` build on.

1. **Build** the screen from `tree:Describe()`: one widget per node, chosen by `kind`; a `group` becomes a page, a tab or — with `inline` — a box inside its parent; children are already in display order. Skip nodes whose `hidden` is `true`; grey out nodes whose `disabled` is `true`.
2. **Configure** each widget from the node's hints: a slider from `min`/`max`/`step`/`softMin`/`softMax`/`isPercent`; a dropdown over `values` in `sorting` order (or sorted by label when there is none); an edit box that is multi-line for `multiline`; a colour swatch with an alpha slider for `hasAlpha`; a confirmation dialog before `Execute` for `confirm`. `schema` carries the same bounds in SchemaKit's vocabulary for a generic widget.
3. **Write** through `tree:Set(node.path, value)`. For typed text, call `tree:Validate(node.path, value)` first and show its message; call `Set` only when it returns `true`, and show the message `Set` returns when `validate` refuses. Run buttons with `tree:Execute(node.path)`.
4. **Refresh** by connecting `tree:OnChange` (and, for bound options, the database's `OnChange`, and `OnProfileChanged` unless the tree holds a profile group), then calling `Describe` again — or, for one widget, `tree:DescribeOption(path)`, or `tree:Get(path)`, `tree:IsDisabled(path)` and `tree:IsHidden(path)`, which allocate nothing. Coalesce a burst of changes into one rebuild; `Describe` allocates the whole description each time.

A command line needs no widgets: `Walk` lists the paths, `DescribeOption` gives the typed path's help (`name`, `desc`, `usage`, `values`), `Validate` answers a typed value and `Set` stores it.

## Method names and inheritance

The Handlers part (revision 16; revision 14 in the core). After [ADR 0003](../../../docs/decisions/0003-method-name-callbacks.md). In `get`, `set`, `validate`, `func`, `disabled`, `hidden`, the three per-interface flags, `values`, `sorting`, `order`, `iconCoords` and `imageCoords`, a string names a method of the **handler in force**: the option's own `handler`, else the nearest group's. Elsewhere a string is the value (`name`, `desc`, `usage`, `width`, `image`, `icon`, `fontSize`, `tooltipHyperlink`, as in AceConfig, and `confirm`).

- At `Define` the handler in force must have the method, or the field is refused at your line: `OptionsKit:Define tree.args.x.get names method "GetX", which the handler in force does not have`, and without a handler `... is a method name ("GetX"), but no handler is in force`.
- The method is looked up on every call, so replacing it on the handler takes effect at once, and is called with the handler first: `method(handler, info, ...)`, where `method` is `handler[name]`. A method removed after `Define` raises `OptionsKit (MyAddon) general.scale: handler method "GetX" is missing` when called.
- The lookup is a small function made at `Define`, one per handler and name in a `Define`, stored where a function would be: `Get`, `Set` and the predicates take the same path for both.

**Inheritance**, resolved at `Define`: `get`, `set`, `validate` and `func` written on a group apply to every option below it that has none of its own (an own `bind` counts as its own accessor); the nearest group wins, and `false` stops the search. `handler` is found the same way. `confirm` is inherited too, but read when asked (`Describe`, `GetConfirmation`), so a group's `confirm` adds nothing to its children. `disabled` and `hidden` keep their own rule: every group above applies.

## Namespaces

The Bind part (revision 16; revision 14 in the core), for SettingsKit revision 15's namespaces: `bind = "ns:Bars.profile.size"` binds into the namespace `Bars` of `options.db`. At `Define` the namespace is asked once (`db:GetNamespace(name, { missingOk = true })`) and its scope checked; every later call reads and writes through that child database, reading its scope table per call, so a profile switch the parent passes on is seen at once, and the read-only rule is the child's. `<name>` is an identifier; a namespace with any other name is bound by passing its child database as `options.db`. Refused at your line: a database without namespaces (`... needs options.db with namespaces (SettingsKit revision 15 or later)`, also when SettingsKit's Namespaces part is not loaded), a namespace not registered (`... namespace "Bars" is not registered in options.db`), and a scope the namespace does not provide. A namespace registered after `Define` is reached by defining again, or by `NotifyChange`.

## Dynamic trees

The Dynamic part (revision 15) lets a tree change shape after `Define`, as AceConfig addons build theirs.

- **`tree:NotifyChange()`** only marks the tree dirty. The next method that reads the structure (`Get`, `Set`, `Validate`, `Reset`, `Execute`, `IsDisabled`, `IsHidden`, `Walk`, `Describe`, `DescribeOption`, `GetConfirmation`, `Replace`, `Remove`) reads the source again once: the builder, or the table passed to `Define`. It is checked in full as `Define` checks it, under the limits and the database `Define` received, and swapped in: the same handle, the same `OnChange` and structure listeners, the same `info` table for every path that survives with the same kind, `arg` and handler, and profile groups kept attached, attached or detached as they appear. Calls before that read coalesce into one rebuild. The table passed to `Define` is held weakly: while you hold it, `NotifyChange` reads it again; once you dropped it, or for a tree defined before revision 15, `NotifyChange` raises `OptionsKit.Tree:NotifyChange has no source to read again: keep the table passed to Define, or define the tree with a builder`.
- **A refused rebuild** (the builder raises, returns no table, or the checks refuse a field) does not raise in the method that triggered it: the previous structure is kept, and one report goes to `geterrorhandler()`: `OptionsKit (MyAddon) NotifyChange: OptionsKit.Tree:NotifyChange tree.args.x.min must not be greater than max`, or the builder's own message with its position. The method then answers from the kept structure. A builder may read the tree (the structure before the rebuild) and call `NotifyChange` again, which leaves the tree dirty for one more rebuild.
- **`tree:Replace(path, option)`** checks one option and its subtree at `path` and puts it there, replacing the option there or adding one under the group the path's parent names; **`tree:Remove(path)`** removes one and returns `true`, or `false` when the tree has no such path. Only the subtree is checked, against the tree's limits, with the accessors and handler of the groups above it; a refusal (`OptionsKit.Tree:Replace option.args.r.min must not be greater than max`) changes nothing. The root cannot be replaced or removed. A later `NotifyChange` reads the source again, which wins over earlier `Replace` and `Remove` calls.
- **`tree:OnStructureChanged(callback)`** (core) runs `callback(tree, path)` after a `Replace` or `Remove` (`path` the option's) and when `NotifyChange` makes a clean tree dirty (`path` `""`, before the rebuild, which the listener's own read triggers).

**What a renderer does** (WidgetKit's `RenderOptions`, PanelKit, CommandKit):

1. Connect `tree:OnStructureChanged` once per rendering or binding, and disconnect it when the rendering is released. A static tree never fires it.
2. In the listener, only schedule: rebuild at most once per frame (SchedulerKit's next frame when it is registered, else at the next show). Calling `Describe` inside the listener rebuilds the tree once per `NotifyChange` of a burst.
3. On the scheduled rebuild, describe `path` again (`DescribeOption`, or `Describe` for `""`) and rebuild that part of the screen; `nil` from `DescribeOption` means the option is gone. Keep the selected page or tab by path and fall back to the first child when that path is gone.
4. Hold no path across a structure change without describing again: `Get` and `Set` on a removed path raise as for any unknown path.
5. CommandKit gathers its paths with `Walk` again on the signal; PanelKit refreshes a shown page and needs nothing for a hidden one, which looks the tree up when shown.

## Parts

| Part | File | What it adds | Without it |
|---|---|---|---|
| Presentation | `parts/OptionsKit-Presentation.lua` | `width`, `relWidth`, `descStyle`, `icon`, `iconCoords`, `image`, `imageCoords`, `imageWidth`, `imageHeight`, `tooltipHyperlink`, `dialogControl`, `control`, `itemControl`, `style`; `name`, `order` and `fontSize` as functions and `sorting` functions, resolved by `Describe`; `guiHidden`, `dialogHidden`, `cmdHidden`, `guiInline`, `dialogInline`, `cmdInline` | `Define` refuses each at your line: `OptionsKit:Define tree.args.general.args.scale.width needs OptionsKit's Presentation part: add optionsKit\parts\OptionsKit-Presentation.lua to embeds.xml (or rebuild it with python3 -m tooling.package.embeds)`; a function: `OptionsKit:Define tree.args.x.name is a function, which needs OptionsKit's Presentation part: ...` |
| Handlers | `parts/OptionsKit-Handlers.lua` | `handler`, method names in every field that takes one, a group's `get`, `set`, `validate` and `func` inherited below it, and `plugins` | The same form: `... .handler needs OptionsKit's Handlers part: ...`; a method name: `... .get is a method name ("GetX"), which needs OptionsKit's Handlers part: ...` |
| Bind | `parts/OptionsKit-Bind.lua` | `bind` and `ns:` binds through `options.db` | `... .bind needs OptionsKit's Bind part: ...` |
| Profiles | `parts/OptionsKit-Profiles.lua` | `OptionsKit:ProfileOptions` and, since part revision 2, the links that connect its group to a tree | `OptionsKit:ProfileOptions is in OptionsKit's Profiles part, which is not loaded: add optionsKit\parts\OptionsKit-Profiles.lua to embeds.xml (or rebuild it with python3 -m tooling.package.embeds)`, at your line. A `ProfileOptions` an older single-file revision installed is kept instead. |
| Dynamic | `parts/OptionsKit-Dynamic.lua` | `tree:NotifyChange`, `Replace`, `Remove`; `Define` with a builder | The same form, naming the member and the Dynamic part. |

The core keeps what every tree needs: `Define` of a static tree with the core fields, schemas, `Get`, `Set`, `Validate`, `Reset`, `Execute`, the predicates, `Walk`, `Describe` and `DescribeOption` (with the `interface` argument), `GetConfirmation`, `OnChange`, `OnStructureChanged`, `GetFields`, `GetTrees`, `IsPartLoaded`, the profile-group map, and the detach of a group's link. A part loads after its core; without the core it raises `MoltenCodes OptionsKit part Dynamic requires OptionsKit API 1 to be loaded first` (each part names itself), and Presentation, Handlers and Bind over a core older than revision 16 raise `MoltenCodes OptionsKit part Presentation requires OptionsKit revision 16 or later to be loaded first`. A part keeps its record in the core's state; the highest part revision serves every addon, and a newer core hands each loaded part its helpers again, so the part extends the newer core's field tables and hooks.

Everything Presentation, Handlers and Bind do is decided at `Define` or reached only through an option that uses them: `Get`, `Set`, `IsHidden(path)` and `IsHidden(path, interface)` allocate nothing and take the same function paths with or without the parts.

## Profile options: `OptionsKit:ProfileOptions(db, options?)`

In the Profiles part since revision 15; its behaviour and errors are unchanged.

The group AceDBOptions gives an AceDB database, over a SettingsKit database: the user sees and chooses the profile this character uses, creates one by name, copies another profile's settings into the current one, resets the current one and deletes one. It is built from the existing kinds only, so WidgetKit, CommandKit and any other renderer show it without knowing what a profile is. `db` is the database `SettingsKit:Open` returned.

```lua
local options = OptionsKit:Define("MyAddon", {
  type = "group",
  args = {
    general = { ... },
    profiles = OptionsKit:ProfileOptions(db, { order = 90 }),
  },
})
```

The returned table is a `group` to place in a tree's `args` (or to pass as the root) **as it is**: `Define` recognises the table itself, so a copy of it would be an ordinary group whose callbacks still work but whose database connections (below) are never made. A group belongs to one tree at a time; `Define` refuses it while another defined tree holds it (`OptionsKit:Define tree.args.profiles is a profile group already defined in the tree of "MyAddon"; Undefine it first`) and refuses it twice in one tree. `Undefine` frees it.

**One group per database and options** (revision 8, as AceDBOptions keeps one per database). The first call for a database builds the group; every later call with the same database and the same options returns **that same table**. Options are compared by value (`name`, `order`, `description`) and `localize` by identity, an absent option and an absent options table counting alike: `ProfileOptions(db)` and `ProfileOptions(db, {})` share a group, while a different `name`, `order`, `description` or `localize` function builds a group of its own, which replaces the cached one (revision 9: one cached group per database, so a `localize` closure made fresh for each call cannot grow the cache). A group that was replaced keeps working wherever you hold it; calls alternating two option sets build a new group each time, so pass the same options, or keep the group you were given. So:

- **`localize` runs once per database and options** for the fixed strings, when the group is built; a later call with the same function does not call it again, and a call with another function gets its own group translated by that function. The live descriptions and the messages of `new` still call it each time, as below.
- **The copy and delete choices are shared** by every caller the group is returned to: they belong to the one group. `Undefine` forgets them, so the next tree that receives the group starts with no choice, as a freshly built group did.
- **Two trees**: the group is still one table, so the rule above holds: while one defined tree holds it, placing it in a second tree is refused at `Define` with the message above; after `Undefine`, the second tree receives it, and only that tree is notified. Two groups in two trees at once need two different option sets (for example two `name`s), or two databases.
- **Treat the group as read-only.** A change you make to the returned table (its `order`, an added option) is seen by every later caller. Pass `options.order` or `options.name` instead.
- Every check runs on every call, before the cache is asked: SettingsKit must be loaded, `db` must offer the profile methods and the options are checked (secret refusals included), so a call answered from the cache refuses exactly what a first call refuses. A database that already has a group was checked when the group was built, and its methods come from SettingsKit's prototype, so its method probes are skipped (revision 13). A call answered from the cache allocates nothing.

The cache holds one group per database for the session: SettingsKit keeps every database it opened for the session too. A replaced group nobody holds any more is released with its link. A group an older revision built before an in-place upgrade is not in the cache; it keeps working, and the first call afterwards builds the group later calls return.

### The group

| Key | Kind | What it does |
|---|---|---|
| `intro` | `description`, `fontSize = "medium"` | Explains profiles. `options.description` replaces the text. |
| `current` | `select` | The profile this character uses: `db:GetProfile()`. The choices are `db:GetProfiles()` — which always includes the current profile, so a fresh database shows the default it was opened with, whatever `defaultProfile` said — plus this character's own profile, `"<name> - <realm>"`, when the client knows the player. No constant `"Default"` is offered: a database opened with another default never asked for it. `Set` calls `db:SetProfile(name)`, which creates a missing profile empty. |
| `new` | `input`, `usage = "<profile name>"` | Reads `""`. `Validate` and `Set` apply SettingsKit's rules for a name — a character other than whitespace, at most `SettingsKit:GetLimits().maxProfileNameLength` bytes — and answer with a message rather than raising. `Set` calls `db:SetProfile(name)`: the profile is created and switched to; the name of an existing profile switches to it. |
| `copySource` | `select` | Every profile but the current one. Remembers the choice for `copy`; reads `nil` until chosen, and again while the choice no longer qualifies (deleted elsewhere, or now current). |
| `copy` | `execute`, `confirm` | `db:CopyProfile(copySource)`: replaces the current profile's settings. Disabled until `copySource` names a profile that exists and is not current. |
| `reset` | `execute`, `confirm` | `db:ResetProfile()`: every setting of the current profile reads its default again. |
| `deleteTarget` | `select` | Every profile but the current one. Remembers the choice for `delete`, with the same `nil` rule. |
| `delete` | `execute`, `confirm` | Forgets the choice, then `db:DeleteProfile(deleteTarget)`, so a target chosen while the deletion is announced is kept. Disabled until `deleteTarget` names a profile that exists and is not current. |
| `specs` | `description` | Revision 11, [spec profiles](#spec-profiles): explains the selects below. Hidden while the character has fewer than two spec indexes. |
| `spec1` to `spec8` | `select` | Revision 11: the profile assigned to spec index 1 to 8. Each is hidden unless the character has at least that many indexes and more than one. |

**A read-only database** (SettingsKit opens data a newer version of the addon saved read-only; `db:IsReadOnly()`, SettingsKit revision 5 and later) disables every option of the group but `intro`: `current`, `new`, `copySource`, `copy`, `reset`, `deleteTarget` and `delete` answer `disabled` with `true` while `db:IsReadOnly()` does, and are enabled again as the rules above say otherwise. The group still reads: `current` shows the profile in use and the selects list the profiles. As for any `disabled` option, `Set` and `Execute` still run, and SettingsKit then refuses the change at the caller with its read-only message. A database without `IsReadOnly` (an older SettingsKit) counts as writable.

The `select` options take their choices from a values function, so `Describe` and every check see the profiles as they are now; the group's `desc` and those of `current`, `copySource`, `copy`, `reset` and `deleteTarget` are `desc` functions that name the current profile (`Return every setting of "Raid" to its default.`). Both are read when `Describe` runs: a renderer that redraws from `Describe` shows the current names, one that caches its last description shows them as of that call.

The three buttons carry `confirm` questions; whether the user is asked is the renderer's concern, as for any `execute`. `Execute` of `copy` or `delete` while its select is unset raises at your line (`OptionsKit.Tree:Execute profiles.copy needs "profiles.copySource" to be set first`); a renderer that honours `disabled` never gets there. A refusal by SettingsKit while switching (or an error raised by one of the database's own profile listeners) propagates from `Set` unchanged.

### Spec profiles

Revision 11, LibDualSpec-1.0's `EnhanceOptions` counterpart. When the database and the SettingsKit facade offer SettingsKit's spec-profile methods (`db:SetSpecProfile`, `db:GetSpecProfile` and `SettingsKit:GetSpecIndex`, SettingsKit revision 11), the group carries one `select` per spec index, `spec1` to `spec8`, after the profile options (orders 10 to 17), and the `specs` description before them (order 9). With an older SettingsKit the group is built without them; once an in-place upgrade of SettingsKit adds the methods, the next `ProfileOptions` call for the database builds a new group with them and caches it (revision 12), and the older group keeps working wherever it is held.

They reach SettingsKit only through those three methods: each select's `hidden` predicate asks `SettingsKit:GetSpecIndex()` for the character's count (a select is shown when the count is at least 2 and at least its index), its `get` answers `db:GetSpecProfile(index)` or `""`, and its `set` calls `db:SetSpecProfile(index, name)`, or `db:SetSpecProfile(index, nil)` for `""`. The choices are those of `current` (every profile and this character's own), the profile already assigned to the index, and `""`, labelled `None`: no assignment, so the character keeps whatever profile is in use. `""` can never be a profile name, since SettingsKit refuses one without a character other than whitespace. Every select is `disabled` while the database is read-only, as the other changing options are.

Assigning a profile to the current index switches to it at once (SettingsKit does), so the tree's `OnChange` fires twice: `profiles.current` from the database's signal, then `profiles.spec<n>` from the `Set`. Switching by a later specialization change is SettingsKit's, with EventKit embedded; see SettingsKit's API, *Spec profiles*.

The labels are fixed when the group is built: `Profile for <name>`, where the name is the specialization's on Retail and Mists of Pandaria Classic, from `GetSpecializationInfoForClassID` with the class ID `UnitClass("player")` answers third (class specialization names need no player data), and the `spec.talentGroup` label (`talent group 2`) elsewhere. A specialization the client does not name, or names with a secret or an empty string, gets the `spec.specialization` label (`specialization 2`).

### Refresh

While a defined tree holds the group, it is connected to the database's `OnProfileChanged`, `OnProfileCopied`, `OnProfileReset` and `OnProfileDeleted` signals. Each fires the tree's `OnChange` with the `current` option's path and the current profile's name — `("profiles.current", "Raid")` — so a renderer connected to `tree:OnChange` redraws after a switch made anywhere, by the group's own buttons or by the addon. A switch through `current` fires `OnChange` once, for that `Set`, even when a listener of that switch switches again through `current` (each `Set` then fires once, the inner one first). Creating through `new` fires twice: `("profiles.current", name)` from the database's signal, because the current profile changed, then `("profiles.new", name)` from the `Set`. `db:ResetDatabase()` fires `profiles.current` once when the database was already on its default profile (`OnProfileReset`) and twice otherwise (`OnProfileReset`, then `OnProfileChanged` for the switch back).

The connections are made at the end of `Define`, after the whole tree was checked, and disconnected at `Undefine`. A `Define` that raises leaves every group free: a connect that fails (a table that passed the structural check but is no SettingsKit database) undoes the connections made before it, and the groups attached earlier in the same tree are detached, before the error reaches your line. The connections live with the tree, which lives for the session, so nothing needs closing at logout.

### Options

| Option | Meaning |
|---|---|
| `name` | The group's label; default the `group.name` string, "Profiles". |
| `order` | The group's `order` among its siblings; default `100`. |
| `description` | The text of the `intro` option; default the `intro` string. |
| `localize` | `fun(key, default): string?`, called for every user-visible string with its key and English text. A string result is used; anything else keeps the default. Called when the group is built (the first `ProfileOptions` call for the database and these options) for fixed strings, at every `Describe` for the live descriptions, and at every `Validate` and `Set` of `new` for its messages. |

Unknown fields and wrong types are refused at your line: `OptionsKit:ProfileOptions options contains unknown field "colour"`, `OptionsKit:ProfileOptions options.localize must be a function`.

### Strings and their keys

`%s` is replaced by the current profile's name in quotes, except in `new.long`, where it is the byte limit, and in the `spec` keys, as their rows say.

| Key | English default |
|---|---|
| `group.name` | `Profiles` |
| `group.desc` | `This character uses the profile %s.` |
| `intro` | `Profiles keep separate sets of settings. Choose the one this character uses, create a new one, copy another profile's settings into it, reset it, or delete one you no longer need.` |
| `current.name` | `Current profile` |
| `current.desc` | `The profile this character uses, now %s. Choosing a name that has no profile yet creates an empty one.` |
| `new.name` | `New profile` |
| `new.desc` | `Type a name to create an empty profile and switch to it. The name of an existing profile switches to that profile.` |
| `new.usage` | `<profile name>` |
| `new.blank` | `a profile name needs a character other than whitespace` |
| `new.long` | `a profile name has at most %s bytes` |
| `copySource.name` | `Copy from` |
| `copySource.desc` | `The profile whose settings replace those of %s when you copy.` |
| `copy.name` | `Copy` |
| `copy.desc` | `Replace every setting of %s with a copy of the profile chosen above.` |
| `copy.confirm` | `Replace the current profile's settings with a copy of the chosen profile?` |
| `reset.name` | `Reset profile` |
| `reset.desc` | `Return every setting of %s to its default.` |
| `reset.confirm` | `Reset the current profile to its defaults?` |
| `deleteTarget.name` | `Delete` |
| `deleteTarget.desc` | `A profile other than %s, to delete.` |
| `delete.name` | `Delete profile` |
| `delete.desc` | `Delete the profile chosen above. Characters that used it start on the default profile next time.` |
| `delete.confirm` | `Delete the chosen profile? Its settings cannot be recovered.` |
| `specs.intro` | `Choose a profile for each specialization. This character switches to it by itself when the specialization changes; None keeps the profile in use.` |
| `spec.name` | `Profile for %s` (`%s` is the specialization's label) |
| `spec.desc` | `The profile this character switches to in %s.` (`%s` is the specialization's label) |
| `spec.none` | `None` |
| `spec.specialization` | `specialization %s` (`%s` is the index) |
| `spec.talentGroup` | `talent group %s` (`%s` is the index) |

### Errors

A secret option is refused first (`OptionsKit:ProfileOptions options.name must not be a secret value`). `ProfileOptions` raises at your line when `Registry:Find("settingsKit", 1)` finds nothing (`OptionsKit:ProfileOptions needs SettingsKit API 1 to be loaded`) and when `db` is not a table offering the profile methods of a SettingsKit database (`OptionsKit:ProfileOptions db must be a SettingsKit database`); SettingsKit publishes no predicate for its databases, so the check is structural, as for `options.db`.

## Secret values

On Retail 12.x some client APIs hand addon code secret values (see [`docs/EMBEDDING.md`](../../../docs/EMBEDDING.md#secret-values-retail-12x)). `Set` refuses a secret value at your line before anything compares it, and `Validate` reports it as `false, "secret value"`. A secret path or addon name is refused before it is used as a table key. `Get` and `Describe` return what a getter returns, secret or not, without inspecting it: `Describe` asks `issecretvalue` before it copies a table value, and passes a secret, at the top or nested inside the table, through without being copied. A secret nested in a table value (a `color` field) is refused by the schema with SchemaKit's `secret` rule. A secret `maxOptions`, `maxDepth` or `maxDynamicEntries` is refused at your line before it is compared with `OptionsKit.UNBOUNDED`, and a secret returned by `validate` or by the database's `Validate` counts as a refusal without being compared with `true`. Every field of an option table, and the `name`, `order`, `description` and `localize` options of `ProfileOptions`, is asked about before OptionsKit tests or compares it: a secret one, a secret `true` for `disabled`, `tristate` or `hasAlpha` included, is refused at your line (`OptionsKit:Define tree.args.general.disabled must not be a secret value`, `OptionsKit:ProfileOptions options.name must not be a secret value`), because testing a secret for truth raises (measured on Retail 12.1.0 b69933). A secret answer from a `disabled` or `hidden` predicate counts as `false`, and a secret string from a `desc` function is passed through `Describe` as the description, like a getter's secret value. Whether a field of your tree, your options or a value read from the database is absent is asked with `type`, never by comparing it with `nil`, so an absent-or-present test never touches a secret.

## Limits

Every tree is bounded by default, and each bound is an option of the `Define` call that creates the tree. OptionsKit has no package-wide limit, so it has no `SetLimits`. A limit reached makes `Define` raise at the caller's line; a multiselect over a values function refuses a larger map through its schema.

| Limit | Default | How to open | `UNBOUNDED` allowed? | Ceiling and reason |
|---|---|---|---|---|
| Options per tree, groups included, root excluded | `1024` (`OptionsKit.MAX_OPTIONS`) | `Define(name, tree, { maxOptions = n })` | yes | none: the tree is your own data, though every renderer walks and describes it in full |
| Keys per option path | `8` (`OptionsKit.MAX_DEPTH`) | `Define(name, tree, { maxDepth = n })` | no | `32`: `Define` builds and `Describe` describes the tree by recursion on the Lua stack; the bound also turns a cyclic tree into an error |
| Entries of a `values` table; keys of a `multiselect` over a values function | `1024` | `Define(name, tree, { maxDynamicEntries = n })` | yes | none: the values are your own data |
| Nesting `Describe` copies of a table value | `8` | not configurable | no | the copy recurses on the Lua stack; a deeper table is shown as `"<depth exceeded>"` |

```lua
OptionsKit:Define("MyAddon", tree, {
  db = db,
  maxOptions = OptionsKit.UNBOUNDED,
  maxDepth = 12,
})
```

`OptionsKit.UNBOUNDED` is one table kept in the package state, so every embedded copy and every revision publishes the same sentinel; asking for it as `maxDepth` raises `OptionsKit:Define options.maxDepth cannot be OptionsKit.UNBOUNDED: the tree is built on the Lua stack, so the ceiling is 32`. A tree keeps the limits it was defined under across an in-place upgrade.

Opening `maxDynamicEntries` past `1024` is honoured by OptionsKit, but a renderer has its own bound on what it shows: WidgetKit's dropdown holds 1024 entries by default, so open `WidgetKit:SetLimits{ maxDropdownEntries }` to the same value (or `WidgetKit.UNBOUNDED`) when WidgetKit renders the tree.

## Error behaviour

Every argument failure, schema refusal and bind-path failure reports the line that called OptionsKit, never a line inside it, and names the method and the offending path or field. Calling a tree method on something that is not a tree raises `OptionsKit.Tree:Get must be called on an OptionsKit tree`; on a tree that was undefined, `OptionsKit.Tree:Get cannot be called on an undefined tree`. Errors raised by your own callbacks (`get`, `set`, `validate`, predicates, `func`, a `Walk` visitor, an `OnChange` listener) propagate unchanged. A field of a part that is not loaded is refused by `Define` at your line, naming the part's file ([Parts](#parts)); an input `pattern` or a values function without SchemaKit's Rules part is refused the same way, naming SchemaKit's file ([Loading](#loading)).

## Performance

| Operation | Cost |
|---|---|
| `Define` | Proportional to the tree; allocates the records, the index and the sorted arrays, and one checked copy per `values` table (options naming the same table share it). Schemas are shared: options of one kind with the same inputs (`tristate`; `min` and `max`; `pattern`; `hasAlpha`; the keys of a `values` table) share one sealed schema for the session, so only inputs not seen before build one; a `select` or `multiselect` over a values function has its own. An option's `info` is built the first time a callback of it runs, then kept. Each option's record keeps to 8 fields (revision 13) and an error label is built only for a refusal: on host Lua 5.1 (2026-11-15) about 580 bytes allocated and 590 held per option with a name, description, getter and setter (revision 12: 1 200 and 806), and 50 options defined in about 0.78 of AceConfigRegistry-3.0's time. |
| `Get`, `Set` of a valid value | One map read, one secret probe, the schema check and your callbacks; no allocation by OptionsKit. A bound option adds one table read per path key and one protected call around the write; a `Set` that must create a missing record allocates that nested table. |
| `Walk` | One pass over a pre-sorted array; no allocation. |
| `IsDisabled`, `IsHidden` | One check per ancestor; no allocation. |
| `Describe` | Allocates the whole description; a `desc` function runs per node that has one. |
| `DescribeOption` | As `Describe`, for that option or group only. |
| `ProfileOptions` | The first call for a database and options builds the group (about 4.5 µs and 6 KB on host Lua 5.1, revision 7's cost of every call). A later call runs the checks, then one cache lookup: no allocation, about 0.5 µs on host Lua 5.1 (2026-11-15, revision 13 with SettingsKit revision 14; AceDBOptions about 0.26 µs; revision 12: 1.6 µs), most of it `Registry:Find` and the checks of the options. |
| The profile group's callbacks | Allocate: they call `db:GetProfiles()`. An options screen, not a hot path. |

Resident memory (host Lua 5.1.5, 64-bit, debug information kept, each file loaded after its dependencies, after a full collection, measured 2026-11-18): the core 134.1 KB (revision 15: 158.7 KB); Presentation 30.1 KB, Handlers 8.2 KB, Bind 10.9 KB, Profiles 41.2 KB (part revision 1: 36.4 KB), Dynamic 17.4 KB. A tree with `get`/`set` only embeds the core; an Ace3 port adds Presentation and Handlers; a tree bound to SettingsKit adds Bind. Per option nothing changed.

## Deviations from the planned contract

The nine-point plan in `docs/ROADMAP.md` is followed except where recorded here:

- **`color { hasAlpha }`** rather than `color { alpha }`: the AceConfig name, which addon authors already know.
- **`Set` returns `false, message` when `validate` refuses** instead of raising. A schema refusal is a caller's mistake and raises at the caller's line as planned; a `validate` refusal is a message for the user, and a renderer should not need `pcall` to show it.
- **`Reset` clears the stored value** instead of writing a default read from the SettingsKit schema. The SettingsKit database surface does not expose its schema, and a cleared value is exactly what SettingsKit's default fallback answers for — without ever writing the default into the saved variables. `Reset` on an option with `get`/`set` raises, since no default exists for OptionsKit to restore.
- **`options.db` is checked structurally**: `Registry:Find("settingsKit", 1)` must find SettingsKit, and the database must be a table with `OnChange` and `Validate` methods whose bound scopes are tables. SettingsKit API 1 publishes no predicate that recognises its databases.
- **Additions:** `tree:Validate`, `tree:Execute`, `tree:IsDisabled`, `tree:IsHidden` and `tree:DescribeOption` (revision 7) — a renderer and a command line need to check typed input, run a button, re-evaluate predicates and describe one option without rebuilding the whole description — and `OptionsKit:Undefine`, `OptionsKit.MAX_OPTIONS`, `OptionsKit.MAX_DEPTH`, `OptionsKit.UNBOUNDED` and the `maxOptions`, `maxDepth` and `maxDynamicEntries` options of `Define`; `OptionsKit:ProfileOptions` (revision 2) and, for it, `desc` as a function evaluated by `Describe`.
- **Not carried over from AceConfig:** `hasAlpha` as a function (it shapes the schema, fixed at `Define`), a `confirm` string as a method name (it is the question), the `dropdown*` fields (no Ace3 interface reads them), `info.option`, `info.options`, `info.appName` and `info.uiType`, `validate` on `execute`, a plugin key that silently wins over an `args` key (refused instead), and validation at render time (everything is checked once at `Define`). Revision 14 added `name` and `order` as functions (resolved before any sort), method names and inheritance, `width`, `arg` and AceConfig's other presentation fields.
- **Parts** (revision 16): the presentation fields, handlers and method names, and binds live in three optional parts; a field of an absent part is refused at `Define` rather than ignored.
- **`GetFields(kind)`** rather than a published `FIELDS` table: a table per kind would stay resident in every addon for a converter that asks once.

## Embedded copies and upgrades

Several addons may embed OptionsKit; Registry selects the newest compatible revision and every copy shares one facade. An upgrade happens in place: trees defined under an older copy stay registered, keep their records, `info` tables, schemas and `OnChange` listeners, and gain the newer copy's methods through the shared `OptionsKit.Tree` prototype. Revision 2 added the profile group map to the package state and a link list to every tree; a tree built by revision 1 gets an empty one when a later revision loads over it. Revisions 3 to 6 changed no layout; a predicate recorded by an older revision is answered secret-aware as soon as revision 5 loads. Revision 7 builds lighter records (no prebuilt `Set` label, absent fields left out, `info` built on first use, shared schemas and hints) and reads an older record's layout as it is: its `info` table and schema stay the ones it was built with. A profile group defined before an upgrade keeps its database connections and the callbacks of the revision that built it: `ProfileOptions` builds them as closures, so a newer copy's fixes reach the groups built after it loads. Revision 8 adds the per-database group cache to the package state; groups built earlier are not in it, and the first call after the upgrade builds the one later calls return. Revision 9 keeps one group per database: it reduces a revision 8 cache to the last group built for each database, and lets the profile group map release groups nobody holds; groups built earlier keep working. Revision 10 accepts the `childGroups` hint and publishes `CHILD_GROUPS`; it changes no layout, and trees defined earlier keep theirs. Revision 11 adds the spec-profile selects to profile groups and the link field `specProfiles`: a link an older revision cached has no such field, so the first `ProfileOptions` call after the upgrade builds a new group, with the selects, and caches it; the older group keeps working wherever it is held. Revision 12 changes no layout: a cached link built without the selects while SettingsKit lacked spec profiles is replaced as soon as SettingsKit offers them.

Revision 14 changes no layout: records gain hint keys only, and a record an older revision built (no new hint, never a function name) is read as before. Revision 15 makes the tree layout 3: it keeps `_maxOptions`, `_maxDepth` and `_maxDynamicEntries` (an older tree gets the defaults, or the values revisions 8 and earlier wrote) and, for a builder, `_builder`; the state gains `parts`, `helpers`, `treeSources` and, after a single-file revision, `legacyMembers`. A tree defined before revision 15 has no source to read again, so `NotifyChange` raises for it; `Replace` and `Remove` work.

Revision 16 moves the presentation fields, handlers and binds into the Presentation, Handlers and Bind parts and the profile links into the Profiles part (revision 2); records and the tree layout are unchanged. Revision 15 was the last core with those features inside, so an addon embedding revision 15 alone may share a session with one embedding revision 16 without the parts. An upgrade from revision 15 keeps that addon working: before it commits, the revision 16 core captures revision 15's `Define` and tree methods into `state.legacyMembers.revision15` and marks the trees that use a part. Routing happens only on the branch that needs an absent part: a bound option's `Get`, `Set`, `Validate` and `Reset` call revision 15's method while Bind is absent; a marked tree's `Describe`, `DescribeOption` and `IsHidden` with an interface call revision 15's while Presentation or Bind is absent; a `Define` that uses a field of an absent part is handed to revision 15's `Define`, and its tree is marked. Method callers, inherited accessors and plugins are resolved into the records at `Define`, so such trees need no routing. Once Presentation, Handlers and Bind are all loaded, the captured functions are dropped and revision 16 serves throughout. Known limits: a revision 15 copy loaded after revision 16 yields, and its addon's trees meet the refusals until some addon embeds the parts; a profile group a Profiles revision 1 part (or a single-file revision's `ProfileOptions`) builds is defined and works with the revision 16 core, but is not linked to its tree, so its database's profile signals do not reach the tree's `OnChange` until the Profiles part revision 2 loads; a routed `Define` reports its own refusals at a line inside OptionsKit.

Nothing survives `/reload`: trees are defined again when the addon loads.
