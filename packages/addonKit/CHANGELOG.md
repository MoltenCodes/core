# Changelog

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
