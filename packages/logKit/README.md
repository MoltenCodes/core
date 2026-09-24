# LogKit

LogKit is levelled, structured logging for World of Warcraft addons and for the
Kits themselves. Every addon owns one **logger** with `Trace`, `Debug`, `Info`,
`Warn` and `Error` methods; a message below the logger's level costs one
comparison and its arguments are never formatted. Delivered messages go to a
bounded in-memory **journal** you can read afterwards and to any **sinks** you
add: a chat frame, a callback, or a table with a `Write` method.

```lua
local LogKit = MoltenCodes.Registries[2]:Get("logKit", 1)
local log = LogKit:ForAddon("MyAddon") -- once, at file scope

log:Debug("rebuilding %d frames", frameCount) -- formatted only when debug is on
log:Warn("profile %q not found, using default", profileName)
log:Error("100% of the bars are missing")   -- a bare message is never formatted

-- Nothing is printed until a sink is added. The chat sink prints
-- "[MyAddon] warn: profile "x" not found, using default", level coloured.
LogKit:AddSink(LogKit:ChatSink())

-- Levels: an addon override beats the global level, which beats the default (warn).
log:SetLevel("debug")
LogKit:SetGlobalLevel("info")
local level, source = log:GetLevel() -- "debug", "addon"

-- The journal is always on and holds the last 1024 delivered messages.
for position, addon, levelName, message, time in LogKit:History("MyAddon", "warn") do
  print(position, addon, levelName, message, time)
end
```

Three contracts are worth knowing before the first message:

- **Disabled is nearly free.** `log:Debug(message, ...)` while `debug` is off
  checks its receiver, compares one number and returns. The message and the
  arguments are not read, so building them lazily is the caller's only cost, and
  a bare message never passes through `string.format`, so `%` in it is safe.
- **Secret-safe.** A format argument for which `issecretvalue` is true is
  replaced by `"<secret>"` before `string.format` sees it; a secret is never
  formatted, converted with `tostring` or concatenated. A bad format string is
  reported through the host error handler and never raises into the caller.
- **Bounded.** The journal is a ring of `journalCapacity` entries (1024), at
  most `maxSinks` (16) sinks and `maxLoggers` (256) loggers exist, and a
  message longer than `maxMessageLength` (1024 bytes) is cut and marked. Every
  bound is opened on purpose with `LogKit:SetLimits{}`; see
  [`docs/API.md`](docs/API.md#limits).

Not in scope: log files (the client has none), remote shipping, and a viewer
window (a later user-interface phase).

See [`docs/API.md`](docs/API.md) for the complete contract and
[`docs/INTERNALS.md`](docs/INTERNALS.md) for how it is built.

## How the package is organised

| Path | Contents |
|---|---|
| `src/LogKit.lua` | The whole runtime: one file, loaded after Registry and SignalKit. |
| `docs/API.md` | Every method, its arguments, results, errors and cost. |
| `docs/INTERNALS.md` | Package state, the hot path, the journal and sink layouts, upgrades. |
| `tests/` | The Busted suite; [`tests/README.md`](tests/README.md) lists what each spec covers. |
| `CHANGELOG.md` | User-visible changes per version. |

## Optional integrations

- **`/log` slash command.** `LogKit:RegisterCommand()` registers `/log <addon|*>
  <level|default>` and `/log show [addon]` through CommandKit when an addon
  embeds it; without CommandKit it returns `false, "absent"`.
- **Persisted levels.** `LogKit:BindLevels(db)` stores addon overrides and the
  global level in a SettingsKit database whose `global` scope declares
  `logLevels`, and restores them on bind. Without SettingsKit it refuses at the
  caller's line.

Both are found through `Registry:Find` when the method is called; neither is a
load-order dependency.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\signalKit\SignalKit.lua
Libs\MoltenCodes\logKit\LogKit.lua
```

Minimum footprint: embed 3 files: `registry/Registry.lua`,
`signalKit/SignalKit.lua`, `logKit/LogKit.lua`.

Direct runtime dependencies: Registry API 2, SignalKit API 1. Every file above
is required; omitting one makes this package raise at load. CommandKit API 1 and
SettingsKit API 1 are optional and found at call time. `GetTimePreciseSec` is
optional: without it a record's `time` is `false`.
