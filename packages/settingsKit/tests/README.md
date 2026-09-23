# SettingsKit Tests

The SettingsKit suite covers:

- `Open`: the saved variable created with the full layout when missing, adopted when the client loaded it, refused when it is not a table; the same database for a second `Open` of the name (and a refusal for a different schema table or a replaced global); nodes and sealed schemas both accepted, with SettingsKit's own failure table; the "every field optional" rule with the offending path, also inside keyed-section records; malformed schema tables, options and saved-variable names;
- defaults: scalar and nested record defaults read without being written back, defaults declared inside a table default, a saved record without a default reading its own field defaults, wildcard defaults of a keyed section (records and scalars), a section's own default entries before its wildcard, the first-read copy of an array default, undeclared fields, views being empty proxies, and a `nil` key of a keyed section reading `nil` after the secret probe was asked;
- validated writes: stored when valid, refused at the writer's line with SchemaKit's failure text, undeclared fields of closed records, nested record fields, whole tables, keyed-section keys, values and entries, the keyed-section bound, `nil` resetting to the default, NaN keys, and `OnChange` with its `(db, scope, key, value, path)` arguments (also not firing for a refused write);
- key rendering: a key holding a `|T...|t` escape and a control byte shown safely in a refusal message and in an `OnChange` path, an identifier key unchanged, and a long key cut between UTF-8 characters;
- secret values: a secret value, a secret nested in a table value, a secret key and a secret read key, each refused at the line that used it with nothing stored;
- scopes: each of the six scope keys in the saved table, keys resolved once, other characters kept apart, unavailable scopes for each missing identity function (including an empty or secret answer) raising at the reader's line, undeclared scopes, and `OnChange` refused for either;
- profiles: `Default`, `defaultProfile = "char"` (and its fallback), a named default, `SetProfile` with its signal, the recorded choice and the change of `db.profile`, reopening on an earlier session's choice, sorted `GetProfiles`, `CopyProfile`, `ResetProfile`, `DeleteProfile` (current and missing refused, views detached, choices forgotten), name validation, a corrupted stored choice, `ResetDatabase`, and profile methods without a profile schema;
- migrations: a new table stamped without running steps, an older table migrated once in ascending order and not again in the next session, an unversioned table treated as version 0, a failing step retried next time, a newer stored version left alone, and a malformed stored version;
- `Compact`: default-equal values removed deeply while changed values, tables without defaults and empty profiles stay, every stored character compacted, compaction on `PLAYER_LOGOUT` through EventKit, a failing logout compaction reported, and a host without EventKit;
- values a saved variable cannot hold: a view assigned as a value (the review's aliasing probe, on a host without `issecretvalue`), a view nested in a table, tables with a metatable;
- keyed-section reads storing nothing: twelve reads of a `max = 3` section with a plain-table wildcard, a key the key schema refuses, and a plain-table default read inside an entry that is not saved;
- `db:Pairs`: record and keyed-section views, undeclared saved keys, no allocation, and refusal of anything but a view of the database;
- `db:Validate`: accepted values with nothing written or signalled, refusal messages identical to a refused write's (schema, undeclared field, key schema, view, metatable, secret value and key), a full keyed section, paths through a non-record, the current profile, argument errors, and no allocation for a valid array-path check;
- a secret read key on a record view, and undeclared keys surviving `Compact`;
- allocation guards (`collectgarbage("count")` with the collector stopped) on a default read, top-level, nested and through a wildcard entry, and on a validated write of an existing key with a listener connected;
- duplicate embedded loading, Registry publication, yielding to a newer revision, missing Registry, SchemaKit or SignalKit, an incomplete facade, loading without EventKit, and an in-place upgrade to revision 2 that keeps the database, its views, its listeners and its logout compaction;
- `error` levels: every `Open` and database-method argument failure, every receiver failure and the view refusals report the caller's own line;
- manifest/runtime API and revision consistency.

`support/SettingsKitTestEnv.lua` loads Registry, SignalKit, EventKit, SchemaKit and SettingsKit in that order. It stubs the player identity (`UnitName`, `GetRealmName`, `UnitClass`, `UnitFactionGroup`) through `SetPlayer`, where a field set to `false` leaves that function out, and removes it again in `Reset`, together with every saved variable a spec named or SettingsKit created; the shared fixture does not model these globals. `InstallSecretProbe` and `NewSecret` provide an `issecretvalue` that reports the spec's own secret tables. EventKit is an optional dependency, so the runner puts it on `LUA_PATH`; `NewPackageWithoutEventKit` simply leaves it out of the module chain.

| Spec | Covers |
|---|---|
| `Open_spec.lua` | `Open`, the saved variable, schema and option refusals |
| `Defaults_spec.lua` | default reads, wildcard defaults, the first-read copy |
| `Writes_spec.lua` | validated writes, `OnChange`, secret values and keys |
| `Scopes_spec.lua` | scope keys and unavailable or undeclared scopes |
| `Profiles_spec.lua` | profile methods and signals, `ResetDatabase` |
| `Migrations_spec.lua` | versioned migrations |
| `Compact_spec.lua` | `Compact` and the logout compaction |
| `Aliasing_spec.lua` | views and metatables refused as values, keyed-section reads storing nothing, `db:Pairs`, undeclared keys through `Compact` |
| `Validate_spec.lua` | `db:Validate` |
| `Allocation_spec.lua` | allocation guards |
| `ErrorLevels_spec.lua` | errors reported at the caller's line |
| `Bootstrap_spec.lua` | publication, duplicate loads, upgrades |
| `Manifest_spec.lua` | manifest and runtime metadata |
