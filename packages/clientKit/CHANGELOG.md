# Changelog

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
