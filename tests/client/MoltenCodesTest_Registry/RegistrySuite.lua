-- MoltenCodes Test: RegistrySuite.lua
--
-- Real-client suites for the `registry` package. The Busted specs under
-- packages/registry/tests/ prove Registry against a fake global environment;
-- these prove, inside the game client with the installed MoltenCodes addon,
-- what that fixture can only simulate:
--
--   * the published namespace (`MoltenCodes.Registries[2]`, the alias) and the
--     committed revision of every installed Kit, as the client actually loaded
--     them;
--   * `Find` and `Get` on the client's Lua, with its real garbage collector;
--   * `Bootstrap` in the live session: first registration, a same-revision
--     copy, an upgrade in place, a downgrade that steps aside, the retire hook;
--   * argument errors pointing at this file as the client names it;
--   * that the framework publishes no global beyond the ones
--     docs/EMBEDDING.md names.
--
-- Run with `/mct run registry`; tests/client/MoltenCodesTest_Registry/EXPECTED.md
-- lists what the chat frame should show.
--
-- What a run leaves behind. Registry has no way to remove a registration, so
-- every Bootstrap test registers a probe package under a fresh ID
-- (`mctRegistryProbe1`, `mctRegistryProbe2`, ...) that stays registered, with
-- its retire hook, until the next `/reload`. The IDs never collide with a real
-- package, and fresh IDs keep every test independent of the others and of an
-- earlier run in the same session. Nothing is written to a global or a saved
-- variable. Every Kit is per-session (docs/EMBEDDING.md, "/reload and saved
-- variables"), so persistence across `/reload` is deliberately not tested.

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
local PACKAGE_ID = "registry"

--- Probe package IDs start with this; a counter makes each one fresh.
local PROBE_PREFIX = "mctRegistryProbe"

--- The API generation every probe copy claims.
local PROBE_API = 1

--- How many times the allocation guard calls `Find` and `Get` each.
local ALLOCATION_CALLS = 10000

--- Kilobytes the allocation guard tolerates. One table per call would cost
--- hundreds of kilobytes over 10000 calls; the tolerance absorbs a stray
--- allocation by the client between the two readings, not a per-call one.
local ALLOCATION_TOLERANCE_KB = 1

--- Every method docs/API.md of registry lists on the facade.
local FACADE_METHODS = { "Register", "Get", "GetInfo", "Find", "Packages", "OnRetire", "Bootstrap" }

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, REGISTRY_API)

local probeSequence = 0

-- Helpers ---------------------------------------------------------------------------

---A package ID no earlier test or run of this session registered.
---@return string
local function freshProbeId()
  probeSequence = probeSequence + 1
  return PROBE_PREFIX .. probeSequence
end

---Whether a probe copy exposes its public surface: the one method it installs.
---@param implementation table
---@return boolean
local function probeSurfaceIsComplete(implementation)
  return type(rawget(implementation, "Ping")) == "function"
end

---Bootstrap one copy of a probe package the way a Kit file bootstraps itself.
---
---`extra` adds request fields (`retire`, `migrations`). A copy Registry
---accepts installs `Ping`, which answers the copy's revision, so a test can
---tell which copy's code a cached reference runs, and then publishes `API`
---and `REVISION`, as every Kit does last.
---@param packageId string
---@param revision integer
---@param extra table|nil
---@return table|nil implementation
---@return integer|nil previousRevision
---@return table|nil selected
---@return any state
local function bootstrapProbe(packageId, revision, extra)
  local request = {
    package = packageId,
    api = PROBE_API,
    revision = revision,
    label = "MoltenCodesTest registry probe",
    validatePublicSurface = probeSurfaceIsComplete,
  }
  for key, value in pairs(extra or {}) do
    request[key] = value
  end

  local implementation, previousRevision, selected, state = Registry:Bootstrap(request)
  if type(implementation) == "table" then
    -- Registry trusts a copy only when its facade carries API and REVISION,
    -- which a Kit publishes once its implementation is installed.
    rawset(implementation, "API", PROBE_API)
    rawset(implementation, "REVISION", revision)
    rawset(implementation, "Ping", function()
      return revision
    end)
  end
  return implementation, previousRevision, selected, state
end

---The `file:line: ` prefix of the line that called the function calling this.
---
---`error` with level 3, raised under `pcall`, names the caller of this
---function's caller: level 1 is `pcall` itself, 2 is this function, 3 the test.
---@return string position
local function callerPosition()
  local _, position = pcall(error, "", 3)
  return position or ""
end

---Split a `file:line: ` prefix into the file as the client names it and the line.
---@param position string
---@return string|nil file
---@return integer|nil line
local function splitPosition(position)
  local file, line = position:match("^(.-):(%d+): ")
  return file, tonumber(line)
end

---Call `raise`, which must raise on the line after it records `startLine`, and
---check the message names this file at that line and carries `expected`.
---@param ctx TestKit.Context
---@param raise fun() Records its start line, then raises on the next line.
---@param expected string The message after the position, compared literally.
---@return integer|nil line The line the message names.
local function expectErrorAtCallingLine(ctx, raise, expected)
  local succeeded, message = pcall(raise)
  ctx:Expect(succeeded):ToBe(false)
  ctx:Expect(type(message)):ToBe("string")
  ctx:Log("client message: " .. message)

  local file, line = splitPosition(message)
  ctx:Expect(type(file)):ToBe("string")
  ctx:Expect((file or ""):sub(-#"RegistrySuite.lua")):ToBe("RegistrySuite.lua")
  ctx:Expect(message:sub(-#expected)):ToBe(expected)
  return line
end

-- registry.facade ---------------------------------------------------------------------

local facade = Harness:Suite(PACKAGE_ID, "facade", addonName)

facade:Test(
  "MoltenCodes.Registries[2] is the Registry facade with API 2 and every documented method",
  function(ctx)
    local generations = rawget(namespace, "Registries")
    ctx:Expect(type(generations)):ToBe("table")
    local registry = rawget(generations, REGISTRY_API)
    ctx:Expect(type(registry)):ToBe("table")
    ctx:Expect(rawget(registry, "API")):ToBe(REGISTRY_API)
    for _, method in ipairs(FACADE_METHODS) do
      ctx:Expect(type(registry[method])):ToBe("function")
    end
  end
)

facade:Test("the installed Registry carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      ctx:Expect(rawget(Registry, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list registry")
end)

facade:Test(
  "MoltenCodes.Registry aliases the newest loaded generation, which is generation 2",
  function(ctx)
    local generations = rawget(namespace, "Registries")
    local newest = 0
    for generation in pairs(generations) do
      if type(generation) == "number" and generation > newest then
        newest = generation
      end
    end
    ctx:Log("newest generation loaded: " .. newest)
    ctx:Expect(rawget(namespace, "Registry")):ToBe(rawget(generations, newest))
    ctx:Expect(newest):ToBe(REGISTRY_API)
    ctx:Expect(rawget(namespace, "Registry")):ToBe(Registry)
  end
)

facade:Test(
  "every installed Kit is registered at its committed API and revision and publishes that REVISION",
  function(ctx)
    local expectedPackages = Harness:GetExpectedPackages()
    if type(expectedPackages) == "nil" then
      ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
      return
    end

    local problems = {}
    local checked = 0
    for _, expected in ipairs(expectedPackages) do
      -- Registry is the resolver, not a registered package; its own
      -- revision is the previous test's subject.
      if expected.id ~= PACKAGE_ID then
        checked = checked + 1
        local implementation, revision = Registry:Get(expected.id, expected.api)
        if type(implementation) ~= "table" then
          problems[#problems + 1] = expected.id .. " is not registered"
        elseif revision ~= expected.revision then
          problems[#problems + 1] = ("%s is at revision %s, expected %d"):format(
            expected.id,
            tostring(revision),
            expected.revision
          )
        elseif rawget(implementation, "REVISION") ~= expected.revision then
          problems[#problems + 1] = expected.id .. " publishes a different REVISION"
        end
      end
    end

    ctx:Log(("checked %d packages"):format(checked))
    for _, problem in ipairs(problems) do
      ctx:Log(problem)
    end
    if #problems > 0 then
      ctx:Fail(table.concat(problems, "; "))
    end
    ctx:Expect(checked > 0):ToBe(true)
  end
)

-- registry.lookup -----------------------------------------------------------------------

local lookup = Harness:Suite(PACKAGE_ID, "lookup", addonName)

lookup:Test(
  "Registry:Find of a package nobody registered returns nil and absent without raising",
  function(ctx)
    local implementation, reason = Registry:Find("mctRegistryNeverRegistered", 1)
    ctx:Expect(implementation):ToBeNil()
    ctx:Expect(reason):ToBe("absent")
  end
)

lookup:Test(
  "Registry:Find of a registered Kit under another API generation returns nil and generation_mismatch",
  function(ctx)
    local implementation, reason = Registry:Find("signalKit", 99)
    ctx:Expect(implementation):ToBeNil()
    ctx:Expect(reason):ToBe("generation_mismatch")
  end
)

lookup:Test(
  "Registry:Get of a package nobody registered returns nil and nil without raising",
  function(ctx)
    local implementation, revision = Registry:Get("mctRegistryNeverRegistered", 1)
    ctx:Expect(implementation):ToBeNil()
    ctx:Expect(revision):ToBeNil()
  end
)

lookup:Test(
  "Registry:Find and Registry:Get allocate nothing over 10000 calls each (allocation guard)",
  function(ctx)
    -- Warm both paths once, so the measurement sees steady state only.
    Registry:Find("signalKit", 1)
    Registry:Get("signalKit", 1)
    Registry:Find("mctRegistryNeverRegistered", 1)

    local before = collectgarbage("count")
    for _ = 1, ALLOCATION_CALLS do
      Registry:Find("signalKit", 1)
      Registry:Find("mctRegistryNeverRegistered", 1)
      Registry:Get("signalKit", 1)
      Registry:Get("mctRegistryNeverRegistered", 1)
    end
    local grownKilobytes = collectgarbage("count") - before

    ctx:Log(
      ("memory delta over %d calls of each: %.3f KB"):format(ALLOCATION_CALLS, grownKilobytes)
    )
    ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
  end
)

lookup:Test(
  "a Registry:Get argument error names RegistrySuite.lua at the calling line",
  function(ctx)
    local startLine
    local line = expectErrorAtCallingLine(ctx, function()
      startLine = select(2, splitPosition(callerPosition()))
      Registry:Get("", 1)
    end, "Registry:Get packageName must be a non-empty string")
    ctx:Expect(line):ToBe(startLine + 1)
  end
)

lookup:Test(
  "a Registry:Find argument error names RegistrySuite.lua at the calling line",
  function(ctx)
    local startLine
    local line = expectErrorAtCallingLine(ctx, function()
      startLine = select(2, splitPosition(callerPosition()))
      Registry:Find("signalKit", 0)
    end, "Registry:Find api must be a positive integer up to 2^53")
    ctx:Expect(line):ToBe(startLine + 1)
  end
)

-- registry.bootstrap ----------------------------------------------------------------------

local bootstrap = Harness:Suite(PACKAGE_ID, "bootstrap", addonName)

bootstrap:Test(
  "Bootstrap of a new probe package registers it and hands back a fresh table",
  function(ctx)
    local probeId = freshProbeId()
    ctx:Expect(select(2, Registry:Find(probeId, 1))):ToBe("absent")

    local implementation, previousRevision, selected, state = bootstrapProbe(probeId, 1)
    ctx:Expect(type(implementation)):ToBe("table")
    ctx:Expect(previousRevision):ToBeNil()
    ctx:Expect(selected):ToBeNil()
    ctx:Expect(state):ToBeNil()

    local found, revision = Registry:Find(probeId, 1)
    ctx:Expect(found):ToBe(implementation)
    ctx:Expect(revision):ToBe(1)
  end
)

bootstrap:Test(
  "a second probe copy at the same revision reuses the first copy's table",
  function(ctx)
    local probeId = freshProbeId()
    local first = bootstrapProbe(probeId, 1)

    local implementation, previousRevision, selected = bootstrapProbe(probeId, 1)
    ctx:Expect(implementation):ToBeNil()
    ctx:Expect(previousRevision):ToBeNil()
    ctx:Expect(selected):ToBe(first)

    local found, revision = Registry:Get(probeId, 1)
    ctx:Expect(found):ToBe(first)
    ctx:Expect(revision):ToBe(1)
  end
)

bootstrap:Test(
  "a higher probe revision upgrades the shared table in place and keeps its identity",
  function(ctx)
    local probeId = freshProbeId()
    local first = bootstrapProbe(probeId, 1)
    ---@cast first table
    local cachedPing = first.Ping
    ctx:Expect(cachedPing()):ToBe(1)

    local implementation, previousRevision = bootstrapProbe(probeId, 2)
    ctx:Expect(implementation):ToBe(first)
    ctx:Expect(previousRevision):ToBe(1)

    -- A consumer that cached the facade now runs the newer copy's code.
    ctx:Expect(first.Ping()):ToBe(2)
    local found, revision = Registry:Get(probeId, 1)
    ctx:Expect(found):ToBe(first)
    ctx:Expect(revision):ToBe(2)
  end
)

bootstrap:Test(
  "a lower probe revision steps aside and leaves the newer copy selected",
  function(ctx)
    local probeId = freshProbeId()
    local newer = bootstrapProbe(probeId, 2)
    ---@cast newer table

    local implementation, previousRevision, selected = bootstrapProbe(probeId, 1)
    ctx:Expect(implementation):ToBeNil()
    ctx:Expect(previousRevision):ToBeNil()
    ctx:Expect(selected):ToBe(newer)

    ctx:Expect(newer.Ping()):ToBe(2)
    local found, revision = Registry:Get(probeId, 1)
    ctx:Expect(found):ToBe(newer)
    ctx:Expect(revision):ToBe(2)
  end
)

bootstrap:Test(
  "the outgoing copy's retire hook runs once and its hand-over reaches the incoming migration",
  function(ctx)
    local probeId = freshProbeId()
    local retireCalls = 0
    local retiredTable, incomingRevision

    local first = bootstrapProbe(probeId, 1, {
      retire = function(implementation, revision)
        retireCalls = retireCalls + 1
        retiredTable = implementation
        incomingRevision = revision
        return { handedOverBy = 1 }
      end,
    })

    local implementation, previousRevision, _, state = bootstrapProbe(probeId, 2, {
      migrations = {
        [2] = function(handOver)
          handOver.migratedTo = 2
          return handOver
        end,
      },
    })
    ctx:Expect(implementation):ToBe(first)
    ctx:Expect(previousRevision):ToBe(1)
    ctx:Expect(retireCalls):ToBe(1)
    ctx:Expect(retiredTable):ToBe(first)
    ctx:Expect(incomingRevision):ToBe(2)
    ctx:Expect(state):ToEqual({ handedOverBy = 1, migratedTo = 2 })
    ctx:Expect(select(2, Registry:Find(probeId, 1))):ToBe(2)

    -- Revision 2 registered no hook, and revision 1's belongs to revision 1.
    bootstrapProbe(probeId, 3)
    ctx:Expect(retireCalls):ToBe(1)
  end
)

bootstrap:Test(
  "a Registry:Bootstrap argument error names RegistrySuite.lua at the calling line",
  function(ctx)
    -- The wrong argument type is the point of the test.
    ---@type any
    local notARequest = "not a table"
    local startLine
    local line = expectErrorAtCallingLine(ctx, function()
      startLine = select(2, splitPosition(callerPosition()))
      Registry:Bootstrap(notARequest)
    end, "Registry:Bootstrap request must be a table")
    ctx:Expect(line):ToBe(startLine + 1)
  end
)

-- registry.globals ----------------------------------------------------------------------------

local globals = Harness:Suite(PACKAGE_ID, "globals", addonName)

globals:Test("the framework publishes only the globals docs/EMBEDDING.md names", function(ctx)
  -- EMBEDDING.md: exactly one global, `MoltenCodes`, one private bootstrap
  -- key, and `wow` only while ApiKit owns that name. The harness adds its
  -- own, which it lists itself.
  local allowed = { MoltenCodes = true }
  for _, name in ipairs(Harness:GetOwnGlobalNames()) do
    allowed[name] = true
  end

  local ApiKit = Registry:Find("apiKit", 1)
  local wowStatus = type(ApiKit) == "table" and ApiKit:GetGlobalStatus() or "absent"
  ctx:Log("ApiKit wow global status: " .. tostring(wowStatus))

  local unexpected = {}
  local privateKeys = {}
  -- The whole global table is walked on purpose: that is the claim.
  -- selene: allow(global_usage)
  for key, value in pairs(_G) do
    if type(key) == "string" then
      if key:sub(1, #"MoltenCodes") == "MoltenCodes" and not allowed[key] then
        unexpected[#unexpected + 1] = key
      elseif key == "wow" and wowStatus == "published" then
        ctx:Expect(value):ToBe(rawget(namespace, "wow"))
      elseif key:sub(1, #"__MOLTENCODES") == "__MOLTENCODES" then
        privateKeys[#privateKeys + 1] = key
      end
    end
  end

  table.sort(unexpected)
  for _, key in ipairs(unexpected) do
    ctx:Log("unexpected global: " .. key)
  end
  for _, key in ipairs(privateKeys) do
    ctx:Log("private key: " .. key)
  end
  ctx:Expect(#unexpected):ToBe(0)
  ctx:Expect(#privateKeys):ToBe(1)
end)
