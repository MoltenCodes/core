# Changelog

## 0.1.0 — 2026-09-23

- Added OptionsKit API generation 1, implementation revision 1.
- Added `OptionsKit:Define(addonName, tree, options)`, `OptionsKit:Get(addonName)` and `OptionsKit:Undefine(addonName)`. A tree is a root `group` whose `args` hold `group`, `toggle`, `range`, `select`, `multiselect`, `input`, `color`, `keybinding`, `execute`, `header` and `description` options. The whole tree is checked and copied at `Define`, refusing unknown fields, more than `OptionsKit.MAX_OPTIONS` (1024) options and paths longer than `OptionsKit.MAX_DEPTH` (8) keys, at the caller's line.
- Every value option gets a SchemaKit schema at `Define`: boolean (optional for a tristate toggle), bounded number, enum of the values' keys (or a custom check over a values function), map of keys to booleans, string with a pattern, `{ r, g, b[, a] }` in `0..1`, and string.
- Values are read and written through `get(info)` / `set(info, value)` or `bind = "profile.path"` into a SettingsKit API 1 database passed as `options.db`; SettingsKit is an optional dependency found with `Registry:Find`.
- Added the tree methods `Get`, `Set` (schema asserted at the caller's line, then `validate`, then the write, then `OnChange`), `Validate`, `Reset` (bound options only), `Execute`, `IsDisabled`, `IsHidden` (a group's flag applies below it), `Walk` (pre-sorted, depth-first), `Describe` (a fresh plain table for renderers) and `OnChange` (a SignalKit connection).
- `Get`, `Set`, `Walk`, `Validate` of a valid value, `IsDisabled` and `IsHidden` allocate nothing: paths are indexed and siblings sorted at `Define`, and each option's `info` table is built once and reused.
- `Set` refuses a secret value at the caller's line.
- A SettingsKit refusal of a bound write is raised at the caller's line of `Set` or `Reset`, with SettingsKit's message kept. `Validate` of a bound option then asks the database through `db:Validate(scope, keys, value)`, so `Validate` and `Set` agree; `options.db` must offer `Validate` as well as `OnChange`.
- A bind path through a record that has no default and no saved data reads as `nil`, and `Set` writes the missing records as one nested table; a scope the database does not provide is refused at the caller's line of `Define` (and of later calls) with OptionsKit's own message instead of SettingsKit's.
- `docs/API.md` carries a complete options tree example over a SettingsKit database.
- `Describe` copies a table value (at most 8 tables deep). A bound `multiselect` or `color` used to be described by the SettingsKit view itself, which `pairs` sees as empty and which writes through to the saved variable when a renderer edits the description; a view is now copied through `db:Pairs`, defaults included. A secret value, at the top or nested, is passed through without being copied before anything inspects it.
- A bound `Set` or `Reset` whose write SettingsKit stored but one of SettingsKit's own `OnChange` listeners then raised re-raises that listener's error unchanged; it used to report it as `refused by the database`. `db:Validate` tells the two apart, on the failure path only.
- An unknown `Define` option is named deterministically (the alphabetically first), and a key that is not a string by its type, so no `__tostring` runs.
- README resolves the package with `MoltenCodes.Registries[2]`, the generation-pinned form `docs/EMBEDDING.md` recommends.
- 103 specs, including allocation guards, pinned error levels, an in-place upgrade spec and a binding spec against a real SettingsKit database (pending when SettingsKit is not on the path).
