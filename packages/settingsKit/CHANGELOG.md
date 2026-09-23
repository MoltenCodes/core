# Changelog

## 0.1.0 — 2026-09-23

- Added SettingsKit API generation 1, implementation revision 1.
- Added `SettingsKit:Open(savedVariable, schema, options)`: one database per saved-variable name for the session; opening the name again returns the same database. A missing saved variable is created as `{}`; any other non-table value is refused. `schema` maps the scopes `global`, `char`, `realm`, `class`, `faction` and `profile` to SchemaKit `table` schemas, each sealed by SettingsKit; every field of a record read through a view must be `optional`. Options are `defaultProfile` (`"Default"`, `"char"` or a name), `version` and `migrations`; unknown fields are refused.
- Scope keys are read once at `Open` from `UnitName`, `GetRealmName`, `UnitClass` and `UnitFactionGroup`. A scope whose key is missing is unavailable, and reading it raises at the reading line; so does reading a scope the schema does not declare.
- Views: `db.<scope>` are empty proxies over the saved table. Reads fall back to the schema's defaults, including wildcard defaults for every key of a keyed section, without writing them back; plain table defaults (arrays) are copied into the saved table on first read. Writes are checked against the scope's schema at the writer's line with SchemaKit's failure text, keyed sections are held to their `max`, and secret keys and values (also nested in a table) are refused.
- Profiles: `GetProfile`, `SetProfile` (creates the profile and records the choice per character), `GetProfiles` (sorted), `CopyProfile`, `ResetProfile`, `DeleteProfile` (the current profile is refused; views of a deleted profile are detached) and `ResetDatabase`.
- Signals, each returning a SignalKit connection: `OnChange(scope, callback)` called with `(db, scope, key, value, path)` after every validated write, `OnProfileChanged`, `OnProfileCopied`, `OnProfileReset` and `OnProfileDeleted`.
- Versioned migrations: each `migrations[n]` receives the raw saved table and runs once, in ascending order, from the stored version + 1 to `options.version`, storing the version after each step. A new, empty saved table is stamped without running any.
- `db:Compact()` removes every saved value equal to its default across every character, realm, class, faction and profile entry, and returns how many it removed. With EventKit API 1 present (found through `Registry:Find`), every database compacts itself on `PLAYER_LOGOUT`; a failure there is reported, not raised.
- The saved table keeps a `namespaces` section and a `profileKeys` section from v1, so v2 (spec-aware profiles and namespaces) needs no layout change.
- A view assigned as a value, or a table carrying a metatable, is refused at the writer's line, top level or nested and on every client, so a saved table never aliases a view or skips validation.
- Reading a missing keyed-section entry never stores anything, so reads cannot grow a section past its `max` or store a key its key schema refuses; only a validated write creates an entry.
- Added `db:Pairs(view)`: a stateless, allocation-free iterator over a view's keys with defaults, then its saved keys.
- A record view refuses a secret read key, as a keyed-section view does.
- The manifest lists EventKit API 1 under `optionalDependencies`.
- A default read and a validated write of an existing key allocate nothing. Databases, views and their listeners survive an in-place upgrade.
- 105 specs, including allocation guards, an in-place upgrade spec and pinned error levels.
