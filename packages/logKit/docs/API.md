# LogKit API

LogKit API generation **1** provides levelled, structured logging: one logger
per addon with lazily formatted, secret-safe messages, a tri-state level, a
bounded journal readable after the fact, and sinks.

Implementation revision: **1**.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
SignalKit.lua
LogKit.lua
```

Portable WoW code resolves the package through Registry:

```lua
local LogKit = MoltenCodes.Registries[2]:Get("logKit", 1)
```

LogKit does not rely on `require()` at runtime. Loading it without a dependency
raises `MoltenCodes LogKit requires Registry API 2 to be loaded first` (or
`SignalKit API 1`).

### Optional dependencies and host facilities

| Facility | Used by | Without it |
|---|---|---|
| `GetTimePreciseSec` | the `time` of every record and journal entry | `time` is `false`. Bound once at load. |
| `issecretvalue` | every consumer-supplied value, read at call time | Nothing is secret, which is correct on clients without secret values. |
| `geterrorhandler` | a failing sink, a bad format string, a refused journal firing, a refused persisted write | Falls back to `print`, also when the handler itself raises. |
| `DEFAULT_CHAT_FRAME` | `ChatSink()` without a frame, read per line | Output goes to `print`. |
| `SlashCmdList` | `RegisterCommand` | `false, "unavailable"`. |
| CommandKit API 1, through `Registry:Find` | `RegisterCommand` | `false, "absent"`. |
| SettingsKit API 1, through `Registry:Find` | `BindLevels` | Raises at the caller. |
| SignalKit's `maxJournalArguments` | every delivered message (one journal firing of four values) | Must stay at least 4 (SignalKit's default is 8); below it every firing is refused, reported through the error handler, and the message still reaches the sinks. |

## Public surface

Package facade:

| Member | Purpose |
|---|---|
| `ForAddon(addonName)` | The logger for `addonName`, created on first use; `nil, "capped"` beyond `maxLoggers`. |
| `SetGlobalLevel(level\|nil)` | Set or clear the global level. |
| `GetGlobalLevel()` | The global level's name, or `nil`. |
| `AddSink(sink)` | Add a function or table sink; returns a handle, or `nil, "full"`. |
| `RemoveSink(handle)` | Remove a sink; `true` when it was registered, `false` for any other value. |
| `ChatSink(chatFrame?)` | A sink printing `[addon] level: message` to a chat frame. |
| `History(addonName?, minimumLevel?)` | Walk the journal oldest to newest, filtered. |
| `RegisterCommand()` | Register `/log` through CommandKit; `true`, or `false, reason`. |
| `BindLevels(db\|nil)` | Persist levels in a SettingsKit database, or stop. |
| `SetLimits(limits)` | Change any subset of the shared limits. Returns nothing. |
| `GetLimits()` | A fresh table of the shared limits; allocates. |
| `LEVELS` | Level name to numeric value, read-only (below). |
| `DEFAULT_LEVEL` | `"warn"`. |
| `DEFAULT_JOURNAL_CAPACITY`, `DEFAULT_MAX_SINKS`, `DEFAULT_MAX_MESSAGE_LENGTH`, `DEFAULT_MAX_LOGGERS` | `1024`, `16`, `1024`, `256`. |
| `MAX_FORMAT_ARGUMENTS` | `16`, the most format arguments one call accepts. |
| `SECRET_PLACEHOLDER` | `"<secret>"`. |
| `UNBOUNDED` | Sentinel that lifts a limit; the same table for every revision. |
| `API`, `REVISION` | API generation `1` and implementation revision. |

Loggers:

| Method | Purpose |
|---|---|
| `Trace(message, ...)`, `Debug(...)`, `Info(...)`, `Warn(...)`, `Error(...)` | Log at that level. |
| `Log(level, message, ...)` | Log at a level given as a name or a `LEVELS` value. |
| `IsEnabled(level)` | Whether a message at `level` would be delivered now. |
| `SetLevel(level\|nil)` | Set or clear this addon's override. |
| `GetLevel()` | The effective level's name and its source: `"addon"`, `"global"` or `"default"`. |
| `GetAddonName()` | The addon name the logger was created for. |

## Levels

```lua
assert(LogKit.LEVELS.trace == 1)
assert(LogKit.LEVELS.debug == 2)
assert(LogKit.LEVELS.info == 3)
assert(LogKit.LEVELS.warn == 4)
assert(LogKit.LEVELS.error == 5)
assert(LogKit.LEVELS.off == 6)
```

A message is delivered when its level is **at least** the logger's effective
level. `off` is a setting only: `SetLevel("off")` silences a logger, and
`Log("off", ...)` or `IsEnabled("off")` raises. `LEVELS` is read-only (a write
raises `LogKit.LEVELS is read-only`) and the same table for every embedded
revision; `getmetatable(LogKit.LEVELS)` is `"LogKit.Levels"`.

Wherever a method takes a `level`, it accepts the name (`"debug"`) or the value
(`LogKit.LEVELS.debug`). Anything else raises at the caller:
`LogKit.Logger:SetLevel level must be a level name (trace, debug, info, warn,
error, off) or a LogKit.LEVELS value`.

### Precedence

A logger's **effective level** is, in order: its own override (`SetLevel`),
the global level (`SetGlobalLevel`), the default `warn`. `GetLevel()` returns
the effective level's name and which of the three it came from. Setting a level
that is already in force changes nothing; `nil` clears an override or the
global level. A level set before its logger exists applies when the logger is
created, so `/log MyAddon debug` may run before MyAddon loads.

Every level change recomputes the cached effective level of every logger, so
the hot path never resolves precedence.

## Loggers

```lua
local log = LogKit:ForAddon("MyAddon")
```

`ForAddon(addonName)` accepts a non-empty, non-secret string and returns the
same logger for the same name for the whole session, so create loggers once at
file scope. Creating a logger allocates one table. Beyond `maxLoggers` (256 by
default) a new name gets `nil, "capped"`; existing names are still returned.

### Logging

```lua
log:Debug("rebuilding %d frames in %.1f ms", count, elapsed)
log:Warn("100% of the bars are missing") -- bare: never formatted
log:Log(LogKit.LEVELS.info, "level chosen at run time")
```

When the level is **disabled**, the call checks its receiver, compares one
number and returns. `message` and the arguments are not read: no type check, no
`tostring`, no `string.format`. Build them as cheaply as you like.

When the level is **enabled**:

1. `message` must be a non-secret string, or the call raises at your line
   (`LogKit.Logger:Warn message must be a string`, `... must not be a secret
   value`). The check runs only when enabled, so a wrong message type surfaces
   once the level is on.
2. With no extra arguments the message is delivered as it is, so `%` in it is
   safe. With arguments, at most `MAX_FORMAT_ARGUMENTS` (16, counting explicit
   `nil`s, or the call raises `LogKit.Logger:Warn accepts at most 16 format
   arguments; received 17`), each argument that `issecretvalue` reports as
   secret is replaced by `SECRET_PLACEHOLDER`, every other argument that is
   not a string or a number is converted with `tostring` (Lua 5.1's `%s`
   accepts only those two; LogKit gives it Lua 5.2's behaviour, so `nil`,
   booleans and tables format, and a table's `__tostring` runs here, on the
   enabled call only), and the message is formatted once with
   `string.format`.
3. A format failure (a bad specifier, a `%d` given a string) is **reported
   through `geterrorhandler()`** as `LogKit.Logger:Warn could not format a
   message for addon MyAddon: <string.format's message>`, and the message is
   dropped: nothing reaches the journal or the sinks, and nothing raises into
   the caller. A log call must not break the code that is reporting something.
4. The text is cut to `maxMessageLength` bytes (1024 by default) and marked
   with `...`, never inside a UTF-8 sequence.
5. The message is recorded in the journal and handed to every sink.

`Log(level, message, ...)` behaves the same after reading `level`; it costs a
few comparisons more than the fixed methods while disabled, so prefer those
when the level is known where the code is written.

## Sinks

```lua
local handle = LogKit:AddSink(function(record)
    MyPanel:Append(record.levelName, record.message)
end)

local capture = { lines = {} }
function capture:Write(record)
    self.lines[#self.lines + 1] = record.message
end
LogKit:AddSink(capture)

LogKit:RemoveSink(handle)
```

`AddSink(sink)` accepts a function `(record)` or a table with a `Write` method,
called as `sink:Write(record)` and looked up at every call, so replacing the
method later (or an upgrade rewriting a shared prototype) takes effect at the
next message. It returns a **handle** for `RemoveSink`, or `nil, "full"` when
`maxSinks` (16 by default) sinks are registered. Anything else raises
`LogKit:AddSink sink must be a function or a table with a Write method`.
`RemoveSink(handle)` returns `true` when the handle was registered and `false`
for any other value, a secret included; it never raises for its argument.

Nothing is printed until a sink is added; the journal alone receives messages
by default.

### The record

Every sink receives **one shared table**, rewritten for each message:

| Field | Meaning |
|---|---|
| `addon` | The addon name the logger was created for. |
| `level` | The message level, a `LEVELS` value. |
| `levelName` | Its name. |
| `message` | The formatted, truncated text. |
| `time` | `GetTimePreciseSec()` when delivered, or `false` on a host without the clock. |

The record is valid **only during the call**. Read what you need and copy what
you keep; never store the table. This is what lets an enabled message allocate
nothing but its formatted string.

### Delivery rules

- Sinks are called in registration order, each inside `pcall`. A sink that
  raises is reported through `geterrorhandler()` (the error value passed on
  unchanged) and the remaining sinks still run. The whole sink pass is itself
  guarded: an error handler that raises cannot reach the logging caller or
  leave delivery stuck, and the report falls back to `print`.
- A sink that removes itself, or another sink, during a message takes effect at
  once for the removed sink; the array is compacted after the message. A sink
  added during a message receives messages from the next one.
- A message logged **from inside a sink** is recorded in the journal but not
  delivered to sinks: the record is in use, and a sink logging at its own level
  would otherwise recurse without end.

### `ChatSink(chatFrame?)`

Builds a table sink that writes `[addon] level: message` with the level word
wrapped in a colour escape, one colour per level:

```text
trace  |cff9d9d9d  grey
debug  |cff6699ff  blue
info   |cffffffff  white
warn   |cffffa500  orange
error  |cffff4040  red

[MyAddon] |cffffa500warn|r: profile "x" not found, using default
```

`chatFrame` is anything with an `AddMessage` method (a chat frame; anything else
raises `LogKit:ChatSink chatFrame must be a table with an AddMessage method`).
Without it, `DEFAULT_CHAT_FRAME` is read **when each line is written**, and
`print` is the fallback outside the client. The sink allocates one string per
line. Pass the result to `AddSink`.

## `History(addonName?, minimumLevel?)`

```lua
for position, addon, levelName, message, time in LogKit:History() do
    -- oldest first
end
for position, addon, levelName, message in LogKit:History("MyAddon", "warn") do
    -- only MyAddon's entries at warn and error
end
```

The journal is **always on** and keeps the newest `journalCapacity` (1024 by
default) delivered messages in a ring built on `SignalKit:NewJournal`. `History`
returns what a generic `for` needs to walk it oldest to newest:

- `position` is the entry's position in the journal, 1 for the oldest recorded
  entry. With a filter, positions that were skipped are not yielded, so the
  sequence has gaps.
- `addonName`, when given, keeps only that addon's entries (a non-empty,
  non-secret string). `minimumLevel`, when given, keeps entries at that level or
  above; `"off"` yields nothing.
- `time` is the record's `time`: seconds, or `false`.

`History()` allocates nothing: it returns one shared iterator function, one
shared cursor holding the filter, and a start position. Because the cursor is
shared, **walks do not nest**: a `History` call made inside a walk replaces the
filter of the outer walk, which continues from its own position under the new
filter. A message logged during a walk moves the ring under it, which may skip
or repeat an entry; the walk never errors and always ends. The entries are
copied out of SignalKit's slots as plain values, so nothing you receive is
reused.

## `RegisterCommand()`

```lua
if LogKit:RegisterCommand() then
    -- /log MyAddon debug      set MyAddon's override
    -- /log MyAddon default    clear it
    -- /log * info             set the global level
    -- /log * default          clear it
    -- /log show               global level and every logger's level
    -- /log show MyAddon       one addon's level
end
```

Finds CommandKit API 1 through `Registry:Find` and registers `/log` in a scope
LogKit owns. Returns `true` when registered (also on every later call: the
command is registered once per session), or `false` with a reason:

| Reason | Meaning |
|---|---|
| `"absent"` | CommandKit API 1 is not loaded. |
| `"unavailable"` | The host has no `SlashCmdList`. |
| `"taken"`, `"emote"`, `"full"` | CommandKit's own refusal: `/log` is used by another command or chat type, by an emote, or the scope is full. |

The level word is a level name or `default`, which clears the override (or the
global level for `*`); it is read without case (`Debug` works), while the addon
name keeps its case because addon names are case-sensitive. Tokens after the
level are ignored. Setting an addon's level **never creates its logger**, so a
typed name cannot consume `maxLoggers`; the level applies when `ForAddon` is
called. An unknown level prints `/log: unknown level "x"; use one of trace,
debug, info, warn, error, off, or default to clear`. `show` is a sub-command,
so an addon literally named `show` cannot be set from the command.
`/log show` prints `global: <level or "not set">` then `<addon>: <level>
(<source>)` for every logger, sorted by name; it allocates, as a chat command
may.

## `BindLevels(db)`

```lua
local S = SchemaKit
local db = SettingsKit:Open("MyAddonDB", {
    global = S.table({
        fields = {
            logLevels = S.optional(
                S.map({ keys = S.string(), values = S.string(), max = 64 }),
                {}
            ),
        },
    }),
})
LogKit:BindLevels(db)
```

Persists the addon overrides and the global level in a SettingsKit API 1
database and restores them on bind. LogKit owns the keyed section
`global.logLevels`: each key is an addon name and the value its level name, and
`"*"` holds the global level. The consumer declares the section exactly as
above (an `optional` `map` with a default, so the section always has a view;
`values` may also be an `enum` of the level names). Requirements are checked at
the caller's line:

- SettingsKit API 1 must be loaded: `LogKit:BindLevels requires SettingsKit API
  1, which is not loaded (absent)`;
- `db` must be a SettingsKit database: `LogKit:BindLevels db must be a
  SettingsKit database`;
- `db:Validate("global", { "logLevels", "*" }, "warn")` must accept and the
  section must have a view: `LogKit:BindLevels db must declare global.logLevels
  as an optional map of addon name to level name; see LogKit docs/API.md`.

On bind, every entry whose key is a string and whose value is a level name is
applied (the `"*"` entry as the global level); other entries are ignored, since
the section is the addon's saved data. Levels set earlier in the session that
the database does not hold stay in force but are not written until set again.
Afterwards every `SetLevel` and `SetGlobalLevel` **that changes a level**
writes the level name (or `nil`) to the section; a call repeating the level in
force writes nothing and fires no `OnChange`. A write the database refuses (a `max` reached, a tighter
schema) is **reported through `geterrorhandler()`** and the level still applies
for the session. `BindLevels(nil)` stops persisting and returns `false`; a
second `BindLevels(db)` replaces the binding and restores again.

Call `BindLevels` in the addon's loaded phase, after `SettingsKit:Open`, like
every saved-variable access.

## Limits

| Limit | Default | How to open | UNBOUNDED allowed? |
|---|---|---|---|
| `journalCapacity` | 1024 | `LogKit:SetLimits({ journalCapacity = n })`, `n` from 1 to 65536 and at most SignalKit's `maxJournalCapacity` | No: the ring is allocated when the journal is created, so a capacity has to be a size; the ceiling keeps one call from allocating without bound |
| `maxSinks` | 16 | `LogKit:SetLimits({ maxSinks = n })` | Yes: sinks are the consumers' own registrations, removed by handle |
| `maxMessageLength` | 1024 bytes | `LogKit:SetLimits({ maxMessageLength = n })`, `n` at least 16 | Yes: the message is the consumer's own string |
| `maxLoggers` | 256 | `LogKit:SetLimits({ maxLoggers = n })` | Yes: one small table per addon name |

```lua
LogKit:SetLimits({ journalCapacity = 256, maxMessageLength = LogKit.UNBOUNDED })
local limits = LogKit:GetLimits() -- a fresh table; allocates
```

`SetLimits` accepts any subset and returns nothing. It raises at the caller's
line, **before changing anything**, when `limits` is not a table, names an
unknown limit, or gives a value outside the rules above (see [Errors](#errors)).
`GetLimits` returns a new table on every call, with `LogKit.UNBOUNDED` itself
for a lifted limit.

**The limits are shared by every consumer in the session**: every embedded copy
and every addon uses one set. A library should rely on the defaults; an addon
that raises a limit raises it for everybody.

`journalCapacity` follows the rule every Kit applies to a preallocated ring:
`UNBOUNDED` refused, default 1024, ceiling 65536. A new capacity **re-creates
the journal**, carrying over the newest entries that fit and dropping the rest;
`SetLimits` with the current capacity keeps the journal. The capacity is also
bounded by SignalKit's own `maxJournalCapacity` (1024 by default): asking for
more raises `... exceeds SignalKit maxJournalCapacity (1024); raise it with
SignalKit:SetLimits first`, because a shared session limit is the consumer's
decision, not LogKit's. When a session has lowered SignalKit's limit below 1024
before LogKit loads, the first journal is created at that limit and `GetLimits`
reports it.

Lowering `maxSinks` or `maxLoggers` below what exists removes nothing; new
registrations are refused with `nil, "full"` or `nil, "capped"` until the count
is under the limit again. `maxMessageLength` applies to the next message.

## Refusal reasons

| Reason | Returned by | Meaning |
|---|---|---|
| `"capped"` | `ForAddon` | A new logger would exceed `maxLoggers`. |
| `"full"` | `AddSink` | `maxSinks` sinks are registered. |
| `"absent"` | `RegisterCommand` | CommandKit API 1 is not loaded. |
| `"unavailable"` | `RegisterCommand` | The host has no `SlashCmdList`. |
| `"taken"`, `"emote"` | `RegisterCommand` | CommandKit refused `/log`. |

## Errors

Argument errors are raised at the caller's line and never format a value that
may be secret:

- `LogKit:ForAddon addonName must be a non-empty string` / `... must not be a secret value`
- `LogKit.Logger:<Method> must be called on a LogKit logger` (every logger method)
- `LogKit.Logger:<Method> message must be a string` / `... must not be a secret value` (enabled calls only)
- `LogKit.Logger:<Method> accepts at most 16 format arguments; received <n>`
- `LogKit.Logger:Log level must be a level name (trace, debug, info, warn, error, off) or a LogKit.LEVELS value` (and the same for `IsEnabled`, `SetLevel`, `LogKit:SetGlobalLevel`, `LogKit:History minimumLevel`)
- `LogKit.Logger:Log level cannot be off` (and `IsEnabled`)
- `LogKit:History addonName must be a non-empty string`
- `LogKit:AddSink sink must be a function or a table with a Write method` / `... must not be a secret value`
- `LogKit:ChatSink chatFrame must be a table with an AddMessage method` / `... must not be a secret value`
- `LogKit:BindLevels requires SettingsKit API 1, which is not loaded (<reason>)`
- `LogKit:BindLevels db must be a SettingsKit database`
- `LogKit:BindLevels db must declare global.logLevels as an optional map of addon name to level name; see LogKit docs/API.md`
- `LogKit:SetLimits limits must be a table`
- `LogKit:SetLimits limits.<name> is not a recognised limit`
- `LogKit:SetLimits limits.journalCapacity must be an integer from 1 to 65536`
- `LogKit:SetLimits limits.journalCapacity cannot be LogKit.UNBOUNDED: the ring is allocated when the journal is created`
- `LogKit:SetLimits limits.journalCapacity exceeds SignalKit maxJournalCapacity (<n>); raise it with SignalKit:SetLimits first`
- `LogKit:SetLimits limits.maxMessageLength must be an integer of at least 16 or LogKit.UNBOUNDED`
- `LogKit:SetLimits limits.maxSinks must be a positive integer or LogKit.UNBOUNDED` (and `maxLoggers`)
- `LogKit:<Method> must be called on the LogKit facade; use LogKit:<Method>(...)` (every facade method)
- `LogKit.LEVELS is read-only`

Failures that are not the caller's argument go to the host error handler
instead, and `print` when the handler is missing or itself raises: a failing
sink (its error value unchanged), a bad format string, a journal firing
SignalKit refuses because its `maxJournalArguments` was lowered below 4 (the
message still reaches the sinks), and a refused persisted write.

## Cost

| Path | Cost |
|---|---|
| Disabled `Trace` … `Error` | One `getmetatable`, one comparison. No allocation; the arguments are not read. |
| Disabled `Log` | The above plus reading the level (a table lookup or an integer check) and one `issecretvalue` call. |
| Enabled bare message | Two checks, one `issecretvalue` call, a length check, one journal firing, one `pcall` per sink. No allocation. |
| Enabled formatted message | The above plus staging the arguments (one `issecretvalue` call each, `tostring` for a value that is neither string nor number) and one `string.format` inside `pcall`. Allocates the formatted string, plus what a table's `tostring` produces. |
| `IsEnabled`, `GetLevel` | A level lookup and one comparison. No allocation. |
| `SetLevel`, `SetGlobalLevel` | Nothing when the level is unchanged; otherwise one pass over every logger, plus one saved-variable write when bound. |
| `ForAddon` (new name) | One table. |
| `AddSink` | One handle table. |
| `History()` | No allocation; one table read and a comparison per entry walked. |
| `ChatSink` write | One string per line. |
| `SetLimits` with a new `journalCapacity` | A new ring of `capacity` slot tables, plus two walks over the old ring. |
| `GetLimits` | One table. |

## Deviations from the planned contract

The nine-point plan in `docs/ROADMAP.md` is followed except where recorded here:

- **`History` takes a second filter**, `minimumLevel`, beside `addonName`, and
  yields plain values rather than journal entry tables, so nothing a consumer
  receives is reused.
- **The record is a reused table**, documented as valid during the sink call
  only; the plan says nothing about allocation per message, and this is what
  makes an enabled call allocate only its formatted string.
- **A message logged from inside a sink is journaled but not delivered to
  sinks**, to bound recursion.
- **`Log`, `IsEnabled`'s acceptance of `LEVELS` values, `GetAddonName`,
  `GetGlobalLevel`, `RegisterCommand`, `BindLevels`, the `maxLoggers` limit,
  `ChatSink`, `LEVELS`, `MAX_FORMAT_ARGUMENTS` and `SECRET_PLACEHOLDER`** are
  additions the plan implied or left open.
- **`journalCapacity` is also bounded by SignalKit's `maxJournalCapacity`**, a
  limit LogKit does not raise on the consumer's behalf.
- **A format failure drops the message** rather than delivering the raw format
  string; it is reported through the host error handler. Arguments that are
  not strings or numbers are converted with `tostring` first, so `%s` behaves
  as in Lua 5.2 rather than raising as in Lua 5.1.
- **The sink shape is `{ Write(record) }` or a function.** The plan says the
  sink contract is one ProfileKit reports can share; ProfileKit 0.1.0 has no
  sink (its `Report` returns rows), and CommandKit's sinks are chat-frame
  shaped (`{ AddMessage(text) }`). LogKit's record-based `Write` is the
  contract a future ProfileKit report sink would implement; a chat frame is
  adapted through `ChatSink`.
- **`BindLevels` requires a declared `global.logLevels` section** rather than
  writing an undeclared field, because a SettingsKit view validates every write
  against the consumer's schema and refuses undeclared fields of a closed record.

## Embedded copies and upgrades

LogKit bootstraps through `Registry:Bootstrap`. Loggers, their cached levels,
the addon overrides and global level, the sinks, the journal, the limits,
`LEVELS`, the `UNBOUNDED` sentinel, the slash-command scope and the SettingsKit
binding live in the shared package state, so an in-place upgrade keeps all of
them: a logger created by an older embedded copy resolves to the newer copy's
methods, a chat sink built by it writes through the newer copy, and the `/log`
handlers dispatch through package state so a newer revision replaces their
behaviour without registering again.

Nothing survives `/reload` except what `BindLevels` persisted.
