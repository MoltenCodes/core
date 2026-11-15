local TestEnv = require("UnitFrameKitTestEnv")

describe("UnitFrameKit secret values", function()
  local UnitFrameKit, secret
  before_each(function()
    UnitFrameKit = TestEnv.NewPackage()
    TestEnv.InstallSecretProbe()
    secret = TestEnv.NewSecret()
  end)
  after_each(TestEnv.Reset)

  it("refuses secret arguments at the caller", function()
    local connection = UnitFrameKit:OnChange(function() end)
    local cases = {
      {
        function()
          UnitFrameKit:GetUnitFrame(secret)
        end,
        "unit must be a non-empty unit token",
      },
      {
        function()
          UnitFrameKit:GetUnitFrames("party1", secret)
        end,
        "options must be a table or nil",
      },
      {
        function()
          UnitFrameKit:GetUnitFrame("party1", { [secret] = true })
        end,
        "options holds an unknown field",
      },
      {
        function()
          UnitFrameKit:GetUnitFrame("party1", { kinds = secret })
        end,
        "options.kinds must be an array of kinds",
      },
      {
        function()
          UnitFrameKit:GetUnitFrame("party1", { priorities = { [secret] = "^Elv" } })
        end,
        "options.priorities must be an array of patterns",
      },
      {
        function()
          UnitFrameKit:GetUnitFrame("party1", { ignore = { secret } })
        end,
        "options.ignore[1] must be a non-empty string",
      },
      {
        function()
          UnitFrameKit:GetNamePlate(secret)
        end,
        "unit must be a non-empty unit token",
      },
      {
        function()
          UnitFrameKit:OnChange(secret)
        end,
        "callback must be a function",
      },
      {
        function()
          UnitFrameKit:GetKindPatterns(secret)
        end,
        "kind must be one of",
      },
      {
        function()
          UnitFrameKit:SetLimits(secret)
        end,
        "limits must be a table",
      },
      {
        function()
          UnitFrameKit:SetLimits({ [secret] = 1 })
        end,
        "limits holds an unknown field",
      },
      {
        function()
          UnitFrameKit:SetLimits({ maxFrames = secret })
        end,
        "limits.maxFrames must not be a secret value",
      },
      {
        function()
          connection.Disconnect(secret)
        end,
        "must be called on a UnitFrameKit connection",
      },
    }
    for _, case in ipairs(cases) do
      TestEnv.expectErrorContaining(case[2], case[1])
    end
  end)

  it("skips frames whose scan answers are secret", function()
    TestEnv.UnitButton("SecretForbidden", "party1", {
      IsForbidden = function()
        return secret
      end,
    })
    TestEnv.UnitButton("SecretType", "party1", {
      GetObjectType = function()
        return secret
      end,
    })
    TestEnv.UnitButton("SecretUnit", nil, { attributes = { unit = secret } })
    TestEnv.UnitButton("SecretVisible", "party1", { visible = secret })
    TestEnv.UnitButton(secret, "party1")
    local named = TestEnv.UnitButton(nil, "party1", {
      parent = TestEnv.Widget({ name = secret }),
      parentKey = "Member",
    })
    TestEnv.UnitButton(nil, "party1", { parent = secret, parentKey = "Member" })
    TestEnv.Widget({ name = "SecretWidget" })
    TestEnv.RunScan(UnitFrameKit)
    assert.are.same({}, UnitFrameKit:GetUnitFrames("party1"))
    assert.is_truthy(named)
  end)

  it("keeps a frame whose aura type is secret, and ignores a secret suffix", function()
    local frame = TestEnv.UnitButton("SecretTypeAttribute", "party1", {
      attributes = { type = secret, unitsuffix = secret },
    })
    TestEnv.RunScan(UnitFrameKit)
    assert.are.equal(frame, UnitFrameKit:GetUnitFrame("party1"))
  end)

  it("treats a secret attribute or UnitIsUnit answer at query time as no match", function()
    local frame = TestEnv.UnitButton("CompactPartyFrameMember2", "party1")
    TestEnv.RunScan(UnitFrameKit)
    frame.attributes.unit = secret
    assert.is_nil(UnitFrameKit:GetUnitFrame("party1"))
    frame.attributes.unit = "party1"
    TestEnv.SetGlobal("UnitIsUnit", function()
      return secret
    end)
    assert.is_nil(UnitFrameKit:GetUnitFrame("party1"))
  end)

  it("still queries when UnitExists answers a secret", function()
    local frame = TestEnv.UnitButton("CompactPartyFrameMember2", "party1")
    TestEnv.RunScan(UnitFrameKit)
    TestEnv.SetGlobal("UnitExists", function()
      return secret
    end)
    assert.are.equal(frame, UnitFrameKit:GetUnitFrame("party1"))
  end)

  it("ignores secret nameplates, secret forbidden answers and secret children", function()
    TestEnv.SetNamePlate("nameplate1", secret)
    assert.is_nil(UnitFrameKit:GetNamePlate("nameplate1"))
    TestEnv.SetNamePlate("nameplate2", TestEnv.Widget({ forbidden = secret }))
    assert.is_nil(UnitFrameKit:GetNamePlate("nameplate2"))
    local plate = TestEnv.Widget({ UnitFrame = secret })
    TestEnv.SetNamePlate("nameplate3", plate)
    assert.are.equal(plate, UnitFrameKit:GetNamePlate("nameplate3"))
  end)

  it("ignores secret event units and a secret elapsed time", function()
    UnitFrameKit:GetUnitFrame("party1")
    TestEnv.Tick(0.016)
    TestEnv.Emit("UNIT_PET", secret)
    assert.is_false(UnitFrameKit:IsScanning())
    TestEnv.Emit("GROUP_ROSTER_UPDATE")
    local update = rawget(UnitFrameKit._state, "scripts").OnUpdate
    update(nil, secret)
    assert.is_true(UnitFrameKit:IsScanning())
    update(nil, 1)
    assert.is_false(UnitFrameKit:IsScanning())
  end)
end)
