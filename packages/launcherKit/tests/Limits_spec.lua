local TestEnv = require("LauncherKitTestEnv")

describe("LauncherKit limits", function()
  local LauncherKit, BrokerKit
  before_each(function()
    LauncherKit, BrokerKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("reports the defaults and the constants in a fresh table", function()
    assert.are.equal(64, LauncherKit.MAX_LAUNCHERS)
    assert.are.equal(256, LauncherKit.LAUNCHERS_CEILING)
    local limits = LauncherKit:GetLimits()
    assert.are.same({ maxLaunchers = 64 }, limits)
    assert.are_not.equal(limits, LauncherKit:GetLimits())
  end)

  it("refuses the launcher past maxLaunchers and keeps every launcher when lowered", function()
    for _, name in ipairs({ "A", "B", "C" }) do
      BrokerKit:New(name)
    end
    LauncherKit:SetLimits({ maxLaunchers = 2 })
    LauncherKit:Register("A", {})
    LauncherKit:Register("B", {})
    TestEnv.expectErrorContaining(
      "LauncherKit:Register holds at most 2 launchers; raise maxLaunchers with LauncherKit:SetLimits",
      function()
        LauncherKit:Register("C", {})
      end
    )
    assert.is_nil(LauncherKit:Get("C"))
    LauncherKit:SetLimits({ maxLaunchers = 1 })
    assert.is_not_nil(LauncherKit:Get("B"))
  end)

  it("accepts the ceiling and refuses anything else without changing the limit", function()
    LauncherKit:SetLimits({ maxLaunchers = 256 })
    LauncherKit:SetLimits({})
    assert.are.equal(256, LauncherKit:GetLimits().maxLaunchers)
    for _, value in ipairs({ 0, 257, 2.5, 0 / 0, "8", {} }) do
      TestEnv.expectErrorContaining(
        "limits.maxLaunchers must be an integer from 1 to 256",
        function()
          LauncherKit:SetLimits({ maxLaunchers = value })
        end
      )
    end
    TestEnv.expectErrorContaining(
      "limits holds an unknown field; it accepts maxLaunchers",
      function()
        LauncherKit:SetLimits({ maxButtons = 2 })
      end
    )
    TestEnv.expectErrorContaining("LauncherKit:SetLimits limits must be a table", function()
      LauncherKit:SetLimits(2)
    end)
    assert.are.equal(256, LauncherKit:GetLimits().maxLaunchers)
  end)

  it("reads only the fields of the limits table itself, never through its metatable", function()
    -- `pairs` sees no field on this table, so a value its `__index` hands out
    -- must not be taken either: it was never checked against the ceiling.
    local inherited = setmetatable({}, { __index = { maxLaunchers = 100000 } })
    LauncherKit:SetLimits(inherited)
    assert.are.equal(64, LauncherKit:GetLimits().maxLaunchers)
  end)
end)
