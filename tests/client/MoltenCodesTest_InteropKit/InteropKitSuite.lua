-- MoltenCodes Test: InteropKitSuite.lua
--
-- Real-client suites for the `interopKit` package. The Busted specs under
-- packages/interopKit/tests/ prove InteropKit against a LibStub stub on a stock
-- Lua 5.1 interpreter; these prove, inside the game client with the installed
-- MoltenCodes addon, what that fixture can only simulate:
--
--   * the installed facade and its committed revision, and whether the session
--     has a global `LibStub` at all (logged: absent, or its minor and the
--     libraries it holds, read without writing);
--   * against a LibStub stand-in (see "The LibStub stand-in" below) when no
--     other addon loaded LibStub: `ExposeToLibStub` of a Kit and of Registry
--     under the default and a custom major, idempotence, raising the minor of
--     an older exposure and never lowering a newer one, the `"taken"`,
--     `"unknown"` and `"unsupported"` refusals, `ExposeAll` over the real
--     Registry rows of this session, and `AdoptFromLibStub`, `Find` and
--     `Adopted` including `Find` still answering after LibStub is gone;
--   * the `"absent"` path of every method when the session has no LibStub;
--   * against a real LibStub another enabled addon loaded, read only: an
--     adoption of one of its libraries, the `"taken"` and `"unknown"`
--     refusals that happen before LibStub is called, and an `ExposeAll` that
--     skips every row, each followed by a check that LibStub's `libs` and
--     `minors` tables hold exactly what they held before;
--   * that `Find` allocates nothing, on the client's own collector;
--   * argument errors, and secret values made by the client's `secretwrap`
--     refused at the calling line in this file as the client names it.
--
-- Which of the stand-in, absent and real-LibStub tests run is decided when the
-- run starts, by whether a global `LibStub` exists: the others end as `SKIP`
-- with the reason. EXPECTED.md lists the lines of both cases.
--
-- The LibStub stand-in. The framework does not require LibStub and this addon
-- does not ship a copy of it: vendoring a third-party library into a test addon
-- is not allowed. When no other addon loaded LibStub, a test that needs one
-- builds a small LibStub-compatible table of its own (`newLibStubStandIn`
-- below; the code is this file's, the behaviour is the one every released
-- LibStub has) and publishes it as the global `LibStub` for the synchronous
-- body of that one test only. `withStandIn` removes it again before the test
-- returns, pass or fail, and every suite's After hook removes it too should a
-- test end any other way. The stand-in is never installed over an existing
-- `LibStub`, and it is removed only while it is still the global and still
-- carries its own `NewLibrary`, so a real LibStub that took the table over
-- would be left alone. Its own minor is 0, below every released LibStub's, so
-- a real LibStub loading in that window would take the table over rather than
-- keep a stand-in.
--
-- Run with `/mct run interopKit`; tests/client/MoltenCodesTest_InteropKit/EXPECTED.md
-- lists what the chat frame should show.
--
-- What a run leaves behind. Nothing is exposed into a real LibStub: every call
-- that reaches one is a refusal made before LibStub is called or a silent
-- `GetLibrary` read, and the tests check that its tables did not change. The
-- stand-in, and everything exposed into it, is gone when each test ends; no
-- global other than the harness's is left. What stays is InteropKit's adoption
-- record, which has no removal method by design (docs/API.md, "Limits"): one
-- entry per major adopted here. The stand-in tests adopt under three majors
-- that start with `MoltenCodesTest-InteropKit-` (`Adopted-1`,
-- `AdoptedBeforeRemoval-1`, `Allocation-1`), each holding a small stand-in
-- table, and the real-LibStub tests adopt one library that LibStub already
-- holds, which only records a reference to it. A second run overwrites the
-- same entries, so the record does not grow. `/reload` clears it.

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
local INTEROP_KIT_API = 1
local PACKAGE_ID = "interopKit"

--- The file name the client puts in front of every error raised at a line of
--- this file.
local THIS_FILE = "InteropKitSuite.lua"

--- The global LibStub publishes itself under.
local LIBSTUB_GLOBAL = "LibStub"

--- The default major InteropKit gives a Kit and Registry (docs/API.md).
local INTEROP_KIT_MAJOR = "MoltenCodes-InteropKit-1"
local REGISTRY_MAJOR = "MoltenCodes-Registry-2"
local DEFAULT_MAJOR_PREFIX = "MoltenCodes-"

--- Every major this file creates starts with this prefix, so no library of
--- another addon can share one.
local TEST_MAJOR_PREFIX = "MoltenCodesTest-InteropKit-"
local ADOPTED_MAJOR = TEST_MAJOR_PREFIX .. "Adopted-1"
local ADOPTED_BEFORE_REMOVAL_MAJOR = TEST_MAJOR_PREFIX .. "AdoptedBeforeRemoval-1"
local ALLOCATION_MAJOR = TEST_MAJOR_PREFIX .. "Allocation-1"
local CUSTOM_MAJOR = TEST_MAJOR_PREFIX .. "Custom-1"
local OLDER_COPY_MAJOR = TEST_MAJOR_PREFIX .. "OlderCopy-1"
local NEWER_COPY_MAJOR = TEST_MAJOR_PREFIX .. "NewerCopy-1"
local FOREIGN_MAJOR = TEST_MAJOR_PREFIX .. "Foreign-1"
local UNUSED_MAJOR = TEST_MAJOR_PREFIX .. "Unused-1"
--- Never registered with any LibStub, and never adopted.
local MISSING_MAJOR = TEST_MAJOR_PREFIX .. "NoSuchLibrary-1"

--- A valid package identifier no package registers.
local UNKNOWN_PACKAGE = "moltenCodesTestNoSuchPackage"

--- An API generation no package registers.
local UNKNOWN_API = 99

--- The minor the stand-in reports for itself: below every released LibStub's
--- own (2), so a real LibStub loading while it is installed takes it over.
local STAND_IN_MINOR = 0

--- How many calls the allocation guard measures, and the kilobytes it
--- tolerates for a stray allocation by the client between two readings.
local ALLOCATION_CALLS = 2000
local ALLOCATION_TOLERANCE_KB = 1

--- Why the stand-in tests are skipped when another addon loaded LibStub.
local REAL_LIBSTUB_SKIP_REASON =
  "another addon loaded LibStub; the stand-in is never installed over it (the realLibStub suite ran instead)"
--- Why the absent tests are skipped when another addon loaded LibStub.
local ABSENT_SKIP_REASON =
  "another addon loaded LibStub, and it is never removed to show the absent path (the realLibStub suite ran instead)"
--- Why the real-LibStub tests are skipped when no addon loaded LibStub.
local NO_LIBSTUB_SKIP_REASON =
  "no enabled addon loaded LibStub; the standIn and absent suites ran instead"

-- Resolving the client and the framework ---------------------------------------------

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- LibStub, `collectgarbage`'s companions and the secret-value functions are
  -- globals, reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Set or remove the global `LibStub`. Only the stand-in this file built is
---ever written, and only while no other `LibStub` exists.
---@param value table|nil
local function writeLibStubGlobal(value)
  -- The stand-in is published under the one name LibStub consumers read.
  -- selene: allow(global_usage)
  rawset(_G, LIBSTUB_GLOBAL, value)
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, REGISTRY_API)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- InteropKit is not in the language-server workspace of tests/client (its
-- .luarc.json lists TestKit's dependency closure only), so its facade is typed
-- `any` here.

---@type any
local InteropKit = Registry:Get(PACKAGE_ID, INTEROP_KIT_API)
if type(InteropKit) == "nil" then
  error(addonName .. " requires InteropKit API 1 in the MoltenCodes addon; reinstall it", 0)
end

--- Read once at load: the secrets suite registers its tests as skipped when
--- the client cannot make a secret value.
local isSecretValue = readHost("issecretvalue")
local secretWrap = readHost("secretwrap")
local SECRETS_AVAILABLE = type(isSecretValue) == "function" and type(secretWrap) == "function"

-- The LibStub stand-in ------------------------------------------------------------------

---What a stand-in counts about the calls it receives, kept beside it so the
---stand-in itself has only the fields a LibStub has.
---@class InteropKitSuite.StandInProbe
---@field newLibraryCalls integer
---@field getLibraryCalls integer
---@field lastSilent any the `silent` argument of the last `GetLibrary` call

---Build a LibStub stand-in and the probe that counts its calls.
---
---The code is this file's; the behaviour is the one every released LibStub
---has, and the one packages/interopKit/tests/support/InteropKitTestEnv.lua
---gives its stub:
---
---* `libs[major]` holds the library table and `minors[major]` its minor.
---* `NewLibrary(major, minor)` raises for a non-string major, reads the first
---  run of digits of `minor` and raises when there is none; returns `nil` when
---  the recorded minor is equal or newer; otherwise records the minor, creates
---  the table on first use and returns it with the previous minor.
---* `GetLibrary(major, silent)` returns the table and its minor, raising at the
---  caller for an unknown major unless `silent`.
---* `IterateLibraries()` is `pairs(libs)`, and calling the table is `GetLibrary`.
---@return table standIn
---@return InteropKitSuite.StandInProbe probe
local function newLibStubStandIn()
  ---@type InteropKitSuite.StandInProbe
  local probe = { newLibraryCalls = 0, getLibraryCalls = 0, lastSilent = nil }
  local standIn = { libs = {}, minors = {}, minor = STAND_IN_MINOR }

  function standIn.NewLibrary(self, major, minor)
    probe.newLibraryCalls = probe.newLibraryCalls + 1
    if type(major) ~= "string" then
      error("Bad argument #2 to `NewLibrary' (string expected)", 2)
    end
    local digits = string.match(tostring(minor), "%d+")
    local number = digits and tonumber(digits) or nil
    if type(number) == "nil" then
      error("Minor version must either be a number or contain a number.", 2)
    end

    local oldMinor = self.minors[major]
    if type(oldMinor) ~= "nil" and oldMinor >= number then
      return nil
    end
    self.minors[major] = number
    self.libs[major] = self.libs[major] or {}
    return self.libs[major], oldMinor
  end

  function standIn.GetLibrary(self, major, silent)
    probe.getLibraryCalls = probe.getLibraryCalls + 1
    probe.lastSilent = silent
    local library = self.libs[major]
    if type(library) == "nil" and not silent then
      error(string.format("Cannot find a library instance of %q.", tostring(major)), 2)
    end
    return library, self.minors[major]
  end

  function standIn.IterateLibraries(self)
    return pairs(self.libs)
  end

  return setmetatable(standIn, {
    __call = function(self, major, silent)
      return self:GetLibrary(major, silent)
    end,
  }),
    probe
end

--- The table this file published as the global `LibStub`, and the
--- `NewLibrary` it carried then; both `nil` while nothing is installed.
---@type table|nil
local installedStandIn = nil
---@type any
local installedNewLibrary = nil

---Remove the stand-in this file installed, if it is still the global and
---still its own. Returns what happened, for the log.
---@return string outcome `"none"`, `"removed"`, or why it was left in place
local function removeStandIn()
  local standIn = installedStandIn
  if type(standIn) == "nil" then
    return "none"
  end
  installedStandIn = nil
  if readHost(LIBSTUB_GLOBAL) ~= standIn then
    return "left in place: the global LibStub is no longer the stand-in"
  end
  if rawget(standIn, "NewLibrary") ~= installedNewLibrary then
    return "left in place: a real LibStub took the stand-in table over"
  end
  writeLibStubGlobal(nil)
  return "removed"
end

---Publish `standIn` as the global `LibStub`, run `body(standIn)` and remove
---the stand-in again, whatever `body` does.
---
---Ends the test as skipped when another addon already loaded LibStub: the
---stand-in is never installed over it. `body` must not yield: the stand-in
---lives only while this synchronous call runs, and a yield across `pcall`
---would raise on Lua 5.1 anyway.
---@param ctx TestKit.Context
---@param standIn table
---@param body fun(standIn: table)
local function withStandIn(ctx, standIn, body)
  if type(readHost(LIBSTUB_GLOBAL)) ~= "nil" then
    Harness:SkipTest(ctx, REAL_LIBSTUB_SKIP_REASON)
    return
  end
  installedStandIn = standIn
  installedNewLibrary = rawget(standIn, "NewLibrary")
  writeLibStubGlobal(standIn)

  local succeeded, problem = pcall(body, standIn)
  local outcome = removeStandIn()
  if outcome ~= "removed" then
    ctx:Log("stand-in " .. outcome)
  end
  if not succeeded then
    error(problem, 0)
  end
end

---The After hook of every suite: remove a stand-in a test left installed.
---@param ctx TestKit.Context
local function cleanUp(ctx)
  local outcome = removeStandIn()
  if outcome ~= "none" then
    ctx:Log("After hook: stand-in " .. outcome)
  end
end

---Register a suite of this package whose tests all end without a stand-in.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName)
  suite:After(cleanUp)
  return suite
end

-- The session's LibStub -----------------------------------------------------------------

---The global `LibStub` another addon loaded, or `nil`. Read only.
---@return table|nil
local function realLibStub()
  local libStub = readHost(LIBSTUB_GLOBAL)
  if type(libStub) ~= "table" then
    return nil
  end
  return libStub
end

---End the test as skipped unless another addon loaded LibStub; return it.
---@param ctx TestKit.Context
---@return table libStub
local function requireRealLibStub(ctx)
  local libStub = realLibStub()
  if type(libStub) == "nil" then
    Harness:SkipTest(ctx, NO_LIBSTUB_SKIP_REASON)
  end
  ---@cast libStub table
  return libStub
end

---End the test as skipped when the session has a global `LibStub`.
---@param ctx TestKit.Context
local function requireNoLibStub(ctx)
  if type(readHost(LIBSTUB_GLOBAL)) ~= "nil" then
    Harness:SkipTest(ctx, ABSENT_SKIP_REASON)
  end
end

---The sorted majors of a LibStub `libs` table whose value is a table.
---@param libs table
---@return string[]
local function sortedMajors(libs)
  local majors = {}
  for major, library in next, libs do
    if type(major) == "string" and type(library) == "table" then
      majors[#majors + 1] = major
    end
  end
  table.sort(majors)
  return majors
end

---The first library major of a real LibStub that is not a MoltenCodes
---exposure (which could be InteropKit's own facade), or `nil`.
---@param libs table
---@return string|nil
local function pickForeignMajor(libs)
  local majors = sortedMajors(libs)
  for index = 1, #majors do
    local major = majors[index]
    if major:sub(1, #DEFAULT_MAJOR_PREFIX) ~= DEFAULT_MAJOR_PREFIX then
      return major
    end
  end
  return nil
end

---A shallow copy of `source`, read raw.
---@param source table
---@return table
local function snapshot(source)
  local copy = {}
  for key, value in next, source do
    copy[key] = value
  end
  return copy
end

---Fail the test unless `current` holds exactly the keys and values `before`
---held, compared by identity; log every difference.
---@param ctx TestKit.Context
---@param label string
---@param current table
---@param before table
local function expectSameEntries(ctx, label, current, before)
  local differences = 0
  for key, value in next, current do
    if rawget(before, key) ~= value then
      differences = differences + 1
      ctx:Log(("%s changed or gained %s"):format(label, tostring(key)))
    end
  end
  for key in next, before do
    if type(rawget(current, key)) == "nil" then
      differences = differences + 1
      ctx:Log(("%s lost %s"):format(label, tostring(key)))
    end
  end
  ctx:Expect(differences):ToBe(0)
end

---The `libs` and `minors` tables of a real LibStub, or a skipped test when it
---does not keep them.
---@param ctx TestKit.Context
---@param libStub table
---@return table libs
---@return table minors
local function realTables(ctx, libStub)
  local libs = rawget(libStub, "libs")
  local minors = rawget(libStub, "minors")
  if type(libs) ~= "table" or type(minors) ~= "table" then
    Harness:SkipTest(ctx, "the loaded LibStub keeps no libs and minors tables")
  end
  return libs, minors
end

-- Registry rows ------------------------------------------------------------------------

---The default major of a package: `"MoltenCodes-<Facade>-<api>"`.
---@param packageName string
---@param api integer
---@return string
local function defaultMajor(packageName, api)
  return DEFAULT_MAJOR_PREFIX .. packageName:sub(1, 1):upper() .. packageName:sub(2) .. "-" .. api
end

---What `ExposeAll(options)` should count for the session's Registry rows,
---when every exposable row is exposed and `refusedPackage` (if any) refused.
---@param rows table[] `Registry:Packages()`
---@param excluded table<string, boolean>
---@param refusedPackage string|nil
---@return integer exposed
---@return integer skipped
---@return integer refused
local function expectedCounts(rows, excluded, refusedPackage)
  local exposed, skipped, refused = 0, 0, 0
  for index = 1, #rows do
    local row = rows[index]
    if excluded[row.package] or row.status ~= "active" then
      skipped = skipped + 1
    elseif row.package == refusedPackage then
      refused = refused + 1
    else
      exposed = exposed + 1
    end
  end
  return exposed, skipped, refused
end

-- Positions and errors ------------------------------------------------------------------------

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
  ctx:Expect((file or ""):sub(-#THIS_FILE)):ToBe(THIS_FILE)
  return line
end

---Call `raise`, which must record its start line with `currentLine()` and
---raise on the next line, and check that the message names this file at that
---next line and ends with `expected`.
---@param ctx TestKit.Context
---@param raise fun() Records its start line in `lineBox.start`, then raises on the next line.
---@param lineBox { start: integer }
---@param expected string The message after the position, compared literally.
local function expectErrorAtCallingLine(ctx, raise, lineBox, expected)
  local succeeded, message = pcall(raise)
  ctx:Expect(succeeded):ToBe(false)
  ctx:Log("client message: " .. tostring(message))

  local line = expectThisFile(ctx, message)
  ctx:Expect(tostring(message):sub(-#expected)):ToBe(expected)
  ctx:Expect(line):ToBe(lineBox.start + 1)
end

-- interopKit.facade --------------------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('interopKit', 1) is the InteropKit facade with API 1 and its six methods",
  function(ctx)
    ctx:Expect(type(InteropKit)):ToBe("table")
    ctx:Expect(rawget(InteropKit, "API")):ToBe(INTEROP_KIT_API)
    ctx:Expect(type(rawget(InteropKit, "REVISION"))):ToBe("number")
    for _, methodName in ipairs({
      "IsLibStubPresent",
      "ExposeToLibStub",
      "ExposeAll",
      "AdoptFromLibStub",
      "Find",
      "Adopted",
    }) do
      ctx:Expect(type(InteropKit[methodName])):ToBe("function")
    end
  end
)

facade:Test("the installed InteropKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      local _, revision = Registry:Get(PACKAGE_ID, INTEROP_KIT_API)
      ctx:Expect(revision):ToBe(expected.revision)
      ctx:Expect(rawget(InteropKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list interopKit")
end)

facade:Test(
  "whether the session has a global LibStub is logged (absent, or its minor and libraries, read only), and IsLibStubPresent agrees",
  function(ctx)
    local libStub = readHost(LIBSTUB_GLOBAL)
    local adoptedRows = InteropKit:Adopted()
    ctx:Log(("InteropKit adoption records at the start: %d"):format(#adoptedRows))
    if type(libStub) == "nil" then
      ctx:Log(
        "global LibStub: absent; the standIn and absent suites run, the realLibStub suite is skipped"
      )
      ctx:Expect(InteropKit:IsLibStubPresent()):ToBe(false)
      return
    end

    ctx:Log("global LibStub: " .. type(libStub) .. ", loaded by another addon")
    if type(libStub) ~= "table" then
      ctx:Expect(InteropKit:IsLibStubPresent()):ToBe(false)
      return
    end
    local hasMethods = type(rawget(libStub, "NewLibrary")) == "function"
      and type(rawget(libStub, "GetLibrary")) == "function"
    ctx:Log(
      ("LibStub.minor %s, NewLibrary %s, GetLibrary %s"):format(
        tostring(rawget(libStub, "minor")),
        type(rawget(libStub, "NewLibrary")),
        type(rawget(libStub, "GetLibrary"))
      )
    )
    ctx:Expect(InteropKit:IsLibStubPresent()):ToBe(hasMethods)

    local libs = rawget(libStub, "libs")
    if type(libs) ~= "table" then
      ctx:Log("LibStub.libs: " .. type(libs))
      return
    end
    local majors = sortedMajors(libs)
    local exposed = {}
    for index = 1, #majors do
      if majors[index]:sub(1, #DEFAULT_MAJOR_PREFIX) == DEFAULT_MAJOR_PREFIX then
        exposed[#exposed + 1] = majors[index]
      end
    end
    ctx:Log(
      ("LibStub holds %d libraries; the first ten: %s"):format(
        #majors,
        table.concat(majors, ", ", 1, math.min(10, #majors))
      )
    )
    ctx:Log(
      "MoltenCodes majors already in LibStub (exposed by another addon): "
        .. (#exposed > 0 and table.concat(exposed, ", ") or "none")
    )
  end
)

-- interopKit.standIn -------------------------------------------------------------------------

local standInSuite = newSuite("standIn")

standInSuite:Test(
  "ExposeToLibStub('interopKit', 1) makes LibStub('MoltenCodes-InteropKit-1') the shared facade at minor REVISION, ExposeToLibStub('registry', 2) does the same for Registry, and exposing again changes nothing",
  function(ctx)
    local standIn, probe = newLibStubStandIn()
    withStandIn(ctx, standIn, function()
      ctx:Expect(InteropKit:IsLibStubPresent()):ToBe(true)
      local revision = rawget(InteropKit, "REVISION")

      local ok, major = InteropKit:ExposeToLibStub("interopKit", 1)
      ctx:Expect(ok):ToBe(true)
      ctx:Expect(major):ToBe(INTEROP_KIT_MAJOR)
      ctx:Expect(rawget(standIn.libs, INTEROP_KIT_MAJOR)):ToBe(InteropKit)
      ctx:Expect(rawget(standIn.minors, INTEROP_KIT_MAJOR)):ToBe(revision)
      local called, calledMinor = standIn(INTEROP_KIT_MAJOR)
      ctx:Expect(called):ToBe(InteropKit)
      ctx:Expect(calledMinor):ToBe(revision)
      ctx:Expect((standIn:GetLibrary(INTEROP_KIT_MAJOR))):ToBe(InteropKit)
      local iterated = false
      for iteratedMajor, library in standIn:IterateLibraries() do
        if iteratedMajor == INTEROP_KIT_MAJOR and library == InteropKit then
          iterated = true
        end
      end
      ctx:Expect(iterated):ToBe(true)
      ctx:Expect(probe.newLibraryCalls):ToBe(1)

      local againOk, againMajor = InteropKit:ExposeToLibStub("interopKit", 1)
      ctx:Expect(againOk):ToBe(true)
      ctx:Expect(againMajor):ToBe(INTEROP_KIT_MAJOR)
      ctx:Expect(probe.newLibraryCalls):ToBe(1)
      ctx:Expect(rawget(standIn.minors, INTEROP_KIT_MAJOR)):ToBe(revision)

      local registryOk, registryMajor = InteropKit:ExposeToLibStub("registry", 2)
      ctx:Expect(registryOk):ToBe(true)
      ctx:Expect(registryMajor):ToBe(REGISTRY_MAJOR)
      ctx:Expect(rawget(standIn.libs, REGISTRY_MAJOR)):ToBe(Registry)
      ctx:Expect(rawget(standIn.minors, REGISTRY_MAJOR)):ToBe(rawget(Registry, "REVISION"))
      ctx:Log(
        ("exposed %s at minor %d and %s at minor %d"):format(
          INTEROP_KIT_MAJOR,
          revision,
          REGISTRY_MAJOR,
          rawget(Registry, "REVISION")
        )
      )
    end)
  end
)

standInSuite:Test(
  "a custom major is honoured, an older exposure of the facade is raised to the current revision in the same table, and a newer one is never lowered",
  function(ctx)
    local standIn, probe = newLibStubStandIn()
    withStandIn(ctx, standIn, function()
      local revision = rawget(InteropKit, "REVISION")

      local ok, major = InteropKit:ExposeToLibStub("interopKit", 1, CUSTOM_MAJOR)
      ctx:Expect(ok):ToBe(true)
      ctx:Expect(major):ToBe(CUSTOM_MAJOR)
      ctx:Expect(rawget(standIn.libs, CUSTOM_MAJOR)):ToBe(InteropKit)
      ctx:Expect(rawget(standIn.libs, INTEROP_KIT_MAJOR)):ToBeNil()

      -- What LibStub holds after an older copy of InteropKit exposed itself:
      -- the same facade table at a lower minor.
      standIn.libs[OLDER_COPY_MAJOR] = InteropKit
      standIn.minors[OLDER_COPY_MAJOR] = revision - 1
      local callsBefore = probe.newLibraryCalls
      local olderOk = InteropKit:ExposeToLibStub("interopKit", 1, OLDER_COPY_MAJOR)
      ctx:Expect(olderOk):ToBe(true)
      ctx:Expect(probe.newLibraryCalls):ToBe(callsBefore + 1)
      ctx:Expect(rawget(standIn.libs, OLDER_COPY_MAJOR)):ToBe(InteropKit)
      ctx:Expect(rawget(standIn.minors, OLDER_COPY_MAJOR)):ToBe(revision)

      -- What LibStub holds after a newer copy exposed itself.
      standIn.libs[NEWER_COPY_MAJOR] = InteropKit
      standIn.minors[NEWER_COPY_MAJOR] = revision + 5
      callsBefore = probe.newLibraryCalls
      local newerOk = InteropKit:ExposeToLibStub("interopKit", 1, NEWER_COPY_MAJOR)
      ctx:Expect(newerOk):ToBe(true)
      ctx:Expect(probe.newLibraryCalls):ToBe(callsBefore)
      ctx:Expect(rawget(standIn.minors, NEWER_COPY_MAJOR)):ToBe(revision + 5)
    end)
  end
)

standInSuite:Test(
  "a major another library holds is refused with false, 'taken' before LibStub is called, and that library and its minor stay as they were",
  function(ctx)
    local standIn, probe = newLibStubStandIn()
    withStandIn(ctx, standIn, function()
      local foreign = standIn:NewLibrary(FOREIGN_MAJOR, 7)
      foreign.owner = "another addon"
      local foreignBefore = snapshot(foreign)
      local callsBefore = probe.newLibraryCalls

      local ok, reason, extra = InteropKit:ExposeToLibStub("interopKit", 1, FOREIGN_MAJOR)
      ctx:Expect(ok):ToBe(false)
      ctx:Expect(reason):ToBe("taken")
      ctx:Expect(extra):ToBeNil()
      ctx:Expect(probe.newLibraryCalls):ToBe(callsBefore)
      ctx:Expect(rawget(standIn.libs, FOREIGN_MAJOR)):ToBe(foreign)
      ctx:Expect(rawget(standIn.minors, FOREIGN_MAJOR)):ToBe(7)
      expectSameEntries(ctx, "the foreign library", foreign, foreignBefore)
    end)
  end
)

standInSuite:Test(
  "an unknown package or API generation answers false, 'unknown' with Registry's reason, a LibStub without libs and minors answers 'unsupported', and a LibStub without NewLibrary counts as absent; nothing raises and nothing is written",
  function(ctx)
    local standIn, probe = newLibStubStandIn()
    withStandIn(ctx, standIn, function()
      local ok, reason, registryReason = InteropKit:ExposeToLibStub(UNKNOWN_PACKAGE, 1)
      ctx:Log("unknown package: " .. tostring(reason) .. ", " .. tostring(registryReason))
      ctx:Expect(ok):ToBe(false)
      ctx:Expect(reason):ToBe("unknown")
      ctx:Expect(registryReason):ToBe("absent")

      ok, reason, registryReason = InteropKit:ExposeToLibStub("interopKit", UNKNOWN_API)
      ctx:Log("unknown API generation: " .. tostring(reason) .. ", " .. tostring(registryReason))
      ctx:Expect(ok):ToBe(false)
      ctx:Expect(reason):ToBe("unknown")
      ctx:Expect(registryReason):ToBe("generation_mismatch")

      ok, reason, registryReason = InteropKit:ExposeToLibStub("registry", UNKNOWN_API)
      ctx:Expect(ok):ToBe(false)
      ctx:Expect(reason):ToBe("unknown")
      ctx:Expect(registryReason):ToBe("generation_mismatch")

      ctx:Expect(probe.newLibraryCalls):ToBe(0)
      ctx:Expect((next(standIn.libs))):ToBeNil()
      ctx:Expect((next(standIn.minors))):ToBeNil()
    end)

    -- A LibStub-like table with both methods but none of LibStub's tables.
    local bareStandIn, bareProbe = newLibStubStandIn()
    bareStandIn.libs = nil
    bareStandIn.minors = nil
    withStandIn(ctx, bareStandIn, function()
      ctx:Expect(InteropKit:IsLibStubPresent()):ToBe(true)
      local ok, reason = InteropKit:ExposeToLibStub("interopKit", 1)
      ctx:Expect(ok):ToBe(false)
      ctx:Expect(reason):ToBe("unsupported")
      ctx:Expect(bareProbe.newLibraryCalls):ToBe(0)
      ctx:Expect(rawget(bareStandIn, "libs")):ToBeNil()
      ctx:Expect(rawget(bareStandIn, "minors")):ToBeNil()
    end)

    -- A global LibStub table without NewLibrary is not a LibStub to InteropKit.
    local partialStandIn = newLibStubStandIn()
    partialStandIn.NewLibrary = nil
    withStandIn(ctx, partialStandIn, function()
      ctx:Expect(InteropKit:IsLibStubPresent()):ToBe(false)
      local ok, reason = InteropKit:ExposeToLibStub("interopKit", 1)
      ctx:Expect(ok):ToBe(false)
      ctx:Expect(reason):ToBe("absent")
      local library, adoptReason = InteropKit:AdoptFromLibStub(MISSING_MAJOR)
      ctx:Expect(library):ToBeNil()
      ctx:Expect(adoptReason):ToBe("absent")
      ctx:Expect((next(partialStandIn.libs))):ToBeNil()
    end)
  end
)

standInSuite:Test(
  "ExposeAll exposes every active Registry row of this session under its default major, skips options.except and retired rows, counts a row whose major a foreign library holds as refused, and is idempotent",
  function(ctx)
    local rows = Registry:Packages()
    local victim = nil
    for index = 1, #rows do
      local row = rows[index]
      if victim == nil and row.status == "active" and row.package ~= PACKAGE_ID then
        victim = row
      end
    end
    if victim == nil then
      ctx:Fail("Registry lists no active package other than interopKit")
      return
    end

    local standIn, probe = newLibStubStandIn()
    withStandIn(ctx, standIn, function()
      local victimMajor = defaultMajor(victim.package, victim.api)
      local foreign = standIn:NewLibrary(victimMajor, 1)
      local callsBefore = probe.newLibraryCalls

      local excluded = { [PACKAGE_ID] = true }
      local expectedExposed, expectedSkipped, expectedRefused =
        expectedCounts(rows, excluded, victim.package)
      local exposed, skipped, refused = InteropKit:ExposeAll({ except = { PACKAGE_ID } })
      ctx:Log(
        ("%d Registry rows: exposed %d, skipped %d, refused %d (foreign library under %s)"):format(
          #rows,
          exposed,
          skipped,
          refused,
          victimMajor
        )
      )
      ctx:Expect(exposed):ToBe(expectedExposed)
      ctx:Expect(skipped):ToBe(expectedSkipped)
      ctx:Expect(refused):ToBe(expectedRefused)
      ctx:Expect(probe.newLibraryCalls):ToBe(callsBefore + expectedExposed)

      for index = 1, #rows do
        local row = rows[index]
        local major = defaultMajor(row.package, row.api)
        if row.status == "active" and row.package ~= PACKAGE_ID and row ~= victim then
          local registered = Registry:Find(row.package, row.api)
          ctx:Expect(rawget(standIn.libs, major)):ToBe(registered)
          ctx:Expect(rawget(standIn.minors, major)):ToBe(row.revision)
        end
      end
      ctx:Expect(rawget(standIn.libs, INTEROP_KIT_MAJOR)):ToBeNil()
      ctx:Expect(rawget(standIn.libs, REGISTRY_MAJOR)):ToBeNil()
      ctx:Expect(rawget(standIn.libs, victimMajor)):ToBe(foreign)
      ctx:Expect(rawget(standIn.minors, victimMajor)):ToBe(1)

      callsBefore = probe.newLibraryCalls
      local againExposed, againSkipped, againRefused =
        InteropKit:ExposeAll({ except = { PACKAGE_ID } })
      ctx:Expect(againExposed):ToBe(expectedExposed)
      ctx:Expect(againSkipped):ToBe(expectedSkipped)
      ctx:Expect(againRefused):ToBe(expectedRefused)
      ctx:Expect(probe.newLibraryCalls):ToBe(callsBefore)
    end)
  end
)

standInSuite:Test(
  "AdoptFromLibStub reads a library through the silent GetLibrary and records it; Find answers from the record, Adopted lists it sorted, adopting again refreshes the minor, and the library is never written",
  function(ctx)
    local standIn, probe = newLibStubStandIn()
    withStandIn(ctx, standIn, function()
      local library = standIn:NewLibrary(ADOPTED_MAJOR, 3)
      library.value = "kept"
      local libraryBefore = snapshot(library)

      local adopted, minor = InteropKit:AdoptFromLibStub(ADOPTED_MAJOR)
      ctx:Expect(adopted):ToBe(library)
      ctx:Expect(minor):ToBe(3)
      ctx:Expect(probe.lastSilent):ToBe(true)
      local found, foundMinor = InteropKit:Find(ADOPTED_MAJOR)
      ctx:Expect(found):ToBe(library)
      ctx:Expect(foundMinor):ToBe(3)

      -- The library upgrades itself in place; the record keeps the minor of
      -- the last adoption until the library is adopted again.
      ctx:Expect((standIn:NewLibrary(ADOPTED_MAJOR, 5))):ToBe(library)
      found, foundMinor = InteropKit:Find(ADOPTED_MAJOR)
      ctx:Expect(found):ToBe(library)
      ctx:Expect(foundMinor):ToBe(3)
      adopted, minor = InteropKit:AdoptFromLibStub(ADOPTED_MAJOR)
      ctx:Expect(adopted):ToBe(library)
      ctx:Expect(minor):ToBe(5)
      found, foundMinor = InteropKit:Find(ADOPTED_MAJOR)
      ctx:Expect(foundMinor):ToBe(5)

      local missing, missingReason = InteropKit:AdoptFromLibStub(MISSING_MAJOR)
      ctx:Expect(missing):ToBeNil()
      ctx:Expect(missingReason):ToBe("unknown")
      ctx:Expect(probe.lastSilent):ToBe(true)
      ctx:Expect(rawget(standIn.libs, MISSING_MAJOR)):ToBeNil()
      local notFound, notFoundReason = InteropKit:Find(MISSING_MAJOR)
      ctx:Expect(notFound):ToBeNil()
      ctx:Expect(notFoundReason):ToBe("unknown")

      local rows = InteropKit:Adopted()
      local listed = nil
      for index = 1, #rows do
        if index > 1 then
          ctx:Expect(rows[index - 1].major < rows[index].major):ToBe(true)
        end
        if rows[index].major == ADOPTED_MAJOR then
          listed = rows[index]
        end
        ctx:Expect(rows[index].major == MISSING_MAJOR):ToBe(false)
      end
      ctx:Expect(listed):ToEqual({ major = ADOPTED_MAJOR, minor = 5 })
      ctx:Expect(InteropKit:Adopted() ~= rows):ToBe(true)
      ctx:Log(("Adopted() lists %d records"):format(#rows))

      expectSameEntries(ctx, "the adopted library", library, libraryBefore)
      ctx:Expect(rawget(standIn.minors, ADOPTED_MAJOR)):ToBe(5)
    end)
  end
)

standInSuite:Test(
  "Find keeps answering an adoption after the global LibStub is gone, while AdoptFromLibStub and ExposeToLibStub then answer 'absent' and the record stays",
  function(ctx)
    local standIn = newLibStubStandIn()
    local library = nil
    withStandIn(ctx, standIn, function()
      library = standIn:NewLibrary(ADOPTED_BEFORE_REMOVAL_MAJOR, 4)
      local adopted = InteropKit:AdoptFromLibStub(ADOPTED_BEFORE_REMOVAL_MAJOR)
      ctx:Expect(adopted):ToBe(library)
    end)

    ctx:Expect(readHost(LIBSTUB_GLOBAL)):ToBeNil()
    ctx:Expect(InteropKit:IsLibStubPresent()):ToBe(false)
    local found, minor = InteropKit:Find(ADOPTED_BEFORE_REMOVAL_MAJOR)
    ctx:Expect(found):ToBe(library)
    ctx:Expect(minor):ToBe(4)

    local again, reason = InteropKit:AdoptFromLibStub(ADOPTED_BEFORE_REMOVAL_MAJOR)
    ctx:Expect(again):ToBeNil()
    ctx:Expect(reason):ToBe("absent")
    local ok, exposeReason = InteropKit:ExposeToLibStub("interopKit", 1)
    ctx:Expect(ok):ToBe(false)
    ctx:Expect(exposeReason):ToBe("absent")

    found, minor = InteropKit:Find(ADOPTED_BEFORE_REMOVAL_MAJOR)
    ctx:Expect(found):ToBe(library)
    ctx:Expect(minor):ToBe(4)
  end
)

-- interopKit.absent --------------------------------------------------------------------------

local absent = newSuite("absent")

absent:Test(
  "with no LibStub at all, IsLibStubPresent is false, ExposeToLibStub answers false, 'absent' even for an unknown package, AdoptFromLibStub nil, 'absent', and Find nil, 'unknown', without raising or creating a LibStub",
  function(ctx)
    requireNoLibStub(ctx)
    local recordsBefore = #InteropKit:Adopted()

    ctx:Expect(InteropKit:IsLibStubPresent()):ToBe(false)
    for _, case in ipairs({
      { packageName = "interopKit", api = 1 },
      { packageName = "registry", api = 2 },
      { packageName = UNKNOWN_PACKAGE, api = 1 },
    }) do
      local ok, reason, extra = InteropKit:ExposeToLibStub(case.packageName, case.api)
      ctx:Expect(ok):ToBe(false)
      ctx:Expect(reason):ToBe("absent")
      ctx:Expect(extra):ToBeNil()
    end
    local ok, reason = InteropKit:ExposeToLibStub("interopKit", 1, CUSTOM_MAJOR)
    ctx:Expect(ok):ToBe(false)
    ctx:Expect(reason):ToBe("absent")

    local library, adoptReason = InteropKit:AdoptFromLibStub(MISSING_MAJOR)
    ctx:Expect(library):ToBeNil()
    ctx:Expect(adoptReason):ToBe("absent")
    local found, findReason = InteropKit:Find(MISSING_MAJOR)
    ctx:Expect(found):ToBeNil()
    ctx:Expect(findReason):ToBe("unknown")

    ctx:Expect(#InteropKit:Adopted()):ToBe(recordsBefore)
    ctx:Expect(readHost(LIBSTUB_GLOBAL)):ToBeNil()
  end
)

absent:Test(
  "with no LibStub at all, ExposeAll counts every active row it would expose as refused and the rest as skipped, with and without options.except",
  function(ctx)
    requireNoLibStub(ctx)
    local rows = Registry:Packages()

    local exposable, notActive = 0, 0
    for index = 1, #rows do
      if rows[index].status == "active" then
        exposable = exposable + 1
      else
        notActive = notActive + 1
      end
    end
    local exposed, skipped, refused = InteropKit:ExposeAll()
    ctx:Log(
      ("%d Registry rows: exposed %d, skipped %d, refused %d"):format(
        #rows,
        exposed,
        skipped,
        refused
      )
    )
    ctx:Expect(exposed):ToBe(0)
    ctx:Expect(skipped):ToBe(notActive)
    ctx:Expect(refused):ToBe(exposable)

    local excluded = { [PACKAGE_ID] = true }
    local wouldExpose, expectedSkipped = expectedCounts(rows, excluded, nil)
    exposed, skipped, refused = InteropKit:ExposeAll({ except = { PACKAGE_ID } })
    ctx:Expect(exposed):ToBe(0)
    ctx:Expect(skipped):ToBe(expectedSkipped)
    ctx:Expect(refused):ToBe(wouldExpose)
    ctx:Expect(readHost(LIBSTUB_GLOBAL)):ToBeNil()
  end
)

-- interopKit.realLibStub ---------------------------------------------------------------------

local realSuite = newSuite("realLibStub")

realSuite:Test(
  "a LibStub another addon loaded is only read: AdoptFromLibStub of one of its libraries returns LibStub's own table and minor, Find agrees, an unknown major answers 'unknown', and LibStub's libs and minors are unchanged",
  function(ctx)
    local libStub = requireRealLibStub(ctx)
    ctx:Expect(InteropKit:IsLibStubPresent()):ToBe(true)
    local libs, minors = realTables(ctx, libStub)
    local major = pickForeignMajor(libs)
    if type(major) == "nil" then
      Harness:SkipTest(ctx, "the loaded LibStub holds no library other than MoltenCodes exposures")
    end
    ---@cast major string
    local libsBefore = snapshot(libs)
    local minorsBefore = snapshot(minors)

    local expected, expectedMinor = rawget(libStub, "GetLibrary")(libStub, major, true)
    local library, minor = InteropKit:AdoptFromLibStub(major)
    ctx:Log(("adopted %s at minor %s"):format(major, tostring(minor)))
    ctx:Expect(library):ToBe(expected)
    ctx:Expect(minor):ToBe(expectedMinor)
    local found, foundMinor = InteropKit:Find(major)
    ctx:Expect(found):ToBe(expected)
    ctx:Expect(foundMinor):ToBe(expectedMinor)

    local missing, reason = InteropKit:AdoptFromLibStub(MISSING_MAJOR)
    ctx:Expect(missing):ToBeNil()
    ctx:Expect(reason):ToBe("unknown")

    expectSameEntries(ctx, "LibStub.libs", libs, libsBefore)
    expectSameEntries(ctx, "LibStub.minors", minors, minorsBefore)
  end
)

realSuite:Test(
  "a real LibStub's library is never overwritten: ExposeToLibStub under its major answers false, 'taken', an unknown package answers 'unknown', both before LibStub is called, and LibStub's tables are unchanged",
  function(ctx)
    local libStub = requireRealLibStub(ctx)
    local libs, minors = realTables(ctx, libStub)
    local major = pickForeignMajor(libs)
    if type(major) == "nil" then
      Harness:SkipTest(ctx, "the loaded LibStub holds no library other than MoltenCodes exposures")
    end
    ---@cast major string
    local libsBefore = snapshot(libs)
    local minorsBefore = snapshot(minors)

    local ok, reason = InteropKit:ExposeToLibStub("interopKit", 1, major)
    ctx:Log(("ExposeToLibStub under %s: %s, %s"):format(major, tostring(ok), tostring(reason)))
    ctx:Expect(ok):ToBe(false)
    ctx:Expect(reason):ToBe("taken")

    local unknownOk, unknownReason, registryReason =
      InteropKit:ExposeToLibStub(UNKNOWN_PACKAGE, 1, UNUSED_MAJOR)
    ctx:Expect(unknownOk):ToBe(false)
    ctx:Expect(unknownReason):ToBe("unknown")
    ctx:Expect(registryReason):ToBe("absent")
    ctx:Expect(rawget(libs, UNUSED_MAJOR)):ToBeNil()

    expectSameEntries(ctx, "LibStub.libs", libs, libsBefore)
    expectSameEntries(ctx, "LibStub.minors", minors, minorsBefore)
  end
)

realSuite:Test(
  "ExposeAll with every Registry row in options.except registers nothing in a real LibStub and counts every row as skipped",
  function(ctx)
    local libStub = requireRealLibStub(ctx)
    local libs, minors = realTables(ctx, libStub)
    local libsBefore = snapshot(libs)
    local minorsBefore = snapshot(minors)

    local rows = Registry:Packages()
    local except = {}
    for index = 1, #rows do
      except[#except + 1] = rows[index].package
    end
    local exposed, skipped, refused = InteropKit:ExposeAll({ except = except })
    ctx:Expect(exposed):ToBe(0)
    ctx:Expect(skipped):ToBe(#rows)
    ctx:Expect(refused):ToBe(0)

    expectSameEntries(ctx, "LibStub.libs", libs, libsBefore)
    expectSameEntries(ctx, "LibStub.minors", minors, minorsBefore)
  end
)

-- interopKit.allocation ----------------------------------------------------------------------

local allocation = newSuite("allocation")

---Collect in a step of its own, run one unmeasured warm-up call, then run
---`operation` `ALLOCATION_CALLS` times, log how far the heap grew and hold it
---to the tolerance.
---
---The collection gets its own step so the measurement starts far from the next
---collector cycle. The warm-up comes after it because the first call after a
---full collection can regrow the coroutine stack or other bookkeeping once,
---which is not the per-call cost docs/API.md promises is zero.
---@param ctx TestKit.Context
---@param label string what `operation` does, for the log
---@param operation fun()
local function expectNoAllocation(ctx, label, operation)
  collectgarbage("collect")
  ctx:Yield()
  operation()
  local before = collectgarbage("count")
  for _ = 1, ALLOCATION_CALLS do
    operation()
  end
  local grownKilobytes = collectgarbage("count") - before
  ctx:Log(
    ("memory delta over %d calls of %s: %.3f KB"):format(ALLOCATION_CALLS, label, grownKilobytes)
  )
  ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
end

allocation:Test(
  "Find of an adopted major and of a never-adopted major allocates nothing over 2000 calls each",
  function(ctx)
    local major = nil
    local libStub = realLibStub()
    if type(libStub) ~= "nil" then
      local libs = realTables(ctx, libStub)
      major = pickForeignMajor(libs)
      if type(major) == "nil" then
        Harness:SkipTest(
          ctx,
          "the loaded LibStub holds no library other than MoltenCodes exposures"
        )
      end
      InteropKit:AdoptFromLibStub(major)
    else
      local standIn = newLibStubStandIn()
      withStandIn(ctx, standIn, function()
        standIn:NewLibrary(ALLOCATION_MAJOR, 1)
        InteropKit:AdoptFromLibStub(ALLOCATION_MAJOR)
      end)
      major = ALLOCATION_MAJOR
    end
    ---@cast major string
    ctx:Expect(type((InteropKit:Find(major)))):ToBe("table")

    expectNoAllocation(ctx, "Find of an adopted major", function()
      InteropKit:Find(major)
    end)
    expectNoAllocation(ctx, "Find of a never-adopted major", function()
      InteropKit:Find(MISSING_MAJOR)
    end)
  end
)

-- interopKit.errors --------------------------------------------------------------------------

local errors = newSuite("errors")

errors:Test(
  "ExposeToLibStub refuses a packageName that is not a string, is empty or is not a package identifier, and an api of 0, 1.5 or '1', at the calling line",
  function(ctx)
    local lines = { start = 0 }
    local notString = "InteropKit:ExposeToLibStub packageName must be a non-empty string"
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      InteropKit:ExposeToLibStub(42, 1)
    end, lines, notString)
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      InteropKit:ExposeToLibStub("", 1)
    end, lines, notString)
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      InteropKit:ExposeToLibStub("Event-Kit", 1)
    end, lines, "InteropKit:ExposeToLibStub packageName must match ^[a-z][A-Za-z0-9]*$")
    local badApi = "InteropKit:ExposeToLibStub api must be a positive integer"
    for _, api in ipairs({ 0, 1.5, "1" }) do
      expectErrorAtCallingLine(ctx, function()
        lines.start = currentLine()
        InteropKit:ExposeToLibStub("interopKit", api)
      end, lines, badApi)
    end
  end
)

errors:Test(
  "a major that is empty or not a string is refused by ExposeToLibStub, AdoptFromLibStub and Find at the calling line",
  function(ctx)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      InteropKit:ExposeToLibStub("interopKit", 1, "")
    end, lines, "InteropKit:ExposeToLibStub major must be a non-empty string")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      InteropKit:AdoptFromLibStub(nil)
    end, lines, "InteropKit:AdoptFromLibStub major must be a non-empty string")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      InteropKit:AdoptFromLibStub("")
    end, lines, "InteropKit:AdoptFromLibStub major must be a non-empty string")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      InteropKit:Find({})
    end, lines, "InteropKit:Find major must be a non-empty string")
  end
)

errors:Test(
  "ExposeAll refuses options that are not a table, an except that is not a table and an except entry that is not a package identifier, at the calling line",
  function(ctx)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      InteropKit:ExposeAll("hookKit")
    end, lines, "InteropKit:ExposeAll options must be a table or nil")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      InteropKit:ExposeAll({ except = "hookKit" })
    end, lines, "InteropKit:ExposeAll options.except must be an array of package names")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      InteropKit:ExposeAll({ except = { 5 } })
    end, lines, "InteropKit:ExposeAll packageName must be a non-empty string")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      InteropKit:ExposeAll({ except = { "Hook Kit" } })
    end, lines, "InteropKit:ExposeAll packageName must match ^[a-z][A-Za-z0-9]*$")
  end
)

-- interopKit.secrets -------------------------------------------------------------------------

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
---Only `issecretvalue` and `type` ever look at the result here: docs/EMBEDDING.md
---("Measured on the client") lists what else raises.
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

---What the session's LibStub looks like, so a test can check a refusal left
---it alone: the global itself and, for a table, shallow copies of its
---`libs` and `minors`.
---@class InteropKitSuite.LibStubState
---@field global any
---@field libs table|nil
---@field minors table|nil

---Read the session's LibStub state.
---@return InteropKitSuite.LibStubState
local function captureLibStubState()
  local global = readHost(LIBSTUB_GLOBAL)
  local state = { global = global, libs = nil, minors = nil }
  if type(global) == "table" then
    local libs = rawget(global, "libs")
    local minors = rawget(global, "minors")
    state.libs = type(libs) == "table" and snapshot(libs) or nil
    state.minors = type(minors) == "table" and snapshot(minors) or nil
  end
  return state
end

---Fail the test unless the session's LibStub is as `before` recorded it.
---@param ctx TestKit.Context
---@param before InteropKitSuite.LibStubState
local function expectLibStubUnchanged(ctx, before)
  local global = readHost(LIBSTUB_GLOBAL)
  ctx:Expect(global):ToBe(before.global)
  if type(global) == "table" and type(before.libs) == "table" then
    expectSameEntries(ctx, "LibStub.libs", rawget(global, "libs"), before.libs)
  end
  if type(global) == "table" and type(before.minors) == "table" then
    expectSameEntries(ctx, "LibStub.minors", rawget(global, "minors"), before.minors)
  end
end

secretTest(
  "a secret packageName, api or major handed to ExposeToLibStub is refused at the calling line before anything compares it, and LibStub is left as it was",
  function(ctx)
    local before = captureLibStubState()
    local secretName = makeSecret(ctx, "interopKit")
    local secretApi = makeSecret(ctx, 1)
    local secretMajor = makeSecret(ctx, CUSTOM_MAJOR)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      InteropKit:ExposeToLibStub(secretName, 1)
    end, lines, "InteropKit:ExposeToLibStub packageName must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      InteropKit:ExposeToLibStub("interopKit", secretApi)
    end, lines, "InteropKit:ExposeToLibStub api must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      InteropKit:ExposeToLibStub("interopKit", 1, secretMajor)
    end, lines, "InteropKit:ExposeToLibStub major must not be a secret value")
    expectLibStubUnchanged(ctx, before)
  end
)

secretTest(
  "a secret major handed to AdoptFromLibStub and Find is refused at the calling line, and the adoption record is unchanged",
  function(ctx)
    local recordsBefore = #InteropKit:Adopted()
    local secretMajor = makeSecret(ctx, MISSING_MAJOR)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      InteropKit:AdoptFromLibStub(secretMajor)
    end, lines, "InteropKit:AdoptFromLibStub major must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      InteropKit:Find(secretMajor)
    end, lines, "InteropKit:Find major must not be a secret value")
    ctx:Expect(#InteropKit:Adopted()):ToBe(recordsBefore)
  end
)

secretTest(
  "a secret package name inside ExposeAll's options.except, first or after a plain one, is refused at the calling line before any row is exposed",
  function(ctx)
    local before = captureLibStubState()
    local secretName = makeSecret(ctx, "hookKit")
    local lines = { start = 0 }
    local expected = "InteropKit:ExposeAll packageName must not be a secret value"
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      InteropKit:ExposeAll({ except = { secretName } })
    end, lines, expected)
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      InteropKit:ExposeAll({ except = { PACKAGE_ID, secretName } })
    end, lines, expected)
    expectLibStubUnchanged(ctx, before)
  end
)
