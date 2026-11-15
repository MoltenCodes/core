# ClientKit API

ClientKit API generation **1** reports the client flavour, build and
capabilities, probes secret values, restricted frames and event names, shims
the host calls whose name or shape differs between flavours, reads an
addon's `.toc` into a read-only manifest, and carries the framework's
deprecation warnings.

```lua
local ClientKit = MoltenCodes.Registries[2]:Get("clientKit", 1)
```

## Public surface

| Method | Returns | Purpose |
|---|---|---|
| `GetFlavor()` | `"mainline" \| "mists" \| "tbc" \| "classic"` | The client family, from `WOW_PROJECT_ID`. |
| `GetBuild()` | `version?, build?, buildDate?` | From `GetBuildInfo()`; each `nil` when the host does not report it. |
| `GetInterfaceNumber()` | `integer` | The `## Interface` number of the running client, or `0` when unknown. |
| `IsAtLeast(interfaceNumber)` | `boolean` | Whether `GetInterfaceNumber() >= interfaceNumber`. |
| `Has(capability)` | `boolean` | One flag from the [capability table](#capabilities). |
| `IsSecret(value)` | `boolean` | Whether `value` is a secret value. |
| `CanAccessFrame(frame)` | `boolean` | Whether the host reports no restriction on touching `frame`. |
| `IsEventValid(eventName)` | `boolean?` | Whether the client knows the event; `nil` when it cannot say. |
| `GetAddOnMetadata(addon, field)` | `string?` | One `.toc` field of an addon. |
| `IsAddOnLoaded(addon)` | `loaded, finished` | Two booleans. |
| `GetSpellInfo(spell)` | `ClientKit.SpellInfo?` | One table shape on every flavour. |
| `GetItemInfo(item)` | `...` | The host's item list, from whichever call the client has. |
| `GetManifest(addonName)` | `ClientKit.Manifest?, reason?` | A read-only snapshot of an addon's `.toc`; see [Manifests](#manifests). |
| `Deprecate(spec)` | `ClientKit.DeprecationReporter` | Declare something a Kit deprecates; see [Deprecations](#deprecations). |
| `GetDeprecationReports()` | `ClientKit.DeprecationReport[]` | Every deprecation report recorded this session, as fresh rows. |
| `SetDeprecationMode(mode)` | nothing | `"report"` (default), `"silent"` or `"raise"`, for the whole session. |
| `GetDeprecationMode()` | `"report" \| "silent" \| "raise"` | The session's mode. |
| `SetLimits(limits)` | nothing | Change `maxDeprecations` and `maxReports`; see [Limits](#limits). |
| `GetLimits()` | `ClientKit.Limits` | The two limits, as a fresh table. |

`API` and `REVISION` are published on the facade as integers.

Every answer is read from the host once, when the file loads, into shared
package state, and read again in place when a newer compatible revision
upgrades the package. After that every probe is a table read and every shim
adds one call to the host function it wraps. Nothing allocates after
bootstrap except `GetSpellInfo` on a client without `C_Spell.GetSpellInfo`,
which builds the one table it returns, the first `GetManifest` call for
an addon, which builds the snapshot that every later call returns, and the
deprecation methods, which build a reporter or a report the first time they
need one.

The values are fixed for the session. A client does not change flavour,
build, locale or API surface without a restart, and an addon's `.toc` is
read when the client starts, so ClientKit does not re-read them.

## Flavour

`GetFlavor()` reads `WOW_PROJECT_ID` and maps it **by value**:

| `WOW_PROJECT_ID` | Client constant | Flavour |
|---|---|---|
| `1` | `WOW_PROJECT_MAINLINE` | `"mainline"` — Retail |
| `2` | `WOW_PROJECT_CLASSIC` | `"classic"` — Classic Era, Hardcore, Season of Discovery |
| `5` | `WOW_PROJECT_BURNING_CRUSADE_CLASSIC` | `"tbc"` — Burning Crusade Classic (Anniversary) |
| `19` | `WOW_PROJECT_MISTS_CLASSIC` | `"mists"` — Mists of Pandaria Classic |
| anything else, not a number, or absent | — | `"classic"` |

The id is required to be a number before anything is compared, and the
numbers are compared as literals rather than against the `WOW_PROJECT_*`
constants. A constant a client predates is simply absent, so the common
`WOW_PROJECT_ID == WOW_PROJECT_MISTS_CLASSIC` test becomes `nil == nil` — true
— on a host where the id is missing too, and a detector built that way reports
every flavour at once.

An id ClientKit does not map — a superseded client such as Wrath Classic
(`11`) or Cataclysm Classic (`14`), or a flavour newer than this revision —
answers `"classic"`, the flavour that assumes the least about the client. The
flavour is identity only: no capability is derived from it, so a
conservative flavour never hides a facility the host has.

## Build and interface number

`GetBuild()` returns the client version string (`"12.1.0"`), the build number
as an integer (the client reports it as a string), and the build date string.
`GetInterfaceNumber()` returns the fourth value of `GetBuildInfo()`, the number
a `.toc`'s `## Interface` line carries. On a host without `GetBuildInfo`, the
three build values are `nil` and the interface number is `0`, so
`IsAtLeast(n)` answers `false` for every real `n`.

`IsAtLeast(interfaceNumber)` is `GetInterfaceNumber() >= interfaceNumber`.
A non-number `interfaceNumber`, NaN and a secret number raise at the caller.
Interface numbers are ordered **within one flavour only**: Classic Era's
`11509` is lower than Mists Classic's `50504` though both are current. When a
floor depends on the flavour, test the flavour first:

```lua
if ClientKit:GetFlavor() == "mainline" and ClientKit:IsAtLeast(120000) then
  -- Midnight or later
end
```

Where a capability flag or `IsEventValid` can answer the real question, prefer
it: a probe cannot go out of date, a version floor can.

The supported interface numbers are listed in
[`docs/EMBEDDING.md`](../../../docs/EMBEDDING.md#supported-client-versions).

## Capabilities

`Has(capability)` answers one flag from this fixed table. Every flag is
probed from the host at bootstrap and is `false` when the host does not
expose the facility; none is inferred from the flavour.

| Capability | `true` when the host has |
|---|---|
| `C_AddOns` | the `C_AddOns` namespace |
| `C_Spell` | the `C_Spell` namespace |
| `C_Item` | the `C_Item` namespace |
| `C_Timer` | the `C_Timer` namespace |
| `spellbookApi` | `C_SpellBook.GetSpellBookItemInfo`, the `C_SpellBook` item API that replaced the global `GetSpellBookItemInfo` |
| `eventValidity` | `C_EventUtils.IsEventValid`, which `IsEventValid` uses |
| `secretValues` | `issecretvalue`, which `IsSecret` uses (Retail 12.0 and later, and the current Classic Era and Mists Classic clients) |
| `forbiddenFrames` | `UIParent:IsForbidden` |
| `restrictedFrames` | `UIParent:CanBeAccessedInContext` (Retail 12.1 and later) |
| `secureCall` | `securecallfunction` |
| `profilingClock` | `debugprofilestop` |
| `preciseClock` | `GetTimePreciseSec` |

Which flavours expose which namespace changes with client patches, which is
exactly why these are probes: the flag is whatever the running host exposes.

A `C_*` flag says the namespace exists, not that every function in it does.
The shims below probe the individual function they call, so a namespace
present without that function falls back to the legacy global.

Frame methods can only be probed on a frame, and creating one at load would
leave a permanent frame behind, so `forbiddenFrames` and `restrictedFrames`
ask `UIParent`, the frame every client creates before any addon loads. They
look the method up; they never call it.

A name outside the table raises at the caller:

```text
ClientKit:Has does not know capability "C_Foo"
```

rather than answering `false`, so a typo cannot silently turn a feature off.

## Taint probes

The rules these probes serve are in
[`docs/EMBEDDING.md`](../../../docs/EMBEDDING.md#secret-values-retail-12x).

### `IsSecret(value)`

Returns `issecretvalue(value)` on a client that has it. On a client without
`issecretvalue` — Retail before 12.0, older Classic builds — every value
answers `false`, which is correct there: nothing is secret. The function is
bound when ClientKit loads; when the client had none then, the global is
looked up on every call, so one installed later is still used. Ask it before
comparing, indexing, doing arithmetic on or keying a table by a value the
client handed you.

### `CanAccessFrame(frame)`

Returns `false` when `frame:IsForbidden()` returns `true`, or when
`frame:CanBeAccessedInContext()` exists and returns `false`; otherwise `true`.
Each method is used only when the frame has it: `CanBeAccessedInContext`
arrived in patch 12.1.0.

**`true` means "the host offers no restriction it can report", not "safe".**
A frame without either method answers `true` because nothing says otherwise;
the other taint rules — never write fields onto a Blizzard frame, never call a
protected function from insecure code — still apply. Frames your addon
created are never forbidden to it; the check is for frames you found by
enumeration. `frame` must be a table; anything else raises at the caller.

### `IsEventValid(eventName)`

| Host | Answer |
|---|---|
| has `C_EventUtils.IsEventValid`, event known | `true` |
| has `C_EventUtils.IsEventValid`, event unknown | `false` |
| lacks `C_EventUtils.IsEventValid` | `nil` — **unknown**, not invalid |

Treat `nil` as "the client cannot say": fall back to whatever the flavour and
build tell you, or register inside `pcall`. A non-string `eventName` raises at
the caller.

## Shims

Each shim prefers the modern `C_*` call and falls back to the legacy global
only on a client that lacks it. Both are bound once at bootstrap. Argument
errors raise at the caller; errors the host call itself raises propagate
unchanged.

### `GetAddOnMetadata(addon, field)`

`C_AddOns.GetAddOnMetadata`, else `GetAddOnMetadata`. `addon` is a folder
name or an addon index; `field` a `.toc` field name such as `"Version"` or
`"X-Website"`. Returns the field's string, or `nil` when the field is absent
or empty, or when the host has neither call.

### `IsAddOnLoaded(addon)`

`C_AddOns.IsAddOnLoaded`, else `IsAddOnLoaded`. Always returns two booleans,
`loaded, finished`: older clients answer `1`/`nil`, which are normalised.
`true, false` is an addon whose files are running but whose `ADDON_LOADED`
has not completed. A host with neither call answers `false, false`.

### `GetSpellInfo(spell)`

`C_Spell.GetSpellInfo`, else `GetSpellInfo`. `spell` is a spell ID or a spell
name. Returns `nil` when the client does not know the spell, or has neither
call; otherwise a `ClientKit.SpellInfo` table:

| Field | Type | Meaning |
|---|---|---|
| `name` | `string` | Localised spell name. |
| `iconID` | `integer \| string` | File ID of the icon (a texture path on some older clients). |
| `castTime` | `integer` | Cast time in milliseconds; `0` for instant spells. |
| `minRange` | `number` | Minimum range in yards. |
| `maxRange` | `number` | Maximum range in yards. |
| `spellID` | `integer` | The resolved spell ID. |

On a client with `C_Spell.GetSpellInfo` the host's own table is returned
unchanged, so it may carry further fields (`originalIconID`, for example);
only the six above are the contract. On an older client the legacy multiple
returns (`name, rank, icon, castTime, minRange, maxRange, spellID`) are copied
into a new table with exactly those six fields. Either way the table is fresh
and belongs to the caller. On Retail 12.x some fields may be secret values
while restrictions apply; ClientKit passes them through untouched.

### `GetItemInfo(item)`

`C_Item.GetItemInfo`, else `GetItemInfo`. `item` is an item ID, name or link.
Both host forms return the same list, so the shim passes it through
unchanged:

```text
itemName, itemLink, itemQuality, itemLevel, itemMinLevel, itemType,
itemSubType, itemStackCount, itemEquipLoc, itemTexture, sellPrice,
classID, subclassID, bindType, expansionID, setID, isCraftingReagent,
itemDescription
```

Trailing values an older client does not provide are `nil`. Nothing is
returned while the item is not in the client's cache; the client then
requests it and fires `GET_ITEM_INFO_RECEIVED`, after which a second call
succeeds. A host with neither call returns `nil`.

## Manifests

`GetManifest(addonName)` returns a read-only snapshot of the `.toc` of the
addon whose folder is `addonName`, read through `C_AddOns.GetAddOnMetadata`
(else the legacy `GetAddOnMetadata`) on the first call for that addon and
answered from the cache on every later one. `addonName` must be a string;
an addon index is not accepted because the cache is keyed by name. The name
is matched **case-insensitively**, as the host matches it, so `"MyAddon"`,
`"myaddon"` and `"MYADDON"` share one snapshot; `manifest.name` carries the
folder name as the host spells it when `GetAddOnInfo` reports one, else as
the caller spelt it. A secret `addonName` is refused at the caller before it
is compared or used as a key.

```lua
local manifest, reason = ClientKit:GetManifest("MyAddon")
if manifest == nil then
  print("no manifest:", reason) -- "unknown" or "unavailable"
else
  print(manifest.title, manifest.version)
  for index = 1, #manifest.savedVariables do
    print(manifest.savedVariables[index])
  end
  print(manifest:Get("X-Website"))
end
```

| Result | Meaning |
|---|---|
| `manifest` | The snapshot; the same table on every call for the same name. |
| `nil, "unknown"` | The host lists no addon by that name. Nothing is cached, so a misspelt name costs one host round trip per call and never grows the cache. |
| `nil, "unavailable"` | The host has neither `C_AddOns.GetAddOnMetadata` nor `GetAddOnMetadata`, so no `.toc` can be read at all. |

An addon is *listed* when `C_AddOns.GetAddOnInfo` (else `GetAddOnInfo`)
describes it without the reason `"MISSING"`: on both client generations the
call never raises for an unknown name but echoes it back with that reason as
its fifth return. The call is still made through `pcall`, so an argument the
host rejects outright reads as "not listed" too. On a host that has the call
its answer is final: after `"MISSING"` no metadata can read for that name,
so no `## Title` is asked for and an unknown name costs exactly one host
call. A host without either call cannot confirm anything; there, an addon is
known when its `## Title` (localised or plain) reads, and one without a
readable title answers `nil, "unknown"`.

### Snapshot fields

| Field | Type | `.toc` source |
|---|---|---|
| `name` | `string` | The folder name as the host spells it, else as asked for. |
| `title` | `string?` | `## Title-<locale>`, else `## Title`. |
| `notes` | `string?` | `## Notes-<locale>`, else `## Notes`. |
| `version` | `string?` | `## Version`. |
| `author` | `string?` | `## Author`. |
| `interface` | `string?` | `## Interface`, as written; compare with `GetInterfaceNumber()` after `tonumber`. |
| `iconTexture` | `string?` | `## IconTexture`. |
| `iconAtlas` | `string?` | `## IconAtlas`. |
| `category` | `string?` | `## Category`. |
| `group` | `string?` | `## Group`. |
| `loadOnDemand` | `string?` | `## LoadOnDemand`, as written (`"1"` when set). |
| `defaultState` | `string?` | `## DefaultState`. |
| `addonCompartmentFunc` | `string?` | `## AddonCompartmentFunc`. |
| `dependencies` | `string[]` | `## Dependencies`, else `## RequiredDeps` (one list under two spellings), split into names. |
| `optionalDependencies` | `string[]` | `## OptionalDeps`, split into names. |
| `savedVariables` | `string[]` | `## SavedVariables`, split into names. |
| `savedVariablesPerCharacter` | `string[]` | `## SavedVariablesPerCharacter`, split into names. |

A scalar field is the `.toc` string unchanged, or `nil` when the field is
absent, empty, or one the running client's metadata call does not export.
Nothing is parsed or converted: the snapshot is what the client reports.

**On real clients the metadata call exports only `Title`, `Notes`, `Author`,
`Version`, `IconTexture`, `IconAtlas` and the `X-` fields**, so `interface`,
`category`, `group`, `loadOnDemand`, `defaultState`,
`addonCompartmentFunc`, `savedVariables` and `savedVariablesPerCharacter`
are usually `nil` or empty there, and the two dependency arrays come from the
dependency host calls described below. The fields are still read, so a
client that starts exporting one is served without a ClientKit change.

A list field is always an array, possibly empty. The string is split on
commas and each name is trimmed, so `## OptionalDeps: LibStub,  Ace3 `
yields `{ "LibStub", "Ace3" }`. When the metadata call exports no
dependency list at all — older clients keep dependencies out of it — the
host's own `C_AddOns.GetAddOnDependencies` /
`C_AddOns.GetAddOnOptionalDependencies` (else the legacy globals) fill the
two dependency arrays; the saved-variable lists have no such call and stay
empty. The raw string, when the client exports it, is still reachable
through `Get("Dependencies")`, `Get("RequiredDeps")` and so on.

### Locale fallback

`Title` and `Notes` may be written per locale in a `.toc`
(`## Title-deDE: Mein Addon`). ClientKit reads `GetLocale()` once at
bootstrap into its state and, for these two fields, asks the host for
`<field>-<locale>` before `<field>`. On a host without `GetLocale`, or one
answering something that is not a locale code (`enUS`, `deDE`, `zhCN`), only
the plain fields are read. The client itself displays the same fallback in
its addon list, so `manifest.title` matches what the player sees. The raw
spellings remain reachable through `Get("Title")` and `Get("Title-deDE")`.

### `manifest:Get(field)`

Returns the raw string of any `## Field`, `X-` fields included, or `nil` when
the field is absent, empty or not exported by the client. A field is asked of
the host **once** and remembered on the manifest: the snapshot fields were
remembered when the snapshot was built, absence included, so `Get("Version")`
never reaches the host. A field the `.toc` does not have is *not* remembered
and is asked again on each call, so the memo grows only by fields the file
actually has, never by the names a caller tries. A non-string `field` raises
at the caller; calling `Get` on anything but a manifest raises
`ClientKit.Manifest:Get must be called on a manifest`.

### Read-only

The snapshot refuses every write at the writer's line:

```text
MyAddon/Core.lua:12: ClientKit manifest for "MyAddon" is read-only; field "version" cannot be written
```

It is a proxy with no keys of its own, so `rawget(manifest, "version")` is
`nil` and `getmetatable(manifest)` is `false`; read the fields normally. The
four arrays are shared by every caller of the same manifest and are to be
treated as read-only too: Lua 5.1 cannot refuse writes to an array without
breaking `#` and `ipairs`, and those are what an array is for.

### Host errors

Every host read a manifest makes goes through `pcall`. The clients differ in
which `.toc` fields their metadata call exports, and a client raises for a
field it does not export rather than answering `nil`; for a snapshot that
means "absent", so the field reads `nil` and nothing propagates. The
`GetAddOnMetadata` shim above keeps its documented behaviour and lets host
errors through unchanged.

## Deprecations

A Kit that deprecates one of its own things (an API generation, a facade
method, an option) declares it once with `Deprecate` and calls the reporter
on the deprecated path. The addon that still uses it is told once per call
site, or once per addon when the Kit knows the addon, for the session; never
once per call. Nothing is raised unless a developer switches the session to
`"raise"`. Registry's line budget leaves no room for this, so it lives here,
as `GetManifest` does. ClientKit itself deprecates nothing.

### `ClientKit:Deprecate(spec)`

```lua
local reporter = ClientKit:Deprecate({
  name = "TimerKit:After",        -- what is deprecated
  replacement = "TimerKit:Delay", -- optional: what to use instead
  removal = "TimerKit API 2",     -- required: when, or in what, it goes
})
```

`name` and `removal` are non-empty strings; `replacement` is a non-empty
string or `nil`. A name is anything a reader recognises: `"EventKit API 1"`,
`"SettingsKit:Open option legacy"`. Declaring a name again returns the same
reporter with the newer `removal` and `replacement`, so a Kit upgraded in
place that declares its deprecations again at load adds nothing, and the
newer text is what later reports carry.

Past [`maxDeprecations`](#limits) distinct names, `Deprecate` returns one
shared inert reporter whose `Warn` checks its arguments and does nothing, and
reports the limit once a session (unless the mode is `"silent"`):

```text
MoltenCodes ClientKit: maxDeprecations (128) reached; "TimerKit:Every" and later deprecations report nothing (raise it with ClientKit:SetLimits).
```

It never raises for a full table, because a Kit declares its deprecations
while it loads.

### `reporter:Warn(level?, addonName?)`

```lua
function TimerKit:After(delay, callback)
  reporter:Warn()            -- before anything changes, see "raise" below
  return self:Delay(delay, callback)
end
```

`level` counts as the Kit's own `error(message, level)` would: `1` is the
Kit's method, `2` (the default) the consumer that called it. A Kit that warns
from a helper passes one more per helper. `Warn` must not be tail-called
(`return reporter:Warn()`), since a tail call removes the Kit's frame and the
level then names the wrong caller.

`addonName`, when the Kit knows the consuming addon (the owner of a scope,
say), makes the addon the once-key: the first call from that addon is
reported and every later one costs one table lookup. Without it the once-key
is the call site, and every call reads it from the client (see below).

A report reads:

```text
MoltenCodes: TimerKit:After is deprecated; use TimerKit:Delay. Removal: TimerKit API 2. Called from MyAddon (Interface/AddOns/MyAddon/Core.lua:42).
```

`; use …` is left out without a replacement, and ` (…)` when the client named
no call site. The addon is the `addonName` given, else the folder after
`Interface/AddOns/` in the call site, else `unknown`. In `"report"` mode the
text goes to `geterrorhandler()`, read at every report because an
error-capturing addon replaces the handler after ClientKit loads, or to
`print` on a host without it. Both run under `pcall`: a handler that fails
cannot break the deprecated call.

### Call sites

The call site comes from the client's `debugstack(start, 1, 0)`, the frame
`level` above the Kit's method. The client has no `debug` library (the
Retail client publishes no `debug` global, measured on 12.1.0 build 69933),
and `debugstack` is a core client function on every flavour (Blizzard's own
`Blizzard_ScriptErrors` calls it on Retail, Mists of Pandaria Classic and
Classic Era). The Retail client writes a frame
`[Interface/AddOns/MyAddon/Core.lua]:42: in function <...>`; ClientKit also
accepts `[string "@Interface\AddOns\MyAddon\Core.lua"]:42:` and a bare path
with either separator, and reports the location as
`Interface/AddOns/MyAddon/Core.lua:42`. A frame outside `Interface/AddOns/`
(a chunk loaded from a string) names no addon, and its text is the location.

The raw frame text is the once-key, so a repeated call from a site already
reported costs one `debugstack` call and one lookup, and no string is built
before the lookup. A host without `debugstack`, or a frame the client
answers empty or secret, gives no call site: the report is then made once
per addon given, else once per deprecation.

### Modes

| Mode | What `Warn` does |
|---|---|
| `"report"` (default) | Records the report and hands its text to the host error handler. |
| `"silent"` | Records the report only; `GetDeprecationReports` still lists it. |
| `"raise"` | Raises the report's text at the consumer's line on every call, and records nothing. |

`ClientKit:SetDeprecationMode(mode)` sets the mode for the whole session:
there is one ClientKit, so every addon shares it. `"raise"` is a developer
switch, to find every deprecated call in an addon under development; do not
ship an addon that sets it, since it makes every other addon's deprecated
call fail too. A Kit calls `Warn` before it changes any state, so a raised
report leaves the Kit as it was. Any other value raises at the caller
(`ClientKit:SetDeprecationMode mode must be "report", "silent" or "raise"`).

### `ClientKit:GetDeprecationReports()`

```lua
for _, report in ipairs(ClientKit:GetDeprecationReports()) do
  print(report.addon, report.name, report.removal, report.site)
end
```

Returns a fresh array of fresh rows `{ name, replacement, removal, addon,
site }`, oldest first; `replacement` and `site` may be `nil`. It is for an
addon author listing what this session used, never for a hot path.

### Optional for every Kit

No Kit depends on ClientKit for this. A Kit finds it through
`Registry:Find` at the first deprecated call and remembers the answer, so a
session without ClientKit, or with a revision older than 6, reports nothing
and fails nothing:

```lua
local afterReporter -- nil until looked up, false when ClientKit cannot report

local function warnAfterDeprecated(addonName)
  if afterReporter == nil then
    afterReporter = false
    local ClientKit = Registry:Find("clientKit", 1)
    if type(ClientKit) == "table" and type(rawget(ClientKit, "Deprecate")) == "function" then
      afterReporter = ClientKit:Deprecate({
        name = "TimerKit:After",
        replacement = "TimerKit:Delay",
        removal = "TimerKit API 2",
      })
    end
  end
  if afterReporter then
    afterReporter:Warn(3, addonName) -- 1 this helper, 2 the Kit's method, 3 its caller
  end
end
```

The answer is remembered for the session, so a ClientKit that loads only
after the first deprecated call is not used for that deprecation.

### Cost

A Kit that deprecates nothing costs nothing: until `Deprecate` is called,
the deprecation state is a handful of small tables created at load. `Warn`
on a deprecated path checks its arguments, compares the mode, and then
costs one table lookup with `addonName` (after the first report of that
addon) or one `debugstack` call and one lookup without it. Past
[`maxReports`](#limits) every reporter stops reading call sites and answers
after that comparison. A repeated warning of a known addon allocates nothing.

## Errors

Argument errors name the method, the parameter and the expected type, and
point at the caller's line:

```text
MyAddon/Core.lua:12: ClientKit:IsAtLeast interfaceNumber must be a number
```

A caller-supplied value is formatted into a message only when `IsSecret`
says it is not secret; a secret is described as `<secret value>`. A string is
quoted, a number, boolean or `nil` shown as written, and any other value named
by its type (`<table>`), so a `__tostring` metamethod never runs inside
ClientKit. A secret
`interfaceNumber` passed to `IsAtLeast`, a secret `capability` passed to
`Has`, and a secret `addonName` or `field` passed to `GetManifest` or
`manifest:Get`, is refused at the caller
(`ClientKit:IsAtLeast interfaceNumber must not be a secret value`,
`ClientKit:Has capability must not be a secret value`,
`ClientKit:GetManifest addonName must not be a secret value`,
`ClientKit.Manifest:Get field must not be a secret value`) before it is
compared or used as a table key: insecure code that compares a secret raises
at the comparison, which would name ClientKit's line instead of yours. The same holds for every argument of the
deprecation methods: `Deprecate`'s `spec` and its `name`, `removal` and
`replacement`, `Warn`'s `level` and `addonName`, `SetDeprecationMode`'s
`mode`, and `SetLimits`' table, its keys and its values. `Warn` raises at its
own caller, the Kit, for a bad argument
(`ClientKit.DeprecationReporter:Warn level must be a positive integer or nil`)
and for a receiver that is not a reporter
(`ClientKit.DeprecationReporter:Warn must be called on a reporter`); that is
the Kit's mistake, not the consumer's.

A value that may be secret is never tested as a boolean either (`if x`,
`x and y`, `x or y`, `not x`), because on Retail 12.1.0 that raises inside
the Kit. `manifest:Get` reads its receiver's `name` without testing it and
asks `IsSecret` before lowering it or using it as a key; a receiver whose
`name` is secret belongs to no manifest and is refused with
`ClientKit.Manifest:Get must be called on a manifest`. Every other value
ClientKit tests is its own, a type-checked host function, or a host return
the client does not document as possibly secret (`IsForbidden`,
`CanBeAccessedInContext`, `C_EventUtils.IsEventValid`, `IsAddOnLoaded`,
`GetLocale`, `GetBuildInfo`, and the legacy `GetSpellInfo` of clients that
have no secret values).

Bootstrap failures raise at the line that loaded the file:

| Message | Cause |
|---|---|
| `MoltenCodes ClientKit requires Registry API 2 to be loaded first` | `Registry.lua` is missing or loaded after this file. |
| `MoltenCodes ClientKit requires a valid Registry API 2 facade` | The published Registry has no `Bootstrap`. |
| `MoltenCodes ClientKit package state is corrupted or incomplete` | The shared package state was modified from outside. |

## Limits

| Limit | Default | How to open | UNBOUNDED allowed? |
|---|---|---|---|
| `maxDeprecations`, deprecations declared under distinct names | 128 | `ClientKit:SetLimits({ maxDeprecations = n })`, `n` from 1 to 1024 | No: deprecations are declared by Kits, so a ceiling covers every real need |
| `maxReports`, reports recorded for the session | 256 | `ClientKit:SetLimits({ maxReports = n })`, `n` from 1 to 4096 | No: each report holds a row and a once-key until the session ends |

```lua
ClientKit:SetLimits({ maxReports = 1024 })
local limits = ClientKit:GetLimits() -- { maxDeprecations = 128, maxReports = 1024 }
```

`SetLimits` accepts any subset and returns nothing. It checks every entry
before applying any, so a refused call changes nothing, and raises at the
caller for a table it cannot use (`ClientKit:SetLimits limits must be a
table`), an unknown name (`ClientKit:SetLimits does not know limit
"maxCalls"`) and a value that is not an integer within the range
(`ClientKit:SetLimits limits.maxReports must be an integer from 1 to 4096`).
A limit lowered below what is already held keeps what is held: past
`maxDeprecations` a new name gets the inert reporter, past `maxReports`
nothing more is recorded. `GetLimits` returns a new table on every call. The
limits are shared by the session and survive an in-place upgrade.

Everything else ClientKit retains needs no limit. It keeps a fixed set of
values probed at load (flavour, interface number, build, locale, a fixed
list of capability flags, the bound host functions). The identity and
capability methods read those values; the taint probes and the shims ask
the host on every call and cache nothing.

The manifest cache grows, and its bound is the host's: one record per addon
asked for, keyed by the lower-cased name and stored only when the client
lists that addon (`GetAddOnInfo` without the reason `"MISSING"`, or a
readable `## Title` on a host without that call). The set of installed
addons is fixed when the client starts and no caller can grow it, so a
consumer cannot fill the cache with names, and a misspelt or foreign name
is answered `nil, "unknown"` without being stored. Within a manifest, `Get`
remembers only fields the `.toc` actually has, so that memo is bounded by
the file's own content. A limit on either would change nothing, which is
why there is none.

## Embedded identity and upgrades

ClientKit bootstraps through `Registry:Bootstrap` like every Kit (see
[`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md#how-a-kit-bootstraps)).
The facade table and its `_state` — including the capability table, the
bound host functions and the manifest cache — keep their identity across
compatible revisions: a newer copy re-probes the host into the same tables
and rewrites the facade methods in place, so a reference taken from an older
copy reads the newer answers. A manifest cached before an upgrade is the same
table afterwards, and its `Get` is resolved through a prototype the newer
copy rewrote. An older copy loading after a newer one yields to it.

Revision 2 added the locale, the manifest cache and the manifest prototype to
the state without a schema change; an upgrade over revision 1 creates them
empty and binds the four host functions the manifests use. Revisions 3, 4
and 5 changed no state field, so an upgrade over revision 2, 3 or 4 keeps every
cached manifest as it is. An inherited `manifests` or `manifestPrototype` that is present but not
a table is refused as corrupted state rather than indexed.

Revision 6 added the deprecation state (reporters, reports, the mode, the
limits and the reporter prototype) without a schema change; an upgrade over
revision 5 or older creates it with the defaults and keeps every cached
manifest. A later upgrade keeps it as it is: a reporter a Kit holds is the
same table afterwards, its `Warn` is resolved through the prototype the
newer copy rewrote, and the call sites and addons it already reported stay
reported. Inherited deprecation state that is not the shape revision 6
creates is refused as corrupted.

Revision 7 changed no state field (it refuses a secret `IsAtLeast` argument
before comparing it), so an upgrade over revision 6 keeps the manifest cache
and the whole deprecation state as they are. Revision 8 changed no state field
either (error descriptions name a table by type, and the secret probe falls
back to the global when the client had none at load); an upgrade over
revision 7 keeps everything.

`_state` is private; its layout is not part of the contract.
