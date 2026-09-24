# LocaleKit API

LocaleKit API generation **1** provides translations per addon and locale: write proxies for translation files, one read table per addon with a chosen missing-key behaviour, a report of the keys read but never defined, and a formatter with indexed specifiers.

Implementation revision: **2**.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
LocaleKit.lua
```

Portable WoW code resolves the package through Registry:

```lua
local LocaleKit = MoltenCodes.Registries[2]:Get("localeKit", 1)
```

LocaleKit does not rely on `require()` at runtime.

### Host facilities

LocaleKit reads three host functions, each at call time rather than at load, and works without any of them:

| Facility | Used by | Without it |
|---|---|---|
| `GetLocale` | `NewLocale`, to learn the client locale | The client locale is `enUS`. An answer that is not a locale code is treated the same way. |
| `geterrorhandler` | the `"report"` missing-key mode | The report is passed to `print`. |
| `issecretvalue` | `Format`, `GetLocale`'s `options.maxMissingKeys`, and a read of an undefined key in `"report"` or `"silent"` mode | Nothing is treated as secret. |

## Public surface

| Method | Purpose |
|---|---|
| `NewLocale(addonName, locale, options?)` | Return a write proxy for `locale`, or `nil` when the client does not need it. |
| `GetLocale(addonName, options?)` | Return the addon's read table. |
| `MissingKeys(addonName)` | Return the sorted keys read but never defined. |
| `Format(template, ...)` | Format with sequential and indexed specifiers. |
| `SetLocaleOverride(locale?)` | Use `locale` instead of the client's for addons registered from now on. |
| `UNBOUNDED` | Sentinel for `GetLocale`'s `options.maxMissingKeys`: record every missing key. |

## The client locale

The client locale is, in order:

1. the override set with `SetLocaleOverride`, when there is one;
2. otherwise `GetLocale()`, with `enGB` folded to `enUS`;
3. otherwise `enUS`.

An addon's client locale is fixed by its first `NewLocale` that registers anything, so every file of one addon agrees even if the override changes midway. A locale code is two lower-case and two upper-case letters (`deDE`, `zhTW`); anything else is refused at the caller.

## `LocaleKit:NewLocale(addonName, locale, options?)`

```lua
local L = LocaleKit:NewLocale("MyAddon", "deDE")
if not L then return end
L["Hello"] = "Hallo"
```

Returns a write proxy when the client needs `locale`, and `nil` otherwise. The client needs a locale when:

- it is the client locale (see above), or
- `options.isDefault` is `true`: the default locale is the fallback every client loads.

`nil` registers nothing, so on a client that needs none of an addon's files nothing is allocated for it.

| Option | Default | Meaning |
|---|---|---|
| `isDefault` | `false` | Marks the fallback locale. An addon has at most one; a second, different one raises `LocaleKit:NewLocale MyAddon already has default locale enUS`. Several files may register the same default locale. |

`locale` is not folded: an `enGB` file is never the client's locale, because `enGB` clients are folded to `enUS`. Register English as `enUS`.

### Write proxies

Every call returns a **new** proxy; there is no shared "table currently being filled", so two addons (or two files of one addon) may register in any interleaving.

| Assignment | Stores |
|---|---|
| `L["key"] = "text"` | `"text"` |
| `L["key"] = true` | `"key"`: the key is its own text, so a default file need not repeat English strings. |

Keys must be non-empty strings and values strings or `true`; anything else, including `nil`, raises at the assignment line. Translations cannot be removed.

The two kinds of proxy differ only in what happens when the key already holds text:

| Proxy | Existing key |
|---|---|
| client locale (not `isDefault`) | Overwritten. A later file of the same locale wins. |
| default (`isDefault`) | Kept, so a translation that loaded first is never replaced by the default, and two modules sharing a default string keep the first. |

When the default locale is also the client locale, its proxy is still a default proxy.

The proxy and read-table metatables are protected with `__metatable`: `getmetatable` returns a name instead of the metatable, and `setmetatable` refuses to replace them. A table that carries a proxy metatable without being a proxy `NewLocale` returned (only the debug library can build one) is refused at the assignment line: `LocaleKit translation target is not a proxy returned by LocaleKit:NewLocale`.

Reading through a proxy (`L["key"]`) returns the text stored so far, from any file, or `nil`; it never raises and never reports.

## `LocaleKit:GetLocale(addonName, options?)`

```lua
local L = LocaleKit:GetLocale("MyAddon")
local text = L["Hello"]
```

Returns the addon's read table: the default locale's strings with the client locale's on top, whatever order the files loaded in. It is the same table on every call and for the whole session, and translations registered after the first call appear in it. A lookup of a defined key is one table read.

Raises when the addon registered nothing yet (`LocaleKit:GetLocale found no locale registered for MyAddon; load its translation files first`): the files calling `GetLocale` must load after the translation files, and at least one of them must be needed on this client (a default locale always is).

| Option | Default | Meaning |
|---|---|---|
| `missing` | `"report"` | What reading an undefined key does. |
| `maxMissingKeys` | `1024` | The most missing keys recorded for the addon: a positive integer or `LocaleKit.UNBOUNDED`. See [Limits](#limits). |

### Missing keys

| Mode | Reading an undefined string key |
|---|---|
| `"report"` | Returns the key, stores it as its own value, records it for `MissingKeys`, and reports `LocaleKit: missing translation "key" for MyAddon (deDE)` through `geterrorhandler()` (or `print`). |
| `"silent"` | The same without the report. |
| `"raw"` | Returns `nil`. The table has no metatable and records nothing. |

A **secret key** (Retail 12.x; a unit name read in combat, say) never reaches LocaleKit. The client refuses a secret used as a table key at the index itself, before the table's `__index` runs, even on a table that has one: measured on Retail 12.1.0 b69933, `L[secretKey]` on a read table raised `attempted to index a table that cannot be indexed with secret keys` at the caller's line. So `L[secretKey]` raises the client's error at your line, and nothing is stored, recorded or reported. Check `issecretvalue` before indexing the table with runtime data, and do not index it with a secret. (`readMissing` still hands back a key `issecretvalue` reports as secret without storing or reporting it, for a host that lets the read reach `__index`; Retail 12.1 does not.)

Because the key is stored on the first read, each key is reported once per session and costs a plain table read afterwards. A key that is not a string reads as `nil` and is not recorded. When a translation or default file defines a key after it was read as missing, the new text replaces the stored key and the key leaves `MissingKeys`.

Recording is bounded: past **1024** missing keys per addon (or the addon's `maxMissingKeys`), further missing keys still read as themselves but are not stored, recorded or reported, and the cap itself is reported once, in `"report"` mode, naming the limit and how to raise it. This keeps a read table indexed with runtime data (a unit name, say) from growing without limit. See [Limits](#limits) to open it.

### The mode is fixed by the first call

The first `GetLocale` for an addon fixes its mode. A later call that names a different mode raises at the caller (`LocaleKit:GetLocale MyAddon already uses missing mode "silent", not "report"`); a later call that names no mode, or the same one, returns the table. Name the mode in the file that loads first and omit it elsewhere.

## `LocaleKit:MissingKeys(addonName)`

```lua
for _, key in ipairs(LocaleKit:MissingKeys("MyAddon")) do
  print("untranslated:", key)
end
```

Returns the keys the addon read through its `"report"` or `"silent"` table and no file defined, sorted with `<`. The array is new on every call and belongs to the caller; building it walks the recorded keys, so it is for a coverage report or a debug command rather than a hot path. An addon LocaleKit does not know, or one in `"raw"` mode, returns an empty array.

## `LocaleKit:Format(template, ...)`

```lua
LocaleKit:Format("%s has %d items", "Alice", 3)              -- "Alice has 3 items"
LocaleKit:Format("%2$d Gegenstände hat %1$s", "Alice", 3)    -- "3 Gegenstände hat Alice"
LocaleKit:Format("%1$s, %1$s!", "Bob")                       -- "Bob, Bob!"
LocaleKit:Format("%.2f%%", 12.5)                             -- "12.50%"
```

| Specifier | Takes |
|---|---|
| `%s` | a string or a number |
| `%d` | a number |
| `%f` | a number |
| `%%` | nothing; a literal `%` |

Flags, width and precision (`%-5s`, `%03d`, `%.2f`) behave as in `string.format`. `%N$` before them (`%2$s`, `%1$.2f`) names argument `N`; an argument may be used any number of times and in any order. Specifiers without an index take the arguments in order, counting only specifiers without an index, so `"%s %2$s %1$s"` with `"a", "b"` gives `"a b a"`. Unused arguments are ignored.

The client's own `string.format` supports positional specifiers too: measured on Retail 12.1.0 b69933, it accepted `%2$s %1$s` and `%3$.2f %1$s %2$05d`, and it refused `%100s` with `invalid format (width or precision too long)`. `Format` does not rely on that. It parses the index itself and hands `string.format` only a specifier without an index, with the chosen argument, so a template behaves the same on every client and on a stock Lua 5.1, and a shape the client refuses is reported under LocaleKit's own message below.

Raised at the caller's line:

- `LocaleKit:Format template must be a string`;
- `LocaleKit:Format template needs argument 3 but 2 were given`, for an index or a sequential specifier past the last argument;
- `LocaleKit:Format template argument indexes start at 1`;
- `LocaleKit:Format template has an unsupported specifier "%x"`, including a `%` at the end of the template;
- `LocaleKit:Format template has an invalid specifier "%100s"`, for a shape `string.format` refuses: a width or precision over two digits, or a repeated flag;
- `LocaleKit:Format argument 1 must be a number, got string` (and `must be a string or a number` for `%s`);
- `LocaleKit:Format template must not be a secret value` and `LocaleKit:Format argument 2 must not be a secret value`, see below.

`Format` runs one `string.gsub` per call and allocates only strings (the formatted piece of each specifier and the result), no table and no closure.

### Secret values

On Retail 12.x the client hands tainted code secret values that raise when compared, tested as a boolean or used as table keys, and formatting one produces a secret result. `Format` asks `issecretvalue` about the template and every argument before formatting and refuses a secret one at the caller, so a secret never becomes part of a translated message by accident and `string.gsub` never runs over a secret template (a secret string from the host passed as the template, say). A read table cannot produce a secret template: the client already refuses `L[secretKey]` at the index (see [Missing keys](#missing-keys)). `issecretvalue` is looked up at every call; without it nothing is secret. See [`docs/EMBEDDING.md`](../../../docs/EMBEDDING.md#secret-values-retail-12x).

## `LocaleKit:SetLocaleOverride(locale?)`

```lua
-- In a file that loads before any translation file, for testing only.
LocaleKit:SetLocaleOverride("koKR")
```

Makes every addon registered from now on use `locale` as its client locale; `enGB` is folded to `enUS`. `nil` clears the override. An addon already registered keeps the locale it was registered with, because its read table has already been built for it. The override is shared by every addon in the session and replaces AceLocale's `GAME_LOCALE` global, which LocaleKit does not read.

## Limits

LocaleKit follows the framework rule "bounded by default, opened on purpose" (`docs/DESIGN_CONSTITUTION.md`, principle 4a).

| Limit | Default | How to open | UNBOUNDED allowed? |
|---|---|---|---|
| `maxMissingKeys`, missing keys recorded per addon | `1024` | `LocaleKit:GetLocale(addonName, { maxMissingKeys = n })` | Yes: `{ maxMissingKeys = LocaleKit.UNBOUNDED }`. The read table is the addon's own. |

```lua
local L = LocaleKit:GetLocale("MyAddon", { maxMissingKeys = 4096 })
local everything = LocaleKit:GetLocale("MyAddon", { maxMissingKeys = LocaleKit.UNBOUNDED })
```

- **Reaching the limit is observable.** In `"report"` mode the first key past it is reported once (`LocaleKit: MyAddon has more than 1024 missing translations; further ones are neither recorded nor reported (raise options.maxMissingKeys to record more)`), and every further key still reads as itself; it is neither stored nor added to `MissingKeys`. `"silent"` mode reports nothing, by definition, and `"raw"` records nothing at all, so the limit does not apply to it.
- **The first call fixes the limit, like the mode.** The first `GetLocale` for an addon fixes `maxMissingKeys`: the value it names, or 1024 when it names none. A later call naming a different limit raises at the caller (`LocaleKit:GetLocale MyAddon already uses options.maxMissingKeys 1024, not 2`) and changes nothing; a later call naming the same limit, or none, returns the table. Name it in the file that loads first. This is the rule every Kit follows for limit options on a shared object (HookKit's and CommandKit's `ForAddon`; SignalKit buses differ only in that a call stating no limit does not fix the default).
- **Invalid values raise at the caller and change nothing:** zero, a negative, fractional, infinite or NaN number, any other type and a secret value (`LocaleKit:GetLocale options.maxMissingKeys must be a positive integer or LocaleKit.UNBOUNDED`). The secret check runs first, before the value is compared with `LocaleKit.UNBOUNDED` or a number. A call refused for its mode does not change the limit either.
- **Why open it deliberately.** `UNBOUNDED` is right for an addon whose read table is only ever indexed with literal keys, where the set is finite anyway; an addon that indexes it with runtime data (unit or item names) should keep a bound, because every distinct name read would otherwise stay in the table until `/reload`.
- **`LocaleKit.UNBOUNDED` is one table shared by every embedded copy.** It lives in the package state, so an addon opened with it stays unbounded across an in-place upgrade.

LocaleKit has no package-wide limit and no other retained collection that grows with runtime data: translation strings are written by the addon's own files.

## Error behaviour

Argument failures report the line that called the public method, and write-proxy failures report the assignment line, never a line inside LocaleKit. Messages name the method (`LocaleKit:NewLocale`, `LocaleKit:GetLocale`, `LocaleKit:Format`) or `LocaleKit translation` for a proxy write. Option tables refuse unknown fields and name the alphabetically first one; a key that is not a string is named by its type (`<number key>`), so no `__tostring` runs.

## Performance

| Operation | Cost |
|---|---|
| Lookup of a defined key | One table read, no allocation. |
| Lookup of a missing key | First read: one `rawset` and one report. Later reads: one table read. |
| `NewLocale` for an unneeded locale | Argument checks only; nothing allocated or retained. |
| `NewLocale` for a needed locale | One proxy table; the addon's record on its first call. |
| Proxy write | One `rawset`. |
| `Format` | One `string.gsub`; allocates only strings, no tables. |
| `MissingKeys` | O(k log k) for k missing keys; allocates the result array. |

## Embedded copies and upgrades

Several addons may embed LocaleKit; Registry selects the newest compatible revision and every copy shares one facade. An upgrade happens in place: read tables, their modes and `maxMissingKeys` limits, recorded missing keys, proxies an older copy handed out, the override and the `LocaleKit.UNBOUNDED` sentinel all survive, and the newer implementation runs behind them.

Nothing survives `/reload`: translation files run again.
