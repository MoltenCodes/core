# Embedding the framework in an addon

This is the document for addon authors. It assumes you are writing a World of
Warcraft addon and want to use one or more MoltenCodes Kits inside it. It does
not assume you work on the framework.

A complete, runnable example lives in [`../examples/`](../examples/). Everything
below explains why that example looks the way it does.

## Contents

- [What a Kit is](#what-a-kit-is)
- [The Registry-first rule](#the-registry-first-rule)
- [Directory layout inside your addon](#directory-layout-inside-your-addon)
- [Load order](#load-order)
- [A complete example addon](#a-complete-example-addon)
- [TOC fields and packaging](#toc-fields-and-packaging)
- [Embed or depend](#embed-or-depend)
- [Several addons, several copies](#several-addons-several-copies)
- [Supported client versions](#supported-client-versions)
- [Coexisting with LibStub](#coexisting-with-libstub)
- [Taint](#taint)
- [The combat log](#the-combat-log)
- [`/reload` and saved variables](#reload-and-saved-variables)
- [User interface](#user-interface)
- [Performance guidance](#performance-guidance)
- [Troubleshooting](#troubleshooting)

## What a Kit is

A **Kit** is one independently publishable runtime package: a single Lua file
that publishes one table of functions and nothing else. `SignalKit` is callback
dispatch, `EventKit` is World of Warcraft events, `TimerKit` is timers, and so
on. The complete list is in the [root README](../README.md).

Three properties matter to a consumer:

- **A Kit embeds, and the framework also installs.** You copy a Kit's Lua file
  into your addon and list it in your `.toc`, so your users download nothing
  else; or your addon depends on the installed `MoltenCodes` addon, which
  loads every Kit. Both can be true at once (see [Embed or depend](#embed-or-depend)).
- **A Kit is shared at runtime.** Ten addons can each ship their own copy of
  `SignalKit.lua`. Exactly one of those copies ends up executing, and all ten
  addons use it. That reconciliation is what `Registry` exists for.
- **A Kit declares an API generation and an implementation revision.** The API
  generation is the contract you write against (`EventKit` API 1). The revision
  orders compatible implementations inside that contract. You ask for a
  generation by number; you never ask for a revision.

`Registry` itself is not a Kit. It is the infrastructure that makes the other
points work, and it is the one package every embedding addon must ship.

## The Registry-first rule

> **`Registry.lua` loads before every other MoltenCodes file, always.**

Every Kit resolves its dependencies while its own file is being read. The first
thing each Kit does is look for the `MoltenCodes` global that `Registry.lua`
publishes. If it is not there, the Kit raises at file scope and stops your
addon's load.

This also means the framework creates exactly one global, `MoltenCodes`, plus
one private bootstrap key that is implementation detail and must never be read
or written by an addon. Two Kits write further globals on request and only
when asked: `SettingsKit` writes the saved-variables global your `.toc` names,
and `CommandKit` writes the `SLASH_<key>1` and `SlashCmdList[<key>]` entries
for the commands you register, plus `ChatEdit_CustomTabPressed` when you turn
completion on (see the taint rules below). `ApiKit` publishes one more, the
short `wow` global (`local api = wow.retail.api`), and only when nothing else
owns that name; it never overwrites an existing `wow`, reports the case
through `ApiKit:GetGlobalStatus()`, and the same tables are always reachable
as `MoltenCodes.wow`. Nothing else in the framework writes a global.

The portable access path is:

```lua
local Registry = MoltenCodes.Registry
```

`MoltenCodes.Registry` is an **alias for the newest Registry API generation
loaded in the session**, which is not necessarily the one you wrote against.
Ask for your generation by number instead, and fall back to the alias only for
copies of Registry older than revision 5:

```lua
local generations = MoltenCodes.Registries
local Registry = generations and generations[2] or MoltenCodes.Registry
```

Then take the Kits you need:

```lua
local EventKit = Registry:Get("eventKit", 1)
```

`Registry:Get(packageName, api)` returns the shared package table and the
selected revision, or `nil` when nothing has registered that package and
generation. `nil` always means the same thing: the file is missing from your
`.toc`, or it is listed after the file that asked for it.

## Directory layout inside your addon

Put the framework where it cannot be mistaken for your own code:

```text
Interface/AddOns/MyAddon/
├── MyAddon.toc
├── Libs/
│   └── MoltenCodes/
│       ├── embeds.xml
│       ├── registry/Registry.lua
│       ├── signalKit/SignalKit.lua
│       ├── eventKit/EventKit.lua
│       ├── lifecycleKit/LifecycleKit.lua
│       ├── moduleKit/ModuleKit.lua
│       ├── timerKit/TimerKit.lua
│       └── <one directory per further Kit you embed>
├── Core.lua
├── Locales/
│   └── enUS.lua
└── Modules/
    └── ...
```

One directory per package, named by the package ID (`signalKit`), holding the
Lua file under its facade name (`SignalKit.lua`). That is exactly the layout the
release artifact ships, so installing an update is a directory copy. See
[`RELEASES.md`](RELEASES.md).

Ship only the Kits you use, **plus everything they depend on**. The dependency
graph is in [`ARCHITECTURE.md`](ARCHITECTURE.md); the release artifact's
`manifest.json` lists it machine-readably.

## Load order

The rule is a single sentence: **`Registry.lua` first, then every other package
after the packages it depends on.** The current graph is:

```text
registry
├──→ apiKit (plus its flavour files)
├──→ clientKit
├──→ compatKit
├──→ cacheKit
├──→ profileKit
├──→ schemaKit
│       ├──→ commandKit
│       ├──→ settingsKit   (also needs signalKit)
│       └──→ optionsKit    (also needs signalKit)
├──→ localeKit
├──→ hookKit
├──→ interopKit
├──→ poolKit
│       ├──→ codecKit
│       └──→ widgetKit   (also needs signalKit)
├──→ timerKit
│       ├──→ readinessKit
│       └──→ schedulerKit
│               ├──→ commKit   (also signalKit, eventKit, poolKit)
│               └──→ testKit   (also lifecycleKit; development only, never bundled)
└──→ signalKit
       ├──→ mediaKit
       ├──→ brokerKit
       ├──→ logKit
       ↓
     eventKit
       ↓
   lifecycleKit
    └──→ moduleKit
```

Any order consistent with that graph works. This one is consistent with it and
is what the release artifact's `manifest.json` records under `loadOrder`:

```text
registry/Registry.lua
apiKit/ApiKit.lua
apiKit/flavours/Beta.lua
apiKit/flavours/ClassicEra.lua
apiKit/flavours/ClassicMop.lua
apiKit/flavours/Ptr.lua
apiKit/flavours/Retail.lua
signalKit/SignalKit.lua
brokerKit/BrokerKit.lua
cacheKit/CacheKit.lua
clientKit/ClientKit.lua
poolKit/PoolKit.lua
codecKit/CodecKit.lua
eventKit/EventKit.lua
timerKit/TimerKit.lua
schedulerKit/SchedulerKit.lua
commKit/CommKit.lua
schemaKit/SchemaKit.lua
commandKit/CommandKit.lua
compatKit/CompatKit.lua
hookKit/HookKit.lua
interopKit/InteropKit.lua
lifecycleKit/LifecycleKit.lua
localeKit/LocaleKit.lua
logKit/LogKit.lua
mediaKit/MediaKit.lua
moduleKit/ModuleKit.lua
optionsKit/OptionsKit.lua
profileKit/ProfileKit.lua
readinessKit/ReadinessKit.lua
settingsKit/SettingsKit.lua
widgetKit/WidgetKit.lua
```

You can list the files directly in your `.toc`:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\signalKit\SignalKit.lua
```

or keep them in an `embeds.xml` and list that one file instead. An `embeds.xml`
keeps the framework out of the way of your own file list and is what the example
addon does. Both are equivalent to the client; pick one.

`.xml` paths use backslashes, like `.toc` paths. The client accepts forward
slashes on some platforms and not on others, so use backslashes everywhere.

Every Kit listed above is one file except `apiKit`, which also carries one
generated file per client flavour under `apiKit\flavours\` (`Retail.lua`,
`ClassicEra.lua`, `ClassicMop.lua`, `Ptr.lua`, `Beta.lua`). Embed the facade
and the files of the flavours your addon supports; the rule is the same for
all of them: the Kit's facade first, then the flavour files, in any order
among themselves, because they depend only on the facade:

```text
apiKit/ApiKit.lua
apiKit/flavours/Retail.lua
```


## Minimum footprint per Kit

Registry is the one file every Kit needs, and SignalKit is the accepted second
one for Kits whose contract includes callbacks. Everything else a Kit can use is
optional and found at call time, so embedding one Kit costs this many files:

| Files | Kit | Alongside `registry/Registry.lua` |
|---|---|---|
| 2 | `clientKit`, `cacheKit`, `compatKit`, `profileKit`, `schemaKit`, `localeKit`, `hookKit`, `interopKit`, `poolKit`, `signalKit`, `timerKit` | nothing |
| 3 | `apiKit` | nothing; the third file is the flavour file of the client you support (one more per further flavour) |
| 3 | `codecKit` | `poolKit` |
| 3 | `commandKit` | `schemaKit` |
| 3 | `brokerKit`, `eventKit`, `logKit`, `mediaKit` | `signalKit` |
| 3 | `readinessKit`, `schedulerKit` | `timerKit` |
| 4 | `lifecycleKit` | `signalKit`, `eventKit` |
| 4 | `optionsKit`, `settingsKit` | `schemaKit`, `signalKit` |
| 4 | `widgetKit` | `poolKit`, `signalKit` |
| 5 | `moduleKit` | `signalKit`, `eventKit`, `lifecycleKit` |
| 7 | `commKit` | `signalKit`, `eventKit`, `timerKit`, `schedulerKit`, `poolKit` |
| 7 | `testKit` (development only) | `signalKit`, `eventKit`, `lifecycleKit`, `timerKit`, `schedulerKit` |

The release artifact's `manifest.json` records the same closures, and
`python3 -m tooling.package.build --package <id>` ships exactly that set.

## A complete example addon

The files below are real: they live in [`../examples/`](../examples/), a spec
loads every one of them against stubs on every test run, and
`lua-language-server` type-checks them on every gate run. Copy the directory
into `Interface/AddOns/ExampleAddon/`, drop the framework files into
`Libs/MoltenCodes/`, and it runs. Each file shows one Kit; the map is in
[`../examples/README.md`](../examples/README.md).

### `ExampleAddon.toc`

```toc
## Interface: 120100, 50504, 20506, 11509
## Title: Example Addon
## Notes: A small addon showing how to embed and use the MoltenCodes framework.
## Author: MoltenCodes
## Version: 1.1.0
## SavedVariables: ExampleAddonDB
## IconTexture: Interface\Icons\INV_Misc_Gear_01
## X-Category: Development Tools
## X-License: MIT
## X-Embeds: MoltenCodes-Registry, MoltenCodes-ApiKit, MoltenCodes-SignalKit, MoltenCodes-BrokerKit, MoltenCodes-CacheKit, MoltenCodes-ClientKit, MoltenCodes-PoolKit, MoltenCodes-CodecKit, MoltenCodes-EventKit, MoltenCodes-TimerKit, MoltenCodes-SchedulerKit, MoltenCodes-CommKit, MoltenCodes-SchemaKit, MoltenCodes-CommandKit, MoltenCodes-CompatKit, MoltenCodes-HookKit, MoltenCodes-InteropKit, MoltenCodes-LifecycleKit, MoltenCodes-LocaleKit, MoltenCodes-LogKit, MoltenCodes-MediaKit, MoltenCodes-ModuleKit, MoltenCodes-OptionsKit, MoltenCodes-ProfileKit, MoltenCodes-ReadinessKit, MoltenCodes-SettingsKit, MoltenCodes-WidgetKit

# Embedded framework packages. This file must come first: every package below
# resolves its dependencies at load time and raises if one is missing.
embeds.xml

# Addon code. Core.lua resolves the framework and must come before the rest;
# the locale files must come before the files that read translations.
Core.lua
Locales\enUS.lua
Locales\deDE.lua
Settings.lua
Options.lua
Window.lua
Commands.lua
```

A comma-separated `## Interface` line is the modern way to support several
client flavours from one `.toc`; see
[Supported client versions](#supported-client-versions). `## X-Embeds` is not
read by the client; it is a convention that tells a reviewer, and you in six
months, which libraries are bundled.

### `embeds.xml`

The file follows the release artifact's `loadOrder` exactly. An addon keeps
only what it uses plus dependencies; the Kits marked `optional here` are unused
by the example and are listed so the file is a complete template.

```xml
<Ui xmlns="http://www.blizzard.com/wow/ui/">
    <!--
        Embedded MoltenCodes packages, in the release bundle's `loadOrder`.

        Registry has no dependencies and must load first; everything else
        resolves its dependencies through `MoltenCodes.Registry` while this file
        is being read, so a package listed above its dependency raises at load.

        In a real addon these files live under Libs/MoltenCodes/ and this file
        lives beside them. This example lists every release package so that it
        doubles as the complete list; an addon keeps only the packages it uses,
        plus everything they depend on. Those marked "optional here" are not
        used by this example and can be removed from a copy of it.
    -->
    <Script file="Libs\MoltenCodes\registry\Registry.lua" />
    <Script file="Libs\MoltenCodes\apiKit\ApiKit.lua" /> <!-- optional here -->
    <Script file="Libs\MoltenCodes\apiKit\flavours\Beta.lua" /> <!-- optional here; an addon embeds only the flavours it supports -->
    <Script file="Libs\MoltenCodes\apiKit\flavours\ClassicEra.lua" /> <!-- optional here -->
    <Script file="Libs\MoltenCodes\apiKit\flavours\ClassicMop.lua" /> <!-- optional here -->
    <Script file="Libs\MoltenCodes\apiKit\flavours\Ptr.lua" /> <!-- optional here -->
    <Script file="Libs\MoltenCodes\apiKit\flavours\Retail.lua" /> <!-- optional here -->
    <Script file="Libs\MoltenCodes\signalKit\SignalKit.lua" />
    <Script file="Libs\MoltenCodes\brokerKit\BrokerKit.lua" /> <!-- optional here -->
    <Script file="Libs\MoltenCodes\cacheKit\CacheKit.lua" /> <!-- optional here -->
    <Script file="Libs\MoltenCodes\clientKit\ClientKit.lua" />
    <Script file="Libs\MoltenCodes\poolKit\PoolKit.lua" /> <!-- WidgetKit needs it -->
    <Script file="Libs\MoltenCodes\codecKit\CodecKit.lua" /> <!-- optional here -->
    <Script file="Libs\MoltenCodes\eventKit\EventKit.lua" />
    <Script file="Libs\MoltenCodes\timerKit\TimerKit.lua" /> <!-- module scope timers; ReadinessKit needs it -->
    <Script file="Libs\MoltenCodes\schedulerKit\SchedulerKit.lua" /> <!-- EventKit:Coalesce needs it -->
    <Script file="Libs\MoltenCodes\commKit\CommKit.lua" /> <!-- optional here -->
    <Script file="Libs\MoltenCodes\schemaKit\SchemaKit.lua" />
    <Script file="Libs\MoltenCodes\commandKit\CommandKit.lua" />
    <Script file="Libs\MoltenCodes\compatKit\CompatKit.lua" /> <!-- optional here -->
    <Script file="Libs\MoltenCodes\hookKit\HookKit.lua" /> <!-- module scope hooks -->
    <Script file="Libs\MoltenCodes\interopKit\InteropKit.lua" /> <!-- optional here -->
    <Script file="Libs\MoltenCodes\lifecycleKit\LifecycleKit.lua" />
    <Script file="Libs\MoltenCodes\localeKit\LocaleKit.lua" />
    <Script file="Libs\MoltenCodes\logKit\LogKit.lua" /> <!-- optional here -->
    <Script file="Libs\MoltenCodes\mediaKit\MediaKit.lua" /> <!-- optional here -->
    <Script file="Libs\MoltenCodes\moduleKit\ModuleKit.lua" />
    <Script file="Libs\MoltenCodes\optionsKit\OptionsKit.lua" />
    <Script file="Libs\MoltenCodes\profileKit\ProfileKit.lua" /> <!-- optional here -->
    <Script file="Libs\MoltenCodes\readinessKit\ReadinessKit.lua" />
    <Script file="Libs\MoltenCodes\settingsKit\SettingsKit.lua" />
    <Script file="Libs\MoltenCodes\widgetKit\WidgetKit.lua" />
</Ui>
```

### `Core.lua`

The full file is [`../examples/Core.lua`](../examples/Core.lua); the other
files each show one Kit. Its shape is:

```lua
-- WoW passes every addon file its addon name and a private shared table.
local ADDON_NAME, ADDON_TABLE = ...
local Registry = MoltenCodes.Registries[2]
local LifecycleKit = Registry:Get("lifecycleKit", 1)
local ModuleKit = Registry:Get("moduleKit", 1)

-- Both are keyed by the addon folder name, which is what `...` gives you.
local lifecycle = LifecycleKit:ForAddon(ADDON_NAME)
local modules = ModuleKit:ForAddon(ADDON_NAME)

modules:CreateModule("Main", {
  inject = {
    database = "Database",
    options = "Options",
    window = "Window",
    registerCommands = "RegisterCommands",
  },

  onEnable = function(self)
    -- Everything registered through the scope is released on disable.
    local scope = self.scope
    scope.Events:Connect("PLAYER_ENTERING_WORLD", function() end)
    scope.Events:Coalesce({ "UNIT_HEALTH", "UNIT_MAXHEALTH" }, 0.5, function(units)
      -- One callback per burst, with the set of units that changed.
    end, { units = { "player" } })
    scope.Timers:Every(60, function() end)
    scope.Hooks:SecureHook("ToggleGameMenu", function()
      self.window:Hide()
    end)
    self.registerCommands(scope.Commands, self.options, self.window)
  end,

  onDisable = function(self)
    -- Widgets and readiness gates are not scope-owned; close them here.
    self.window:Hide()
  end,
})

lifecycle:OnReady(function() end)
```

Four things are worth pointing out:

- **`...` is the addon name.** `LifecycleKit:ForAddon`, `ModuleKit:ForAddon` and
  `LocaleKit:GetLocale` key their per-addon state by the folder name exactly as
  the client reports it in `ADDON_LOADED`. Passing the `...` vararg means you
  cannot get it wrong, and it survives your addon being renamed.
- **You do not drive the lifecycle yourself.** ModuleKit binds the container to
  your LifecycleKit instance: modules are initialized when the addon's
  `ADDON_LOADED` completes, enabled when the player logs in, and disabled on
  `PLAYER_LOGOUT`. Nothing in `Core.lua` calls `InitializeAll`.
- **Late is fine.** LifecycleKit phases are replay-aware: a callback registered
  after its phase already happened runs immediately instead of never. You do not
  have to race the client's events.
- **Scopes clean up.** Anything registered through `module.scope` (events,
  timers, hooks, commands, messages, comm prefixes, scheduler jobs) is released
  when the module is disabled, including at logout, so a module writes no
  teardown for them.

## TOC fields and packaging

### The fields the client and the addon sites read

Your `.toc` is read by three different consumers: the game client, the BigWigs
packager that builds your upload, and the addon sites and addon managers that
display it. Which field matters to whom:

| Field | Read by | What it does |
|---|---|---|
| `## Interface` | client, packager | The client versions the `.toc` is written for. The packager also turns every number into a supported game version when it uploads. See [Supported client versions](#supported-client-versions). |
| `## IconTexture` | client | The icon shown next to your addon in the in-game addon list, as a texture path or a FileDataID. |
| `## Version` | client, addon managers | Your version string. Write `## Version: @project-version@` and the packager substitutes the tag (or a commit-based version for untagged builds) when it builds the zip; an unpackaged checkout shows the literal placeholder. |
| `## X-Curse-Project-ID` | packager | The CurseForge project the packager uploads to. |
| `## X-Wago-ID` | packager | The Wago Addons project the packager uploads to. |
| `## X-WoWI-ID` | packager | The WoWInterface addon ID the packager uploads to. |
| `## X-Flavor` | people | A label naming the flavour a per-flavour `.toc` targets. Neither the client nor the packager reads it; flavour selection comes from the Interface numbers and the `_Mainline` / `_Mists` / `_TBC` / `_Vanilla` file suffixes. |
| `## X-Category` | people, some addon managers | A free-text category. The addon sites take the real category from the project page, not from the `.toc`. |
| `## X-Website` | people, some addon managers | A link to the addon's home page or repository. |
| `## X-Embeds` | people | Which libraries are bundled. A convention, as described above. |

The three project IDs only matter once the projects exist on the sites; leave
them out until then rather than inventing placeholders, because a wrong ID
uploads to somebody else's project or fails the build.

### `## Dependencies` and `## OptionalDeps` with embedded Kits

**An addon that embeds its Kits needs neither field for them.** Whether your
copy of a Kit loads before or after another addon's copy makes no difference to
correctness: Registry selects the highest revision whichever order the copies
arrive in, and every addon ends up with the same shared table (see
[Several addons, several copies](#several-addons-several-copies)).

**An addon that relies on the installed `MoltenCodes` addon declares
`## OptionalDeps: MoltenCodes`**, so the client loads it first when it is
present and still loads your addon when it is not. `## Dependencies:
MoltenCodes` (or `## RequiredDeps`) is for an addon that ships no embedded copy
and must not run without the framework; the client then disables the addon when
`MoltenCodes` is missing, which is a worse experience than embedding a copy. The
whole choice is laid out in [Embed or depend](#embed-or-depend).

### Pulling the Kits in with the packager (`externals`)

Copying the Kits by hand, as the example addon does, is always supported. If you
build your releases with the BigWigs packager, you can instead let it fetch the
Kits at build time with `externals` in your addon's `.pkgmeta`, so your
repository holds only your own code.

> **Not yet available.** The framework repository is not published yet, so the
> URL below does not resolve today. The form is documented now so that nothing
> about your layout has to change when it is.

Each package is tagged separately (`<package>-v<version>`, see
[`RELEASES.md`](RELEASES.md)), and each external takes one package's `src/`
directory into the same `Libs/MoltenCodes/<packageId>/` directory a manual copy
uses:

```yaml
externals:
  Libs/MoltenCodes/registry:
    url: https://github.com/MoltenCodes/core
    tag: registry-v1.0.0
    path: packages/registry/src
  Libs/MoltenCodes/signalKit:
    url: https://github.com/MoltenCodes/core
    tag: signalKit-v1.0.0
    path: packages/signalKit/src
  Libs/MoltenCodes/eventKit:
    url: https://github.com/MoltenCodes/core
    tag: eventKit-v1.0.0
    path: packages/eventKit/src
```

Three things to keep in mind:

- **Pin a tag, never a branch.** A tag is the version you tested against; a
  branch is whatever was pushed last. The tags above are illustrations: use the
  release you actually tested.
- **List the dependency closure yourself.** The packager fetches exactly what
  you name. A Kit whose dependency is missing raises at load, with the messages
  in [Troubleshooting](#troubleshooting).
- **The load order is still yours.** `externals` puts the files on disk; your
  `.toc` or `embeds.xml` still lists them, Registry first.

## Embed or depend

There are two ways to give your addon the framework, and Registry lets them
coexist in one session.

**Embed.** Copy the Kits you use into `Libs/MoltenCodes/` and list them in your
`.toc` in load order, as the rest of this document describes. Your addon works
with nothing else installed, and you control which revision you ship.

**Depend.** The release artifact also installs as a standalone addon named
`MoltenCodes`, which loads every release Kit in order (a single-Kit release
installs as `MoltenCodes-<Facade>`, for example `MoltenCodes-TimerKit`, and
loads that Kit with its dependencies). An addon that relies on it declares:

```toc
## OptionalDeps: MoltenCodes
```

`OptionalDeps` makes the client load `MoltenCodes` before your addon when it is
installed and load your addon anyway when it is not. Use `## Dependencies` only
if your addon must refuse to load without the framework, because the client
then disables your addon outright when `MoltenCodes` is missing; a friendlier
addon embeds a copy as well and lists both.

**Both at once.** An addon that embeds Kits while the standalone addon is also
installed is the normal case the design was built for: the copies bootstrap
through one Registry, the highest revision of each Kit wins in place, and every
consumer keeps the table it already holds (see
[Several addons, several copies](#several-addons-several-copies)). Two things
follow for you as an author: never cache individual methods off a Kit, only the
Kit table, and never assume your embedded copy is the one running, because a
newer standalone install may have upgraded it. That is also why an embedded
Kit reads its own revision through the Registry rather than a constant.

**Which to choose.** Embed when you ship to users who install one addon and
expect it to work; depend when you write for a community that already installs
`MoltenCodes`, or when several of your addons would otherwise carry the same
Kits. Libraries you publish for other authors should embed, so they impose no
install step.

## Several addons, several copies

Assume three addons ship `SignalKit.lua`: one at revision 1, two at revision 2.
The client loads them in whatever order it likes.

What happens is:

1. The first `Registry.lua` to load creates the shared bootstrap state and
   publishes `MoltenCodes`. Every later copy of `Registry.lua` finds that state
   and reuses it, so there is one Registry per API generation, not one per addon.
2. The first `SignalKit.lua` to load asks Registry for initialization rights,
   gets a **new, empty shared table**, and fills it in.
3. A later copy carrying a **higher** revision asks for the same rights, and
   receives **the same table** plus the revision it is replacing. It overwrites
   the methods in place.
4. A later copy carrying an **equal or lower** revision is refused, receives
   `nil`, and returns without touching anything.

The consequence that matters: the table identity never changes. An addon that
did `local SignalKit = Registry:Get("signalKit", 1)` early keeps a reference that
is still correct after a newer revision from a different addon upgrades it. You
never need to re-fetch, and you must never cache individual methods off a Kit —
cache the Kit table, call methods through it.

Two different **API generations** of the same package do not merge. They are
separate identities: `Registry:Get("eventKit", 1)` and
`Registry:Get("eventKit", 2)` are two different tables, both live, neither
displacing the other. Two Registry generations likewise coexist, each published
at `MoltenCodes.Registries[<generation>]`, with `MoltenCodes.Registry` aliasing
the newest. This is why you ask for your generation by number: an addon written
against generation 2 is never handed generation 3's contract.

The full rules are in
[`../packages/registry/docs/API.md`](../packages/registry/docs/API.md).

## Supported client versions

Interface numbers verified on **2026-09-23** against
`Template:LatestPatchInfo` on warcraft.wiki.gg. The wiki can lag a hotfix, so the
ground truth on any machine is `/dump (select(4, GetBuildInfo()))` typed into
that client.

The numbers are kept in one machine-readable table,
[`tooling/validation/supported_clients.json`](../tooling/validation/supported_clients.json).
Repository validation fails when the table below, the example addon's `.toc` or
any `## Interface` line quoted in the documentation disagrees with it, and
`python3 -m tooling.validation.interface_numbers` prints the line to paste into
your own `.toc`:

```toc
## Interface: 120100, 50504, 20506, 11509
```

| Flavour | `## Interface` | Patch | Packager TOC suffix |
|---|---|---|---|
| Retail (Midnight) | `120100` | 12.1.0 | `_Mainline` |
| Mists of Pandaria Classic | `50504` | 5.5.4 | `_Mists` |
| Burning Crusade Classic (Anniversary) | `20506` | 2.5.6 | `_TBC` |
| Classic Era (also Hardcore, Season of Discovery) | `11509` | 1.15.9 | `_Vanilla` |

Hardcore and Season of Discovery are not separate TOC flavours; they run on
Classic Era's number.

Two more flavours exist and are deliberately **not** listed above. "Forever"
(the Classic+ client, packager suffix `_Camelot`; the wiki listed `16001` on
2026-09-23) is new enough that the framework has not been considered against it,
and the Chinese Titan Reforged client (`38002`) is region-locked. If you target
either, verify the number against the current client rather than copying one
from here.

Cataclysm Classic (`40402`) and Wrath Classic (`30405`) are superseded by Mists
of Pandaria Classic and are listed here only so an old `.toc` is recognisable.

### What the framework promises

The framework **promises to run on Retail, on the current Classic progression
client, and on Classic Era**, and those are the flavours a change is considered
against.

It **does not exclude** any other client that provides the API surface the Kits
actually touch, which is deliberately small:

| Kit | Requires | Degrades gracefully without |
|---|---|---|
| `registry`, `poolKit` | nothing but Lua 5.1 | — |
| `moduleKit` | LifecycleKit's surface | HookKit, CommandKit, CommKit, TimerKit and SchedulerKit API 1, EventKit scopes and SignalKit buses through `Registry:Find` (a missing Kit leaves that `module.scope` field `nil`); SchemaKit API 1 through `Registry:Find` (a schema passed as `implements` is refused at the caller when it is absent) |
| `signalKit` | nothing but Lua 5.1 | `securecallfunction` (bus deliveries fall back to `xpcall`), `geterrorhandler` (falls back to `print`), `issecretvalue` (only guards a validator's refusal reason); LifecycleKit and EventKit API 1 through `Registry:Find` decide who closes an addon bus at logout (with neither, call `SignalKit:CloseAddonBus` on `PLAYER_LOGOUT`) |
| `schemaKit` | nothing but Lua 5.1 | `issecretvalue` (looked up at every check; absent: nothing is treated as secret) |
| `localeKit` | nothing but Lua 5.1 | `GetLocale` (client locale `enUS`), `geterrorhandler` (missing-key reports fall back to `print`), `issecretvalue` (`Format` and missing-key reads treat nothing as secret) |
| `settingsKit` | SchemaKit's and SignalKit's surfaces | `UnitName` and `GetRealmName` (`db.char`, and `db.realm` without `GetRealmName`, unavailable), `UnitClass` (`db.class` unavailable), `UnitFactionGroup` (`db.faction` unavailable); an unavailable scope raises at the reader; `issecretvalue` (nothing treated as secret), `geterrorhandler` (`print`), EventKit API 1 through `Registry:Find` (no compaction at `PLAYER_LOGOUT`; call `db:Compact()`) |
| `optionsKit` | SchemaKit's and SignalKit's surfaces | `issecretvalue` (looked up at every call; absent: nothing is treated as secret), SettingsKit API 1 through `Registry:Find` (`Define` with `options.db` and `ProfileOptions` raise; `get`/`set` options unaffected); `UnitName` / `GetRealmName` (`ProfileOptions` then offers no per-character profile choice) |
| `commandKit` | SchemaKit's surface; `SlashCmdList` (`Register` and `BindOptions` raise at the caller) | `SLASH_<key><n>`, `SecureCmdList`, `ChatTypeInfo`, `EMOTE<n>_CMD<m>` and `MAXEMOTEINDEX` (the taken check finds nothing), `DEFAULT_CHAT_FRAME` (`print`), `ChatEdit_CustomTabPressed` (`EnableCompletion` returns `false`), `ChatEdit_GetActiveWindow`, `geterrorhandler` (`print`), ClientKit API 1 / `issecretvalue`, OptionsKit API 1 (`BindOptions` raises), LocaleKit API 1 (`Printf` uses `string.format`); LifecycleKit and EventKit API 1 through `Registry:Find` decide who closes an addon scope at logout (with neither, call `CommandKit:CloseAddonScopes` on `PLAYER_LOGOUT`) |
| `codecKit` | PoolKit's surface | SchedulerKit API 1 through `Registry:Find` (`EncodeAsync` and `DecodeAsync` raise at the caller), `issecretvalue` (looked up at every call; absent: nothing is treated as secret) |
| `interopKit` | nothing but Lua 5.1 | `LibStub` (every call returns `"absent"`), `issecretvalue` (nothing treated as secret) |
| `brokerKit` | SignalKit's surface | `issecretvalue` (nothing is secret), `LibStub` and LibDataBroker-1.1 (`ExposeToLibDataBroker` and `AdoptFromLibDataBroker` return `false, "absent"`) |
| `logKit` | SignalKit's surface (`NewJournal`, `GetLimits`; `maxJournalArguments` at least 4) | `GetTimePreciseSec` (record `time` is `false`), `issecretvalue` (nothing secret), `geterrorhandler` (failing sinks, format errors and refused journal firings fall back to `print`, also when the handler raises), `DEFAULT_CHAT_FRAME` (`ChatSink` prints), `SlashCmdList` (`RegisterCommand` returns `false, "unavailable"`), CommandKit API 1 through `Registry:Find` (`RegisterCommand` returns `false, "absent"`), SettingsKit API 1 through `Registry:Find` (`BindLevels` raises at the caller) |
| `mediaKit` | SignalKit's surface | `GetLocale` (the client writes Latin), `issecretvalue` (nothing is secret), `LibStub` and LibSharedMedia-3.0 (`AdoptLibSharedMedia` and `MirrorToLibSharedMedia` return `false, "absent"`) |
| `testKit` (development only) | LifecycleKit's and SchedulerKit's surfaces | `issecretvalue` (nothing treated as secret), `issecurevariable` (`ToBeSecure` fails), `GetTimePreciseSec` (`durationMs` 0), `geterrorhandler` (`print`), EventKit and TimerKit API 1 through `Registry:Find` |
| `commKit` | SignalKit's, EventKit's, TimerKit's, SchedulerKit's and PoolKit's surfaces; `GetTimePreciseSec`; `C_ChatInfo.SendAddonMessage` (legacy global fallback; else `Send` refuses `"unavailable"`) | `C_ChatInfo.RegisterAddonMessagePrefix` and `IsAddonMessagePrefixRegistered` (legacy globals, then nothing registered), `C_ChatInfo.SendAddonMessageLogged` (logged sends refused), the events `CHAT_MSG_ADDON`, `CHAT_MSG_ADDON_LOGGED`, `GROUP_ROSTER_UPDATE`, `PLAYER_ENTERING_WORLD`, `GetFramerate` (no low-frame-rate mode), `UnitInParty` and `UnitInRaid` (no roster eviction; streams still expire), `Enum` (12.x values assumed), `securecallfunction` (`pcall`), `issecretvalue`, `geterrorhandler` (`print`), CodecKit API 1 (`SyncSet` raises), HookKit API 1 (outside traffic uncharged), SchemaKit API 1 (`schema` raises); LifecycleKit API 1 through `Registry:Find` (otherwise CommKit's own `PLAYER_LOGOUT` watcher closes its addon scopes) |
| `widgetKit` | PoolKit's and SignalKit's surfaces; `CreateFrame` | `UIParent` (released frames rest on a hidden holder), `issecretvalue` (nothing secret), `geterrorhandler` (`print`), `ColorPickerFrame:SetupColorPickerAndShow` (a click fires the current colour), `IsAltKeyDown`, `IsControlKeyDown`, `IsShiftKeyDown` (no modifiers), OptionsKit API 1 through `Registry:Find` (`RenderOptions` raises at the caller), SchedulerKit API 1 (saves are immediate), MediaKit API 1 (`CreateMediaPicker` raises; the renderer uses the option's `values`) |
| `hookKit` | nothing but Lua 5.1 | `hooksecurefunc` (`SecureHook` raises at the caller), `issecurevariable` (nothing treated as secure), `Frame:HookScript` / `Frame:GetScript` / `Frame:SetScript` (the matching script hooks raise at the caller), `Frame:IsProtected` (frame not protected), `InCombatLockdown` (never in combat), ClientKit API 1 (`issecretvalue`); LifecycleKit and EventKit API 1 through `Registry:Find` decide who closes an addon scope at logout (with neither, call `HookKit:CloseAddonScopes` on `PLAYER_LOGOUT`) |
| `eventKit` | `CreateFrame`, `Frame:RegisterEvent`, `Frame:RegisterUnitEvent`, `Frame:UnregisterEvent`, `Frame:SetScript`; `CombatLogGetCurrentEventInfo`, or `C_CombatLog.GetCurrentEventInfo` without it, for `ConnectCombatLog` alone (with neither, as on retail 12, `IsCombatLogAvailable()` answers `false` and `ConnectCombatLog` raises at the caller) | `C_EventUtils.IsEventValid` (unknown event names reach `RegisterEvent` instead of being refused at the caller), `securecallfunction` (falls back to `xpcall`), `geterrorhandler` (falls back to `print`), SchedulerKit API 1 through `Registry:Find` (`Coalesce` refused, `Derive` recomputes synchronously); LifecycleKit API 1 through `Registry:Find` (addon scopes close at logout either way: through LifecycleKit when loaded, otherwise through EventKit's own `PLAYER_LOGOUT` listener) |
| `lifecycleKit` | EventKit's surface; the events `ADDON_LOADED`, `PLAYER_LOGIN`, `PLAYER_LOGOUT`, `PLAYER_REGEN_DISABLED`, `PLAYER_REGEN_ENABLED` | `C_AddOns.IsAddOnLoaded` (falls back to the legacy global), `IsLoggedIn`, `InCombatLockdown` (absent: never in combat), TimerKit, SchedulerKit, HookKit, CommandKit and CommKit API 1 through `Registry:Find` (at logout the addon's TimerKit, SchedulerKit, EventKit, HookKit, CommandKit and CommKit scopes and then its SignalKit bus are closed, in that order); publishes the read-only `LifecycleKit.CLOSES_ADDON_SCOPES` naming the seven packages it closes at shutdown, and pairs with any revision of them |
| `readinessKit` | TimerKit's surface | `GetTimePreciseSec` (negative cache disabled, timeouts counted in polls), EventKit API 1 through `Registry:Find` (`gate:ReprobeOn` raises at the caller), `geterrorhandler` (probe and waiter failures fall back to `print`) |
| `timerKit` | `C_Timer.NewTimer`, `C_Timer.NewTicker` | `GetTimePreciseSec` (`GetRemaining` and `GetDeadline` then return `nil`); LifecycleKit and EventKit API 1 through `Registry:Find` decide who closes the addon scope at logout (with neither, call `TimerKit:CloseAddonScopes` on `PLAYER_LOGOUT`) |
| `apiKit` | nothing but Lua 5.1 | `WOW_PROJECT_ID`, `IsTestBuild`, `IsBetaBuild` (a client matching no flavour is `"unsupported"` and gets no surface); every namespace or function the running build lacks is simply absent from the wrapper; the `wow` global when another addon owns it (`GetGlobalStatus` says `"taken"`; use `MoltenCodes.wow`) |
| `compatKit` | nothing but Lua 5.1 | `issecretvalue` (nothing treated as secret), `geterrorhandler` (failing shims and probes fall back to `print`), ClientKit API 1 through `Registry:Find` (`context.flavour` is `false` and every shim applies whatever its `flavours`), ApiKit API 1 with the client's flavour file through `Registry:Find` (`context.hasApi` answers `false` for every name; a shim record's `missing` stays `false`) |
| `clientKit` | nothing but Lua 5.1 | `WOW_PROJECT_ID` (flavour `"classic"`), `C_AddOns.GetAddOnMetadata` / `GetAddOnMetadata` (`GetManifest` answers `nil, "unavailable"`), `GetLocale` (no localized `Title`/`Notes` fallback), `C_AddOns.GetAddOnInfo` / `GetAddOnInfo` (an addon is recognised by a readable `## Title`), `GetBuildInfo` (interface `0`), `issecretvalue` (`IsSecret` false), `C_EventUtils.IsEventValid` (`IsEventValid` nil), `IsForbidden` / `CanBeAccessedInContext` (`CanAccessFrame` true), `C_AddOns` / `C_Spell` / `C_Item` (legacy globals, then nil or false); any other probed facility (`Has` answers `false`) |
| `cacheKit` | nothing but Lua 5.1 | `GetTimePreciseSec` (age limits disabled: TTL caches never expire and `PutNegative` entries never lapse), EventKit API 1 (`cache:ClearOn` raises at the caller), `issecretvalue` (snapshot `fill` treats nothing as secret) |
| `profileKit` | nothing but Lua 5.1 | `debugprofilestop` (`Enable` returns `false, "unavailable"`) |
| `schedulerKit` | TimerKit's surface, `CreateFrame`, `GetTimePreciseSec` | `debugprofilestop` (falls back to the wall clock), `debug.traceback` or the client's `debugstack`, the one the Retail client has (with neither, failures report the error value only); LifecycleKit is not needed: it calls `SchedulerKit:CloseAddonScopes` at logout when both are present; LifecycleKit and EventKit API 1 through `Registry:Find` decide who closes the addon scope at logout (with neither, call `SchedulerKit:CloseAddonScopes` on `PLAYER_LOGOUT`) |

Runtime code stays Lua 5.1-compatible because that is what every client runs.
A Kit that needed a newer client facility would need a new API generation, not a
revision.

## Coexisting with LibStub

**The Registry is not LibStub.** They solve the same problem in different
ways. LibStub keys a library by name and a single integer minor version, and
hands out one table per name. Registry keys a package by `(name, API
generation)`, orders implementations inside a generation by revision, and never
replaces the table it handed out. The two live side by side in one addon with
nothing special: they are different globals (`LibStub` and `MoltenCodes`) with
different state, so embedding Ace3 and MoltenCodes together only means listing
each library's files in your `.toc` in its own required order. The framework
never requires LibStub to be present.

**The shipped bridge is `InteropKit`** (package `interopKit`). Without it, no
Kit is a LibStub library: `LibStub("MoltenCodes-EventKit-1")` returns `nil`.
With it:

```lua
local InteropKit = MoltenCodes.Registries[2]:Get("interopKit", 1)

-- Publish one Kit, or every active Kit, to LibStub consumers.
InteropKit:ExposeToLibStub("eventKit", 1)   -- LibStub("MoltenCodes-EventKit-1")
InteropKit:ExposeAll()

-- Read a LibStub library with Registry:Find's silent contract.
local LDB = InteropKit:AdoptFromLibStub("LibDataBroker-1.1")
```

The major is `MoltenCodes-<Facade>-<api>` and the minor is the implementation
revision, so a newer embedded copy raises the minor exactly as LibStub expects.
A major another library already holds is refused, never overwritten. The
bridge's only write into LibStub's tables is replacing the table
`LibStub:NewLibrary` just created with the shared Kit facade, so consumers get
the same table Registry hands out, the one that stays valid across revision
upgrades. Store that table, never individual methods off it. The exact contract
is in [`interopKit/docs/API.md`](../packages/interopKit/docs/API.md).

Three Kits read LibStub libraries themselves, at call time and only when asked:
`MediaKit` adopts and mirrors LibSharedMedia-3.0, `BrokerKit` exposes into and
adopts from LibDataBroker-1.1, and `InteropKit` is the bridge above. Every other
Kit ignores LibStub.

## Taint

EventKit is a **shared event bus**: one Frame serves every addon in the session
that subscribed to a given event, and one dispatch walks every listener. That
has two consequences you must design around.

**Your handler inherits the taint of whoever fired the event, and of whoever ran
before you in the same dispatch.** If an insecure addon's listener runs first,
the dispatch it returns into is tainted, and so is every listener after it. On
clients that publish `securecallfunction`, EventKit calls each listener through
it precisely to keep one listener's taint out of the next; on clients that do
not, the `xpcall` fallback isolates *errors* but not taint. Either way you
cannot assume a clean execution path.

**No Kit calls a protected function, and neither should your listener.** An
EventKit listener is never a secure execution path, whichever addon happened to
load EventKit. Protected actions — anything the client refuses from insecure
code — belong in a secure template or in a hardware-event handler that your addon
owns directly.

Registration itself is not protected. `CreateFrame("Frame")`,
`Frame:RegisterEvent` and `Frame:RegisterUnitEvent` on an addon-created frame are
safe from any code, which is why EventKit can create frames lazily.

A listener that raises is reported through `geterrorhandler()` and delivery
continues to the listeners behind it. That is a deliberate multi-tenant
guarantee: your bug must not silence someone else's addon. It also means a
listener error does **not** propagate to your code, so check the error frame
rather than expecting a `pcall` to catch it.

### Secret values (Retail 12.x)

The rules below follow the warcraft.wiki.gg page
[Secret Values](https://warcraft.wiki.gg/wiki/Secret_Values), re-read on
2026-09-23; when the two disagree, the page wins, except where the measurements
recorded below show what the client itself did.

Since patch 12.0.0, some Retail APIs hand addon code **secret values** instead of
ordinary ones while restrictions apply — in combat and in instanced content, and
most visibly on unit and aura APIs: names, health, aura data, and in some cases
the unit token an event carries. A secret looks like an ordinary string, number
or boolean, but tainted code may not look inside it. Each of these raises an
immediate Lua error at the line that tries it:

- comparing it with a value of its own type (`==`, `~=`, `<`, `<=`, …), and
  `rawequal` too: a secret number against a number, a secret string against a
  string, a secret against itself;
- a boolean test on a secret *boolean* (`if secret then`);
- arithmetic on it;
- the length operator (`#secret`);
- indexing into it or assigning through it (`secret.foo`, `secret["foo"] = 1`);
- calling it as a function;
- using it as a table *key*, to read (`plainTable[secret]`) as well as to
  store.

What stays allowed:

- storing it in a local, an upvalue or as a table *value*, and passing it to
  Lua functions (`select("#", secret)` counts it);
- comparing it with `nil` or with a value of another type (`secret == nil`,
  `rawequal(secret, {})`): the answer is `false`, without an error;
- concatenating secret strings and numbers, and passing secrets to
  `string.format`, `string.concat` and `string.join`. The result is itself a
  secret string, with every restriction above;
- `type(secret)`, which returns the real type;
- a boolean test on a secret that is not a boolean: `nil` is false and every
  other type is true, because the type is not secret.

Which client APIs accept a secret argument is documented per API on the wiki;
do not assume one does.

**Measured on the client.** On Retail 12.1.0 build 69933 (2026-09-24), with a
secret made by `secretwrap(42)`, the in-game suites logged:

| Operation | Result |
|-----------|--------|
| `type(secret)` | `"number"`, the underlying type |
| `rawequal(secret, secret)` | raises `attempt to compare a secret number value (execution tainted by '<addon>')` |
| `rawequal(secret, {})`, `rawequal({}, secret)` | `false`, no error |
| `secret == nil`, `type(secret) == "nil"` | `false`, no error |
| `policy ~= "automatic"` with a secret string `policy` (an earlier run, inside ModuleKit) | raises `attempt to compare local 'policy' (a secret string value, while execution tainted by 'MoltenCodes')` |
| `plainTable[secret]` | raises `attempted to index a table that cannot be indexed with secret keys` |
| `readTable[secret]` on a table whose metatable has `__index` (a LocaleKit read table) | raises the same at the indexing line, before `__index` runs |
| `if result then` with `result = secretwrap(true)` (inside ReadinessKit) | raises `attempt to perform boolean test on local 'result' (a secret boolean value, while execution tainted by 'MoltenCodes')` |
| `select("#", secret)`; a secret stored as a table value and returned | works; the value comes back still secret |

So a comparison raises when both sides have the same type, and answers without
raising when one side is `nil` or of another type; a secret used as a key
raises, before any `__index` metamethod can see it; a boolean test of a secret
raises, so a secret must not be the condition of an `if`, `while` or `until`
nor an operand of `and`, `or` or `not`; storing and passing one is fine. The Kits still test the absence of a
foreign value with `type(value) == "nil"` rather than `value == nil` (see the
checklist in [`CONTRIBUTING.md`](CONTRIBUTING.md#taint-and-secret-values)): the rule is uniform, cheap
and never compares anything, so it does not depend on the comparison with
`nil` staying harmless.

`issecretvalue(value)` returns `true` for a secret. Ask it before any of the
operations above on a value that came from the client during combat. Clients
without secret values (Retail before 12.0 and older Classic builds; current Classic Era 1.15.9 and Mists Classic 5.5.4 do expose it) do not have
the function, so probe it once:

```lua
local isSecret = issecretvalue or function()
  return false
end
```

**What a handler may do with a secret argument.** An EventKit or SignalKit
listener receives whatever the client or the emitter passed, secrets included,
and no Kit inspects or unwraps an event's payload. Your handler may store the
value, forward it, and build a string from it — knowing that the string is
secret too, so it can no more be compared with another string or used as a
key than the value itself. It may not compare the value with one of its own
type, test it as a boolean (`if value`, `value and ...`, `not value`), key a
cache by it, do arithmetic on it or index it. Filter on something that is never secret first — the event name, a
frame you own — and check `isSecret(value)` before any such operation on the
value itself.

### Frames you did not create

A frame reached by enumeration — `EnumerateFrames`, `GetChildren`,
`GetRegions`, the nameplate list, the mouse focus — may belong to protected
Blizzard UI. Calling a method on a **forbidden** frame from insecure code is an
error, and since patch 12.1.0 a frame can also refuse access in the current
execution context. Before touching such a frame, ask both:

- `frame:IsForbidden()` — `true` when the frame has been explicitly marked
  forbidden, whatever the execution context.
- `frame:CanBeAccessedInContext()` (added in patch 12.1.0) — `false` when the current execution
  is tainted and the frame is forbidden or enforces access restrictions.

Both are methods, and older clients lack the second, so test for the method
before calling it:

```lua
local function canTouch(frame)
  if frame.IsForbidden and frame:IsForbidden() then
    return false
  end
  if frame.CanBeAccessedInContext and not frame:CanBeAccessedInContext() then
    return false
  end
  return true
end
```

Frames your addon created are never forbidden to it; the check is for frames
you found.

### Secure calls and secure variables

- `securecallfunction(callback, ...)` calls `callback` so that taint picked up
  inside it does not spread into the code that runs after it, and reports an
  error inside it to the error handler instead of propagating it. This is what
  EventKit uses between listeners where the client provides it.
- `issecurevariable([table,] name)` returns whether a global (or a field of
  `table`) still holds a secure value, and, when it does not, the name of the
  addon that tainted it. Ask it before you "repair" shared state: a secure
  value must be left alone.

### Rules for taint-safe addon code

These are the rules the survey of existing libraries shows every author learns
the hard way. The framework follows them, and a contribution that breaks one is
a defect:

1. **Post-hook, never replace.** Use `hooksecurefunc` (or a post-hook on a
   script) and never assign over a Blizzard global, method or script handler.
   `HookKit` (package `hookKit`) implements this rule: `SecureHook` and
   `SecureHookScript` are reversible post-hooks, and a non-secure hook of a
   secure target is refused without `options.forceSecure`; see
   [`hookKit/docs/API.md`](../packages/hookKit/docs/API.md).
   One recorded exception: tab completion in `CommandKit` replaces
   `ChatEdit_CustomTabPressed`, because the client consumes the tab only when
   that function returns `true`, which a post-hook cannot deliver. It is off
   until `scope:EnableCompletion()`, it forwards to the previous function, and
   disabling it writes the previous function back, which leaves the global
   tainted for the session (rule 3); see
   [`commandKit/docs/API.md`](../packages/commandKit/docs/API.md).
2. **Never attach your own tables or fields to a frame Blizzard code indexes.**
   Keep your per-frame state in a table of your own, keyed by the frame.
3. **Delete, do not overwrite, a key you tainted by mistake.** Another value
   written from your code is still yours and still tainted; setting the key to
   `nil` lets secure code create it again cleanly.
4. **Probe `issecurevariable` before repairing shared state.**
5. **Persist intent always; apply only out of combat.** Record what the user
   asked for immediately, and apply anything that touches protected frames on
   `PLAYER_REGEN_ENABLED`. `LifecycleKit` does the waiting for you:
   `instance:WhenOutOfCombat(callback)` runs at once when safe and otherwise
   queues the callback, bounded, for the next `PLAYER_REGEN_ENABLED`.
6. **Never recycle a region without clearing its secret values.** A pooled
   `FontString` or texture that displayed a secret must be cleared before it is
   reused for something else.

**How a Kit reports errors — the rule, and where the Kits stand today.** A
message built from a secret is itself a secret string, so an error handler, a
log or a test that compares or searches the message inherits every restriction
above, and the report that was meant to explain a failure causes another. The
rule the Kits will meet is: a value the Kit did not create is formatted into an
error message only after `issecretvalue` says it is not secret; a secret is
described by a fixed placeholder such as `<secret value>`; argument errors name
the parameter and the expected type. **Where the Kits stand:** every Kit written in phase 4 (ClientKit, CacheKit,
ProfileKit, ReadinessKit, SchemaKit, LocaleKit, HookKit, SettingsKit,
OptionsKit, CommandKit, CodecKit, InteropKit, MediaKit, CommKit, WidgetKit,
TestKit) and SignalKit's bus probe `issecretvalue` before comparing or
formatting a foreign value. The eight original Kits (Registry, SignalKit's raw
signals, EventKit, LifecycleKit, ModuleKit, TimerKit, SchedulerKit, PoolKit)
still format some argument values through `tostring` in error messages; the
risk is low because each such value was already compared or used as a key, so
a secret would have failed earlier, and the roadmap's standing obligations
carry the remaining work. `ClientKit:IsSecret(value)` is the probe to use in
your own code, and your error messages should follow the rule from the start.

**A tooltip or nameplate consumer, written safely.**

```lua
local plates = {} -- per-plate state, keyed by the frame; never stored on it

EventKit:Connect("NAME_PLATE_UNIT_ADDED", function(_, unit)
  local plate = C_NamePlate.GetNamePlateForUnit(unit)
  if not plate or not canTouch(plate) then
    return -- a forbidden plate, such as a friendly one in an instance
  end

  local name = UnitName(unit)
  plates[plate] = plates[plate] or {}
  plates[plate].name = name -- storing a secret is allowed

  if not isSecret(name) and name == trackedName then
    -- only a non-secret name may be compared
  end
end)
```

The same shape applies to a tooltip post-hook
(`TooltipDataProcessor.AddTooltipPostCall`): check the tooltip frame with `canTouch`, treat every
field of the tooltip data as possibly secret, and treat any string built from
one as secret too.

### Catalogue of taint-hostile subsystems

The subsystems below taint when insecure code touches them, whatever the
intent. Each row names the sanctioned replacement and, when that replacement is
a documented client API, the apiKit flavours whose committed metadata
(`packages/apiKit/metadata/<flavour>/namespaces.json`) describes it; a
replacement that is FrameXML or the addon's own frames is not in the documented
API tables, and the column says so. `CompatKit.CATALOGUE` (package `compatKit`)
publishes the same rows as a read-only Lua table for tooling and addons, and
`tooling/tests/test_compat_catalogue.py` holds this table, that table and the
metadata together.

| Subsystem | Why it taints | Sanctioned replacement | Replacement in the apiKit metadata |
|---|---|---|---|
| `UIDropDownMenu (UIDropDownMenu_*, EasyMenu)` | One shared set of dropdown frames and globals (`UIDROPDOWNMENU_OPEN_MENU`, `UIDROPDOWNMENU_MENU_LEVEL`) serves every menu; a write from insecure code taints them and blocks the next secure menu (unit frame and raid frame menus). | `Menu` and `MenuUtil` (`Blizzard_Menu`, FrameXML): own menu descriptions, no shared globals. | FrameXML, not a documented API; none. |
| `StaticPopup_Show dialogs` | The four `StaticPopup<n>` frames are shared; a dialog shown from insecure code taints the frame Blizzard reuses for its next protected confirmation. | Own dialog frames (WidgetKit; dialogKit when it ships). | Own frames; none. |
| `ActionButton_ShowOverlayGlow / ActionButton_HideOverlayGlow` | Writes overlay fields on secure action buttons, tainting the action bar and blocking its secure updates in combat. | Own glow frame parented to the button, state kept in a table of your own keyed by the button. | Own frames; none. |
| `Hidden tooltip scanning (GameTooltip:SetOwner/SetUnit, GameTooltipTextLeft<n>)` | `GameTooltip` is shared with the secure UI; setting it from insecure code taints it, and in combat the text it shows is a secret value. | `C_TooltipInfo.GetUnit` and its siblings return the tooltip data as a table; post-hook with `TooltipDataProcessor.AddTooltipPostCall`. | `C_TooltipInfo.GetUnit`: `beta`, `ptr`, `retail` (the Classic flavours document the namespace without `GetUnit`). |
| `GetAddOnMetadata (legacy global)` | Removed from Retail in 10.1; an addon that writes the global back to shim it taints a name secure code reads. | `C_AddOns.GetAddOnMetadata` (`ClientKit:GetAddOnMetadata` chooses per client). | `C_AddOns.GetAddOnMetadata`: `beta`, `classic-era`, `classic-mop`, `ptr`, `retail`. |
| `ShowUIPanel / HideUIPanel on Blizzard panels` | `UIParent`'s panel management (`UIPanelWindows`, `UIParent_ManageFramePositions`) is secure; a call from insecure code taints its layout state and blocks secure panels in combat. | Own frames outside the UIPanel system; `UISpecialFrames` for Escape to close. | Own frames; none. |
| `InterfaceOptionsFrame_OpenToCategory` | Removed with `InterfaceOptionsFrame` in 10.0; compatibility wrappers that recreate it write into the Settings frames. | `Settings.OpenToCategory(categoryID)` (`Blizzard_Settings`, FrameXML) opens your category; `C_SettingsUtil.OpenSettingsPanel` opens the panel. | `C_SettingsUtil.OpenSettingsPanel`: `beta`, `classic-era`, `classic-mop`, `ptr`, `retail`; `Settings.OpenToCategory` is FrameXML. |
| `SetOverrideBindingClick in combat` | Protected while in combat lockdown; a call from insecure code then raises `ADDON_ACTION_BLOCKED` and the binding is lost. | Record the intent at once and apply it out of combat (LifecycleKit `instance:WhenOutOfCombat`). | Not an API change; none. |
| `CompactUnitFrame hooks that write frame fields` | The compact raid frames are secure; replacing `CompactUnitFrame_*` functions or writing fields on the frames taints them for the session. | `hooksecurefunc` post-hooks (HookKit `SecureHook`) that write nothing on the frame; read auras through `C_UnitAuras.GetAuraDataByIndex`. | `C_UnitAuras.GetAuraDataByIndex`: `beta`, `classic-era`, `classic-mop`, `ptr`, `retail`. |

The flavour lists were read from the committed metadata on 2026-09-24; a
metadata refresh that adds or removes one of these functions fails the tooling
test until both tables are updated.

## The combat log

`COMBAT_LOG_EVENT_UNFILTERED` has carried **no arguments** since Legion. Your
listener receives the event name and nothing else:

```lua
EventKit:Connect("COMBAT_LOG_EVENT_UNFILTERED", function()
  local timestamp, subEvent, hideCaster, sourceGUID = CombatLogGetCurrentEventInfo()
  -- ...
end)
```

Three rules:

- `CombatLogGetCurrentEventInfo()` is valid **only inside the handler**. Copy out
  what you need; do not keep the call for later.
- It is a normal event, not a unit event. `EventKit:ConnectUnit` does not apply.
- It is the highest-frequency event in the client. Keep the handler short, filter
  on `subEvent` before doing anything else, and do the real work on a
  SchedulerKit job rather than inline.

`EventKit:ConnectCombatLog(subEvent, callback)` does the read once per event for
every listener and routes by sub-event; prefer it to reading the client yourself.
Retail 12 clients give addon code no combat-log event reader: measured on Retail
12.1.0 on 2026-09-24, `CombatLogGetCurrentEventInfo` and `GetCurrentEventInfo`
under `C_CombatLog`, `C_CombatLogInternal` and `C_CombatLogSecure` are all
absent from addon code. Ask `EventKit:IsCombatLogAvailable()` first: it answers
`false` there, and `ConnectCombatLog` raises at your line. Classic clients
document `C_CombatLog.GetCurrentEventInfo`, which EventKit reads when the global
is absent, so it answers `true` there.

## `/reload` and saved variables

**Every Kit is per-session. Nothing the framework holds survives `/reload`.**

A UI reload tears down the Lua state: the `MoltenCodes` global, Registry's
bootstrap state, every registered package table, every signal, connection,
timer, module container and pool go with it, and the whole framework bootstraps
again from your `.toc`. LifecycleKit reports `PLAYER_LOGOUT` on the way out, so
`OnShutdown` callbacks run and every addon-owned scope (timers, jobs, events,
hooks, commands, messaging, the bus) closes whenever LifecycleKit or EventKit is
loaded, and otherwise through your own `CloseAddonScopes` call, but
none of that state is written anywhere.

**Persistence is yours to declare.** Declare `## SavedVariables` in your
`.toc` and open the database in your `loaded` phase, which is the addon's own
`ADDON_LOADED` and the first moment the client guarantees the table exists. Do
not touch it at file scope.

```lua
lifecycle:OnLoaded(function()
  local db = SettingsKit:Open("MyAddonDB", {
    profile = SchemaKit.table{ fields = {
      scale = SchemaKit.optional(SchemaKit.number{ min = 0.5, max = 2 }, 1),
    } },
  }, { version = 1 })
  print(db.profile.scale) -- 1, read from the defaults, never stored
end)
```

`SettingsKit` (package `settingsKit`) is the one Kit that writes a saved
variable, and only the global your own `.toc` names: defaults are never written
into the table, every write is validated against your schema at the writer's
line and a secret value is refused, profiles and versioned migrations are built
in, and `db:Compact()` removes values equal to their defaults at `PLAYER_LOGOUT`
when EventKit is present. The layout of the saved table is specified in
[`settingsKit/docs/INTERNALS.md`](../packages/settingsKit/docs/INTERNALS.md).
No other Kit reads or writes a saved variable, and none will add one of its own:
a shared library that wrote to a global saved-variables table would make every
embedding addon's state depend on which copy won.

## User interface

`WidgetKit` (package `widgetKit`) builds insecure frames of its own with
`CreateFrame`. That has four consequences worth knowing before you use it.

- **Widgets are insecure frames.** Creating, moving and showing them in combat
  is fine; using them for protected actions (casting, targeting, secure
  attribute buttons) is not, and a secure frame must never be parented into a
  widget, because the parent's taint reaches it.
- **WidgetKit sets scripts and fields only on frames it creates.** It does
  re-anchor a frame you hand it: `BindPosition`, `binding:Capture`,
  `binding:Restore` and `Anchor.Apply` call `ClearAllPoints`, `SetPoint` and
  `SetScale` on that frame, after `IsForbidden` and `CanBeAccessedInContext`
  allow it, and bindings refuse a frame they may not touch. The one client
  frame it uses, `ColorPickerFrame`, is opened only through its own
  `SetupColorPickerAndShow` after the same check, and a click fires the current
  colour when the check fails.
- **Text setters refuse a secret.** `Label:SetText` refuses a secret value
  unless the caller passes `allowSecret`; `EditBox:SetText` always refuses
  one, because the client's edit box takes a secret only from untainted code
  (measured on Retail 12.1.0 b69933, 2026-09-25), so the options renderer
  shows a secret input value as `<secret value>`, disabled. Every pooled widget
  clears its text on release, so a recycled region never shows a value from
  its previous life (taint rule 6).
- **Positions persist through SettingsKit.** `WidgetKit:BindPosition(frame,
  db.profile.window)` saves a plain anchor table `{ point, relativeTo,
  relativePoint, x, y, scale }` into a record you declare in your schema,
  debounced through SchedulerKit when it is present, and restores it on bind.

Rendering an options tree is one call: `WidgetKit:RenderOptions(tree,
container)` walks `tree:Describe()`, creates one widget per option, writes
through `tree:Validate` then `tree:Set`, shows a refusal inline, and refreshes
on `tree:OnChange`. Call `rendering:Refresh()` from `db:OnProfileChanged` so a
profile switch redraws the values. The widget author contract, the release
contract and the layout contract are in
[`widgetKit/docs/API.md`](../packages/widgetKit/docs/API.md).

## Performance guidance

The framework is allocation-conscious on its hot paths, and it stays that way
only if you use the parts that exist rather than rebuilding them.

- **Do not do work per high-frequency event.** `UNIT_HEALTH`, `BAG_UPDATE`,
  `UNIT_AURA` and their kind arrive in bursts. `EventKit:Coalesce` delivers one
  callback per interval with the set of payloads, and `EventKit:Derive` keeps a
  value recomputed from a set of events. Coalescing needs SchedulerKit loaded:
  without it `Coalesce` is refused at the caller and `Derive` still works but
  recomputes synchronously on every event.
- **Ration a server resource through a lane, and send addon messages through
  CommKit.** Inspect requests, `/who` and other calls the server throttles go
  through one shared `SchedulerKit:Lane` (in-flight cap, minimum interval,
  retry with backoff) rather than a private token bucket per addon. Addon
  messages are the one resource with its own owner: `CommKit` holds the
  session's bandwidth budget, chunks and reassembles, and refuses rather than
  grows when a queue is full.
- **Do not run your own `OnUpdate`.** Every per-frame handler in the session
  costs the client a call whether or not it has work. SchedulerKit installs one
  `OnUpdate` for the whole session, only while ready work exists, and removes it
  again when the queues drain. Put per-frame work on a SchedulerKit job.
- **Respect the frame budget.** A scheduled job is cooperative, not preemptive:
  it runs until it returns or calls `context:Yield()`. Check
  `context:ShouldYield()` inside your loops and yield when it says so. A job that
  runs long is not killed, but it is demoted a priority lane and reported through
  the error handler.
- **The budget is CPU time, not wall time.** SchedulerKit measures with
  `debugprofilestop`, so a client hitch or a garbage-collection pause is not
  charged to your job.
- **Do not call `debugprofilestart()`.** There is one profiling timer per
  process and that call zeroes it for every addon in the session, including
  SchedulerKit's frame accounting and every other library measuring its own
  cost. SchedulerKit survives a restart — its budget is monotonic and re-anchors
  itself, see *The profiling clock is shared* in
  [`schedulerKit/docs/API.md`](../packages/schedulerKit/docs/API.md) — but the
  measurement straddling your call is lost, for you and for everybody else. Use
  `GetTimePreciseSec()` for your own timings, and if you must profile CPU, keep
  the restart off any per-frame path.
- **Every Kit is bounded by default and opened on purpose.** A cap on an
  object you create is a constructor option (`SignalKit:Bus(name, { maxTopics,
  maxListeners })`, `HookKit:CreateScope{ maxHooks }`, `CommandKit:CreateScope{
  maxCommands }`, `CacheKit:NewLru{ maxEntries }`, `LocaleKit:GetLocale(name, {
  maxMissingKeys })`) and accepts the Kit's `UNBOUNDED` sentinel where the
  retained memory is your own registrations. A package-wide cap goes through
  `Kit:SetLimits{}` and is read back with `Kit:GetLimits()`; those are shared by
  every addon in the session, so a library keeps the defaults. `UNBOUNDED` is
  refused where the client never frees the resource (frames, shared buses,
  LibSharedMedia entries) or where a wire format or the stack sets a ceiling;
  each API.md has a "Limits" table naming the default, the ceiling and the
  reason.
- **Pools are bounded by default.** PoolKit retains 128 objects per pool unless
  you say otherwise, and `PoolKit.UNBOUNDED` is an explicit, documented opt-in
  that makes retention your problem. `maxRetained` bounds what the pool keeps,
  not what you borrow: a borrowed object is yours until you release it, and
  `maxActiveWarning` exists to tell you once when too many are out at a time.
- **Let a scope disconnect what you connect.** An EventKit connection keeps its
  callback alive, and the last connection to an event is what unregisters it
  from the client. Inside a ModuleKit module, connect through `module.scope`
  (`Events`, `Timers`, `Jobs`, `Hooks`, `Commands`, `Messages`, `Comm`) and the
  scope is closed when the module is disabled; outside a module, hold the
  handle and disconnect it yourself.
- **Prefer addon-owned scopes.** `EventKit:ForAddon(name)`,
  `TimerKit:ForAddon(name)`, `SchedulerKit:ForAddon(name)`,
  `HookKit:ForAddon(name)`, `CommandKit:ForAddon(name)`,
  `CommKit:ForAddon(name)` and `SignalKit:ForAddon(name)` are closed by
  LifecycleKit on `PLAYER_LOGOUT` without you writing teardown code. The
  package-level convenience methods (`TimerKit:After`, `SchedulerKit:Schedule`)
  use an internal manual scope that is *not* tied to any addon lifecycle.
- **Keep event handlers small.** The bus is shared. Time spent in your handler is
  time every other addon's handler waits, on an event that may fire thousands of
  times a second.

## Troubleshooting

Almost every first-run problem is load order. These are the exact messages the
code raises, and what each one means.

### `MoltenCodes <Kit> requires Registry API 2 to be loaded first`

`Registry.lua` is missing from your `.toc`, or it is listed after this Kit. It
must be the first MoltenCodes file you load. The same message appears for every
Kit, because every Kit checks for Registry before anything else.

You also see it if something else in the session owns a `MoltenCodes` global
that is not a table, which Registry reports separately as
`Registry: MoltenCodes global namespace is owned by an incompatible value`.

### `MoltenCodes EventKit requires SignalKit API 1 to be loaded first`

`SignalKit.lua` is missing or listed after `EventKit.lua`. EventKit builds its
dispatch on SignalKit.

### `MoltenCodes LifecycleKit requires EventKit API 1 to be loaded first`

`EventKit.lua` is missing or listed after `LifecycleKit.lua`. There is also a
`... requires SignalKit API 1 to be loaded first` variant with the same cause one
level down.

### `MoltenCodes ModuleKit requires LifecycleKit API 1 to be loaded first`

`LifecycleKit.lua` is missing or listed after `ModuleKit.lua`.

### `MoltenCodes SchedulerKit requires a valid TimerKit API 1 facade`

`TimerKit.lua` is missing or listed after `SchedulerKit.lua`. SchedulerKit
checks the facade's shape in one step, so a missing dependency and a corrupted
one produce the same message. TimerKit itself needs only Registry.

### `MoltenCodes TimerKit requires C_Timer.NewTimer and C_Timer.NewTicker`

The client did not publish `C_Timer`. On a real client this means you are on a
flavour older than anything the framework supports; outside a client it means
the environment is not a WoW client at all.

### `MoltenCodes SchedulerKit requires CreateFrame` / `requires GetTimePreciseSec`

The same class of problem for SchedulerKit. `debugprofilestop` is optional and
falls back silently; these two are not.

### `EventKit: requires the World of Warcraft CreateFrame API`

Raised when the first subscription is made, not at load, because EventKit creates
its frame lazily. Same cause as above.

### `MoltenCodes ApiKit (<Flavour> bindings) requires ApiKit API 1 to be loaded first`

A flavour file (`apiKit\flavours\Retail.lua`) is listed before
`apiKit\ApiKit.lua`, or the facade is missing. The facade comes first, then the
flavour files.

### `api.<namespace>` is `nil` on a client that has the namespace

Either no flavour file for the running client is embedded (`ApiKit:GetFlavor()`
names the flavour; `ApiKit:GetMetadataBuild(flavour)` returns nothing when its
file never registered), or the client is one ApiKit does not describe
(`"unsupported"`). A namespace the client itself lacks is absent by design.

### `Registry:Get(...)` returned `nil`

The package is not in your `.toc` at all, or you asked for an API generation that
nothing registered. Check the number: `Registry:Get("eventKit", 1)` and
`Registry:Get("eventKit", 2)` are different questions and only one of them has an
answer today.

### `EventKit:ConnectUnit accepts at most 2 distinct unit tokens ...`

`Frame:RegisterUnitEvent` has exactly two filter slots. The client silently
drops a third token, which would give you a filter you never asked for, so
EventKit makes it an error instead. Use two subscriptions, or subscribe without a filter and
check the unit in your handler.

### `EventKit: refusing to create more than 64 unit-filter Frames ...`

Frames cannot be destroyed once created, so EventKit caps how many it will ever
make. Reaching the cap means unit sets are being created and abandoned in a loop.
Disconnect unit subscriptions you no longer need — a unit group releases its
frame back to a free list when its last listener goes.

### `LifecycleKit:ForAddon addonName must be a non-empty string`

You passed something other than the addon folder name. Use the `...` vararg:
`local ADDON_NAME = ...` at the top of the file.

### `MoltenCodes <Kit> requires SchemaKit API 1 to be loaded first`

SettingsKit, OptionsKit and CommandKit validate through SchemaKit and load
after it. Put `schemaKit/SchemaKit.lua` before them in `embeds.xml`; the
release artifact's `loadOrder` already does.

### `Coalesce` is refused, or `EncodeAsync` / `RenderOptions` / `BindOptions` raise "not loaded"

These are the call-time optional dependencies: EventKit coalescing needs
SchedulerKit, CodecKit's asynchronous variants need SchedulerKit, WidgetKit's
renderer needs OptionsKit, CommandKit's `BindOptions` needs OptionsKit. Each
Kit finds the other through `Registry:Find` when the method is called, so the
fix is to embed the missing Kit, in load order, not to change the call.

### `SettingsKit (<name>) <scope>.<path>: expected <type>, found <type>`

A write into a saved-variable view failed its schema at the writer's line. The
message is SchemaKit's failure text; fix the value or widen the schema. A
secret value is refused before the schema runs, with `refused a secret value:
saved variables never hold secret values`; never store one.

### `SettingsKit (<name>) <scope> is read-only: the saved table has version <n>, newer than options.version <m>; ...`

The saved variable was written by a newer version of your addon than the one
running (the player downgraded, or two installations share a `WTF` folder).
SettingsKit opens such data read-only so an older version cannot damage it:
reads work, writes raise, and `db:IsReadOnly()` is `true`. Update the addon,
or, when this version can safely write the newer layout, open the database
with `allowNewerData = true`.

### `CommandKit ... nil, "taken"` or `nil, "emote"`

The slash name is already a chat type (`/s`, `/g`), an emote (`/dance`) or
another addon's command. Pick another name: the client resolves chat types
before slash commands and emotes after them, so a command named like a chat
type would never run, and one named like an emote would hide the emote.

### Nothing happens, and there is no error

Check that you are not swallowing it. An EventKit listener that raises is
reported through `geterrorhandler()` and does not propagate, so with no error
display addon installed the message goes nowhere visible. Install one before
concluding that a callback did not run.

## Where to go next

- Each package's own `docs/API.md` is its complete contract.
- [`ARCHITECTURE.md`](ARCHITECTURE.md) explains the dependency graph and
  embedded package identity.
- [`RELEASES.md`](RELEASES.md) describes the artifacts and their checksums.
