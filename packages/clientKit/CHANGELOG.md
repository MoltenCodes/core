# Changelog

## 0.2.1 — 2026-09-24

- `GetManifest` trusts `GetAddOnInfo` on a host that has it: once it answers `"MISSING"` the name is `nil, "unknown"` without asking for `## Title`, so an unknown name costs one host call instead of up to three metadata reads. The `## Title` probe remains the way a host without `GetAddOnInfo` recognises an addon.
- `Has(capability)` refuses a secret `capability` at the caller (`ClientKit:Has capability must not be a secret value`) before using it as a table key.
- An upgrade refuses inherited `manifests` or `manifestPrototype` state that is present but not a table (`package state is corrupted or incomplete`) instead of indexing it.
- `docs/API.md`: `issecretvalue` is present on the current Classic Era and Mists Classic clients as well as Retail 12.0 and later; `GetItemInfo` lists the eighteenth host return, `itemDescription`; the listed-addon rule and the `Has` secret refusal are documented.
- Implementation revision 3. Revision 3 changes no state field, so an upgrade over revision 2 keeps every cached manifest and its identity.
- 129 specs: an upgrade over a revision 2 layout that keeps the manifest cache, both non-table state refusals, an unknown name answered without any `Title` read, and the `Has` secret refusal with its error level. `ClientKitTestEnv.NewHostFor` installs a profile and ClientKit's own host functions without loading ClientKit, for upgrade specs.

## 0.2.0 — 2026-09-24

- Added `ClientKit:GetManifest(addonName)`: a read-only snapshot of an addon's `.toc`, read through `C_AddOns.GetAddOnMetadata` (else the legacy `GetAddOnMetadata`) once per addon on the first call and cached for the session. The snapshot carries `name`, `title`, `notes`, `version`, `author`, `interface`, `iconTexture`, `iconAtlas`, `category`, `group`, `loadOnDemand`, `defaultState` and `addonCompartmentFunc` as the raw `.toc` strings (`nil` when absent, empty or not exported by the client), and `dependencies`, `optionalDependencies`, `savedVariables` and `savedVariablesPerCharacter` as arrays split on commas. `Dependencies` and `RequiredDeps` are one list; when the metadata call exports no dependency list the host's own `GetAddOnDependencies` / `GetAddOnOptionalDependencies` (either form) fill the arrays.
- `Title` and `Notes` try the locale-suffixed spelling first (`Title-deDE` before `Title`), with the locale read from `GetLocale()` at bootstrap into `_state.locale`; a host without `GetLocale`, or one answering something that is not a locale code, reads the plain fields only.
- `manifest:Get(field)` returns any raw `## Field`, `X-` fields included. A field is asked of the host once and remembered; the snapshot fields are remembered at creation, absence included, so `Get("Version")` never asks again. A field the `.toc` lacks is not remembered, so the memo grows only by fields the file actually has.
- Writes to a snapshot raise at the writer's line (`ClientKit manifest for "MyAddon" is read-only; field "version" cannot be written`); the four arrays are shared and documented read-only, since Lua 5.1 cannot refuse writes to an array without breaking `#` and `ipairs`.
- An addon the host does not list (`GetAddOnInfo` echoes the name with the reason `"MISSING"`, and no `## Title` reads) answers `nil, "unknown"` and is not cached; a host with neither metadata call answers `nil, "unavailable"`. The cache is therefore bounded by the addons installed in the client, a set no caller can grow, and needs no `SetLimits`.
- Addon names are matched case-insensitively, as the host matches them: the cache is keyed by the lower-cased name, so every spelling of one addon shares one snapshot, and `manifest.name` carries the folder name as the host spells it when `GetAddOnInfo` reports one.
- A secret `addonName` or `field` is refused at the caller (`must not be a secret value`) before it is compared or used as a table key.
- On real clients the metadata call exports only `Title`, `Notes`, `Author`, `Version`, `IconTexture`, `IconAtlas` and the `X-` fields; `docs/API.md` says which snapshot fields are therefore usually empty and that the dependency arrays come from the dependency host calls.
- Every host read a manifest makes goes through `pcall`, because a client raises for a `.toc` field its metadata call does not export; such a field reads `nil`.
- Implementation revision 2. An upgrade over revision 1 adds `locale`, `manifests` and `manifestPrototype` to the shared state without a schema change and binds `getLocale`, `getAddOnInfo`, `getAddOnDependencies` and `getAddOnOptionalDependencies` into the shared host table; snapshots cached before a later upgrade keep their identity and resolve `Get` through the prototype the newer copy rewrote. The upgrade specs now load the next revision instead of revision 2.
- 125 specs; `GetManifest_spec.lua` covers every field on all four profiles and both host forms, locale fallback, list splitting and the host list fallback, `X-` fields and memoisation counted at the host, unknown and unavailable addons (fifty unknown names leave the cache untouched), case-insensitive names, secret refusals, read-only enforcement, cache bounds and an allocation guard.

## 0.1.0 — 2026-09-23

- Added ClientKit API generation 1, implementation revision 1.
- `GetFlavor()` maps `WOW_PROJECT_ID` by value to `"mainline"`, `"mists"`, `"tbc"` or `"classic"`. The id must be a number before anything is compared, so an absent id can never match every flavour; an absent, non-number or unknown id yields `"classic"`, the flavour that assumes the least.
- `GetBuild()`, `GetInterfaceNumber()` and `IsAtLeast(interfaceNumber)` read `GetBuildInfo()` once at bootstrap. A host without it reports interface `0`, so every `IsAtLeast` floor answers `false`.
- `Has(capability)` over a fixed table of twelve capabilities, each probed from the host rather than inferred from the flavour. An unknown name raises at the caller.
- `IsSecret(value)`, `CanAccessFrame(frame)` and `IsEventValid(eventName)` wrap `issecretvalue`, `IsForbidden` / `CanBeAccessedInContext` and `C_EventUtils.IsEventValid`, with documented answers on clients that lack them.
- Shims `GetAddOnMetadata`, `IsAddOnLoaded`, `GetSpellInfo` and `GetItemInfo` return one documented shape on every flavour, preferring the `C_AddOns`, `C_Spell` and `C_Item` forms and falling back to the legacy globals.
- Everything is read from the host at bootstrap into shared state and re-read in place on an upgrade. Probes allocate nothing; `GetSpellInfo` on a client without `C_Spell.GetSpellInfo` allocates the one table it returns.
- Argument errors name the parameter and the expected type and point at the caller's line; a caller-supplied value is formatted into a message only when `issecretvalue` says it is not secret.
- An upgrade over inherited state whose `capabilities` or `host` table is missing raises `package state is corrupted or incomplete` instead of rebuilding the host table silently.
