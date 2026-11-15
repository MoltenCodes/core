local TestEnv = require("RangeKitTestEnv")

describe("RangeKit secret values", function()
  local RangeKit, secret
  before_each(function()
    RangeKit = TestEnv.NewPackage()
    TestEnv.InstallSecretProbe()
    secret = TestEnv.NewSecret()
    TestEnv.Learn(589, 40)
    TestEnv.Learn(5019, 30)
  end)
  after_each(TestEnv.Reset)

  it("refuses secret units, yards, kinds, callbacks, limits and receivers", function()
    for _, case in ipairs({
      {
        "RangeKit:GetRange unit must be a unit token string",
        function()
          RangeKit:GetRange(secret)
        end,
      },
      {
        "RangeKit:IsInRange unit must be a unit token string",
        function()
          RangeKit:IsInRange(secret, 30)
        end,
      },
      {
        "RangeKit:IsInRange yards must be a finite number of at least 0",
        function()
          RangeKit:IsInRange("target", secret)
        end,
      },
      {
        "RangeKit:DescribeCheckers kind must be",
        function()
          RangeKit:DescribeCheckers(secret)
        end,
      },
      {
        "RangeKit:OnCheckersChanged callback must be a function",
        function()
          RangeKit:OnCheckersChanged(secret)
        end,
      },
      {
        "RangeKit:SetLimits limits must be a table",
        function()
          RangeKit:SetLimits(secret)
        end,
      },
      {
        "limits holds an unknown field",
        function()
          RangeKit:SetLimits({ [secret] = 1 })
        end,
      },
      {
        "RangeKit:SetLimits limits.maxListeners must not be a secret value",
        function()
          RangeKit:SetLimits({ maxListeners = secret })
        end,
      },
      {
        "must be called on the RangeKit facade",
        function()
          RangeKit.GetRange(secret, "target")
        end,
      },
      {
        "must be called on a RangeKit connection",
        function()
          RangeKit:OnCheckersChanged(function() end).Disconnect(secret)
        end,
      },
    }) do
      TestEnv.expectErrorContaining(case[1], case[2])
    end
  end)

  it("counts a secret range answer as no answer", function()
    TestEnv.DefineSpell(589, 40, 0, secret)
    TestEnv.PlaceUnit("target", 35, "hostile")
    assert.are.same({ 40 }, { RangeKit:GetRange("target") })
    local checkInteractDistance = TestEnv.GetGlobal("CheckInteractDistance")
    TestEnv.SetGlobal("CheckInteractDistance", function()
      return secret
    end)
    TestEnv.PlaceUnit("target", 3, "hostile")
    assert.are.same({ 28, 30 }, { RangeKit:GetRange("target") })
    TestEnv.SetGlobal("CheckInteractDistance", checkInteractDistance)
  end)

  it("answers nothing when whether the unit exists is secret", function()
    TestEnv.PlaceUnit("target", 10, "hostile")
    TestEnv.SetGlobal("UnitExists", function()
      return secret
    end)
    assert.are.same({}, { RangeKit:GetRange("target") })
  end)

  it("treats secret relation and combat answers as no", function()
    TestEnv.PlaceUnit("target", 10, "hostile")
    for _, name in ipairs({ "UnitCanAttack", "UnitCanAssist", "UnitIsDeadOrGhost", "UnitIsUnit" }) do
      TestEnv.SetGlobal(name, function()
        return secret
      end)
    end
    TestEnv.SetGlobal("InCombatLockdown", function()
      return secret
    end)
    -- Neither attackable nor assistable: the interact list, used out of combat.
    assert.are.same({ 7, 28 }, { RangeKit:GetRange("target") })
  end)

  it("builds no spell checker from a secret class, spellbook, bank, info or range", function()
    local function harmSources()
      TestEnv.Emit("SPELLS_CHANGED")
      local sources = TestEnv.Sources(RangeKit, "harm")
      TestEnv.InstallClient()
      return sources
    end
    local interactOnly = { "interact:3", "interact:4" }

    TestEnv.SetGlobal("UnitClass", function()
      return "Priest", secret
    end)
    assert.are.same(interactOnly, harmSources())

    TestEnv.SetGlobal("C_SpellBook", {
      IsSpellInSpellBook = function()
        return secret
      end,
    })
    assert.are.same(interactOnly, harmSources())

    TestEnv.SetGlobal("Enum", { SpellBookSpellBank = { Player = secret } })
    assert.are.same(interactOnly, harmSources())

    local spellApi = TestEnv.GetGlobal("C_Spell")
    spellApi.GetSpellInfo = function()
      return secret
    end
    assert.are.same(interactOnly, harmSources())

    spellApi = TestEnv.GetGlobal("C_Spell")
    spellApi.GetSpellInfo = function(spellID)
      return { spellID = spellID, maxRange = secret, minRange = 0 }
    end
    assert.are.same(interactOnly, harmSources())

    spellApi = TestEnv.GetGlobal("C_Spell")
    spellApi.GetSpellInfo = function(spellID)
      return { spellID = spellID, maxRange = 40, minRange = secret }
    end
    assert.are.same({ "interact:3", "interact:4", "spell:589" }, harmSources())
  end)

  it("registers no event the client answers a secret about", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    TestEnv.InstallSecretProbe()
    TestEnv.SetGlobal("C_EventUtils", {
      IsEventValid = function()
        return secret
      end,
    })
    require("Registry")
    local loaded = require("RangeKit")
    assert.are.same({}, rawget(loaded._state, "eventFrame").registrations)
  end)
end)
