# OptionsKit API

OptionsKit API generation **1** provides a typed, validated, introspectable options tree with no renderer: what an addon exposes as configurable, how each option is read and written, and what a dialog or a command line needs to present it.

Implementation revision: **5**.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
SignalKit.lua
SchemaKit.lua
OptionsKit.lua
```

Portable WoW code resolves the package through Registry:

```lua
local OptionsKit = MoltenCodes.Registries[2]:Get("optionsKit", 1)
```

OptionsKit does not rely on `require()` at runtime.

### Optional dependencies and host facilities

| Facility | Used by | Without it |
|---|---|---|
| SettingsKit API 1, through `Registry:Find` | `Define` with `options.db`, which every `bind` needs; `ProfileOptions` | `Define` with `options.db` and `ProfileOptions` raise; options with `get`/`set` work as usual. |
| `UnitName("player")`, `GetRealmName()` | `ProfileOptions`, for the per-character profile choice `"<name> - <realm>"` | The choice is left out; the group works otherwise. Read once per `ProfileOptions` call. |
| `issecretvalue` | `Set`, `Validate`, `Describe`'s copy of a value, every path and addon-name argument, the `Define` limit options, and the results of `validate` and `db:Validate` | Nothing is treated as secret, which is correct on clients without secret values. |

`issecretvalue` is read from the global table at every call, as SchemaKit reads it, so a probe that appears later is used at once.

## Public surface

Package facade:

| Field | Purpose |
|---|---|
| `Define(addonName, tree, options?)` | Check and copy an options tree; return its handle. |
| `Get(addonName)` | The tree defined for `addonName`, or `nil`. |
| `Undefine(addonName)` | Forget the tree and disconnect its listeners. `true` when there was one. |
| `ProfileOptions(db, options?)` | A ready-made `group` over a SettingsKit database's profiles, to place in a tree (see [Profile options](#profile-options-optionskitprofileoptionsdb-options)). |
| `MAX_OPTIONS` | `1024`: the default `maxOptions`, the most options one tree holds. |
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
| `IsDisabled(path)`, `IsHidden(path)` | The effective flag, a group's included. | no |
| `Walk(visitor)` | Visit every option in order. Returns the count. | no |
| `Describe()` | A fresh plain description of the whole tree. | yes, by design |
| `OnChange(callback)` | Connect `callback(tree, path, value)` to every `Set`, `Reset` and, while the tree holds a profile group, its database's profile signals; return a SignalKit connection. | one connection |

The options of a [profile group](#profile-options-optionskitprofileoptionsdb-options) are the exception to the "no" column: their getters, predicates and values functions call `db:GetProfiles()`, which allocates (see [Performance](#performance)).

## `OptionsKit:Define(addonName, tree, options?)`

`addonName` is a non-empty string; one tree per addon name (a second `Define` raises until `Undefine`). `tree` is the root: a `group` whose `name` is optional and defaults to `addonName`. `options` accepts these fields:

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

The tree is **copied**: labels, values tables and sorting arrays are read once, and later edits to the tables you passed have no effect. Functions (`get`, `set`, `validate`, `disabled`, `hidden`, `values`, `func`) are kept by reference.

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

| Field | Type | Meaning |
|---|---|---|
| `type` | string | The kind, below. |
| `name` | string | The label. Required, except on the root. |
| `desc` | string, or `fun(info): string` | Longer help text. A function is called by `Describe`, with the option's `info`, and must return a string; it is the one place a description can follow the current state. Nothing else reads `desc`. |
| `order` | number? | Sort position among siblings; default `100`. Ties sort by `name`, then by key. A number, never a function: no code of yours runs inside a sort. |
| `disabled` | boolean or `fun(info): boolean` | Shown but not editable. A disabled group disables everything below it. |
| `hidden` | boolean or `fun(info): boolean` | Not shown. A hidden group hides everything below it. |

A predicate's answer is tested for truth only after `issecretvalue` says it is not a secret: a secret answer (Retail 12.x) counts as `false`, so the option stays enabled and shown rather than an error being raised inside OptionsKit. `disabled` and `hidden` are renderer concerns: `Get`, `Set` and `Execute` work on hidden and disabled options exactly as on any other, so an addon can still change a value its UI hides. A renderer, or CommandKit, asks `IsDisabled` / `IsHidden` before offering an option.

### Fields every value option accepts

Value options are `toggle`, `range`, `select`, `multiselect`, `input`, `color` and `keybinding`.

| Field | Type | Meaning |
|---|---|---|
| `get` | `fun(info): any` | Returns the current value. With `set`. |
| `set` | `fun(info, value)` | Stores a value that passed the schema and `validate`. With `get`. |
| `bind` | string | `"<scope>.<key>[.<key>...]"` into `options.db`, instead of `get` and `set`. `<scope>` is `global`, `char`, `realm`, `class`, `faction` or `profile`; every segment is an identifier. |
| `validate` | `fun(info, value): boolean, string?` | Runs after the schema accepted the value. Anything but `true` refuses, a secret result included (it is never compared); the second result is the message (`"refused by validate"` when there is none). |

### Kinds and their schemas

| Kind | Own fields | Schema built at `Define` |
|---|---|---|
| `group` | `args` (table of key → option, required), `inline` (boolean: draw inside the parent) | none |
| `toggle` | `tristate` (boolean: `nil` is a third state) | `SchemaKit.boolean()`, wrapped in `optional` when `tristate` |
| `range` | `min`, `max` (required numbers, `min <= max`), `step`, `bigStep` (numbers `> 0`), `softMin`, `softMax` (between `min` and `max`, `softMin <= softMax`), `isPercent` (boolean) | `SchemaKit.number{ min = min, max = max }` |
| `select` | `values` (table of key → label, or `fun(info): table`), `sorting` (array of keys: display order) | table: `SchemaKit.enum` of its keys; function: `SchemaKit.custom` accepting a string or number key of the table the function returns at check time |
| `multiselect` | `values`, `sorting`, as `select` | `SchemaKit.map{ keys = <the select key schema>, values = SchemaKit.boolean(), max = <number of keys> }`; with a values function `max` is the tree's `maxDynamicEntries` (1024 by default; 2147483647 when unbounded, since the map needs an integer and the function's own table is then the bound) |
| `input` | `pattern` (Lua pattern the text must contain; anchor it with `^`/`$`), `multiline` (boolean), `usage` (string: what to type, for a command line) | `SchemaKit.string{ pattern = pattern }`, or `SchemaKit.string()` |
| `color` | `hasAlpha` (boolean) | `SchemaKit.table{ fields = { r, g, b = number 0..1 } }`, plus a required `a` when `hasAlpha`; a closed table, so `a` is refused without `hasAlpha` |
| `keybinding` | none | `SchemaKit.string()`; `""` is "unbound" |
| `execute` | `func` (`fun(info)`, required), `confirm` (boolean, or the question as a string) | none |
| `header` | none | none |
| `description` | `fontSize` (`"small"`, `"medium"` or `"large"`); the text is `name` | none |

`values` tables have string or number keys and string labels, at least one entry and at most `maxDynamicEntries` (1024 by default). `sorting` entries must be keys of a `values` table.

`step`, `bigStep`, `softMin`, `softMax`, `isPercent`, `multiline`, `usage`, `inline`, `confirm` and `fontSize` are hints for renderers: nothing in OptionsKit enforces them. In particular `step` is not part of the schema: a slider snaps to it, and a value typed on a command line only has to lie between `min` and `max`.

## `info`

Every callback — `get`, `set`, `validate`, `disabled`, `hidden`, a `values` function and `func` — receives the option's `info`:

| Field | Meaning |
|---|---|
| `info[1]` … `info[#info]` | The option's keys from the root: `"general"`, `"scale"`. |
| `info.path` | The dotted path, `"general.scale"`; `""` for the root group. |
| `info.kind` | The option's kind. |
| `info.tree` | The tree handle, so a callback can `Get` a sibling. |

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

The option's own flag or predicate, then each ancestor's, up to the root: `true` as soon as one says so. Predicates run on every call, with their own option's `info`. Any option path is accepted, groups included.

### Bound options

A bind path is split once, at `Define`. At every `Get`, `Set` and `Reset` the scope view is read from the database afresh (`rawget(db, "profile")`), so a profile switch is seen at once, and the keys are walked through the views SettingsKit returns, so its default fallback answers for anything the user never changed. The last write goes through SettingsKit's own validated write.

SettingsKit reads a record that has no default and no saved data as `nil`. OptionsKit treats such a gap on the bind path as an unset value rather than an error:

| Call | Record on the path missing |
|---|---|
| `Get`, `Describe` | `nil` (a default declared on the leaf field inside that record is not reachable until the record exists) |
| `Set` | writes the missing records as one nested table holding the value (`frame = { x = 1 }`), which SettingsKit validates like any write; this is the only `Set` that allocates |
| `Reset` | nothing to clear; returns `nil` |

Give the record a default (`S.optional(S.table{...}, {})`) when its leaf defaults should be visible before the first write.

If the walk meets something that is not a table, the call raises at your line: `OptionsKit.Tree:Get bind path "profile.frame.anchor" does not lead to a table`. A scope the database no longer provides raises `OptionsKit.Tree:Get bind scope "profile" is not an available scope of the database`.

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
| `disabled`, `hidden` | every node | Effective booleans, evaluated now (`IsDisabled` / `IsHidden`). |
| `addonName` | the root | |
| `children` | `group` | Child nodes, sorted as `Walk` visits them. |
| `inline` | `group` | When defined. |
| `value` | value kinds | The current value, as `Get` returns it, except that a table is copied: a bound value that SettingsKit returns as a view is copied through `db:Pairs`, defaults included, so the description never holds the getter's table or a view that writes through to the saved variable. A table nested deeper than 8 levels appears as the string `"<depth exceeded>"`, and a table that contains itself as `"<cycle>"`. A secret value is passed through without being copied (see [Secret values](#secret-values)). |
| `schema` | value kinds | `schema:Describe()` of the option's SchemaKit schema. |
| `bind` | bound options | The bind path. |
| `values` | `select`, `multiselect` | A copy of the values table; a values function is called and its result copied. |
| `sorting` | `select`, `multiselect` | A copy, when defined. |
| `tristate` · `min`, `max`, `step`, `bigStep`, `softMin`, `softMax`, `isPercent` · `pattern`, `multiline`, `usage` · `hasAlpha` · `confirm` · `fontSize` | their kinds | As defined. |

Functions never appear in a description. Everything a renderer does goes back through the tree by `path`.

### How a renderer consumes `Describe`

This is the contract WidgetKit's `RenderOptions` and CommandKit's `BindOptions` build on.

1. **Build** the screen from `tree:Describe()`: one widget per node, chosen by `kind`; a `group` becomes a page, a tab or — with `inline` — a box inside its parent; children are already in display order. Skip nodes whose `hidden` is `true`; grey out nodes whose `disabled` is `true`.
2. **Configure** each widget from the node's hints: a slider from `min`/`max`/`step`/`softMin`/`softMax`/`isPercent`; a dropdown over `values` in `sorting` order (or sorted by label when there is none); an edit box that is multi-line for `multiline`; a colour swatch with an alpha slider for `hasAlpha`; a confirmation dialog before `Execute` for `confirm`. `schema` carries the same bounds in SchemaKit's vocabulary for a generic widget.
3. **Write** through `tree:Set(node.path, value)`. For typed text, call `tree:Validate(node.path, value)` first and show its message; call `Set` only when it returns `true`, and show the message `Set` returns when `validate` refuses. Run buttons with `tree:Execute(node.path)`.
4. **Refresh** by connecting `tree:OnChange` (and, for bound options, the database's `OnChange`, and `OnProfileChanged` unless the tree holds a profile group), then calling `Describe` again — or, for one widget, `tree:Get(path)`, `tree:IsDisabled(path)` and `tree:IsHidden(path)`, which allocate nothing. Coalesce a burst of changes into one rebuild; `Describe` allocates the whole description each time.

A command line needs no widgets: `Walk` lists the paths, `Describe` gives each one's help (`name`, `desc`, `usage`, `values`), `Validate` answers a typed value and `Set` stores it.

## Profile options: `OptionsKit:ProfileOptions(db, options?)`

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

The `select` options take their choices from a values function, so `Describe` and every check see the profiles as they are now; the group's `desc` and those of `current`, `copySource`, `copy`, `reset` and `deleteTarget` are `desc` functions that name the current profile (`Return every setting of "Raid" to its default.`). Both are read when `Describe` runs: a renderer that redraws from `Describe` shows the current names, one that caches its last description shows them as of that call.

The three buttons carry `confirm` questions; whether the user is asked is the renderer's concern, as for any `execute`. `Execute` of `copy` or `delete` while its select is unset raises at your line (`OptionsKit.Tree:Execute profiles.copy needs "profiles.copySource" to be set first`); a renderer that honours `disabled` never gets there. A refusal by SettingsKit while switching (or an error raised by one of the database's own profile listeners) propagates from `Set` unchanged.

### Refresh

While a defined tree holds the group, it is connected to the database's `OnProfileChanged`, `OnProfileCopied`, `OnProfileReset` and `OnProfileDeleted` signals. Each fires the tree's `OnChange` with the `current` option's path and the current profile's name — `("profiles.current", "Raid")` — so a renderer connected to `tree:OnChange` redraws after a switch made anywhere, by the group's own buttons or by the addon. A switch through `current` fires `OnChange` once, for that `Set`, even when a listener of that switch switches again through `current` (each `Set` then fires once, the inner one first). Creating through `new` fires twice: `("profiles.current", name)` from the database's signal, because the current profile changed, then `("profiles.new", name)` from the `Set`. `db:ResetDatabase()` fires `profiles.current` once when the database was already on its default profile (`OnProfileReset`) and twice otherwise (`OnProfileReset`, then `OnProfileChanged` for the switch back).

The connections are made at the end of `Define`, after the whole tree was checked, and disconnected at `Undefine`. A `Define` that raises leaves every group free: a connect that fails (a table that passed the structural check but is no SettingsKit database) undoes the connections made before it, and the groups attached earlier in the same tree are detached, before the error reaches your line. The connections live with the tree, which lives for the session, so nothing needs closing at logout.

### Options

| Option | Meaning |
|---|---|
| `name` | The group's label; default the `group.name` string, "Profiles". |
| `order` | The group's `order` among its siblings; default `100`. |
| `description` | The text of the `intro` option; default the `intro` string. |
| `localize` | `fun(key, default): string?`, called for every user-visible string with its key and English text. A string result is used; anything else keeps the default. Called at `ProfileOptions` for fixed strings, at every `Describe` for the live descriptions, and at every `Validate` and `Set` of `new` for its messages. |

Unknown fields and wrong types are refused at your line: `OptionsKit:ProfileOptions options contains unknown field "colour"`, `OptionsKit:ProfileOptions options.localize must be a function`.

### Strings and their keys

`%s` is replaced by the current profile's name in quotes, except in `new.long`, where it is the byte limit.

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

### Errors

A secret option is refused first (`OptionsKit:ProfileOptions options.name must not be a secret value`). `ProfileOptions` raises at your line when `Registry:Find("settingsKit", 1)` finds nothing (`OptionsKit:ProfileOptions needs SettingsKit API 1 to be loaded`) and when `db` is not a table offering the profile methods of a SettingsKit database (`OptionsKit:ProfileOptions db must be a SettingsKit database`); SettingsKit publishes no predicate for its databases, so the check is structural, as for `options.db`.

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

## Secret values

On Retail 12.x some client APIs hand addon code secret values (see [`docs/EMBEDDING.md`](../../../docs/EMBEDDING.md#secret-values-retail-12x)). `Set` refuses a secret value at your line before anything compares it, and `Validate` reports it as `false, "secret value"`. A secret path or addon name is refused before it is used as a table key. `Get` and `Describe` return what a getter returns, secret or not, without inspecting it: `Describe` asks `issecretvalue` before it copies a table value, and passes a secret, at the top or nested inside the table, through without being copied. A secret nested in a table value (a `color` field) is refused by the schema with SchemaKit's `secret` rule. A secret `maxOptions`, `maxDepth` or `maxDynamicEntries` is refused at your line before it is compared with `OptionsKit.UNBOUNDED`, and a secret returned by `validate` or by the database's `Validate` counts as a refusal without being compared with `true`. Every field of an option table, and the `name`, `order`, `description` and `localize` options of `ProfileOptions`, is asked about before OptionsKit tests or compares it: a secret one, a secret `true` for `disabled`, `tristate` or `hasAlpha` included, is refused at your line (`OptionsKit:Define tree.args.general.disabled must not be a secret value`, `OptionsKit:ProfileOptions options.name must not be a secret value`), because testing a secret for truth raises (measured on Retail 12.1.0 b69933). A secret answer from a `disabled` or `hidden` predicate counts as `false`, and a secret string from a `desc` function is passed through `Describe` as the description, like a getter's secret value. Whether a field of your tree, your options or a value read from the database is absent is asked with `type`, never by comparing it with `nil`, so an absent-or-present test never touches a secret.

## Error behaviour

Every argument failure, schema refusal and bind-path failure reports the line that called OptionsKit, never a line inside it, and names the method and the offending path or field. Calling a tree method on something that is not a tree raises `OptionsKit.Tree:Get must be called on an OptionsKit tree`; on a tree that was undefined, `OptionsKit.Tree:Get cannot be called on an undefined tree`. Errors raised by your own callbacks (`get`, `set`, `validate`, predicates, `func`, a `Walk` visitor, an `OnChange` listener) propagate unchanged.

## Performance

| Operation | Cost |
|---|---|
| `Define` | Proportional to the tree; allocates the records, the index, the sorted arrays, one `info` per option and one schema per value option. |
| `Get`, `Set` of a valid value | One map read, one secret probe, the schema check and your callbacks; no allocation by OptionsKit. A bound option adds one table read per path key and one protected call around the write; a `Set` that must create a missing record allocates that nested table. |
| `Walk` | One pass over a pre-sorted array; no allocation. |
| `IsDisabled`, `IsHidden` | One check per ancestor; no allocation. |
| `Describe` | Allocates the whole description; a `desc` function runs per node that has one. |
| The profile group's callbacks | Allocate: they call `db:GetProfiles()`. An options screen, not a hot path. |

## Deviations from the planned contract

The nine-point plan in `docs/ROADMAP.md` is followed except where recorded here:

- **`color { hasAlpha }`** rather than `color { alpha }`: the AceConfig name, which addon authors already know.
- **`Set` returns `false, message` when `validate` refuses** instead of raising. A schema refusal is a caller's mistake and raises at the caller's line as planned; a `validate` refusal is a message for the user, and a renderer should not need `pcall` to show it.
- **`Reset` clears the stored value** instead of writing a default read from the SettingsKit schema. The SettingsKit database surface does not expose its schema, and a cleared value is exactly what SettingsKit's default fallback answers for — without ever writing the default into the saved variables. `Reset` on an option with `get`/`set` raises, since no default exists for OptionsKit to restore.
- **`options.db` is checked structurally**: `Registry:Find("settingsKit", 1)` must find SettingsKit, and the database must be a table with `OnChange` and `Validate` methods whose bound scopes are tables. SettingsKit API 1 publishes no predicate that recognises its databases.
- **Additions:** `tree:Validate`, `tree:Execute`, `tree:IsDisabled` and `tree:IsHidden` — a renderer and a command line need to check typed input, run a button and re-evaluate predicates without rebuilding the whole description — and `OptionsKit:Undefine`, `OptionsKit.MAX_OPTIONS`, `OptionsKit.MAX_DEPTH`, `OptionsKit.UNBOUNDED` and the `maxOptions`, `maxDepth` and `maxDynamicEntries` options of `Define`; `OptionsKit:ProfileOptions` (revision 2) and, for it, `desc` as a function evaluated by `Describe`.
- **Not carried over from AceConfig:** `order` and `name` as functions (no user code inside a sort), inherited `get`/`set`/`handler` (each value option names its own reader and writer or `bind`), `width`, `arg`, and validation at render time (everything is checked once at `Define`). `desc` is the one text a function may supply, because it is read by `Describe` alone.

## Embedded copies and upgrades

Several addons may embed OptionsKit; Registry selects the newest compatible revision and every copy shares one facade. An upgrade happens in place: trees defined under an older copy stay registered, keep their records, `info` tables, schemas and `OnChange` listeners, and gain the newer copy's methods through the shared `OptionsKit.Tree` prototype. Revision 2 added the profile group map to the package state and a link list to every tree; a tree built by revision 1 gets an empty one when a later revision loads over it. Revisions 3 to 5 changed no layout; a predicate recorded by an older revision is answered secret-aware as soon as revision 5 loads. A profile group defined before an upgrade keeps its database connections and the callbacks of the revision that built it: `ProfileOptions` builds them as closures, so a newer copy's fixes reach the groups built after it loads.

Nothing survives `/reload`: trees are defined again when the addon loads.
