local TestEnv = require("EventKitTestEnv")
local Timed = TestEnv.Timed

-- The in-place upgrade from revision 22, the floor this revision upgrades
-- (docs/API.md, "Upgrading in place"). The older copy is the byte copy of the
-- files revision 22 shipped (`tests/fixtures/`), loaded first as an addon
-- embedding that release would: unit events and the combat log were in its
-- core, and its Coalescing part was revision 1.

---Load Registry, SignalKit and TimerKit, then revision 22's core and
---Coalescing part, without this revision.
---@return table EventKit the facade revision 22 registered
local function loadRevision22()
  Timed.Reset()
  Timed.InstallWowApi()
  Timed.InstallHostErrorHandler()
  TestEnv.InstallCombatLogEventInfo()
  require("Registry")
  require("SignalKit")
  require("TimerKit")
  local legacy = TestEnv.LoadRevision22("core")
  TestEnv.LoadRevision22("coalescing")
  assert.are.equal(22, legacy.REVISION)
  return legacy
end

---Connect one of each kind revision 22 could make, counting deliveries.
---@param legacy table
---@return table calls counts by kind
---@return table handles the connections and the Coalesce handle
local function connectEveryKind(legacy)
  local calls = { regular = 0, unit = 0, combat = 0, coalesced = 0 }
  local scope = legacy:ForAddon("MyAddon")
  local handles = {
    regular = scope:Connect("BAG_UPDATE", function()
      calls.regular = calls.regular + 1
    end),
    unit = scope:ConnectUnit("UNIT_HEALTH", function()
      calls.unit = calls.unit + 1
    end, "player"),
    combat = scope:ConnectCombatLog("SPELL_DAMAGE", function()
      calls.combat = calls.combat + 1
    end),
    coalesce = scope:Coalesce("UNIT_AURA", 0.5, function()
      calls.coalesced = calls.coalesced + 1
    end),
    scope = scope,
  }
  return calls, handles
end

---Deliver one event of each kind and the Coalesce handle's pending timer.
local function deliverEveryKind()
  Timed.Emit("BAG_UPDATE")
  Timed.Emit("UNIT_HEALTH", "player")
  TestEnv.SetCombatLogEventInfo(1, "SPELL_DAMAGE")
  Timed.Emit("COMBAT_LOG_EVENT_UNFILTERED")
  Timed.Emit("UNIT_AURA", "player")
  local timers = Timed.NativeTimers()
  Timed.FireNative(#timers)
end

describe("EventKit upgrade from revision 22", function()
  after_each(Timed.Reset)

  it("keeps every kind of connection delivering when the parts load", function()
    local legacy = loadRevision22()
    local calls, handles = connectEveryKind(legacy)

    local EventKit = require("EventKit")
    TestEnv.LoadUnitsAndCombatLog()
    TestEnv.LoadCoalescing()
    assert.are.equal(legacy, EventKit)
    assert.are.equal(23, EventKit.REVISION)
    assert.are.equal(2, EventKit._state.parts.Coalescing.revision)

    deliverEveryKind()
    assert.are.same({ regular = 1, unit = 1, combat = 1, coalesced = 1 }, calls)

    assert.is_true(EventKit:CloseAddonScopes("MyAddon"))
    assert.is_false(handles.unit:IsConnected())
    assert.is_false(handles.combat:IsConnected())
    assert.is_true(handles.coalesce:IsClosed())
    assert.is_nil(next(EventKit._state.unitGroups))
    assert.is_false(EventKit._state.combatLog.channel)
    assert.are.equal(0, #Timed.ReportedErrors())
  end)

  it("retires unit and combat-log connections on the next frame without their parts", function()
    local legacy = loadRevision22()
    local calls, handles = connectEveryKind(legacy)
    local timersBefore = #Timed.NativeTimers()

    local EventKit = require("EventKit")
    -- The settle runs on the next frame, after every part an addon embeds.
    assert.are.equal(timersBefore + 1, #Timed.NativeTimers())
    assert.is_true(handles.unit:IsConnected())
    Timed.FireNative(timersBefore + 1)

    assert.is_false(handles.unit:IsConnected())
    assert.is_false(handles.combat:IsConnected())
    assert.is_true(handles.regular:IsConnected())
    assert.is_nil(next(EventKit._state.unitGroups))
    assert.are.equal(1, #EventKit._state.unitFrames)
    assert.is_false(EventKit._state.combatLog.channel)
    assert.are.equal(1, handles.scope:GetActiveCount() - 1)

    local reported = Timed.ReportedErrors()
    assert.are.equal(2, #reported)
    assert.is_not_nil(string.find(reported[1], "eventKit\\parts\\EventKit-Units.lua", 1, true))
    assert.is_not_nil(string.find(reported[2], "eventKit\\parts\\EventKit-CombatLog.lua", 1, true))

    deliverEveryKind()
    assert.are.equal(1, calls.regular)
    assert.are.equal(0, calls.unit)
    assert.are.equal(0, calls.combat)
    -- The Coalescing part revision 22 installed keeps serving its handle.
    assert.are.equal(1, calls.coalesced)
    assert.are.equal(2, #Timed.ReportedErrors())
  end)

  it("retires them at the first event that reaches them before the next frame", function()
    local legacy = loadRevision22()
    local calls, handles = connectEveryKind(legacy)

    require("EventKit")
    Timed.Emit("UNIT_HEALTH", "player")

    assert.are.equal(0, calls.unit)
    assert.is_false(handles.unit:IsConnected())
    assert.is_false(handles.combat:IsConnected())
    assert.are.equal(2, #Timed.ReportedErrors())
  end)

  it("lets a Units part loaded later reuse the retired Frames", function()
    local legacy = loadRevision22()
    connectEveryKind(legacy)
    local EventKit = require("EventKit")
    Timed.FireNative(#Timed.NativeTimers())
    local frames = #Timed.Frames()

    TestEnv.LoadUnitsAndCombatLog()
    local calls = 0
    EventKit:ConnectUnit("UNIT_HEALTH", function()
      calls = calls + 1
    end, "target")
    Timed.Emit("UNIT_HEALTH", "target")
    assert.are.equal(1, calls)
    assert.are.equal(frames, #Timed.Frames())
  end)
end)
