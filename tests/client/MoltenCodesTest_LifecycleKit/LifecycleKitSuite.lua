-- MoltenCodes Test: LifecycleKitSuite.lua
--
-- Real-client suites for the `lifecycleKit` package. The Busted specs under
-- packages/lifecycleKit/tests/ prove LifecycleKit against a fake client whose
-- ADDON_LOADED, PLAYER_LOGIN and PLAYER_REGEN_* a spec emits by hand; these
-- prove, inside the game client with the installed MoltenCodes addon, what that
-- fixture can only simulate:
--
--   * the installed facade and its committed revision;
--   * the phases this very addon went through while the client loaded it: the
--     state its instance had while this file ran, what `C_AddOns.IsAddOnLoaded`
--     and `IsLoggedIn()` answered then, and the order in which the Kit and two
--     plain EventKit listeners saw ADDON_LOADED and PLAYER_LOGIN;
--   * replay: a phase subscription made after the phase already happened runs
--     at once and comes back disconnected;
--   * `DependsOn` on the harness addon (loaded) and on an addon that is not
--     installed;
--   * the combat gate out of combat, next to what `InCombatLockdown()` answers;
--   * `CLOSES_ADDON_SCOPES` and the Kits of the bundle that read it;
--   * argument errors, and the refusal of genuine secret values made by the
--     client's `secretwrap`, pointing at this file as the client names it.
--
-- Nothing here needs combat, a group or an instance, and nothing waits in a
-- normal run. One test is passive and optional: `lifecycleKit.combatDeferral`
-- exercises the deferred path of the combat gate only when the run starts in
-- combat (EXPECTED.md, "Optional: the training-dummy run"), and is reported as
-- skipped otherwise. Logout ends the session, so what shutdown does cannot be
-- observed in a run; the Busted specs prove it.
--
-- Run with `/mct run lifecycleKit`;
-- tests/client/MoltenCodesTest_LifecycleKit/EXPECTED.md lists what the chat
-- frame should show.
--
-- What a run leaves behind. Every subscription, connection and deferred call a
-- test creates is released by the After hook of its suite, whatever the test's
-- outcome, and the combat-queue limit a test changes is put back afterwards.
-- What LifecycleKit keeps for the session, and API 1 cannot release: this
-- addon's lifecycle instance (created while this file ran, as for every
-- addon), and the two dependencies the `dependencies` tests record on it, on
-- `MoltenCodesTest` and on `MoltenCodesTest_NoSuchAddon` (a later run records
-- nothing new). No other lifecycle instance is created, nothing is halted,
-- `SetLimits` is only ever refused, and nothing is written to a global or a
-- saved variable. The two EventKit listeners connected while this file ran
-- disconnect themselves when their event arrives, during the login.

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
local LIFECYCLE_KIT_API = 1
local EVENT_KIT_API = 1
local PACKAGE_ID = "lifecycleKit"

--- The harness addon: a dependency of this addon, so it loaded before it.
local HARNESS_ADDON = "MoltenCodesTest"

--- An addon name no installation has, for the `DependsOn` test.
local MISSING_ADDON = "MoltenCodesTest_NoSuchAddon"

--- Every method docs/API.md of lifecycleKit lists on the facade.
local FACADE_METHODS = { "ForAddon", "IsInCombat", "SetLimits", "GetLimits" }

--- Every method docs/API.md of lifecycleKit lists on a lifecycle instance.
local INSTANCE_METHODS = {
    "GetAddonName",
    "GetState",
    "IsLoaded",
    "IsReady",
    "IsShutdown",
    "IsHalted",
    "GetHaltReason",
    "OnLoaded",
    "OnReady",
    "OnShutdown",
    "OnHalted",
    "Halt",
    "DependsOn",
    "OnDependencyHalted",
    "WhenOutOfCombat",
    "OnCombatStart",
    "OnCombatEnd",
    "SetCombatQueueLimit",
    "GetCombatQueueLimit",
}

---One Kit whose addon scopes LifecycleKit closes at shutdown, and the first
---version of it that reads `CLOSES_ADDON_SCOPES` (docs/API.md of
---lifecycleKit, "Addon-scope capability").
---@class MoltenCodesTest.LifecycleKit.ScopeReader
---@field id string
---@field readsFrom string

--- The seven packages `CLOSES_ADDON_SCOPES` names, in the order shutdown
--- closes them, each with the version it reads the capability from.
---@type MoltenCodesTest.LifecycleKit.ScopeReader[]
local SCOPE_READERS = {
    { id = "timerKit", readsFrom = "0.6.0" },
    { id = "schedulerKit", readsFrom = "0.8.0" },
    { id = "eventKit", readsFrom = "0.7.0" },
    { id = "hookKit", readsFrom = "0.2.0" },
    { id = "commandKit", readsFrom = "0.2.0" },
    { id = "commKit", readsFrom = "0.2.0" },
    { id = "signalKit", readsFrom = "0.6.0" },
}

--- Seconds the training-dummy test waits for combat to end. The owner stops
--- attacking right after typing the command; a dummy drops combat a few
--- seconds after the last hit.
local COMBAT_END_TIMEOUT_SECONDS = 30

--- TestKit's limit for one test of the training-dummy suite: the wait above
--- plus room for the steps around it.
local COMBAT_SUITE_TIMEOUT_SECONDS = COMBAT_END_TIMEOUT_SECONDS + 10

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
    -- Login and combat state, addon load state and secret-value functions are
    -- World of Warcraft client globals, reachable only through the global table.
    -- selene: allow(global_usage)
    return rawget(_G, name)
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, REGISTRY_API)
if type(Registry) ~= "table" then
    error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

---@type LifecycleKit|nil
local LifecycleKitOrNil = Registry:Get(PACKAGE_ID, LIFECYCLE_KIT_API)
---@type EventKit|nil
local EventKitOrNil = Registry:Get("eventKit", EVENT_KIT_API)
if type(LifecycleKitOrNil) == "nil" or type(EventKitOrNil) == "nil" then
    error(
        addonName
            .. " requires LifecycleKit API 1 and EventKit API 1 in the MoltenCodes addon; reinstall it",
        0
    )
end
---@cast LifecycleKitOrNil LifecycleKit
---@cast EventKitOrNil EventKit
local LifecycleKit = LifecycleKitOrNil
local EventKit = EventKitOrNil

--- Read once at load: the secrets suite registers its tests as skipped when
--- the client cannot make a secret value.
local isSecretValue = readHost("issecretvalue")
local secretWrap = readHost("secretwrap")
local SECRETS_AVAILABLE = type(isSecretValue) == "function" and type(secretWrap) == "function"

-- Client facts -------------------------------------------------------------------------

---What `IsLoggedIn()` answers, or `nil` when the client has no such function.
---@return any
local function readLoggedIn()
    local isLoggedIn = readHost("IsLoggedIn")
    if type(isLoggedIn) ~= "function" then
        return nil
    end
    return isLoggedIn()
end

---What `InCombatLockdown()` answers, or `nil` when the client has no such function.
---@return any
local function readCombatLockdown()
    local inCombatLockdown = readHost("InCombatLockdown")
    if type(inCombatLockdown) ~= "function" then
        return nil
    end
    return inCombatLockdown()
end

---What `C_AddOns.IsAddOnLoaded(name)` answers: `(loaded, finished)`. Two
---`nil`s and the error when the client has no such function or it raised,
---which the tests log rather than trust.
---@param name string
---@return any loaded
---@return any finished
---@return string|nil problem
local function readAddonLoaded(name)
    local addOns = readHost("C_AddOns")
    local isAddOnLoaded = type(addOns) == "table" and addOns.IsAddOnLoaded or nil
    if type(isAddOnLoaded) ~= "function" then
        return nil, nil, "the client has no C_AddOns.IsAddOnLoaded"
    end
    local succeeded, loaded, finished = pcall(isAddOnLoaded, name)
    if not succeeded then
        return nil, nil, "C_AddOns.IsAddOnLoaded raised: " .. tostring(loaded)
    end
    return loaded, finished, nil
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

-- What this addon went through while the client loaded it -----------------------------
--
-- Everything below runs while the client executes this file, before its
-- ADDON_LOADED. `ForAddon` is called here, as an addon would call it, so the
-- instance is created while the client reports this addon as loading.

local lifecycle = LifecycleKit:ForAddon(addonName)

---What was true while this file ran.
---@class MoltenCodesTest.LifecycleKit.FileFacts
---@field state string
---@field loggedIn any
---@field addonLoaded any
---@field addonFinished any
---@field addonProblem string|nil why `C_AddOns.IsAddOnLoaded` could not be read
---@field inCombatLockdown any
---@field isInCombat boolean

---@type MoltenCodesTest.LifecycleKit.FileFacts
local fileFacts
do
    local addonLoaded, addonFinished, addonProblem = readAddonLoaded(addonName)
    fileFacts = {
        state = lifecycle:GetState(),
        loggedIn = readLoggedIn(),
        addonLoaded = addonLoaded,
        addonFinished = addonFinished,
        addonProblem = addonProblem,
        inCombatLockdown = readCombatLockdown(),
        isInCombat = LifecycleKit:IsInCombat(),
    }
end

---One moment of the load, in the order it happened.
---@class MoltenCodesTest.LifecycleKit.Observation
---@field step string who observed it
---@field state string the instance's state then
---@field loggedIn any what `IsLoggedIn()` answered then

---@type MoltenCodesTest.LifecycleKit.Observation[]
local loadTimeline = {}

---Record that `step` happened now, with the instance's state and the login.
---@param step string
local function observe(step)
    loadTimeline[#loadTimeline + 1] = {
        step = step,
        state = lifecycle:GetState(),
        loggedIn = readLoggedIn(),
    }
end

observe("file")

-- The Kit's own view of the two phases. Both subscriptions are one-shot.
lifecycle:OnLoaded(function()
    observe("OnLoaded")
end)
lifecycle:OnReady(function()
    observe("OnReady")
end)

-- Two plain listeners, connected after LifecycleKit's watchers (installed by
-- the harness's `ForAddon`, before this file ran), so EventKit runs them after
-- the Kit's handler of the same event. Each disconnects itself.
local addonLoadedConnection
addonLoadedConnection = EventKit:Connect("ADDON_LOADED", function(_, loadedName)
    if type(loadedName) == "string" and loadedName == addonName then
        observe("ADDON_LOADED listener")
        addonLoadedConnection:Disconnect()
    end
end)
EventKit:Once("PLAYER_LOGIN", function()
    observe("PLAYER_LOGIN listener")
end)

-- Helpers ---------------------------------------------------------------------------

--- Release actions of the test that is running (disconnect a subscription or a
--- connection, cancel a deferred call), run first by the After hook.
---@type (fun())[]
local pendingReleases = {}

--- Restore actions of the test that is running (a combat-queue limit), run by
--- the After hook after every release.
---@type (fun())[]
local pendingRestores = {}

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

---Release everything the test created, then restore what it changed.
---Registered as the After hook of every suite.
local function cleanUp()
    local releasedCleanly, releaseProblem = pcall(runActions, pendingReleases)
    runActions(pendingRestores)
    if not releasedCleanly then
        error(releaseProblem, 0)
    end
end

---Remember a LifecycleKit subscription for the After hook, which disconnects
---it, and hand it back.
---@param subscription LifecycleKit.Subscription
---@return LifecycleKit.Subscription subscription
local function track(subscription)
    pendingReleases[#pendingReleases + 1] = function()
        subscription:Disconnect()
    end
    return subscription
end

---Remember an EventKit connection for the After hook, which disconnects it.
---@param connection EventKit.Connection
local function trackConnection(connection)
    pendingReleases[#pendingReleases + 1] = function()
        connection:Disconnect()
    end
end

---Remember a deferred call for the After hook, which cancels it when it is
---still waiting. `nil` (a refused call) is ignored.
---@param call LifecycleKit.DeferredCall|nil
local function trackDeferredCall(call)
    if type(call) == "nil" then
        return
    end
    ---@cast call LifecycleKit.DeferredCall
    pendingReleases[#pendingReleases + 1] = function()
        call:Cancel()
    end
end

---Change this addon's combat-queue limit for the test; the After hook puts the
---previous one back.
---@param limit integer|table
local function setQueueLimitForTest(limit)
    local previous = lifecycle:GetCombatQueueLimit()
    pendingRestores[#pendingRestores + 1] = function()
        lifecycle:SetCombatQueueLimit(previous)
    end
    lifecycle:SetCombatQueueLimit(limit)
end

---Register a suite of this package whose tests all end released and restored.
---@param part string
---@param options MoltenCodesTest.SuiteOptions|nil
---@return TestKit.Suite
local function newSuite(part, options)
    local suite = Harness:Suite(PACKAGE_ID, part, addonName, options)
    suite:After(cleanUp)
    return suite
end

---`ctx:WaitUntil(predicate, timeoutSeconds)`, returning only whether the
---predicate became truthy in time.
---
---The call goes through an untyped alias because the LuaCATS field TestKit
---declares for `WaitUntil` reads to lua-language-server as a predicate
---returning two values, so a direct call is reported as passing one argument
---too many.
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
    ctx:Expect((file or ""):sub(-#"LifecycleKitSuite.lua")):ToBe("LifecycleKitSuite.lua")
    return line
end

---Call `raise`, which must record its start line and raise on the next line,
---and check the message names this file and ends with `expected`.
---@param ctx TestKit.Context
---@param raise fun() Records its start line with `currentLine()`, then raises on the next line.
---@param expected string The message after the position, compared literally.
---@return integer|nil line The line the message names.
local function expectErrorAtCallingLine(ctx, raise, expected)
    local succeeded, message = pcall(raise)
    ctx:Expect(succeeded):ToBe(false)
    ctx:Log("client message: " .. describeFact(message))

    local line = expectThisFile(ctx, message)
    ctx:Expect(tostring(message):sub(-#expected)):ToBe(expected)
    return line
end

---Parse a `major.minor.patch` version into three numbers.
---@param version string
---@return integer[]
local function versionParts(version)
    local major, minor, patch = version:match("^(%d+)%.(%d+)%.(%d+)")
    return { tonumber(major) or 0, tonumber(minor) or 0, tonumber(patch) or 0 }
end

---Whether `version` is `minimum` or later.
---@param version string
---@param minimum string
---@return boolean
local function isVersionAtLeast(version, minimum)
    local have = versionParts(version)
    local need = versionParts(minimum)
    for index = 1, 3 do
        if have[index] ~= need[index] then
            return have[index] > need[index]
        end
    end
    return true
end

---The row Expected.lua has for `packageId`, or a failed test.
---@param ctx TestKit.Context
---@param packageId string
---@return MoltenCodesTest.ExpectedPackage
local function expectedPackage(ctx, packageId)
    local expectedPackages = Harness:GetExpectedPackages()
    if type(expectedPackages) == "nil" then
        ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    end
    ---@cast expectedPackages MoltenCodesTest.ExpectedPackage[]
    for _, expected in ipairs(expectedPackages) do
        if expected.id == packageId then
            return expected
        end
    end
    ctx:Fail("Expected.lua does not list " .. packageId)
    error("unreachable: ctx:Fail raises", 0)
end

-- lifecycleKit.facade -------------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
    "Registry:Get('lifecycleKit', 1) is the LifecycleKit facade with API 1, every documented method, UNBOUNDED and CLOSES_ADDON_SCOPES",
    function(ctx)
        ctx:Expect(type(LifecycleKit)):ToBe("table")
        ctx:Expect(rawget(LifecycleKit, "API")):ToBe(LIFECYCLE_KIT_API)
        for _, method in ipairs(FACADE_METHODS) do
            ctx:Expect(type(LifecycleKit[method])):ToBe("function")
        end
        for _, method in ipairs(INSTANCE_METHODS) do
            ctx:Expect(type(lifecycle[method])):ToBe("function")
        end
        ctx:Expect(type(LifecycleKit.UNBOUNDED)):ToBe("table")
        ctx:Expect(type(LifecycleKit.CLOSES_ADDON_SCOPES)):ToBe("table")
    end
)

facade:Test(
    "the installed LifecycleKit carries the revision of the committed manifest",
    function(ctx)
        local expected = expectedPackage(ctx, PACKAGE_ID)
        local _, revision = Registry:Get(PACKAGE_ID, LIFECYCLE_KIT_API)
        ctx:Expect(revision):ToBe(expected.revision)
        ctx:Expect(rawget(LifecycleKit, "REVISION")):ToBe(expected.revision)
    end
)

-- lifecycleKit.phases -------------------------------------------------------------------

local phases = newSuite("phases")

phases:Test(
    "while this file ran, the client reported the addon not finished loading and not logged in, and its instance was loading",
    function(ctx)
        ctx:Log("C_AddOns.IsAddOnLoaded answered loaded " .. describeFact(fileFacts.addonLoaded))
        ctx:Log(
            "C_AddOns.IsAddOnLoaded answered finished " .. describeFact(fileFacts.addonFinished)
        )
        if type(fileFacts.addonProblem) ~= "nil" then
            ctx:Log(fileFacts.addonProblem)
        end
        ctx:Log("IsLoggedIn() answered " .. describeFact(fileFacts.loggedIn))
        ctx:Log("InCombatLockdown() answered " .. describeFact(fileFacts.inCombatLockdown))
        ctx:Log("LifecycleKit:IsInCombat() answered " .. describeFact(fileFacts.isInCombat))

        -- LifecycleKit trusts only the second value (docs/API.md, "State model").
        ctx:Expect(fileFacts.addonFinished):ToBe(false)
        ctx:Expect(fileFacts.loggedIn):ToBe(false)
        ctx:Expect(fileFacts.state):ToBe("loading")
    end
)

phases:Test(
    "the Kit reached loaded at this addon's ADDON_LOADED and ready at PLAYER_LOGIN, each before a listener connected after it",
    function(ctx)
        local steps, states, loggedIn = {}, {}, {}
        for index, observation in ipairs(loadTimeline) do
            steps[index] = observation.step
            states[index] = observation.state
            loggedIn[index] = observation.loggedIn
            ctx:Log(
                ("%d. %s: state %s, IsLoggedIn() %s"):format(
                    index,
                    observation.step,
                    observation.state,
                    describeFact(observation.loggedIn)
                )
            )
        end

        ctx:Expect(steps):ToEqual({
            "file",
            "OnLoaded",
            "ADDON_LOADED listener",
            "OnReady",
            "PLAYER_LOGIN listener",
        })
        ctx:Expect(states):ToEqual({ "loading", "loaded", "loaded", "ready", "ready" })
        ctx:Expect(loggedIn):ToEqual({ false, false, false, true, true })
    end
)

phases:Test(
    "ForAddon with this addon's name returns the instance created at load, ready and neither halted nor shut down",
    function(ctx)
        ctx:Expect(LifecycleKit:ForAddon(addonName) == lifecycle):ToBe(true)
        ctx:Expect(lifecycle:GetAddonName()):ToBe(addonName)
        ctx:Expect(lifecycle:GetState()):ToBe("ready")
        ctx:Expect(lifecycle:IsLoaded()):ToBe(true)
        ctx:Expect(lifecycle:IsReady()):ToBe(true)
        ctx:Expect(lifecycle:IsShutdown()):ToBe(false)
        ctx:Expect(lifecycle:IsHalted()):ToBe(false)
        ctx:Expect(lifecycle:GetHaltReason()):ToBeNil()
    end
)

phases:Test(
    "OnLoaded and OnReady made after their phase run at once with the instance and return a disconnected subscription",
    function(ctx)
        ---@param subscribe fun(self: LifecycleKit.Instance, callback: LifecycleKit.PhaseCallback): LifecycleKit.Subscription
        ---@param label string
        local function expectReplay(subscribe, label)
            local calls = {}
            local subscription = subscribe(lifecycle, function(...)
                calls[#calls + 1] = { instance = (...), second = (select(2, ...)) }
            end)
            local callsWhenReturned = #calls
            ctx:Log(("%s: %d call(s) before it returned"):format(label, callsWhenReturned))
            ctx:Expect(callsWhenReturned):ToBe(1)
            ctx:Expect(calls[1].instance == lifecycle):ToBe(true)
            ctx:Expect(calls[1].second):ToBeNil()
            ctx:Expect(subscription:IsConnected()):ToBe(false)
            ctx:Expect(subscription:Disconnect()):ToBe(false)
        end

        expectReplay(lifecycle.OnLoaded, "OnLoaded")
        expectReplay(lifecycle.OnReady, "OnReady")
    end
)

phases:Test(
    "OnShutdown and OnHalted made now stay pending without running, and Disconnect ends them",
    function(ctx)
        local calls = 0
        local function count()
            calls = calls + 1
        end
        local shutdownSubscription = track(lifecycle:OnShutdown(count))
        local haltedSubscription = track(lifecycle:OnHalted(count))

        ctx:Expect(calls):ToBe(0)
        ctx:Expect(shutdownSubscription:IsConnected()):ToBe(true)
        ctx:Expect(haltedSubscription:IsConnected()):ToBe(true)
        ctx:Expect(shutdownSubscription:Disconnect()):ToBe(true)
        ctx:Expect(haltedSubscription:Disconnect()):ToBe(true)
        ctx:Expect(shutdownSubscription:IsConnected()):ToBe(false)
        ctx:Expect(haltedSubscription:IsConnected()):ToBe(false)
        ctx:Expect(calls):ToBe(0)
    end
)

-- lifecycleKit.dependencies -------------------------------------------------------------

local dependencies = newSuite("dependencies")

---Declare `dependencyName` on this addon's instance and check the documented
---answers: `true` the first time in the session (`false` when an earlier run
---already recorded it), then `false`, and no halt notice.
---@param ctx TestKit.Context
---@param dependencyName string
local function expectDependencyRecorded(ctx, dependencyName)
    local first, firstReason = lifecycle:DependsOn(dependencyName)
    ctx:Log(
        ("DependsOn(%q) answered %s, %s (false: an earlier run in this session recorded it)"):format(
            dependencyName,
            describeFact(first),
            describeFact(firstReason)
        )
    )
    ctx:Expect(first == true or first == false):ToBe(true)
    ctx:Expect(firstReason):ToBeNil()

    local second, secondReason = lifecycle:DependsOn(dependencyName)
    ctx:Expect(second):ToBe(false)
    ctx:Expect(secondReason):ToBeNil()

    local notices = 0
    local subscription = track(lifecycle:OnDependencyHalted(function()
        notices = notices + 1
    end))
    ctx:Expect(notices):ToBe(0)
    ctx:Expect(subscription:IsConnected()):ToBe(true)
    ctx:Expect(subscription:Disconnect()):ToBe(true)
    ctx:Expect(lifecycle:IsHalted()):ToBe(false)
end

dependencies:Test(
    "DependsOn the loaded harness addon records it once, and no halt notice is delivered",
    function(ctx)
        local loaded, finished, problem = readAddonLoaded(HARNESS_ADDON)
        ctx:Log(
            ("C_AddOns.IsAddOnLoaded(%q) answered %s, %s"):format(
                HARNESS_ADDON,
                describeFact(loaded),
                describeFact(finished)
            )
        )
        if type(problem) ~= "nil" then
            ctx:Log(problem)
        end
        local harnessLifecycle = LifecycleKit:ForAddon(HARNESS_ADDON)
        ctx:Expect(harnessLifecycle:GetState()):ToBe("ready")

        expectDependencyRecorded(ctx, HARNESS_ADDON)
        ctx:Expect(harnessLifecycle:IsHalted()):ToBe(false)
    end
)

dependencies:Test(
    "DependsOn an addon that is not installed records it once, and no halt notice is delivered",
    function(ctx)
        local loaded, finished, problem = readAddonLoaded(MISSING_ADDON)
        ctx:Log(
            ("C_AddOns.IsAddOnLoaded(%q) answered %s, %s"):format(
                MISSING_ADDON,
                describeFact(loaded),
                describeFact(finished)
            )
        )
        if type(problem) ~= "nil" then
            ctx:Log(problem)
        end
        ctx:Expect(loaded == true):ToBe(false)

        expectDependencyRecorded(ctx, MISSING_ADDON)
    end
)

dependencies:Skip(
    "Halt of a throwaway instance tells a dependent through OnDependencyHalted",
    "not exercised: API 1 keeps every ForAddon instance for the session and halted is terminal, so a probe addon would stay halted until /reload; Halt reads no client API, and packages/lifecycleKit/tests/Halt_spec.lua proves it"
)

-- lifecycleKit.combatGate ---------------------------------------------------------------

local combatGate = newSuite("combatGate")

combatGate:Test(
    "out of combat, WhenOutOfCombat runs the callback with the instance and true before it returns and hands back a spent call",
    function(ctx)
        local lockdown = readCombatLockdown()
        local inCombat = LifecycleKit:IsInCombat()
        ctx:Log("InCombatLockdown() answered " .. describeFact(lockdown))
        ctx:Log("LifecycleKit:IsInCombat() answered " .. describeFact(inCombat))
        if lockdown == true or inCombat then
            Harness:SkipTest(
                ctx,
                "in combat, so the out-of-combat path was not exercised; run it again out of combat"
            )
            return
        end

        local calls = {}
        local call, refusal = lifecycle:WhenOutOfCombat(function(...)
            local instance, ran, reason = ...
            calls[#calls + 1] = {
                count = select("#", ...),
                instance = instance,
                ran = ran,
                reason = reason,
            }
        end)
        local callsWhenReturned = #calls
        trackDeferredCall(call)

        ctx:Expect(lockdown):ToBe(false)
        ctx:Expect(inCombat):ToBe(false)
        ctx:Expect(callsWhenReturned):ToBe(1)
        ctx:Expect(calls[1].count):ToBe(2)
        ctx:Expect(calls[1].instance == lifecycle):ToBe(true)
        ctx:Expect(calls[1].ran):ToBe(true)
        ctx:Expect(refusal):ToBeNil()
        if type(call) == "nil" then
            ctx:Fail("WhenOutOfCombat returned no call handle")
        end
        ---@cast call LifecycleKit.DeferredCall
        ctx:Expect(call:IsPending()):ToBe(false)
        ctx:Expect(call:Cancel()):ToBe(false)
    end
)

combatGate:Test(
    "SetCombatQueueLimit changes this addon's limit, including to UNBOUNDED, and GetCombatQueueLimit reads it back",
    function(ctx)
        local original = lifecycle:GetCombatQueueLimit()
        ctx:Log(
            "limit before the test: "
                .. (original == LifecycleKit.UNBOUNDED and "UNBOUNDED" or describeFact(original))
        )
        setQueueLimitForTest(3)
        ctx:Expect(lifecycle:GetCombatQueueLimit()):ToBe(3)
        lifecycle:SetCombatQueueLimit(LifecycleKit.UNBOUNDED)
        ctx:Expect(lifecycle:GetCombatQueueLimit() == LifecycleKit.UNBOUNDED):ToBe(true)
    end
)

-- lifecycleKit.capabilities -------------------------------------------------------------

local capabilities = newSuite("capabilities")

capabilities:Test(
    "CLOSES_ADDON_SCOPES names exactly the seven Kits shutdown closes, holds no keys of its own and refuses every write",
    function(ctx)
        local closes = LifecycleKit.CLOSES_ADDON_SCOPES
        for _, reader in ipairs(SCOPE_READERS) do
            ctx:Expect(closes[reader.id]):ToBe(true)
        end
        ctx:Expect(closes[PACKAGE_ID]):ToBeNil()
        ctx:Expect(closes.testKit):ToBeNil()
        ctx:Expect(next(closes)):ToBeNil()
        ctx:Expect(getmetatable(closes)):ToBe(false)

        -- The writes are the point: both must raise and change nothing.
        ---@type any
        local view = closes
        local addSucceeded, addMessage = pcall(function()
            view.mctProbe = true
        end)
        ctx:Log("adding a field raised: " .. describeFact(addMessage))
        ctx:Expect(addSucceeded):ToBe(false)
        local expectedAdd =
            'LifecycleKit.CLOSES_ADDON_SCOPES is read-only; field "mctProbe" cannot be written'
        ctx:Expect(tostring(addMessage):sub(-#expectedAdd)):ToBe(expectedAdd)

        local overwriteSucceeded, overwriteMessage = pcall(function()
            view.eventKit = false
        end)
        ctx:Expect(overwriteSucceeded):ToBe(false)
        local expectedOverwrite =
            'LifecycleKit.CLOSES_ADDON_SCOPES is read-only; field "eventKit" cannot be written'
        ctx:Expect(tostring(overwriteMessage):sub(-#expectedOverwrite)):ToBe(expectedOverwrite)

        ctx:Expect(closes.mctProbe):ToBeNil()
        ctx:Expect(closes.eventKit):ToBe(true)
    end
)

capabilities:Test(
    "every Kit CLOSES_ADDON_SCOPES names is loaded from the bundle at a version documented to read it",
    function(ctx)
        for _, reader in ipairs(SCOPE_READERS) do
            local expected = expectedPackage(ctx, reader.id)
            local implementation, revision = Registry:Get(reader.id, 1)
            ctx:Log(
                ("%s %s, revision %s loaded: reads CLOSES_ADDON_SCOPES from %s"):format(
                    reader.id,
                    expected.version,
                    describeFact(revision),
                    reader.readsFrom
                )
            )
            ctx:Expect(type(implementation)):ToBe("table")
            ctx:Expect(revision):ToBe(expected.revision)
            ctx:Expect(rawget(implementation or {}, "REVISION")):ToBe(expected.revision)
            ctx:Expect(isVersionAtLeast(expected.version, reader.readsFrom)):ToBe(true)
        end
    end
)

-- lifecycleKit.errors -------------------------------------------------------------------

local errors = newSuite("errors")

errors:Test("ForAddon with an empty name is refused at the calling line", function(ctx)
    local startLine = 0
    local line = expectErrorAtCallingLine(ctx, function()
        startLine = currentLine()
        LifecycleKit:ForAddon("")
    end, "LifecycleKit:ForAddon addonName must be a non-empty string")
    ctx:Expect(line):ToBe(startLine + 1)
end)

errors:Test(
    "OnReady with a callback that is not a function is refused at the calling line",
    function(ctx)
        -- The wrong argument type is the point of the test.
        ---@type any
        local notACallback = 42
        local startLine = 0
        local line = expectErrorAtCallingLine(ctx, function()
            startLine = currentLine()
            lifecycle:OnReady(notACallback)
        end, "LifecycleKit.Instance:OnReady callback must be a function")
        ctx:Expect(line):ToBe(startLine + 1)
    end
)

errors:Test(
    "Halt with an empty reason is refused at the calling line and halts nothing",
    function(ctx)
        local startLine = 0
        local line = expectErrorAtCallingLine(ctx, function()
            startLine = currentLine()
            lifecycle:Halt("")
        end, "LifecycleKit.Instance:Halt reason must be a non-empty string")
        ctx:Expect(line):ToBe(startLine + 1)
        ctx:Expect(lifecycle:IsHalted()):ToBe(false)
    end
)

errors:Test("DependsOn this addon's own name is refused at the calling line", function(ctx)
    local startLine = 0
    local line = expectErrorAtCallingLine(ctx, function()
        startLine = currentLine()
        lifecycle:DependsOn(addonName)
    end, "LifecycleKit.Instance:DependsOn addonName must name another addon")
    ctx:Expect(line):ToBe(startLine + 1)
end)

errors:Test(
    "SetCombatQueueLimit(0) is refused at the calling line and leaves the limit unchanged",
    function(ctx)
        local before = lifecycle:GetCombatQueueLimit()
        local startLine = 0
        local line = expectErrorAtCallingLine(
            ctx,
            function()
                startLine = currentLine()
                lifecycle:SetCombatQueueLimit(0)
            end,
            "LifecycleKit.Instance:SetCombatQueueLimit limit must be a positive integer or LifecycleKit.UNBOUNDED"
        )
        ctx:Expect(line):ToBe(startLine + 1)
        ctx:Expect(lifecycle:GetCombatQueueLimit() == before):ToBe(true)
    end
)

errors:Test(
    "SetLimits with a limit LifecycleKit does not know is refused at the calling line and changes nothing",
    function(ctx)
        local before = LifecycleKit:GetLimits()
        local startLine = 0
        local line = expectErrorAtCallingLine(ctx, function()
            startLine = currentLine()
            LifecycleKit:SetLimits({ mctNoSuchLimit = 1 })
        end, "LifecycleKit:SetLimits limits.mctNoSuchLimit is not a recognised limit")
        ctx:Expect(line):ToBe(startLine + 1)
        ctx:Expect(LifecycleKit:GetLimits()):ToEqual(before)
    end
)

errors:Test("GetLimits called with a dot is refused at the calling line", function(ctx)
    -- The missing receiver is the point of the test.
    ---@type any
    local getLimits = LifecycleKit.GetLimits
    local startLine = 0
    local line = expectErrorAtCallingLine(
        ctx,
        function()
            startLine = currentLine()
            getLimits()
        end,
        "LifecycleKit:GetLimits must be called on the LifecycleKit facade; use LifecycleKit:GetLimits()"
    )
    ctx:Expect(line):ToBe(startLine + 1)
end)

-- lifecycleKit.secrets ------------------------------------------------------------------

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
        ctx:Fail(
            "secretwrap raised, so the secret path was not exercised: " .. describeFact(secret)
        )
    end
    if not isSecret(secret) then
        ctx:Fail("secretwrap returned a value issecretvalue does not report as secret")
    end
    return secret
end

secretTest("ForAddon with a secret name is refused at the calling line", function(ctx)
    local secretName = makeSecret(ctx, addonName)
    local startLine = 0
    local line = expectErrorAtCallingLine(ctx, function()
        startLine = currentLine()
        LifecycleKit:ForAddon(secretName)
    end, "LifecycleKit:ForAddon addonName must not be a secret value")
    ctx:Expect(line):ToBe(startLine + 1)
end)

secretTest(
    "Halt with a secret reason is refused at the calling line and halts nothing",
    function(ctx)
        local secretReason = makeSecret(ctx, "mctLifecycleKit secret reason")
        local startLine = 0
        local line = expectErrorAtCallingLine(ctx, function()
            startLine = currentLine()
            lifecycle:Halt(secretReason)
        end, "LifecycleKit.Instance:Halt reason must not be a secret value")
        ctx:Expect(line):ToBe(startLine + 1)
        ctx:Expect(lifecycle:IsHalted()):ToBe(false)
    end
)

secretTest("DependsOn with a secret addon name is refused at the calling line", function(ctx)
    local secretName = makeSecret(ctx, HARNESS_ADDON)
    local startLine = 0
    local line = expectErrorAtCallingLine(ctx, function()
        startLine = currentLine()
        lifecycle:DependsOn(secretName)
    end, "LifecycleKit.Instance:DependsOn addonName must not be a secret value")
    ctx:Expect(line):ToBe(startLine + 1)
end)

secretTest(
    "SetCombatQueueLimit with a secret limit is refused at the calling line and leaves the limit unchanged",
    function(ctx)
        local before = lifecycle:GetCombatQueueLimit()
        local secretLimit = makeSecret(ctx, 8)
        local startLine = 0
        local line = expectErrorAtCallingLine(ctx, function()
            startLine = currentLine()
            lifecycle:SetCombatQueueLimit(secretLimit)
        end, "LifecycleKit.Instance:SetCombatQueueLimit limit must not be a secret value")
        ctx:Expect(line):ToBe(startLine + 1)
        ctx:Expect(lifecycle:GetCombatQueueLimit() == before):ToBe(true)
    end
)

secretTest(
    "SetLimits with a secret maxDependencies is refused at the calling line and changes nothing",
    function(ctx)
        local before = LifecycleKit:GetLimits()
        local secretLimit = makeSecret(ctx, 32)
        local startLine = 0
        local line = expectErrorAtCallingLine(ctx, function()
            startLine = currentLine()
            LifecycleKit:SetLimits({ maxDependencies = secretLimit })
        end, "LifecycleKit:SetLimits limits.maxDependencies must not be a secret value")
        ctx:Expect(line):ToBe(startLine + 1)
        ctx:Expect(LifecycleKit:GetLimits()):ToEqual(before)
    end
)

-- lifecycleKit.shutdown -----------------------------------------------------------------

local shutdown = newSuite("shutdown")

shutdown:Skip(
    "at logout the Kit reaches shutdown and closes this addon's scopes after its OnShutdown callbacks",
    "not observable in a run: PLAYER_LOGOUT ends the session before a result could be printed or saved; packages/lifecycleKit/tests/OwnedScopes_spec.lua proves it"
)

-- lifecycleKit.combatDeferral -----------------------------------------------------------
--
-- Passive and optional: it changes nothing in the world and only reads the
-- combat the owner is already in. EXPECTED.md, "Optional: the training-dummy
-- run", says how to be in combat when the run starts.

local combatDeferral = newSuite("combatDeferral", { timeoutSeconds = COMBAT_SUITE_TIMEOUT_SECONDS })

combatDeferral:Test(
    "in combat, WhenOutOfCombat queues the call, refuses one past the limit, and runs it at PLAYER_REGEN_ENABLED before OnCombatEnd",
    function(ctx)
        local lockdown = readCombatLockdown()
        local inCombat = LifecycleKit:IsInCombat()
        ctx:Log("InCombatLockdown() answered " .. describeFact(lockdown))
        ctx:Log("LifecycleKit:IsInCombat() answered " .. describeFact(inCombat))
        if lockdown ~= true and not inCombat then
            Harness:SkipTest(
                ctx,
                "not in combat; to exercise it, attack a training dummy and type /mct run lifecycleKit (EXPECTED.md)"
            )
            return
        end
        ctx:Expect(lockdown):ToBe(true)
        ctx:Expect(inCombat):ToBe(true)

        local order = {}
        local runs = {}
        setQueueLimitForTest(1)
        local call, refusal = lifecycle:WhenOutOfCombat(function(instance, ran, reason)
            order[#order + 1] = "deferred call"
            runs[#runs + 1] = {
                instance = instance,
                ran = ran,
                reason = reason,
                lockdown = readCombatLockdown(),
                inCombat = LifecycleKit:IsInCombat(),
            }
        end)
        trackDeferredCall(call)
        if type(call) == "nil" then
            ctx:Fail("WhenOutOfCombat refused the call in combat: " .. describeFact(refusal))
        end
        ---@cast call LifecycleKit.DeferredCall
        ctx:Expect(#runs):ToBe(0)
        ctx:Expect(call:IsPending()):ToBe(true)

        local overflow, overflowReason = lifecycle:WhenOutOfCombat(ignore)
        trackDeferredCall(overflow)
        ctx:Expect(overflow):ToBeNil()
        ctx:Expect(overflowReason):ToBe("full")

        track(lifecycle:OnCombatEnd(function()
            order[#order + 1] = "OnCombatEnd"
        end))
        trackConnection(EventKit:Once("PLAYER_REGEN_ENABLED", function()
            order[#order + 1] = "PLAYER_REGEN_ENABLED listener"
        end))

        local ended = waitUntil(ctx, function()
            return #runs > 0
        end, COMBAT_END_TIMEOUT_SECONDS)
        if not ended then
            ctx:Fail(
                ("combat did not end within %d seconds; stop attacking right after typing the command"):format(
                    COMBAT_END_TIMEOUT_SECONDS
                )
            )
        end

        local run = runs[1]
        ctx:Log(
            "inside the deferred call, InCombatLockdown() answered " .. describeFact(run.lockdown)
        )
        ctx:Log("order: " .. table.concat(order, ", "))
        ctx:Expect(#runs):ToBe(1)
        ctx:Expect(run.instance == lifecycle):ToBe(true)
        ctx:Expect(run.ran):ToBe(true)
        ctx:Expect(run.reason):ToBeNil()
        ctx:Expect(run.lockdown):ToBe(false)
        ctx:Expect(run.inCombat):ToBe(false)
        ctx:Expect(call:IsPending()):ToBe(false)
        ctx:Expect(order)
            :ToEqual({ "deferred call", "OnCombatEnd", "PLAYER_REGEN_ENABLED listener" })
    end
)
