# LocaleKit Tests

The LocaleKit suite covers:

- `NewLocale`: a proxy for the client locale and `nil` for any other, the default locale always needed, nothing registered for an unneeded locale, a fresh proxy per call, `true` stored as the key, the default proxy not overwriting a translation or an earlier default file, a translation overwriting a default, reading through a proxy without raising, two addons interleaving their calls, a second default locale refused, bad keys, values and arguments, protected metatables, a forged proxy refused at the assignment line, and unknown option keys named by type without `__tostring`;
- `GetLocale`: layering, one table per addon, translations registered after the first call, the three missing-key modes, the report sent once through the host error handler and printed without one, the first call fixing the mode (a later different mode refused, an omitted one accepted), a missing key taking a translation or default registered later, the 1024-key cap, and an addon that registered nothing;
- `MissingKeys`: sorted, a new array per call, per addon, empty for an unknown addon;
- `Format`: sequential `%s`, `%d`, `%.2f`, flags and width, indexed reordering and repetition, mixed indexed and unindexed specifiers, `%%`, an index beyond the arguments, index zero, unsupported and truncated specifiers, wrong argument types, specifiers `string.format` refuses (width over 99, repeated flags) reported by name, no argument retained after a call or a refusal, and secret arguments and a secret template refused through an `issecretvalue` stub looked up at call time; a secret key handed back by a read table without being stored or reported;
- the client locale: `enGB` folding, a client without `GetLocale` or with an unexpected answer, the override (set, `enGB` folded, cleared, not applied to an addon already registered, named in reports);
- allocation guards (`collectgarbage("count")` with the collector stopped) on translated and default lookups, a missing key after its first read, and a repeated `Format`;
- duplicate embedded loading, Registry publication, yielding to a newer revision, missing Registry, an incomplete facade, and an in-place upgrade that keeps tables, modes, missing keys, older proxies and the override;
- `error` levels: every argument, write-proxy and template failure reports the caller's own line;
- manifest/runtime API and revision consistency.

The shared fixture does not stub `GetLocale`, so `support/LocaleKitTestEnv.lua` installs it (`NewPackage(clientLocale)`, `SetClientLocale`) and removes it on `Reset`.

| Spec | Covers |
|---|---|
| `NewLocale_spec.lua` | write proxies, default and client-locale rules, bad writes |
| `GetLocale_spec.lua` | layering, missing-key modes, the mode fixed by the first call, the cap |
| `MissingKeys_spec.lua` | the coverage report |
| `Format_spec.lua` | specifiers, indexes, template and argument errors |
| `SecretValues_spec.lua` | secret templates, arguments and keys |
| `ClientLocale_spec.lua` | `enGB` folding, a missing `GetLocale`, the override |
| `Allocation_spec.lua` | allocation guards |
| `ErrorLevels_spec.lua` | errors reported at the caller's line |
| `Bootstrap_spec.lua` | publication, duplicate loads, upgrades |
| `Manifest_spec.lua` | manifest and runtime metadata |
