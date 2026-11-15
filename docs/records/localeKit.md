# localeKit records

Moved from `docs/ROADMAP.md` (Package C planned Kits — the nine points).

## localeKit

**localeKit** — facade `LocaleKit`

1. Package `localeKit`, facade `LocaleKit`, API generation 1.
2. Purpose: translations per addon and locale with the cost of one table on
   any client, missing-key reporting once per key, a coverage report, and
   indexed format specifiers so translators can reorder arguments. Non-goals:
   plural rules, gender, shipping any translations.
3. Dependencies: registry API 2 only.
4. Surface: `LocaleKit:NewLocale(addonName, locale, options)` → a write
   proxy for that locale, or `nil` when the client does not need it
   (`options.isDefault` marks the fallback locale; a per-call proxy, never a
   shared one; the default proxy never overwrites a translated key);
   `LocaleKit:GetLocale(addonName, options)` → the read table for the
   running client, `__index` returning the key and reporting once through
   the host error handler (`options.missing = "report" | "silent" |
   "raw"`); `LocaleKit:Format(template, ...)` supporting `%1$s`-style
   indexed specifiers; `LocaleKit:MissingKeys(addonName)` → sorted array;
   `LocaleKit:SetLocaleOverride(locale)` for translators; `enGB` folded to
   `enUS`.
5. Ownership: locale tables are package state keyed by addon name; nothing
   to tear down; upgrades keep them.
6. Performance: a translation lookup is one table read; a missing key is
   `rawset` on first use so it costs the report once; `Format` allocates only
   strings (each formatted piece and the result), no tables.
7. Tests: proxy for the running locale versus `nil`, default proxy not
   overwriting, missing-key modes, report once, MissingKeys sorted,
   indexed format including reordering and repeated arguments, override,
   enGB folding, upgrade, manifest, error levels pinned.
8. Docs: README, API.md, CHANGELOG; a translation-file example.
9. Status: implemented (package C2, 0.1.0).

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## localeKit fast unneeded-locale path

**localeKit fast unneeded-locale path** — an internal change to facade `LocaleKit`

1. Package `localeKit`, facade `LocaleKit`, API generation 1 (unchanged),
   version 0.1.7, implementation revision 5 (from 0.1.6, revision 4).
   Patch.
2. Purpose: make `NewLocale` for a locale the client does not need cost
   what AceLocale-3.0's does, and win back the revision 4 regression
   (123 → 180 ns), following the runtime performance diagnosis of
   2026-11-15 (localeKit).
   - Fast path: when `options` is `nil`, `NewLocale` asks the probe about
     `addonName` and `locale`, then looks up `addons[addonName]` and
     `CLIENT_LOCALE_CODES[locale]`. When both hit and the locale is not the
     record's, it returns `nil` at once. `addons` holds only validated
     non-empty names and `CLIENT_LOCALE_CODES` only valid codes, so the two
     hits prove what the `type` checks proved. Everything else (a first
     call for an addon, options given, a miss, a secret) takes today's full
     path with its messages and levels.
   - The secret-probe rule: `issecretvalue` resolved once at load, looked
     up per call only when it was absent at load, in `refuseSecret`,
     `validateLimit`, `NewLocale` and `Format`
     (`LocaleKit.lua:294`, `:372`, `:819`, `:1014`).
   - Decision 19b: `readMissing` (`:626-640`) drops its probe check on the
     key. The client refuses a secret key at the index, before `__index`
     runs (measured on Retail 12.1.0 b69933, docs/EMBEDDING.md), so
     `L[secretKey]` raises at the caller's line and the branch never runs
     in the client.
3. Dependencies: unchanged (registry API 2).
4. Surface: unchanged. Same messages and levels on every path. On a host
   that lets a secret key reach `__index` (none in the client), the key is
   now treated like any other key.
5. Ownership: unchanged; the load-time probe is file-local. An in-place
   upgrade from revision 4 keeps every addon record.
6. Performance and memory, host bench `locale` workload, MoltenCodes ÷
   AceLocale-3.0 in the same run (the diagnosis prototype):

   | Case | Before | After (expected) |
   |---|---:|---:|
   | unneeded-locale | 190 / 52 ns = 3.64× | 82 / 53 ns = 1.56× |
   | direct timing | 152 ns | 54 ns |
   | with a probe present at load (the client case) | | 35 ns |

   `lookup` is already at parity (1.02×). Not changed: first-miss (2.4×,
   the missing-key set `MissingKeys` needs) and register (1.35×, per-string
   validation). No memory change.
7. Tests: the fast path returns `nil` for an unneeded locale of a known
   addon; a first call, options, an unknown locale code, a non-string or
   empty name, and a secret name or locale each take the full path with
   today's messages at the caller's line; the probe rule (present at load,
   installed after load: `SecretValues_spec:26` keeps passing); the
   `SecretValues_spec:60` case for the defensive `readMissing` branch is
   replaced by a client suite assertion; in-place upgrade from revision 4.
   Client suite (`tests/client/MoltenCodesTest_LocaleKit/`, never run
   here): `L[secretwrap("x")]` raises at the reading line, and nothing is
   recorded as missing.
8. Docs: `docs/API.md` (cost note, the secret-key read), `INTERNALS.md`,
   `CHANGELOG.md` 0.1.7, `tests/README.md`, the client suite's
   `EXPECTED.md`.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.1.7,
   revision 5, 5 specs (124).

