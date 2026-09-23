# ClientKit API

ClientKit API generation **1** reports the client flavour, build and
capabilities, probes secret values, restricted frames and event names, and
shims the host calls whose name or shape differs between flavours.

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

`API` and `REVISION` are published on the facade as integers.

Every answer is read from the host once, when the file loads, into shared
package state, and read again in place when a newer compatible revision
upgrades the package. After that every probe is a table read and every shim
adds one call to the host function it wraps. Nothing allocates after
bootstrap except `GetSpellInfo` on a client without `C_Spell.GetSpellInfo`,
which builds the one table it returns.

The values are fixed for the session. A client does not change flavour,
build or API surface without a restart, so ClientKit does not re-read them.

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
| `secretValues` | `issecretvalue`, which `IsSecret` uses (Retail 12.0 and later) |
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
secret values — the Classic flavours, Retail before 12.0 — every value
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
classID, subclassID, bindType, expansionID, setID, isCraftingReagent
```

Trailing values an older client does not provide are `nil`. Nothing is
returned while the item is not in the client's cache; the client then
requests it and fires `GET_ITEM_INFO_RECEIVED`, after which a second call
succeeds. A host with neither call returns `nil`.

## Errors

Argument errors name the method, the parameter and the expected type, and
point at the caller's line:

```text
MyAddon/Core.lua:12: ClientKit:IsAtLeast interfaceNumber must be a number
```

A caller-supplied value is formatted into a message only when `IsSecret`
says it is not secret; a secret is described as `<secret value>`.

Bootstrap failures raise at the line that loaded the file:

| Message | Cause |
|---|---|
| `MoltenCodes ClientKit requires Registry API 2 to be loaded first` | `Registry.lua` is missing or loaded after this file. |
| `MoltenCodes ClientKit requires a valid Registry API 2 facade` | The published Registry has no `Bootstrap`. |
| `MoltenCodes ClientKit package state is corrupted or incomplete` | The shared package state was modified from outside. |

## Limits

ClientKit has no limits to open, so it has no `SetLimits` and no `UNBOUNDED`. It retains a fixed set of values probed at load (flavour, interface number, build, a fixed list of capability flags, the bound host functions) and nothing any call can grow: the probes and shims answer from the host on every call and cache nothing.

## Embedded identity and upgrades

ClientKit bootstraps through `Registry:Bootstrap` like every Kit (see
[`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md#how-a-kit-bootstraps)).
The facade table and its `_state` — including the capability table and the
bound host functions — keep their identity across compatible revisions: a
newer copy re-probes the host into the same tables and rewrites the facade
methods in place, so a reference taken from an older copy reads the newer
answers. An older copy loading after a newer one yields to it.

`_state` is private; its layout is not part of the contract.
