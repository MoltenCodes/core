-- MoltenCodes Test: HookKitSuite.lua
--
-- Real-client suites for the `hookKit` package. The Busted specs under
-- packages/hookKit/tests/ prove HookKit against stubs of `hooksecurefunc`,
-- `issecurevariable` and frames; these prove, inside the game client with the
-- installed MoltenCodes addon, what those stubs can only simulate:
--
--   * the installed facade and its committed revision;
--   * `SecureHook` through the client's real `hooksecurefunc` on one harmless
--     Blizzard global, `IsLinuxClient` on Retail and `IsDebugBuild` on the
--     Classic clients (see "The Blizzard global" below), and
--     that the client's own `issecurevariable` still reports that global
--     secure after the hook and after `Unhook`, which leaves the client's
--     wrapper in place because a secure hook cannot be removed, only silenced;
--   * that `Hook` and `RawHook` of that global are refused at the calling line
--     and write nothing, so the global is never tainted;
--   * `SecureHook` of a method of a table this file owns: the receiver and
--     every argument reach the handler, the caller gets the original's results
--     unchanged, and a raising handler is reported to the client's error
--     handler while the call still returns;
--   * `SecureHookScript`, `HookScript` and `RawHookScript` on hidden 1x1 test
--     frames driven by `Show` and `Hide`; the client's own `Frame:HookScript`
--     answer (Retail documents a `success` boolean, the Classic clients no
--     return value; HookKit discards it either way);
--     what HookKit does when the client declines a `HookScript`; whether the
--     client's `SetScript` drops `HookScript` post-hooks, which is why HookKit
--     refuses a script pre-hook after a post-hook;
--   * the secure-target check on a method a real frame inherits from the
--     client's widget method table, the protected-frame refusals on a secure
--     action button this file creates, and the `IsForbidden` and
--     `CanBeAccessedInContext` answers of a test frame (the Classic clients
--     have no `CanBeAccessedInContext`; only `IsForbidden` is asked there);
--   * in a combat run (`/mct run hookKit combat`), the refusal of a forced
--     script hook of that secure button during combat lockdown;
--   * `Unhook`, `UnhookAll`, `Close` and `ForAddon`, and a scope's limit;
--   * that a hooked call and the lookups allocate nothing, measured with the
--     client's own garbage collector;
--   * argument errors, and the refusal of genuine secret values made by
--     `secretwrap`, pointing at this file as the client names it, and secret
--     arguments passing through the hooks untouched.
--
-- Run with `/mct run hookKit`, and the combat suite with `/mct run hookKit
-- combat`; tests/client/MoltenCodesTest_HookKit/EXPECTED.md lists what the
-- chat frame should show.
--
-- The Blizzard global. The one Blizzard function this file post-hooks is a C
-- function of the Build system (BuildDocumentation.lua in
-- packages/apiKit/metadata/<flavour>/namespaces.json) that takes no argument,
-- answers one boolean, has no side effect, carries no restriction flag,
-- returns no secret, and has nothing to do with combat, units, actions or
-- protected frames: `IsLinuxClient` on Retail, which the Retail interface code
-- has no reason to call on a Windows or macOS client, so the inert closure the
-- hook leaves behind is almost never even reached. The Classic Era and Mists
-- Classic metadata document no `IsLinuxClient`, so on those clients the same
-- role goes to `IsDebugBuild`, which all three flavours document with the same
-- shape (no argument, one boolean). It is hooked only with `SecureHook`,
-- which goes through `hooksecurefunc` and keeps the global secure; the tests
-- that ask HookKit for a non-secure hook of it expect a refusal, and run only
-- while `issecurevariable` reports the global secure, which is exactly when
-- HookKit refuses. No other Blizzard function, method or script is hooked,
-- and nothing protected is hooked: the protected-frame refusals are asked of a
-- secure action button this file creates, which has no action, no size and is
-- never shown.
--
-- What a run leaves behind. Every scope a test creates is closed by its
-- suite's After hook, pass or fail, which silences every hook and writes back
-- every original HookKit may restore. What the client keeps for the session,
-- because a secure hook cannot be removed, is documented in EXPECTED.md: per
-- run, two inert closures in the `hooksecurefunc` chain of that global,
-- and inert or no-op closures in the `HookScript` chains of this file's own
-- test frames. The test frames themselves (plain 1x1 frames at alpha 0, never
-- visible, and one hidden secure action button) stay, because the client never
-- frees a frame; they are created once and reused by later runs. This addon's
-- own HookKit scope (`HookKit:ForAddon("MoltenCodesTest_HookKit")`) stays
-- open and empty until logout. The client's error handler is replaced only for
-- the length of one hooked call and put back at once. Nothing is written to a
-- global, a saved variable or a CVar.

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
local HOOK_KIT_API = 1
local PACKAGE_ID = "hookKit"

--- The one Blizzard global this file post-hooks on each apiKit flavour; see
--- "The Blizzard global" in the header for why it is harmless. Only the Retail
--- metadata documents `IsLinuxClient`; `IsDebugBuild` is documented on all
--- three flavours with the same shape.
local BLIZZARD_GLOBAL_BY_FLAVOUR = {
  retail = "IsLinuxClient",
  ["classic-era"] = "IsDebugBuild",
  ["classic-mop"] = "IsDebugBuild",
}

--- The Blizzard global this run post-hooks: the running flavour's, or the
--- Retail one on a client the harness does not recognise.
local BLIZZARD_GLOBAL = BLIZZARD_GLOBAL_BY_FLAVOUR[Harness:GetFlavour() or "retail"]
  or BLIZZARD_GLOBAL_BY_FLAVOUR.retail

--- A global name no client defines, for the secret global-name refusal.
local ABSENT_GLOBAL = "MoltenCodesTestHookKitNoSuchGlobal"

--- The default `maxHooks` docs/API.md names.
local DOCUMENTED_MAX_HOOKS = 256

--- A script a plain Frame does not have (sliders and status bars do).
local SCRIPT_A_FRAME_LACKS = "OnValueChanged"

--- How many calls each allocation guard makes, and how many lookup rounds.
--- One table or closure per call would cost well over a hundred kilobytes.
local HOOKED_CALLS = 10000
local LOOKUP_ROUNDS = 5000

--- Kilobytes an allocation guard tolerates. The tolerance absorbs a stray
--- allocation by the client between the two readings, not a per-call one.
local ALLOCATION_TOLERANCE_KB = 1

--- Text a deliberately failing handler raises, so a test can recognise it.
local HANDLER_FAILURE = "mctHookKit deliberate handler failure"

--- Why a test that needs the client's error handler could not observe it.
local HANDLER_KEPT_REASON =
  "the client's error handler could not be replaced (an error-capturing addon such as BugGrabber keeps it); the failure went to that addon"

--- Why the tests that touch the Blizzard global or the secure button wait for
--- the end of combat.
local IN_COMBAT_REASON =
  "the player is in combat; this test touches a Blizzard global or a protected frame only out of combat"

--- Why the combat suite's test is skipped out of combat.
local NOT_IN_COMBAT_REASON =
  "the player is not in combat; type /mct run hookKit combat and attack a training dummy to run it"

--- Why the combat suite's test is skipped when the secure button does not exist.
local NO_SECURE_BUTTON_REASON =
  "the secure button is created out of combat; type /mct run hookKit combat out of combat so its preparation creates it"

--- Every facade method docs/API.md lists.
local FACADE_METHODS = { "CreateScope", "ForAddon", "CloseAddonScopes" }

--- Every scope method docs/API.md lists.
local SCOPE_METHODS = {
  "SecureHook",
  "SecureHookScript",
  "Hook",
  "RawHook",
  "HookScript",
  "RawHookScript",
  "Unhook",
  "UnhookAll",
  "IsHooked",
  "Original",
  "Hooks",
  "Close",
  "IsClosed",
  "GetActiveCount",
  "GetAddonName",
  "GetMaxHooks",
}

-- Client types ------------------------------------------------------------------------

-- The language-server stubs in meta/ declare only what the framework packages
-- call on a Frame, so the part of the client's Frame API this file calls is
-- declared here.

---The part of a World of Warcraft Frame this file calls.
---@class MoltenCodesTest.HookKit.Frame
---@field Show fun(self: MoltenCodesTest.HookKit.Frame)
---@field Hide fun(self: MoltenCodesTest.HookKit.Frame)
---@field IsVisible fun(self: MoltenCodesTest.HookKit.Frame): boolean
---@field SetSize fun(self: MoltenCodesTest.HookKit.Frame, width: number, height: number)
---@field SetAlpha fun(self: MoltenCodesTest.HookKit.Frame, alpha: number)
---@field GetScript fun(self: MoltenCodesTest.HookKit.Frame, script: string): function|nil
---@field SetScript fun(self: MoltenCodesTest.HookKit.Frame, script: string, handler: function|nil)
---@field HookScript fun(self: MoltenCodesTest.HookKit.Frame, script: string, handler: function): boolean|nil
---@field IsForbidden fun(self: MoltenCodesTest.HookKit.Frame): boolean
---@field CanBeAccessedInContext (fun(self: MoltenCodesTest.HookKit.Frame): boolean)|nil
---@field IsProtected fun(self: MoltenCodesTest.HookKit.Frame): boolean, boolean

-- Resolving the client and the framework ------------------------------------------------

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- Hook, security, frame, error-handler and secret-value functions are
  -- World of Warcraft client globals, reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, REGISTRY_API)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- tests/client/.luarc.json does not list HookKit's source, so the facade is
-- typed loosely here; docs/API.md is its contract.
---@type any
local HookKit = Registry:Get(PACKAGE_ID, HOOK_KIT_API)
if type(HookKit) == "nil" then
  error(addonName .. " requires HookKit API 1 in the MoltenCodes addon; reinstall it", 0)
end

local createFrame = readHost("CreateFrame")
if type(createFrame) ~= "function" then
  error(addonName .. " requires the client's CreateFrame", 0)
end

--- The client functions the secure-hook tests need, read once at load: those
--- tests are registered as skipped when one is missing.
local hookSecureFunc = readHost("hooksecurefunc")
local isSecureVariable = readHost("issecurevariable")
local HOOK_API_AVAILABLE = type(hookSecureFunc) == "function"
  and type(isSecureVariable) == "function"
local HOOK_API_SKIP_REASON =
  "the client has no hooksecurefunc or issecurevariable; the secure-hook path was not exercised"

--- Whether the client has the Blizzard global the `secureGlobal` tests hook.
local BLIZZARD_GLOBAL_AVAILABLE = type(readHost(BLIZZARD_GLOBAL)) == "function"
local BLIZZARD_GLOBAL_SKIP_REASON = "the client has no "
  .. BLIZZARD_GLOBAL
  .. "; the secure-global path was not exercised"

--- The two client functions the secrets suite needs.
local isSecretValue = readHost("issecretvalue")
local secretWrap = readHost("secretwrap")
local SECRETS_AVAILABLE = type(isSecretValue) == "function" and type(secretWrap) == "function"

-- Test frames -----------------------------------------------------------------------------

--- Plain test frames by purpose, created once and reused by later runs,
--- because the client never frees a frame.
---@type table<string, MoltenCodesTest.HookKit.Frame>
local plainFrames = {}

--- The secure action button the protected-frame tests ask about, created once,
--- out of combat, on first use.
---@type MoltenCodesTest.HookKit.Frame|nil
local secureButton = nil

---The plain test frame for `purpose`: parentless, 1x1, alpha 0, no texture,
---hidden. A parentless frame becomes visible on `Show`, so its `OnShow` and
---`OnHide` run even while the interface is hidden (Alt+Z), yet nothing is
---drawn.
---@param purpose string
---@return MoltenCodesTest.HookKit.Frame
local function plainFrame(purpose)
  local frame = plainFrames[purpose]
  if frame == nil then
    frame = createFrame("Frame")
    frame:SetSize(1, 1)
    frame:SetAlpha(0)
    plainFrames[purpose] = frame
  end
  frame:Hide()
  return frame
end

---The test's secure action button, or `nil` in combat before it exists.
---
---`SecureActionButtonTemplate` inherits `SecureFrameTemplate`, so the button is
---protected. It has no attribute, so it has no action; it has no size and is
---hidden, so it can be neither seen nor clicked. It is only ever asked for a
---hook that HookKit must refuse.
---@return MoltenCodesTest.HookKit.Frame|nil
local function protectedButton()
  if secureButton == nil then
    local inCombatLockdown = readHost("InCombatLockdown")
    if type(inCombatLockdown) == "function" and inCombatLockdown() then
      return nil
    end
    local button = createFrame("Button", nil, nil, "SecureActionButtonTemplate")
    button:Hide()
    secureButton = button
  end
  return secureButton
end

-- Helpers ---------------------------------------------------------------------------------

--- Scopes created by the running test; the After hook closes them.
---@type any[]
local trackedScopes = {}

--- Puts the client's error handler back, while a test has it replaced.
---@type fun()|nil
local restoreHandler = nil

---Create a manual HookKit scope and remember it for the After hook.
---@param options table|nil
---@return any scope
local function newScope(options)
  local scope = HookKit:CreateScope(options)
  trackedScopes[#trackedScopes + 1] = scope
  return scope
end

---Put back the client's error handler if a test replaced it.
local function restoreErrorHandler()
  local restore = restoreHandler
  restoreHandler = nil
  if restore ~= nil then
    restore()
  end
end

---Close every scope the running test created, newest first, then clear the
---scripts the tests set on the plain frames and hide them. The After hook of
---every suite; a failure in one close does not stop the others.
local function releaseEverything()
  restoreErrorHandler()
  for index = #trackedScopes, 1, -1 do
    local scope = trackedScopes[index]
    trackedScopes[index] = nil
    pcall(scope.Close, scope)
  end
  for _, frame in pairs(plainFrames) do
    frame:SetScript("OnShow", nil)
    frame:SetScript("OnHide", nil)
    frame:Hide()
  end
end

---Register a suite of this package whose tests all end with every scope closed.
---@param part string
---@param options MoltenCodesTest.SuiteOptions|nil
---@return TestKit.Suite
local function newSuite(part, options)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName, options)
  suite:After(releaseEverything)
  return suite
end

---End the running test as skipped while the player is in combat.
---@param ctx TestKit.Context
local function requireOutOfCombat(ctx)
  local inCombatLockdown = readHost("InCombatLockdown")
  if type(inCombatLockdown) == "function" and inCombatLockdown() then
    Harness:SkipTest(ctx, IN_COMBAT_REASON)
  end
end

---End the running test as skipped unless the client reports the Blizzard
---global secure right now. Taint of a global lasts for the session, so a
---global reported secure now was secure whenever HookKit asked before, which
---is exactly when HookKit refuses a non-secure hook of it.
---@param ctx TestKit.Context
local function requireSecureBlizzardGlobal(ctx)
  local secure = isSecureVariable(BLIZZARD_GLOBAL)
  ctx:Log("issecurevariable(" .. BLIZZARD_GLOBAL .. ") before the test: " .. tostring(secure))
  if secure ~= true then
    Harness:SkipTest(
      ctx,
      BLIZZARD_GLOBAL
        .. " is already tainted in this session (by another addon); /reload and run again"
    )
  end
end

---A table this file owns, with the methods the table tests hook.
---@return table
local function newProbeTable()
  local probe = {}

  ---Answer how many arguments came, then the arguments themselves.
  ---@param ... any
  ---@return integer count
  ---@return any ...
  function probe.Combine(_, ...)
    return select("#", ...), ...
  end

  ---Answer `value` with a prefix.
  ---@param value string
  ---@return string
  function probe.Format(_, value)
    return "formatted:" .. value
  end

  ---Answer `value` itself, untouched.
  ---@param value any
  ---@return any
  function probe.Echo(_, value)
    return value
  end

  return probe
end

---Pack a call's results with their count.
---@param ... any
---@return { count: integer, values: any[] }
local function pack(...)
  return { count = select("#", ...), values = { ... } }
end

---A no-op handler.
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
  ctx:Expect((file or ""):sub(-#"HookKitSuite.lua")):ToBe("HookKitSuite.lua")
  return line
end

---Call `raise`, which must record its start line with `currentLine()` and
---raise on the next line, and check the message names this file at that line
---and ends with `expected`.
---@param ctx TestKit.Context
---@param raise fun() Records its start line with `currentLine()`, then raises on the next line.
---@param expected string The message after the position, compared literally.
---@param startLine fun(): integer Reads the line `raise` recorded.
local function expectErrorAtCallingLine(ctx, raise, expected, startLine)
  local succeeded, message = pcall(raise)
  ctx:Expect(succeeded):ToBe(false)
  ctx:Log("client message: " .. tostring(message))
  local line = expectThisFile(ctx, message)
  ctx:Expect(tostring(message):sub(-#expected)):ToBe(expected)
  ctx:Expect(line):ToBe(startLine() + 1)
end

---Run `action`, which must not yield, with HookKit's handler failures reported
---to a collector instead of the client's error handler, and put the handler
---back before returning.
---
---HookKit reports a handler failure to `geterrorhandler()`, which on the
---Retail client reads the handler `seterrorhandler` installed. Replacing the
---global `geterrorhandler` would taint a global Blizzard code calls, so the
---handler is swapped with `seterrorhandler` for the call instead
---(tests/client/README.md, "Catching an error a Kit reports instead of raising").
---@param ctx TestKit.Context
---@param action fun()
---@return any[] reported every value the collector received, in order
---@return boolean observed whether the collector was the handler HookKit reported to
local function collectReportedErrors(ctx, action)
  local reported = {}
  ---@param message any
  local function collector(message)
    reported[#reported + 1] = message
  end

  local observed = false
  local setErrorHandler = readHost("seterrorhandler")
  local getErrorHandler = readHost("geterrorhandler")
  if type(setErrorHandler) == "function" and type(getErrorHandler) == "function" then
    local previous = getErrorHandler()
    setErrorHandler(collector)
    -- An error-capturing addon (BugGrabber) may refuse the swap.
    observed = getErrorHandler() == collector
    restoreHandler = function()
      setErrorHandler(previous)
    end
  else
    -- Outside the Retail client HookKit asks the global on every report;
    -- TestKit puts it back when the test ends.
    -- selene: allow(global_usage)
    ctx:Replace(_G, "geterrorhandler", function()
      return collector
    end)
    observed = true
  end

  local succeeded, problem = pcall(action)
  restoreErrorHandler()
  if not succeeded then
    error(problem, 0)
  end
  return reported, observed
end

---Measure how many kilobytes `work` grows the Lua heap by.
---@param work fun()
---@return number grownKilobytes
local function measureAllocation(work)
  local before = collectgarbage("count")
  work()
  return collectgarbage("count") - before
end

---Run a full collection in a step of its own, so the measurement that follows
---starts far from the next collector cycle, which would otherwise shrink the
---count mid-measurement and hide an allocation.
---@param ctx TestKit.Context
local function collectBeforeMeasuring(ctx)
  collectgarbage("collect")
  ctx:Yield()
end

-- hookKit.facade ----------------------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('hookKit', 1) is the HookKit facade with API 1, every documented method, MAX_HOOKS 256 and UNBOUNDED",
  function(ctx)
    ctx:Expect(type(HookKit)):ToBe("table")
    ctx:Expect(rawget(HookKit, "API")):ToBe(HOOK_KIT_API)
    for _, method in ipairs(FACADE_METHODS) do
      ctx:Expect(type(HookKit[method])):ToBe("function")
    end
    ctx:Expect(HookKit.MAX_HOOKS):ToBe(DOCUMENTED_MAX_HOOKS)
    ctx:Expect(type(HookKit.UNBOUNDED)):ToBe("table")
    ctx:Expect(type(HookKit.Scope)):ToBe("table")
    for _, method in ipairs(SCOPE_METHODS) do
      ctx:Expect(type(HookKit.Scope[method])):ToBe("function")
    end
  end
)

facade:Test("the installed HookKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      local _, revision = Registry:Get(PACKAGE_ID, HOOK_KIT_API)
      ctx:Expect(revision):ToBe(expected.revision)
      ctx:Expect(rawget(HookKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list hookKit")
end)

-- hookKit.secureGlobal ------------------------------------------------------------------------

local secureGlobal = newSuite("secureGlobal")

---Register `body` as a test when the client has the secure-hook functions and
---the Blizzard global, and as a skipped test naming why otherwise.
---@param name string
---@param body fun(ctx: TestKit.Context)
local function secureGlobalTest(name, body)
  if not HOOK_API_AVAILABLE then
    secureGlobal:Skip(name, HOOK_API_SKIP_REASON)
  elseif not BLIZZARD_GLOBAL_AVAILABLE then
    secureGlobal:Skip(name, BLIZZARD_GLOBAL_SKIP_REASON)
  else
    secureGlobal:Test(name, body)
  end
end

secureGlobalTest(
  "SecureHook of the Blizzard global "
    .. BLIZZARD_GLOBAL
    .. " runs the handler once per call with no argument, the caller gets the original answer, and issecurevariable still reports the global secure",
  function(ctx)
    requireOutOfCombat(ctx)
    requireSecureBlizzardGlobal(ctx)
    local before = readHost(BLIZZARD_GLOBAL)
    local originalAnswer = pack(before())

    local scope = newScope()
    local calls = 0
    local argumentCount = -1
    local handlerSecure = nil
    local installed = scope:SecureHook(BLIZZARD_GLOBAL, function(...)
      calls = calls + 1
      argumentCount = select("#", ...)
      local isSecure = readHost("issecure")
      if type(isSecure) == "function" then
        handlerSecure = isSecure()
      end
    end)
    ctx:Expect(installed):ToBe(true)

    local wrapper = readHost(BLIZZARD_GLOBAL)
    ctx:Log(
      "hooksecurefunc replaced the global with a new function: "
        .. tostring(not rawequal(wrapper, before))
    )
    local hookedAnswer = pack(wrapper())
    ctx:Log("issecure() inside the post-hook handler: " .. tostring(handlerSecure))

    ctx:Expect(hookedAnswer):ToEqual(originalAnswer)
    ctx:Expect(calls):ToBe(1)
    ctx:Expect(argumentCount):ToBe(0)
    ctx:Expect(nil):ToBeSecure(nil, BLIZZARD_GLOBAL)
    local hooked, kind = scope:IsHooked(BLIZZARD_GLOBAL)
    ctx:Expect(hooked):ToBe(true)
    ctx:Expect(kind):ToBe("secure")
    ctx:Expect(scope:Original(BLIZZARD_GLOBAL)):ToBeNil()
  end
)

secureGlobalTest(
  "Unhook of that secure post-hook silences the handler but leaves the client's hooksecurefunc wrapper installed and the global secure (a secure hook cannot be removed)",
  function(ctx)
    requireOutOfCombat(ctx)
    requireSecureBlizzardGlobal(ctx)
    local scope = newScope()
    local calls = 0
    scope:SecureHook(BLIZZARD_GLOBAL, function()
      calls = calls + 1
    end)
    local wrapper = readHost(BLIZZARD_GLOBAL)
    wrapper()
    ctx:Expect(calls):ToBe(1)

    ctx:Expect(scope:Unhook(BLIZZARD_GLOBAL)):ToBe(true)
    -- HookKit wrote nothing back: a write from addon code would taint it.
    ctx:Expect(readHost(BLIZZARD_GLOBAL)):ToBe(wrapper)
    ctx:Expect(nil):ToBeSecure(nil, BLIZZARD_GLOBAL)
    wrapper()
    ctx:Expect(calls):ToBe(1)
    ctx:Expect(scope:IsHooked(BLIZZARD_GLOBAL)):ToBe(false)
    ctx:Expect(scope:Unhook(BLIZZARD_GLOBAL)):ToBe(false)
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
  end
)

secureGlobalTest(
  "Hook and RawHook of the secure Blizzard global "
    .. BLIZZARD_GLOBAL
    .. " are refused at the calling line, write nothing and leave the global secure",
  function(ctx)
    requireOutOfCombat(ctx)
    requireSecureBlizzardGlobal(ctx)
    local current = readHost(BLIZZARD_GLOBAL)
    local scope = newScope()

    local startLine = 0
    expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        scope:Hook(BLIZZARD_GLOBAL, ignore)
      end,
      'HookKit.Scope:Hook refuses to hook secure "'
        .. BLIZZARD_GLOBAL
        .. '" non-securely; use SecureHook, or pass options.forceSecure',
      function()
        return startLine
      end
    )
    expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        scope:RawHook(BLIZZARD_GLOBAL, ignore)
      end,
      'HookKit.Scope:RawHook refuses to hook secure "'
        .. BLIZZARD_GLOBAL
        .. '" non-securely; use SecureHook, or pass options.forceSecure',
      function()
        return startLine
      end
    )

    ctx:Expect(readHost(BLIZZARD_GLOBAL)):ToBe(current)
    ctx:Expect(nil):ToBeSecure(nil, BLIZZARD_GLOBAL)
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
  end
)

-- hookKit.secureMethod ------------------------------------------------------------------------

local secureMethod = newSuite("secureMethod")

---Register `body` as a test when the client has `hooksecurefunc`.
---@param name string
---@param body fun(ctx: TestKit.Context)
local function secureMethodTest(name, body)
  if HOOK_API_AVAILABLE then
    secureMethod:Test(name, body)
  else
    secureMethod:Skip(name, HOOK_API_SKIP_REASON)
  end
end

secureMethodTest(
  "SecureHook of a method of a test-owned table passes the receiver and every argument, explicit nils included, and the caller gets the original's results unchanged",
  function(ctx)
    local probe = newProbeTable()
    local scope = newScope()
    local received = nil
    ctx
      :Expect(scope:SecureHook(probe, "Combine", function(...)
        received = pack(...)
      end))
      :ToBe(true)

    local results = pack(probe:Combine(1, nil, "x", nil))
    ctx:Expect(results):ToEqual({ count = 5, values = { 4, 1, nil, "x", nil } })
    ctx:Expect(type(received)):ToBe("table")
    ---@cast received { count: integer, values: any[] }
    ctx:Expect(received.count):ToBe(5)
    ctx:Expect(received.values[1]):ToBe(probe)
    ctx:Expect(received.values[2]):ToBe(1)
    ctx:Expect(received.values[3]):ToBeNil()
    ctx:Expect(received.values[4]):ToBe("x")
    ctx:Expect(received.values[5]):ToBeNil()
  end
)

secureMethodTest(
  "a raising secure post-hook handler is reported once to the client's error handler, naming HookKitSuite.lua at the raising line, and the caller still gets the original's results",
  function(ctx)
    local probe = newProbeTable()
    local scope = newScope()
    local failingLine = 0
    scope:SecureHook(probe, "Combine", function()
      failingLine = currentLine()
      error(HANDLER_FAILURE)
    end)

    local results = nil
    local reported, observed = collectReportedErrors(ctx, function()
      results = pack(probe:Combine(7))
    end)
    ctx:Expect(results):ToEqual({ count = 2, values = { 1, 7 } })
    if not observed then
      ctx:Fail(HANDLER_KEPT_REASON)
      return
    end
    ctx:Expect(#reported):ToBe(1)
    ctx:Log("reported: " .. tostring(reported[1]))
    local line = expectThisFile(ctx, reported[1])
    ctx:Expect(line):ToBe(failingLine + 1)
    ctx:Expect(tostring(reported[1]):sub(-#HANDLER_FAILURE)):ToBe(HANDLER_FAILURE)
  end
)

-- hookKit.scripts -----------------------------------------------------------------------------

local scripts = newSuite("scripts")

scripts:Test(
  "SecureHookScript runs OnShow and OnHide handlers with the frame when a hidden 1x1 test frame is shown and hidden, and Unhook silences them",
  function(ctx)
    local frame = plainFrame("secureScripts")
    local scope = newScope()
    local seen = {}
    local shownFrame = nil
    ctx
      :Expect(scope:SecureHookScript(frame, "OnShow", function(received)
        seen[#seen + 1] = "show"
        shownFrame = received
      end))
      :ToBe(true)
    ctx
      :Expect(scope:SecureHookScript(frame, "OnHide", function()
        seen[#seen + 1] = "hide"
      end))
      :ToBe(true)

    frame:Show()
    ctx:Log("the frame is visible after Show: " .. tostring(frame:IsVisible()))
    frame:Hide()
    ctx:Expect(seen):ToEqual({ "show", "hide" })
    ctx:Expect(shownFrame):ToBe(frame)

    ctx:Expect(scope:Unhook(frame, "OnShow")):ToBe(true)
    ctx:Expect(scope:Unhook(frame, "OnHide")):ToBe(true)
    frame:Show()
    frame:Hide()
    ctx:Expect(seen):ToEqual({ "show", "hide" })
  end
)

--- What the client documents `Frame:HookScript` to return, per apiKit flavour
--- (SimpleScriptRegionAPIDocumentation in
--- packages/apiKit/metadata/<flavour>/namespaces.json): Retail a `success`
--- boolean, the Classic clients no value.
local HOOK_SCRIPT_ANSWERS_SUCCESS = Harness:GetFlavour() ~= "classic-era"
  and Harness:GetFlavour() ~= "classic-mop"

--- The name of the `Frame:HookScript` answer test, which states the answer
--- the running flavour documents.
local HOOK_SCRIPT_ANSWER_TEST = HOOK_SCRIPT_ANSWERS_SUCCESS
    and "the client's own Frame:HookScript answers true for OnShow on a test-owned frame (HookKit discards this answer; it is logged)"
  or "the client's own Frame:HookScript answers no value for OnShow on a test-owned frame, as the Classic documentation says (HookKit discards any answer; it is logged)"

scripts:Test(HOOK_SCRIPT_ANSWER_TEST, function(ctx)
  local frame = plainFrame("hookScriptAnswer")
  local succeeded, answer = pcall(function()
    return pack(frame:HookScript("OnShow", ignore))
  end)
  ctx:Log("HookScript raised: " .. tostring(not succeeded))
  if not succeeded then
    ctx:Fail("Frame:HookScript raised for OnShow: " .. tostring(answer))
    return
  end
  ctx:Log(
    ("HookScript returned %d value(s); the first is %s"):format(
      answer.count,
      type(answer.values[1]) .. " " .. tostring(answer.values[1])
    )
  )
  if HOOK_SCRIPT_ANSWERS_SUCCESS then
    ctx:Expect(answer.count):ToBe(1)
    ctx:Expect(answer.values[1]):ToBe(true)
  else
    ctx:Expect(answer.count):ToBe(0)
  end
end)

scripts:Test(
  "SecureHookScript of a script a plain Frame lacks records no hook when the client declines it (the client's own HookScript answer is logged)",
  function(ctx)
    local frame = plainFrame("declinedScript")
    local directSucceeded, direct = pcall(function()
      return pack(frame:HookScript(SCRIPT_A_FRAME_LACKS, ignore))
    end)
    if directSucceeded then
      ctx:Log(
        ("the client's HookScript(%s) answered %d value(s), the first %s"):format(
          SCRIPT_A_FRAME_LACKS,
          direct.count,
          tostring(direct.values[1])
        )
      )
    else
      ctx:Log(
        "the client's HookScript(" .. SCRIPT_A_FRAME_LACKS .. ") raised: " .. tostring(direct)
      )
    end

    local scope = newScope()
    local installed, outcome =
      pcall(scope.SecureHookScript, scope, frame, SCRIPT_A_FRAME_LACKS, ignore)
    ctx:Log(
      "HookKit's SecureHookScript "
        .. (installed and "returned " or "raised: ")
        .. tostring(outcome)
    )
    -- Retail answers a success boolean; the Classic clients document no
    -- answer, so there a call that did not raise accepted the script.
    local clientAccepted = directSucceeded and direct.values[1] ~= false
    if clientAccepted then
      -- This client binds any script name; HookKit records what it installed.
      ctx:Expect(installed):ToBe(true)
      ctx:Expect(scope:IsHooked(frame, SCRIPT_A_FRAME_LACKS)):ToBe(true)
      return
    end
    if installed then
      ctx:Fail(
        "the client declined HookScript, yet HookKit recorded the hook and returned "
          .. tostring(outcome)
          .. ": HookKit ignores HookScript's success answer"
      )
      return
    end
    ctx:Expect(scope:IsHooked(frame, SCRIPT_A_FRAME_LACKS)):ToBe(false)
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
  end
)

scripts:Test(
  "HookScript runs its handler before the frame's own OnShow with the frame, and Unhook puts that same script back",
  function(ctx)
    local frame = plainFrame("preHook")
    local order = {}
    local preReceived = nil
    local own = function()
      order[#order + 1] = "own"
    end
    frame:SetScript("OnShow", own)

    local scope = newScope()
    ctx
      :Expect(scope:HookScript(frame, "OnShow", function(received)
        order[#order + 1] = "pre"
        preReceived = received
      end))
      :ToBe(true)
    ctx:Expect(scope:Original(frame, "OnShow")):ToBe(own)

    frame:Show()
    frame:Hide()
    ctx:Expect(order):ToEqual({ "pre", "own" })
    ctx:Expect(preReceived):ToBe(frame)

    ctx:Expect(scope:Unhook(frame, "OnShow")):ToBe(true)
    ctx:Expect(frame:GetScript("OnShow")):ToBe(own)
    frame:Show()
    frame:Hide()
    ctx:Expect(order):ToEqual({ "pre", "own", "own" })
  end
)

scripts:Test(
  "RawHookScript of OnHide on a frame without one receives nil as the previous script, and Unhook leaves OnHide empty again",
  function(ctx)
    local frame = plainFrame("replacement")
    frame:SetScript("OnHide", nil)
    local scope = newScope()
    local calls = 0
    local previousType = "unset"
    local hiddenFrame = nil
    -- The handler only records: an expectation failing inside a script
    -- would reach the client's error handler instead of this test.
    ctx
      :Expect(scope:RawHookScript(frame, "OnHide", function(previous, received)
        calls = calls + 1
        previousType = type(previous)
        hiddenFrame = received
      end))
      :ToBe(true)

    frame:Show()
    frame:Hide()
    ctx:Expect(calls):ToBe(1)
    ctx:Expect(previousType):ToBe("nil")
    ctx:Expect(hiddenFrame):ToBe(frame)

    ctx:Expect(scope:Unhook(frame, "OnHide")):ToBe(true)
    ctx:Expect(frame:GetScript("OnHide")):ToBeNil()
    frame:Show()
    frame:Hide()
    ctx:Expect(calls):ToBe(1)
  end
)

scripts:Test(
  "a script pre-hook is refused at the calling line while a SecureHookScript post-hook holds that script; the safe order (pre-hook first) runs both, and unhooking the pre-hook then leaves it inert",
  function(ctx)
    local frame = plainFrame("installOrder")
    local order = {}
    -- The refusal holds across scopes: one scope holds the post-hook, and
    -- another asks for the pre-hook.
    local postHookScope = newScope()
    local refusalScope = newScope()
    postHookScope:SecureHookScript(frame, "OnShow", ignore)
    local startLine = 0
    expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        refusalScope:HookScript(frame, "OnShow", ignore)
      end,
      'HookKit.Scope:HookScript refuses to replace script "OnShow": HookKit holds a SecureHookScript post-hook on it, which SetScript may drop; Unhook it first, or install the pre-hook before the post-hook',
      function()
        return startLine
      end
    )

    local preScope = newScope()
    local postScope = newScope()
    preScope:HookScript(frame, "OnHide", function()
      order[#order + 1] = "pre"
    end)
    local scriptBeforePostHook = frame:GetScript("OnHide")
    postScope:SecureHookScript(frame, "OnHide", function()
      order[#order + 1] = "post"
    end)
    ctx:Log(
      "GetScript is unchanged by the client's HookScript: "
        .. tostring(rawequal(frame:GetScript("OnHide"), scriptBeforePostHook))
    )
    frame:Show()
    frame:Hide()
    ctx:Expect(order):ToEqual({ "pre", "post" })

    -- The post-hook was added after the pre-hook, so HookKit leaves the
    -- pre-hook's closure in place, inert, rather than call SetScript.
    ctx:Expect(preScope:Unhook(frame, "OnHide")):ToBe(true)
    ctx:Expect(type(frame:GetScript("OnHide"))):ToBe("function")
    frame:Show()
    frame:Hide()
    ctx:Expect(order):ToEqual({ "pre", "post", "post" })
  end
)

scripts:Test(
  "Frame:SetScript over a client HookScript post-hook runs the new script; whether the post-hook survives is logged (why HookKit refuses a pre-hook after a post-hook)",
  function(ctx)
    local frame = plainFrame("setScriptOverHook")
    frame:SetScript("OnShow", nil)
    local postRuns = 0
    frame:HookScript("OnShow", function()
      postRuns = postRuns + 1
    end)
    frame:Show()
    frame:Hide()
    ctx:Expect(postRuns):ToBe(1)

    local replacedRuns = 0
    frame:SetScript("OnShow", function()
      replacedRuns = replacedRuns + 1
    end)
    frame:Show()
    frame:Hide()
    ctx:Expect(replacedRuns):ToBe(1)
    ctx:Log("the HookScript post-hook still ran after SetScript: " .. tostring(postRuns == 2))
  end
)

-- hookKit.access ------------------------------------------------------------------------------

local access = newSuite("access")

access:Test(
  "a test-owned frame answers IsForbidden false and CanBeAccessedInContext true, and SecureHookScript accepts it",
  function(ctx)
    local frame = plainFrame("accessible")
    local forbidden = frame:IsForbidden()
    ctx:Log("IsForbidden(): " .. tostring(forbidden))
    ctx:Expect(forbidden):ToBe(false)
    local canBeAccessedInContext = frame.CanBeAccessedInContext
    if type(canBeAccessedInContext) == "function" then
      local accessible = canBeAccessedInContext(frame)
      ctx:Log("CanBeAccessedInContext(): " .. tostring(accessible))
      ctx:Expect(accessible):ToBe(true)
    else
      ctx:Log("the client has no CanBeAccessedInContext; only IsForbidden is asked")
    end
    local scope = newScope()
    ctx:Expect(scope:SecureHookScript(frame, "OnShow", ignore)):ToBe(true)
  end
)

access:Skip(
  "a script hook of a genuinely forbidden frame is refused at the calling line",
  "no forbidden frame is reachable from addon code without side effects; hookKit.errors checks the refusal on a stand-in, packages/hookKit/tests on the fixture"
)

access:Test(
  "Hook of Show on a test-owned frame is refused at the calling line: the method the frame inherits from the client's widget table is secure there, and the frame gets no field",
  function(ctx)
    local frame = plainFrame("inheritedMethod")
    local metatable = getmetatable(frame)
    local index = type(metatable) == "table" and rawget(metatable, "__index") or nil
    ctx:Log(
      ("getmetatable(frame) is a %s; its __index is a %s"):format(type(metatable), type(index))
    )
    if type(index) ~= "table" or type(rawget(index, "Show")) ~= "function" then
      Harness:SkipTest(
        ctx,
        "the client hides the frame's method table, so HookKit cannot locate Show; logged"
      )
      return
    end
    ---@cast index table
    local secure = HOOK_API_AVAILABLE and isSecureVariable(index, "Show") == true
    ctx:Log("issecurevariable(method table, Show): " .. tostring(secure))
    if not secure then
      Harness:SkipTest(ctx, "the client does not report the widget method Show as secure")
      return
    end
    ctx:Expect(rawget(frame, "Show")):ToBeNil()

    local scope = newScope()
    local startLine = 0
    expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        scope:Hook(frame, "Show", ignore)
      end,
      'HookKit.Scope:Hook refuses to hook secure "Show" non-securely; use SecureHook, or pass options.forceSecure',
      function()
        return startLine
      end
    )
    ctx:Expect(rawget(frame, "Show")):ToBeNil()
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
  end
)

access:Test(
  "on a test-owned secure action button (IsProtected true), HookScript of OnClick is refused outright and RawHookScript of OnEnter without forceSecure too, both at the calling line, and the scripts stay as they were",
  function(ctx)
    requireOutOfCombat(ctx)
    local button = protectedButton()
    if button == nil then
      Harness:SkipTest(ctx, IN_COMBAT_REASON)
      return
    end
    local isProtected = button:IsProtected()
    ctx:Log("IsProtected(): " .. tostring(isProtected))
    if isProtected ~= true then
      Harness:SkipTest(
        ctx,
        "the client does not report a SecureActionButtonTemplate button as protected"
      )
      return
    end
    local clickBefore = button:GetScript("OnClick")
    local enterBefore = button:GetScript("OnEnter")

    local scope = newScope()
    local startLine = 0
    expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        scope:HookScript(button, "OnClick", ignore)
      end,
      'HookKit.Scope:HookScript refuses to replace protected script "OnClick" of a protected frame; use SecureHookScript',
      function()
        return startLine
      end
    )
    expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        scope:RawHookScript(button, "OnEnter", ignore)
      end,
      'HookKit.Scope:RawHookScript refuses to replace script "OnEnter" of a protected frame; use SecureHookScript, or pass options.forceSecure',
      function()
        return startLine
      end
    )

    ctx:Expect(button:GetScript("OnClick")):ToBe(clickBefore)
    ctx:Expect(button:GetScript("OnEnter")):ToBe(enterBefore)
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
  end
)

-- hookKit.combat ----------------------------------------------------------------------------
--
-- A combat suite: `/mct run hookKit combat` creates the secure button out of
-- combat (its `prepare`), waits for the player to attack a training dummy and
-- runs the test in combat lockdown. A default run out of combat reports it as
-- skipped. The test is passive: it attacks, casts and moves nothing.

local combat = newSuite("combat", {
  combat = true,
  prepare = function()
    protectedButton()
  end,
})

combat:Test(
  "during combat lockdown a forced script hook of the test's secure button is refused at the calling line (passive: skipped out of combat)",
  function(ctx)
    local inCombatLockdown = readHost("InCombatLockdown")
    if type(inCombatLockdown) ~= "function" or not inCombatLockdown() then
      Harness:SkipTest(ctx, NOT_IN_COMBAT_REASON)
      return
    end
    local button = protectedButton()
    if button == nil then
      Harness:SkipTest(ctx, NO_SECURE_BUTTON_REASON)
      return
    end
    local enterBefore = button:GetScript("OnEnter")
    local scope = newScope()
    local startLine = 0
    expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        scope:HookScript(button, "OnEnter", ignore, { forceSecure = true })
      end,
      "HookKit.Scope:HookScript cannot replace a script of a protected frame during combat lockdown",
      function()
        return startLine
      end
    )
    ctx:Expect(button:GetScript("OnEnter")):ToBe(enterBefore)
  end
)

-- hookKit.release -----------------------------------------------------------------------------

local release = newSuite("release")

release:Test(
  "Unhook of a pre-hook and of a replacement on a test-owned table writes each original back exactly, and a second Unhook answers false",
  function(ctx)
    local probe = newProbeTable()
    local originalCombine = probe.Combine
    local originalFormat = probe.Format
    local scope = newScope()
    local preCalls = 0
    scope:Hook(probe, "Combine", function()
      preCalls = preCalls + 1
    end)
    scope:RawHook(probe, "Format", function(original, self, value)
      return "wrapped:" .. original(self, value)
    end)

    ctx:Expect(pack(probe:Combine("a"))):ToEqual({ count = 2, values = { 1, "a" } })
    ctx:Expect(preCalls):ToBe(1)
    ctx:Expect(probe:Format("x")):ToBe("wrapped:formatted:x")
    ctx:Expect(scope:Original(probe, "Format")):ToBe(originalFormat)

    ctx:Expect(scope:Unhook(probe, "Combine")):ToBe(true)
    ctx:Expect(scope:Unhook(probe, "Format")):ToBe(true)
    ctx:Expect(rawget(probe, "Combine")):ToBe(originalCombine)
    ctx:Expect(rawget(probe, "Format")):ToBe(originalFormat)
    ctx:Expect(scope:Unhook(probe, "Combine")):ToBe(false)
    ctx:Expect(probe:Format("x")):ToBe("formatted:x")
  end
)

release:Test(
  "UnhookAll undoes every hook newest first and keeps the scope usable; Close is terminal and a later hook is refused at the calling line",
  function(ctx)
    local probe = newProbeTable()
    local frame = plainFrame("releaseAll")
    local scope = newScope()
    scope:Hook(probe, "Combine", ignore)
    scope:SecureHook(probe, "Format", ignore)
    scope:HookScript(frame, "OnShow", ignore)

    local kinds = {}
    for _, row in ipairs(scope:Hooks()) do
      kinds[#kinds + 1] = row.kind
    end
    ctx:Expect(kinds):ToEqual({ "hook", "secure", "hookScript" })
    ctx:Expect(scope:UnhookAll()):ToBe(3)
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
    ctx:Expect(frame:GetScript("OnShow")):ToBeNil()

    ctx:Expect(scope:SecureHook(probe, "Combine", ignore)):ToBe(true)
    ctx:Expect(scope:Close()):ToBe(true)
    ctx:Expect(scope:Close()):ToBe(false)
    ctx:Expect(scope:IsClosed()):ToBe(true)
    ctx:Expect(scope:GetActiveCount()):ToBe(0)

    local startLine = 0
    expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        scope:SecureHook(probe, "Echo", ignore)
      end,
      "HookKit.Scope:SecureHook cannot hook in a closed scope",
      function()
        return startLine
      end
    )
  end
)

release:Test(
  "a scope opened with maxHooks 1 answers nil and full to a second hook and leaves that target untouched",
  function(ctx)
    local probe = newProbeTable()
    local originalFormat = probe.Format
    local scope = newScope({ maxHooks = 1 })
    ctx:Expect(scope:GetMaxHooks()):ToBe(1)
    ctx:Expect(scope:Hook(probe, "Combine", ignore)):ToBe(true)
    ctx
      :Expect(pack(scope:Hook(probe, "Format", ignore)))
      :ToEqual({ count = 2, values = { nil, "full" } })
    ctx:Expect(rawget(probe, "Format")):ToBe(originalFormat)
    ctx:Expect(scope:GetActiveCount()):ToBe(1)
  end
)

release:Test(
  "ForAddon with this test addon's name returns one open scope that names the addon, with the default limit of 256",
  function(ctx)
    local addonScope = HookKit:ForAddon(addonName)
    ctx:Expect(HookKit:ForAddon(addonName)):ToBe(addonScope)
    ctx:Expect(addonScope:GetAddonName()):ToBe(addonName)
    ctx:Expect(addonScope:IsClosed()):ToBe(false)
    ctx:Expect(addonScope:GetMaxHooks()):ToBe(DOCUMENTED_MAX_HOOKS)
    ctx:Expect(addonScope:GetActiveCount()):ToBe(0)
  end
)

-- hookKit.allocation --------------------------------------------------------------------------

local allocation = newSuite("allocation")

---Call `probe:Combine` `HOOKED_CALLS` times and return the heap growth.
---@param probe table
---@return number grownKilobytes
local function measureHookedCalls(probe)
  -- Warm the path once, so the measurement sees steady state only.
  probe:Combine(1, "payload", true)
  return measureAllocation(function()
    for _ = 1, HOOKED_CALLS do
      probe:Combine(1, "payload", true)
    end
  end)
end

---Register `body` as an allocation test when the client has `hooksecurefunc`.
---@param name string
---@param body fun(ctx: TestKit.Context)
local function secureAllocationTest(name, body)
  if HOOK_API_AVAILABLE then
    allocation:Test(name, body)
  else
    allocation:Skip(name, HOOK_API_SKIP_REASON)
  end
end

secureAllocationTest(
  "a secure post-hooked table method called 10000 times allocates nothing, active and after Unhook, through the client's hooksecurefunc wrapper (allocation guard)",
  function(ctx)
    local probe = newProbeTable()
    local scope = newScope()
    local calls = 0
    scope:SecureHook(probe, "Combine", function()
      calls = calls + 1
    end)

    collectBeforeMeasuring(ctx)
    local activeKilobytes = measureHookedCalls(probe)
    ctx:Log(("active: %.3f KB over %d calls"):format(activeKilobytes, HOOKED_CALLS))
    ctx:Expect(activeKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
    ctx:Expect(calls):ToBe(HOOKED_CALLS + 1)

    scope:Unhook(probe, "Combine")
    collectBeforeMeasuring(ctx)
    local inertKilobytes = measureHookedCalls(probe)
    ctx:Log(("inert: %.3f KB over %d calls"):format(inertKilobytes, HOOKED_CALLS))
    ctx:Expect(inertKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
    ctx:Expect(calls):ToBe(HOOKED_CALLS + 1)
  end
)

allocation:Test(
  "a pre-hooked and a raw-hooked table method called 10000 times each allocate nothing (allocation guard)",
  function(ctx)
    local preHooked = newProbeTable()
    local replaced = newProbeTable()
    local scope = newScope()
    scope:Hook(preHooked, "Combine", ignore)
    scope:RawHook(replaced, "Combine", function(original, self, ...)
      return original(self, ...)
    end)

    collectBeforeMeasuring(ctx)
    local preKilobytes = measureHookedCalls(preHooked)
    ctx:Log(("pre-hook: %.3f KB over %d calls"):format(preKilobytes, HOOKED_CALLS))
    ctx:Expect(preKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)

    collectBeforeMeasuring(ctx)
    local rawKilobytes = measureHookedCalls(replaced)
    ctx:Log(("replacement: %.3f KB over %d calls"):format(rawKilobytes, HOOKED_CALLS))
    ctx:Expect(rawKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
  end
)

allocation:Test(
  "IsHooked, Original and GetActiveCount of hooked and never-hooked targets allocate nothing over 5000 rounds (allocation guard)",
  function(ctx)
    local probe = newProbeTable()
    local neverHooked = newProbeTable()
    local scope = newScope()
    scope:Hook(probe, "Combine", ignore)
    local hits = 0

    collectBeforeMeasuring(ctx)
    local grownKilobytes = measureAllocation(function()
      for _ = 1, LOOKUP_ROUNDS do
        if scope:IsHooked(probe, "Combine") then
          hits = hits + 1
        end
        if scope:IsHooked(neverHooked, "Combine") then
          hits = hits + 1
        end
        if scope:Original(probe, "Combine") ~= nil then
          hits = hits + 1
        end
        hits = hits + scope:GetActiveCount()
      end
    end)
    ctx:Log(("memory delta over %d rounds: %.3f KB"):format(LOOKUP_ROUNDS, grownKilobytes))
    ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
    ctx:Expect(hits):ToBe(LOOKUP_ROUNDS * 3)
  end
)

-- hookKit.errors ------------------------------------------------------------------------------

local errors = newSuite("errors")

errors:Test(
  "SecureHook with a handler that is not a function names HookKitSuite.lua at the calling line",
  function(ctx)
    local probe = newProbeTable()
    local scope = newScope()
    -- The wrong argument type is the point of the test.
    ---@type any
    local notAFunction = "not a function"
    local startLine = 0
    expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        scope:SecureHook(probe, "Combine", notAFunction)
      end,
      "HookKit.Scope:SecureHook handler must be a function",
      function()
        return startLine
      end
    )
  end
)

errors:Test(
  "Hook of a field that holds no function names HookKitSuite.lua at the calling line",
  function(ctx)
    local probe = newProbeTable()
    local scope = newScope()
    local startLine = 0
    expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        scope:Hook(probe, "Missing", ignore)
      end,
      'HookKit.Scope:Hook target "Missing" is not a function',
      function()
        return startLine
      end
    )
  end
)

errors:Test("a second hook of one target in one scope is refused at the calling line", function(ctx)
  local probe = newProbeTable()
  local scope = newScope()
  scope:Hook(probe, "Format", ignore)
  local startLine = 0
  expectErrorAtCallingLine(
    ctx,
    function()
      startLine = currentLine()
      scope:RawHook(probe, "Format", ignore)
    end,
    'HookKit.Scope:RawHook "Format" is already hooked in this scope; Unhook it first',
    function()
      return startLine
    end
  )
end)

errors:Test(
  "Hook with an unknown option field is refused at the calling line and installs nothing",
  function(ctx)
    local probe = newProbeTable()
    local originalFormat = probe.Format
    local scope = newScope()
    local startLine = 0
    expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        scope:Hook(probe, "Format", ignore, { force = true })
      end,
      'HookKit.Scope:Hook options contains unknown field "force"',
      function()
        return startLine
      end
    )
    ctx:Expect(rawget(probe, "Format")):ToBe(originalFormat)
  end
)

errors:Test(
  "a scope method called with a dot instead of a colon names HookKitSuite.lua at the calling line",
  function(ctx)
    local scope = newScope()
    local probe = newProbeTable()
    -- The missing receiver is the point of the test.
    ---@type any
    local unhookWithoutReceiver = scope.Unhook
    local startLine = 0
    expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        unhookWithoutReceiver(probe, "Combine")
      end,
      "HookKit.Scope:Unhook must be called on a HookKit scope",
      function()
        return startLine
      end
    )
  end
)

errors:Test(
  "SecureHookScript on a stand-in whose IsForbidden answers true is refused at the calling line before any frame method runs",
  function(ctx)
    local reached = false
    local standIn = {
      IsForbidden = function()
        return true
      end,
      HookScript = function()
        reached = true
      end,
    }
    local scope = newScope()
    local startLine = 0
    expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        scope:SecureHookScript(standIn, "OnShow", ignore)
      end,
      "HookKit.Scope:SecureHookScript frame is forbidden or not accessible in this context",
      function()
        return startLine
      end
    )
    ctx:Expect(reached):ToBe(false)
  end
)

errors:Test("CreateScope with maxHooks 0 is refused at the calling line", function(ctx)
  local startLine = 0
  expectErrorAtCallingLine(
    ctx,
    function()
      startLine = currentLine()
      HookKit:CreateScope({ maxHooks = 0 })
    end,
    "HookKit:CreateScope options.maxHooks must be a positive integer or HookKit.UNBOUNDED",
    function()
      return startLine
    end
  )
end)

-- hookKit.secrets -----------------------------------------------------------------------------

local secrets = newSuite("secrets")

--- Why the secrets tests are skipped on a client without the two functions.
local SECRETS_SKIP_REASON =
  "the client has no issecretvalue and secretwrap; the secret path was not exercised"

---Register `body` as a test when the client can make a secret value, and as a
---skipped test naming why otherwise: it lacks the two functions, or has them
---but makes no secret (`Harness:CanMakeSecrets`).
---@param name string
---@param body fun(ctx: TestKit.Context)
local function secretTest(name, body)
  if not SECRETS_AVAILABLE then
    secrets:Skip(name, SECRETS_SKIP_REASON)
  elseif not Harness:CanMakeSecrets() then
    -- The Classic clients document both functions too; whether the client
    -- applies secrets is measured once by the harness.
    secrets:Skip(name, Harness.NO_SECRETS_REASON)
  else
    secrets:Test(name, body)
  end
end

---A genuine secret value made by the client's `secretwrap`, or a failed test.
---
---`secretwrap` is documented in the client's own API documentation
---(FrameScriptDocumentation, packages/apiKit/metadata/retail/namespaces.json)
---with no restriction and no side effect: it converts the values given to it.
---A secret is checked only with `issecretvalue` and `type`: comparing one with
---a value of its own type raises.
---@param ctx TestKit.Context
---@param value any
---@return any secret
local function makeSecret(ctx, value)
  local succeeded, secret = pcall(secretWrap, value)
  if not succeeded then
    ctx:Fail("secretwrap raised, so the secret path was not exercised: " .. tostring(secret))
  end
  if isSecretValue(secret) ~= true then
    ctx:Fail("secretwrap returned a value issecretvalue does not report as secret")
  end
  return secret
end

secretTest(
  "a secret method name is refused by SecureHook and Hook at the calling line before HookKit compares it",
  function(ctx)
    local probe = newProbeTable()
    local originalCombine = probe.Combine
    local secretMethod = makeSecret(ctx, "Combine")
    local scope = newScope()
    local startLine = 0
    expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        scope:SecureHook(probe, secretMethod, ignore)
      end,
      "HookKit.Scope:SecureHook method must not be a secret value",
      function()
        return startLine
      end
    )
    expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        scope:Hook(probe, secretMethod, ignore)
      end,
      "HookKit.Scope:Hook method must not be a secret value",
      function()
        return startLine
      end
    )
    ctx:Expect(rawget(probe, "Combine")):ToBe(originalCombine)
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
  end
)

secretTest(
  "a secret global name is refused by SecureHook and by Unhook at the calling line",
  function(ctx)
    local secretGlobal = makeSecret(ctx, ABSENT_GLOBAL)
    local scope = newScope()
    local startLine = 0
    expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        scope:SecureHook(secretGlobal, ignore)
      end,
      "HookKit.Scope:SecureHook method must not be a secret value",
      function()
        return startLine
      end
    )
    expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        scope:Unhook(secretGlobal)
      end,
      "HookKit.Scope:Unhook globalName must not be a secret value",
      function()
        return startLine
      end
    )
  end
)

secretTest(
  "a secret script name is refused by SecureHookScript and HookScript at the calling line",
  function(ctx)
    local frame = plainFrame("secretScript")
    local secretScript = makeSecret(ctx, "OnShow")
    local scope = newScope()
    local startLine = 0
    expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        scope:SecureHookScript(frame, secretScript, ignore)
      end,
      "HookKit.Scope:SecureHookScript script must not be a secret value",
      function()
        return startLine
      end
    )
    expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        scope:HookScript(frame, secretScript, ignore)
      end,
      "HookKit.Scope:HookScript script must not be a secret value",
      function()
        return startLine
      end
    )
    ctx:Expect(frame:GetScript("OnShow")):ToBeNil()
  end
)

secretTest(
  "a secret addon name is refused by ForAddon and a secret maxHooks by CreateScope at the calling line",
  function(ctx)
    local secretAddonName = makeSecret(ctx, addonName)
    local secretLimit = makeSecret(ctx, 8)
    local startLine = 0
    expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        HookKit:ForAddon(secretAddonName)
      end,
      "HookKit:ForAddon addonName must not be a secret value",
      function()
        return startLine
      end
    )
    expectErrorAtCallingLine(
      ctx,
      function()
        startLine = currentLine()
        HookKit:CreateScope({ maxHooks = secretLimit })
      end,
      "HookKit:CreateScope options.maxHooks must be a positive integer or HookKit.UNBOUNDED",
      function()
        return startLine
      end
    )
  end
)

secretTest(
  "a secret argument reaches a pre-hook handler, the original and a secure post-hook handler still secret, and the original's secret result reaches the caller",
  function(ctx)
    local probe = newProbeTable()
    local preScope = newScope()
    local postScope = newScope()
    local preSawSecret = false
    local postSawSecret = false
    -- The pre-hook first: the secure post-hook then wraps it.
    preScope:Hook(probe, "Echo", function(_, value)
      preSawSecret = isSecretValue(value) == true
    end)
    if not HOOK_API_AVAILABLE then
      Harness:SkipTest(ctx, HOOK_API_SKIP_REASON)
      return
    end
    postScope:SecureHook(probe, "Echo", function(_, value)
      postSawSecret = isSecretValue(value) == true
    end)

    local result = probe:Echo(makeSecret(ctx, 42))
    ctx:Expect(preSawSecret):ToBe(true)
    ctx:Expect(postSawSecret):ToBe(true)
    ctx:Expect(isSecretValue(result)):ToBe(true)
    ctx:Expect(type(result)):ToBe("number")
  end
)
