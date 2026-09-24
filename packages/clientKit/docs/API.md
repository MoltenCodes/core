# ClientKit API

ClientKit API generation **1** reports the client flavour, build and
capabilities, probes secret values, restricted frames and event names, shims
the host calls whose name or shape differs between flavours, and reads an
addon's `.toc` into a read-only manifest.

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

`API` and `REVISION` are published on the facade as integers.

Every answer is read from the host once, when the file loads, into shared
package state, and read again in place when a newer compatible revision
upgrades the package. After that every probe is a table read and every shim
adds one call to the host function it wraps. Nothing allocates after
bootstrap except `GetSpellInfo` on a client without `C_Spell.GetSpellInfo`,
which builds the one table it returns, and the first `GetManifest` call for
an addon, which builds the snapshot that every later call returns.

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
A non-number `interfaceNumber`, and NaN, raise at the caller.
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
answers `false`, which is correct there: nothing is secret. Ask it before
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

## Errors

Argument errors name the method, the parameter and the expected type, and
point at the caller's line:

```text
MyAddon/Core.lua:12: ClientKit:IsAtLeast interfaceNumber must be a number
```

A caller-supplied value is formatted into a message only when `IsSecret`
says it is not secret; a secret is described as `<secret value>`. A secret
`capability` passed to `Has`, and a secret `addonName` or `field` passed to
`GetManifest` or `manifest:Get`, is refused at the caller
(`ClientKit:Has capability must not be a secret value`,
`ClientKit:GetManifest addonName must not be a secret value`,
`ClientKit.Manifest:Get field must not be a secret value`) before it is
compared or used as a table key.

Bootstrap failures raise at the line that loaded the file:

| Message | Cause |
|---|---|
| `MoltenCodes ClientKit requires Registry API 2 to be loaded first` | `Registry.lua` is missing or loaded after this file. |
| `MoltenCodes ClientKit requires a valid Registry API 2 facade` | The published Registry has no `Bootstrap`. |
| `MoltenCodes ClientKit package state is corrupted or incomplete` | The shared package state was modified from outside. |

## Limits

ClientKit has no limits to open, so it has no `SetLimits` and no `UNBOUNDED`.
It retains a fixed set of values probed at load (flavour, interface number,
build, locale, a fixed list of capability flags, the bound host functions),
and the probes and shims answer from the host on every call and cache
nothing.

The one collection that grows is the manifest cache, and its bound is the
host's: one record per addon asked for, keyed by the lower-cased name and
stored only when the client lists that addon (`GetAddOnInfo` without the
reason `"MISSING"`, or a readable `## Title` on a host without that call).
The set of installed addons is fixed when the client starts and no caller
can grow it, so a consumer cannot fill the cache with names, and a misspelt
or foreign name is answered `nil, "unknown"` without being stored.
Within a manifest, `Get` remembers only fields the `.toc` actually has, so
that memo is bounded by the file's own content. A limit a consumer could
open would therefore change nothing, which is why there is none.

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
empty and binds the four host functions the manifests use. Revisions 3 and 4
changed no state field, so an upgrade over revision 2 or 3 keeps every cached
manifest as it is. An inherited `manifests` or `manifestPrototype` that is present but not
a table is refused as corrupted state rather than indexed.

`_state` is private; its layout is not part of the contract.
