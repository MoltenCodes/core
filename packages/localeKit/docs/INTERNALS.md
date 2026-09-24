# LocaleKit Internals

This document describes implementation invariants for maintainers. It is not an additional public API.

## Package state

`LocaleKit._state` holds everything that must survive an in-place upgrade:

| Field | Meaning |
|---|---|
| `addons` | Addon name to addon record. |
| `recordByStrings` | An addon's read table to its record, for the read metatables. |
| `proxyRecords` | Write proxy to addon record, weak-keyed so a proxy is collected once its file has run. |
| `translatedProxyMetatable`, `defaultProxyMetatable` | The two write-proxy metatables. |
| `reportMetatable`, `silentMetatable` | The two read-table metatables. |
| `localeOverride` | The translator's override, or `false`. |
| `unbounded` | The `LocaleKit.UNBOUNDED` sentinel, created once so every revision publishes the same table and a record's `maxMissingKeys` keeps meaning "unbounded" after an upgrade. The current-state predicate requires the facade field to be this table. |
| `runtimeRevision`, `schema` | Bookkeeping shared with every Kit. |

The four metatables are created once and kept, and carry `__metatable` so callers can neither read nor replace them. Every loading revision writes its own functions into their `__index` and `__newindex` fields, so proxies and read tables created by an older copy run the newer behaviour without being replaced.

## Addon records

A record is created by the first `NewLocale` that returns a proxy, with every field present from construction:

| Field | Meaning |
|---|---|
| `name` | The addon name. |
| `locale` | The client locale, fixed at creation. |
| `defaultLocale` | The `isDefault` locale, or `false`. |
| `strings` | The read table `GetLocale` returns. |
| `missing`, `missingCount` | The set of keys read but never defined, and its size. |
| `capReported` | Whether the missing-key limit has been reported. Never cleared: the limit is fixed by the first `GetLocale`, before the read table has a metatable and so before any key can be recorded as missing. |
| `maxMissingKeys` | The most missing keys recorded: `MAX_MISSING_KEYS` (1024) unless the addon's first `GetLocale` (the one that fixes `mode`) names another positive integer or the `unbounded` sentinel; a later call naming a different value is refused. |
| `mode` | `"report"`, `"silent"`, `"raw"`, or `false` before the first `GetLocale`. |
| `schema` | The record layout version, `1`. |

## One table, two write rules

There is no separate default table and translation table merged at `GetLocale` time. Both kinds of proxy write straight into `strings`:

- the client-locale proxy always `rawset`s;
- the default proxy `rawset`s only when the key is absent or holds its own name because it was read while missing.

This produces "default strings with the client's on top" for every load order, keeps a lookup at one table read, and lets translation files load after the first `GetLocale`. It is AceLocale's design, minus its shared `registering` variable and shared proxy tables.

A proxy is an empty table per call. Nothing is ever stored in it, so `__newindex` sees every assignment; the metatable says which rule applies and `proxyRecords` which addon. Reading through a proxy uses `rawget` on `strings`, so it never triggers the missing-key path.

## Missing keys

`GetLocale` sets `reportMetatable` or `silentMetatable` on `strings` when it fixes the mode (`"raw"` sets none). Their `__index` functions, `readMissingReported` and `readMissingSilently`, both call `readMissing`, which `rawset`s the key as its own value, adds it to `missing`, and reports it in `"report"` mode. The `rawset` is what makes the report happen once and later reads plain table reads. A write that defines a missing key removes it from `missing`.

A key `issecretvalue` reports as secret is returned before any of this, because storing it or concatenating it into the report would raise.

Past the record's `maxMissingKeys` (default `MAX_MISSING_KEYS`, 1024; never for the `unbounded` sentinel) `readMissing` returns the key without storing it, so `__index` runs on every read of such a key; that costs a call but no allocation, and it bounds the table's growth.

## Format

`Format` stages its arguments in the file-level array `formatArguments`, sets `formatArgumentCount` and `formatNextSequential`, and runs one `string.gsub` with the file-level `replaceSpecifier`. Nothing captures the arguments, so no closure or table is created per call; the specifier strings built inside (`"%" .. flags .. conversion`) are short strings Lua interns, so a repeated template allocates nothing new after the first call. Each call still makes strings (every formatted piece and the result), never a table. The staged slots are cleared after every call, successful or not, so the array retains nothing.

`replaceSpecifier` calls `string.format` under `pcall`, because the pattern admits shapes it refuses (a width over 99, a repeated flag); a refusal goes through `failFormat` like every other template error, so the staged arguments are always cleared. It only passes strings and numbers, which runs no metamethod, so `Format` cannot be re-entered while its arguments are staged.

The pattern `%%(%d*)(%$?)([-+ #0]*%d*%.?%d*)(.?)` splits a specifier into digits, an optional `$`, flags/width/precision and the conversion. Digits followed by `$` are an index; otherwise they are the start of the width and are put back into the specifier.

## Error levels

Every argument validator takes an explicit `level`, which is the value `error` needs *inside the function that receives it*; each further hop towards `error` adds one.

- Write-proxy failures come from `translationText`, called by the `__newindex` metamethod, which Lua calls from the assignment line: level 3.
- Template failures come from `failFormat`, called by `replaceSpecifier`, called by `string.gsub`, called by `Format`: level 5. The C function `string.gsub` counts as a level.

The error-level spec pins every one of these.

## Upgrades

The upgrade specs load the same source a second time with `IMPLEMENTATION_REVISION` raised to the shipped revision plus one and check that read tables, modes, missing keys, older proxies and the override survive. A further spec loads the source as revision 1 and then the working file through `require`, the upgrade a client meets when an addon ships the previous release.
