# CommandKit API

CommandKit API generation **1** provides slash commands for World of Warcraft addons: collision-safe registration owned by a scope, a hyperlink-aware argument parser, sub-commands with generated usage, schema-checked arguments, output sinks, optional tab completion, and a command line over an OptionsKit tree.

Implementation revision: **1**.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
SchemaKit.lua
CommandKit.lua
```

Portable WoW code resolves the package through Registry:

```lua
local CommandKit = MoltenCodes.Registries[2]:Get("commandKit", 1)
```

CommandKit does not rely on `require()` at runtime.

### Optional dependencies and host facilities

| Facility | Used by | Without it |
|---|---|---|
| `SlashCmdList` | `Register`, `BindOptions` | Both raise at the caller. |
| `SLASH_<key><n>`, `SecureCmdList` | the taken check | Nothing is found taken. |
| `DEFAULT_CHAT_FRAME` | the default sink | Output goes to `print`. |
| `ChatEdit_CustomTabPressed` | `EnableCompletion` | `EnableCompletion` returns `false`; nothing is installed. |
| `ChatEdit_GetActiveWindow` | completion, when the client passes no edit box | That Tab press is not completed. |
| `geterrorhandler` | handler and completion failures | Falls back to `print`. |
| OptionsKit API 1, through `Registry:Find` | `BindOptions` | `BindOptions` raises at the caller. |
| LocaleKit API 1, through `Registry:Find` | `context:Printf` | `string.format`, without indexed specifiers. |
| ClientKit API 1, through `Registry:Find` | every secret check | The host's `issecretvalue`; without that, nothing is secret. |

Host globals are read with `rawget` when they are used, never cached at load.

## Public surface

Package facade:

| Field | Purpose |
|---|---|
| `CreateScope()` | A manually owned scope. |
| `ForAddon(addonName)` | The addon's canonical scope, created on demand. |
| `CloseAddonScopes(addonName)` | Close the addon's scope. `false` when it has none or it was closed. |
| `Parse(text)` | A new array of arguments, or `nil, reason`. |
| `ParseInto(text, array)` | Fill `array`; return the count, or `nil, reason`. |
| `CaptureSink()` | A sink that keeps its lines, for tests. |
| `MAX_COMMANDS` | `64`: the most top-level commands one scope registers. |
| `MAX_DEPTH` | `3`: the deepest sub-command nesting. |
| `Scope`, `Context` | The shared prototypes of scopes and contexts. |

Scope:

| Method | Purpose |
|---|---|
| `Register(name, spec)` | Register `/name`. `true`, or `nil, "taken"` / `nil, "full"`. |
| `Unregister(name)` | Unregister one command. `false` when this scope has no such command. |
| `IsRegistered(name)` | Whether this scope registered `name`. |
| `SetSink(sink)` | Send this scope's output to `sink`; `nil` restores the chat frame. |
| `BindOptions(tree, commandName, options?)` | Register `/commandName` over an OptionsKit tree. |
| `EnableCompletion()`, `DisableCompletion()` | Tab completion for this scope's commands. |
| `Close()` | Unregister everything and turn completion off. Terminal. |
| `IsClosed()`, `GetActiveCount()`, `GetAddonName()` | State. |

Context, handed to every handler and completion function:

| Method | Purpose |
|---|---|
| `Print(...)` | `tostring` of each argument, joined by spaces, to the sink. |
| `Printf(template, ...)` | Formatted text to the sink. |
| `Usage()` | The command's usage lines to the sink. |
| `Fail(reason)` | `<command path>: <reason>` to the sink. |
| `GetCommandPath()` | `"/name sub"`. |
| `GetRawText()` | What the user typed after the slash name, unparsed. |

## A complete slash command

An addon with a `/myaddon` command: a status line, a scale setting checked against a schema, a mode chosen from a list, an item link argument, a sub-command group, custom completion, and its options tree bound to `/myaddon_options`.

```lua
local Registry = MoltenCodes.Registries[2]
local SchemaKit = Registry:Get("schemaKit", 1)
local CommandKit = Registry:Get("commandKit", 1)
local OptionsKit = Registry:Get("optionsKit", 1)
local S = SchemaKit

local commands = CommandKit:ForAddon("MyAddon")

local registered, reason = commands:Register("myaddon", {
    description = "My Addon.",
    subcommands = {
        status = {
            description = "Show what the addon is doing.",
            handler = function(context)
                context:Printf("%d frames tracked, mode %s.", MyAddon:CountFrames(), MyAddon.mode)
            end,
        },
        scale = {
            description = "Set the frame scale.",
            arguments = { S.number({ min = 0.5, max = 2 }) },
            handler = function(context, scale)
                MyAddon:SetScale(scale)
                context:Printf("Scale %.2f.", scale)
            end,
        },
        mode = {
            description = "Choose what to track.",
            arguments = { S.enum({ "party", "raid", "all" }), S.optional(S.boolean()) },
            handler = function(context, mode, quiet)
                MyAddon.mode = mode
                if not quiet then
                    context:Print("Tracking", mode)
                end
            end,
        },
        watch = {
            description = "Watch an item: shift-click it into the chat box.",
            usage = "<item link>",
            arguments = { S.string({ pattern = "|Hitem:" }) },
            handler = function(context, itemLink)
                MyAddon:Watch(itemLink)
                context:Print("Watching", itemLink)
            end,
        },
        frame = {
            description = "Frame commands.",
            subcommands = {
                show = {
                    arguments = { S.string() },
                    handler = function(context, name)
                        if not MyAddon:ShowFrame(name) then
                            context:Fail('no frame named "' .. name .. '"')
                        end
                    end,
                    complete = function(context, text, position)
                        return MyAddon:FrameNames()
                    end,
                },
                reset = {
                    handler = function(context)
                        MyAddon:ResetFrames()
                    end,
                },
            },
        },
    },
})
if not registered then
    -- "taken": another addon owns /myaddon; "full": 64 commands already.
    print("MyAddon could not register its command: " .. reason)
end

commands:BindOptions(OptionsKit:Get("MyAddon"), "myaddon_options", { description = "My Addon options." })
commands:EnableCompletion()
```

What the user sees:

```text
/myaddon
Usage: /myaddon <frame|mode|scale|status|watch>
My Addon.
  /myaddon frame <reset|show> - Frame commands.
  /myaddon mode <party|raid|all> [on|off] - Choose what to track.
  /myaddon scale <number 0.5..2> - Set the frame scale.
  /myaddon status - Show what the addon is doing.
  /myaddon watch <item link> - Watch an item: shift-click it into the chat box.

/myaddon scale 5
/myaddon scale: argument 1: expected number <= 2, found larger number
Usage: /myaddon scale <number 0.5..2>
Set the frame scale.

/myaddon_options set frame.scale 1.25
frame.scale = 1.25
```

## Registration

### `scope:Register(name, spec)`

`name` is the slash name without the slash: letters, digits and underscores, starting with a letter, at most 32 bytes. It is case-insensitive and stored in lower case, so `Register("MyAddon", ...)` answers to `/myaddon`, `/MyAddon` and `/MYADDON`, as the client matches slash names.

Registration writes two client globals with `rawset`:

```lua
SlashCmdList["MOLTENCODES_MYADDON_MYADDON"] = <dispatcher>
SLASH_MOLTENCODES_MYADDON_MYADDON1 = "/myaddon"
```

The key is `MOLTENCODES_<ADDON>_<NAME>` for a `ForAddon` scope and `MOLTENCODES_<NAME>` for a manual one, upper-cased, with every byte that is not a letter or digit replaced by `_`, and a numeric suffix in the rare case two names meet in one key.

`Register` returns:

| Result | When |
|---|---|
| `true` | Registered. |
| `nil, "taken"` | Another scope has registered the name, or another addon uses it. |
| `nil, "full"` | The scope holds `MAX_COMMANDS` commands. |

The spec is checked in full first; every problem with it raises at your line (below). Registering one name twice in one scope raises (`Unregister` it first); registering it from a second scope returns `nil, "taken"`.

**The taken check is best effort.** CommandKit reads the keys of `SlashCmdList` and `SecureCmdList` and, for every key it did not write, the `SLASH_<key>1`, `SLASH_<key>2`, … globals up to the first gap, comparing each with `/NAME` without case. That is how the client itself resolves slash names, so it finds every command registered the documented way. A command another addon registers *after* yours is outside CommandKit's reach: it is that addon's registration that overwrites. Nothing scans the whole global table.

### Inert globals and re-registration

The client caches the function behind a slash name the first time it is typed, and the cache cannot be cleared by an addon. CommandKit therefore never removes what it wrote. `Unregister`, `Close` and `CloseAddonScopes` remove the command from CommandKit's own tables, and the dispatcher under the key finds nothing and does nothing — no output, no error — when the name is typed.

A slash name keeps the key of its first registration for the session. When any scope registers the name again, CommandKit writes the same key and the same dispatcher, so the command works again whatever the client cached. The key may then carry the first addon's name; it is only a table key.

### `scope:Unregister(name)` and `scope:IsRegistered(name)`

`Unregister` returns `true` when this scope had the command, `false` otherwise. The name is compared without case.

## Command specs

| Field | Type | Meaning |
|---|---|---|
| `handler` | `fun(context, ...)` | Runs the command. Required unless `subcommands` is given. |
| `arguments` | `SchemaKit.array` schema, or a list of schemas | The arguments' schemas; see below. |
| `usage` | string | What to type after the command path, for the usage line. Generated from `arguments` when absent. |
| `description` | string | One line of help. |
| `subcommands` | table of name → spec | Named sub-commands, at most `MAX_DEPTH` (3) levels below the command and 64 per level. |
| `complete` | `fun(context, text, position): string[]?` | Candidates for tab completion of argument `position` (1-based), starting with `text`. |

A spec with an unknown field raises (`CommandKit.Scope:Register spec.subcommands.frame contains unknown field "desc"`), as does a sub-command key that is not a valid name, two keys equal without case, a spec with neither `handler` nor `subcommands`, and nesting deeper than three levels. The spec is compiled into records once; later edits to your tables have no effect. Functions are kept by reference.

### Arguments

A **list of schemas** declares one schema per position, at most 16. The handler receives exactly that many arguments (`nil` for a missing optional one). Typing more tokens than positions is refused (`expected at most 2 arguments`).

A **`SchemaKit.array` schema** checks the whole argument list at once; its `min` and `max` bound the count. The handler receives every token.

Without `arguments` the handler receives every token as a string.

Tokens are strings. Before a schema checks one, CommandKit converts it as the schema's description says, decided once at `Register`:

| Schema | Conversion |
|---|---|
| `number`, or an `enum` of numbers | the token read as a number |
| `boolean`, or an `enum` of booleans | `on`, `true`, `yes`, `1` → `true`; `off`, `false`, `no`, `0` → `false` (any case) |
| anything else | none: the string |

A token that does not convert stays a string, and the schema refuses it with its own message.

### Usage text

Each command and sub-command has usage lines built once at `Register`:

```text
Usage: <command path> <usage>
<description>
  <sub-command path> <usage> - <description>
  ...
```

A generated usage names each position from its schema: `<number>`, `<integer 1..10>`, `<number 0.5..2>`, `<on|off>`, `<a|b|c>` for an `enum` or a string `oneOf`, `<text>` for another string; square brackets for an `optional` position; `<number...>` for an array (`[number...]` when it may be empty). A command without a handler shows its sub-commands: `<frame|mode|scale>`.

CommandKit's own words (`Usage:`, the refusal messages) are English. Usage and description strings are yours; pass them through your LocaleKit table to translate them.

## Dispatch

When the user types `/name text`, the client calls the dispatcher with `text`. CommandKit then:

1. tokenises `text` (see [Parsing](#parsing)); an unterminated quote or link prints `/name: unterminated quote` and the usage;
2. follows sub-command names from the first token, comparing without case, as deep as they match;
3. at a command without a handler, prints `/name: unknown sub-command "x"` and the usage when a token is left, or just the usage when none is;
4. converts and checks the remaining tokens; a refusal prints the failure (`/name scale: argument 1: expected number <= 2, found larger number`, `/name sum: arguments[2]: expected number, found string`) followed by the usage, and the handler does not run;
5. calls `handler(context, ...)` inside `pcall`. An error is written to the sink as `/name scale failed: <message>` (the message is left out when it is not a string or is secret) and handed, unchanged, to the host error handler. A slash command runs from the client, so there is no caller to propagate to.

A handler may run another slash command. Dispatches nest up to 4 deep; the fifth prints `/name: commands nested too deeply` and does nothing.

## The context

A handler, and a `complete` function, receive a context. **It is valid only while that call runs**: CommandKit reuses it for the next command, and every method raises `CommandKit.Context:Print cannot be used after its command returned` on a context kept longer. For output after the command returned, keep your own reference to a sink.

- `Print(...)` writes `tostring` of each argument joined by single spaces, with no prefix.
- `Printf(template, ...)` formats with `LocaleKit:Format` when `Registry:Find("localeKit", 1)` finds LocaleKit, so translators can reorder arguments (`%2$s`); otherwise with `string.format`. A formatting error raised by either propagates from `Printf` unchanged.
- `Usage()` writes the usage lines of the command being run.
- `Fail(reason)` writes `<command path>: <reason>`. It does not stop the handler; `return` after it.
- `GetCommandPath()` returns the path of the command being run, sub-commands included: `"/myaddon frame show"`.
- `GetRawText()` returns the text the client passed, before parsing.

## Parsing

`CommandKit:Parse(text)` and `CommandKit:ParseInto(text, array)` split text the way dispatch does. Whitespace (space, tab, newline, carriage return) separates tokens; runs of it count once. Inside and around tokens:

| Input | Token |
|---|---|
| `"two words"`, `'two words'` | `two words`. A quote starts a quoted token only at the start of a token. |
| `"say \"hi\""`, `'it\'s'` | `say "hi"`, `it's`: a backslash before the quote that opened the token escapes it. Every other backslash is kept (`"Interface\Icons\X"`). |
| `""` | the empty string. |
| `|H<link data>|h[Some Long Item]|h` | the whole hyperlink, spaces included, in or out of quotes. |
| `|cffa335ee|H…|h[Some Long Item]|h|r` | the whole colour-wrapped text, which is how the client inserts a shift-clicked link. |
| `|TInterface\Icons\X:16|t` | the whole texture. |
| `a||b` | `a||b`: an escaped pipe is ordinary text. |

Refusals, returned as `nil, reason`:

- `"unterminated quote"` — a quote without its closing quote;
- `"unterminated link"` — a `|H` without its two `|h` markers.

A `|c` without a closing `|r`, or a `|T` without `|t`, is ordinary text, as the client displays it.

`Parse` allocates a new array on every call. `ParseInto` writes `array[1..count]`, sets every slot after `count` to `nil` (it stops at the first slot that already is), and returns `count`; on a refusal it leaves `array` empty. Neither keeps any state between calls. Both allocate only the token strings, and a token equal to a string that already exists is that string, so parsing text seen before allocates nothing.

## Sinks

A sink is anything with an `AddMessage(sink, text)` method; a chat frame is one. `scope:SetSink(sink)` sends the scope's output there, and `scope:SetSink(nil)` goes back to the default: `DEFAULT_CHAT_FRAME`, read when a line is written, or `print` outside the client. An error raised by a sink propagates to whatever was writing (a handler's `Print` inside `pcall`, or dispatch, which reports it).

`CommandKit:CaptureSink()` returns a sink for tests:

| Method | Purpose |
|---|---|
| `AddMessage(text)` | Keep `text`. The latest 256 lines are kept; older ones are dropped. |
| `Messages()` | A fresh array of the kept lines, oldest first. |
| `Clear()` | Forget every line. |

## `scope:BindOptions(tree, commandName, options?)`

Registers `/commandName` with five sub-commands over an OptionsKit tree handle (`OptionsKit:Define` returns it). OptionsKit must be registered (`Registry:Find("optionsKit", 1)`) and `tree` must be one of its trees; otherwise `BindOptions` raises at your line. `options.description` is the command's help line. The result is `Register`'s.

| Sub-command | Does |
|---|---|
| `get <path>` | Prints `path = value`. |
| `set <path> <value...>` | Parses the value for the option's kind, asks `tree:Validate`, then `tree:Set`; prints `path = value`, or the refusal. |
| `reset <path>` | `tree:Reset` for a bound option; prints the value it reset to. An option with its own `get`/`set` has no default: `"label" has no default to reset to`. |
| `list [path]` | Lists the visible children of a group (the root without a path): `path = value - Name`, `path - Name (group)`, `path - Name (exec)`, with ` (disabled)` appended where it applies. For one option: its line, its `desc`, and its values. |
| `exec <path> [confirm]` | `tree:Execute`. An option with `confirm` prints its question (when it is a string) and `Type /cmd exec path confirm to run it.` unless the word `confirm` follows. |

Paths are OptionsKit's dotted paths (`frame.scale`). Hidden options are unknown to the command line (`unknown option "x"`); disabled options can be read and listed but not set, reset or run.

Values typed after `set <path>`:

| Kind | Accepted |
|---|---|
| `toggle` | `on`/`off`, `true`/`false`, `yes`/`no`, `1`/`0`, `toggle`; `default` for a `tristate` toggle. |
| `range` | A number; the option's schema checks the bounds. |
| `select` | A key, or a label without case; several words are joined first. |
| `multiselect` | `<key or label> on|off|toggle`, changing one entry of a copy of the current map. |
| `color` | `r g b [a]` between 0 and 1, or `#` and six or eight hex digits (`#ff8000`, `#ff8000cc`). Alpha defaults to 1 with `hasAlpha` and is refused without it. |
| `input` | Every remaining token, joined with single spaces (quote a value to keep runs of spaces). |
| `keybinding` | As `input`; `none` or `unbound` clears the binding. |

Every refusal is printed as `/cmd set: <message>`: CommandKit's own (`expected on, off or toggle`, `expected a number`, `expected one of: TOP, CENTER`), the schema's (`expected number <= 2, found larger number`), or the one your `validate` returned (`that label is taken`).

Each bound sub-command calls `tree:Describe()` once per run to see the tree as it is now (values, labels from a `values` function, hidden and disabled flags). That allocates by design: a typed command is not a hot path.

## Tab completion

Off by default. `scope:EnableCompletion()` turns it on for the scope's commands; `DisableCompletion()` and `Close()` turn it off. `EnableCompletion` returns `false`, and installs nothing, when the host has no `ChatEdit_CustomTabPressed`.

When the cursor is at the end of `/name <text>` and `/name` belongs to a scope with completion on, Tab completes the last word from:

- the names of the sub-commands, when every earlier word was a sub-command;
- what the reached command's `complete(context, text, position)` returns (strings only; others are ignored), where `position` is the argument number being typed;
- for a bound command, the option paths each sub-command accepts (value options for `get`, `set` and `reset`, buttons for `exec`, everything visible for `list`).

Candidates are matched on their start, without case, at most 32 of them. One candidate replaces the word and adds a space; several fill in their longest common start, and when that adds nothing they are listed on the sink. With no candidate, or for any other text, the Tab press goes to the previous handler. An error in a `complete` function is reported to the host error handler and the Tab press goes on to the previous handler.

**How it is installed, and the trade-off.** The client calls `ChatEdit_CustomTabPressed(editBox)` from its tab handler and skips its own completion when it returns `true`; the global is the client's documented extension point and does nothing by itself. A secure post-hook (`hooksecurefunc`) cannot be used, because a post-hook's return value is discarded and the client would complete over CommandKit's result. CommandKit therefore replaces the global once, remembering the previous function and calling it for everything it does not complete — the chain other completion libraries use too. The global becomes addon code; the client calls it through its secure-call wrapper, which keeps that taint away from the rest of its tab handling. When the last scope turns completion off, CommandKit writes the previous function back if its replacement is still the installed one; if another addon has replaced the global since, CommandKit's function stays in that addon's chain, forwarding every call.

## Secret values

On Retail 12.x some client APIs hand addon code secret values (see [`docs/EMBEDDING.md`](../../../docs/EMBEDDING.md#secret-values-retail-12x)). CommandKit asks ClientKit's `IsSecret` when ClientKit is registered, and the host's `issecretvalue` otherwise.

- `context:Print` and `context:Printf` refuse a secret argument (the template included) at the caller: `CommandKit.Context:Print argument 2 must not be a secret value`. A secret never becomes part of chat output by accident.
- `Parse`, `ParseInto`, every name argument, and `Fail`'s reason refuse a secret before comparing it.
- A bound option whose getter returns a secret prints as `(secret value)`.
- A handler failure whose message is secret is written to the sink without the message and handed to the host error handler unchanged.

Text typed by the user never is secret, so dispatch does not probe it.

## Error behaviour

Every argument failure and spec refusal reports the line that called CommandKit, never a line inside it, and names the method and the field by its path in the spec:

```text
MyAddon.lua:12: CommandKit.Scope:Register spec.subcommands.frame.subcommands.show.arguments[1] must be a SchemaKit schema
MyAddon.lua:30: CommandKit.Scope:Register "myaddon" is already registered in this scope; Unregister it first
MyAddon.lua:31: CommandKit.Scope:BindOptions requires OptionsKit API 1
```

Calling a scope method on something that is not a scope raises `CommandKit.Scope:Register must be called on a CommandKit scope`; a facade method called with a dot raises `CommandKit:ForAddon must be called on the CommandKit facade; use CommandKit:ForAddon(...)`; `Register`, `BindOptions` and `EnableCompletion` on a closed scope raise `... cannot be used on a closed scope`.

What the user types is never an error: it is printed to the sink. Errors raised by your handler, `complete` function or sink are isolated during dispatch and completion and reported to the host error handler.

## Performance

| Operation | Cost |
|---|---|
| `Register` | Compiles the spec once; seals and describes each argument schema; scans the slash tables once. |
| Dispatch | One read of the key's name, one of the active command, one per sub-command level; a schema `Check` per argument; the handler under `pcall`. No allocation for text seen before. |
| An unregistered dispatcher | Two table reads; no allocation. |
| `ParseInto` | One pass over the text; only token strings, none for text seen before. |
| `Parse` | As `ParseInto`, plus the array. |
| Usage, bound sub-commands, completion | Allocate; not hot paths. |

## Bounds

| Bound | Value | Refusal |
|---|---|---|
| Top-level commands per scope | 64 (`CommandKit.MAX_COMMANDS`) | `nil, "full"` |
| Sub-command levels | 3 (`CommandKit.MAX_DEPTH`) | `Register` raises |
| Sub-commands per level | 64 | `Register` raises |
| Per-position argument schemas | 16 | `Register` raises |
| Name length | 32 bytes | `Register` raises |
| Nested dispatches | 4 | the fifth prints a message and does nothing |
| Completion candidates | 32 | the rest are not offered |
| Capture sink lines | 256 | the oldest are dropped |
| `SLASH_<key><n>` read per foreign key | 16 | the rest are not read |

## Deviations from the planned contract

The nine-point plan in `docs/ROADMAP.md` is followed except where recorded here:

- **`complete(context, text, position)`** instead of `complete(text)`: a completion function needs the sink and the command path for output, and the argument position to know what to offer.
- **Registration keys are kept per slash name for the session.** The plan derives the key from the addon and command names; the first registration does, and a re-registration of the same name by another owner reuses that key so the client's cached function keeps working.
- **The taken check reads `SlashCmdList` and `SecureCmdList`** and their `SLASH_<key><n>` globals, best effort as documented, rather than every `SLASH_*` global: scanning the global table would be unbounded.
- **`BindOptions` adds `exec`** beside `get`, `set`, `reset` and `list`, honours `confirm` with an explicit word, and parses values per option kind before OptionsKit's schema and `validate` check them; it calls `Describe` once per run.
- **Completion is opt-in per scope** (`EnableCompletion`), because it replaces a client global; the plan made it optional without naming the switch.
- **Additions:** `scope:IsRegistered`, `scope:DisableCompletion`, `scope:GetAddonName`, `CommandKit.MAX_COMMANDS`, `CommandKit.MAX_DEPTH` and the `CommandKit.Context` prototype; argument tokens are converted for number and boolean schemas; textures are single tokens; `Print` writes no prefix.
- **Localised help** is the addon's: usage and description strings are passed in already translated, and `Printf` goes through LocaleKit. CommandKit's own fixed words stay English.

## Embedded copies and upgrades

Several addons may embed CommandKit; Registry selects the newest compatible revision and every copy shares one facade. An upgrade happens in place: scopes, commands, the slash dispatchers already in the client's tables and the completion replacement stay, because every one of them calls through shared package state that the newer copy rewrites. Scopes and contexts gain the newer copy's methods through the shared `CommandKit.Scope` and `CommandKit.Context` prototypes.

Nothing survives `/reload`: commands are registered again when the addon loads.
