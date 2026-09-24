# CompatKit API

CompatKit API generation **1** provides named, versioned shims applied once per
session with a host opt-out, provider registries with liveness probes and a
deterministic fallback cascade, and the read-only catalogue of taint-hostile
Blizzard subsystems.

Implementation revision: **2**.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
CompatKit.lua
```

Portable WoW code resolves the package through Registry:

```lua
local CompatKit = MoltenCodes.Registries[2]:Get("compatKit", 1)
```

CompatKit does not rely on `require()` at runtime.

### Optional dependencies and host facilities

CompatKit finds two Kits at call time through `Registry:Find` and reads two host
globals at call time; it works without any of them.

| Facility | Used by | Without it |
|---|---|---|
| ClientKit API 1 | `Apply`: `context.flavour` and `options.flavours` filtering | `context.flavour` is `false`; every shim applies whatever its `flavours`. |
| ApiKit API 1 (with the client's flavour file) | `context.hasApi`, `options.covers` | `hasApi` answers `false` for every name; `missing` stays `false`. |
| `issecretvalue` | every argument check | Nothing is treated as secret. |
| `geterrorhandler` | failing shims and probes | The failure is printed, as the client's default handler does. |

## Public surface

| Member | Purpose |
|---|---|
| `Shim(name, version, implementation, options?)` | Record a shim. `true, "pending" \| "replaced" \| "recorded"` or `false, "ignored" \| "full"`. |
| `SkipShim(name)` | Mark a shim never to run, before or after its registration. `true`, or `false, "full"`. |
| `GetShims()` | A fresh, name-sorted array of fresh shim records. |
| `Apply()` | Run every pending shim that is not skipped and applies to the client, once. Returns `applied, skipped, failed`. |
| `Providers(kind)` | The provider registry of `kind`, the same object on every call. |
| `SetLimits(limits)` | Change the shared limits (`maxShims`, `maxProviders`, `maxProviderKinds`). Returns nothing. |
| `GetLimits()` | A fresh table of the three limits; allocates. |
| `CATALOGUE`, `CATALOGUE_COUNT` | The read-only catalogue and how many rows it has. |
| `UNBOUNDED` | Sentinel that lifts any limit; the same table for every revision. |
| `API`, `REVISION` | `1`, `1`. |

Every method checks its receiver: `CompatKit.Shim(...)` raises
`CompatKit:Shim must be called on the CompatKit facade; use CompatKit:Shim(...)`.

## Shims

A shim is a named fix that must run at most once per session, however many
addons embed it, and that the owner of the session can switch off. CompatKit
keeps one entry per name.

### `CompatKit:Shim(name, version, implementation, options?)`

- `name` is a non-empty string; use a prefix that is yours
  (`"MyAddon.FixDropDownTaint"`).
- `version` is a positive integer. The highest version registered under a
  name before `Apply` is the one that runs.
- `implementation` is `function(context)`; see [The context](#the-context).
- `options` is an optional table with any of:

| Option | Type | Meaning |
|---|---|---|
| `description` | string | What the shim does; carried into `GetShims`. |
| `flavours` | non-empty array of strings | ClientKit flavour ids (`"mainline"`, `"mists"`, `"tbc"`, `"classic"`) the shim applies to. On another flavour `Apply` filters it. Without ClientKit the shim applies everywhere. Any non-empty string is accepted, so a flavour a later ClientKit adds needs no CompatKit change. |
| `covers` | non-empty array of strings | Documented API names (`"C_TooltipInfo.GetUnit"`, `"GetMouseFoci"`: an identifier, or two identifiers joined by one dot) the shim relates to. When ApiKit is loaded, `Apply` records in the shim's `missing` field the names `hasApi` reports absent. Informational: nothing is refused. |

An unknown option field is refused by name.

| Result | When |
|---|---|
| `true, "pending"` | A new name. The shim waits for `Apply`. |
| `true, "replaced"` | A higher version than the pending one; the new implementation and options replace it. For a skipped shim only the version and options move: its implementation is never kept. |
| `true, "recorded"` | A higher version than one that was already attempted (applied, failed or filtered). `version` and the options move; the implementation is **not** run: shims are applied once. `GetShims` shows `version` (newest) beside `applied` (the one that ran), and `missing` is reset to `false` because it described the version that ran. |
| `false, "ignored"` | An equal or lower version. Nothing changes. |
| `false, "full"` | A new name while the shims plus the skips waiting for their shim already reach `maxShims`. A name `SkipShim` marked earlier holds its slot and is never refused. See [Limits](#limits). |

A shim is never removed; a name lives for the session.

### `CompatKit:SkipShim(name)`

Marks `name` as never to run and returns `true`. Called before the
registration, the mark is kept and applied when the shim arrives; called for a
pending shim, its implementation is dropped at once; called after `Apply` ran
the shim, the record shows `skipped = true` beside `applied`, and nothing is
undone. A skipped shim stays in `GetShims` and is counted in `Apply`'s
`skipped` result on every call, because it stays pending; a name nothing
registered is not listed. A skip cannot be undone: the opt-out is the host's
decision for the session.

A skip for a name that has no shim yet is retained for the session in case the
shim arrives, so it takes a slot of `maxShims` like a shim does; when the shim
arrives it takes that slot over. `SkipShim` returns `false, "full"` for such a
name when the shims plus the waiting skips already reach the limit, and `true`
without needing a slot for a name that is registered or already skipped.

### `CompatKit:Apply()`

Runs every pending shim in name order (byte-wise `<` on the names, so the
order is the same in every session) and returns three counts for this call:

- `applied` — shims that ran to completion;
- `skipped` — shims left out because `SkipShim` named them or their `flavours`
  exclude the client's flavour;
- `failed` — shims whose implementation raised.

Each implementation runs under `pcall`. A failure is handed to
`geterrorhandler()` unchanged (it may be a secret string) and recorded in the
shim's `failed` field; the shims behind it still run. The failing shim is not
retried: a shim is attempted once, whatever the outcome. The error handler is
itself called under `pcall`: a handler that raises falls back to `print`, and
the whole loop runs under a guard that is cleared whatever happens, so one
failure can never leave `Apply` refusing every later call.

A second `Apply` runs only shims registered since the first; an `Apply` with
nothing pending returns `0, 0, 0`. A shim may register another shim, which
runs on the next `Apply`; a shim that calls `Apply` fails with
`CompatKit:Apply cannot be called from inside a shim` and is recorded as failed.

Taint: `pcall` isolates errors, not taint. Every shim runs on whatever
execution path called `Apply`, and a shim that touches secure state taints it
for the caller as well; the catalogue below says what not to touch.

### The context

Every implementation receives one read-only table (a write raises at the
writer's line):

| Field | Meaning |
|---|---|
| `flavour` | `ClientKit:GetFlavor()` when ClientKit is loaded, else `false`. |
| `hasApi(name)` | Whether ApiKit's installed surface binds the documented function `name`: `"C_TooltipInfo.GetUnit"`, or a documented global such as `"GetMouseFoci"`. Bindings are direct aliases of host functions, so the check is identity against the host's function: the name must exist on the host **and** be bound by the installed flavour file. `false` without ApiKit, without a flavour file for the running client, for an undocumented name and for a documented function the client lacks. |
| `hasGlobal(name)` | Whether the host global `name` is not `nil`. A dotted path (`"C_AddOns.GetAddOnMetadata"`) is followed with raw reads; a path through a non-table is `false`. |

`hasApi` builds its index of the installed surface once per `Apply`, on its
first call, so a flavour file that loads between two `Apply` calls is seen by
the second. Both helpers refuse a secret or empty name at the shim's line.

### `CompatKit:GetShims()`

Returns a new array of new records, sorted by name:

| Field | Meaning |
|---|---|
| `name` | The shim's name. |
| `version` | The highest version registered. |
| `applied` | The version that ran, or `false`. |
| `skipped` | Whether `SkipShim` named it. |
| `failed` | The error value the implementation raised, or `false`. |
| `status` | `"pending"`, `"applied"`, `"skipped"`, `"failed"` or `"filtered"`; see below. |
| `description` | `options.description`, or `false`. |
| `flavours` | A copy of `options.flavours`, or `false`. |
| `covers` | A copy of `options.covers`, or `false`. |
| `missing` | The `covers` names `hasApi` reported absent when the shim ran with ApiKit loaded (an empty array when none was); `false` before the shim ran, without ApiKit, for a shim without `covers`, and for a skipped or filtered shim. |

`status` is the first that applies: `"applied"` when `applied` is set,
`"failed"` when `failed` is set, `"filtered"` when `Apply` filtered it by
flavour, `"skipped"` when `SkipShim` named it, else `"pending"`.

## Providers

A provider registry answers "who implements *kind* right now?" for consumers
that route output, storage or any other pluggable role, in a way every
consumer in the session shares.

### `CompatKit:Providers(kind)`

Returns the registry of `kind` (a non-empty string), creating it on the first
call and returning the same object after; raises
`CompatKit:Providers refuses more than <n> kinds` at the `maxProviderKinds`
limit. A registry's methods check their receiver:
`registry.Resolve()` raises `CompatKit.ProviderRegistry:Resolve must be called
on a provider registry; use registry:Resolve(...)`.

### `registry:Register(name, implementation, probe?, priority?)`

- `name` is a non-empty string, unique within the kind.
- `implementation` is anything but `nil`: a function, a table, a string. It is
  what `Resolve` hands back, unchanged.
- `probe` is `function() -> boolean`, asked whether the provider is usable at
  the moment of a `Resolve` or `List`. Default: always alive. Only `true`
  counts as alive (a secret answer is dead and is never compared); a probe
  that raises is reported through the host error handler and counts as dead.
- `priority` is an integer, negative allowed, default `0`; higher wins.

| Result | When |
|---|---|
| `true` | Registered. |
| `false, "exists"` | The name is taken. A provider is replaced by unregistering it first. |
| `false, "full"` | The kind already holds `maxProviders` providers. |

### `registry:Unregister(name)`

Removes the provider and returns whether it existed. The memoised answer is
forgotten when it named this provider.

### `registry:Resolve(preferred?)`

Returns `implementation, name`, or `nil, "none"` when no provider is alive:

1. When `preferred` names a live provider, it is returned. The memo is not
   touched: a preferred lookup is the caller's choice, not the cascade's.
2. Otherwise the memoised answer is returned when its provider still exists
   and its probe says alive.
3. Otherwise the cascade walks the providers by priority (higher first) and
   then by name (byte-wise `<`), returns the first live one and memoises it.
   A provider whose probe already said dead in this call (as `preferred` or
   as the memo) is not asked again, so a raising probe is reported once per
   `Resolve`.

The memo is **stable while alive**, not always the best: after the cascade
chose a lower-priority provider because the higher one was dead, `Resolve()`
keeps answering it until it dies, even after the higher one comes back. A
consumer that wants the best provider at every call names it as `preferred`.
Registration order never changes the answer: two sessions with the same
providers, priorities and probe answers resolve the same provider.

`Resolve` allocates nothing: the cascade walks an array maintained at
`Register` and `Unregister`.

### `registry:List()`

Returns a new array of new `{ name, priority, alive }` rows in cascade order,
asking every probe once. For consoles and options pages.

## Catalogue

`CompatKit.CATALOGUE` mirrors the table
[Catalogue of taint-hostile subsystems](../../../docs/EMBEDDING.md#catalogue-of-taint-hostile-subsystems)
in `docs/EMBEDDING.md`, row for row and in the same order, so tooling and
addons can read it. It is a read-only view over `CATALOGUE_COUNT` rows; on
Lua 5.1 `#`, `ipairs` and `pairs` do not see through a view, so index it from
`1` to `CATALOGUE_COUNT`. Each row is a read-only view with:

| Field | Meaning |
|---|---|
| `subsystem` | The Blizzard subsystem or call, as the document's first column spells it. |
| `reason` | Why touching it from insecure code taints. |
| `replacement` | The sanctioned replacement. |
| `replacementApi` | The documented client API the replacement names (`"C_TooltipInfo.GetUnit"`), or `false` when the replacement is FrameXML or the addon's own frames, which the documented API tables do not describe. |
| `flavours`, `flavourCount` | A read-only view of the apiKit flavour ids (`"beta"`, `"classic-era"`, `"classic-mop"`, `"ptr"`, `"retail"`, sorted) whose committed metadata documents `replacementApi`, and how many there are; empty when `replacementApi` is `false`. |

`tooling/tests/test_compat_catalogue.py` loads the package under Lua 5.1 and
checks that every `replacementApi` is documented by at least one flavour, that
each row's `flavours` is exactly the set of flavours documenting it, and that
the rows mirror the document. A write into the catalogue raises
`CompatKit.CATALOGUE[<n>] is read-only; field "<name>" cannot be written` at
the writer's line.

## Secret values

On a client with secret values, a shim name, version, description, flavour or
cover, an option key, a provider kind, name, implementation, priority or
preferred name, a context helper's name, and a limit value or key that
`issecretvalue` reports secret is refused at the caller before it is compared,
used as a key or formatted:

```text
MyAddon/Core.lua:12: CompatKit:Shim name must not be a secret value
```

A shim's error value and a probe's error value are handed to the host error
handler and stored unchanged; CompatKit never formats or compares them, so a
secret string built inside a shim stays a secret string. A probe that answers
with a secret counts as dead, and `hasGlobal` reports a global holding a secret
as present; neither compares it. A secret receiver is reported as a call
without the facade, before it is compared.

Absence of a value CompatKit did not create (an argument, an options or limits
field, a host global) is tested with `type`, never with `== nil`, because
comparing a secret with `nil` raises too.

## Limits

| Limit | Default | How to open | UNBOUNDED allowed? |
|---|---|---|---|
| `maxShims` | 64 | `CompatKit:SetLimits({ maxShims = n })` | Yes |
| `maxProviders` | 32 per kind | `CompatKit:SetLimits({ maxProviders = n })` | Yes |
| `maxProviderKinds` | 32 | `CompatKit:SetLimits({ maxProviderKinds = n })` | Yes |

`maxShims` bounds the shims plus the skips waiting for a shim of their name (a
skip for a name that never arrives is retained for the session).
`maxProviders` bounds the providers of one kind, and `maxProviderKinds` the
kinds `Providers` creates.

```lua
CompatKit:SetLimits({ maxShims = 200 })
CompatKit:SetLimits({ maxProviders = CompatKit.UNBOUNDED })
local limits = CompatKit:GetLimits() -- a fresh table; allocates
```

`SetLimits` accepts any subset of the limits and returns nothing. It raises at
the caller's line, **before changing anything**, when `limits` is not a table,
names an unknown limit (`CompatKit:SetLimits limits.<name> is not a recognised
limit`), or gives a secret or invalid value (`CompatKit:SetLimits
limits.<name> must be a positive integer or CompatKit.UNBOUNDED`). `GetLimits`
returns a new table on every call, with `CompatKit.UNBOUNDED` itself for a
lifted limit.

No limit has a ceiling: shims, providers and kinds are the registering
addons' own tables and nothing here is mirrored into a client resource that
cannot be freed. A limit reached is refused with `"full"` (shims, providers)
or raises (kinds); lowering a limit removes nothing.

**The limits are shared by every consumer in the session**, like the shims and
the registries themselves. A library should rely on the defaults; an addon
that raises a limit raises it for everybody.

## Errors

Argument failures report the line that called the public method, never a line
inside CompatKit, and name the method and the argument:

| Message | Cause |
|---|---|
| `CompatKit:<Method> must be called on the CompatKit facade; use CompatKit:<Method>(...)` | Called with `.` instead of `:`, or on another table or a secret value. |
| `CompatKit:Shim name must be a non-empty string` | Also for `SkipShim name`, `Providers kind`. |
| `CompatKit:Shim version must be a positive integer` | Not an integer from 1 to 2^53. |
| `CompatKit:Shim implementation must be a function` | |
| `CompatKit:Shim options must be a table or nil` | |
| `CompatKit:Shim options contains unknown field "<name>"` | The alphabetically first unknown field is named. |
| `CompatKit:Shim options.description must be a string` | |
| `CompatKit:Shim options.flavours must be a non-empty array of flavour ids` | Also `options.covers must be a non-empty array of API names`. |
| `CompatKit:Shim options.flavours contains an invalid flavour id` | An entry is not a non-empty string. `options.covers contains an invalid API name`: an entry is not `Name` or `Namespace.Name` made of word characters. |
| `CompatKit:Apply cannot be called from inside a shim` | Raised inside the shim, which is then recorded as failed. |
| `CompatKit:Providers refuses more than <n> kinds` | The `maxProviderKinds` limit. |
| `CompatKit.ProviderRegistry:<Method> must be called on a provider registry; use registry:<Method>(...)` | Called with `.` instead of `:`, or on another table. |
| `CompatKit.ProviderRegistry:Register name must be a non-empty string` | Also `Unregister name`, `Resolve preferred`. |
| `CompatKit.ProviderRegistry:Register implementation must not be nil` | |
| `CompatKit.ProviderRegistry:Register probe must be a function or nil` | |
| `CompatKit.ProviderRegistry:Register probe must not be a secret value` | See [Secret values](#secret-values); also `implementation`, `priority` and `Resolve preferred`. |
| `CompatKit.ProviderRegistry:Register priority must be an integer` | |
| `CompatKit.ShimContext.hasApi name must be a non-empty string` | Also `hasGlobal name`; reported at the shim's line. |
| `CompatKit:<Method> <argument> must not be a secret value` | See [Secret values](#secret-values); also `options must not be a secret value`, `options must not have a secret key`, `options.<field> must not be a secret value`, `options.flavours must not contain a secret value`, `limits must not have a secret key`. Every secret check runs before the value is compared, and absence is tested with `type`. |
| `CompatKit:SetLimits limits must be a table` | |
| `CompatKit:SetLimits limits.<name> is not a recognised limit` | |
| `CompatKit:SetLimits limits.<name> must be a positive integer or CompatKit.UNBOUNDED` | |
| `CompatKit.CATALOGUE is read-only; field "<name>" cannot be written` | Also `CompatKit.CATALOGUE[<n>]`, `CompatKit.CATALOGUE[<n>].flavours` and `CompatKit shim context`. |

Bootstrap failures raise at the line that loaded the file:

| Message | Cause |
|---|---|
| `MoltenCodes CompatKit requires Registry API 2 to be loaded first` | `Registry.lua` is missing or loaded after this file. |
| `MoltenCodes CompatKit requires a valid Registry API 2 facade` | The published Registry lacks `Bootstrap` or `Find`. |
| `MoltenCodes CompatKit package state is corrupted or incomplete` | The shared package state was modified from outside. |

Ordinary outcomes (`"ignored"`, `"full"`, `"exists"`, `"none"`) are results,
not errors: two addons registering the same shim or provider is not a
programming error in either.

## Cost

| Operation | Cost |
|---|---|
| `Shim` | Argument checks; one entry table and up to two copied arrays on a new name. Load time. |
| `SkipShim` | Argument checks and at most three table writes. |
| `Apply` | One sorted array of the pending entries, one context, and, on the first `hasApi` call, one walk over the installed ApiKit surface. Each shim: one `pcall`. Load time. |
| `GetShims` | One array and one table per shim, plus copied arrays. Diagnostic. |
| `Providers` | One table read after the first call. No allocation. |
| `Register` | Argument checks, one entry table, one insertion into the ordered array. |
| `Resolve` | Argument checks, at most one probe call on the memo hit; the cascade walks the ordered array. No allocation. |
| `List` | One array and one row per provider; every probe once. Diagnostic. |
| `GetLimits` | One table. |

## Embedded copies and upgrades

Several addons may embed CompatKit; Registry selects the newest compatible
revision and every copy shares one facade. An upgrade happens in place: shims
(pending and attempted), skips, provider registries and their memo, the limits
a consumer set and the `UNBOUNDED` sentinel all survive, and a registry an
older copy handed out runs the newer methods. The catalogue is the newest
revision's. An older copy loading after a newer one yields to it.

Nothing survives `/reload`: shims register and apply again.

`_state` is private; its layout is described in [`INTERNALS.md`](INTERNALS.md)
for maintainers and is not part of the contract.

## Deviations from the planned contract

The nine-point plan in `docs/ROADMAP.md` is followed except where recorded here:

- **`Shim` takes an `options` table** (`description`, `flavours`, `covers`)
  beside the three planned arguments, and **returns a result**
  (`true`/`false` and a reason) so a caller can see whether its version won.
- **`Apply` returns counts** (`applied, skipped, failed`) rather than nothing,
  and a flavour-filtered shim is counted as skipped.
- **A higher version registered after `Apply` is recorded, not run.** The
  plan says the newest version wins; that holds until `Apply`, after which
  "applied once" wins. `GetShims` shows both versions.
- **`Register` returns `false, "exists"`** for a taken name instead of
  replacing the provider: replacing would let a later-loading addon silently
  take over a name; `Unregister` first makes the intent visible.
- **No change signals** on a registry: a registry has no SignalKit dependency
  by design (the package needs Registry alone), and output routing polls
  `Resolve` at the moment of use. A consumer that must react to a change
  wraps its own `Register` calls.
- **Additions:** `registry:Unregister`, `GetLimits`, `UNBOUNDED`,
  `maxProviderKinds`, the `context` argument, `CATALOGUE` and
  `CATALOGUE_COUNT`, the `status` and `missing` record fields.
