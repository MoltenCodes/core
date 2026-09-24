-- MoltenCodes Test: ModuleKitSuite.lua
--
-- Real-client suites for the `moduleKit` package. The Busted specs under
-- packages/moduleKit/tests/ prove ModuleKit against a fake client whose
-- lifecycle phases a spec drives by hand and whose Kits are stubs or run on a
-- fake frame loop; these prove, inside the game client with the installed
-- MoltenCodes addon, what that fixture can only simulate:
--
--   * the installed facade and its committed revision;
--   * the container of this very addon, first asked for after the client has
--     loaded the addon and logged in: it catches up to LifecycleKit's real
--     `loaded` and `ready` phases, so a definition-table module is enabled
--     inside `CreateModule` and a mutable one by `Activate`;
--   * enable and disable order under `DependsOn`, `Before` and `After`, the
--     `automatic` cascade and recovery, and the `strict` refusal;
--   * `module.scope` over the real Kits of the bundle: a TimerKit timer on the
--     client's `C_Timer` that never fires once the module is disabled, an
--     EventKit listener for the CVAR_UPDATE that `C_CVar.SetCVar("chatBubbles")`
--     raises, whose frame registration `GetFramesRegisteredForEvent` shows
--     gone after the disable, a HookKit pre-hook on a table this file owns
--     that the disable takes off again, and the CommandKit, SchedulerKit,
--     SignalKit and CommKit scopes, each closed by the disable;
--   * dependency injection with `implements`, in the list form and in the
--     SchemaKit schema form;
--   * argument errors, and the refusal of genuine secret values made by the
--     client's `secretwrap`, pointing at this file as the client names it;
--   * that name lookups and cached resolutions allocate nothing.
--
-- Nothing here needs combat, a group or an instance. Every wait is at most two
-- seconds.
--
-- Run with `/mct run moduleKit`; tests/client/MoltenCodesTest_ModuleKit/EXPECTED.md
-- lists what the chat frame should show and the visible side effects.
--
-- What a run leaves behind. ModuleKit API 1 keeps every container, module and
-- provider for the session and has no way to remove one, so every test names
-- its modules and providers with a prefix of its own (`mct<serial>_`), and the
-- modules and providers a run creates stay in this addon's container, disabled,
-- until `/reload`; the container disables whatever is still enabled at logout.
-- Every module a test creates is disabled by the After hook of its suite,
-- whatever the test's outcome, and every hook a test gives a module does
-- nothing once its test has ended, so a later `EnableAll` that enables the
-- whole container again (the ordering test calls one) runs no test's work a
-- second time. The After hook also puts back the container's dependency
-- policy and `chatBubbles`. The deliberate hook failure is caught by
-- ModuleKit's own `pcall` and re-raised to the test, so the client's error
-- handler is never involved. Reading a scope field
-- leaves what the Kit keeps for the session: one PLAYER_ENTERING_WORLD
-- listener CommKit connects the first time any CommKit scope is created, and
-- this addon's SignalKit bus, which LifecycleKit closes at logout. Nothing is
-- written to a global or a saved variable, and no slash command is registered.

local addonName = ...

-- The harness is this addon's dependency and publishes one documented global.
-- selene: allow(global_usage)
local Harness = rawget(_G, "MoltenCodesTest")
-- The shared MoltenCodes namespace is the one documented global handoff point.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
if type(Harness) ~= "table" or type(namespace) ~= "table" then
  error(addonName .. " requires the MoltenCodesTest harness and the MoltenCodes addon", 0)
end

local REGISTRY_API = 2
local MODULE_KIT_API = 1
local LIFECYCLE_KIT_API = 1
local TIMER_KIT_API = 1
local SCHEMA_KIT_API = 1
local PACKAGE_ID = "moduleKit"

--- The CVar the events test changes to make the client raise CVAR_UPDATE. It
--- is cosmetic (whether chat bubbles are drawn), always present on Retail, not
--- read-only and not secure, so `C_CVar.SetCVar` accepts it from addon code;
--- every change is put back by the After hook.
local PROBE_CVAR = "chatBubbles"

--- The event the client raises when a CVar changes: `(cvarName, value)`.
local CVAR_EVENT = "CVAR_UPDATE"

--- Seconds a test waits for an event the client raises locally.
local LOCAL_EVENT_TIMEOUT_SECONDS = 2

--- Seconds after a CVar change during which a delivery to a disabled module
--- would be wrong. CVAR_UPDATE arrives inside `SetCVar`; the wait only makes
--- sure a late delivery would have been seen.
local QUIET_SECONDS = 0.5

--- Delay of the timer or job a module starts in its scope. Short, so that a
--- timer the disable failed to cancel fires well inside the test.
local SCOPED_DELAY_SECONDS = 0.2

--- Delay of the control timer, which proves the client's timers ran: when it
--- has fired, a scoped timer that was still running would have fired too.
local CONTROL_DELAY_SECONDS = 0.4

--- How long a test waits for its control timer.
local CONTROL_TIMEOUT_SECONDS = 2

--- How many times the allocation guard repeats each lookup. One table or
--- closure per call would cost hundreds of kilobytes at this count.
local LOOKUP_CALLS = 10000

--- Kilobytes the allocation guard tolerates. The tolerance absorbs a stray
--- allocation by the client between the two readings, not a per-call one.
local ALLOCATION_TOLERANCE_KB = 1

--- Text a deliberately failing module hook raises, so a test can recognise it.
local HOOK_FAILURE = "mctModuleKit deliberate OnEnable failure"

--- Every member docs/API.md of moduleKit lists on the facade, besides `API`
--- and `REVISION`.
local FACADE_METHODS = { "ForAddon", "SetLimits", "GetLimits" }

--- Every method docs/API.md lists on an addon container.
local CONTAINER_METHODS = {
  "GetAddonName",
  "GetDependencyPolicy",
  "SetDependencyPolicy",
  "CreateModule",
  "GetModule",
  "HasModule",
  "GetModules",
  "GetActivationOrder",
  "ValidateGraph",
  "InitializeAll",
  "EnableAll",
  "DisableAll",
  "ProvideValue",
  "ProvideSingleton",
  "ProvideModule",
  "ProvideTransient",
  "Resolve",
}

--- Every method docs/API.md lists on a module.
local MODULE_METHODS = {
  "GetName",
  "GetAddon",
  "GetState",
  "IsInitialized",
  "IsEnabled",
  "GetLastError",
  "HasLastError",
  "GetBlockedBy",
  "GetEnableState",
  "GetInjections",
  "DependsOn",
  "OptionalDependency",
  "Before",
  "After",
  "Inject",
  "Initialize",
  "Enable",
  "Disable",
  "Activate",
  "Resolve",
}

--- The seven `module.scope` fields, alphabetically, as ModuleKit closes them.
local SCOPE_FIELDS = { "Comm", "Commands", "Events", "Hooks", "Jobs", "Messages", "Timers" }

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- CVars, frame registrations, error handling and secret-value functions
  -- are World of Warcraft client globals, reachable only through the global
  -- table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Read a function from a client namespace table such as `C_CVar`, or `nil`.
---@param namespaceName string
---@param functionName string
---@return function|nil
local function readHostFunction(namespaceName, functionName)
  local hostNamespace = readHost(namespaceName)
  if type(hostNamespace) ~= "table" then
    return nil
  end
  local candidate = hostNamespace[functionName]
  if type(candidate) ~= "function" then
    return nil
  end
  return candidate
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, REGISTRY_API)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- ModuleKit, HookKit, CommandKit, CommKit and SchemaKit are not in the
-- language-server workspace of tests/client (its .luarc.json lists TestKit's
-- dependency closure only), so their facades are typed `any` here.

---@type any
local ModuleKit = Registry:Get(PACKAGE_ID, MODULE_KIT_API)
---@type LifecycleKit|nil
local LifecycleKitOrNil = Registry:Get("lifecycleKit", LIFECYCLE_KIT_API)
---@type TimerKit|nil
local TimerKitOrNil = Registry:Get("timerKit", TIMER_KIT_API)
if type(ModuleKit) == "nil" or type(LifecycleKitOrNil) == "nil" or type(TimerKitOrNil) == "nil" then
  error(
    addonName
      .. " requires ModuleKit API 1, LifecycleKit API 1 and TimerKit API 1 in the MoltenCodes addon; reinstall it",
    0
  )
end
---@cast LifecycleKitOrNil LifecycleKit
---@cast TimerKitOrNil TimerKit
local LifecycleKit = LifecycleKitOrNil
local TimerKit = TimerKitOrNil

--- Read once at load: the schema tests are registered as skipped without it.
---@type any
local SchemaKit = Registry:Get("schemaKit", SCHEMA_KIT_API)
local SCHEMA_KIT_LOADED = type(SchemaKit) ~= "nil"

--- Read once at load: the events test is registered as skipped when the
--- client does not list the frames registered for an event.
local getFramesRegisteredForEvent = readHost("GetFramesRegisteredForEvent")
local REGISTRATIONS_READABLE = type(getFramesRegisteredForEvent) == "function"

--- Read once at load: the secrets suite registers its tests as skipped when
--- the client cannot make a secret value.
local isSecretValue = readHost("issecretvalue")
local secretWrap = readHost("secretwrap")
local SECRETS_AVAILABLE = type(isSecretValue) == "function" and type(secretWrap) == "function"

-- Helpers ---------------------------------------------------------------------------

--- Release actions of the test that is running (disable a module, close a
--- scope, repair the container's graph), run first by the After hook.
---@type (fun())[]
local pendingReleases = {}

--- Restore actions of the test that is running (the probe CVar), run by the
--- After hook after every release, so no listener of the test sees the event
--- a restore raises.
---@type (fun())[]
local pendingRestores = {}

--- The dependency policy to put back before anything else is released, or
--- `nil` when the running test did not change it. Kept apart from the release
--- list because a module's release depends on it: under `strict` a dependency
--- cannot be disabled while a dependent is enabled.
---@type string|nil
local policyToRestore = nil

---The container of this test addon. `ForAddon` is idempotent, so every test
---asks for it and receives the same one.
---@return any
local function ownContainer()
  return ModuleKit:ForAddon(addonName)
end

---Run and empty one action list, newest first. Every action runs even when an
---earlier one raised; the first error is raised again afterwards.
---@param actions (fun())[]
local function runActions(actions)
  local firstProblem = nil
  for index = #actions, 1, -1 do
    local action = actions[index]
    actions[index] = nil
    local succeeded, problem = pcall(action)
    if not succeeded and type(firstProblem) == "nil" then
      firstProblem = problem
    end
  end
  if type(firstProblem) ~= "nil" then
    error(firstProblem, 0)
  end
end

---Put the policy back, release everything the test created, then restore
---what it changed. Registered as the After hook of every suite.
local function cleanUp()
  local policyProblem = nil
  if policyToRestore ~= nil then
    local previous = policyToRestore
    policyToRestore = nil
    local succeeded, problem = pcall(function()
      ownContainer():SetDependencyPolicy(previous)
    end)
    if not succeeded then
      policyProblem = problem
    end
  end
  local releasedCleanly, releaseProblem = pcall(runActions, pendingReleases)
  runActions(pendingRestores)
  if type(policyProblem) ~= "nil" then
    error(policyProblem, 0)
  end
  if not releasedCleanly then
    error(releaseProblem, 0)
  end
end

---Register a suite of this package whose tests all end released and restored.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName)
  suite:After(cleanUp)
  return suite
end

--- Serial of the last name prefix handed out; see `newNamePrefix`.
local namePrefixSerial = 0

---A module and provider name prefix no earlier test of the session used.
---
---ModuleKit keeps every module and provider for the session and refuses a
---name twice, so each test names its own with a fresh prefix. The trailing
---underscore keeps `mct1_` from being a prefix of `mct12_`.
---@return string
local function newNamePrefix()
  namePrefixSerial = namePrefixSerial + 1
  return ("mct%d_"):format(namePrefixSerial)
end

---Whether `name` starts with `prefix`.
---@param name string
---@param prefix string
---@return boolean
local function hasPrefix(name, prefix)
  return name:sub(1, #prefix) == prefix
end

---A journal the hooks of the running test's modules write to. It stops
---accepting entries when the test ends, and every hook built by
---`journalHooks` does nothing more than write to it once it has, so a later
---whole-container operation that enables or disables the module again does no
---test's work a second time.
---@return { live: boolean, entries: string[] }
local function newJournal()
  local journal = { live = true, entries = {} }
  pendingReleases[#pendingReleases + 1] = function()
    journal.live = false
  end
  return journal
end

---Append `entry` to `journal` while its test runs.
---@param journal { live: boolean, entries: string[] }
---@param entry string
local function note(journal, entry)
  if journal.live then
    journal.entries[#journal.entries + 1] = entry
  end
end

---The three lifecycle hooks of a module, each noting `<label>:<phase>` in
---`journal`. `onEnableWork(module)` runs after the enable is noted, and only
---while the test runs.
---@param journal { live: boolean, entries: string[] }
---@param label string
---@param onEnableWork (fun(module: any))|nil
---@return table hooks `{ onInitialize, onEnable, onDisable }`, the definition-table spelling
local function journalHooks(journal, label, onEnableWork)
  return {
    onInitialize = function()
      note(journal, label .. ":initialize")
    end,
    onEnable = function(module)
      note(journal, label .. ":enable")
      if journal.live and type(onEnableWork) ~= "nil" then
        onEnableWork(module)
      end
    end,
    onDisable = function()
      note(journal, label .. ":disable")
    end,
  }
end

---A definition table with the journal hooks of `journalHooks` and every
---field of `extra` (`dependsOn`, `inject`, `implements`, ...).
---@param journal { live: boolean, entries: string[] }
---@param label string
---@param extra table|nil
---@param onEnableWork (fun(module: any))|nil
---@return table definition
local function journalDefinition(journal, label, extra, onEnableWork)
  local definition = journalHooks(journal, label, onEnableWork)
  for key, value in pairs(extra or {}) do
    definition[key] = value
  end
  return definition
end

---Give a mutable module the journal hooks, in the documented mutable style.
---@param module any
---@param journal { live: boolean, entries: string[] }
---@param label string
local function attachJournal(module, journal, label)
  local hooks = journalHooks(journal, label)
  module.OnInitialize = hooks.onInitialize
  module.OnEnable = hooks.onEnable
  module.OnDisable = hooks.onDisable
end

---The entries of `journal` that end with `:<phase>`, without the phase.
---@param journal { live: boolean, entries: string[] }
---@param phase string
---@return string[]
local function journalLabels(journal, phase)
  local suffix = ":" .. phase
  local labels = {}
  for _, entry in ipairs(journal.entries) do
    if entry:sub(-#suffix) == suffix then
      labels[#labels + 1] = entry:sub(1, -#suffix - 1)
    end
  end
  return labels
end

---Remember `module` for the After hook, which disables it when it is still
---enabled, and hand it back.
---@param module any
---@return any module
local function trackModule(module)
  pendingReleases[#pendingReleases + 1] = function()
    if module:IsEnabled() then
      module:Disable()
    end
  end
  return module
end

---Remember a Kit scope for the After hook, which closes it.
---@param closable any a scope with `Close`
local function trackClosable(closable)
  pendingReleases[#pendingReleases + 1] = function()
    closable:Close()
  end
end

---Switch this addon's container to `policy` until the test ends.
---@param policy string
local function useDependencyPolicy(policy)
  local previous = ownContainer():SetDependencyPolicy(policy)
  if policyToRestore == nil then
    policyToRestore = previous
  end
end

---`ctx:WaitUntil(predicate, timeoutSeconds)`, returning only whether the
---predicate became truthy in time.
---
---The call goes through an untyped alias because the LuaCATS field TestKit
---declares for `WaitUntil` (`predicate: fun(): any, timeoutSeconds: number`)
---reads to lua-language-server as a predicate returning two values, so a
---direct call is reported as passing one argument too many.
---@param ctx TestKit.Context
---@param predicate fun(): any
---@param timeoutSeconds number
---@return boolean satisfied
local function waitUntil(ctx, predicate, timeoutSeconds)
  ---@type any
  local context = ctx
  local satisfied = context:WaitUntil(predicate, timeoutSeconds)
  return satisfied == true
end

---Whether `value` is a secret value, which cannot be compared.
---@param value any
---@return boolean
local function isSecret(value)
  return type(isSecretValue) == "function" and isSecretValue(value) == true
end

---Describe a client fact for a log line without comparing or indexing it.
---@param value any
---@return string
local function describeFact(value)
  if isSecret(value) then
    return "<secret value>"
  end
  return type(value) .. " " .. tostring(value)
end

---A no-op callback.
local function ignore() end

---Split a `file:line: ` prefix into the file as the client names it and the line.
---@param position string
---@return string|nil file
---@return integer|nil line
local function splitPosition(position)
  local file, line = position:match("^(.-):(%d+): ")
  return file, tonumber(line)
end

---The line of the caller of this function, as the client numbers it.
---
---`error` with level 3, raised under `pcall`, names the caller of this
---function: level 1 is `pcall` itself, 2 is this function, 3 its caller.
---@return integer
local function currentLine()
  local _, position = pcall(error, "", 3)
  local _, line = splitPosition(position or "")
  return line or 0
end

---Check that `message` is a string naming this file, and return its line.
---@param ctx TestKit.Context
---@param message any
---@return integer|nil line
local function expectThisFile(ctx, message)
  ctx:Expect(type(message)):ToBe("string")
  if type(message) ~= "string" then
    return nil
  end
  local file, line = splitPosition(message)
  ctx:Expect(type(file)):ToBe("string")
  ctx:Expect((file or ""):sub(-#"ModuleKitSuite.lua")):ToBe("ModuleKitSuite.lua")
  return line
end

---Call `raise`, which records its line in `at.line` with `currentLine()` and
---raises on the next line, and check the message names this file at that next
---line and ends with `expected`.
---@param ctx TestKit.Context
---@param raise fun(at: { line: integer })
---@param expected string The message after the position, compared literally.
local function expectErrorAtCallingLine(ctx, raise, expected)
  local at = { line = 0 }
  local succeeded, message = pcall(raise, at)
  ctx:Expect(succeeded):ToBe(false)
  ctx:Log("client message: " .. describeFact(message))

  local line = expectThisFile(ctx, message)
  ctx:Expect(tostring(message):sub(-#expected)):ToBe(expected)
  ctx:Expect(line):ToBe(at.line + 1)
end

-- Timers --------------------------------------------------------------------------------

---Start a control timer in a TimerKit scope of the test's own and wait until
---it fired, so a scoped timer with a shorter delay that was still running
---would have fired too. Fails the test when the control never fires.
---@param ctx TestKit.Context
local function waitForControlTimer(ctx)
  local controlScope = TimerKit:CreateScope()
  trackClosable(controlScope)
  local controlFired = false
  controlScope:After(CONTROL_DELAY_SECONDS, function()
    controlFired = true
  end)
  if not waitUntil(ctx, function()
    return controlFired
  end, CONTROL_TIMEOUT_SECONDS) then
    ctx:Fail(
      ("the control timer of %.1f seconds did not fire within %d seconds"):format(
        CONTROL_DELAY_SECONDS,
        CONTROL_TIMEOUT_SECONDS
      )
    )
  end
end

-- The probe CVar ------------------------------------------------------------------------

---The probe CVar's value through `C_CVar.GetCVar`, or `nil` when the client
---has neither the function nor the CVar.
---@return string|nil
local function currentProbeValue()
  local getCVar = readHostFunction("C_CVar", "GetCVar")
  if type(getCVar) == "nil" then
    return nil
  end
  local value = getCVar(PROBE_CVAR)
  if type(value) ~= "string" then
    return nil
  end
  return value
end

---Set the probe CVar through `C_CVar.SetCVar` and return what it answered.
---@param value string
---@return any success
local function writeProbeCVar(value)
  local setCVar = readHostFunction("C_CVar", "SetCVar")
  if type(setCVar) == "nil" then
    error("the client has no C_CVar.SetCVar", 2)
  end
  ---@cast setCVar function
  return setCVar(PROBE_CVAR, value)
end

--- Whether the running test already scheduled the probe CVar's restore.
local probeRestoreScheduled = false

---Flip the probe CVar between "1" and "0". The first flip of a test schedules
---the original value's restore.
---@param ctx TestKit.Context
local function flipProbeCVar(ctx)
  local current = currentProbeValue()
  if type(current) == "nil" then
    ctx:Fail("C_CVar.GetCVar is missing or does not know the CVar " .. PROBE_CVAR)
  end
  ---@cast current string
  if not probeRestoreScheduled then
    probeRestoreScheduled = true
    local original = current
    pendingRestores[#pendingRestores + 1] = function()
      probeRestoreScheduled = false
      if currentProbeValue() ~= original then
        writeProbeCVar(original)
      end
    end
  end
  local written = current == "1" and "0" or "1"
  local accepted = writeProbeCVar(written)
  ctx:Log(
    ("C_CVar.SetCVar(%q, %q) answered %s"):format(PROBE_CVAR, written, describeFact(accepted))
  )
end

---Whether a CVAR_UPDATE payload names the probe CVar, compared without regard
---to case.
---@param cvarName any
---@return boolean
local function namesProbeCVar(cvarName)
  if type(cvarName) ~= "string" or isSecret(cvarName) then
    return false
  end
  return cvarName:lower() == PROBE_CVAR:lower()
end

-- Frame registrations -------------------------------------------------------------------

---The set of frames the client lists as registered for `eventName`.
---@param eventName string
---@return table<any, boolean>
local function registeredFrameSet(eventName)
  local set = {}
  local frames = { getFramesRegisteredForEvent(eventName) }
  for index = 1, #frames do
    set[frames[index]] = true
  end
  return set
end

---The frames registered for `eventName` now that were not in `before`.
---@param eventName string
---@param before table<any, boolean>
---@return any[]
local function framesAddedSince(eventName, before)
  local added = {}
  for frame in pairs(registeredFrameSet(eventName)) do
    if not before[frame] then
      added[#added + 1] = frame
    end
  end
  return added
end

-- Secret values ------------------------------------------------------------------------------

---A genuine secret value made by the client's `secretwrap`, or a failed test.
---
---`secretwrap` is documented in the client's own API documentation
---(FrameScriptDocumentation, packages/apiKit/metadata/retail/namespaces.json)
---with no restriction and no side effect: it converts the values given to it.
---@param ctx TestKit.Context
---@param value any
---@return any secret
local function makeSecret(ctx, value)
  local succeeded, secret = pcall(secretWrap, value)
  if not succeeded then
    ctx:Fail("secretwrap raised, so the secret path was not exercised: " .. describeFact(secret))
  end
  if not isSecret(secret) then
    ctx:Fail("secretwrap returned a value issecretvalue does not report as secret")
  end
  return secret
end

-- moduleKit.facade ------------------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('moduleKit', 1) is the ModuleKit facade with API 1, ForAddon, SetLimits, GetLimits and UNBOUNDED",
  function(ctx)
    ctx:Expect(type(ModuleKit)):ToBe("table")
    ctx:Expect(rawget(ModuleKit, "API")):ToBe(MODULE_KIT_API)
    for _, method in ipairs(FACADE_METHODS) do
      ctx:Expect(type(ModuleKit[method])):ToBe("function")
    end
    ctx:Expect(type(ModuleKit.UNBOUNDED)):ToBe("table")
  end
)

facade:Test("the installed ModuleKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      local _, revision = Registry:Get(PACKAGE_ID, MODULE_KIT_API)
      ctx:Expect(revision):ToBe(expected.revision)
      ctx:Expect(rawget(ModuleKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list moduleKit")
end)

-- moduleKit.lifecycle -----------------------------------------------------------------------

local lifecycle = newSuite("lifecycle")

--- Whether a run of this session asked for the container before; logged only.
local containerAskedBefore = false

lifecycle:Test(
  "ForAddon with this test addon's name, asked after its loaded and ready phases, returns one container that names the addon and carries every documented method",
  function(ctx)
    local instance = LifecycleKit:ForAddon(addonName)
    ctx:Log(
      "first request for the container in this session: " .. tostring(not containerAskedBefore)
    )
    containerAskedBefore = true
    ctx:Expect(instance:IsLoaded()):ToBe(true)
    ctx:Expect(instance:IsReady()):ToBe(true)
    ctx:Expect(instance:IsShutdown()):ToBe(false)

    local container = ownContainer()
    ctx:Expect(ModuleKit:ForAddon(addonName)):ToBe(container)
    ctx:Expect(container:GetAddonName()):ToBe(addonName)
    ctx:Expect(container:GetDependencyPolicy()):ToBe("automatic")
    for _, method in ipairs(CONTAINER_METHODS) do
      ctx:Expect(type(container[method])):ToBe("function")
    end

    local module = trackModule(container:CreateModule(newNamePrefix() .. "Surface"))
    for _, method in ipairs(MODULE_METHODS) do
      ctx:Expect(type(module[method])):ToBe("function")
    end
    ctx:Expect(type(module.scope)):ToBe("table")
    ctx:Expect(module:GetAddon()):ToBe(container)
  end
)

lifecycle:Test(
  "a definition-table module created after ready catches up inside CreateModule: OnInitialize, then OnEnable with the injection table, and it returns enabled and wanted",
  function(ctx)
    local journal = newJournal()
    local injectionTables = {}
    local definition = journalDefinition(journal, "Late", nil, function(module)
      injectionTables[#injectionTables + 1] = module:GetInjections()
    end)
    local module = trackModule(ownContainer():CreateModule(newNamePrefix() .. "Late", definition))

    ctx:Expect(journal.entries):ToEqual({ "Late:initialize", "Late:enable" })
    ctx:Expect(module:GetState()):ToBe("enabled")
    ctx:Expect(module:IsInitialized()):ToBe(true)
    ctx:Expect(module:IsEnabled()):ToBe(true)
    ctx:Expect(module:HasLastError()):ToBe(false)
    ctx:Expect(module:GetEnableState()):ToEqual({ wanted = true, actual = true })
    ctx:Expect(injectionTables):ToEqual({ {} })
  end
)

lifecycle:Test(
  "a mutable module created after ready stays created until Activate, which runs OnInitialize then OnEnable at once",
  function(ctx)
    local journal = newJournal()
    local module = trackModule(ownContainer():CreateModule(newNamePrefix() .. "Mutable"))
    attachJournal(module, journal, "Mutable")

    ctx:Expect(module:GetState()):ToBe("created")
    ctx:Expect(#journal.entries):ToBe(0)

    ctx:Expect(module:Activate()):ToBe(module)
    ctx:Expect(journal.entries):ToEqual({ "Mutable:initialize", "Mutable:enable" })
    ctx:Expect(module:GetState()):ToBe("enabled")

    ctx:Expect(module:Disable()):ToBe(module)
    ctx:Expect(module:GetState()):ToBe("disabled")
    ctx:Expect(module:GetEnableState()):ToEqual({ wanted = false, actual = false })
    ctx:Expect(journal.entries[3]):ToBe("Mutable:disable")
  end
)

lifecycle:Skip(
  "at logout the container disables every enabled module in reverse graph order and closes its scopes",
  "not observable in a run: PLAYER_LOGOUT ends the session before a result could be printed or saved; packages/moduleKit/tests/Lifecycle_spec.lua proves it"
)

lifecycle:Skip(
  "a halt of this addon or of a required addon takes the affected modules down and keeps them blocked",
  "not exercised: a halt is terminal for the session (LifecycleKit has no resume), so the addon would stay halted until /reload; packages/moduleKit/tests/Halted_spec.lua proves it"
)

-- moduleKit.ordering ------------------------------------------------------------------------

local ordering = newSuite("ordering")

ordering:Test(
  "EnableAll initializes and enables Before, DependsOn and After modules in graph order, not creation order, and DisableAll disables them in reverse",
  function(ctx)
    local container = ownContainer()
    local prefix = newNamePrefix()
    local journal = newJournal()

    -- Created in an order opposite to the one the edges demand.
    local interface = trackModule(container:CreateModule(prefix .. "Interface"))
    interface:After(prefix .. "Data")
    local data = trackModule(container:CreateModule(prefix .. "Data"))
    data:DependsOn(prefix .. "Core")
    local core = trackModule(container:CreateModule(prefix .. "Core"))
    local early = trackModule(container:CreateModule(prefix .. "Early"))
    early:Before(prefix .. "Core")
    attachJournal(interface, journal, "Interface")
    attachJournal(data, journal, "Data")
    attachJournal(core, journal, "Core")
    attachJournal(early, journal, "Early")

    local expectedOrder = { "Early", "Core", "Data", "Interface" }
    local ownOrder = {}
    for _, name in ipairs(container:GetActivationOrder()) do
      if hasPrefix(name, prefix) then
        ownOrder[#ownOrder + 1] = name:sub(#prefix + 1)
      end
    end
    ctx:Expect(ownOrder):ToEqual(expectedOrder)

    -- EnableAll enables the whole container, so the modules earlier tests
    -- left behind are enabled too; their hooks do nothing any more, and
    -- the release below disables them again.
    pendingReleases[#pendingReleases + 1] = function()
      container:DisableAll()
    end
    container:EnableAll()
    ctx:Expect(journalLabels(journal, "initialize")):ToEqual(expectedOrder)
    ctx:Expect(journalLabels(journal, "enable")):ToEqual(expectedOrder)
    ctx:Expect(interface:IsEnabled()):ToBe(true)

    container:DisableAll()
    ctx:Expect(journalLabels(journal, "disable")):ToEqual({ "Interface", "Data", "Core", "Early" })
    ctx:Expect(early:GetState()):ToBe("disabled")
  end
)

ordering:Test(
  "under the automatic policy Enable brings up the DependsOn chain first, Disable of its base takes the dependents down first and keeps them wanted, and enabling the base again recovers them",
  function(ctx)
    local container = ownContainer()
    local prefix = newNamePrefix()
    local journal = newJournal()
    local base = trackModule(container:CreateModule(prefix .. "Base"))
    local middle = trackModule(container:CreateModule(prefix .. "Middle"))
    local top = trackModule(container:CreateModule(prefix .. "Top"))
    middle:DependsOn(prefix .. "Base")
    top:DependsOn(prefix .. "Middle")
    attachJournal(base, journal, "Base")
    attachJournal(middle, journal, "Middle")
    attachJournal(top, journal, "Top")

    top:Enable()
    ctx:Expect(journalLabels(journal, "enable")):ToEqual({ "Base", "Middle", "Top" })

    base:Disable()
    ctx:Expect(journalLabels(journal, "disable")):ToEqual({ "Top", "Middle", "Base" })
    -- Each dependent the cascade took down still wants to be enabled and
    -- waits for the dependency whose disable took it down.
    ctx:Expect(middle:GetEnableState()):ToEqual({
      wanted = true,
      actual = false,
      blockedBy = prefix .. "Base",
    })
    ctx:Expect(top:GetEnableState()):ToEqual({
      wanted = true,
      actual = false,
      blockedBy = prefix .. "Middle",
    })
    ctx:Expect(base:GetEnableState()):ToEqual({ wanted = false, actual = false })

    base:Enable()
    ctx:Expect(journalLabels(journal, "enable")):ToEqual({
      "Base",
      "Middle",
      "Top",
      "Base",
      "Middle",
      "Top",
    })
    ctx:Expect(top:GetEnableState()):ToEqual({ wanted = true, actual = true })
  end
)

ordering:Test(
  "under the strict policy Enable of a module whose dependency is off is refused at the calling line, and enabling the dependency recovers it",
  function(ctx)
    local container = ownContainer()
    local prefix = newNamePrefix()
    local journal = newJournal()
    local base = trackModule(container:CreateModule(prefix .. "Base"))
    local dependent = trackModule(container:CreateModule(prefix .. "Dependent"))
    dependent:DependsOn(prefix .. "Base")
    attachJournal(base, journal, "Base")
    attachJournal(dependent, journal, "Dependent")
    useDependencyPolicy("strict")
    ctx:Expect(container:GetDependencyPolicy()):ToBe("strict")

    expectErrorAtCallingLine(
      ctx,
      function(at)
        at.line = currentLine()
        dependent:Enable()
      end,
      'ModuleKit strict policy: module "'
        .. prefix
        .. 'Dependent" requires enabled dependency "'
        .. prefix
        .. 'Base"'
    )
    ctx:Expect(dependent:GetState()):ToBe("created")
    ctx:Expect(dependent:GetBlockedBy()):ToBe(prefix .. "Base")
    ctx:Expect(#journal.entries):ToBe(0)

    base:Enable()
    ctx:Expect(journalLabels(journal, "enable")):ToEqual({ "Base", "Dependent" })
    ctx:Expect(dependent:IsEnabled()):ToBe(true)

    expectErrorAtCallingLine(
      ctx,
      function(at)
        at.line = currentLine()
        base:Disable()
      end,
      'ModuleKit strict policy: cannot disable module "'
        .. prefix
        .. 'Base" while dependent "'
        .. prefix
        .. 'Dependent" is enabled'
    )
    ctx:Expect(base:IsEnabled()):ToBe(true)
  end
)

-- moduleKit.scopes --------------------------------------------------------------------------

local scopes = newSuite("scopes")

scopes:Test(
  "scope.Timers is created on its first read in OnEnable, and a 0.2-second C_Timer timer started there never fires once Disable closed it; the next enable gets a fresh scope",
  function(ctx)
    local journal = newJournal()
    local observations = {}
    local fired = 0
    local definition = journalDefinition(journal, "Timers", nil, function(module)
      local observation = {}
      observation.createdBeforeRead = rawget(module.scope, "Timers") ~= nil
      observation.scope = module.scope.Timers
      observation.sameOnSecondRead = module.scope.Timers == observation.scope
      observation.timer = observation.scope:After(SCOPED_DELAY_SECONDS, function()
        fired = fired + 1
      end)
      observations[#observations + 1] = observation
    end)
    local module = trackModule(ownContainer():CreateModule(newNamePrefix() .. "Timers", definition))

    ctx:Expect(#observations):ToBe(1)
    local first = observations[1]
    ctx:Expect(first.createdBeforeRead):ToBe(false)
    ctx:Expect(first.sameOnSecondRead):ToBe(true)
    ctx:Expect(rawget(module.scope, "Timers")):ToBe(first.scope)
    ctx:Expect(first.scope:GetActiveCount()):ToBe(1)
    ctx:Expect(first.timer:IsPending()):ToBe(true)
    for _, field in ipairs(SCOPE_FIELDS) do
      if field ~= "Timers" then
        ctx:Expect(rawget(module.scope, field)):ToBeNil()
      end
    end

    module:Disable()
    ctx:Expect(first.scope:IsClosed()):ToBe(true)
    ctx:Expect(first.timer:GetState()):ToBe("cancelled")
    ctx:Expect(rawget(module.scope, "Timers")):ToBeNil()

    module:Enable()
    ctx:Expect(#observations):ToBe(2)
    local second = observations[2]
    ctx:Expect(second.scope == first.scope):ToBe(false)
    ctx:Expect(second.scope:IsClosed()):ToBe(false)
    module:Disable()
    ctx:Expect(second.scope:IsClosed()):ToBe(true)

    waitForControlTimer(ctx)
    ctx:Log(("scoped timer callbacks after the control fired: %d"):format(fired))
    ctx:Expect(fired):ToBe(0)
  end
)

scopes:Test(
  "a failed OnEnable raises its own error to Activate's caller, closes the timer scope it opened before failing, and that timer never fires",
  function(ctx)
    local journal = newJournal()
    local opened = {}
    local failingLine = 0
    local fired = 0
    local module = trackModule(ownContainer():CreateModule(newNamePrefix() .. "Failing"))
    module.OnEnable = function(self)
      if not journal.live then
        return
      end
      local timers = self.scope.Timers
      opened.scope = timers
      opened.timer = timers:After(SCOPED_DELAY_SECONDS, function()
        fired = fired + 1
      end)
      failingLine = currentLine()
      error(HOOK_FAILURE)
    end

    local activated, message = pcall(module.Activate, module)
    ctx:Expect(activated):ToBe(false)
    ctx:Log("client message: " .. describeFact(message))
    local line = expectThisFile(ctx, message)
    ctx:Expect(line):ToBe(failingLine + 1)
    ctx:Expect(tostring(message):sub(-#HOOK_FAILURE)):ToBe(HOOK_FAILURE)

    ctx:Expect(module:GetState()):ToBe("initialized")
    ctx:Expect(module:HasLastError()):ToBe(true)
    ctx:Expect(opened.scope:IsClosed()):ToBe(true)
    ctx:Expect(opened.timer:GetState()):ToBe("cancelled")

    waitForControlTimer(ctx)
    ctx:Expect(fired):ToBe(0)
  end
)

--- Why the events test is skipped on a client without the function.
local REGISTRATIONS_SKIP_REASON =
  "the client has no GetFramesRegisteredForEvent; the host registration was not read back"

local eventsTestName =
  "scope.Events delivers the CVAR_UPDATE of a chatBubbles change while enabled; after Disable its frame is gone from GetFramesRegisteredForEvent and a second change reaches nothing"

if REGISTRATIONS_READABLE then
  scopes:Test(eventsTestName, function(ctx)
    local journal = newJournal()
    local deliveries = 0
    local eventsScope = nil
    local before = registeredFrameSet(CVAR_EVENT)
    local definition = journalDefinition(journal, "Events", nil, function(module)
      eventsScope = module.scope.Events
      eventsScope:Connect(CVAR_EVENT, function(_, cvarName)
        if namesProbeCVar(cvarName) then
          deliveries = deliveries + 1
        end
      end)
    end)
    local module = trackModule(ownContainer():CreateModule(newNamePrefix() .. "Events", definition))

    ctx:Expect(type(eventsScope)):ToBe("table")
    ---@cast eventsScope any
    ctx:Expect(eventsScope:GetActiveCount()):ToBe(1)
    local added = framesAddedSince(CVAR_EVENT, before)
    ctx:Log(("frames added by the module's Connect: %d"):format(#added))
    ctx:Expect(#added):ToBe(1)
    local frame = added[1]
    ctx:Expect((frame:IsEventRegistered(CVAR_EVENT))):ToBe(true)

    flipProbeCVar(ctx)
    ctx:Log("delivered before SetCVar returned: " .. tostring(deliveries > 0))
    ctx
      :Expect(waitUntil(ctx, function()
        return deliveries >= 1
      end, LOCAL_EVENT_TIMEOUT_SECONDS))
      :ToBe(true)
    local deliveredWhileEnabled = deliveries

    module:Disable()
    ctx:Expect(eventsScope:IsClosed()):ToBe(true)
    ctx:Expect(#framesAddedSince(CVAR_EVENT, before)):ToBe(0)
    ctx:Expect((frame:IsEventRegistered(CVAR_EVENT))):ToBe(false)

    flipProbeCVar(ctx)
    local lateDelivery = waitUntil(ctx, function()
      return deliveries > deliveredWhileEnabled
    end, QUIET_SECONDS)
    ctx:Log(("deliveries: %d while enabled, %d in all"):format(deliveredWhileEnabled, deliveries))
    ctx:Expect(lateDelivery):ToBe(false)
  end)
else
  scopes:Skip(eventsTestName, REGISTRATIONS_SKIP_REASON)
end

scopes:Test(
  "scope.Hooks pre-hooks a method of a table this test owns while enabled, and Disable writes the original method back",
  function(ctx)
    local journal = newJournal()
    local originalCalls = 0
    local hookCalls = 0
    local target = {}
    local function originalPing(_, value)
      originalCalls = originalCalls + 1
      return value
    end
    target.Ping = originalPing

    local hooksScope = nil
    local definition = journalDefinition(journal, "Hooks", nil, function(module)
      hooksScope = module.scope.Hooks
      hooksScope:Hook(target, "Ping", function()
        hookCalls = hookCalls + 1
      end)
    end)
    local module = trackModule(ownContainer():CreateModule(newNamePrefix() .. "Hooks", definition))

    ctx:Expect(type(hooksScope)):ToBe("table")
    ---@cast hooksScope any
    ctx:Expect(rawget(target, "Ping") == originalPing):ToBe(false)
    ctx:Expect(hooksScope:IsHooked(target, "Ping")):ToBe(true)
    ctx:Expect(target:Ping(7)):ToBe(7)
    ctx:Expect(hookCalls):ToBe(1)
    ctx:Expect(originalCalls):ToBe(1)

    module:Disable()
    ctx:Expect(hooksScope:IsClosed()):ToBe(true)
    ctx:Expect(rawget(target, "Ping")):ToBe(originalPing)
    ctx:Expect(target:Ping(8)):ToBe(8)
    ctx:Expect(hookCalls):ToBe(1)
    ctx:Expect(originalCalls):ToBe(2)
  end
)

scopes:Test(
  "scope.Commands is an empty CommandKit scope while enabled and Disable closes it; no slash command is registered",
  function(ctx)
    local journal = newJournal()
    local commandsScope = nil
    local definition = journalDefinition(journal, "Commands", nil, function(module)
      commandsScope = module.scope.Commands
    end)
    local module =
      trackModule(ownContainer():CreateModule(newNamePrefix() .. "Commands", definition))

    ctx:Expect(type(commandsScope)):ToBe("table")
    ---@cast commandsScope any
    ctx:Expect(commandsScope:IsClosed()):ToBe(false)
    ctx:Expect(commandsScope:GetActiveCount()):ToBe(0)

    module:Disable()
    ctx:Expect(commandsScope:IsClosed()):ToBe(true)
    ctx:Expect(rawget(module.scope, "Commands")):ToBeNil()
  end
)

scopes:Skip(
  "a slash command registered through scope.Commands goes inert when the module is disabled",
  "not exercised: the client keeps a registered command's SLASH_ globals and SlashCmdList entry for the session, so it would stay visible; packages/moduleKit/tests/Scope_spec.lua proves it"
)

scopes:Test(
  "scope.Jobs, scope.Messages and scope.Comm are scopes of SchedulerKit, this addon's SignalKit bus and CommKit; Disable closes all three, and a 0.2-second job never runs",
  function(ctx)
    local journal = newJournal()
    local opened = {}
    local jobRuns = 0
    local definition = journalDefinition(journal, "Others", nil, function(module)
      opened.jobs = module.scope.Jobs
      opened.messages = module.scope.Messages
      opened.comm = module.scope.Comm
      if type(opened.jobs) ~= "nil" then
        opened.job = opened.jobs:After(SCOPED_DELAY_SECONDS, function()
          jobRuns = jobRuns + 1
        end)
      end
    end)
    local module = trackModule(ownContainer():CreateModule(newNamePrefix() .. "Others", definition))

    for _, field in ipairs({ "jobs", "messages", "comm" }) do
      ctx:Log(field .. ": " .. type(opened[field]))
      ctx:Expect(type(opened[field])):ToBe("table")
      ctx:Expect(opened[field]:IsClosed()):ToBe(false)
    end
    ctx:Expect(opened.jobs:GetActiveCount()):ToBe(1)

    module:Disable()
    for _, field in ipairs({ "jobs", "messages", "comm" }) do
      ctx:Expect(opened[field]:IsClosed()):ToBe(true)
    end
    ctx:Expect(opened.job:IsCancelled()):ToBe(true)

    waitForControlTimer(ctx)
    ctx:Expect(jobRuns):ToBe(0)
  end
)

-- moduleKit.injection -----------------------------------------------------------------------

local injection = newSuite("injection")

---A table with a no-op function under each of `methodNames`.
---@param methodNames string[]
---@return table<string, function>
local function withMethods(methodNames)
  local value = {}
  for _, name in ipairs(methodNames) do
    value[name] = ignore
  end
  return value
end

injection:Test(
  "ProvideSingleton with a list implements runs its factory once and injects the same checked instance into two modules created after ready",
  function(ctx)
    local container = ownContainer()
    local prefix = newNamePrefix()
    local journal = newJournal()
    local factoryRuns = 0
    container:ProvideSingleton(prefix .. "Store", function()
      factoryRuns = factoryRuns + 1
      return withMethods({ "Save", "Load" })
    end, { implements = { "Save", "Load" } })

    local received = {}
    for _, label in ipairs({ "First", "Second" }) do
      local definition = journalDefinition(journal, label, {
        inject = { store = prefix .. "Store" },
        onInitialize = function(_, dependencies)
          if journal.live then
            received[#received + 1] = dependencies.store
          end
        end,
      })
      trackModule(container:CreateModule(prefix .. label, definition))
    end

    ctx:Expect(factoryRuns):ToBe(1)
    ctx:Expect(#received):ToBe(2)
    ctx:Expect(type(received[1])):ToBe("table")
    ctx:Expect(received[2]):ToBe(received[1])
    ctx:Expect(container:Resolve(prefix .. "Store")):ToBe(received[1])
    ctx:Expect(container:GetModule(prefix .. "First"):GetInjections().store):ToBe(received[1])
    ctx:Expect(factoryRuns):ToBe(1)
  end
)

injection:Test(
  "ProvideModule with a list implements runs its factory once per requesting module and hands it that module",
  function(ctx)
    local container = ownContainer()
    local prefix = newNamePrefix()
    local journal = newJournal()
    local requesters = {}
    container:ProvideModule(prefix .. "Logger", function(_, requestingModule)
      requesters[#requesters + 1] = requestingModule:GetName()
      local logger = withMethods({ "Log" })
      logger.owner = requestingModule:GetName()
      return logger
    end, { implements = { "Log" } })

    local modules = {}
    for _, label in ipairs({ "Left", "Right" }) do
      local definition = journalDefinition(journal, label, {
        inject = { logger = prefix .. "Logger" },
      })
      modules[label] = trackModule(container:CreateModule(prefix .. label, definition))
    end

    ctx:Expect(requesters):ToEqual({ prefix .. "Left", prefix .. "Right" })
    local leftLogger = modules.Left:GetInjections().logger
    ctx:Expect(leftLogger.owner):ToBe(prefix .. "Left")
    ctx:Expect(modules.Right:GetInjections().logger.owner):ToBe(prefix .. "Right")
    ctx:Expect(modules.Left:Resolve(prefix .. "Logger")):ToBe(leftLogger)
    ctx:Expect(container:Resolve(prefix .. "Logger", modules.Left)):ToBe(leftLogger)
    ctx:Expect(#requesters):ToBe(2)
  end
)

injection:Test(
  "a lazy provider whose value lacks a listed method is refused at the Resolve line, is not cached, and runs its factory again on the next Resolve",
  function(ctx)
    local container = ownContainer()
    local name = newNamePrefix() .. "Broken"
    local factoryRuns = 0
    container:ProvideSingleton(name, function()
      factoryRuns = factoryRuns + 1
      return withMethods({ "Save" })
    end, { implements = { "Save", "Load" } })

    local expected = 'ModuleKit provider "' .. name .. '" must implement "Load": no such member'
    expectErrorAtCallingLine(ctx, function(at)
      at.line = currentLine()
      container:Resolve(name)
    end, expected)
    expectErrorAtCallingLine(ctx, function(at)
      at.line = currentLine()
      container:Resolve(name)
    end, expected)
    ctx:Expect(factoryRuns):ToBe(2)
  end
)

injection:Test(
  "ProvideValue with a list implements refuses a member that is not a function at the ProvideValue line, and the name stays free",
  function(ctx)
    local container = ownContainer()
    local name = newNamePrefix() .. "Settings"
    expectErrorAtCallingLine(
      ctx,
      function(at)
        at.line = currentLine()
        container:ProvideValue(name, { Save = "yes" }, { implements = { "Save" } })
      end,
      'ModuleKit provider "'
        .. name
        .. '" must implement "Save": member "Save" is a string, not a function'
    )

    local accepted = withMethods({ "Save" })
    container:ProvideValue(name, accepted, { implements = { "Save" } })
    ctx:Expect(container:Resolve(name)):ToBe(accepted)
  end
)

injection:Test(
  "a definition-table module whose implements names a hook it does not set is refused at the CreateModule line and is not created",
  function(ctx)
    local container = ownContainer()
    local name = newNamePrefix() .. "Forgetful"
    expectErrorAtCallingLine(ctx, function(at)
      at.line = currentLine()
      container:CreateModule(name, { implements = { "OnEnable", "OnDisable" }, onEnable = ignore })
    end, 'ModuleKit module "' .. name .. '" must implement "OnDisable": no such member')
    ctx:Expect(container:HasModule(name)):ToBe(false)
  end
)

--- Why the schema tests are skipped without SchemaKit.
local SCHEMA_SKIP_REASON =
  "SchemaKit API 1 is not loaded; the schema form of implements was not exercised"

---Register `body` as an injection test when SchemaKit is loaded, and as a
---skipped test naming why otherwise.
---@param name string
---@param body fun(ctx: TestKit.Context)
local function schemaTest(name, body)
  if SCHEMA_KIT_LOADED then
    injection:Test(name, body)
  else
    injection:Skip(name, SCHEMA_SKIP_REASON)
  end
end

---Whether `value` is a function; the check of a SchemaKit `custom` node.
---@param value any
---@return boolean
local function isFunction(value)
  return type(value) == "function"
end

---An open SchemaKit table node that requires a `Save` function and a `scale`
---number from 0.5 to 2, and accepts every other field.
---@return any node
local function settingsNode()
  return SchemaKit.table({
    fields = {
      Save = SchemaKit.custom(isFunction, "function"),
      scale = SchemaKit.number({ min = 0.5, max = 2 }),
    },
    open = true,
  })
end

schemaTest(
  "ProvideValue with a SchemaKit implements schema accepts a matching value and refuses a mismatch at the ProvideValue line, naming the path",
  function(ctx)
    local container = ownContainer()
    local prefix = newNamePrefix()
    local accepted = { Save = ignore, scale = 1, extra = true }
    container:ProvideValue(prefix .. "Settings", accepted, { implements = settingsNode() })
    ctx:Expect(container:Resolve(prefix .. "Settings")):ToBe(accepted)

    local refusedName = prefix .. "Refused"
    expectErrorAtCallingLine(
      ctx,
      function(at)
        at.line = currentLine()
        container:ProvideValue(
          refusedName,
          { Save = ignore, scale = "big" },
          { implements = settingsNode() }
        )
      end,
      'ModuleKit provider "'
        .. refusedName
        .. '" does not match its implements schema: at scale, expected number, found string'
    )
    ctx:Expect(container:HasModule(refusedName)):ToBe(false)
  end
)

schemaTest(
  "ProvideSingleton with a SchemaKit implements schema checks the factory's result when it first arrives and refuses it at the Resolve line",
  function(ctx)
    local container = ownContainer()
    local prefix = newNamePrefix()
    container:ProvideSingleton(prefix .. "Good", function()
      return { Save = ignore, scale = 2 }
    end, { implements = SchemaKit:Seal(settingsNode()) })
    container:ProvideSingleton(prefix .. "Bad", function()
      return { scale = 1 }
    end, { implements = settingsNode() })

    local good = container:Resolve(prefix .. "Good")
    ctx:Expect(type(good)):ToBe("table")
    ctx:Expect(container:Resolve(prefix .. "Good")):ToBe(good)
    expectErrorAtCallingLine(
      ctx,
      function(at)
        at.line = currentLine()
        container:Resolve(prefix .. "Bad")
      end,
      'ModuleKit provider "'
        .. prefix
        .. 'Bad" does not match its implements schema: at Save, expected function, found nil'
    )
  end
)

-- moduleKit.errors ---------------------------------------------------------------------------

local errors = newSuite("errors")

errors:Test(
  "CreateModule with a name that is not a string is refused at the calling line",
  function(ctx)
    -- The wrong argument type is the point of the test.
    ---@type any
    local notAName = 42
    local container = ownContainer()
    expectErrorAtCallingLine(ctx, function(at)
      at.line = currentLine()
      container:CreateModule(notAName)
    end, "ModuleKit.Addon:CreateModule name must be a non-empty string")
  end
)

errors:Test(
  "CreateModule with a misspelled definition field is refused at the calling line and creates nothing",
  function(ctx)
    local container = ownContainer()
    local name = newNamePrefix() .. "Misspelled"
    expectErrorAtCallingLine(ctx, function(at)
      at.line = currentLine()
      container:CreateModule(name, { onEnabel = ignore })
    end, 'ModuleKit module definition contains unknown field "onEnabel"')
    ctx:Expect(container:HasModule(name)):ToBe(false)
  end
)

errors:Test(
  "SetDependencyPolicy with an unknown policy is refused at the calling line and keeps the policy",
  function(ctx)
    local container = ownContainer()
    expectErrorAtCallingLine(ctx, function(at)
      at.line = currentLine()
      container:SetDependencyPolicy("lenient")
    end, 'ModuleKit.Addon:SetDependencyPolicy policy must be "automatic" or "strict"')
    ctx:Expect(container:GetDependencyPolicy()):ToBe("automatic")
  end
)

errors:Test(
  "reading scope.Timers of a disabled module is refused at the reading line",
  function(ctx)
    local container = ownContainer()
    local name = newNamePrefix() .. "Closed"
    local module = trackModule(container:CreateModule(name, { onEnable = ignore }))
    module:Disable()
    expectErrorAtCallingLine(
      ctx,
      function(at)
        at.line = currentLine()
        local _ = module.scope.Timers
      end,
      'ModuleKit module "'
        .. name
        .. '" scope.Timers is available only while the module is enabling or enabled'
    )
  end
)

errors:Test(
  "Enable of a module two DependsOn steps from a missing module is refused at the Enable line, naming the missing one",
  function(ctx)
    local container = ownContainer()
    local prefix = newNamePrefix()
    local top = trackModule(container:CreateModule(prefix .. "Top"))
    local middle = trackModule(container:CreateModule(prefix .. "Middle"))
    top:DependsOn(prefix .. "Middle")
    middle:DependsOn(prefix .. "Missing")
    -- The container is shared by every test of the session, and an
    -- `EnableAll` refuses a graph with a missing module, so the missing
    -- module is created once the test is over.
    pendingReleases[#pendingReleases + 1] = function()
      if not container:HasModule(prefix .. "Missing") then
        container:CreateModule(prefix .. "Missing")
      end
    end

    expectErrorAtCallingLine(
      ctx,
      function(at)
        at.line = currentLine()
        top:Enable()
      end,
      'ModuleKit module "'
        .. prefix
        .. 'Middle" requires missing dependency "'
        .. prefix
        .. 'Missing"'
    )
    ctx:Expect(top:GetState()):ToBe("created")
    ctx:Expect(middle:GetState()):ToBe("created")
  end
)

errors:Test("Before an already-initialized module is refused at the calling line", function(ctx)
  local container = ownContainer()
  local prefix = newNamePrefix()
  trackModule(container:CreateModule(prefix .. "Settled", { onEnable = ignore }))
  local late = trackModule(container:CreateModule(prefix .. "Late"))
  expectErrorAtCallingLine(
    ctx,
    function(at)
      at.line = currentLine()
      late:Before(prefix .. "Settled")
    end,
    'ModuleKit module "'
      .. prefix
      .. 'Late" cannot be ordered before already-initialized module "'
      .. prefix
      .. 'Settled"'
  )
end)

errors:Test(
  "SetLimits with a limit ModuleKit does not know is refused at the calling line and changes nothing",
  function(ctx)
    local before = ModuleKit:GetLimits()
    expectErrorAtCallingLine(ctx, function(at)
      at.line = currentLine()
      ModuleKit:SetLimits({ maxModules = 8 })
    end, "ModuleKit:SetLimits limits.maxModules is not a recognised limit")
    ctx:Expect(ModuleKit:GetLimits()):ToEqual(before)
  end
)

-- moduleKit.secrets --------------------------------------------------------------------------

local secrets = newSuite("secrets")

--- Why the secrets tests are skipped on a client without the two functions.
local SECRETS_SKIP_REASON =
  "the client has no issecretvalue and secretwrap; the secret path was not exercised"

---Register `body` as a test when the client can make a secret value, and as a
---skipped test naming why otherwise.
---@param name string
---@param body fun(ctx: TestKit.Context)
local function secretTest(name, body)
  if SECRETS_AVAILABLE then
    secrets:Test(name, body)
  else
    secrets:Skip(name, SECRETS_SKIP_REASON)
  end
end

secretTest("ForAddon with a secret addon name is refused at the calling line", function(ctx)
  local secretName = makeSecret(ctx, addonName)
  expectErrorAtCallingLine(ctx, function(at)
    at.line = currentLine()
    ModuleKit:ForAddon(secretName)
  end, "ModuleKit:ForAddon addonName must not be a secret value")
end)

secretTest(
  "CreateModule with a secret name is refused at the calling line and creates nothing",
  function(ctx)
    local container = ownContainer()
    local plainName = newNamePrefix() .. "Secret"
    local secretName = makeSecret(ctx, plainName)
    expectErrorAtCallingLine(ctx, function(at)
      at.line = currentLine()
      container:CreateModule(secretName)
    end, "ModuleKit.Addon:CreateModule name must not be a secret value")
    ctx:Expect(container:HasModule(plainName)):ToBe(false)
  end
)

secretTest("DependsOn with a secret module name is refused at the calling line", function(ctx)
  local container = ownContainer()
  local prefix = newNamePrefix()
  local module = trackModule(container:CreateModule(prefix .. "Dependent"))
  local secretName = makeSecret(ctx, prefix .. "Base")
  expectErrorAtCallingLine(ctx, function(at)
    at.line = currentLine()
    module:DependsOn(secretName)
  end, "ModuleKit.Module:DependsOn moduleName must not be a secret value")
end)

secretTest(
  "ProvideValue with a secret implements entry is refused at the calling line and leaves the name free",
  function(ctx)
    local container = ownContainer()
    local name = newNamePrefix() .. "Contract"
    local secretEntry = makeSecret(ctx, "Load")
    expectErrorAtCallingLine(ctx, function(at)
      at.line = currentLine()
      container:ProvideValue(
        name,
        withMethods({ "Save", "Load" }),
        { implements = { "Save", secretEntry } }
      )
    end, "ModuleKit.Addon:ProvideValue options.implements entries must not be secret values")
    container:ProvideValue(name, true)
    ctx:Expect(container:Resolve(name)):ToBe(true)
  end
)

secretTest(
  "ProvideValue accepts a secret value, which is never compared, and Resolve and injection hand back that secret",
  function(ctx)
    local container = ownContainer()
    local prefix = newNamePrefix()
    local journal = newJournal()
    local secretValue = makeSecret(ctx, "mctModuleKit secret payload")
    container:ProvideValue(prefix .. "Secret", secretValue)

    ctx:Expect(isSecret(container:Resolve(prefix .. "Secret"))):ToBe(true)
    local injectedSecret = false
    trackModule(
      container:CreateModule(
        prefix .. "Consumer",
        journalDefinition(journal, "Consumer", {
          inject = { payload = prefix .. "Secret" },
          onInitialize = function(_, dependencies)
            injectedSecret = isSecret(dependencies.payload)
          end,
        })
      )
    )
    ctx:Expect(injectedSecret):ToBe(true)
  end
)

secretTest(
  "SetLimits with a secret maxRequiredAddons is refused at the calling line and changes nothing",
  function(ctx)
    local before = ModuleKit:GetLimits()
    local secretLimit = makeSecret(ctx, 8)
    expectErrorAtCallingLine(ctx, function(at)
      at.line = currentLine()
      ModuleKit:SetLimits({ maxRequiredAddons = secretLimit })
    end, "ModuleKit:SetLimits limits.maxRequiredAddons must not be a secret value")
    ctx:Expect(ModuleKit:GetLimits()):ToEqual(before)
  end
)

secretTest(
  "SetDependencyPolicy with a secret policy is refused at the calling line and keeps the policy",
  function(ctx)
    local container = ownContainer()
    local secretPolicy = makeSecret(ctx, "strict")
    expectErrorAtCallingLine(ctx, function(at)
      at.line = currentLine()
      container:SetDependencyPolicy(secretPolicy)
    end, "ModuleKit.Addon:SetDependencyPolicy policy must not be a secret value")
    ctx:Expect(container:GetDependencyPolicy()):ToBe("automatic")
  end
)

-- moduleKit.allocation -----------------------------------------------------------------------

local allocation = newSuite("allocation")

---Measure how many kilobytes `work` grows the Lua heap by.
---@param work fun()
---@return number grownKilobytes
local function measureAllocation(work)
  local before = collectgarbage("count")
  work()
  return collectgarbage("count") - before
end

allocation:Test(
  "GetModule, HasModule, GetState, IsEnabled and the Resolve of a cached singleton and module-scoped value allocate nothing over 10000 rounds (allocation guard)",
  function(ctx)
    local container = ownContainer()
    local prefix = newNamePrefix()
    local journal = newJournal()
    container:ProvideSingleton(prefix .. "Store", function()
      return withMethods({ "Save" })
    end, { implements = { "Save" } })
    container:ProvideModule(prefix .. "Logger", function()
      return withMethods({ "Log" })
    end, { implements = { "Log" } })
    local moduleName = prefix .. "Reader"
    local module =
      trackModule(container:CreateModule(
        moduleName,
        journalDefinition(journal, "Reader", {
          inject = { store = prefix .. "Store", logger = prefix .. "Logger" },
        })
      ))
    local storeName = prefix .. "Store"
    local loggerName = prefix .. "Logger"

    -- A full collection in a step of its own, so the measurement that
    -- follows starts far from the next collector cycle.
    collectgarbage("collect")
    ctx:Yield()

    local grownKilobytes = measureAllocation(function()
      for _ = 1, LOOKUP_CALLS do
        container:GetModule(moduleName)
        container:HasModule(moduleName)
        module:GetState()
        module:IsEnabled()
        container:Resolve(storeName)
        module:Resolve(loggerName)
      end
    end)

    ctx:Log(("memory delta over %d rounds: %.3f KB"):format(LOOKUP_CALLS, grownKilobytes))
    ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
    ctx:Expect(module:IsEnabled()):ToBe(true)
  end
)
