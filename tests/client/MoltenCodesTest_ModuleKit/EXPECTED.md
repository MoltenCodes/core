# Expected result: `/mct run moduleKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package moduleKit`
and nothing else from the MoltenCodes framework enabled in the client.

Run it out of combat, solo, outside any instance (a capital city is ideal). No
test needs combat, a group or an instance, and nothing is typed or clicked
besides the command. A run finishes within about five seconds: three tests
wait up to two seconds for a 0.4-second control timer, and one for a CVar
event.

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for moduleKit. Type /mct run moduleKit to run them; /mct help lists every command.
```

## After `/mct run moduleKit`

Exactly these lines, in this order (`PASS` is green and `SKIP` yellow in the
client):

```text
MoltenCodes Test: running moduleKit: 8 suites. Results follow when every test has finished.
MoltenCodes Test: PASS moduleKit.facade: Registry:Get('moduleKit', 1) is the ModuleKit facade with API 1, ForAddon, SetLimits, GetLimits and UNBOUNDED
MoltenCodes Test: PASS moduleKit.facade: the installed ModuleKit carries the revision of the committed manifest
MoltenCodes Test: PASS moduleKit.lifecycle: ForAddon with this test addon's name, asked after its loaded and ready phases, returns one container that names the addon and carries every documented method
MoltenCodes Test: PASS moduleKit.lifecycle: a definition-table module created after ready catches up inside CreateModule: OnInitialize, then OnEnable with the injection table, and it returns enabled and wanted
MoltenCodes Test: PASS moduleKit.lifecycle: a mutable module created after ready stays created until Activate, which runs OnInitialize then OnEnable at once
MoltenCodes Test: SKIP moduleKit.lifecycle: at logout the container disables every enabled module in reverse graph order and closes its scopes -- not observable in a run: PLAYER_LOGOUT ends the session before a result could be printed or saved; packages/moduleKit/tests/Lifecycle_spec.lua proves it
MoltenCodes Test: SKIP moduleKit.lifecycle: a halt of this addon or of a required addon takes the affected modules down and keeps them blocked -- not exercised: a halt is terminal for the session (LifecycleKit has no resume), so the addon would stay halted until /reload; packages/moduleKit/tests/Halted_spec.lua proves it
MoltenCodes Test: PASS moduleKit.ordering: EnableAll initializes and enables Before, DependsOn and After modules in graph order, not creation order, and DisableAll disables them in reverse
MoltenCodes Test: PASS moduleKit.ordering: under the automatic policy Enable brings up the DependsOn chain first, Disable of its base takes the dependents down first and keeps them wanted, and enabling the base again recovers them
MoltenCodes Test: PASS moduleKit.ordering: under the strict policy Enable of a module whose dependency is off is refused at the calling line, and enabling the dependency recovers it
MoltenCodes Test: PASS moduleKit.scopes: scope.Timers is created on its first read in OnEnable, and a 0.2-second C_Timer timer started there never fires once Disable closed it; the next enable gets a fresh scope
MoltenCodes Test: PASS moduleKit.scopes: a failed OnEnable raises its own error to Activate's caller, closes the timer scope it opened before failing, and that timer never fires
MoltenCodes Test: PASS moduleKit.scopes: scope.Events delivers the CVAR_UPDATE of a chatBubbles change while enabled; after Disable its frame is gone from GetFramesRegisteredForEvent and a second change reaches nothing
MoltenCodes Test: PASS moduleKit.scopes: scope.Hooks pre-hooks a method of a table this test owns while enabled, and Disable writes the original method back
MoltenCodes Test: PASS moduleKit.scopes: scope.Commands is an empty CommandKit scope while enabled and Disable closes it; no slash command is registered
MoltenCodes Test: SKIP moduleKit.scopes: a slash command registered through scope.Commands goes inert when the module is disabled -- not exercised: the client keeps a registered command's SLASH_ globals and SlashCmdList entry for the session, so it would stay visible; packages/moduleKit/tests/Scope_spec.lua proves it
MoltenCodes Test: PASS moduleKit.scopes: scope.Jobs, scope.Messages and scope.Comm are scopes of SchedulerKit, this addon's SignalKit bus and CommKit; Disable closes all three, and a 0.2-second job never runs
MoltenCodes Test: PASS moduleKit.injection: ProvideSingleton with a list implements runs its factory once and injects the same checked instance into two modules created after ready
MoltenCodes Test: PASS moduleKit.injection: ProvideModule with a list implements runs its factory once per requesting module and hands it that module
MoltenCodes Test: PASS moduleKit.injection: a lazy provider whose value lacks a listed method is refused at the Resolve line, is not cached, and runs its factory again on the next Resolve
MoltenCodes Test: PASS moduleKit.injection: ProvideValue with a list implements refuses a member that is not a function at the ProvideValue line, and the name stays free
MoltenCodes Test: PASS moduleKit.injection: a definition-table module whose implements names a hook it does not set is refused at the CreateModule line and is not created
MoltenCodes Test: PASS moduleKit.injection: ProvideValue with a SchemaKit implements schema accepts a matching value and refuses a mismatch at the ProvideValue line, naming the path
MoltenCodes Test: PASS moduleKit.injection: ProvideSingleton with a SchemaKit implements schema checks the factory's result when it first arrives and refuses it at the Resolve line
MoltenCodes Test: PASS moduleKit.errors: CreateModule with a name that is not a string is refused at the calling line
MoltenCodes Test: PASS moduleKit.errors: CreateModule with a misspelled definition field is refused at the calling line and creates nothing
MoltenCodes Test: PASS moduleKit.errors: SetDependencyPolicy with an unknown policy is refused at the calling line and keeps the policy
MoltenCodes Test: PASS moduleKit.errors: reading scope.Timers of a disabled module is refused at the reading line
MoltenCodes Test: PASS moduleKit.errors: Enable of a module two DependsOn steps from a missing module is refused at the Enable line, naming the missing one
MoltenCodes Test: PASS moduleKit.errors: Before an already-initialized module is refused at the calling line
MoltenCodes Test: PASS moduleKit.errors: SetLimits with a limit ModuleKit does not know is refused at the calling line and changes nothing
MoltenCodes Test: PASS moduleKit.secrets: ForAddon with a secret addon name is refused at the calling line
MoltenCodes Test: PASS moduleKit.secrets: CreateModule with a secret name is refused at the calling line and creates nothing
MoltenCodes Test: PASS moduleKit.secrets: DependsOn with a secret module name is refused at the calling line
MoltenCodes Test: PASS moduleKit.secrets: ProvideValue with a secret implements entry is refused at the calling line and leaves the name free
MoltenCodes Test: PASS moduleKit.secrets: ProvideValue accepts a secret value, which is never compared, and Resolve and injection hand back that secret
MoltenCodes Test: PASS moduleKit.secrets: SetLimits with a secret maxRequiredAddons is refused at the calling line and changes nothing
MoltenCodes Test: PASS moduleKit.secrets: SetDependencyPolicy with a secret policy is refused at the calling line and keeps the policy
MoltenCodes Test: PASS moduleKit.allocation: GetModule, HasModule, GetState, IsEnabled and the Resolve of a cached singleton and module-scoped value allocate nothing over 10000 rounds (allocation guard)
MoltenCodes Test: moduleKit: 36 passed, 0 failed, 3 skipped, 0 timed out (39 tests)
```

The three `SKIP` lines are expected on every run:

- **Logout.** What the container does at `shutdown` (every enabled module
  disabled in reverse graph order, its scopes closed) happens at
  `PLAYER_LOGOUT`, after which the client runs no more addon code that could
  print or save a result. Do not log out to test it.
- **Halt.** LifecycleKit API 1 has no resume: halting this addon, or an addon a
  module names in `requiresAddons`, would leave it halted, with its modules
  blocked, until `/reload`. `Halt` reads nothing from the client, so the
  Busted specs are the right place for it.
- **A registered slash command.** Registering one through `scope.Commands`
  writes `SLASH_<key><n>` globals and a `SlashCmdList` entry that the client
  keeps for the session; closing the scope only makes the command inert. The
  test next to it proves the `Commands` scope is created and closed without
  registering anything.

Running it again in the same session prints the same lines: every test names
its modules and providers with a prefix no earlier test used.

### On a client without secret values

The seven `moduleKit.secrets` tests need the client's `issecretvalue` and
`secretwrap`, which Retail 12.1 has. A client without them prints each of the
seven with `SKIP` and ` -- the client has no issecretvalue and secretwrap; the
secret path was not exercised`, and the totals line reads
`29 passed, 0 failed, 10 skipped, 0 timed out (39 tests)`.

## Visible side effects

- The `chatBubbles` CVar (Interface options, chat bubbles) is flipped twice
  by the `scope.Events` test and put back at once; a bubble said during that
  moment may not show.
- Nothing is printed to chat besides the harness lines. The deliberate
  failures (the `OnEnable` that raises `mctModuleKit deliberate OnEnable
  failure`, and every argument and secret refusal) are caught with `pcall`
  inside the test, so no error window opens.

## What a run leaves behind

ModuleKit API 1 keeps every container, module and provider for the session
and offers no way to remove one. What stays until `/reload`:

- the container of `MoltenCodesTest_ModuleKit`, created by the first run,
  with its dependency policy back at `automatic`;
- about thirty modules per run, all disabled at the end of their test, named
  `mct<serial>_<Name>` (the serial counts up across runs), and the providers
  the injection tests register under the same kind of names. Every hook a test
  gives a module does nothing once its test has ended, so a later run's
  `EnableAll` enables and disables them again without running any test's
  work; the container disables whatever is still enabled at logout;
- one secret value, held by a `ProvideValue` provider of the secrets test;
- this addon's SignalKit bus, created when `scope.Messages` is first read and
  closed by LifecycleKit at logout, and one `PLAYER_ENTERING_WORLD` listener
  CommKit connects the first time any CommKit scope is created.

Every Kit scope a module opens (timers, events, hooks, commands, jobs,
messages, comm) is closed by the module's disable, and the tests check it; the
control timers are closed by the After hook. `ModuleKit:SetLimits` is only ever
called with values it refuses, so the package-wide limits never change. No
slash command is registered, and nothing is written to a global or a saved
variable.

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('moduleKit', 1) is the ModuleKit facade ...` | The facade the client loaded is API 1 and carries `ForAddon`, `SetLimits`, `GetLimits` and the `UNBOUNDED` sentinel. |
| `the installed ModuleKit carries the revision ...` | Registry's selected revision and the facade's `REVISION` are both the committed manifest's, not an older or newer embedded copy. |
| `ForAddon with this test addon's name, asked after ...` | LifecycleKit reports this addon `loaded` and `ready`, not shut down; `ForAddon` returns one container for the session, named after the addon, with the `automatic` policy and every documented container and module method. The log says whether this run created the container. |
| `a definition-table module created after ready catches up ...` | The container replays the real `loaded` and `ready` phases: `OnInitialize` and then `OnEnable` (with an empty injection table) run before `CreateModule` returns, and the module is `enabled`, wanted and without error. |
| `a mutable module created after ready stays created ...` | A module created without a definition stays `created` and runs no hook until `Activate`, which runs both at once; `Disable` makes it `disabled` and unwanted. |
| `EnableAll initializes and enables Before, DependsOn and After ...` | Four modules created in the order Interface, Data, Core, Early with `Interface:After(Data)`, `Data:DependsOn(Core)` and `Early:Before(Core)` come out of `GetActivationOrder`, `OnInitialize` and `OnEnable` as Early, Core, Data, Interface, and `DisableAll` runs their `OnDisable` in reverse. |
| `under the automatic policy Enable brings up the DependsOn chain first ...` | `Top:Enable()` enables Base, Middle, Top in that order; `Base:Disable()` disables Top, Middle, Base; Middle and Top stay wanted, blocked by Base and by Middle; `Base:Enable()` brings all three back in order. |
| `under the strict policy Enable of a module whose dependency is off ...` | The refusal names `ModuleKitSuite.lua` at the `Enable` line and records the dependency in `GetBlockedBy`; enabling the dependency enables the waiting module too; `Disable` of the dependency while the dependent is enabled is refused at its line. The policy is put back. |
| `scope.Timers is created on its first read in OnEnable ...` | `scope.Timers` does not exist before its first read, is the same TimerKit scope on the next read, and is the only field created; a 0.2-second timer on the client's `C_Timer` is `cancelled` by `Disable` and has not fired when a 0.4-second control timer has; the next `Enable` gets a new, open scope. |
| `a failed OnEnable raises its own error ...` | The hook's error reaches `Activate`'s caller naming `ModuleKitSuite.lua` at the raising line; the module stays `initialized` with `HasLastError()`; the timer scope the hook opened is closed and its timer never fires. |
| `scope.Events delivers the CVAR_UPDATE ...` | The module's EventKit scope adds exactly one frame to `GetFramesRegisteredForEvent("CVAR_UPDATE")` and receives the event of a `C_CVar.SetCVar("chatBubbles")` change; after `Disable` the scope is closed, the frame is no longer listed, `IsEventRegistered` answers `false`, and a second change reaches nothing within half a second. The log says whether the event arrived before `SetCVar` returned. |
| `scope.Hooks pre-hooks a method of a table this test owns ...` | While enabled, calling the method runs the hook and then the original with the result intact; after `Disable` the scope is closed, the table holds the original function again, and a call runs only the original. |
| `scope.Commands is an empty CommandKit scope ...` | The field is an open CommandKit scope with nothing registered; `Disable` closes it and removes the field. |
| `scope.Jobs, scope.Messages and scope.Comm ...` | The three fields are open scopes of SchedulerKit, this addon's SignalKit bus and CommKit; `Disable` closes all three, and a 0.2-second SchedulerKit job is cancelled and never runs. |
| `ProvideSingleton with a list implements runs its factory once ...` | Two modules created after ready receive the same checked instance in `OnInitialize`, which `Resolve` and `GetInjections` also return; the factory ran once. |
| `ProvideModule with a list implements runs its factory once per requesting module ...` | Each module gets its own value, built for it, and `module:Resolve` and `addon:Resolve(name, module)` return that cached value. |
| `a lazy provider whose value lacks a listed method ...` | `ModuleKit provider "<name>" must implement "Load": no such member` names `ModuleKitSuite.lua` at the `Resolve` line, twice, and the factory ran twice, so nothing was cached. |
| `ProvideValue with a list implements refuses a member ...` | The refusal (`member "Save" is a string, not a function`) names the `ProvideValue` line, and the same name is then free for a conforming value. |
| `a definition-table module whose implements names a hook ...` | `ModuleKit module "<name>" must implement "OnDisable": no such member` names the `CreateModule` line and the module does not exist. |
| `ProvideValue with a SchemaKit implements schema ...` | With the bundle's SchemaKit, an open table schema accepts a value with `Save` and `scale = 1`, and refuses `scale = "big"` at the `ProvideValue` line with `at scale, expected number, found string`. |
| `ProvideSingleton with a SchemaKit implements schema ...` | A sealed schema accepts the factory's result once and caches it; a factory result without `Save` is refused at the `Resolve` line with `at Save, expected function, found nil`. |
| `errors` tests | Each documented refusal names `ModuleKitSuite.lua` at the calling line with the documented message: a name that is not a string, a misspelled definition field (nothing created), an unknown policy (policy kept), reading `scope.Timers` of a disabled module (at the reading line), a missing module two `DependsOn` steps away (at the `Enable` line, however deep), `Before` an initialized module, and `SetLimits` with an unknown limit (`ModuleKit:SetLimits limits.maxModules is not a recognised limit`, limits unchanged). |
| `secrets` tests | A genuine secret from `secretwrap` as the `ForAddon` name, the `CreateModule` name, the `DependsOn` name, an `implements` entry or the `maxRequiredAddons` limit is refused at the calling line before ModuleKit compares it, and changes nothing; a secret *value* is accepted by `ProvideValue` and handed back by `Resolve` and through injection still secret. |
| `SetDependencyPolicy with a secret policy ...` | `ModuleKit.Addon:SetDependencyPolicy policy must not be a secret value` names `ModuleKitSuite.lua` at the calling line, as docs/API.md lists it, and the policy stays `automatic`. Before ModuleKit 0.8.3 the client raised `attempt to compare local 'policy' (a secret string value ...)` inside `ModuleKit.lua` instead. |
| `GetModule, HasModule, GetState, IsEnabled and the Resolve ...` | Over 10000 rounds of those six calls, the Lua heap grows by at most 1 KB, as docs/API.md's "Cost" promises for name lookups and cached resolutions. The log holds the delta. |

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, any `SKIP` other than the three listed, or a
  totals line other than `36 passed, 0 failed, 3 skipped, 0 timed out (39 tests)`.
- No login line, or `Expected.lua is missing`: the harness or the installer did
  not run as intended.
- A Lua error window or a BugSack entry naming `MoltenCodes`,
  `MoltenCodesTest` or `MoltenCodesTest_ModuleKit`.
- A scope test failing at its last line (`expected number 1 to be number 0`
  or similar): a timer or job the disable should have cancelled fired, or an
  event reached a disabled module. The logs hold the counts.
- The `scope.Events` test failing at the frame count: another addon's
  EventKit copy already listened for CVAR_UPDATE, or the client lists frames
  differently. The log holds the count.
- The `ordering` `EnableAll` test failing on a second run in the same session:
  a module an earlier run left behind raised from a hook, which the journal
  design should prevent.
- `chatBubbles` not back to what it was after the run.
- `the installed ModuleKit carries the revision ...` failing: another enabled
  addon embeds a different ModuleKit copy.

## What to send back

1. The chat lines above as they appeared (a screenshot, or a copy of the chat
   log), including any line that differs.
2. After `/reload` or a logout, the file
   `/Applications/World of Warcraft/_retail_/WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`.
   It holds the full report, each test's logs (the client's messages with their
   paths, the CVAR_UPDATE facts, the frame count, the allocation delta) and the client
   facts. Lua shortens
   a long file path from the left, so a logged message may start with `...`;
   the tests compare only the `ModuleKitSuite.lua:<line>` part.
3. The text of any Lua error, with `/console scriptErrors 1` turned on.
4. The list of other enabled addons, when a test failed.
