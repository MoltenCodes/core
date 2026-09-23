# Changelog

## 0.1.0 — 2026-09-23

- Added OptionsKit API generation 1, implementation revision 1.
- Added `OptionsKit:Define(addonName, tree, options)`, `OptionsKit:Get(addonName)` and `OptionsKit:Undefine(addonName)`. A tree is a root `group` whose `args` hold `group`, `toggle`, `range`, `select`, `multiselect`, `input`, `color`, `keybinding`, `execute`, `header` and `description` options. The whole tree is checked and copied at `Define`, refusing unknown fields, more than `OptionsKit.MAX_OPTIONS` (1024) options and paths longer than `OptionsKit.MAX_DEPTH` (8) keys, at the caller's line.
- Every value option gets a SchemaKit schema at `Define`: boolean (optional for a tristate toggle), bounded number, enum of the values' keys (or a custom check over a values function), map of keys to booleans, string with a pattern, `{ r, g, b[, a] }` in `0..1`, and string.
- Values are read and written through `get(info)` / `set(info, value)` or `bind = "profile.path"` into a SettingsKit API 1 database passed as `options.db`; SettingsKit is an optional dependency found with `Registry:Find`.
- Added the tree methods `Get`, `Set` (schema asserted at the caller's line, then `validate`, then the write, then `OnChange`), `Validate`, `Reset` (bound options only), `Execute`, `IsDisabled`, `IsHidden` (a group's flag applies below it), `Walk` (pre-sorted, depth-first), `Describe` (a fresh plain table for renderers) and `OnChange` (a SignalKit connection).
- `Get`, `Set`, `Walk`, `Validate` of a valid value, `IsDisabled` and `IsHidden` allocate nothing: paths are indexed and siblings sorted at `Define`, and each option's `info` table is built once and reused.
- `Set` refuses a secret value at the caller's line.
- 94 specs, including allocation guards, pinned error levels, an in-place upgrade spec and a binding spec against a real SettingsKit database (pending when SettingsKit is not on the path).
