# Example addon

A small, complete, runnable World of Warcraft addon that embeds the MoltenCodes
framework and uses it end to end. It exists so that the instructions in
[`../docs/EMBEDDING.md`](../docs/EMBEDDING.md) are demonstrably true rather than
merely written down, and so that a new addon has something real to copy.

```text
examples/
├── ExampleAddon.toc   # the manifest: saved variable, embedded Kits, load order
├── embeds.xml         # every release Kit, in the bundle's load order
├── Core.lua           # framework resolution, lifecycle, the main module
├── Locales/
│   ├── enUS.lua       # the default locale
│   └── deDE.lua       # one translation
├── Settings.lua       # the saved-variable database
├── Options.lua        # the options tree bound to the database
├── Window.lua         # the options tree rendered into a window
├── Commands.lua       # the slash commands
└── tests/             # a Busted spec that loads all of the above
```

## What each file shows

| File | Shows |
|---|---|
| `ExampleAddon.toc` | `## Interface` for every supported client, `## SavedVariables`, `## X-Embeds` naming every embedded Kit, and the load order: `embeds.xml`, then `Core.lua`, then the locales, then the rest. |
| `embeds.xml` | The release bundle's `loadOrder`, all 27 release packages; ApiKit is the one Kit with further files, one per client flavour under `apiKit\flavours\`; the example lists all five, an addon embeds only the flavours it supports. Those this example does not use are marked `optional here`; an addon keeps only what it uses plus its dependencies. TestKit is development-only and never embedded. |
| `Core.lua` | Resolving Registry API 2 and each Kit by API generation; the LifecycleKit and ModuleKit handles; a `ready` phase callback; the `Main` module, whose `module.scope` owns an event, an `EventKit:Coalesce` burst, a timer, a secure hook and the slash commands, all released on disable; a ReadinessKit gate for spell data; a ClientKit capability check. |
| `Locales/enUS.lua` | LocaleKit's default locale, with `L[key] = true`. |
| `Locales/deDE.lua` | A translation that reorders arguments with indexed specifiers (`%4$d`) and leaves some keys to the default. |
| `Settings.lua` | A SettingsKit database over `ExampleAddonDB`, described by a SchemaKit schema with a `global` scope and a `profile`, opened in the `loaded` phase through a ModuleKit singleton, with a versioned migration. |
| `Options.lua` | An OptionsKit tree whose options `bind` to the database, with the ready-made profile group from `OptionsKit:ProfileOptions`. |
| `Window.lua` | WidgetKit rendering the options tree into a `Frame` widget, created on open and released on close. |
| `Commands.lua` | CommandKit: `/exampleaddon`, a command line generated from the options tree by `BindOptions` (`list`, `get`, `set`, `reset`, `exec`), and `/exampleaddonwindow`, which opens and closes the window. |

In the game, `/exampleaddon list` shows the settings, `/exampleaddon set
windowScale 1.25` changes one, `/exampleaddon set profiles.new Raid` creates a
profile and switches to it, and `/exampleaddonwindow` opens the window.

## Running it in a client

Copy this directory to `Interface/AddOns/ExampleAddon/`, then copy the framework
files into `ExampleAddon/Libs/MoltenCodes/` in the layout `embeds.xml` expects.
`python3 -m tooling.package.build --all --out <dir>` produces that layout; see
[`../docs/RELEASES.md`](../docs/RELEASES.md).

`tests/` and `.luarc.json` are development files. Leave them behind.

## Why it cannot rot

`tests/ExampleAddon_spec.lua` reads the load order out of `embeds.xml`, loads
each listed package from its real package source, and then runs every addon
file the `.toc` lists, in `.toc` order, the way the client does — with the addon
name and the addon's private table as each file's `...` vararg. The host is the
shared `FrameworkTestEnv` fixture with the Retail client profile, plus the few
globals only this addon touches (`SlashCmdList`, `DEFAULT_CHAT_FRAME`,
`hooksecurefunc`, `ToggleGameMenu`, `GetLocale`) and a `UIParent` frame for
WidgetKit to rest released widgets on. The spec first checks that every package
`embeds.xml` lists loads, in that order, and then:

- logs in and checks the module is enabled, the database was opened and
  migrated, and the greeting reports the client;
- types `/exampleaddon set ...` through `SlashCmdList` and checks the value
  reached the saved variable, and that an out-of-range value was refused;
- creates, switches and copies profiles through the `ProfileOptions` group,
  with the `confirm` word the copy button asks for;
- opens the window with `/exampleaddonwindow`, closes it through the hooked
  `ToggleGameMenu`, and checks the pooled frame is reused;
- fires a burst of health events and checks they are reported once;
- makes spell data available and checks the ReadinessKit gate opens;
- runs on a German client and checks the translation is used;
- logs out and checks every timer was cancelled, the commands went inert, the
  window was released, and the database was compacted.

Run it from the repository root with the Lua 5.1 toolchain:

```bash
python3 -m tooling.test.run examples
```

`busted examples/tests` runs the same spec directly. `python3 -m unittest
discover -s tooling/tests -p "test_*.py"` runs it too and additionally checks
that the `.toc`, `embeds.xml` and the package manifests still agree about the
load order.

`lua-language-server --check examples --checklevel=Warning` type-checks the
example against the framework's own LuaCATS annotations, so a change that breaks
a published signature breaks the example too. `.luarc.json` lists exactly the
packages `embeds.xml` embeds; `python3 -m tooling.validation.validate_repository`
enforces that.
