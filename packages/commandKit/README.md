# CommandKit

CommandKit gives a World of Warcraft addon its slash commands: registration owned by a scope, an argument parser that keeps quoted text and shift-clicked item links whole, sub-commands with usage text generated from their declarations, arguments checked against SchemaKit schemas, output to a replaceable sink, optional tab completion, and a command line over an OptionsKit tree.

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

Typing `/myaddon` prints the generated usage; `/myaddon scale 3` prints `/myaddon scale: argument 1: expected number <= 2, found larger number` followed by the usage; `/myaddon link` followed by a shift-clicked item receives the whole link as one argument.

What each piece promises:

- **Collision-safe registration.** CommandKit writes `SlashCmdList[<key>]` and `SLASH_<key>1` with a key built from the addon and command names, and returns `nil, "taken"` when another owner or a chat type already uses the slash name, or `nil, "emote"` when an emote does, instead of silently overwriting or shadowing it.
- **A parser that understands WoW text.** `"double"` and `'single'` quotes with `\"` escapes (an unclosed `'` is an apostrophe), `|H…|h[…]|h` hyperlinks, `|c…|r` colour-wrapped text and `|T…|t` textures are single tokens; an unterminated double quote or link is refused with a reason. `CommandKit:ParseInto` fills a caller-owned array and allocates nothing for text it has seen.
- **Declarative sub-commands.** Up to three levels deep, with usage lines generated from the argument schemas (`<number 0.5..2>`, `[TOP|CENTER]`) and descriptions.
- **Two kinds of failure, two channels.** A bad spec raises at your line when you register it; a bad thing the user typed is printed to the sink with the usage. A handler that raises is reported to the sink and to the host error handler.
- **Cheap dispatch.** A slash command allocates nothing when its text has been seen before; the parser has no state outside the call; everything is bounded (64 commands per scope, 3 sub-command levels, 4 nested dispatches).
- **Options from the command line.** `scope:BindOptions(tree, "myaddon_options")` gives `get`, `set`, `reset`, `list` and `exec` over an OptionsKit tree, with values parsed per option kind and the tree's own validation messages.
- **Completion on request.** `scope:EnableCompletion()` completes sub-command names and option paths on Tab through the client's `ChatEdit_CustomTabPressed` extension point.

See [`docs/API.md`](docs/API.md) for the complete contract, and [`docs/INTERNALS.md`](docs/INTERNALS.md) for the parser's state machine and the state layout.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\schemaKit\SchemaKit.lua
Libs\MoltenCodes\commandKit\CommandKit.lua
```

Direct runtime dependencies: Registry API 2 and SchemaKit API 1.
All three files above are required; omitting either of the first two makes this
package raise at load.

Optional, each found with `Registry:Find` when it is used, so they may load in
any order:

- OptionsKit API 1 (and its SignalKit dependency), needed only by
  `scope:BindOptions`;
- LocaleKit API 1, used by `context:Printf` for indexed specifiers such as
  `%2$s`; without it `Printf` uses `string.format`;
- ClientKit API 1, used to recognise a secret value; without it CommandKit asks
  the host's `issecretvalue` directly.

Register commands at load or in your addon's loaded phase. Addon scopes are
closed by whoever observes the addon's shutdown. Without LifecycleKit, close
yours on logout:

```lua
EventKit:Once("PLAYER_LOGOUT", function()
    CommandKit:CloseAddonScopes("MyAddon")
end)
```

Closing leaves the slash name in the client's tables pointing at a dispatcher
that does nothing: the client caches slash functions, so the entry cannot be
removed cleanly. See [`docs/API.md`](docs/API.md#registration).
