local TestEnv = require("LauncherKitTestEnv")

describe("LauncherKit:AddToCompartment", function()
  local LauncherKit, BrokerKit
  before_each(function()
    LauncherKit, BrokerKit = TestEnv.NewPackage()
    TestEnv.InstallHostErrorHandler()
  end)
  after_each(TestEnv.Reset)

  it("answers unavailable on a client without AddonCompartmentFrame", function()
    BrokerKit:New("MyAddon")
    assert.are.same({ nil, "unavailable" }, { LauncherKit:AddToCompartment("MyAddon") })
    TestEnv.SetGlobal("AddonCompartmentFrame", {})
    assert.are.same({ nil, "unavailable" }, { LauncherKit:AddToCompartment("MyAddon") })
  end)

  it("registers the object's label and icon once, and answers already after", function()
    local frame = TestEnv.InstallCompartment()
    BrokerKit:New("MyAddon", { label = "My Addon", icon = 134400 })
    BrokerKit:New("Plain")
    assert.is_true(LauncherKit:AddToCompartment("MyAddon"))
    assert.is_true(LauncherKit:AddToCompartment("Plain"))
    assert.are.same({ nil, "already" }, { LauncherKit:AddToCompartment("MyAddon") })
    assert.are.equal(2, #frame.registered)
    assert.are.equal("My Addon", frame.registered[1].text)
    assert.are.equal(134400, frame.registered[1].icon)
    assert.are.equal("Plain", frame.registered[2].text)
    assert.is_nil(frame.registered[2].icon)
  end)

  it("calls the object's OnClick with the frame and button, and its tooltip on hover", function()
    local frame = TestEnv.InstallCompartment()
    local clicks = {}
    BrokerKit:New("MyAddon", {
      OnClick = function(clickedFrame, mouseButton)
        clicks[#clicks + 1] = { clickedFrame, mouseButton }
      end,
      OnTooltipShow = function(tooltip)
        tooltip:AddLine("My Addon")
      end,
    })
    LauncherKit:AddToCompartment("MyAddon")
    local entry = frame.registered[1]
    entry.func(nil, { buttonName = "RightButton" }, {})
    entry.func(nil, nil, {})
    assert.are.same({ { frame, "RightButton" }, { frame, "LeftButton" } }, clicks)
    local row = {}
    entry.funcOnEnter(row)
    local tooltip = TestEnv.GetGlobal("GameTooltip")
    assert.are.equal(row, tooltip:GetOwner())
    assert.are.same({ "My Addon" }, tooltip.lines)
    entry.funcOnLeave(row)
    assert.is_false(tooltip.shown)
  end)

  it("reports an OnClick that raises", function()
    local frame = TestEnv.InstallCompartment()
    BrokerKit:New("MyAddon", {
      OnClick = function()
        error("click failed", 0)
      end,
    })
    LauncherKit:AddToCompartment("MyAddon")
    frame.registered[1].func(nil, { buttonName = "LeftButton" })
    assert.are.same({ "click failed" }, TestEnv.TakeReportedValues())
  end)

  it("refuses an object that does not exist", function()
    TestEnv.InstallCompartment()
    TestEnv.expectErrorContaining(
      "LauncherKit:AddToCompartment has no BrokerKit object named Missing",
      function()
        LauncherKit:AddToCompartment("Missing")
      end
    )
  end)
end)
