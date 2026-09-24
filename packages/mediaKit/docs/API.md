# MediaKit API

MediaKit API generation **1** provides a typed registry of named media: seven fixed media types, entries that are a path or a FileDataID, fonts that declare the scripts they render, cached sorted lists, registration signals, per-consumer defaults over the client's built-in media, and a two-way bridge to LibSharedMedia-3.0.

Implementation revision: **2**.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
SignalKit.lua
MediaKit.lua
```

Portable WoW code resolves the package through Registry:

```lua
local MediaKit = MoltenCodes.Registries[2]:Get("mediaKit", 1)
```

MediaKit does not rely on `require()` at runtime.

### Host facilities

MediaKit reads three host globals, each at call time rather than at load (the built-in fonts are the one exception: they are chosen once, at load), and works without any of them:

| Facility | Used by | Without it |
|---|---|---|
| `GetLocale` | font filtering in `Fetch`, `Has`, `List` and `Defaults:Get`; the built-in fonts at load | The client writes Latin. An unknown locale is treated the same way. |
| `issecretvalue` | every argument check | Nothing is treated as secret. |
| `LibStub` | `AdoptLibSharedMedia`, `MirrorToLibSharedMedia` | Both return `false, "absent"`. |

`LibStub` is read with `rawget(_G, "LibStub")`, and LibSharedMedia with `LibStub:GetLibrary("LibSharedMedia-3.0", true)`. MediaKit does not use the `interopKit` bridge: it needs a LibStub library's methods, not a Registry entry for it.

## Public surface

| Member | Purpose |
|---|---|
| `Register(type, name, data, options?)` | Add an entry. `true`, or `nil, "taken"` / `nil, "full"`. |
| `Fetch(type, name, options?)` | The entry's data, or `nil`. |
| `Has(type, name, options?)` | Whether `Fetch` would return data. |
| `List(type, options?)` | The cached sorted array of names. |
| `OnRegistered(type, callback)` | A SignalKit connection fired for each new entry. |
| `Defaults(consumerName)` | The consumer's defaults object. |
| `AdoptLibSharedMedia()` | Adopt LibSharedMedia's entries read-only and follow new ones. |
| `MirrorToLibSharedMedia()` | Register our entries into LibSharedMedia and keep doing so. |
| `IsFileDataID(data)` | Whether `data` is a FileDataID rather than a path. |
| `SetLimits(limits)` | Change the shared limits (`maxEntriesPerType`, `maxConsumers`). Returns nothing. |
| `GetLimits()` | A fresh table of both limits; allocates. |
| `MAX_ENTRIES_PER_TYPE` | `1024`, the default of `maxEntriesPerType`. |
| `UNBOUNDED` | Sentinel that lifts `maxConsumers`; the same table for every revision. |
| `API`, `REVISION` | `1`, `2`. |

## Media types

The set is fixed. Any other value, including a differently cased one (`"statusBar"`), is refused at the caller by every method that takes a type:

| Type | What it names | LibSharedMedia type |
|---|---|---|
| `background` | a frame backdrop background | `background` |
| `border` | a frame backdrop edge | `border` |
| `font` | a font file | `font` |
| `icon` | an icon texture | none |
| `sound` | a sound file | `sound` |
| `statusbar` | a status bar texture | `statusbar` |
| `texture` | any other texture | none |

Each type is its own namespace: `"Solid"` may be both a `statusbar` and a `background`.

## Data: path or FileDataID

An entry's data is one of:

- a **path**: a non-empty string such as `[[Interface\AddOns\MyPack\Bar.tga]]`;
- a **FileDataID**: a finite positive integer such as `569593`, the client's numeric id of a file it ships.

The type is kept as given: `Fetch` returns the string or the number, and `MediaKit:IsFileDataID(data)` tells them apart (it is `false` for strings, `0`, negatives, fractions, `math.huge`, NaN and secret values). Client APIs such as `SetTexture`, `SetFont` (paths only) and `PlaySoundFile` accept one or both; which one is the caller's knowledge, so MediaKit neither converts nor probes files.

## Scripts

A font declares the writing scripts it renders with `options.scripts`, an array of names from this fixed set. **Without the option a font is taken to render `latin` only**, as LibSharedMedia assumes; declare the scripts explicitly for any font that renders more.

| Script | Client locales that write it |
|---|---|
| `latin` | `enUS`, `enGB`, `deDE`, `frFR`, `esES`, `esMX`, `itIT`, `ptBR`, `ptPT`, any unknown locale, and a client without `GetLocale` |
| `cyrillic` | `ruRU` |
| `cjkSimplified` | `zhCN` |
| `cjkTraditional` | `zhTW` |
| `korean` | `koKR` |
| `greek` | none today |
| `japanese` | none today |

`greek` and `japanese` exist so a font can describe itself fully; a font that declares only those is never offered by default on any current client.

The client's script is read from `GetLocale()` at every call. For fonts:

- `Fetch` and `Has` answer as if the font did not exist when it does not render the client's script;
- `List("font")` holds only the fonts that render it;
- `options.anyScript = true` switches the filter off in all three.

Other types are never filtered.

## `MediaKit:Register(type, name, data, options?)`

```lua
MediaKit:Register("statusbar", "MyPack Smooth", [[Interface\AddOns\MyPack\Smooth.tga]])
MediaKit:Register("sound", "MyPack Chime", 569593)
MediaKit:Register("font", "MyPack Sans", [[Interface\AddOns\MyPack\Sans.ttf]], {
    scripts = { "latin", "cyrillic" },
})
```

| Result | When |
|---|---|
| `true` | The entry was added, **or** the name already holds the same data (and, for a font, the same set of scripts; an undeclared font's set is `{ "latin" }`). The second case changes nothing and fires nothing. |
| `nil, "taken"` | The name already holds different data or scripts, whoever registered it: another addon, the built-ins, or LibSharedMedia through adoption. The first registration stays. |
| `nil, "full"` | The type already holds `maxEntriesPerType` entries (default `MAX_ENTRIES_PER_TYPE`, 1024), counting built-ins and adopted ones. See [Limits](#limits). |

A path and a FileDataID are never "the same data", even for the same file. Script sets compare as sets: order and repeats do not matter.

| Option | Default | Meaning |
|---|---|---|
| `scripts` | `{ "latin" }` | Fonts only; a non-empty array of script names. Refused for other types. |

Raised at the caller: an unknown type; a name that is not a non-empty string; data that is neither a non-empty string nor a FileDataID; a secret type, name, data or script name; an option table that is not a table or has an unknown field; `scripts` on a non-font, empty, not a table, or naming an unknown script.

A successful registration stores the entry, invalidates the type's lists, mirrors it into LibSharedMedia when mirroring is on, and then fires `OnRegistered`, in that order.

## `MediaKit:Fetch(type, name, options?)` and `MediaKit:Has(type, name, options?)`

```lua
local path = MediaKit:Fetch("statusbar", "MyPack Smooth")
if MediaKit:Has("font", savedFont) then --[[ use it ]] end
```

`Fetch` returns the data or `nil`; `Has` returns whether `Fetch` with the same arguments would return data. There is no default substitution: ask a defaults object for a name that always exists. A name must be a non-empty string; `nil` is refused at the caller, so read a saved name through `defaults:Get` rather than straight from saved variables.

| Option | Default | Meaning |
|---|---|---|
| `anyScript` | `false` | Fonts only in effect: ignore whether the font renders the client's script. |

## `MediaKit:List(type, options?)`

```lua
for _, name in ipairs(MediaKit:List("statusbar")) do --[[ add a row ]] end
```

Returns the names of the type sorted with `<` (byte order: upper case before lower case, `"Bar 10"` before `"Bar 2"`). The order depends only on the names, never on the order they were registered in.

**The array is shared and read-only.** Every caller receives the same cached array until the next registration of that type; do not sort, append to or remove from it. A registration makes the next `List` build a **new** array; an array handed out earlier is never modified, so iterating one while registering is safe. For fonts, a change of the client's script also rebuilds. Font lists are filtered by script unless `options.anyScript`, and the two lists are cached separately.

## `MediaKit:OnRegistered(type, callback)`

```lua
local connection = MediaKit:OnRegistered("font", function(mediaType, name, data)
    refreshFontDropdown()
end)
```

Connects `callback` to every entry added to `type` from now on — registered, built-in or adopted — and returns a SignalKit connection (`connection:Disconnect()`, `connection:IsConnected()`; see [`signalKit/docs/API.md`](../../signalKit/docs/API.md)). The connection belongs to the caller. Listeners run in connection order after the entry is stored, so `Fetch` and `List` already see it. A listener error propagates to whoever registered, as SignalKit's `Fire` does, after the entry was stored; an identical or refused registration fires nothing.

## `MediaKit:Defaults(consumerName)`

```lua
local defaults = MediaKit:Defaults("MyAddon")
defaults:Set("font", MyAddonDB.font)
fontString:SetFont(MediaKit:Fetch("font", defaults:Get("font")), 12, "")
```

Returns the defaults object of `consumerName`, the same object on every call. There is no global default: each addon or module keeps its own choices, and nobody can change another consumer's.

| Method | Meaning |
|---|---|
| `defaults:Set(type, name)` | Choose `name` for `type`, or clear the choice with `nil`. The name need not be registered yet. |
| `defaults:Get(type)` | The first name this client can use (`Has(type, name)` is true) of, in order: the consumer's choice, the type's built-in fallback below, the first name of `List(type)` (for fonts, filtered to the client's script, adopted LibSharedMedia fonts included). `nil` only when the type holds nothing this client can use. |

Because `Get` checks at every call, a choice from a pack that loads later is answered as soon as the pack registers it, and a font the client cannot render yields the next step instead. Only fonts reach the third step, on a client whose script no built-in font renders. `Get` allocates nothing while the list is cached. At most `maxConsumers` consumers are created (default 1024; see [Limits](#limits)); the next new name raises at the caller with `MediaKit:Defaults refuses more than <n> consumers`.

### Built-in media

These are **the client's own files**, shipped with the game on every flavour; MediaKit ships no media. They are registered once, at load, with the names LibSharedMedia-3.0 uses for the same files, so a name saved by an addon that used LibSharedMedia keeps working.

| Type | Name | Data | Fallback of `Get` |
|---|---|---|---|
| `background` | `Blizzard Dialog Background` | `Interface\DialogFrame\UI-DialogBox-Background` | yes |
| `background` | `Blizzard Tooltip` | `Interface\Tooltips\UI-Tooltip-Background` | |
| `background` | `Solid` | `Interface\Buttons\WHITE8X8` | |
| `border` | `Blizzard Dialog` | `Interface\DialogFrame\UI-DialogBox-Border` | |
| `border` | `Blizzard Tooltip` | `Interface\Tooltips\UI-Tooltip-Border` | yes |
| `border` | `None` | `Interface\None` | |
| `font` | `Arial Narrow` | `Fonts\ARIALN.TTF` | |
| `font` | `Friz Quadrata TT` | `Fonts\FRIZQT__.TTF` (`ruRU`: `Fonts\FRIZQT___CYR.TTF`) | yes |
| `font` | `Morpheus` | `Fonts\MORPHEUS.TTF` (`ruRU`: `Fonts\MORPHEUS_CYR.TTF`) | |
| `font` | `Skurri` | `Fonts\SKURRI.TTF` (`ruRU`: `Fonts\SKURRI_CYR.TTF`) | |
| `icon` | `Question Mark` | `Interface\Icons\INV_Misc_QuestionMark` | yes |
| `sound` | `None` | `Interface\Quiet.ogg` | yes |
| `statusbar` | `Blizzard` | `Interface\TargetingFrame\UI-StatusBar` | yes |
| `statusbar` | `Solid` | `Interface\Buttons\WHITE8X8` | |
| `texture` | `Solid` | `Interface\Buttons\WHITE8X8` | yes |

The built-in fonts render `latin` on every client, and `latin` and `cyrillic` on a `ruRU` client, which ships the Cyrillic files above. No built-in font renders a CJK or Korean script, because those clients' font files differ by locale and are not part of this contract; on such a client `List("font")` holds only pack fonts that declare the script, and `defaults:Get("font")` answers the first of them (or `nil` when there is none). LibSharedMedia registers those clients' own fonts, so `AdoptLibSharedMedia` makes them available.

## LibSharedMedia-3.0

LibSharedMedia-3.0 is the media registry most existing addons and packs use. MediaKit bridges the five types both registries share (`background`, `border`, `font`, `sound`, `statusbar`); `icon` and `texture` stay MediaKit's own. Nothing happens until one of these two methods is called, and each can be called again safely.

### `MediaKit:AdoptLibSharedMedia()`

```lua
local found, added = MediaKit:AdoptLibSharedMedia()
```

- Reads `LibSharedMedia:HashTable(type)` for each shared type and adds every entry MediaKit does not hold as an **adopted** entry, in sorted name order (so `OnRegistered` fires deterministically).
- Registers one callback for `LibSharedMedia_Registered` through LibSharedMedia's CallbackHandler (`RegisterCallback`), so packs registering later are adopted as they arrive. A LibSharedMedia without `RegisterCallback` is read on each call only.
- Returns `true` and the number of entries this call added, or `false, "absent"` when LibStub or LibSharedMedia-3.0 is not loaded. A second call re-reads the tables and never subscribes twice.

Adopted entries are **read-only**: `Register` with the same name and data returns `true` and changes nothing, with other data `nil, "taken"`. They appear in `List`, `Fetch`, `Has` and `OnRegistered` like any other entry. An adopted font is offered on every client, because LibSharedMedia already refused, at its own registration, the fonts this client's locale cannot render. Entries whose name is not a non-empty string, whose data is not a path or FileDataID, or that are secret are skipped. When MediaKit already holds a name with other data, MediaKit's entry stays and LibSharedMedia's is not adopted. Adoption stops quietly at the `maxEntriesPerType` limit.

### `MediaKit:MirrorToLibSharedMedia()`

```lua
local found, mirrored = MediaKit:MirrorToLibSharedMedia()
```

- Calls `LibSharedMedia:Register(type, name, data, langmask)` for every MediaKit entry of the shared types that was **not** adopted from it and whose name LibSharedMedia does not hold yet, in sorted name order. Built-ins LibSharedMedia already has are skipped by the same rule.
- For a font, `langmask` is the sum of LibSharedMedia's `LOCALE_BIT_*` values for the scripts it declares, so an undeclared font is `LOCALE_BIT_western` only (`latin` → `LOCALE_BIT_western`, `cyrillic` → `LOCALE_BIT_ruRU`, `cjkSimplified` → `LOCALE_BIT_zhCN`, `cjkTraditional` → `LOCALE_BIT_zhTW`, `korean` → `LOCALE_BIT_koKR`; `greek` and `japanese` add nothing), read from the library and defaulting to its long-standing values `128`, `2`, `4`, `8`, `1`. LibSharedMedia may refuse a font its mask excludes on this client; that is its rule.
- From then on, every successful `Register` of a shared type is mirrored the same way before `OnRegistered` fires.
- Returns `true` and the number of entries LibSharedMedia accepted in this call, or `false, "absent"`. A second call registers only what is new.

### No echo

With both directions on, nothing bounces:

- an entry adopted from LibSharedMedia is never mirrored back to it;
- an entry mirrored into LibSharedMedia comes back through `LibSharedMedia_Registered` while `Register` is still running, finds itself already present and adds nothing, so there is no duplicate and no second signal.

## Secret values

On Retail 12.x the client hands tainted code secret values that raise when compared or used as table keys. MediaKit asks `issecretvalue` about a type, name, data or script name before any comparison and refuses a secret one at the caller (`MediaKit:Register name must not be a secret value`); `IsFileDataID` answers `false` for a secret, and adoption skips secret LibSharedMedia entries. `issecretvalue` is looked up at every call; without it nothing is secret. See [`docs/EMBEDDING.md`](../../../docs/EMBEDDING.md#secret-values-retail-12x).

## Limits

| Limit | Default | How to open | UNBOUNDED allowed? |
|---|---|---|---|
| `maxEntriesPerType` | 1024 (`MAX_ENTRIES_PER_TYPE`) | `MediaKit:SetLimits({ maxEntriesPerType = n })`, `n` from 1 to 16384 | No: entries are never removed and are mirrored into LibSharedMedia |
| `maxConsumers` | 1024 | `MediaKit:SetLimits({ maxConsumers = n })` | Yes |

```lua
MediaKit:SetLimits({ maxEntriesPerType = 4096 })
MediaKit:SetLimits({ maxConsumers = MediaKit.UNBOUNDED })
local limits = MediaKit:GetLimits() -- a fresh table; allocates
```

`SetLimits` accepts any subset of the limits and returns nothing. It raises at the caller's line, **before changing anything**, when `limits` is not a table, names an unknown limit (`MediaKit:SetLimits limits.<name> is not a recognised limit`), or gives a secret or invalid value: `maxEntriesPerType` must be an integer from 1 to 16384, and `maxConsumers` a positive integer or `MediaKit.UNBOUNDED`. `GetLimits` returns a new table on every call, with `MediaKit.UNBOUNDED` itself for a lifted limit.

**The limits are shared by every consumer in the session**: every embedded copy and every addon uses one set, like the entries themselves. A library or media pack should rely on the defaults; an addon that raises a limit raises it for everybody.

Why the two limits differ:

- **`maxEntriesPerType` refuses `UNBOUNDED`** and stops at a ceiling of 16384. Entries are never removed, every addon's `List` (and so every media dropdown) sorts and returns all of them, and mirrored entries land in LibSharedMedia, which has no way to unregister. The memory and the list work belong to every consumer, not to the one that registered. Sixteen times the default covers any real media collection.
- **`maxConsumers` accepts `UNBOUNDED`.** A defaults object holds only its own consumer's choices and nobody else sees it, so the memory is the consumers' own.

Lowering a limit removes nothing: entries and defaults objects that exist stay, a further entry is refused with `nil, "full"`, and a further consumer name raises, until the count is under the limit again.

## Error behaviour

Argument failures report the line that called the public method, never a line inside MediaKit. Messages name the method (`MediaKit:Register`, `MediaKit.Defaults:Set`) and the argument. Option tables refuse unknown fields and name the alphabetically first one; a key or script that is not a string is named by its type (`<number>`), and `SetLimits` names an unknown key that is a table, function or userdata the same way (`limits.<table>`), so no `__tostring` runs. Calling a defaults method with `.` instead of `:` raises `MediaKit.Defaults:Get must be called on a defaults object; use defaults:Get(...)`.

`Register` reports ordinary outcomes (`"taken"`, `"full"`) as results rather than errors, because two independent addons choosing the same name is not a programming error in either.

## Performance

| Operation | Cost |
|---|---|
| `Fetch`, `Has` | Argument checks and one table read; a font adds one `GetLocale` call. No allocation. |
| `List` unchanged | Argument checks and a version comparison. No allocation. |
| `List` after a registration | O(n log n) for n entries; one new array. |
| `Register` | One entry table; the signal's dispatch; a LibSharedMedia `Register` when mirroring. |
| `defaults:Get` | At most two `Has` checks and a cached `List`. No allocation while the list is cached. |
| `AdoptLibSharedMedia` | O(n log n) per type for n LibSharedMedia entries; one temporary name array per type. |
| `MirrorToLibSharedMedia` | O(n) per type after the list is built. |
| `GetLimits` | One table. |

## Embedded copies and upgrades

Several addons may embed MediaKit; Registry selects the newest compatible revision and every copy shares one facade. An upgrade happens in place: entries, cached lists, signals and their connections, defaults objects, the limits a consumer set, the `UNBOUNDED` sentinel, and the LibSharedMedia adoption, subscription and mirroring all survive. The callback LibSharedMedia holds dispatches through package state, so a newer revision replaces its behaviour without subscribing again. Built-ins are registered by the first copy only. Revision 2 keeps the revision 1 state as it is and replaces the methods only.

Nothing survives `/reload`: packs register again.

## Deviations from the planned contract

The nine-point plan in `docs/ROADMAP.md` is followed except where recorded here:

- **LibStub directly, not through the LibStub bridge.** Point 3 says "through the LibStub bridge". MediaKit reads `rawget(_G, "LibStub")` itself: it needs LibSharedMedia's methods and callback, which the bridge's Registry entry does not add, and depending on `interopKit` would make every media pack embed it.
- **Mirroring is explicit.** Point 2 says MediaKit mirrors into LibSharedMedia "when it is present". Because LibSharedMedia may load after MediaKit, and writing into another library should be the embedding addon's decision, mirroring starts at `MirrorToLibSharedMedia()` and continues from then on. The method is an addition to point 4's surface.
- **`Defaults(consumerName)`** is the surface for point 2's "per-consumer defaults", with `Set` and `Get`; `Get` falls back to the **built-in media**, which MediaKit registers at load. These are the client's own files, so the non-goal "shipping media" holds.
- **Additions:** `options.anyScript` on `Fetch`, `Has` and `List`; the `nil, "full"` result; `true` for an identical re-registration; `MAX_ENTRIES_PER_TYPE`; the count returned by the two LibSharedMedia methods; a 1024-consumer bound on `Defaults`; `SetLimits`, `GetLimits` and `UNBOUNDED`, which open both bounds.
- **Listener errors propagate** to the registering caller, as SignalKit's `Fire` does, after the entry is stored; they are not isolated.
- **No built-in CJK or Korean font**; see [Built-in media](#built-in-media). `defaults:Get` falls back to the first usable listed font instead.
- **An undeclared font renders `latin` only**, matching LibSharedMedia's default, so a Latin font is never offered to a CJK or Korean client by omission.
