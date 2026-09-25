-- MoltenCodes Test: ProfileKitSuite.lua
--
-- Real-client suites for the `profileKit` package. The Busted specs under
-- packages/profileKit/tests/ prove ProfileKit on a stock Lua 5.1 with a fake
-- `debugprofilestop` the spec advances by hand; these prove, inside the game
-- client with the installed MoltenCodes addon, what that fixture can only
-- simulate:
--
--   * the installed facade and its committed revision, and that ProfileKit
--     was still disabled when this addon loaded;
--   * `Enable` with the client's real `debugprofilestop`, and that `Enable`
--     and `Disable` swap functions rather than flip a flag;
--   * sections and `Measure` around busy loops of known length on that clock:
--     a 2 ms loop is recorded as 2 ms within `SPIN_TOLERANCE_MS`, and the
--     count, total, spike and last of three measurements are exactly what
--     `End` returned; every measured value is logged;
--   * the refusals (`active`, `idle`), an abandoned measurement across
--     `Disable`, statistics kept across `Disable`, `Reset`, `Measure`'s
--     re-raise and its recursion rule;
--   * the disabled path: `Begin`, `End` and `Measure` record nothing,
--     allocate nothing on the client's own collector, and cost little, with
--     the cost per call logged beside a direct call of the same function;
--   * that enabled `Begin`/`End` and `Measure` of an existing section
--     allocate nothing;
--   * `Report` sorted by total, then by name, with rows the caller owns;
--   * the `maxSections` refusal (`"capped"`) and `UNBOUNDED`;
--   * argument errors pointing at this file as the client names it, and a
--     secret `maxSections` made by the client's `secretwrap` refused.
--
-- Nothing here needs combat, a group or an instance, and nothing is visible.
-- The busy loops spin on `debugprofilestop` for at most a few milliseconds per
-- step; the allocation guards run a full garbage collection first.
--
-- Run with `/mct run profileKit`; tests/client/MoltenCodesTest_ProfileKit/EXPECTED.md
-- lists what the chat frame should show.
--
-- What a run leaves behind. ProfileKit's enabled state and its `maxSections`
-- limit are remembered by the Before hook of every suite and put back by its
-- After hook, whatever the test's outcome; the After hook's `Disable` also
-- abandons any measurement a failing test left open. ProfileKit never frees a
-- section, so the sections named `mctProfileKit.*` below stay in the session
-- (they count against `maxSections`), each with the statistics of the last
-- test that used it. Several tests call `ProfileKit:Reset()`, which zeroes the
-- statistics of every section in the session, including sections other addons
-- created. `debugprofilestart()` is never called. Nothing is written to a
-- global or a saved variable.

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
local PROFILE_KIT_API = 1
local PACKAGE_ID = "profileKit"

--- The default of `maxSections` docs/API.md of profileKit documents.
local DOCUMENTED_DEFAULT_MAX_SECTIONS = 256

--- Milliseconds a measured span may exceed the busy loop it wraps. The span
--- covers the loop plus a few function calls and two clock reads, which take
--- microseconds; the rest absorbs the operating system pausing the client's
--- thread in the middle of a loop.
local SPIN_TOLERANCE_MS = 1

--- How many calls each allocation guard and each cost measurement makes. One
--- table or closure per call would cost well over half a megabyte at this count.
local CALLS = 20000

--- Kilobytes an allocation guard tolerates. The tolerance absorbs a stray
--- allocation by the client between the two readings, not a per-call one.
local ALLOCATION_TOLERANCE_KB = 1

--- The most a disabled `Measure` of an empty function, or a disabled
--- `Begin`/`End` pair, may cost per call, in milliseconds (2 microseconds).
--- Two type checks and a tail call take a small fraction of that on any
--- client; the bound catches a disabled path that reads the clock, allocates
--- or runs `pcall`, not a slow computer.
local DISABLED_COST_LIMIT_MS = 0.002

--- Text a deliberately failing measured function raises.
local MEASURED_FAILURE = "mctProfileKit deliberate measured failure"

--- Every section name this file uses. ProfileKit never frees a section, so
--- these stay in the session; EXPECTED.md lists them.
local SECTION = {
  busyLoop = "mctProfileKit.BusyLoop",
  measuredLoop = "mctProfileKit.MeasuredLoop",
  semantics = "mctProfileKit.Semantics",
  outer = "mctProfileKit.Outer",
  inner = "mctProfileKit.Inner",
  active = "mctProfileKit.Active",
  idle = "mctProfileKit.Idle",
  abandoned = "mctProfileKit.Abandoned",
  kept = "mctProfileKit.Kept",
  reset = "mctProfileKit.Reset",
  raising = "mctProfileKit.Raising",
  recursive = "mctProfileKit.Recursive",
  disabled = "mctProfileKit.Disabled",
  allocation = "mctProfileKit.Allocation",
  heavy = "mctProfileKit.ReportHeavy",
  light = "mctProfileKit.ReportLight",
  unmeasured = "mctProfileKit.ReportUnmeasured",
  capExisting = "mctProfileKit.CapExisting",
  receiver = "mctProfileKit.Receiver",
  secret = "mctProfileKit.Secret",
}

--- A name no test ever creates: the cap tests are refused it, so it never
--- becomes a section.
local CAP_PROBE_NAME = "mctProfileKit.CapProbe"

--- Every member docs/API.md of profileKit lists on the facade.
local FACADE_METHODS = {
  "Enable",
  "Disable",
  "IsEnabled",
  "Section",
  "Measure",
  "Report",
  "Reset",
  "SetLimits",
  "GetLimits",
}

-- Resolving the client and the framework ---------------------------------------------

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- The clock and the secret-value functions are World of Warcraft client
  -- globals, reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, REGISTRY_API)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- ProfileKit is not in the language-server workspace of tests/client (its
-- .luarc.json lists TestKit's dependency closure only), so its facade and its
-- sections are typed `any` here.

---@type any
local ProfileKit = Registry:Get(PACKAGE_ID, PROFILE_KIT_API)
if type(ProfileKit) == "nil" then
  error(addonName .. " requires ProfileKit API 1 in the MoltenCodes addon; reinstall it", 0)
end

--- The clock ProfileKit reads. The busy loops spin on the same one, so the
--- addon refuses to load on a client without it.
local debugProfileStop = readHost("debugprofilestop")
if type(debugProfileStop) ~= "function" then
  error(addonName .. " requires the client's debugprofilestop", 0)
end

--- Whether ProfileKit was measuring when this addon loaded. Read once, before
--- any test can enable it.
local ENABLED_AT_LOAD = ProfileKit:IsEnabled()

--- The two client functions the secrets suite needs, read once at load: the
--- suite registers its tests as skipped when either is missing.
local isSecretValue = readHost("issecretvalue")
local secretWrap = readHost("secretwrap")
local SECRETS_AVAILABLE = type(isSecretValue) == "function" and type(secretWrap) == "function"

--- Read once at load: whether the client makes a secret value, as the harness
--- measures it. Classic Era and Mists Classic document `issecretvalue` and
--- `secretwrap` too, so their presence alone does not prove the client applies
--- secrets; the secrets suite registers its tests as skipped when it does not.
local SECRETS_ACTIVE = Harness:CanMakeSecrets()

-- Helpers ---------------------------------------------------------------------------

--- ProfileKit's session-wide state as the Before hook found it.
local remembered = { taken = false, enabled = false, maxSections = nil }

---Remember ProfileKit's enabled state and limit. Registered as a Before hook
---on every suite.
local function rememberProfileKitState()
  remembered.enabled = ProfileKit:IsEnabled()
  remembered.maxSections = ProfileKit:GetLimits().maxSections
  remembered.taken = true
end

---Put ProfileKit's enabled state and limit back. Registered as an After hook
---on every suite. `Disable` first, so a measurement a failing test left open
---is abandoned whatever the state to restore.
local function restoreProfileKitState()
  if not remembered.taken then
    return
  end
  ProfileKit:Disable()
  if remembered.enabled then
    ProfileKit:Enable()
  end
  ProfileKit:SetLimits({ maxSections = remembered.maxSections })
  remembered.taken = false
end

---Register a suite of this package whose tests all end with ProfileKit as
---they found it.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName)
  suite:Before(rememberProfileKitState)
  suite:After(restoreProfileKitState)
  return suite
end

---Enable ProfileKit and check that the real clock was accepted.
---@param ctx TestKit.Context
local function enableProfileKit(ctx)
  local enabled, reason = ProfileKit:Enable()
  ctx:Expect(reason):ToBeNil()
  ctx:Expect(enabled):ToBe(true)
end

---The section called `name`, or a failed test.
---@param ctx TestKit.Context
---@param name string
---@return any section
local function sectionNamed(ctx, name)
  local section, reason = ProfileKit:Section(name)
  if type(section) == "nil" then
    ctx:Fail("ProfileKit:Section refused " .. name .. ": " .. tostring(reason))
  end
  return section
end

---The report row of the section called `name`, or `nil`.
---@param name string
---@return table|nil row `{ name, count, total, max, last }`
local function reportRow(name)
  for _, row in ipairs(ProfileKit:Report()) do
    if row.name == name then
      return row
    end
  end
  return nil
end

---The report row of the section called `name`, or a failed test.
---@param ctx TestKit.Context
---@param name string
---@return table row `{ name, count, total, max, last }`
local function expectRow(ctx, name)
  local row = reportRow(name)
  if type(row) == "nil" then
    ctx:Fail("ProfileKit:Report has no row for " .. name)
  end
  ---@cast row table
  return row
end

---Spin on `debugprofilestop` until at least `milliseconds` have passed on it:
---known work, measured by the clock ProfileKit reads.
---
---A reading below the start means another addon zeroed the process-wide
---timer with `debugprofilestart()`; the loop then stops instead of spinning
---for as long as the old reading was.
---@param milliseconds number
---@return number spun milliseconds the loop took on the clock
local function spinFor(milliseconds)
  local startedAt = debugProfileStop()
  local elapsed = 0
  while elapsed < milliseconds do
    elapsed = debugProfileStop() - startedAt
    if elapsed < 0 then
      return elapsed
    end
  end
  return elapsed
end

---Check that `measured` covers a `target`-millisecond loop and exceeds it by
---at most `SPIN_TOLERANCE_MS`, and log both.
---@param ctx TestKit.Context
---@param label string what was measured, for the log
---@param target number milliseconds the loop spun for at least
---@param measured any milliseconds ProfileKit recorded
local function expectAboutMilliseconds(ctx, label, target, measured)
  ctx:Log(("%s: %s ms measured for a %.1f ms loop"):format(label, tostring(measured), target))
  ctx:Expect(type(measured)):ToBe("number")
  if type(measured) ~= "number" then
    return
  end
  ctx:Expect(measured >= target):ToBe(true)
  ctx:Expect(measured <= target + SPIN_TOLERANCE_MS):ToBe(true)
end

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
  ctx:Expect((file or ""):sub(-#"ProfileKitSuite.lua")):ToBe("ProfileKitSuite.lua")
  return line
end

---Call `raise`, which must record its start line with `currentLine()` and
---raise on the next line, and check the message names this file at that line
---and ends with `expected`.
---@param ctx TestKit.Context
---@param raise fun(recordLine: fun())
---@param expected string The message after the position, compared literally.
local function expectErrorAtCallingLine(ctx, raise, expected)
  local startLine = 0
  local succeeded, message = pcall(raise, function()
    -- Level 3 names the `raise` that called this closure: level 1 is
    -- `pcall` itself, 2 this closure.
    local _, position = pcall(error, "", 3)
    local _, line = splitPosition(position or "")
    startLine = line or 0
  end)
  ctx:Expect(succeeded):ToBe(false)
  ctx:Log("client message: " .. tostring(message))

  local line = expectThisFile(ctx, message)
  ctx:Expect(tostring(message):sub(-#expected)):ToBe(expected)
  ctx:Expect(line):ToBe(startLine + 1)
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

---Milliseconds `work` takes on `debugprofilestop`.
---@param work fun()
---@return number
local function timeMilliseconds(work)
  local startedAt = debugProfileStop()
  work()
  return debugProfileStop() - startedAt
end

---An empty function: the measured work of the allocation and cost tests.
local function ignore() end

---Return every argument, so a test can see what `Measure` hands back.
---@param ... any
---@return ...
local function passThrough(...)
  return ...
end

---The number of values given and the first of them.
---@param ... any
---@return integer count
---@return any first
local function countAndFirst(...)
  return select("#", ...), (...)
end

-- profileKit.facade ------------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('profileKit', 1) is the ProfileKit facade with API 1, every documented method, DEFAULT_MAX_SECTIONS 256 and UNBOUNDED",
  function(ctx)
    ctx:Expect(type(ProfileKit)):ToBe("table")
    ctx:Expect(rawget(ProfileKit, "API")):ToBe(PROFILE_KIT_API)
    for _, method in ipairs(FACADE_METHODS) do
      ctx:Expect(type(ProfileKit[method])):ToBe("function")
    end
    ctx:Expect(ProfileKit.DEFAULT_MAX_SECTIONS):ToBe(DOCUMENTED_DEFAULT_MAX_SECTIONS)
    ctx:Expect(type(ProfileKit.UNBOUNDED)):ToBe("table")
  end
)

facade:Test("the installed ProfileKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      local _, revision = Registry:Get(PACKAGE_ID, PROFILE_KIT_API)
      ctx:Expect(revision):ToBe(expected.revision)
      ctx:Expect(rawget(ProfileKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list profileKit")
end)

facade:Test(
  "ProfileKit was disabled when this addon loaded, because nothing in the framework enables it",
  function(ctx)
    ctx:Expect(ENABLED_AT_LOAD):ToBe(false)
  end
)

-- profileKit.clock -------------------------------------------------------------------

local clock = newSuite("clock")

clock:Test(
  "Enable with the client's debugprofilestop answers true, and Enable, Disable and IsEnabled agree however often they are called",
  function(ctx)
    ProfileKit:Disable()
    ctx:Expect(ProfileKit:IsEnabled()):ToBe(false)

    enableProfileKit(ctx)
    enableProfileKit(ctx)
    ctx:Expect(ProfileKit:IsEnabled()):ToBe(true)

    ProfileKit:Disable()
    ProfileKit:Disable()
    ctx:Expect(ProfileKit:IsEnabled()):ToBe(false)
  end
)

clock:Test(
  "Enable and Disable swap the Begin, End and Measure functions instead of flipping a flag",
  function(ctx)
    local section = sectionNamed(ctx, SECTION.busyLoop)
    ProfileKit:Disable()
    local disabledBegin, disabledEnd = section.Begin, section.End
    local disabledMeasure = ProfileKit.Measure

    enableProfileKit(ctx)
    ctx:Expect(section.Begin).Not:ToBe(disabledBegin)
    ctx:Expect(section.End).Not:ToBe(disabledEnd)
    ctx:Expect(ProfileKit.Measure).Not:ToBe(disabledMeasure)

    ProfileKit:Disable()
    ctx:Expect(section.Begin):ToBe(disabledBegin)
    ctx:Expect(section.End):ToBe(disabledEnd)
    ctx:Expect(ProfileKit.Measure):ToBe(disabledMeasure)
  end
)

clock:Test(
  "a section around a 2 ms busy loop records about 2 ms on debugprofilestop, and End returns what Report records",
  function(ctx)
    enableProfileKit(ctx)
    ProfileKit:Reset()
    local section = sectionNamed(ctx, SECTION.busyLoop)

    ctx:Expect(section:Begin()):ToBe(true)
    local spun = spinFor(2)
    local elapsed, reason = section:End()
    ctx:Log(("the loop itself took %.4f ms"):format(spun))
    ctx:Expect(reason):ToBeNil()
    expectAboutMilliseconds(ctx, "Begin/End", 2, elapsed)

    local row = expectRow(ctx, SECTION.busyLoop)
    ctx:Expect(row.count):ToBe(1)
    ctx:Expect(row.total):ToBe(elapsed)
    ctx:Expect(row.max):ToBe(elapsed)
    ctx:Expect(row.last):ToBe(elapsed)
  end
)

clock:Test(
  "Measure of a 2 ms busy loop records about 2 ms and returns every result of fn, trailing nils included",
  function(ctx)
    enableProfileKit(ctx)
    ProfileKit:Reset()

    local count, first = countAndFirst(ProfileKit:Measure(SECTION.measuredLoop, function()
      spinFor(2)
      return "done", nil, nil
    end))
    ctx:Expect(count):ToBe(3)
    ctx:Expect(first):ToBe("done")

    local row = expectRow(ctx, SECTION.measuredLoop)
    ctx:Expect(row.count):ToBe(1)
    expectAboutMilliseconds(ctx, "Measure", 2, row.last)
  end
)

clock:Test(
  "loops of 1, 3 and 2 ms give count 3, the sum as total, the largest as the spike and the 2 ms one as last",
  function(ctx)
    enableProfileKit(ctx)
    ProfileKit:Reset()
    local section = sectionNamed(ctx, SECTION.semantics)

    local measured = {}
    for index, target in ipairs({ 1, 3, 2 }) do
      section:Begin()
      spinFor(target)
      measured[index] = section:End()
      expectAboutMilliseconds(ctx, "loop " .. index, target, measured[index])
    end

    local row = expectRow(ctx, SECTION.semantics)
    ctx:Log(
      ("count %d, total %s ms, max %s ms, last %s ms"):format(
        row.count,
        tostring(row.total),
        tostring(row.max),
        tostring(row.last)
      )
    )
    ctx:Expect(row.count):ToBe(3)
    ctx:Expect(row.total):ToBe(measured[1] + measured[2] + measured[3])
    ctx:Expect(row.max):ToBe(math.max(measured[1], measured[2], measured[3]))
    ctx:Expect(row.last):ToBe(measured[3])
    ctx:Expect(row.max):ToBe(measured[2])
  end
)

clock:Test(
  "an outer section's span includes the whole span of an inner section begun and ended inside it",
  function(ctx)
    enableProfileKit(ctx)
    local outer = sectionNamed(ctx, SECTION.outer)
    local inner = sectionNamed(ctx, SECTION.inner)

    outer:Begin()
    spinFor(1)
    inner:Begin()
    spinFor(2)
    local innerElapsed = inner:End()
    local outerElapsed = outer:End()

    expectAboutMilliseconds(ctx, "inner", 2, innerElapsed)
    ctx:Log(("outer: %s ms"):format(tostring(outerElapsed)))
    ctx:Expect(type(outerElapsed)):ToBe("number")
    ctx:Expect((outerElapsed or 0) >= (innerElapsed or 0) + 1):ToBe(true)
  end
)

-- profileKit.states ------------------------------------------------------------------

local states = newSuite("states")

states:Test(
  "Begin on a begun section is refused with nil, active and the eventual End measures from the first Begin",
  function(ctx)
    enableProfileKit(ctx)
    ProfileKit:Reset()
    local section = sectionNamed(ctx, SECTION.active)

    ctx:Expect(section:Begin()):ToBe(true)
    spinFor(1)
    local begun, reason = section:Begin()
    ctx:Expect(begun):ToBeNil()
    ctx:Expect(reason):ToBe("active")
    spinFor(1)
    local elapsed = section:End()

    ctx:Log(("span from the first Begin: %s ms"):format(tostring(elapsed)))
    ctx:Expect((elapsed or 0) >= 2):ToBe(true)
    ctx:Expect(expectRow(ctx, SECTION.active).count):ToBe(1)
  end
)

states:Test("End without a Begin answers nil, idle and records nothing", function(ctx)
  enableProfileKit(ctx)
  ProfileKit:Reset()
  local section = sectionNamed(ctx, SECTION.idle)

  local elapsed, reason = section:End()
  ctx:Expect(elapsed):ToBeNil()
  ctx:Expect(reason):ToBe("idle")
  ctx:Expect(expectRow(ctx, SECTION.idle).count):ToBe(0)
end)

states:Test(
  "a measurement begun before Disable is abandoned: End after a later Enable answers nil, idle and records nothing",
  function(ctx)
    enableProfileKit(ctx)
    ProfileKit:Reset()
    local section = sectionNamed(ctx, SECTION.abandoned)

    ctx:Expect(section:Begin()):ToBe(true)
    ProfileKit:Disable()
    enableProfileKit(ctx)
    local elapsed, reason = section:End()
    ctx:Expect(elapsed):ToBeNil()
    ctx:Expect(reason):ToBe("idle")
    ctx:Expect(expectRow(ctx, SECTION.abandoned).count):ToBe(0)
  end
)

states:Test(
  "Disable keeps every statistic, and a later Enable continues counting from them",
  function(ctx)
    enableProfileKit(ctx)
    ProfileKit:Reset()
    local section = sectionNamed(ctx, SECTION.kept)
    section:Begin()
    spinFor(1)
    local first = section:End()

    ProfileKit:Disable()
    local whileDisabled = expectRow(ctx, SECTION.kept)
    ctx:Expect(whileDisabled.count):ToBe(1)
    ctx:Expect(whileDisabled.total):ToBe(first)

    enableProfileKit(ctx)
    section:Begin()
    local second = section:End()
    local afterEnable = expectRow(ctx, SECTION.kept)
    ctx:Expect(afterEnable.count):ToBe(2)
    ctx:Expect(afterEnable.total):ToBe(first + second)
  end
)

states:Test(
  "Reset zeroes count, total, spike and last but keeps the section, its identity and the enabled state",
  function(ctx)
    enableProfileKit(ctx)
    local section = sectionNamed(ctx, SECTION.reset)
    section:Begin()
    spinFor(1)
    section:End()
    local sectionsBefore = #ProfileKit:Report()

    ProfileKit:Reset()
    ctx:Expect(ProfileKit:IsEnabled()):ToBe(true)
    ctx:Expect(ProfileKit:Section(SECTION.reset)):ToBe(section)
    ctx:Expect(#ProfileKit:Report()):ToBe(sectionsBefore)
    ctx:Expect(expectRow(ctx, SECTION.reset)):ToEqual({
      name = SECTION.reset,
      count = 0,
      total = 0,
      max = 0,
      last = 0,
    })
  end
)

states:Test(
  "Measure re-raises fn's string error unchanged, naming this file at fn's line, and still records the span",
  function(ctx)
    enableProfileKit(ctx)
    ProfileKit:Reset()
    local raisingLine = 0

    local succeeded, message = pcall(function()
      ProfileKit:Measure(SECTION.raising, function()
        raisingLine = currentLine()
        error(MEASURED_FAILURE)
      end)
    end)
    ctx:Expect(succeeded):ToBe(false)
    ctx:Log("client message: " .. tostring(message))
    ctx:Expect(expectThisFile(ctx, message)):ToBe(raisingLine + 1)
    ctx:Expect(tostring(message):sub(-#MEASURED_FAILURE)):ToBe(MEASURED_FAILURE)
    ctx:Expect(expectRow(ctx, SECTION.raising).count):ToBe(1)
  end
)

states:Test("Measure re-raises fn's table error as the very same table", function(ctx)
  enableProfileKit(ctx)
  local problem = { reason = "deliberate" }

  local succeeded, raised = pcall(ProfileKit.Measure, ProfileKit, SECTION.raising, function()
    error(problem)
  end)
  ctx:Expect(succeeded):ToBe(false)
  ctx:Expect(raised):ToBe(problem)
end)

states:Test(
  "a recursive Measure of one name is recorded once, at the outermost call, and returns fn's result",
  function(ctx)
    enableProfileKit(ctx)
    ProfileKit:Reset()

    ---@param depth integer
    ---@return integer
    local function descend(depth)
      if depth == 0 then
        return 0
      end
      return ProfileKit:Measure(SECTION.recursive, descend, depth - 1) + 1
    end

    ctx:Expect(ProfileKit:Measure(SECTION.recursive, descend, 3)):ToBe(3)
    ctx:Expect(expectRow(ctx, SECTION.recursive).count):ToBe(1)
  end
)

-- profileKit.disabled ----------------------------------------------------------------

local disabled = newSuite("disabled")

disabled:Test(
  "while disabled, Begin and End return nothing and record nothing, and Measure calls fn once and returns its results",
  function(ctx)
    ProfileKit:Reset()
    ProfileKit:Disable()
    local section = sectionNamed(ctx, SECTION.disabled)

    ctx:Expect(select("#", section:Begin())):ToBe(0)
    ctx:Expect(select("#", section:End())):ToBe(0)

    local calls = 0
    local count, first = countAndFirst(ProfileKit:Measure(SECTION.disabled, function(value)
      calls = calls + 1
      return value, nil
    end, "value"))
    ctx:Expect(calls):ToBe(1)
    ctx:Expect(count):ToBe(2)
    ctx:Expect(first):ToBe("value")
    ctx:Expect(expectRow(ctx, SECTION.disabled).count):ToBe(0)
  end
)

disabled:Test(
  "a disabled Measure allocates nothing over 20000 calls (allocation guard)",
  function(ctx)
    ProfileKit:Disable()
    ProfileKit:Measure(SECTION.disabled, ignore)
    collectBeforeMeasuring(ctx)

    local grownKilobytes = measureAllocation(function()
      for _ = 1, CALLS do
        ProfileKit:Measure(SECTION.disabled, ignore)
      end
    end)

    ctx:Log(("memory delta over %d disabled Measure calls: %.3f KB"):format(CALLS, grownKilobytes))
    ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
  end
)

disabled:Test(
  "disabled Begin and End allocate nothing over 20000 pairs (allocation guard)",
  function(ctx)
    ProfileKit:Disable()
    local section = sectionNamed(ctx, SECTION.disabled)
    collectBeforeMeasuring(ctx)

    local grownKilobytes = measureAllocation(function()
      for _ = 1, CALLS do
        section:Begin()
        section:End()
      end
    end)

    ctx:Log(
      ("memory delta over %d disabled Begin/End pairs: %.3f KB"):format(CALLS, grownKilobytes)
    )
    ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
  end
)

disabled:Test(
  "a disabled Measure and a disabled Begin/End pair each cost under 2 microseconds per call, logged beside a direct call",
  function(ctx)
    ProfileKit:Disable()
    local section = sectionNamed(ctx, SECTION.disabled)

    local directMs = timeMilliseconds(function()
      for _ = 1, CALLS do
        ignore()
      end
    end)
    local measureMs = timeMilliseconds(function()
      for _ = 1, CALLS do
        ProfileKit:Measure(SECTION.disabled, ignore)
      end
    end)
    local pairMs = timeMilliseconds(function()
      for _ = 1, CALLS do
        section:Begin()
        section:End()
      end
    end)

    local microsecondsPerCall = 1000 / CALLS
    ctx:Log(
      ("per call over %d calls: direct %.4f us, disabled Measure %.4f us, disabled Begin+End %.4f us"):format(
        CALLS,
        directMs * microsecondsPerCall,
        measureMs * microsecondsPerCall,
        pairMs * microsecondsPerCall
      )
    )
    ctx:Expect(measureMs / CALLS < DISABLED_COST_LIMIT_MS):ToBe(true)
    ctx:Expect(pairMs / CALLS < DISABLED_COST_LIMIT_MS):ToBe(true)
    ctx:Expect(expectRow(ctx, SECTION.disabled).count):ToBe(0)
  end
)

-- profileKit.allocation --------------------------------------------------------------

local allocation = newSuite("allocation")

allocation:Test(
  "enabled Begin and End allocate nothing over 20000 pairs (allocation guard)",
  function(ctx)
    enableProfileKit(ctx)
    ProfileKit:Reset()
    local section = sectionNamed(ctx, SECTION.allocation)
    section:Begin()
    section:End()
    collectBeforeMeasuring(ctx)

    local grownKilobytes = measureAllocation(function()
      for _ = 1, CALLS do
        section:Begin()
        section:End()
      end
    end)

    ctx:Log(("memory delta over %d enabled Begin/End pairs: %.3f KB"):format(CALLS, grownKilobytes))
    ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
    ctx:Expect(expectRow(ctx, SECTION.allocation).count):ToBe(CALLS + 1)
  end
)

allocation:Test(
  "an enabled Measure of an existing section allocates nothing over 20000 calls (allocation guard)",
  function(ctx)
    enableProfileKit(ctx)
    ProfileKit:Reset()
    ProfileKit:Measure(SECTION.allocation, ignore)
    collectBeforeMeasuring(ctx)

    local grownKilobytes = measureAllocation(function()
      for _ = 1, CALLS do
        ProfileKit:Measure(SECTION.allocation, ignore)
      end
    end)

    ctx:Log(("memory delta over %d enabled Measure calls: %.3f KB"):format(CALLS, grownKilobytes))
    ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
    ctx:Expect(expectRow(ctx, SECTION.allocation).count):ToBe(CALLS + 1)
  end
)

-- profileKit.report ------------------------------------------------------------------

local reportSuite = newSuite("report")

reportSuite:Test(
  "Report lists every section by total descending, then by name, and after Reset a 3 ms and a 1 ms section lead it",
  function(ctx)
    enableProfileKit(ctx)
    sectionNamed(ctx, SECTION.unmeasured)
    ProfileKit:Reset()
    ProfileKit:Measure(SECTION.light, spinFor, 1)
    ProfileKit:Measure(SECTION.heavy, spinFor, 3)

    local rows = ProfileKit:Report()
    ctx:Log(("%d sections in the session"):format(#rows))
    ctx:Expect(rows[1].name):ToBe(SECTION.heavy)
    ctx:Expect(rows[2].name):ToBe(SECTION.light)
    expectAboutMilliseconds(ctx, "heavy", 3, rows[1].total)
    expectAboutMilliseconds(ctx, "light", 1, rows[2].total)

    local unmeasuredSeen = false
    for index = 2, #rows do
      local previous, current = rows[index - 1], rows[index]
      local ordered = previous.total > current.total
        or (previous.total == current.total and previous.name < current.name)
      if not ordered then
        ctx:Fail(("rows %d and %d are out of order"):format(index - 1, index))
      end
      if current.name == SECTION.unmeasured then
        unmeasuredSeen = true
        ctx:Expect(current.count):ToBe(0)
        ctx:Expect(current.total):ToBe(0)
      end
    end
    ctx:Expect(unmeasuredSeen):ToBe(true)
  end
)

reportSuite:Test(
  "Report returns a new array of new rows on every call, and changing them changes nothing in ProfileKit",
  function(ctx)
    enableProfileKit(ctx)
    ProfileKit:Measure(SECTION.light, ignore)

    local first = ProfileKit:Report()
    local second = ProfileKit:Report()
    ctx:Expect(first).Not:ToBe(second)
    ctx:Expect(first[1]).Not:ToBe(second[1])

    local row = expectRow(ctx, SECTION.light)
    local countBefore = row.count
    row.count = -1
    row.name = "changed by the caller"
    ctx:Expect(expectRow(ctx, SECTION.light).count):ToBe(countBefore)
  end
)

-- profileKit.limits ------------------------------------------------------------------

local limits = newSuite("limits")

limits:Test(
  "a new name at maxSections is refused with nil, capped; an existing name is still returned; Measure runs the refused name unmeasured",
  function(ctx)
    enableProfileKit(ctx)
    local existing = sectionNamed(ctx, SECTION.capExisting)
    local sectionCount = #ProfileKit:Report()
    ProfileKit:SetLimits({ maxSections = sectionCount })
    ctx:Log(("maxSections set to the %d sections that exist"):format(sectionCount))

    local refused, reason = ProfileKit:Section(CAP_PROBE_NAME)
    ctx:Expect(refused):ToBeNil()
    ctx:Expect(reason):ToBe("capped")
    ctx:Expect(ProfileKit:Section(SECTION.capExisting)):ToBe(existing)

    local count, first = countAndFirst(ProfileKit:Measure(CAP_PROBE_NAME, passThrough, 7, nil))
    ctx:Expect(count):ToBe(2)
    ctx:Expect(first):ToBe(7)
    ctx:Expect(reportRow(CAP_PROBE_NAME)):ToBeNil()
    ctx:Expect(#ProfileKit:Report()):ToBe(sectionCount)
  end
)

limits:Test(
  "lowering maxSections below the sections that exist removes none of them and refuses new names",
  function(ctx)
    sectionNamed(ctx, SECTION.capExisting)
    local sectionCount = #ProfileKit:Report()
    ProfileKit:SetLimits({ maxSections = 1 })

    ctx:Expect(#ProfileKit:Report()):ToBe(sectionCount)
    ctx:Expect(reportRow(SECTION.capExisting)).Not:ToBeNil()
    local refused, reason = ProfileKit:Section(CAP_PROBE_NAME)
    ctx:Expect(refused):ToBeNil()
    ctx:Expect(reason):ToBe("capped")
  end
)

limits:Test(
  "SetLimits with UNBOUNDED returns nothing, and GetLimits hands back the same UNBOUNDED table in a fresh table each call",
  function(ctx)
    ctx:Expect(select("#", ProfileKit:SetLimits({ maxSections = ProfileKit.UNBOUNDED }))):ToBe(0)
    local first = ProfileKit:GetLimits()
    local second = ProfileKit:GetLimits()
    ctx:Expect(first.maxSections):ToBe(ProfileKit.UNBOUNDED)
    ctx:Expect(first).Not:ToBe(second)
  end
)

-- profileKit.errors ------------------------------------------------------------------

local errors = newSuite("errors")

errors:Test(
  "Section with an empty name names ProfileKitSuite.lua at the calling line",
  function(ctx)
    expectErrorAtCallingLine(ctx, function(recordLine)
      recordLine()
      ProfileKit:Section("")
    end, "ProfileKit:Section name must be a non-empty string")
  end
)

errors:Test(
  "a disabled Measure with a name that is not a string names ProfileKitSuite.lua at the calling line",
  function(ctx)
    ProfileKit:Disable()
    -- The wrong argument type is the point of the test.
    ---@type any
    local notAName = 42
    expectErrorAtCallingLine(ctx, function(recordLine)
      recordLine()
      ProfileKit:Measure(notAName, ignore)
    end, "ProfileKit:Measure name must be a non-empty string")
  end
)

errors:Test(
  "an enabled Measure with a name that is not a string names ProfileKitSuite.lua at the calling line",
  function(ctx)
    enableProfileKit(ctx)
    ---@type any
    local notAName = 42
    expectErrorAtCallingLine(ctx, function(recordLine)
      recordLine()
      ProfileKit:Measure(notAName, ignore)
    end, "ProfileKit:Measure name must be a non-empty string")
  end
)

errors:Test(
  "Measure with an fn that is not a function names ProfileKitSuite.lua at the calling line, disabled and enabled",
  function(ctx)
    ---@type any
    local notAFunction = "not a function"
    ProfileKit:Disable()
    expectErrorAtCallingLine(ctx, function(recordLine)
      recordLine()
      ProfileKit:Measure(SECTION.receiver, notAFunction)
    end, "ProfileKit:Measure fn must be a function")

    enableProfileKit(ctx)
    expectErrorAtCallingLine(ctx, function(recordLine)
      recordLine()
      ProfileKit:Measure(SECTION.receiver, notAFunction)
    end, "ProfileKit:Measure fn must be a function")
  end
)

errors:Test(
  "an enabled section.Begin() and section.End() without the section name ProfileKitSuite.lua at the calling line",
  function(ctx)
    enableProfileKit(ctx)
    local section = sectionNamed(ctx, SECTION.receiver)
    -- The missing receiver is the point of the test.
    ---@type any
    local beginWithoutReceiver = section.Begin
    ---@type any
    local endWithoutReceiver = section.End

    expectErrorAtCallingLine(ctx, function(recordLine)
      recordLine()
      beginWithoutReceiver()
    end, "ProfileKit.Section:Begin must be called on a ProfileKit section")
    expectErrorAtCallingLine(ctx, function(recordLine)
      recordLine()
      endWithoutReceiver()
    end, "ProfileKit.Section:End must be called on a ProfileKit section")
  end
)

errors:Test(
  "a disabled section.Begin() without the section raises nothing, as documented",
  function(ctx)
    ProfileKit:Disable()
    local section = sectionNamed(ctx, SECTION.receiver)
    ---@type any
    local beginWithoutReceiver = section.Begin
    ctx:Expect(pcall(beginWithoutReceiver)):ToBe(true)
  end
)

errors:Test(
  "SetLimits with a value that is not a table names ProfileKitSuite.lua at the calling line",
  function(ctx)
    ---@type any
    local notATable = "maxSections"
    expectErrorAtCallingLine(ctx, function(recordLine)
      recordLine()
      ProfileKit:SetLimits(notATable)
    end, "ProfileKit:SetLimits limits must be a table")
  end
)

errors:Test(
  "SetLimits with an unknown limit names ProfileKitSuite.lua at the calling line and changes nothing",
  function(ctx)
    ---@type any
    local unknownLimit = { maxSections = 1, maxWidgets = 4 }
    expectErrorAtCallingLine(ctx, function(recordLine)
      recordLine()
      ProfileKit:SetLimits(unknownLimit)
    end, "ProfileKit:SetLimits limits.maxWidgets is not a recognised limit")
    ctx:Expect(ProfileKit:GetLimits().maxSections):ToBe(remembered.maxSections)
  end
)

errors:Test(
  "SetLimits with a maxSections of 0 names ProfileKitSuite.lua at the calling line and changes nothing",
  function(ctx)
    expectErrorAtCallingLine(
      ctx,
      function(recordLine)
        recordLine()
        ProfileKit:SetLimits({ maxSections = 0 })
      end,
      "ProfileKit:SetLimits limits.maxSections must be a positive integer or ProfileKit.UNBOUNDED"
    )
    ctx:Expect(ProfileKit:GetLimits().maxSections):ToBe(remembered.maxSections)
  end
)

errors:Test(
  "ProfileKit.SetLimits and ProfileKit.GetLimits called with a dot name ProfileKitSuite.lua at the calling line",
  function(ctx)
    ---@type any
    local setLimits = ProfileKit.SetLimits
    ---@type any
    local getLimits = ProfileKit.GetLimits
    expectErrorAtCallingLine(
      ctx,
      function(recordLine)
        recordLine()
        setLimits({ maxSections = 1 })
      end,
      "ProfileKit:SetLimits must be called on the ProfileKit facade; use ProfileKit:SetLimits(...)"
    )
    expectErrorAtCallingLine(
      ctx,
      function(recordLine)
        recordLine()
        getLimits()
      end,
      "ProfileKit:GetLimits must be called on the ProfileKit facade; use ProfileKit:GetLimits(...)"
    )
    ctx:Expect(ProfileKit:GetLimits().maxSections):ToBe(remembered.maxSections)
  end
)

-- profileKit.secrets -----------------------------------------------------------------

local secrets = newSuite("secrets")

--- Why the secrets tests are skipped on a client without the two functions.
local SECRETS_SKIP_REASON =
  "the client has no issecretvalue and secretwrap; the secret path was not exercised"

---Register `body` as a test when the client can make a secret value, and as a
---skipped test naming why otherwise.
---@param name string
---@param body fun(ctx: TestKit.Context)
local function secretTest(name, body)
  if SECRETS_ACTIVE then
    secrets:Test(name, body)
  elseif SECRETS_AVAILABLE then
    secrets:Skip(name, Harness.NO_SECRETS_REASON)
  else
    secrets:Skip(name, SECRETS_SKIP_REASON)
  end
end

---A genuine secret value made by the client's `secretwrap`, or a failed test.
---
---`secretwrap` is documented in the client's own API documentation
---(FrameScriptDocumentation, packages/apiKit/metadata/retail/namespaces.json)
---with no restriction and no side effect: it converts the values given to it.
---A secret can only be checked with `issecretvalue` and `type`: comparing it
---with a value of its own type raises on the client.
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
  "a secret maxSections is refused at the calling line with the documented message and the limit is unchanged",
  function(ctx)
    local secretLimit = makeSecret(ctx, 64)
    expectErrorAtCallingLine(
      ctx,
      function(recordLine)
        recordLine()
        ProfileKit:SetLimits({ maxSections = secretLimit })
      end,
      "ProfileKit:SetLimits limits.maxSections must be a positive integer or ProfileKit.UNBOUNDED"
    )
    ctx:Expect(ProfileKit:GetLimits().maxSections):ToBe(remembered.maxSections)
  end
)

secretTest(
  "an enabled Measure hands a secret argument to fn and fn's secret result back still secret, and records the span",
  function(ctx)
    enableProfileKit(ctx)
    ProfileKit:Reset()
    local secretArgument = makeSecret(ctx, 5)
    local receivedSecret = false

    local count, result = countAndFirst(ProfileKit:Measure(SECTION.secret, function(value)
      receivedSecret = isSecretValue(value) == true
      return value, nil
    end, secretArgument))

    ctx:Expect(receivedSecret):ToBe(true)
    ctx:Expect(count):ToBe(2)
    ctx:Expect(isSecretValue(result)):ToBe(true)
    ctx:Expect(type(result)):ToBe("number")
    ctx:Expect(expectRow(ctx, SECTION.secret).count):ToBe(1)
  end
)

-- profileKit.host --------------------------------------------------------------------

local host = newSuite("host")

host:Skip(
  "Enable answers false, unavailable on a host without debugprofilestop",
  "every client publishes debugprofilestop and ProfileKit binds it at load; proven by the Busted specs"
)

host:Skip(
  "an End whose clock reading went backwards drops the sample with nil, clockReset",
  "only debugprofilestart() moves the clock back, and it would reset the timer SchedulerKit and other addons read; proven by the Busted specs"
)
