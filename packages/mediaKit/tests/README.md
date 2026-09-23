# MediaKit Tests

The MediaKit suite covers:

- `Register`: every media type, path and FileDataID data kept as their Lua types, refused data (empty, zero, negative, fractional, infinite, NaN, other types), names, unknown types, a taken name and a taken built-in name refused with `"taken"`, an identical re-registration as a no-op without a signal or list rebuild, a path and a FileDataID never identical, one namespace per type, the 1024-entry cap with `"full"` counting built-ins, `scripts` for fonts only, malformed and unknown scripts, and script sets compared as sets;
- `Fetch`, `Has` and `IsFileDataID`: unknown names, `Has` agreeing with `Fetch`, case sensitivity, option validation, and the FileDataID predicate;
- `List`: byte-wise sorting with built-ins, the same list for four insertion orders, the cached array returned until a registration of that type, a new array after one with the old array left intact, no rebuild after a refused or identical registration, and every type's built-ins;
- scripts: the lists and lookups a `enUS`, `zhCN` and `ruRU` client sees, every other client locale mapped to its script, an unknown locale and a missing `GetLocale` treated as Latin, `anyScript` in `Fetch`, `Has` and `List`, other types never filtered, a refilter when the client's script changes, scripts no client writes, and an undeclared font treated as Latin only;
- built-ins: every documented path, the Cyrillic font files on `ruRU`, and no built-in font on a CJK client;
- `Defaults`: every fallback, the first usable listed font on a CJK client (pack or adopted) and `nil` with none, one object per consumer, a choice registered later, a font the client cannot render, clearing with `nil`, the hidden metatable, argument and receiver errors, and the 1024-consumer bound;
- `OnRegistered`: arguments, per-type delivery, nothing for refused or identical registrations, the connection's lifetime, the entry visible to a listener, and a listener error propagating after the entry is stored;
- LibSharedMedia: `"absent"` without LibStub and with a LibStub that holds no LibSharedMedia; adoption of the five shared types, signals in sorted order, adopted names refused with other data and accepted with the same, MediaKit's entry kept on a clash, invalid entries skipped, a later pack arriving through the callback, idempotence with one subscription, and a LibSharedMedia without CallbackHandler; mirroring with names LibSharedMedia holds skipped, icons and textures kept out, later registrations mirrored, idempotence, and the `langmask` built from a font's declared scripts (western only for an undeclared font); and both directions at once without an adopted entry mirrored back, a mirrored entry returning as a duplicate or a second signal;
- allocation guards (`collectgarbage("count")` with the collector stopped) on `Fetch` and `Has` with and without options, on `List` while nothing was registered, and on `defaults:Get`;
- secret values: a secret type, name, data or script name refused at the caller through an `issecretvalue` stub looked up at call time, and secret LibSharedMedia entries skipped;
- the limits: `GetLimits` defaults and fresh tables, `maxEntriesPerType` raised to its ceiling and lowered without removing entries, `UNBOUNDED` refused for it with the reason and honoured for `maxConsumers`, and invalid, secret or unknown values and non-facade receivers refused at the caller's line without changing anything;
- duplicate embedded loading, Registry publication, yielding to a newer revision, missing Registry, missing SignalKit, an incomplete facade, and an in-place upgrade that keeps entries, lists, connections, defaults, adoption, the single subscription and mirroring, an upgrade that keeps the set limits and the `UNBOUNDED` sentinel, and a refusal of state holding an invalid limit;
- `error` levels: every argument failure reports the caller's own line;
- manifest/runtime API and revision consistency, and the declared dependencies.

The shared fixture does not stub `GetLocale` or LibStub, so `support/MediaKitTestEnv.lua` installs `GetLocale` before MediaKit loads (`NewPackage(clientLocale)`, `SetClientLocale`), provides a minimal LibStub (`InstallLibStub`) and a LibSharedMedia-3.0 stub (`InstallLibSharedMedia`) with `Register`, `Fetch`, `HashTable`, the `LOCALE_BIT_*` fields, a CallbackHandler-shaped `RegisterCallback` fired synchronously from `Register`, and counters for idempotence checks, and removes both globals on `Reset`.

| Spec | Covers |
|---|---|
| `Register_spec.lua` | `Register`, the cap and identical re-registrations |
| `Fetch_spec.lua` | `Fetch`, `Has` and `IsFileDataID` |
| `List_spec.lua` | sorted, cached lists |
| `Scripts_spec.lua` | script filtering per client locale |
| `BuiltIns_spec.lua` | the client's built-in media |
| `Defaults_spec.lua` | defaults objects and their fallbacks |
| `OnRegistered_spec.lua` | registration signals |
| `LibSharedMedia_spec.lua` | adoption and mirroring |
| `SecretValues_spec.lua` | secret arguments and LibSharedMedia entries |
| `Limits_spec.lua` | `SetLimits`, `GetLimits`, the entries ceiling and `UNBOUNDED` |
| `Allocation_spec.lua` | allocation guards |
| `ErrorLevels_spec.lua` | argument errors reported at the caller's line |
| `Bootstrap_spec.lua` | publication, duplicate loads, load order, upgrades |
| `Manifest_spec.lua` | manifest and runtime `API` / `REVISION` agreement, declared dependencies |
