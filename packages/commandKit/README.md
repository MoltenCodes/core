# CommandKit

CommandKit gives a World of Warcraft addon its slash commands: registration owned by a scope, an argument parser that keeps quoted text and shift-clicked item links whole, sub-commands with usage text generated from their declarations and output to a replaceable sink in its core; arguments checked against SchemaKit schemas, tab completion and a command line over an OptionsKit tree in optional parts.

```lua
local Registry = MoltenCodes.Registries[2]
local SchemaKit = Registry:Get("schemaKit", 1)
local CommandKit = Registry:Get("commandKit", 1)
local S = SchemaKit

local commands = CommandKit:ForAddon("MyAddon")

commands:Register("myaddon", {
  description = "My Addon commands.",
  subcommands = {
    scale = {
      description = "Set the frame scale.",
      arguments = { S.number({ min = 0.5, max = 2 }) },
      handler = function(context, scale)
        MyAddonFrame:SetScale(scale)
        context:Printf("Scale set to %.2f.", scale)
      end,
    },
    link = {
      description = "Remember an item.",
      arguments = { S.string({ pattern = "^|c.-|Hitem:" }) },
      handler = function(context, itemLink)
        context:Print("Remembered", itemLink)
      end,
    },
  },
})
```

The `arguments` schemas need the Arguments part (`parts/CommandKit-Arguments.lua`) and SchemaKit; without them a command receives its words as strings. Typing `/myaddon` prints the generated usage; `/myaddon scale 3` prints `/myaddon scale: argument 1: expected number <= 2, found larger number` followed by the usage; `/myaddon link` followed by a shift-clicked item receives the whole link as one argument.

What each piece promises:

- **Collision-safe registration.** CommandKit writes `SlashCmdList[<key>]` and `SLASH_<key>1` with a key built from the addon and command names, and returns `nil, "taken"` when another owner or a chat type already uses the slash name, or `nil, "emote"` when an emote does, instead of silently overwriting or shadowing it.
- **A parser that understands WoW text.** `"double"` and `'single'` quotes with `\"` escapes (an unclosed `'` is an apostrophe), `|H…|h[…]|h` hyperlinks, `|c…|r` colour-wrapped text and `|T…|t` textures are single tokens; an unterminated double quote or link is refused with a reason. `CommandKit:ParseInto` fills a caller-owned array and allocates nothing for text it has seen.
- **Declarative sub-commands.** Up to three levels deep, with usage lines generated from the argument schemas (`<number 0.5..2>`, `[TOP|CENTER]`; the Arguments part) and descriptions.
- **Two kinds of failure, two channels.** A bad spec raises at your line when you register it; a bad thing the user typed is printed to the sink with the usage. A handler that raises is reported to the sink and to the host error handler.
- **Cheap dispatch.** A slash command allocates nothing when its text has been seen before, unless a table default is filled (each dispatch gets a fresh copy); the parser has no state outside the call; everything is bounded (64 commands per scope, 3 sub-command levels, 4 nested dispatches).
- **Bounded by default, opened on purpose.** Scope options (`maxCommands`, `maxSubcommands`, `maxPositions`, `maxSlashAliases`), `CommandKit:SetLimits{}` and `CommandKit.UNBOUNDED` lift the defaults where the memory is yours; see [Limits](docs/API.md#limits).
- **Options from the command line** (the Options part). `scope:BindOptions(tree, "myaddon_options")` gives `get`, `set`, `reset`, `list` and `exec` over an OptionsKit tree, with values parsed per option kind and the tree's own validation messages; `{ syntax = "path" }` adds AceConfigCmd's `/myaddon group option value`.
- **Completion on request** (the Completion part). `scope:EnableCompletion()` completes sub-command names and option paths on Tab through the client's `ChatEdit_CustomTabPressed` extension point; `scope:RegisterCompletion(name, pattern, provider)` completes any word of chat input, as AceTab does.
- **A prefix, and printing from anywhere.** `scope:SetPrefix("|cff33ff99MyAddon|r: ")` starts every line with it; `scope:Print` and `scope:Printf` write outside a handler; `scope:Dispatch(name, text)` runs a command from code.

See [`docs/API.md`](docs/API.md) for the complete contract, and [`docs/INTERNALS.md`](docs/INTERNALS.md) for the parser's state machine and the state layout.

### Moving from AceConsole-3.0, AceTab-3.0 and AceConfigCmd-3.0

| Ace3 | CommandKit |
|---|---|
| `self:RegisterChatCommand("myaddon", "SlashCommand")`, which overwrites any earlier owner | `commands:Register("myaddon", { handler = function(context, ...) end })`, which returns `nil, "taken"` or `nil, "emote"` instead of overwriting |
| `func(input, editBox)` receiving the raw text | The handler receives the parsed tokens (or the values its `arguments` schemas accepted); `context:GetRawText()` is the raw text |
| `self:GetArgs(input, 2)` | `CommandKit:Parse(input)` or `CommandKit:ParseInto(input, array)`, which also keep colour-wrapped text and textures whole; usually `arguments` and `subcommands` in the spec make it unnecessary |
| Parsing sub-commands by hand in `SlashCommand` | `subcommands = { show = { ... } }`, up to three levels, with generated usage |
| `self:UnregisterChatCommand("myaddon")` | `commands:Unregister("myaddon")`; the slash name stays bound to an inert dispatcher (see "Inert globals" in the API) |
| `self:Print(...)`, `self:Printf(format, ...)` | `commands:Print(...)`, `commands:Printf(template, ...)` anywhere, or `context:Print`/`Printf` inside a handler; `commands:SetPrefix("|cff33ff99MyAddon|r: ")` for AceConsole's coloured addon name; `scope:SetSink(sink)` for another frame |
| `AceConsole:IterateChatCommands()` | `CommandKit:GetCommands()` (every command in the session) or `commands:GetCommands()` (this scope's), sorted arrays |
| `AceTab:RegisterTabCompletion(...)` for your own command | A `complete` function in the spec, and `commands:EnableCompletion()` (Completion part) |
| `AceTab:RegisterTabCompletion(descriptor, ...)` for any chat input | `commands:RegisterCompletion(name, pattern, provider)` (Completion part): `pattern` is matched against the text before the word, `provider(partial, before, editBox)` returns the candidates; chat edit boxes only |
| `AceConfigCmd:CreateChatCommand("myaddon", "MyAddon")` | `commands:BindOptions(tree, "myaddon", { syntax = "path" })` (Options part): the same `/myaddon group option value` line, plus the `get`/`set`/`reset`/`list`/`exec` verbs |
| `AceConfigCmd:HandleCommand("myaddon", "MyAddon", input)` | `commands:Dispatch("myaddon", input)`; for "an empty line opens the window", `BindOptions(..., { onEmpty = function(context) ... end })` |
| `AceConfigCmd:GetChatCommandOptions("myaddon")` | `commands:GetBoundTree("myaddon")` |

[`docs/MIGRATING_FROM_ACE3.md`](../../docs/MIGRATING_FROM_ACE3.md#aceconsole-30) walks through a whole addon.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\commandKit\CommandKit.lua
Libs\MoltenCodes\schemaKit\SchemaKit.lua                       # with the Arguments part
Libs\MoltenCodes\commandKit\parts\CommandKit-Arguments.lua    # only with argument schemas or BindOptions
Libs\MoltenCodes\signalKit\SignalKit.lua                       # with the Options part
Libs\MoltenCodes\optionsKit\OptionsKit.lua                     # with the Options part
Libs\MoltenCodes\commandKit\parts\CommandKit-Options.lua      # only with BindOptions
Libs\MoltenCodes\commandKit\parts\CommandKit-Completion.lua   # only with completion
```

Minimum footprint: embed 2 files: `registry/Registry.lua`, `commandKit/CommandKit.lua`.
The three parts ([ADR 0001](../../docs/decisions/0001-kit-core-and-parts.md)) are
optional; `python3 -m tooling.package.embeds` writes the list for any selection.
Resident sizes on host Lua 5.1.5 (64-bit, debug information kept, measured
2026-11-18, each file after its dependencies in one process):

| File | Adds | Needs | Resident |
|---|---|---|---:|
| `CommandKit.lua` | registration, parsing, dispatch, sub-commands and usage, sinks | Registry | 113.3 KB |
| `parts/CommandKit-Arguments.lua` | `arguments` schemas: coercion, usage words, refusals | SchemaKit | 12.1 KB |
| `parts/CommandKit-Options.lua` | `BindOptions`, `GetBoundTree` | OptionsKit, the Arguments part | 40.2 KB |
| `parts/CommandKit-Completion.lua` | tab completion and completion providers | nothing more | 19.3 KB |

Direct runtime dependency of the core: Registry API 2; omitting it makes this
package raise at load. The Arguments part needs SchemaKit API 1 and raises at
load without it.

Optional, each found with `Registry:Find` when it is used, so they may load in
any order:

- OptionsKit API 1 (and its SignalKit dependency), needed by the Options part
  (`scope:BindOptions`), which names it as its dependency;
- LocaleKit API 1, used by `context:Printf` for indexed specifiers such as
  `%2$s`; without it `Printf` uses `string.format`;
- LifecycleKit API 1 and EventKit API 1, used to close an addon scope at
  logout (below).

Register commands at load or in your addon's loaded phase. At logout an addon
scope is closed by LifecycleKit, or by CommandKit's own `PLAYER_LOGOUT` watcher
when only EventKit is loaded; with neither, call
`CommandKit:CloseAddonScopes("MyAddon")` yourself (see "At logout" in
[`docs/API.md`](docs/API.md#at-logout)).

Closing leaves the slash name in the client's tables pointing at a dispatcher
that does nothing: the client caches slash functions, so the entry cannot be
removed cleanly. See [`docs/API.md`](docs/API.md#registration).
