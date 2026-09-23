# OptionsKit API

OptionsKit API generation **1** provides a typed, validated, introspectable options tree with no renderer: what an addon exposes as configurable, how each option is read and written, and what a dialog or a command line needs to present it.

Implementation revision: **1**.

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
| SettingsKit API 1, through `Registry:Find` | `Define` with `options.db`, which every `bind` needs | `Define` with `options.db` raises; options with `get`/`set` work as usual. |
| `issecretvalue` | `Set`, `Validate`, and every path and addon-name argument | Nothing is treated as secret, which is correct on clients without secret values. |

`issecretvalue` is read from the global table at every call, as SchemaKit reads it, so a probe that appears later is used at once.

## Public surface

Package facade:

| Field | Purpose |
|---|---|
| `Define(addonName, tree, options?)` | Check and copy an options tree; return its handle. |
| `Get(addonName)` | The tree defined for `addonName`, or `nil`. |
| `Undefine(addonName)` | Forget the tree and disconnect its listeners. `true` when there was one. |
| `MAX_OPTIONS` | `1024`: the most options one tree holds. |
| `MAX_DEPTH` | `8`: the most keys one option path has. |
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
| `OnChange(callback)` | Connect `callback(tree, path, value)`; return a SignalKit connection. | one connection |

## `OptionsKit:Define(addonName, tree, options?)`

`addonName` is a non-empty string; one tree per addon name (a second `Define` raises until `Undefine`). `tree` is the root: a `group` whose `name` is optional and defaults to `addonName`. `options` accepts one field:

| Option | Meaning |
|---|---|
| `db` | A SettingsKit API 1 database (the `db` `SettingsKit:Open` returns). Required when any option uses `bind`. |

`Define` checks the whole tree before it registers anything and raises at the line that called it, naming the field by its path from the root:

```text
MyAddon.lua:40: OptionsKit:Define tree.args.general.args.scale.min must not be greater than max
MyAddon.lua:40: OptionsKit:Define tree.args.general contains unknown field "witdh" for type "group"
```

What it refuses:

- a root that is not a `group`; an option that is not a table or has no known `type`;
- any field its kind does not accept (a misspelling fails at once instead of being ignored);
- a key in `args` that is not an identifier (`[%a_][%w_]*`), so a dotted path is never ambiguous;
- more than `MAX_OPTIONS` options below the root (groups count), and an option path longer than `MAX_DEPTH` keys — which also turns a cyclic tree into an error;
- a value option with neither `get` and `set` nor `bind`, or with both; a `bind` without `options.db`;
- `options.db` when `Registry:Find("settingsKit", 1)` finds nothing, or when it is not a table with an `OnChange` method; a `bind` whose scope the database did not declare or cannot provide on this client (`OptionsKit:Define tree.args.x.bind scope "realm" is not an available scope of options.db`). The scope is read with `rawget`, so SettingsKit's own error for an undeclared scope never escapes from inside OptionsKit.

The tree is **copied**: labels, values tables and sorting arrays are read once, and later edits to the tables you passed have no effect. Functions (`get`, `set`, `validate`, `disabled`, `hidden`, `values`, `func`) are kept by reference.

## A complete options tree

An addon with saved settings in SettingsKit, one option with its own accessors, and every kind of option. The SettingsKit schema declares what is stored; the options tree declares what is configurable and how it is presented. Bounds that appear in both are kept equal, because `Validate` checks the option's schema only.

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
| `desc` | string? | Longer help text. |
| `order` | number? | Sort position among siblings; default `100`. Ties sort by `name`, then by key. A number, never a function: no code of yours runs inside a sort. |
| `disabled` | boolean or `fun(info): boolean` | Shown but not editable. A disabled group disables everything below it. |
| `hidden` | boolean or `fun(info): boolean` | Not shown. A hidden group hides everything below it. |

`disabled` and `hidden` are renderer concerns: `Get`, `Set` and `Execute` work on hidden and disabled options exactly as on any other, so an addon can still change a value its UI hides. A renderer, or CommandKit, asks `IsDisabled` / `IsHidden` before offering an option.

### Fields every value option accepts

Value options are `toggle`, `range`, `select`, `multiselect`, `input`, `color` and `keybinding`.

| Field | Type | Meaning |
|---|---|---|
| `get` | `fun(info): any` | Returns the current value. With `set`. |
| `set` | `fun(info, value)` | Stores a value that passed the schema and `validate`. With `get`. |
| `bind` | string | `"<scope>.<key>[.<key>...]"` into `options.db`, instead of `get` and `set`. `<scope>` is `global`, `char`, `realm`, `class`, `faction` or `profile`; every segment is an identifier. |
| `validate` | `fun(info, value): boolean, string?` | Runs after the schema accepted the value. Anything but `true` refuses; the second result is the message (`"refused by validate"` when there is none). |

### Kinds and their schemas

| Kind | Own fields | Schema built at `Define` |
|---|---|---|
| `group` | `args` (table of key → option, required), `inline` (boolean: draw inside the parent) | none |
| `toggle` | `tristate` (boolean: `nil` is a third state) | `SchemaKit.boolean()`, wrapped in `optional` when `tristate` |
| `range` | `min`, `max` (required numbers, `min <= max`), `step`, `bigStep` (numbers `> 0`), `softMin`, `softMax` (between `min` and `max`, `softMin <= softMax`), `isPercent` (boolean) | `SchemaKit.number{ min = min, max = max }` |
| `select` | `values` (table of key → label, or `fun(info): table`), `sorting` (array of keys: display order) | table: `SchemaKit.enum` of its keys; function: `SchemaKit.custom` accepting a string or number key of the table the function returns at check time |
| `multiselect` | `values`, `sorting`, as `select` | `SchemaKit.map{ keys = <the select key schema>, values = SchemaKit.boolean(), max = <number of keys> }`; with a values function `max` is 1024 |
| `input` | `pattern` (Lua pattern the text must contain; anchor it with `^`/`$`), `multiline` (boolean), `usage` (string: what to type, for a command line) | `SchemaKit.string{ pattern = pattern }`, or `SchemaKit.string()` |
| `color` | `hasAlpha` (boolean) | `SchemaKit.table{ fields = { r, g, b = number 0..1 } }`, plus a required `a` when `hasAlpha`; a closed table, so `a` is refused without `hasAlpha` |
| `keybinding` | none | `SchemaKit.string()`; `""` is "unbound" |
| `execute` | `func` (`fun(info)`, required), `confirm` (boolean, or the question as a string) | none |
| `header` | none | none |
| `description` | `fontSize` (`"small"`, `"medium"` or `"large"`); the text is `name` | none |

`values` tables have string or number keys and string labels, at least one entry and at most 1024. `sorting` entries must be keys of a `values` table.

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
4. `set(info, value)` runs, or the value is written at the bind path; a refusal by SettingsKit (its schema is narrower, or the profile view is detached) is raised again **at your line** with SettingsKit's message kept: `OptionsKit.Tree:Set frame.x refused by the database: SettingsKit (MyAddonDB) profile.frame.x: expected number <= 3, found larger number`;
5. `OnChange` listeners run with `(tree, path, value)`;
6. `Set` returns `true`.

The two kinds of refusal are deliberately different. A value of the wrong type or out of the schema's bounds is a programming error in the caller — a renderer knows the bounds from `Describe` — so it raises. `validate` expresses a rule the user can break with a well-typed value ("that name is taken"), so its refusal comes back as a message a renderer can show. `Set` does not compare the new value with the old one: setting the same value fires `OnChange` again.

A table value (`multiselect`, `color`) is handed to `set`, or stored at the bind path, as it is, not copied.

### `tree:Validate(path, value)`

Runs steps 1 to 3 without raising for the value and without writing: `true`, or `false` and a message such as `expected number <= 2, found larger number`, `r: expected number <= 1, found larger number`, `secret value`, or `validate`'s own message. Command lines and edit boxes use it to answer the user before calling `Set`.

**For a bound option, `Validate` does not consult the database.** It checks the option's own schema and `validate` only, so it can return `true` for a value SettingsKit then refuses in `Set` — when the SettingsKit schema at the bind path is narrower than the option's (a `range` of `0..10` bound to a field declared `0..3`). SettingsKit API 1 offers no way to check a value at a path without writing it. Declare the option's bounds to match the database's until it does.

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

OptionsKit does not listen to the database. A value changed by SettingsKit directly — a profile switch, `db:ResetProfile()` — fires SettingsKit's signals, not `OnChange`; a renderer that shows bound options listens to `db:OnChange` and `db:OnProfileChanged` as well.

### Paths

A path is the option's keys joined with dots. Every path is indexed in one map at `Define`, so a lookup is one table read; nothing is split per call. An unknown path raises at your line (`OptionsKit.Tree:Get unknown path "general.size"`), as does a path naming an option without a value (`OptionsKit.Tree:Set path "general" is a group, not a value option`). The root group has no path.

## `tree:Walk(visitor)`

Calls `visitor(path, kind, depth)` for every option below the root, depth-first, a group before its children, siblings sorted by `order`, then `name`, then key. `depth` is `1` for the root's children. Returns the number of options visited. The order is fixed at `Define`, so `Walk` allocates nothing; an error raised by the visitor propagates to the caller of `Walk`.

## `tree:OnChange(callback)`

Connects `callback(tree, path, value)` to every successful `Set` and every `Reset`, and returns the SignalKit connection (`connection:Disconnect()`). Dispatch follows SignalKit's rules: listeners run in connection order, and a listener error propagates to the caller of `Set` after the value was written. `Undefine` disconnects every listener.

## `tree:Describe()`

A fresh plain table describing the whole tree, built on every call and safe to edit. Each node:

| Field | Present for | Meaning |
|---|---|---|
| `kind` | every node | The option kind. |
| `key` | every node but the root | The option's key. |
| `path` | every node | The dotted path; `""` for the root. |
| `depth` | every node | `0` for the root. |
| `name`, `order` | every node | As defined; the root's `name` defaults to the addon name, `order` to `100`. |
| `desc` | when defined | |
| `disabled`, `hidden` | every node | Effective booleans, evaluated now (`IsDisabled` / `IsHidden`). |
| `addonName` | the root | |
| `children` | `group` | Child nodes, sorted as `Walk` visits them. |
| `inline` | `group` | When defined. |
| `value` | value kinds | The current value, as `Get` returns it. |
| `schema` | value kinds | `schema:Describe()` of the option's SchemaKit schema. |
| `bind` | bound options | The bind path. |
| `values` | `select`, `multiselect` | A copy of the values table; a values function is called and its result copied. |
| `sorting` | `select`, `multiselect` | A copy, when defined. |
| `tristate` · `min`, `max`, `step`, `bigStep`, `softMin`, `softMax`, `isPercent` · `pattern`, `multiline`, `usage` · `hasAlpha` · `confirm` · `fontSize` | their kinds | As defined. |

Functions never appear in a description. Everything a renderer does goes back through the tree by `path`.

### How a renderer consumes `Describe`

This is the contract WidgetKit (package E) and CommandKit build on.

1. **Build** the screen from `tree:Describe()`: one widget per node, chosen by `kind`; a `group` becomes a page, a tab or — with `inline` — a box inside its parent; children are already in display order. Skip nodes whose `hidden` is `true`; grey out nodes whose `disabled` is `true`.
2. **Configure** each widget from the node's hints: a slider from `min`/`max`/`step`/`softMin`/`softMax`/`isPercent`; a dropdown over `values` in `sorting` order (or sorted by label when there is none); an edit box that is multi-line for `multiline`; a colour swatch with an alpha slider for `hasAlpha`; a confirmation dialog before `Execute` for `confirm`. `schema` carries the same bounds in SchemaKit's vocabulary for a generic widget.
3. **Write** through `tree:Set(node.path, value)`. For typed text, call `tree:Validate(node.path, value)` first and show its message; call `Set` only when it returns `true`, and show the message `Set` returns when `validate` refuses. Run buttons with `tree:Execute(node.path)`.
4. **Refresh** by connecting `tree:OnChange` (and, for bound options, the database's `OnChange` and `OnProfileChanged`), then calling `Describe` again — or, for one widget, `tree:Get(path)`, `tree:IsDisabled(path)` and `tree:IsHidden(path)`, which allocate nothing. Coalesce a burst of changes into one rebuild; `Describe` allocates the whole description each time.

A command line needs no widgets: `Walk` lists the paths, `Describe` gives each one's help (`name`, `desc`, `usage`, `values`), `Validate` answers a typed value and `Set` stores it.

## Bounds

| Bound | Value | Refusal |
|---|---|---|
| Options per tree, groups included, root excluded | 1024 (`OptionsKit.MAX_OPTIONS`) | `Define` raises |
| Keys per option path | 8 (`OptionsKit.MAX_DEPTH`) | `Define` raises |
| Entries of a `values` table | 1024 | `Define` raises |
| Keys of a `multiselect` with a values function | 1024 | the schema refuses a larger map |

## Secret values

On Retail 12.x some client APIs hand addon code secret values (see [`docs/EMBEDDING.md`](../../../docs/EMBEDDING.md#secret-values-retail-12x)). `Set` refuses a secret value at your line before anything compares it, and `Validate` reports it as `false, "secret value"`. A secret path or addon name is refused before it is used as a table key. `Get` and `Describe` return what a getter returns, secret or not, without inspecting it. A secret nested in a table value (a `color` field) is refused by the schema with SchemaKit's `secret` rule.

## Error behaviour

Every argument failure, schema refusal and bind-path failure reports the line that called OptionsKit, never a line inside it, and names the method and the offending path or field. Calling a tree method on something that is not a tree raises `OptionsKit.Tree:Get must be called on an OptionsKit tree`; on a tree that was undefined, `OptionsKit.Tree:Get cannot be called on an undefined tree`. Errors raised by your own callbacks (`get`, `set`, `validate`, predicates, `func`, a `Walk` visitor, an `OnChange` listener) propagate unchanged.

## Performance

| Operation | Cost |
|---|---|
| `Define` | Proportional to the tree; allocates the records, the index, the sorted arrays, one `info` per option and one schema per value option. |
| `Get`, `Set` of a valid value | One map read, one secret probe, the schema check and your callbacks; no allocation by OptionsKit. A bound option adds one table read per path key and one protected call around the write; a `Set` that must create a missing record allocates that nested table. |
| `Walk` | One pass over a pre-sorted array; no allocation. |
| `IsDisabled`, `IsHidden` | One check per ancestor; no allocation. |
| `Describe` | Allocates the whole description. |

## Deviations from the planned contract

The nine-point plan in `docs/ROADMAP.md` is followed except where recorded here:

- **`color { hasAlpha }`** rather than `color { alpha }`: the AceConfig name, which addon authors already know.
- **`Set` returns `false, message` when `validate` refuses** instead of raising. A schema refusal is a caller's mistake and raises at the caller's line as planned; a `validate` refusal is a message for the user, and a renderer should not need `pcall` to show it.
- **`Reset` clears the stored value** instead of writing a default read from the SettingsKit schema. The SettingsKit database surface does not expose its schema, and a cleared value is exactly what SettingsKit's default fallback answers for — without ever writing the default into the saved variables. `Reset` on an option with `get`/`set` raises, since no default exists for OptionsKit to restore.
- **`Validate` of a bound option does not ask the database**, so it can accept what SettingsKit refuses in `Set`; see [`tree:Validate`](#treevalidatepath-value). SettingsKit API 1 has no check-without-write.
- **`options.db` is checked structurally**: `Registry:Find("settingsKit", 1)` must find SettingsKit, and the database must be a table with an `OnChange` method whose bound scopes are tables. SettingsKit API 1 publishes no predicate that recognises its databases.
- **Additions:** `tree:Validate`, `tree:Execute`, `tree:IsDisabled` and `tree:IsHidden` — a renderer and a command line need to check typed input, run a button and re-evaluate predicates without rebuilding the whole description — and `OptionsKit:Undefine`, `OptionsKit.MAX_OPTIONS` and `OptionsKit.MAX_DEPTH`.
- **Not carried over from AceConfig:** `order` and `name` as functions (no user code inside a sort), inherited `get`/`set`/`handler` (each value option names its own reader and writer or `bind`), `width`, `arg`, and validation at render time (everything is checked once at `Define`).

## Embedded copies and upgrades

Several addons may embed OptionsKit; Registry selects the newest compatible revision and every copy shares one facade. An upgrade happens in place: trees defined under an older copy stay registered, keep their records, `info` tables, schemas and `OnChange` listeners, and gain the newer copy's methods through the shared `OptionsKit.Tree` prototype.

Nothing survives `/reload`: trees are defined again when the addon loads.
