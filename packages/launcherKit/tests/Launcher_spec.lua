local TestEnv = require("LauncherKitTestEnv")

describe("LauncherKit launchers", function()
  local LauncherKit, BrokerKit
  before_each(function()
    LauncherKit, BrokerKit = TestEnv.NewPackage()
    TestEnv.InstallHostErrorHandler()
  end)
  after_each(TestEnv.Reset)

  ---Assert two numbers are within a hundredth of each other.
  local function near(expected, actual)
    assert.is_true(
      math.abs(expected - actual) < 0.01,
      ("expected %.3f, got %.3f"):format(expected, actual)
    )
  end

  local EDGE = 70 + 5

  it("puts a button on the minimap at the default angle, with the object's icon", function()
    BrokerKit:New("MyAddon", { type = "launcher", icon = 134400 })
    local launcher = LauncherKit:Register("MyAddon", {})
    local button = launcher:GetButton()
    assert.are.equal(TestEnv.GetGlobal("Minimap"), button:GetParent())
    assert.is_true(launcher:IsShown())
    local x, y = TestEnv.Offset(button)
    near(-EDGE * math.sqrt(0.5), x)
    near(-EDGE * math.sqrt(0.5), y)
    assert.are.equal(225, LauncherKit.DEFAULT_ANGLE)
    assert.are.equal(launcher, LauncherKit:Get("MyAddon"))
  end)

  it("reads a LibDBIcon-shaped table as it is", function()
    BrokerKit:New("MyAddon")
    local launcher = LauncherKit:Register("MyAddon", { minimapPos = 0, hide = true, lock = true })
    local x, y = TestEnv.Offset(launcher:GetButton())
    near(EDGE, x)
    near(0, y)
    assert.is_false(launcher:IsShown())
    assert.is_true(launcher:IsLocked())
  end)

  it("follows GetMinimapShape: a square quarter puts the button on the square's edge", function()
    BrokerKit:New("MyAddon")
    local storage = { minimapPos = 30 }
    local launcher = LauncherKit:Register("MyAddon", storage)
    local corner = math.sqrt(2 * EDGE * EDGE) - 10
    local x, y = TestEnv.Offset(launcher:GetButton())
    near(EDGE * math.cos(math.rad(30)), x)
    near(EDGE * math.sin(math.rad(30)), y)

    TestEnv.SetGlobal("GetMinimapShape", function()
      return "SQUARE"
    end)
    launcher:Refresh()
    x, y = TestEnv.Offset(launcher:GetButton())
    near(EDGE, x)
    near(corner * 0.5, y)

    -- Only the top-left quarter is round: the top-right one stays square,
    -- the top-left one is a circle again.
    TestEnv.SetGlobal("GetMinimapShape", function()
      return "CORNER-TOPLEFT"
    end)
    launcher:Refresh()
    x = TestEnv.Offset(launcher:GetButton())
    near(EDGE, x)
    storage.minimapPos = 135
    launcher:Refresh()
    x, y = TestEnv.Offset(launcher:GetButton())
    near(-EDGE * math.sqrt(0.5), x)
    near(EDGE * math.sqrt(0.5), y)

    -- A shape nobody knows, an answer that is not a string, and a function
    -- that raises all count as round.
    for _, answer in ipairs({ "HEXAGON", 7 }) do
      TestEnv.SetGlobal("GetMinimapShape", function()
        return answer
      end)
      storage.minimapPos = 30
      launcher:Refresh()
      x = TestEnv.Offset(launcher:GetButton())
      near(EDGE * math.cos(math.rad(30)), x)
    end
    TestEnv.SetGlobal("GetMinimapShape", function()
      error("shape failed")
    end)
    launcher:Refresh()
    x = TestEnv.Offset(launcher:GetButton())
    near(EDGE * math.cos(math.rad(30)), x)
  end)

  it("drags round the edge and saves the angle when the drag stops", function()
    BrokerKit:New("MyAddon")
    local storage = {}
    local button = LauncherKit:Register("MyAddon", storage):GetButton()
    TestEnv.Run(button, "OnDragStart")
    assert.is_function(button:GetScript("OnUpdate"))
    TestEnv.SetCursor(TestEnv.MINIMAP_X, TestEnv.MINIMAP_Y + 300)
    TestEnv.Run(button, "OnUpdate", 0.016)
    local x, y = TestEnv.Offset(button)
    near(0, x)
    near(EDGE, y)
    assert.is_nil(storage.minimapPos)
    TestEnv.Run(button, "OnDragStop")
    assert.is_nil(button:GetScript("OnUpdate"))
    near(90, storage.minimapPos)
  end)

  it("keeps a locked button where it is", function()
    BrokerKit:New("MyAddon")
    local storage = {}
    local launcher = LauncherKit:Register("MyAddon", storage)
    launcher:Lock()
    assert.is_true(storage.lock)
    TestEnv.Run(launcher:GetButton(), "OnDragStart")
    assert.is_nil(launcher:GetButton():GetScript("OnUpdate"))
    TestEnv.Run(launcher:GetButton(), "OnDragStop")
    assert.is_nil(storage.minimapPos)
    launcher:Unlock()
    assert.is_false(storage.lock)
    assert.is_false(launcher:IsLocked())
  end)

  it("saves hide on Show and Hide, and Refresh reads the table again", function()
    BrokerKit:New("MyAddon")
    local storage = {}
    local launcher = LauncherKit:Register("MyAddon", storage)
    launcher:Hide()
    assert.is_true(storage.hide)
    assert.is_false(launcher:IsShown())
    launcher:Show()
    assert.is_false(storage.hide)
    assert.is_true(launcher:IsShown())
    storage.hide = true
    storage.minimapPos = 0
    launcher:Refresh()
    assert.is_false(launcher:IsShown())
    near(EDGE, (TestEnv.Offset(launcher:GetButton())))
  end)

  it("reads and writes through a storage function at every use", function()
    BrokerKit:New("MyAddon")
    local profiles = { first = { minimapPos = 0 }, second = { minimapPos = 180, hide = true } }
    local current = "first"
    local launcher = LauncherKit:Register("MyAddon", function()
      return profiles[current]
    end)
    near(EDGE, (TestEnv.Offset(launcher:GetButton())))
    current = "second"
    launcher:Refresh()
    near(-EDGE, (TestEnv.Offset(launcher:GetButton())))
    assert.is_false(launcher:IsShown())
    launcher:Show()
    assert.is_false(profiles.second.hide)
    assert.is_nil(profiles.first.hide)
  end)

  it("reports a storage function that raises or returns no table, and writes nothing", function()
    BrokerKit:New("MyAddon")
    local answer = nil
    local launcher = LauncherKit:Register("MyAddon", function()
      if answer == "raise" then
        error("storage failed", 0)
      end
      return answer
    end)
    assert.are.same(
      { "LauncherKit storage for MyAddon must return a table" },
      TestEnv.TakeReportedValues()
    )
    answer = "raise"
    launcher:Hide()
    assert.are.same({ "storage failed" }, TestEnv.TakeReportedValues())
    assert.is_false(launcher:IsShown())
  end)

  it("reports a write the storage refuses", function()
    BrokerKit:New("MyAddon")
    local storage = setmetatable({}, {
      __newindex = function()
        error("read-only", 0)
      end,
    })
    local launcher = LauncherKit:Register("MyAddon", storage)
    launcher:Lock()
    assert.are.same({ "read-only" }, TestEnv.TakeReportedValues())
  end)

  it("follows the object's icon attributes", function()
    local object = BrokerKit:New(
      "MyAddon",
      { icon = "Interface\\Icons\\A", iconCoords = { 0.1, 0.9, 0.1, 0.9 } }
    )
    local launcher = LauncherKit:Register("MyAddon", {})
    local icon = launcher:GetButton().icon
    assert.are.equal("Interface\\Icons\\A", icon:GetTexture())
    object.icon = 134400
    assert.are.equal(134400, icon:GetTexture())
    object.iconR, object.iconG, object.iconB = 1, 0, 0
    assert.are.same({ 1, 0, 0, 1 }, { icon:GetVertexColor() })
    object.text = "unrelated"
    assert.are.equal(134400, icon:GetTexture())
  end)

  it("calls the object's OnClick and fills GameTooltip through OnTooltipShow", function()
    local clicks = {}
    BrokerKit:New("MyAddon", {
      OnClick = function(frame, mouseButton)
        clicks[#clicks + 1] = { frame, mouseButton }
      end,
      OnTooltipShow = function(tooltip)
        tooltip:AddLine("My Addon")
      end,
    })
    local button = LauncherKit:Register("MyAddon", {}):GetButton()
    TestEnv.Run(button, "OnClick", "RightButton")
    assert.are.same({ { button, "RightButton" } }, clicks)
    TestEnv.Run(button, "OnEnter")
    local tooltip = TestEnv.GetGlobal("GameTooltip")
    assert.are.equal(button, tooltip:GetOwner())
    assert.are.same({ "My Addon" }, tooltip.lines)
    assert.is_true(tooltip.shown)
    TestEnv.Run(button, "OnLeave")
    assert.is_false(tooltip.shown)
  end)

  it("uses OnEnter and OnLeave when the object has no OnTooltipShow", function()
    local seen = {}
    BrokerKit:New("MyAddon", {
      OnEnter = function(frame)
        seen[#seen + 1] = { "enter", frame }
      end,
      OnLeave = function(frame)
        seen[#seen + 1] = { "leave", frame }
      end,
    })
    local button = LauncherKit:Register("MyAddon", {}):GetButton()
    TestEnv.Run(button, "OnEnter")
    TestEnv.Run(button, "OnLeave")
    assert.are.same({ { "enter", button }, { "leave", button } }, seen)
    assert.is_false(TestEnv.GetGlobal("GameTooltip").shown)
  end)

  it("reports object callbacks that raise", function()
    local function failing()
      error("callback failed", 0)
    end
    BrokerKit:New("MyAddon", { OnClick = failing, OnTooltipShow = failing, OnLeave = failing })
    local button = LauncherKit:Register("MyAddon", {}):GetButton()
    TestEnv.Run(button, "OnClick", "LeftButton")
    TestEnv.Run(button, "OnEnter")
    TestEnv.Run(button, "OnLeave")
    assert.are.same(
      { "callback failed", "callback failed", "callback failed" },
      TestEnv.TakeReportedValues()
    )
  end)

  it("hides its tooltip when a drag starts and shows none during it", function()
    BrokerKit:New("MyAddon", {
      OnTooltipShow = function(tooltip)
        tooltip:AddLine("x")
      end,
    })
    local button = LauncherKit:Register("MyAddon", {}):GetButton()
    TestEnv.Run(button, "OnEnter")
    TestEnv.Run(button, "OnDragStart")
    assert.is_false(TestEnv.GetGlobal("GameTooltip").shown)
    TestEnv.Run(button, "OnEnter")
    assert.is_false(TestEnv.GetGlobal("GameTooltip").shown)
    TestEnv.Run(button, "OnDragStop")
  end)

  it("refuses invalid arguments without creating a button", function()
    BrokerKit:New("MyAddon")
    local cases = {
      { "objectName must be a non-empty string", nil, {} },
      { "objectName must be a non-empty string", "", {} },
      {
        "has no BrokerKit object named Missing; create it with BrokerKit:New first",
        "Missing",
        {},
      },
      { "storage must be a table or a function returning one", "MyAddon", nil },
      { "storage must be a table or a function returning one", "MyAddon", "db" },
    }
    for _, case in ipairs(cases) do
      TestEnv.expectErrorContaining("LauncherKit:Register " .. case[1], function()
        LauncherKit:Register(case[2], case[3])
      end)
    end
    assert.is_nil(LauncherKit:Get("MyAddon"))
    LauncherKit:Register("MyAddon", {})
    TestEnv.expectErrorContaining("LauncherKit:Register MyAddon already has a launcher", function()
      LauncherKit:Register("MyAddon", {})
    end)
  end)

  it("refuses to register without the client's Minimap", function()
    BrokerKit:New("MyAddon")
    TestEnv.SetGlobal("Minimap", nil)
    TestEnv.expectErrorContaining("needs the client's Minimap and CreateFrame", function()
      LauncherKit:Register("MyAddon", {})
    end)
    assert.is_nil(LauncherKit:Get("MyAddon"))
  end)

  it("checks Get's argument and the receivers", function()
    TestEnv.expectErrorContaining(
      "LauncherKit:Get objectName must be a non-empty string",
      function()
        LauncherKit:Get(1)
      end
    )
    BrokerKit:New("MyAddon")
    local launcher = LauncherKit:Register("MyAddon", {})
    for _, name in ipairs({
      "Show",
      "Hide",
      "IsShown",
      "Lock",
      "Unlock",
      "IsLocked",
      "Refresh",
      "GetButton",
    }) do
      TestEnv.expectErrorContaining(
        "LauncherKit.Launcher:" .. name .. " must be called on a LauncherKit launcher",
        function()
          launcher[name]({})
        end
      )
    end
    TestEnv.expectErrorContaining("must be called on the LauncherKit facade", function()
      LauncherKit.Register({}, "MyAddon", {})
    end)
    assert.are.equal("LauncherKit.Launcher", getmetatable(launcher))
  end)
end)
