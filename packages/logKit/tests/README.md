# LogKit Tests

The LogKit suite covers:

- levels: `LEVELS` ordering and read-only refusal, the `warn` default, one
  memoised logger per addon name, gating below the effective level,
  `IsEnabled` and `Log` by name and by `LEVELS` value, override precedence
  (addon over global over default) with the source `GetLevel` reports, `off`
  as a setting but not a message level, and the `maxLoggers` cap;
- formatting: a metatable-driven probe proving the arguments are never touched
  while disabled, `string.format` once per enabled message, a table's
  `__tostring` run once and only when enabled, `nil`, booleans and tables
  formatted through `tostring`, a bare message with `%` delivered unchanged, a
  bad format string reported through the host error handler without raising
  or recording, the `MAX_FORMAT_ARGUMENTS` ceiling, the message checked only
  when enabled, and `time` from `GetTimePreciseSec` or `false` without it;
- the journal: always on, oldest to newest, the ring at `journalCapacity`, the
  addon and level filters alone and combined, re-creation on a new capacity
  keeping the newest entries, the journal kept when the capacity repeats, a
  `History` call inside a walk taking over the shared filter, a message logged
  during a walk over a full ring never erroring, and a message logged from
  inside a sink recorded but not delivered to sinks;
- sinks: function and table sinks, `Write` looked up at every call, the reused
  record, registration order, removal by handle (`false` for any other value, a
  secret included), a failing sink isolated and reported, an error handler that
  raises falling back to `print` with delivery still working afterwards, a sink
  removing itself or another sink during a message, a sink added during a
  message starting with the next one, a journal firing SignalKit refuses
  reported while the sinks are still fed, the `maxSinks` bound, and the chat
  sink's `[addon] level: message` lines with every level's colour, the given
  frame, `DEFAULT_CHAT_FRAME` read per line and the `print` fallback;
- secret values: the placeholder in place of a secret argument, no `tostring`
  or `string.format` of a secret, a secret message refused at the caller and not
  read while disabled, secret addon names, levels, sinks, chat frames and
  limit keys and values refused, and the probe looked up at call time;
- limits: defaults, fresh `GetLimits` tables, subsets, `maxMessageLength`
  truncation with the marker at exactly the limit and never inside a UTF-8
  sequence, `UNBOUNDED` where allowed and refused with the reason for
  `journalCapacity`, the SignalKit `maxJournalCapacity` interaction (refusal
  above it, first journal clamped to it), and invalid values, unknown names and
  non-facade receivers refused at the caller's line without changing anything;
- the `/log` command: `false, "absent"` without CommandKit, `false,
  "unavailable"` without `SlashCmdList`, idempotent registration, setting and
  clearing addon and global levels, the level word read without case with extra
  tokens ignored, unknown levels, usage, `/log show`, a level set without
  creating a logger, CommandKit's `"taken"` passed through, and dispatch through
  the newest revision after an upgrade;
- `BindLevels`: refusals without SettingsKit, for a non-database and for a
  schema without `global.logLevels`, storing and clearing levels, restoring on
  bind (unknown level names ignored, a logger created later sees its level),
  one saved-variable write per change, `BindLevels(nil)`, and a refused write
  reported through the host error handler while the session level stays;
- allocation guards on a disabled call, an enabled bare message with a sink, an
  enabled formatted message whose result is interned, `IsEnabled`/`GetLevel`,
  and filtered and unfiltered history walks;
- duplicate embedded loading, refusal to downgrade, an in-place upgrade from
  revision 1 (the real source loaded as revision 1, then revision 2 over it)
  that keeps a logger, its override, the global level, a sink, the journal and
  a raised limit and then refuses a secret limit, an in-place upgrade to the
  next revision (the real source with its revision constant rewritten) that
  keeps loggers, levels, sinks, the journal, `LEVELS` and `UNBOUNDED`, an older
  chat sink routed through the newest `Write`, the slash command working across
  it, and corrupted-state refusals (limits, global level, `delivering`,
  `pendingRemovals`, `binding`, missing tables);
- `error` levels: every argument failure reports the caller's own line;
- manifest/runtime API and revision consistency, and the declared required and
  optional dependencies.

`support/LogKitTestEnv.lua` loads Registry, SignalKit and LogKit under the
shared fixture's `mainline` profile (which publishes `issecretvalue`). It
installs `DEFAULT_CHAT_FRAME` on request (`InstallChatApi`, `ChatLines`), a
`SlashCmdList` with `LoadCommandKit` and `RunSlash`, loads SettingsKit with
`LoadSettingsKit`, and removes all of it in `Reset`. CommandKit and SettingsKit
are on `LUA_PATH` because the manifest declares them under
`optionalDependencies`; the specs that cover the "absent" path simply do not
load them.

| Spec | Covers |
|---|---|
| `Levels_spec.lua` | `LEVELS`, gating, `IsEnabled`, `Log`, precedence and sources, `maxLoggers` |
| `Formatting_spec.lua` | lazy formatting, bare `%`, format failures, argument ceiling, time stamps |
| `Journal_spec.lua` | ring order, filters, capacity changes, logging from a sink |
| `Sinks_spec.lua` | function and table sinks, removal, isolation, `maxSinks`, the chat sink |
| `SecretValues_spec.lua` | the placeholder and every secret refusal |
| `Limits_spec.lua` | `SetLimits`, `GetLimits`, truncation, `UNBOUNDED`, the SignalKit interaction |
| `Command_spec.lua` | `RegisterCommand` and `/log` |
| `BindLevels_spec.lua` | `BindLevels` against a real SettingsKit database |
| `Allocation_spec.lua` | the allocation guards |
| `ErrorLevels_spec.lua` | argument errors reported at the caller's line |
| `Bootstrap_spec.lua` | publication, duplicate loads, upgrades, corrupted state |
| `Manifest_spec.lua` | manifest and runtime `API` / `REVISION` agreement, declared dependencies |
