# Changelog

## 0.1.0 — 2026-09-23

- Added LocaleKit API generation 1, implementation revision 1.
- Added `LocaleKit:NewLocale(addonName, locale, options)`: a fresh write proxy per call for the client's locale or the default locale (`options.isDefault`), and `nil` for any other, so a translation file for an unneeded locale ends on its first line. `L["key"] = true` stores the key as its own text. The default proxy never overwrites a key already present, so translation files may load in any order. Reading through a proxy returns the stored text or `nil` and never raises. A second, different default locale for the same addon is refused.
- Added `LocaleKit:GetLocale(addonName, options)`: one read table per addon, default strings with the client's on top, with `missing = "report"` (the default: the key is returned, stored as its own value and reported once through the host error handler, or printed without one), `"silent"` or `"raw"`. The first call fixes the mode; a later call naming another mode raises at the caller, one naming none accepts it. A key read before its translation file loaded takes the translation when it arrives.
- Missing-key bookkeeping is bounded at 1024 keys per addon; past that a missing key still reads as itself but is neither stored, recorded nor reported, and the cap is reported once.
- Added `LocaleKit:MissingKeys(addonName)`: the sorted keys read but never defined, in a new array per call.
- Added `LocaleKit:Format(template, ...)` with `%s`, `%d`, `%f` (flags, width, precision), indexed `%1$s` specifiers with reordering and repetition, and `%%`: one `string.gsub` per call, no table or closure allocated. A missing argument, a wrong argument type, an unsupported specifier and a secret argument (through `issecretvalue`, looked up at call time) raise at the caller.
- Added `LocaleKit:SetLocaleOverride(locale)` for translators; `nil` clears it. `enGB` clients and overrides are folded to `enUS`, and a client without `GetLocale` is treated as `enUS`.
- Proxies and read tables use metatables kept in package state and rewritten by each loading revision, so an in-place upgrade keeps every table, mode, missing key, proxy and the override.
- `Format` reports a specifier `string.format` refuses (a width or precision over 99, a repeated flag) as `LocaleKit:Format template has an invalid specifier "..."` at the caller and clears its staged arguments on every failure.
- A read table returns a secret key (through `issecretvalue`, looked up at call time) unchanged, without storing, recording or reporting it.
- The proxy and read-table metatables are protected with `__metatable`, and a table carrying a proxy metatable that `NewLocale` did not return is refused at the assignment line.
- An unknown option key that is not a string is named by its type, so no `__tostring` runs.
- 86 specs, including interleaved registration by two addons, an in-place upgrade spec, allocation guards on translated and missing lookups and on `Format`, and error levels pinned for every argument, write-proxy and template failure.
