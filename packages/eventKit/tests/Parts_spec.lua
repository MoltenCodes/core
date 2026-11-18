local TestEnv = require("EventKitTestEnv")
local Scheduled = TestEnv.Scheduled

-- EventKit is a core and three parts, Units, CombatLog and Coalescing
-- (docs/decisions/0001-kit-core-and-parts.md). These specs hold the parts'
-- runtime contract: their bootstrap, the core's stubs and `HasPart`, what
-- the core answers without them, and a part upgraded in place.

local PART_PATH = "packages/eventKit/src/parts/EventKit-Coalescing.lua"
local MANIFEST_PATH = "packages/eventKit/package.manifest.json"
---The fix-it text a stub of `part` raises after the member's name.
---@param part string
---@return string
local function missingPart(part)
  return "is in EventKit's "
    .. part
    .. " part, which is not loaded: add eventKit\\parts\\EventKit-"
    .. part
    .. ".lua to embeds.xml after eventKit\\EventKit.lua"
end

local function readFile(path)
  local file = assert(io.open(path, "rb"))
  local content = file:read("*a")
  file:close()
  return content
end

---Run a part's source once more with `PART_REVISION` set to `revision`.
---@param revision integer
---@param path string? the part file; the Coalescing part when omitted
---@return table EventKit
local function loadPartAtRevision(revision, path)
  path = path or PART_PATH
  local source = readFile(path)
  local patched, count =
    source:gsub("local PART_REVISION = %d+", "local PART_REVISION = " .. revision, 1)
  assert.are.equal(1, count)
  return assert(loadstring(patched, "@" .. path))()
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

  it("raises at load against a core older than part interface 2", function()
    local EventKit = TestEnv.NewPackage()
    rawset(EventKit._state, "partInterface", 1)
    local ok, message = pcall(TestEnv.LoadCoalescing)
    assert.is_false(ok)
    assert.is_not_nil(string.find(tostring(message), "requires EventKit API 1", 1, true))
    TestEnv.Reset()
  end)

  it("records its revision and returns the facade", function()
    local EventKit = Scheduled.NewEventKit()
    assert.are.same({ revision = 2 }, EventKit._state.parts.Coalescing)
    assert.is_true(EventKit:HasPart("Coalescing"))
  end)

  it("leaves an equal or newer installed revision alone", function()
    local EventKit = Scheduled.NewEventKit()
    local coalesce = EventKit.Coalesce
    local record = EventKit._state.parts.Coalescing
    assert.are.equal(EventKit, loadPartAtRevision(2))
    assert.are.equal(coalesce, EventKit.Coalesce)
    assert.are.equal(record, EventKit._state.parts.Coalescing)

    rawset(EventKit._state.parts, "Coalescing", { revision = 5 })
    loadPartAtRevision(4)
    assert.are.equal(coalesce, EventKit.Coalesce)
  end)

  it("refuses to load without SignalKit, naming it", function()
    local ok = TestEnv.NewPackageWithout("SignalKit")
    assert.is_true(ok)
    local loaded, message = pcall(TestEnv.LoadCoalescing)
    assert.is_false(loaded)
    assert.is_not_nil(
      string.find(
        tostring(message),
        "MoltenCodes EventKit part Coalescing requires SignalKit API 1 to be loaded first",
        1,
        true
      )
    )
  end)

  it("refuses a units option without the Units part, naming the file", function()
    -- The core, TimerKit and the Coalescing part, without the Units part.
    local _, _, _, EventKit = TestEnv.Timed.NewPackage()
    TestEnv.LoadCoalescing()
    expectErrorAtThisSpec(
      'EventKit:Coalesce option "units" is in EventKit\'s Units part, which is not loaded: '
        .. "add eventKit\\parts\\EventKit-Units.lua to embeds.xml after eventKit\\EventKit.lua",
      function()
        EventKit:Coalesce("UNIT_HEALTH", 1, function() end, { units = { "player" } })
      end
    )
    assert.are.equal(0, #TestEnv.Timed.Frames())
    TestEnv.Timed.Reset()
  end)

  it("takes over live handles and pending timers when a higher revision loads", function()
    local EventKit = Scheduled.NewEventKit()
    local deliveries = 0
    local handle = EventKit:Coalesce("UNIT_HEALTH", 0.5, function()
      deliveries = deliveries + 1
    end)
    Scheduled.Emit("UNIT_HEALTH", "player")
    local onEvent = EventKit._state.composites.onEvent

    loadPartAtRevision(3)
    assert.are.equal(3, EventKit._state.parts.Coalescing.revision)
    assert.are_not.equal(onEvent, EventKit._state.composites.onEvent)

    Scheduled.Emit("UNIT_HEALTH", "target")
    Scheduled.FireNative(#Scheduled.NativeTimers())
    assert.are.equal(1, deliveries)
    assert.is_true(handle:Close())
  end)

  it("is served by a core upgraded after it loaded", function()
    local EventKit = Scheduled.NewEventKit()
    local coalesce = EventKit.Coalesce
    TestEnv.LoadSourceAtRevision(24)
    assert.are.equal(24, EventKit.REVISION)
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

describe("EventKit Units and CombatLog part bootstrap", function()
  after_each(TestEnv.Reset)

  for _, part in ipairs({ "Units", "CombatLog" }) do
    local path = "packages/eventKit/src/parts/EventKit-" .. part .. ".lua"

    it("declares the revision the " .. part .. " file carries", function()
      local manifest = readFile(MANIFEST_PATH)
      local declared = manifest:match('"' .. part .. '"%s*:%s*{.-"revision"%s*:%s*(%d+)')
      local carried = readFile(path):match("local PART_REVISION = (%d+)")
      assert.is_not_nil(declared)
      assert.are.equal(declared, carried)
    end)

    it("raises at load of " .. part .. " without EventKit's core", function()
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      require("Registry")
      local ok, message = pcall(require, "EventKit-" .. part)
      assert.is_false(ok)
      assert.is_not_nil(
        string.find(
          tostring(message),
          "MoltenCodes EventKit part " .. part .. " requires EventKit API 1 to be loaded first",
          1,
          true
        )
      )
    end)

    it("records the " .. part .. " revision and leaves an equal one alone", function()
      local EventKit = TestEnv.NewPackage()
      assert.are.same({ revision = 1 }, EventKit._state.parts[part])
      assert.is_true(EventKit:HasPart(part))
      local record = EventKit._state.parts[part]
      assert.are.equal(EventKit, loadPartAtRevision(1, path))
      assert.are.equal(record, EventKit._state.parts[part])
    end)
  end

  it("hands live unit groups to a higher Units revision", function()
    local EventKit = TestEnv.NewPackage()
    local calls = 0
    local connection = EventKit:ConnectUnit("UNIT_HEALTH", function()
      calls = calls + 1
    end, "player")
    local dispatchUnit = EventKit._state.dispatchUnit

    loadPartAtRevision(2, "packages/eventKit/src/parts/EventKit-Units.lua")
    assert.are_not.equal(dispatchUnit, EventKit._state.dispatchUnit)
    TestEnv.Emit("UNIT_HEALTH", "player")
    assert.are.equal(1, calls)
    assert.is_true(connection:Disconnect())
    assert.is_nil(next(EventKit._state.unitGroups))
  end)

  it("hands a live combat-log router to a higher CombatLog revision", function()
    local EventKit = TestEnv.NewPackage()
    local calls = 0
    local connection = EventKit:ConnectCombatLog("SPELL_DAMAGE", function()
      calls = calls + 1
    end)
    local dispatchCombatLog = EventKit._state.dispatchCombatLog

    loadPartAtRevision(2, "packages/eventKit/src/parts/EventKit-CombatLog.lua")
    assert.are_not.equal(dispatchCombatLog, EventKit._state.dispatchCombatLog)
    TestEnv.EmitCombatLogEvent(1, "SPELL_DAMAGE")
    assert.are.equal(1, calls)
    assert.is_true(connection:Disconnect())
    assert.is_false(EventKit._state.combatLog.channel)
  end)
end)

describe("EventKit core without its parts", function()
  local EventKit
  before_each(function()
    EventKit = TestEnv.NewCore()
  end)
  after_each(TestEnv.Reset)

  it("raises every part member at the caller's line, naming the file to embed", function()
    local scope = EventKit:CreateScope()
    local cases = {
      {
        "EventKit:ConnectUnit",
        "Units",
        function()
          EventKit:ConnectUnit("UNIT_HEALTH", print, "player")
        end,
      },
      {
        "EventKit:OnceUnit",
        "Units",
        function()
          EventKit:OnceUnit("UNIT_HEALTH", print, "player")
        end,
      },
      {
        "EventKit.Scope:ConnectUnit",
        "Units",
        function()
          scope:ConnectUnit("UNIT_HEALTH", print, "player")
        end,
      },
      {
        "EventKit.Scope:OnceUnit",
        "Units",
        function()
          scope:OnceUnit("UNIT_HEALTH", print, "player")
        end,
      },
      {
        "EventKit:ConnectCombatLog",
        "CombatLog",
        function()
          EventKit:ConnectCombatLog("SPELL_DAMAGE", print)
        end,
      },
      {
        "EventKit.Scope:ConnectCombatLog",
        "CombatLog",
        function()
          scope:ConnectCombatLog("SPELL_DAMAGE", print)
        end,
      },
      {
        "EventKit:Coalesce",
        "Coalescing",
        function()
          EventKit:Coalesce("UNIT_HEALTH", 1, print)
        end,
      },
      {
        "EventKit:Derive",
        "Coalescing",
        function()
          EventKit:Derive("UNIT_HEALTH", print)
        end,
      },
      {
        "EventKit.Scope:Coalesce",
        "Coalescing",
        function()
          scope:Coalesce("UNIT_HEALTH", 1, print)
        end,
      },
      {
        "EventKit.Scope:Derive",
        "Coalescing",
        function()
          scope:Derive("UNIT_HEALTH", print)
        end,
      },
    }
    for _, case in ipairs(cases) do
      expectErrorAtThisSpec(case[1] .. " " .. missingPart(case[2]), case[3])
    end
    assert.are.equal(0, #TestEnv.Frames())
  end)

  it("keeps the members, so another copy's surface check accepts the facade", function()
    for _, name in ipairs({ "ConnectUnit", "OnceUnit", "ConnectCombatLog", "Coalesce", "Derive" }) do
      assert.is_function(rawget(EventKit, name))
      assert.is_function(rawget(EventKit.Scope, name))
    end
  end)

  it("answers HasPart, and refuses a name that is not a string", function()
    assert.is_false(EventKit:HasPart("Units"))
    assert.is_false(EventKit:HasPart("CombatLog"))
    assert.is_false(EventKit:HasPart("Coalescing"))
    assert.is_false(EventKit:HasPart("Missing"))
    expectErrorAtThisSpec("EventKit:HasPart name must be a part name string", function()
      EventKit:HasPart(1)
    end)
    TestEnv.LoadUnitsAndCombatLog()
    assert.is_true(EventKit:HasPart("Units"))
    assert.is_true(EventKit:HasPart("CombatLog"))
  end)

  it("answers IsCombatLogAvailable and takes maxUnitFrames limits", function()
    assert.is_true(EventKit:IsCombatLogAvailable())
    EventKit:SetLimits({ maxUnitFrames = 10 })
    assert.are.equal(10, EventKit:GetLimits().maxUnitFrames)
  end)

  it("closes scopes and addon scopes as before", function()
    local scope = EventKit:ForAddon("MyAddon")
    scope:Connect("UNIT_HEALTH", function() end)
    assert.is_true(EventKit:CloseAddonScopes("MyAddon"))
    assert.is_true(scope:IsClosed())
  end)
end)

describe("EventKit scope with every kind of member", function()
  after_each(Scheduled.Reset)

  it("closes unit, combat-log and coalesced connections together", function()
    local EventKit = Scheduled.NewEventKit()
    local scope = EventKit:CreateScope()
    local unit = scope:ConnectUnit("UNIT_HEALTH", function() end, "player")
    local combat = scope:ConnectCombatLog("SPELL_DAMAGE", function() end)
    local plain = scope:Connect("BAG_UPDATE", function() end)
    local handle = scope:Coalesce("UNIT_AURA", 0.5, function() end)
    assert.are.equal(4, scope:GetActiveCount())

    assert.is_true(scope:Close())
    assert.is_false(unit:IsConnected())
    assert.is_false(combat:IsConnected())
    assert.is_false(plain:IsConnected())
    assert.is_true(handle:IsClosed())
    assert.are.equal(0, scope:GetActiveCount())
    assert.is_nil(next(EventKit._state.unitGroups))
    assert.is_false(EventKit._state.combatLog.channel)
  end)
end)
