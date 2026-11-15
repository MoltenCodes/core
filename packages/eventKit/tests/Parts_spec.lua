local TestEnv = require("EventKitTestEnv")
local Scheduled = TestEnv.Scheduled

-- Revision 22 splits EventKit into a core and the Coalescing part
-- (docs/decisions/0001-kit-core-and-parts.md). These specs hold the part's
-- runtime contract: its bootstrap, the core's stubs and `HasPart`, and the
-- in-place upgrade from the last single-file revision.

local PART_PATH = "packages/eventKit/src/parts/EventKit-Coalescing.lua"
local MANIFEST_PATH = "packages/eventKit/package.manifest.json"
local MISSING_PART = "is in EventKit's Coalescing part, which is not loaded: add "
  .. "eventKit\\parts\\EventKit-Coalescing.lua to embeds.xml after eventKit\\EventKit.lua"

local function readFile(path)
  local file = assert(io.open(path, "rb"))
  local content = file:read("*a")
  file:close()
  return content
end

---Run the part's source once more with `PART_REVISION` set to `revision`.
---@param revision integer
---@return table EventKit
local function loadPartAtRevision(revision)
  local source = readFile(PART_PATH)
  local patched, count =
    source:gsub("local PART_REVISION = %d+", "local PART_REVISION = " .. revision, 1)
  assert.are.equal(1, count)
  return assert(loadstring(patched, "@" .. PART_PATH))()
end

---Assert that `callback` fails with `expected` at a line of this spec file.
local function expectErrorAtThisSpec(expected, callback)
  local ok, message = pcall(callback)
  message = tostring(message)
  assert.is_false(ok)
  assert.is_not_nil(string.find(message, expected, 1, true), message)
  assert.is_not_nil(
    string.find(message, "packages/eventKit/tests/Parts_spec.lua:", 1, true),
    message
  )
end

describe("EventKit Coalescing part bootstrap", function()
  after_each(Scheduled.Reset)

  it("declares the revision its file carries", function()
    local manifest = readFile(MANIFEST_PATH)
    local declared = manifest:match('"Coalescing"%s*:%s*{.-"revision"%s*:%s*(%d+)')
    local carried = readFile(PART_PATH):match("local PART_REVISION = (%d+)")
    assert.is_not_nil(declared)
    assert.are.equal(declared, carried)
  end)

  it("raises at load without EventKit's core", function()
    Scheduled.Reset()
    Scheduled.InstallWowApi()
    require("Registry")
    local ok, message = pcall(require, "EventKit-Coalescing")
    assert.is_false(ok)
    assert.is_not_nil(
      string.find(
        tostring(message),
        "MoltenCodes EventKit part Coalescing requires EventKit API 1 to be loaded first",
        1,
        true
      )
    )
  end)

  it("raises at load against a core without the part interface", function()
    local EventKit = TestEnv.NewPackage()
    rawset(EventKit._state, "partInterface", 0)
    local ok, message = pcall(TestEnv.LoadCoalescing)
    assert.is_false(ok)
    assert.is_not_nil(string.find(tostring(message), "requires EventKit API 1", 1, true))
    TestEnv.Reset()
  end)

  it("records its revision and returns the facade", function()
    local EventKit = Scheduled.NewEventKit()
    assert.are.same({ revision = 1 }, EventKit._state.parts.Coalescing)
    assert.is_true(EventKit:HasPart("Coalescing"))
  end)

  it("leaves an equal or newer installed revision alone", function()
    local EventKit = Scheduled.NewEventKit()
    local coalesce = EventKit.Coalesce
    local record = EventKit._state.parts.Coalescing
    assert.are.equal(EventKit, loadPartAtRevision(1))
    assert.are.equal(coalesce, EventKit.Coalesce)
    assert.are.equal(record, EventKit._state.parts.Coalescing)

    rawset(EventKit._state.parts, "Coalescing", { revision = 5 })
    loadPartAtRevision(4)
    assert.are.equal(coalesce, EventKit.Coalesce)
  end)

  it("takes over live handles and pending timers when a higher revision loads", function()
    local EventKit = Scheduled.NewEventKit()
    local deliveries = 0
    local handle = EventKit:Coalesce("UNIT_HEALTH", 0.5, function()
      deliveries = deliveries + 1
    end)
    Scheduled.Emit("UNIT_HEALTH", "player")
    local onEvent = EventKit._state.composites.onEvent

    loadPartAtRevision(2)
    assert.are.equal(2, EventKit._state.parts.Coalescing.revision)
    assert.are_not.equal(onEvent, EventKit._state.composites.onEvent)

    Scheduled.Emit("UNIT_HEALTH", "target")
    Scheduled.FireNative(#Scheduled.NativeTimers())
    assert.are.equal(1, deliveries)
    assert.is_true(handle:Close())
  end)

  it("is served by a core upgraded after it loaded", function()
    local EventKit = Scheduled.NewEventKit()
    local coalesce = EventKit.Coalesce
    TestEnv.LoadSourceAtRevision(23)
    assert.are.equal(23, EventKit.REVISION)
    -- The installed part keeps its members; the core's stubs are not put back.
    assert.are.equal(coalesce, EventKit.Coalesce)
    local deliveries = 0
    EventKit:Coalesce("UNIT_HEALTH", 0.5, function()
      deliveries = deliveries + 1
    end)
    Scheduled.Emit("UNIT_HEALTH", "player")
    Scheduled.FireNative(#Scheduled.NativeTimers())
    assert.are.equal(1, deliveries)
  end)
end)

describe("EventKit core without the Coalescing part", function()
  local EventKit
  before_each(function()
    EventKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("raises every part member at the caller's line, naming the file to embed", function()
    expectErrorAtThisSpec("EventKit:Coalesce " .. MISSING_PART, function()
      EventKit:Coalesce("UNIT_HEALTH", 1, function() end)
    end)
    expectErrorAtThisSpec("EventKit:Derive " .. MISSING_PART, function()
      EventKit:Derive("UNIT_HEALTH", function() end)
    end)
    local scope = EventKit:CreateScope()
    expectErrorAtThisSpec("EventKit.Scope:Coalesce " .. MISSING_PART, function()
      scope:Coalesce("UNIT_HEALTH", 1, function() end)
    end)
    expectErrorAtThisSpec("EventKit.Scope:Derive " .. MISSING_PART, function()
      scope:Derive("UNIT_HEALTH", function() end)
    end)
    assert.are.equal(0, #TestEnv.Frames())
  end)

  it("keeps the members, so another copy's surface check accepts the facade", function()
    assert.is_function(rawget(EventKit, "Coalesce"))
    assert.is_function(rawget(EventKit, "Derive"))
    assert.is_function(rawget(EventKit.Scope, "Coalesce"))
    assert.is_function(rawget(EventKit.Scope, "Derive"))
  end)

  it("answers HasPart, and refuses a name that is not a string", function()
    assert.is_false(EventKit:HasPart("Coalescing"))
    assert.is_false(EventKit:HasPart("Missing"))
    expectErrorAtThisSpec("EventKit:HasPart name must be a part name string", function()
      EventKit:HasPart(1)
    end)
    TestEnv.LoadCoalescing()
    assert.is_true(EventKit:HasPart("Coalescing"))
  end)

  it("closes scopes and addon scopes as before", function()
    local scope = EventKit:ForAddon("MyAddon")
    scope:Connect("UNIT_HEALTH", function() end)
    assert.is_true(EventKit:CloseAddonScopes("MyAddon"))
    assert.is_true(scope:IsClosed())
  end)
end)

describe("EventKit upgrade from the single-file revision 21", function()
  after_each(Scheduled.Reset)

  ---Load revision 21 as the single file it was, with a scope-owned Coalesce
  ---handle on a SchedulerKit lane and a Derive handle on a SchedulerKit
  ---debounce, the timing revision 21 gave them.
  local function loadRevision21()
    Scheduled.Reset()
    Scheduled.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("TimerKit")
    local SchedulerKit = require("SchedulerKit")
    TestEnv.LoadSchedulerLaneParts()
    local legacy = TestEnv.LoadSourceAtRevision(21)
    assert.are.equal(21, legacy.REVISION)
    assert.is_nil(rawget(legacy._state, "parts"))

    local result = { legacy = legacy, SchedulerKit = SchedulerKit, coalesced = 0, computes = 0 }
    result.scope = legacy:ForAddon("MyAddon")
    result.coalesce = result.scope:Coalesce("UNIT_HEALTH", 0.5, function()
      result.coalesced = result.coalesced + 1
    end, { lane = SchedulerKit:Lane("EventKitPartsSpec") })
    result.derive = result.scope:Derive("CUSTOM_EVENT", function()
      result.computes = result.computes + 1
    end)
    local schedulerScope = SchedulerKit:CreateScope()
    rawset(result.derive, "_schedulerScope", schedulerScope)
    rawset(
      result.derive,
      "_timing",
      schedulerScope:Debounce(function()
        return rawget(rawget(legacy._state, "composites"), "recompute")(result.derive)
      end, 0)
    )
    rawset(result.derive, "_delay", nil)
    return result
  end

  ---Fire every native timer still armed, then run SchedulerKit's frame pass.
  local function runTimers()
    for index = 1, #Scheduled.NativeTimers() do
      Scheduled.FireNative(index)
    end
    Scheduled.Tick(0.016)
  end

  it("keeps live handles delivering when the part loads with the core", function()
    local old = loadRevision21()
    package.loaded["EventKit"] = nil
    local EventKit = require("EventKit")
    TestEnv.LoadCoalescing()
    assert.are.equal(old.legacy, EventKit)
    assert.are.equal(22, EventKit.REVISION)

    Scheduled.Emit("UNIT_HEALTH", "player")
    Scheduled.Emit("CUSTOM_EVENT")
    runTimers()
    assert.are.equal(1, old.coalesced)
    assert.are.equal(2, old.computes)
    assert.is_false(old.coalesce:IsClosed())
    assert.are.equal(0, #Scheduled.TakeReportedErrors())

    EventKit:CloseAddonScopes("MyAddon")
    assert.is_true(old.coalesce:IsClosed())
    assert.is_true(old.derive:IsClosed())
  end)

  it("closes them without the part and says once which file to embed", function()
    local old = loadRevision21()
    package.loaded["EventKit"] = nil
    local EventKit = require("EventKit")
    assert.are.equal(22, EventKit.REVISION)
    Scheduled.TakeReportedErrors()

    Scheduled.Emit("UNIT_HEALTH", "player")
    Scheduled.Emit("CUSTOM_EVENT")
    runTimers()
    assert.is_true(old.coalesce:IsClosed())
    assert.is_true(old.derive:IsClosed())
    assert.are.equal(0, old.coalesced)
    assert.are.equal(1, old.computes)
    assert.are.equal(0, old.scope:GetActiveCount())

    local reported = Scheduled.TakeReportedErrors()
    assert.are.equal(1, #reported)
    assert.is_not_nil(
      string.find(tostring(reported[1].value), "eventKit\\parts\\EventKit-Coalescing.lua", 1, true)
    )
    expectErrorAtThisSpec("EventKit:Coalesce " .. MISSING_PART, function()
      EventKit:Coalesce("UNIT_HEALTH", 1, function() end)
    end)
  end)

  it("lets a scope close a handle the part no longer serves", function()
    local old = loadRevision21()
    package.loaded["EventKit"] = nil
    local EventKit = require("EventKit")
    EventKit:CloseAddonScopes("MyAddon")
    assert.is_true(old.coalesce:IsClosed())
    assert.is_true(old.derive:IsClosed())
  end)

  it("makes revision 21 loaded after a core-only revision 22 yield", function()
    Scheduled.Reset()
    Scheduled.InstallWowApi()
    require("Registry")
    require("SignalKit")
    local EventKit = require("EventKit")
    local older = TestEnv.LoadSourceAtRevision(21)
    assert.are.equal(EventKit, older)
    assert.are.equal(22, older.REVISION)
    expectErrorAtThisSpec("EventKit:Coalesce " .. MISSING_PART, function()
      older:Coalesce("UNIT_HEALTH", 1, function() end)
    end)
  end)
end)
