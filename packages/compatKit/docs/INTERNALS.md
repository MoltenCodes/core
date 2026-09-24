# CompatKit Internals

This document describes implementation invariants for maintainers. It is not an additional public API.

## Package state

`CompatKit._state` holds everything that must survive an in-place upgrade:

| Field | Meaning |
|---|---|
| `shims`, `shimCount` | Shim name to its entry (below), and how many exist (bounded by `limits.maxShims`). |
| `skips`, `skipCount` | Names `SkipShim` marked, whether or not a shim of that name exists yet, and how many of them have no shim yet. A registration reads `skips` so an opt-out that arrives first is honoured; `shimCount + skipCount` is what `maxShims` bounds, and a registration for a skipped name moves one from `skipCount` to `shimCount`. |
| `providers`, `providerKindCount` | Kind to its registry object, and how many kinds exist (bounded by `limits.maxProviderKinds`). |
| `registryPrototype`, `registryMetatable` | Shared by every registry object. The metatable's `__metatable` is `"CompatKit.ProviderRegistry"`, which is also how a receiver is recognised. |
| `limits` | The shared limits `SetLimits` writes: `maxShims`, `maxProviders`, `maxProviderKinds`, each a positive integer or the sentinel. |
| `unbounded` | The `UNBOUNDED` sentinel, created once so every revision publishes the same table. |
| `applying` | `true` while `Apply` runs, so a shim cannot re-enter it. The loop runs under `pcall` and the flag is cleared before a failure is re-raised, so it can never stay set. |
| `runtimeRevision`, `schema` | Bookkeeping shared with every Kit. |

The prototype and the metatable are created once and kept; every loading revision writes its functions into the prototype, so a registry an older copy handed out runs the newer behaviour. The catalogue is not state: each loading revision builds its views from its own rows and the newest revision's rows are the ones published.

## Shim entries

One per name, every field present from construction:

| Field | Meaning |
|---|---|
| `name`, `version` | The name, and the highest version registered so far. |
| `implementation` | The pending function, or `false` once the shim was attempted or skipped: a skipped shim's implementation is dropped by `SkipShim`, and `Shim` never stores one for a skipped name. |
| `applied` | The version that ran to completion, or `false`. |
| `attempted` | Whether `Apply` ran, failed or filtered the shim. An attempted shim is never run again in the session. |
| `skipped` | Whether `SkipShim` named it. A skipped shim is not attempted, so it stays pending and is counted as skipped on every `Apply`. |
| `failed` | The error value the implementation raised, unchanged, or `false`. |
| `filtered` | Whether `options.flavours` excluded the running client at `Apply`. |
| `description`, `flavours`, `covers` | The options of the newest registration; arrays are copies of what the caller passed. |
| `missing` | The `covers` names `hasApi` reported absent when the shim ran with ApiKit loaded, or `false`. Reset to `false` when a newer version is recorded after the run, because `covers` moved with it. |

`Shim` writes `version`, the option fields, `implementation` (unless skipped) and, on a recorded version, `missing`; `Apply` writes `implementation`, `applied`, `attempted`, `failed`, `filtered` and `missing`; `SkipShim` writes `skipped`, `implementation`, `skips` and `skipCount`.

## Apply

1. Collect every entry with `attempted == false` into an array and sort it by name.
2. Read the flavour from ClientKit (`Registry:Find("clientKit", 1)`, `GetFlavor`), or `false`.
3. Build the context: a read-only view over `{ flavour, hasApi, hasGlobal }`. `hasApi` builds the installed-surface index on its first call (see below) and keeps it for this `Apply` only.
4. For each pending entry: a skipped one counts as skipped and stays pending; one whose `flavours` exclude the flavour is marked attempted and filtered and counts as skipped; otherwise `missing` is computed, the implementation runs under `pcall`, and the entry is marked attempted with `applied` or `failed` set.

`applying` is set around the loop, which runs under `pcall`, and cleared before any failure is re-raised, so a shim that calls `Apply` raises at its own line and is recorded as failed like any other error, and nothing can leave the flag set. The host error handler is called under `pcall` too, with `print` as the fallback.

## The installed-surface index

`hasApi(name)` answers whether ApiKit's installed surface binds the documented function `name`. Generated flavour files bind by direct alias, so the host function and the wrapper entry are the same value; the check is therefore identity, and no copy of the naming rules exists here. The index is built by walking `MoltenCodes.wow` through at most two nested tables (the depth constant in the source; `classic.era` is the deepest), collecting every function found in a table under an `api` key, and keying them by the function itself. Only the running flavour's `api` table is ever filled, so the walk costs the installed surface once per `Apply` that calls `hasApi`. Without ApiKit (`Registry:Find("apiKit", 1)` is `nil`) the index is `nil` and `hasApi` answers `false`; `hasGlobal` follows the dotted path through the host global table with raw reads: the first segment is a global, every later one a field of the table before it, and a missing or non-table step ends the walk with `nil` (a later segment is never read as a global).

## Provider registries

One object per kind, created by `Providers` and kept in `providers`:

| Field | Meaning |
|---|---|
| `_kind` | The kind string. |
| `_providers` | Name to `{ implementation, probe, priority }`; `probe` is `false` for an always-alive provider. |
| `_order` | Every name, ordered by priority (higher first) and then by name. Maintained at `Register` (insertion) and `Unregister` (removal), so `Resolve` walks it without sorting or allocating. |
| `_count` | How many providers exist (bounded by `limits.maxProviders`). |
| `_resolved` | The name the cascade last answered, or `false`. |

`Resolve(preferred)`:

1. A `preferred` that names a live provider is returned; the memo is untouched. A dead preferred provider is remembered so it is not probed again in this call.
2. The memoised name is returned when its provider still exists, is not the dead preferred one, and its probe says alive; otherwise the memo is cleared and that name is remembered as dead for this call.
3. The cascade walks `_order`, skipping the names that reported dead in this call, returns the first live provider and memoises it.
4. Nothing alive: `nil, "none"`.

A probe is called through `pcall`; a probe that raises is reported through the host error handler and counts as dead, and only `true` counts as alive. `Unregister` clears the memo when it names the removed provider.

## Read-only views

`CATALOGUE`, each of its rows, each row's `flavours` and the shim context are empty proxies whose metatable reads through to the real table and refuses every write at the writer's line with the view's label. On Lua 5.1 `#`, `ipairs` and `pairs` do not see through a proxy, which is why every array view is published with a count (`CATALOGUE_COUNT`, `flavourCount`).
