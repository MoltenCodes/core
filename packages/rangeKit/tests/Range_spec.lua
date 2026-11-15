local TestEnv = require("RangeKitTestEnv")

describe("RangeKit checker lists", function()
  local RangeKit
  before_each(function()
    RangeKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("builds each kind from the spells the spellbook reports, shortest first", function()
    TestEnv.Learn(589, 40)
    TestEnv.Learn(5019, 30.4)
    TestEnv.DefineSpell(8092, 30)
    TestEnv.Learn(2061, 40)
    TestEnv.Learn(2006, 40)
    assert.are.same(
      { "interact:3", "interact:4", "spell:5019", "spell:589" },
      TestEnv.Sources(RangeKit, "harm")
    )
    assert.are.same(
      { "interact:3", "interact:4", "spell:2061" },
      TestEnv.Sources(RangeKit, "friend")
    )
    assert.are.same(
      { "interact:3", "interact:4", "spell:2006" },
      TestEnv.Sources(RangeKit, "resurrect")
    )
    assert.are.same({ "interact:3", "interact:4", "spell:2061" }, TestEnv.Sources(RangeKit, "pet"))
    assert.are.same({ "interact:3", "interact:4" }, TestEnv.Sources(RangeKit, "interact"))
    assert.are.same({
      { range = 7, source = "interact:3" },
      { range = 28, source = "interact:4" },
      { range = 30, source = "spell:5019" },
      { range = 40, source = "spell:589" },
    }, RangeKit:DescribeCheckers("harm"))
  end)

  it("keeps the first checker of a range, spells before interact, and leaves melee out", function()
    TestEnv.Learn(589, 40)
    TestEnv.Learn(585, 39.6)
    TestEnv.Learn(8092, 0)
    TestEnv.Learn(5019, 7)
    assert.are.same({ "spell:5019", "interact:4", "spell:589" }, TestEnv.Sources(RangeKit, "harm"))
  end)

  it("joins a minimum-range spell with a closer checker, and leaves it out without one", function()
    TestEnv.SetClass("WARRIOR")
    TestEnv.Learn(100, 25, 8)
    TestEnv.Learn(355, 30)
    assert.are.same({ "interact:3", "interact:4", "spell:355" }, TestEnv.Sources(RangeKit, "harm"))

    TestEnv.Learn(5246, 8)
    TestEnv.Emit("SPELLS_CHANGED")
    assert.are.same({
      { range = 7, source = "interact:3" },
      { range = 8, source = "spell:5246" },
      { range = 25, minRange = 8, source = "spell:100" },
      { range = 28, source = "interact:4" },
      { range = 30, source = "spell:355" },
    }, RangeKit:DescribeCheckers("harm"))

    -- Inside the minimum range the spell says no; the closer checker answers.
    TestEnv.PlaceUnit("target", 5, "hostile")
    assert.are.same({ 0, 7 }, { RangeKit:GetRange("target") })
    TestEnv.PlaceUnit("target", 20, "hostile")
    assert.are.same({ 8, 25 }, { RangeKit:GetRange("target") })
  end)

  it("joins a minimum-range spell with an interact checker outside combat only", function()
    TestEnv.SetClass("HUNTER")
    TestEnv.Learn(136, 45, 10)
    assert.are.same({ "interact:3", "interact:4", "spell:136" }, TestEnv.Sources(RangeKit, "pet"))
    TestEnv.PlaceUnit("pet", 20, "friendly", true)
    assert.are.same({ 7, 28 }, { RangeKit:GetRange("pet") })
    TestEnv.SetCombat(true)
    assert.are.same({}, { RangeKit:GetRange("pet") })
  end)

  it("drops a spell whose minimum range is not below its range", function()
    TestEnv.Learn(589, 10, 10)
    assert.are.same({ "interact:3", "interact:4" }, TestEnv.Sources(RangeKit, "harm"))
  end)

  it("builds nothing but interact checkers for a class it has no spells for", function()
    TestEnv.SetClass("ADVENTURER")
    TestEnv.Learn(589, 40)
    assert.are.same({ "interact:3", "interact:4" }, TestEnv.Sources(RangeKit, "harm"))
  end)
end)

describe("RangeKit estimates", function()
  local RangeKit
  before_each(function()
    RangeKit = TestEnv.NewPackage()
    TestEnv.Learn(589, 40)
    TestEnv.Learn(5019, 30)
  end)
  after_each(TestEnv.Reset)

  it("brackets the distance at both ends and between checkers", function()
    for _, case in ipairs({
      { 3, 0, 7 },
      { 10, 7, 28 },
      { 29, 28, 30 },
      { 35, 30, 40 },
      { 50, 40, nil },
    }) do
      TestEnv.PlaceUnit("target", case[1], "hostile")
      local minRange, maxRange = RangeKit:GetRange("target")
      assert.are.equal(case[2], minRange)
      assert.are.equal(case[3], maxRange)
    end
  end)

  it("asks the client at most three times for four checkers", function()
    TestEnv.PlaceUnit("target", 35, "hostile")
    RangeKit:GetRange("target")
    TestEnv.CheckCount()
    RangeKit:GetRange("target")
    assert.is_true(TestEnv.CheckCount() <= 3)
  end)

  it("picks the list by the unit's kind", function()
    TestEnv.Learn(2061, 40)
    TestEnv.Learn(2006, 35)
    TestEnv.PlaceUnit("party1", 33, "friendly")
    assert.are.same({ 28, 40 }, { RangeKit:GetRange("party1") })
    TestEnv.PlaceUnit("party1", 33, "dead")
    assert.are.same({ 28, 35 }, { RangeKit:GetRange("party1") })
    TestEnv.PlaceUnit("target", 33, "deadHostile")
    assert.are.same({ 28 }, { RangeKit:GetRange("target") })
    TestEnv.PlaceUnit("mouseover", 3, "neutral")
    assert.are.same({ 0, 7 }, { RangeKit:GetRange("mouseover") })
    TestEnv.PlaceUnit("partypet1", 33, "friendly", true)
    assert.are.same({ 28, 40 }, { RangeKit:GetRange("partypet1") })
  end)

  it("answers nothing for a unit that does not exist", function()
    assert.are.same({}, { RangeKit:GetRange("target") })
    assert.is_nil(RangeKit:IsInRange("target", 30))
  end)

  it("skips interact checks in combat for a unit the player cannot attack", function()
    TestEnv.SetCombat(true)
    TestEnv.PlaceUnit("party1", 5, "friendly")
    assert.are.same({}, { RangeKit:GetRange("party1") })
    TestEnv.Learn(2061, 40)
    TestEnv.Emit("SPELLS_CHANGED")
    TestEnv.CheckCount()
    assert.are.same({ 0, 40 }, { RangeKit:GetRange("party1") })
    assert.are.equal(1, TestEnv.CheckCount())
    TestEnv.PlaceUnit("target", 5, "hostile")
    assert.are.same({ 0, 7 }, { RangeKit:GetRange("target") })
  end)

  it("says whether the unit is within a distance, or that it cannot decide", function()
    TestEnv.PlaceUnit("target", 25, "hostile")
    assert.is_true(RangeKit:IsInRange("target", 28))
    assert.is_true(RangeKit:IsInRange("target", 40))
    assert.is_false(RangeKit:IsInRange("target", 7))
    assert.is_nil(RangeKit:IsInRange("target", 20))
    TestEnv.PlaceUnit("target", 50, "hostile")
    assert.is_false(RangeKit:IsInRange("target", 40))
    assert.is_nil(RangeKit:IsInRange("target", 100))
  end)

  it("counts a legacy 0, and no answer, as out of range", function()
    TestEnv.DefineSpell(589, 40, 0, 0)
    TestEnv.DefineSpell(5019, 30, 0, 1)
    TestEnv.PlaceUnit("target", 35, "hostile")
    assert.are.same({ 28, 30 }, { RangeKit:GetRange("target") })
  end)
end)

describe("RangeKit rebuilds and listeners", function()
  local RangeKit
  before_each(function()
    RangeKit = TestEnv.NewPackage()
    TestEnv.InstallHostErrorHandler()
  end)
  after_each(TestEnv.Reset)

  it("rebuilds on each event and calls listeners only when a list changed", function()
    local calls = 0
    local connection = RangeKit:OnCheckersChanged(function()
      calls = calls + 1
    end)
    TestEnv.Emit("SPELLS_CHANGED")
    assert.are.equal(1, calls)
    TestEnv.Emit("SPELLS_CHANGED")
    assert.are.equal(1, calls)
    local spellID = 589
    for _, event in ipairs({
      { "LEARNED_SPELL_IN_SKILL_LINE" },
      { "PLAYER_TALENT_UPDATE" },
      { "CHARACTER_POINTS_CHANGED" },
      { "UNIT_PET", "player" },
    }) do
      TestEnv.Learn(spellID, spellID % 37 + 1)
      spellID = spellID + 1
      TestEnv.SetClass("PRIEST")
      TestEnv.Emit(event[1], event[2])
    end
    assert.are.equal(2, calls)
    assert.is_true(connection:IsConnected())
  end)

  it("calls listeners when only a spell's minimum range changed", function()
    TestEnv.SetClass("WARRIOR")
    TestEnv.Learn(100, 25, 8)
    TestEnv.Learn(5246, 12)
    local calls = 0
    RangeKit:OnCheckersChanged(function()
      calls = calls + 1
    end)
    assert.are.equal(8, RangeKit:DescribeCheckers("harm")[3].minRange)
    assert.are.equal(1, calls)

    -- Same sources and ranges, a different minimum range.
    TestEnv.DefineSpell(100, 25, 10)
    TestEnv.Emit("SPELLS_CHANGED")
    assert.are.equal(10, RangeKit:DescribeCheckers("harm")[3].minRange)
    assert.are.equal(2, calls)
  end)

  it("hears about spells learned and forgotten", function()
    local calls = 0
    RangeKit:OnCheckersChanged(function()
      calls = calls + 1
    end)
    assert.are.same({ "interact:3", "interact:4" }, TestEnv.Sources(RangeKit, "harm"))
    assert.are.equal(1, calls)
    TestEnv.Learn(589, 40)
    TestEnv.Emit("LEARNED_SPELL_IN_SKILL_LINE")
    assert.are.equal(2, calls)
    TestEnv.Forget(589)
    TestEnv.Emit("PLAYER_TALENT_UPDATE")
    assert.are.equal(3, calls)
    TestEnv.SetClass("WARLOCK")
    TestEnv.Learn(755, 45)
    TestEnv.Emit("UNIT_PET", "player")
    assert.are.equal(4, calls)
    assert.are.same({ "interact:3", "interact:4", "spell:755" }, TestEnv.Sources(RangeKit, "pet"))
  end)

  it("ignores the pet event of another unit", function()
    local calls = 0
    RangeKit:OnCheckersChanged(function()
      calls = calls + 1
    end)
    local eventFrame = rawget(RangeKit._state, "eventFrame")
    eventFrame:GetScript("OnEvent")(eventFrame, "UNIT_PET", "party1")
    assert.are.equal(0, calls)
    assert.are.same({ kind = "unit", units = { "player" } }, eventFrame.registrations.UNIT_PET)
  end)

  it("isolates a listener that raises", function()
    local calls = 0
    RangeKit:OnCheckersChanged(function()
      error("listener failed", 0)
    end)
    RangeKit:OnCheckersChanged(function()
      calls = calls + 1
    end)
    TestEnv.Emit("SPELLS_CHANGED")
    assert.are.equal(1, calls)
    assert.are.same({ "listener failed" }, TestEnv.TakeReportedValues())
  end)

  it("prints a listener failure without a host error handler", function()
    TestEnv.SetGlobal("geterrorhandler", nil)
    local printed = {}
    local savedPrint = print
    -- selene: allow(global_usage)
    rawset(_G, "print", function(value)
      printed[#printed + 1] = value
    end)
    RangeKit:OnCheckersChanged(function()
      error("listener failed", 0)
    end)
    TestEnv.Emit("SPELLS_CHANGED")
    -- selene: allow(global_usage)
    rawset(_G, "print", savedPrint)
    assert.are.same({ "listener failed" }, printed)
  end)

  it("disconnects once, and respects a disconnection during a notification", function()
    local calls = 0
    local second
    local first = RangeKit:OnCheckersChanged(function()
      second:Disconnect()
    end)
    second = RangeKit:OnCheckersChanged(function()
      calls = calls + 1
    end)
    TestEnv.Emit("SPELLS_CHANGED")
    assert.are.equal(0, calls)
    assert.is_false(second:IsConnected())
    assert.is_false(second:Disconnect())
    assert.is_true(first:Disconnect())
    assert.is_false(first:IsConnected())
    assert.are.equal("RangeKit.Connection", getmetatable(first))
  end)

  it("holds at most maxListeners listeners and keeps them when the limit drops", function()
    RangeKit:SetLimits({ maxListeners = 2 })
    local first = RangeKit:OnCheckersChanged(function() end)
    RangeKit:OnCheckersChanged(function() end)
    TestEnv.expectErrorContaining(
      "RangeKit:OnCheckersChanged holds at most 2 listeners; raise maxListeners with RangeKit:SetLimits",
      function()
        RangeKit:OnCheckersChanged(function() end)
      end
    )
    RangeKit:SetLimits({ maxListeners = 1 })
    assert.is_true(first:IsConnected())
    first:Disconnect()
    RangeKit:SetLimits({})
    assert.are.same({ maxListeners = 1 }, RangeKit:GetLimits())
    assert.are.equal(32, RangeKit.MAX_LISTENERS)
    assert.are.equal(256, RangeKit.LISTENERS_CEILING)
  end)
end)

describe("RangeKit on a host that lacks calls", function()
  after_each(TestEnv.Reset)

  it("registers only the events the client says are valid", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    TestEnv.SetGlobal("C_EventUtils", {
      IsEventValid = function(event)
        return event ~= "PLAYER_TALENT_UPDATE" and event ~= "UNIT_PET"
      end,
    })
    require("Registry")
    local RangeKit = require("RangeKit")
    local registrations = rawget(RangeKit._state, "eventFrame").registrations
    assert.is_not_nil(registrations.SPELLS_CHANGED)
    assert.is_not_nil(registrations.LEARNED_SPELL_IN_SKILL_LINE)
    assert.is_not_nil(registrations.CHARACTER_POINTS_CHANGED)
    assert.is_nil(registrations.PLAYER_TALENT_UPDATE)
    assert.is_nil(registrations.UNIT_PET)
  end)

  it("listens once CreateFrame appears after load", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local createFrame = TestEnv.GetGlobal("CreateFrame")
    TestEnv.SetGlobal("CreateFrame", nil)
    require("Registry")
    local RangeKit = require("RangeKit")
    assert.is_false(rawget(RangeKit._state, "eventFrame"))
    TestEnv.SetGlobal("CreateFrame", createFrame)
    RangeKit:DescribeCheckers("harm")
    assert.is_table(rawget(RangeKit._state, "eventFrame"))
  end)

  it("answers from interact checks without the spell calls, and nothing without them", function()
    local RangeKit = TestEnv.NewPackage()
    TestEnv.Learn(589, 40)
    TestEnv.PlaceUnit("target", 10, "hostile")
    for _, name in ipairs({ "C_Spell", "C_SpellBook", "Enum", "UnitClass" }) do
      TestEnv.SetGlobal(name, nil)
      TestEnv.Emit("SPELLS_CHANGED")
      assert.are.same({ "interact:3", "interact:4" }, TestEnv.Sources(RangeKit, "harm"))
      TestEnv.InstallClient()
      TestEnv.Emit("SPELLS_CHANGED")
    end
    TestEnv.SetGlobal("Enum", { SpellBookSpellBank = {} })
    TestEnv.Emit("SPELLS_CHANGED")
    assert.are.same({ "interact:3", "interact:4" }, TestEnv.Sources(RangeKit, "harm"))
    TestEnv.InstallClient()

    TestEnv.SetGlobal("CheckInteractDistance", nil)
    TestEnv.Emit("SPELLS_CHANGED")
    assert.are.same({ "spell:589" }, TestEnv.Sources(RangeKit, "harm"))
    assert.are.same({ 0, 40 }, { RangeKit:GetRange("target") })

    TestEnv.InstallClient()
    TestEnv.Emit("SPELLS_CHANGED")
    TestEnv.SetGlobal("CheckInteractDistance", nil)
    TestEnv.SetGlobal("C_Spell", nil)
    -- Every check says no: the unit counts as beyond the longest checker.
    assert.are.same({ 40 }, { RangeKit:GetRange("target") })

    TestEnv.SetGlobal("UnitExists", nil)
    assert.are.same({}, { RangeKit:GetRange("target") })
  end)

  it(
    "treats a unit as neither attackable, assistable, dead nor the pet without those calls",
    function()
      local RangeKit = TestEnv.NewPackage()
      TestEnv.Learn(589, 40)
      TestEnv.PlaceUnit("target", 10, "hostile")
      TestEnv.PlaceUnit("pet", 10, "friendly")
      for _, name in ipairs({
        "UnitCanAttack",
        "UnitCanAssist",
        "UnitIsDeadOrGhost",
        "UnitIsUnit",
        "InCombatLockdown",
      }) do
        TestEnv.SetGlobal(name, nil)
      end
      assert.are.same({ 7, 28 }, { RangeKit:GetRange("target") })
      assert.are.same({ 7, 28 }, { RangeKit:GetRange("pet") })
    end
  )
end)
