# LocaleKit

LocaleKit gives an addon translations per locale at the cost of one table on any client. A translation file for a locale the client does not need ends on its first line, a key nobody translated reads as the key itself and is reported once, the keys read but never defined are available as a coverage report, and `Format` understands indexed specifiers (`%2$s`) so a translator can reorder arguments.

A translation file:

```lua
-- Locales/deDE.lua
local LocaleKit = MoltenCodes.Registries[2]:Get("localeKit", 1)
local L = LocaleKit:NewLocale("MyAddon", "deDE")
if not L then return end

L["Hello"] = "Hallo"
L["%s has %d items"] = "%2$d Gegenstände hat %1$s"
```

The default locale, loaded on every client, may list keys only:

```lua
-- Locales/enUS.lua
local LocaleKit = MoltenCodes.Registries[2]:Get("localeKit", 1)
local L = LocaleKit:NewLocale("MyAddon", "enUS", { isDefault = true })

L["Hello"] = true               -- the key is its own text
L["%s has %d items"] = true
```

Reading the strings:

```lua
local L = LocaleKit:GetLocale("MyAddon")
print(L["Hello"])                                             -- "Hallo" on a German client
print(LocaleKit:Format(L["%s has %d items"], "Alice", 3))     -- "3 Gegenstände hat Alice"
```

What each piece promises:

- **`NewLocale`** returns a fresh write proxy when the client needs that locale (it is the client's, or `isDefault` marks it as the fallback) and `nil` otherwise. Proxies are per call, so two addons registering at the same time cannot corrupt each other. The default proxy never overwrites a key already present, so translation files may load before or after the default file.
- **`GetLocale`** returns one table: the default strings with the client's on top. A lookup is one table read. `missing = "report"` (the default) returns an undefined key as itself and reports it once through the host error handler; `"silent"` does the same without the report; `"raw"` returns `nil`. The first call fixes the mode.
- **`MissingKeys`** returns the sorted keys an addon read but never defined, for a coverage report.
- **`Format`** supports `%s`, `%d`, `%f` with flags, width and precision, indexed `%1$s` in any order and any number of times, and `%%`. It raises at the caller for an argument that is missing, of the wrong type or secret.
- **`SetLocaleOverride`** lets a translator run another locale on their own client. `enGB` clients are folded to `enUS`.

Non-goals: plural rules, grammatical gender, runtime locale switching, and shipping any translations.

See [`docs/API.md`](docs/API.md) for the complete contract and [`docs/INTERNALS.md`](docs/INTERNALS.md) for the layout.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\localeKit\LocaleKit.lua
```

Direct runtime dependencies: Registry API 2.
Every file above is required; omitting one makes this package raise at
load.

List your own translation files after LocaleKit and before the files that call
`GetLocale`, with the default locale's file anywhere among them:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\localeKit\LocaleKit.lua
Locales\enUS.lua
Locales\deDE.lua
Locales\frFR.lua
Core.lua
```

LocaleKit reads the host's `GetLocale`, `geterrorhandler` and `issecretvalue`
when it needs them; each one is optional (see *Host facilities* in the API).
