# Changelog

## 0.1.3 — 2026-09-24

- Documentation and comments only; the executed code is unchanged (`luac -s -l` listings identical), so the implementation revision stays 2.
- `docs/API.md` ("Missing keys") no longer promises that a secret key is returned unchanged. Measured on Retail 12.1.0 b69933, the client refuses a secret used as a table key at the index itself, before the read table's `__index` runs: `L[secretKey]` raises `attempted to index a table that cannot be indexed with secret keys` at the caller's line, and nothing is stored, recorded or reported. The secret-values section of `Format` no longer gives a read table as the source of a secret template.
- `docs/API.md` records that the client's own `string.format` accepts positional specifiers (`%2$s %1$s`, `%3$.2f %1$s %2$05d`) and refuses `%100s` with `invalid format (width or precision too long)`, measured on Retail 12.1.0 b69933. `Format` keeps parsing indexes itself, as documented.
- The comments in `readMissing` and `Format` and `docs/INTERNALS.md` say that the secret-key branch of `readMissing` is not reached on Retail 12.1; it stays for a host that lets such a read through. Two spec descriptions in `SecretValues_spec.lua` say the same.

## 0.1.2 — 2026-09-24

- Implementation revision 2 applies the repository nil rule: the absence of a caller's argument or option field (`options`, `options.isDefault`, `options.missing`, `options.maxMissingKeys`, `SetLocaleOverride`'s `locale`) and a failed locale-code match on a caller's or the host's value are tested with `type(value) == "nil"`, never by comparing the value with `nil`. The Registry lookup in the shared namespace and the results of `Registry:Bootstrap` are tested the same way.
- `GetLocale` asks `issecretvalue` about `options.maxMissingKeys` before comparing it with `LocaleKit.UNBOUNDED`; a secret is still refused with the same message at the caller.
- The upgrade specs load the shipped revision plus one instead of a fixed revision 2, and a new spec upgrades a revision 1 package in place to the working file. The suite has 98 specs.

## 0.1.1 — 2026-09-24

- Documentation only; the executed code is unchanged, so the implementation revision stays 1.
- `docs/API.md` lists `GetLocale`'s `options.maxMissingKeys` check among the uses of `issecretvalue`.
- `docs/INTERNALS.md` no longer claims `capReported` is cleared when `GetLocale` raises the limit: the first `GetLocale` fixes the limit before any key can be recorded as missing, so the flag is never cleared.
- `tests/README.md` describes the limit rule as the specs pin it: the first call fixes it, a later different one is refused.
- The suite has 96 specs; the 0.1.0 entry's count of 87 predates the last specs added to that release.

## 0.1.0 — 2026-09-23

- Added LocaleKit API generation 1, implementation revision 1.
- Added `LocaleKit:NewLocale(addonName, locale, options)`: a fresh write proxy per call for the client's locale or the default locale (`options.isDefault`), and `nil` for any other, so a translation file for an unneeded locale ends on its first line. `L["key"] = true` stores the key as its own text. The default proxy never overwrites a key already present, so translation files may load in any order. Reading through a proxy returns the stored text or `nil` and never raises. A second, different default locale for the same addon is refused.
- Added `LocaleKit:GetLocale(addonName, options)`: one read table per addon, default strings with the client's on top, with `missing = "report"` (the default: the key is returned, stored as its own value and reported once through the host error handler, or printed without one), `"silent"` or `"raw"`. The first call fixes the mode; a later call naming another mode raises at the caller, one naming none accepts it. A key read before its translation file loaded takes the translation when it arrives.
- Missing-key bookkeeping is bounded at 1024 keys per addon; past that a missing key still reads as itself but is neither stored, recorded nor reported, and the cap is reported once.
- Bounded by default, opened on purpose: `GetLocale` accepts `options.maxMissingKeys`, a positive integer or the new `LocaleKit.UNBOUNDED` sentinel, fixed by the first call like the mode: a later call naming a different limit raises at the caller, one naming the same limit or none accepts it. The one-time cap report names the limit and the option. An invalid or secret value raises at the caller and changes nothing. The sentinel lives in the package state (`_state.unbounded`), is part of the public-surface check, and survives an in-place upgrade together with each addon's limit. See "Limits" in `docs/API.md`.
- Added `LocaleKit:MissingKeys(addonName)`: the sorted keys read but never defined, in a new array per call.
- Added `LocaleKit:Format(template, ...)` with `%s`, `%d`, `%f` (flags, width, precision), indexed `%1$s` specifiers with reordering and repetition, and `%%`: one `string.gsub` per call, no table or closure allocated. A missing argument, a wrong argument type, an unsupported specifier and a secret argument (through `issecretvalue`, looked up at call time) raise at the caller.
- Added `LocaleKit:SetLocaleOverride(locale)` for translators; `nil` clears it. `enGB` clients and overrides are folded to `enUS`, and a client without `GetLocale` is treated as `enUS`.
- Proxies and read tables use metatables kept in package state and rewritten by each loading revision, so an in-place upgrade keeps every table, mode, missing key, proxy and the override.
- `Format` reports a specifier `string.format` refuses (a width or precision over 99, a repeated flag) as `LocaleKit:Format template has an invalid specifier "..."` at the caller and clears its staged arguments on every failure.
- A read table returns a secret key (through `issecretvalue`, looked up at call time) unchanged, without storing, recording or reporting it.
- The proxy and read-table metatables are protected with `__metatable`, and a table carrying a proxy metatable that `NewLocale` did not return is refused at the assignment line.
- An unknown option key that is not a string is named by its type, so no `__tostring` runs.
- `Format` refuses a secret template as well as a secret argument (`LocaleKit:Format template must not be a secret value`, at the caller). A read table returns a secret key as itself, so a template read with runtime data could be secret, and `string.gsub` must not run over it.
- 87 specs, including interleaved registration by two addons, an in-place upgrade spec, allocation guards on translated and missing lookups and on `Format`, and error levels pinned for every argument, write-proxy and template failure.
