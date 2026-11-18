# AddonKit Tests

The AddonKit suite covers:

- lookup: one facade per addon, a Kit resolved on the first read and cached, `MC.S` and `MC.Registry`, the "not loaded" and "other generation" messages, suggestions for misspelt Kits, methods and fields, a part member whose part is not loaded, `MC:Use` before and after a read, `maxFacades`;
- the addon object: the three hooks at the lifecycle phases, a definition table, a second addon object refused, modules that enable after the addon and are disabled with it, `dependsOn` merged once, a module file loaded before the addon's, the name `Main` refused, `GetAddon` and `GetModule`, ModuleKit not loaded, a ModuleKit refusal at the author's line, method-name callbacks through the scope (pending until the runtime Kits take them);
- the database: plain defaults read through the views, inferred types refusing wrong types, undeclared fields and long strings, `["*"]` wildcards of records and plain values, `{}` bags, lists, inline nodes, `MC.Range` and `MC.Enum` keeping their bounds, a scope written as a node, SettingsKit options, a repeated open, the `ADDON_LOADED` gate, every defaults refusal, all ten SettingsKit scopes accepted, plain defaults without SchemaKit, SettingsKit, its Defaults part or SchemaKit not loaded;
- composition: the panel and its slash command, a title, no slash command, a taken slash name raised with nothing left behind, the command unregistered when the tree is refused, the launcher kept in the profile and refreshed on a profile switch, an undeclared launcher field, per-addon `LAUNCHER_DEFAULTS`, every argument check;
- arguments and secrets: every argument error at the caller's line, through `__index`, `__newindex`, the namespace entry and each method, secret receivers, arguments, keys and limits, AddonKit's position removed from a message raised again, a non-string error object passed through;
- Registry publication, a duplicate embedded load, yielding to a newer revision, an in-place upgrade that keeps facades, cached Kits, pins, limits, the entry and the parts, part revisions (equal kept, newer installed, older ignored), a foreign `MoltenCodes.For` left alone and reported once, a missing or incomplete Registry, corrupted state, a part loaded before the core;
- the shared helper blocks: a raising host error handler while the foreign entry is reported, the probe kept from load, the facade message, and the in-place upgrade over the committed revision 2 file (`fixtures/AddonKit-revision2.lua`);
- the repository conformance suite (`tests/support/KitConformance.lua`): manifest, receivers, arguments and upgrade; its limits group is pending, with the reason in the spec;
- the manifest: API, revision, each part's revision against its `PART_REVISION`, the dependencies; the catalogue against every package manifest and the published generations;
- the ten tasks of the usability comparison, run as an addon folder (`fixtures/TenTasks`);
- the getting-started guide: each step's addon folder (`fixtures/FirstAddon/step1` to `step4`) loaded and logged in, and every guide block marked with a fixture equal to it (pending until `docs/GETTING_STARTED.md` is in the repository);
- lua-language-server: the fixtures check clean, and misspelt calls through the facade, a Kit and a database are flagged (pending without lua-language-server).

`support/AddonKitTestEnv.lua` provides the module chains (`CHAINS`, `LoadKits`, `LoadParts`, `NewFullPackage`), `LogIn`, stand-ins for `Settings`, `Minimap` and `SlashCmdList` with `RunSlash`, `InstallClient` and `LoadAddonFolder` for addon folders, the secret probe, `LoadRevision` and `LoadPartRevision`, and `ExpectRaisedInside`, which checks that an error names the first line of the closure that raised it.

The fixture addons carry a `--# selene:` line because they are linted as test code, where the client's globals are undefined; the guide comparison leaves it out.

| Spec | Covers |
|---|---|
| `Lookup_spec.lua` | the facade, Kit resolution, suggestions, pins, the facade limit |
| `Addon_spec.lua` | the addon object and modules |
| `ModuleDefaults_spec.lua` | revision 2: `MC:SetDefaultModuleState` keeping the addon object on, `enabledState = false` on the addon object, the default and a module's own prototype, `MC:OnModuleCreated` with a receiver, ModuleKit's refusals and an old ModuleKit named at the author's line, and facades of revision 1 gaining the three methods |
| `Database_spec.lua` | the Database part |
| `Composition_spec.lua` | the Composition part |
| `Arguments_spec.lua` | argument errors at the caller's line, secrets, re-raised messages |
| `Bootstrap_spec.lua` | publication, duplicate loads, upgrades, parts, the namespace entry |
| `SharedHelpers_spec.lua` | the shared `isSecret`, `reportError` and `validateFacade` blocks, the upgrade from revision 2 |
| `Conformance_spec.lua` | the conformance suite |
| `Manifest_spec.lua` | manifest agreement and the catalogue |
| `TenTasks_spec.lua` | the ten-task addon |
| `Guide_spec.lua` | the getting-started guide's steps and blocks |
| `LanguageServer_spec.lua` | lua-language-server over the fixtures |
