# Changelog

## 0.3.3 — 2026-11-18

- Documentation and tests only; implementation revision 8 is unchanged. `docs/API.md` follows the repository skeleton: new *Loading*, *Secret values* and *Performance* sections, *Errors* renamed *Error behaviour* and placed after *Limits*, *Embedded identity and upgrades* renamed *Embedded copies and upgrades*. ClientKit carries no copy of the shared helper blocks (docs/records/shared-helpers.md): its probe, value descriptions and deprecation reporter are its own contract.
- New spec: `Conformance_spec.lua` (the repository's conformance suite).

## 0.3.2 — 2026-11-15

- Fixed: an error message described a caller's value with `tostring`, so a table with a `__tostring` metamethod given as a `SetLimits` key or written to a manifest snapshot ran the caller's code inside ClientKit, which could raise its own error or answer a secret. A string is still quoted and a number, boolean or `nil` shown as written; anything else is named by its type: `ClientKit:SetLimits does not know limit <table>`, `ClientKit manifest for "MyAddon" is read-only; field <table> cannot be written`. `Taint_spec.lua` ("ClientKit value descriptions") holds the regression specs, each with a `__tostring` that records that it ran and raises.
- The secret probe follows the rule every Kit follows: the `issecretvalue` bound at load is used, and only when the client had none then is the global looked up on each call, so a probe installed after load is honoured by `IsSecret` and every secret refusal. `Has("secretValues")` stays the answer read at load.
- Implementation revision 8. No state field changed: an in-place upgrade from revision 7 keeps the manifest cache, the deprecation state and the limits (`Bootstrap_spec.lua`, "upgrades the previous revision in place to the working file", now loads revision 7).
- Client suite: `clientKit.secrets` gains `writing a genuine secret key to a manifest is refused at the calling line, ...`, which records whether the client refuses a secret key on assignment before `__newindex` runs (core decision 19b); `EXPECTED.md` lists it and its totals move to 45 tests. Written, not run.
- 182 specs (was 178).

## 0.3.1 — 2026-11-15

- `IsAtLeast(interfaceNumber)` compared its argument before asking `issecretvalue`. A secret number passed the type check (`type` answers a secret's real type) and then reached the NaN test and the floor comparison, and comparing a secret from insecure code raises at the comparison (warcraft.wiki.gg, "Secret Values"), so the error named ClientKit's line instead of the caller's. `IsAtLeast` now refuses a secret first, at the caller: `ClientKit:IsAtLeast interfaceNumber must not be a secret value`. `ErrorLevels_spec.lua` ("refuses a secret IsAtLeast interfaceNumber at the caller before comparing it") is the regression spec; the client suite gains the same check with a value made by `secretwrap`.
- Implementation revision 7. No state field changed: an in-place upgrade from revision 6 keeps the manifest cache, the deprecation reporters, their once-keys, the reports, the mode and the limits (`Bootstrap_spec.lua`, "upgrades the previous revision in place to the working file", now loads revision 6).
- `Deprecation_spec.lua` covers a host error handler that warns again from inside a report: the once-key and the row are written before the handler runs, so the re-entry is answered as already reported.
- Documentation: the README gains a migration table from the hand-written client checks ClientKit replaces; `docs/API.md` lists the `IsAtLeast` secret refusal under "Errors" and revision 7 under "Embedded identity and upgrades".
- 178 specs (was 176).

## 0.3.0 — 2026-11-15

- Added deprecation warnings (W13, the part Registry's spent line budget leaves to ClientKit). `ClientKit:Deprecate({ name, removal, replacement? })` declares something a Kit deprecates and returns a reporter; a name declared again returns the same reporter with the newer text. `reporter:Warn(level?, addonName?)` reports the consumer once per call site, or once per addon when the Kit names it, never once per call: `MoltenCodes: TimerKit:After is deprecated; use TimerKit:Delay. Removal: TimerKit API 2. Called from MyAddon (Interface/AddOns/MyAddon/Core.lua:42).` The call site is read with the client's `debugstack` (the client has no `debug` library); the addon is the one given, else the folder after `Interface/AddOns/`, else `unknown`. Reports go to `geterrorhandler()` (else `print`), both under `pcall`.
- `GetDeprecationReports()` returns fresh rows `{ name, replacement, removal, addon, site }`. `SetDeprecationMode(mode)` / `GetDeprecationMode()`: `"report"` (default), `"silent"` (record only) or `"raise"` (a developer switch: raise at the consumer's line on every call, record nothing), one mode for the session.
- `SetLimits({ maxDeprecations, maxReports })` / `GetLimits()`: 128 deprecations (at most 1024) and 256 reports (at most 4096), no `UNBOUNDED`. Past `maxDeprecations` `Deprecate` returns one inert reporter and reports the limit once; past `maxReports` reporters stop reading call sites. `docs/API.md` "Limits" is rewritten, since ClientKit now has limits.
- Kits use it optionally, through `Registry:Find("clientKit", 1)` and a check for `Deprecate`; `docs/API.md` "Deprecations" gives the pattern. No Kit deprecates anything yet.
- Implementation revision 6. The state gains `deprecation` without a schema change; an upgrade over revision 5 or older creates it and keeps every cached manifest, and a later upgrade keeps reporters, their once-keys, the reports, the mode and the limits, with `Warn` rewritten in place through the reporter prototype.
- 176 specs (was 132): `Deprecation_spec.lua` (reporting, call-site forms, a host without `debugstack` or `geterrorhandler`, modes, limits, arguments and secret values, the optional-Kit pattern with ClientKit absent and at revision 5, an allocation guard), the upgrade from a revision 5 layout and across revisions in `Bootstrap_spec.lua`, and error levels in `ErrorLevels_spec.lua`. The client suite logs the client's `debugstack` frame and checks the suite's own addon is named.

## 0.2.4 — 2026-11-15

- Documentation: `docs/API.md` "Limits" no longer says every probe answers from the host on every call. The identity and capability methods read the values fixed at bootstrap; the taint probes (`IsSecret`, `CanAccessFrame`, `IsEventValid`) and the shims ask the host on every call and cache nothing. The `validateState` comment says the revisions after 2 changed no state field (it stopped at revision 3). Comments and documentation only: the implementation revision is unchanged.

## 0.2.3 — 2026-09-24

- A value that may be secret is no longer tested as a boolean, which raises inside the Kit on Retail 12.1.0 (build 69933). `manifest:Get` read its receiver's `name` with `view.name or nil`, a boolean test on a caller value; it now reads the field without testing it and asks `issecretvalue` before lowering it or using it as a key, so a receiver whose `name` is secret is refused at the caller with `ClientKit.Manifest:Get must be called on a manifest`. Every other boolean test was audited and left: each is on a value ClientKit created, a type-checked host function, or a host return the client does not document as possibly secret. `docs/API.md` lists them under "Errors".
- Implementation revision 5, because the executed implementation changed. No state changed: an in-place upgrade from revision 4 keeps every cached manifest, whose `Get` resolves through the rewritten prototype. `Bootstrap_spec.lua` covers that upgrade; `ErrorLevels_spec.lua` covers the refusal.

## 0.2.2 — 2026-09-24

- Implementation revision 4 applies the repository nil rule: the locale probe tests the result of matching `GetLocale()`'s answer against the locale-code shape with `type(match) == "nil"`, and the Registry lookup in the shared namespace and the results of `Registry:Bootstrap` are tested the same way, never by comparing them with `nil`. Every other `nil` comparison left in the source is on a value ClientKit created itself (its state tables, its memo, the normalised result of its own metadata read).
- Specs: the upgrade specs over the revision 1 and revision 2 layouts load the working file instead of a fixed revision 3, and a new spec upgrades a revision 3 package in place to the working file.

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
