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
- [Several addons, several copies](#several-addons-several-copies)
- [Supported client versions](#supported-client-versions)
- [Coexisting with LibStub](#coexisting-with-libstub)
- [Taint](#taint)
- [The combat log](#the-combat-log)
- [`/reload` and saved variables](#reload-and-saved-variables)
- [Performance guidance](#performance-guidance)
- [Troubleshooting](#troubleshooting)

## What a Kit is

A **Kit** is one independently publishable runtime package: a single Lua file
that publishes one table of functions and nothing else. `SignalKit` is callback
dispatch, `EventKit` is World of Warcraft events, `TimerKit` is timers, and so
on. The complete list is in the [root README](../README.md).

Three properties matter to a consumer:

- **A Kit is embedded, not installed.** You copy its Lua file into your addon
  and list it in your `.toc`. There is no shared addon your users must download
  and no dependency for them to get wrong.
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
or written by an addon. Nothing else in the framework writes a global.

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
│       └── timerKit/TimerKit.lua
├── Core.lua
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
├──→ poolKit
└──→ signalKit
       ↓
     eventKit
       ↓
   lifecycleKit
    ├──→ moduleKit
    ├──→ timerKit
    │       ↓
    └──→ schedulerKit
```

Any order consistent with that graph works. This one is consistent with it and
is what the release artifact's `manifest.json` records under `loadOrder`:

```text
registry/Registry.lua
signalKit/SignalKit.lua
eventKit/EventKit.lua
lifecycleKit/LifecycleKit.lua
moduleKit/ModuleKit.lua
poolKit/PoolKit.lua
timerKit/TimerKit.lua
schedulerKit/SchedulerKit.lua
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

## A complete example addon

The three files below are real: they live in [`../examples/`](../examples/), a
spec loads them against stubs on every test run, and `lua-language-server`
type-checks them on every gate run. Copy the directory into
`Interface/AddOns/ExampleAddon/`, drop the framework files into
`Libs/MoltenCodes/`, and it runs.

### `ExampleAddon.toc`

```toc
## Interface: 120100, 50504, 20506, 11509
## Title: Example Addon
## Notes: Minimal addon showing how to embed the MoltenCodes framework.
## Author: MoltenCodes
## Version: 1.0.0
## SavedVariables: ExampleAddonDB
## IconTexture: Interface\Icons\INV_Misc_Gear_01
## X-Category: Development Tools
## X-License: MIT
## X-Embeds: MoltenCodes-Registry, MoltenCodes-SignalKit, MoltenCodes-EventKit, MoltenCodes-LifecycleKit, MoltenCodes-ModuleKit, MoltenCodes-TimerKit

# Embedded framework packages. This file must come first: every package below
# resolves its dependencies at load time and raises if one is missing.
embeds.xml

# Addon code.
Core.lua
```

A comma-separated `## Interface` line is the modern way to support several
client flavours from one `.toc`; see
[Supported client versions](#supported-client-versions). `## X-Embeds` is not
read by the client — it is a convention that tells a reviewer, and you in six
months, which libraries are bundled.

### `embeds.xml`

```xml
<Ui xmlns="http://www.blizzard.com/wow/ui/">
    <Script file="Libs\MoltenCodes\registry\Registry.lua" />
    <Script file="Libs\MoltenCodes\signalKit\SignalKit.lua" />
    <Script file="Libs\MoltenCodes\eventKit\EventKit.lua" />
    <Script file="Libs\MoltenCodes\lifecycleKit\LifecycleKit.lua" />
    <Script file="Libs\MoltenCodes\moduleKit\ModuleKit.lua" />
    <Script file="Libs\MoltenCodes\timerKit\TimerKit.lua" />
</Ui>
```

### `Core.lua`

The full file is [`../examples/Core.lua`](../examples/Core.lua). Its shape is:

```lua
-- WoW passes every addon file its addon name and a private shared table.
local ADDON_NAME, ADDON_TABLE = ...

local generations = MoltenCodes and MoltenCodes.Registries
local Registry = generations and generations[2] or MoltenCodes.Registry

local EventKit = Registry:Get("eventKit", 1)
local LifecycleKit = Registry:Get("lifecycleKit", 1)
local ModuleKit = Registry:Get("moduleKit", 1)
local TimerKit = Registry:Get("timerKit", 1)

-- All three are keyed by the addon folder name, which is what `...` gives you.
local lifecycle = LifecycleKit:ForAddon(ADDON_NAME)
local modules = ModuleKit:ForAddon(ADDON_NAME)
local timers = TimerKit:ForAddon(ADDON_NAME)

modules:ProvideValue("AddonName", ADDON_NAME)

modules:CreateModule("Greeter", {
    inject = { addonName = "AddonName" },

    onEnable = function(self)
        print(self.addonName .. " is ready")

        self.connection = EventKit:Connect("PLAYER_ENTERING_WORLD", function()
            -- Short, and never a protected call. See Taint, below.
        end)

        -- Cancelled automatically when the addon shuts down.
        self.tick = timers:Every(60, function() end)
    end,

    onDisable = function(self)
        self.connection:Disconnect()
        self.tick:Cancel()
    end,
})
```

Three things are worth pointing out:

- **`...` is the addon name.** `LifecycleKit:ForAddon`, `ModuleKit:ForAddon` and
  `TimerKit:ForAddon` key their per-addon state by the folder name exactly as
  the client reports it in `ADDON_LOADED`. Passing the `...` vararg means you
  cannot get it wrong, and it survives your addon being renamed.
- **You do not drive the lifecycle yourself.** ModuleKit binds the container to
  your LifecycleKit instance: modules are initialized when the addon's
  `ADDON_LOADED` completes, enabled when the player logs in, and disabled on
  `PLAYER_LOGOUT`. Nothing in `Core.lua` calls `InitializeAll`.
- **Late is fine.** LifecycleKit phases are replay-aware: a callback registered
  after its phase already happened runs immediately instead of never. You do not
  have to race the client's events.

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

**Never list MoltenCodes in `## Dependencies` (or its synonym
`## RequiredDeps`).** Those fields name other *addons* that must be installed and
enabled. The framework is not an addon: it has no `.toc`, nothing called
`MoltenCodes` appears in the addon list, and an addon that declares it as a
dependency never loads.

**`## OptionalDeps` is not needed for the Kits either.** It only asks the client
to load the named addons before yours when they are installed. Whether your copy
of a Kit loads before or after another addon's copy makes no difference to
correctness: Registry selects the highest revision whichever order the copies
arrive in, and every addon ends up with the same shared table (see
[Several addons, several copies](#several-addons-several-copies)). Use
`## OptionalDeps` for the standalone addons you integrate with, exactly as you
would without the framework.

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
| `registry`, `signalKit`, `poolKit`, `moduleKit` | nothing but Lua 5.1 | — |
| `eventKit` | `CreateFrame`, `Frame:RegisterEvent`, `Frame:RegisterUnitEvent`, `Frame:UnregisterEvent`, `Frame:SetScript` | `securecallfunction` (falls back to `xpcall`), `geterrorhandler` (falls back to `print`) |
| `lifecycleKit` | EventKit's surface | `C_AddOns.IsAddOnLoaded` (falls back to the legacy global), `IsLoggedIn` |
| `timerKit` | `C_Timer.NewTimer`, `C_Timer.NewTicker` | — |
| `schedulerKit` | `CreateFrame`, `GetTimePreciseSec` | `debugprofilestop` (falls back to the wall clock), `debug.traceback` (failures then report the error value only) |

Runtime code stays Lua 5.1-compatible because that is what every client runs.
A Kit that needed a newer client facility would need a new API generation, not a
revision.

## Coexisting with LibStub

**The Registry is not LibStub, and the two do not interact.**

They solve the same problem in different ways. LibStub keys a library by name
and a single integer minor version, and hands out one table per name. Registry
keys a package by `(name, API generation)`, orders implementations inside a
generation by revision, and never replaces the table it handed out. The
consequences differ enough that pretending one is the other would be misleading,
so the framework does not try.

What this means in practice:

- **Both can live in one addon.** They are different globals (`LibStub` and
  `MoltenCodes`) with different state. Embedding Ace3 and MoltenCodes side by
  side needs nothing special; list each library's files in your `.toc` in its own
  required order.
- **MoltenCodes Kits are not LibStub libraries.** No Kit calls
  `LibStub:NewLibrary` or `LibStub:GetLibrary`, and no Kit appears in a LibStub
  listing. Do not write `LibStub("SignalKit-1.0")`; it will return `nil`.
- **The framework does not depend on LibStub being present**, and does not care
  whether it is.

If you genuinely need a LibStub-visible handle — for example a plugin API of
your own that other authors reach through LibStub — bridge it in **your** addon
rather than in the framework:

```lua
-- In your addon, after the MoltenCodes files have loaded.
if LibStub then
    local bridge, oldMinor = LibStub:NewLibrary("MyAddon-Signals-1.0", 1)
    if bridge and not oldMinor then
        local Registry = MoltenCodes.Registries[2]
        bridge.SignalKit = Registry:Get("signalKit", 1)
    end
end
```

Two warnings about doing that. First, the bridge table is yours and its
versioning is yours; do not present it as the framework's contract. Second,
`bridge.SignalKit` is a reference to the shared Kit table, which is exactly the
reference that stays valid across revision upgrades — so store the table, never
individual methods off it.

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
2026-09-23; when the two disagree, the page wins.

Since patch 12.0.0, some Retail APIs hand addon code **secret values** instead of
ordinary ones while restrictions apply — in combat and in instanced content, and
most visibly on unit and aura APIs: names, health, aura data, and in some cases
the unit token an event carries. A secret looks like an ordinary string, number
or boolean, but tainted code may not look inside it. Each of these raises an
immediate Lua error at the line that tries it:

- comparing it (`==`, `~=`, `<`, …);
- a boolean test on a secret *boolean* (`if secret then`);
- arithmetic on it;
- the length operator (`#secret`);
- indexing into it or assigning through it (`secret.foo`, `secret["foo"] = 1`);
- calling it as a function;
- storing it as a table *key*.

What stays allowed:

- storing it in a local, an upvalue or as a table *value*, and passing it to
  Lua functions;
- concatenating secret strings and numbers, and passing secrets to
  `string.format`, `string.concat` and `string.join`. The result is itself a
  secret string, with every restriction above;
- `type(secret)`, which returns the real type;
- a boolean test on a secret that is not a boolean: `nil` is false and every
  other type is true, because the type is not secret.

Which client APIs accept a secret argument is documented per API on the wiki;
do not assume one does.

`issecretvalue(value)` returns `true` for a secret. Ask it before any of the
operations above on a value that came from the client during combat. Clients
without secret values (the Classic flavours, and Retail before 12.0) do not have
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
secret too, so it can no more be compared or used as a key than the value
itself. It may not compare the value, key a cache by it, do arithmetic on it or
index it. Filter on something that is never secret first — the event name, a
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
2. **Never attach your own tables or fields to a frame Blizzard code indexes.**
   Keep your per-frame state in a table of your own, keyed by the frame.
3. **Delete, do not overwrite, a key you tainted by mistake.** Another value
   written from your code is still yours and still tainted; setting the key to
   `nil` lets secure code create it again cleanly.
4. **Probe `issecurevariable` before repairing shared state.**
5. **Persist intent always; apply only out of combat.** Record what the user
   asked for immediately, and apply anything that touches protected frames on
   `PLAYER_REGEN_ENABLED`.
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
the parameter and the expected type. **Today's Kits do not check yet.** Several
argument and failure messages in SchedulerKit, TimerKit, PoolKit and Registry
pass the offending value through `tostring`. The check arrives with the
`IsSecret` probe of the planned `clientKit` (roadmap package B). Until then,
do not pass a value that may be secret as an argument a Kit validates. Your own
error messages should follow the rule from the start.

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

## `/reload` and saved variables

**Every Kit is per-session. Nothing the framework holds survives `/reload`.**

A UI reload tears down the Lua state: the `MoltenCodes` global, Registry's
bootstrap state, every registered package table, every signal, connection,
timer, module container and pool go with it, and the whole framework bootstraps
again from your `.toc`. LifecycleKit reports `PLAYER_LOGOUT` on the way out, so
`OnShutdown` callbacks run and addon-owned timer and scheduler scopes close, but
none of that state is written anywhere.

**Persistence is entirely yours.** Declare `## SavedVariables` in your `.toc`,
populate the table in your `loaded` phase, and read it from there:

```lua
lifecycle:OnLoaded(function()
    MyAddonDB = MyAddonDB or { version = 1 }
end)
```

The `loaded` phase is the addon's own `ADDON_LOADED`, which is the first moment
the client guarantees your saved variables table exists. Do not touch it at file
scope.

No Kit reads or writes a saved variable, and no Kit will ever add one: a shared
library that wrote to a global saved-variables table would make every embedding
addon's state depend on which copy won.

## Performance guidance

The framework is allocation-conscious on its hot paths, and it stays that way
only if you use the parts that exist rather than rebuilding them.

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
- **Pools are bounded by default.** PoolKit retains 128 objects per pool unless
  you say otherwise, and `PoolKit.UNBOUNDED` is an explicit, documented opt-in
  that makes retention your problem. `maxRetained` bounds what the pool keeps,
  not what you borrow: a borrowed object is yours until you release it, and
  `maxActiveWarning` exists to tell you once when too many are out at a time.
- **Disconnect what you connect.** An EventKit connection keeps its callback
  alive, and the last connection to an event is what unregisters it from the
  client. Hold the connection handle and disconnect it in `OnDisable`.
- **Prefer addon-owned scopes.** `TimerKit:ForAddon(name)` and
  `SchedulerKit:ForAddon(name)` close on `PLAYER_LOGOUT` without you writing
  teardown code. The package-level `TimerKit:After` / `SchedulerKit:Schedule`
  convenience methods use an internal manual scope that is *not* tied to any
  addon lifecycle.
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

### `MoltenCodes TimerKit requires a valid LifecycleKit API 1 facade`

Same cause, different wording: `LifecycleKit.lua` is missing or listed after
`TimerKit.lua`. TimerKit checks the facade's shape in one step, so a missing
dependency and a corrupted one produce the same message.
`MoltenCodes SchedulerKit requires a valid TimerKit API 1 facade` and
`MoltenCodes SchedulerKit requires a valid LifecycleKit API 1 facade` are the
same problem for SchedulerKit.

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

### `Registry:Get(...)` returned `nil`

The package is not in your `.toc` at all, or you asked for an API generation that
nothing registered. Check the number: `Registry:Get("eventKit", 1)` and
`Registry:Get("eventKit", 2)` are different questions and only one of them has an
answer today.

### `EventKit:ConnectUnit accepts at most 2 distinct unit tokens ...`

`Frame:RegisterUnitEvent` has exactly two filter slots. A third token used to be
silently dropped by the client, which gave you a filter you never asked for, so
it is an error instead. Use two subscriptions, or subscribe without a filter and
check the unit in your handler.

### `EventKit: refusing to create more than 64 unit-filter Frames ...`

Frames cannot be destroyed once created, so EventKit caps how many it will ever
make. Reaching the cap means unit sets are being created and abandoned in a loop.
Disconnect unit subscriptions you no longer need — a unit group releases its
frame back to a free list when its last listener goes.

### `LifecycleKit:ForAddon addonName must be a non-empty string`

You passed something other than the addon folder name. Use the `...` vararg:
`local ADDON_NAME = ...` at the top of the file.

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
