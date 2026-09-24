# LogKit Internals

This document describes implementation invariants for maintainers. It is not an additional public API.

## Package state

`LogKit._state` holds everything that must survive an in-place upgrade:

| Field | Meaning |
|---|---|
| `schema` | The state layout version, `1`. |
| `unbounded` | The `UNBOUNDED` sentinel, created once so every revision publishes the same table. |
| `limits` | The shared limits `SetLimits` writes: `journalCapacity`, `maxSinks`, `maxMessageLength`, `maxLoggers`. |
| `globalLevel` | The global level number, or `false`. |
| `addonLevels` | Addon name to override level number. Kept apart from the loggers so a level restored or set before a logger exists applies when it is created. |
| `loggers`, `loggerCount` | Addon name to logger, and how many (compared with `limits.maxLoggers`). |
| `loggerPrototype`, `loggerMetatable` | Shared by every logger; every loading revision rewrites the prototype's methods. |
| `chatSinkPrototype`, `chatSinkMetatable` | Shared by every chat sink, so a sink built by an older copy writes through the newest `Write`. |
| `levels` | The read-only `LEVELS` proxy. |
| `sinks`, `sinkHandles` | Handles `{ write, receiver, active }` in registration order, and the set of live handles `RemoveSink` checks. `write` is a function sink; `receiver` a table sink whose `Write` is looked up per call. |
| `delivering`, `pendingRemovals` | Whether sinks are being called, and how many were removed meanwhile. |
| `journal` | The SignalKit journal; replaced by `SetLimits` when the capacity changes. |
| `record` | The one table every sink receives. |
| `formatArguments` | Staging for format arguments, cleared after each call. |
| `historyCursor` | The filter of the most recent `History` walk: `journal`, `iterator`, `addon`, `minimumLevel`. |
| `dispatch` | `commandSetLevel` and `commandShow`, called through by the closures handed to CommandKit. |
| `command` | The CommandKit scope and whether `/log` is registered. |
| `binding` | `{ db, view }` while `BindLevels` is active, else `false`. |

## Loggers

A logger is `{ _name, _effective }` under `loggerMetatable`. `_effective` is
the resolved level number, recomputed for every logger by
`refreshEffectiveLevels()` after any `SetLevel`, `SetGlobalLevel`, restore or
upgrade, so the level methods read one field and compare. A receiver is
recognised by `getmetatable(self) == loggerMetatable`, a call that never
raises whatever `self` is.

## The hot path

Each of `Trace` … `Error` is a closure over its level built by
`newLevelMethod`:

```text
receiver check -> level < self._effective ? return : emit(...)
```

`emit` runs only for an enabled message and, in order: refuses a secret or
non-string message, counts the arguments, stages them into `formatArguments`
with secrets replaced, formats inside `pcall(string.format, message,
unpack(staging, 1, count))`, clears the staging, truncates, and delivers. The
staging table is cleared after every call so a logged table is not kept alive
by LogKit. Everything on this path reuses tables that exist from the first
load; the only allocation is the string `string.format` returns (and none when
it is already interned).

## Delivery

`deliver` fires the journal with `(addon, level, message, time)` through
`recordInJournal`, which runs `journal:Fire` under `pcall` so a SignalKit
refusal (its `maxJournalArguments` lowered below 4) is reported rather than
raised into the logging caller. Then, unless a delivery is already in progress
or no sink exists, it fills `record`, sets `delivering`, runs `callSinks` under
`pcall`, clears the flag unconditionally, compacts pending removals and only
then reports whatever escaped. `callSinks` calls each sink under its own
`pcall`; a table sink is reached through `writeThrough`, which indexes `Write`
at call time. `reportError` runs the host error handler under `pcall` too and
prints when it raises, so a broken handler can neither stick `delivering` nor
reach the caller. The `delivering` flag is what makes a message logged from
inside a sink skip the sinks: the record is in use, and recursion would
otherwise be unbounded.

Removal during delivery marks the handle `active = false`, counts it in
`pendingRemovals` and lets `deliver` compact the array afterwards; outside a
delivery `RemoveSink` compacts at once. The loop reads `#sinks` once, so a sink
added during delivery is first called for the next message.

## Journal

The journal is a `SignalKit:NewJournal(capacity)` with no listeners: SignalKit
owns the ring, the slots and the argument staging, and `History` walks it
through the stateless iterator `journal:History()` returns. LogKit's iterator
(`nextHistoryEntry`) advances that iterator until an entry passes the cursor's
filter and yields the entry's four values, so nothing a consumer receives is a
ring slot. The cursor is one shared table, which is why walks do not nest.

A capacity change builds a new journal and refires the newest entries that fit
from the old one, oldest first, so the new ring holds the same tail in the same
order.

## Level changes

`setAddonLevel(addonName, number)` is the one writer of `addonLevels`, used by
`logger:SetLevel` and by the `/log` handler, so the command never creates a
logger. It and `SetGlobalLevel` return early when the level is already in
force: no refresh of the loggers, no saved-variable write, no `OnChange`.

## Chat sink

A chat sink is `{ _chatFrame }` under `chatSinkMetatable`. `Write` builds one
line with a single concatenation expression (one allocation) and resolves the
frame per line: the sink's own frame, else `DEFAULT_CHAT_FRAME`, else `print`.

## Slash command

`RegisterCommand` creates one `CommandKit:CreateScope()` and registers `log`
with a top-level handler and a `show` sub-command. CommandKit keeps handler
functions by reference, so both handlers are closures that call
`dispatch.commandSetLevel` and `dispatch.commandShow`; a newer revision writes
new functions into `dispatch` and the registered closures run them.

## SettingsKit binding

`BindLevels` recognises a database by comparing `db.Validate` and `db.Pairs`
with the functions of the published `SettingsKit.Database` prototype (the
database metatable is private to SettingsKit). It checks the schema with
`db:Validate("global", { "logLevels", "*" }, "warn")`, reads the section view
`db.global.logLevels`, restores every string key whose value is a level name
through `db:Pairs`, and keeps `{ db, view }` in `binding`. `persistLevel`
writes `view[key] = levelName or nil` under `pcall`; a refusal is reported
through the host error handler because the level setter's caller did not
choose the schema.

## Upgrades

Every loading revision rewrites the logger and chat-sink prototypes and the
`dispatch` functions, re-binds `LEVELS` and `UNBOUNDED` from the state, and
recomputes every logger's cached level. `validateStateBase` refuses a state
whose limits, global level or any table field is missing or invalid; a newer
revision that changes the layout adds a migration step and raises
`STATE_SCHEMA`.
