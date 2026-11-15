# Changelog

## 0.2.0 — 2026-11-15

The module defaults and the module-created notice on the facade (roadmap package O, "addonKit: the module defaults and the created notice on the facade", ADR 0004).

- Added: `MC:SetDefaultModuleState(enabled)`, `MC:SetDefaultModulePrototype(prototype)` and `MC:OnModuleCreated(callback | receiver[, methodName])`, forwarded to the addon container's ModuleKit methods (ModuleKit revision 23 and later) with their refusals raised at the author's line; an older ModuleKit is named with the fix.
- Changed: `MC:NewAddon()` sets the addon object's intent back to `true` when the container's module default is `false`, unless its definition says `enabledState = false`: the module default never applies to the addon object, as in AceAddon.
- Not changed: the Composition part registers `MC:Options`' slash command with `Register` alone, so it needs neither of CommandKit 0.3.0's parts, and its contract is unchanged.
- Memory (host, load-and-execute footprint, debug information kept): 38,752 → 41,409 B.
- Implementation revision 2. An in-place upgrade from revision 1 adds the three methods to `_state.methods`.
- Specs: 72 → 79 (`ModuleDefaults_spec.lua`). The client suite gains one test (never run).

## 0.1.0 — 2026-11-15

- Added AddonKit API generation 1, implementation revision 1: the single entry point for addon authors, as recorded in `docs/ROADMAP.md` (package O, core decisions 18 and 19).
- `MoltenCodes:For(...)` and `AddonKit:For(...)`: one facade per addon, shared by its files. `MC.<Kit>` resolves every catalogue Kit through `Registry:Find` on the first read and caches it; `MC.S`, `MC.Registry`, `MC.addonName`; `MC:Use` pins a generation. AddonKit installs `MoltenCodes.For` only when the key is free or already its own.
- Errors at the author's line that say the fix: a Kit not loaded (the file to add), a misspelt name (`did you mean`), a part not loaded, a write to the facade.
- The addon object: `MC:NewAddon`, `MC:NewModule` (modules depend on the addon), `MC:GetAddon`, `MC:GetModule`, over ModuleKit.
- Part Database, revision 1: `MC:Database` opens a SettingsKit database from AceDB-style defaults with the schema inferred (`["*"]` wildcards, `{}` bags, lists, inline schema nodes) and refuses to open before `ADDON_LOADED`; `MC.Range` and `MC.Enum`.
- Part Composition, revision 1: `MC:Options` (OptionsKit, PanelKit and a CommandKit slash command, with CommandKit's refusals raised), `MC:Launcher` (BrokerKit and LauncherKit, the position kept in the profile and moved on a profile switch), `MC.LAUNCHER_DEFAULTS`.
- `AddonKit:GetCatalogue`, `SetLimits` and `GetLimits` for `maxFacades` (256, up to 4096).
- Full LuaCATS types for the facade, so lua-language-server completes and checks calls through it.
- 72 specs, among them the ten-task flow and the getting-started guide's steps, and a client suite, `tests/client/MoltenCodesTest_AddonKit`, not yet run in a client.
