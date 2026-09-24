local TestEnv = require("WidgetKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Run `action` and assert it failed with `message` reported at the line of this
---spec file that called into WidgetKit. A wrong `error` level shows up either
---as a different line number or as a message with no `file:line` prefix.
---
---`action` receives a `mark` function; calling `mark()` records the line of the
---statement on the line after it, which must be the call into WidgetKit.
---@param message string
---@param action fun(mark: fun())
local function assertReportedAtCaller(message, action)
  local expectedLine = nil
  local function mark()
    expectedLine = debug.getinfo(2, "l").currentline + 1
  end
  local ok, value = pcall(action, mark)
  assert.is_false(ok)
  assert.are.equal(SOURCE .. ":" .. tostring(expectedLine) .. ": " .. message, value)
end

local function noop() end

describe("WidgetKit error levels", function()
  local WidgetKit
  before_each(function()
    WidgetKit = TestEnv.NewPackage()
    TestEnv.InstallSecretProbe()
  end)
  after_each(TestEnv.Reset)

  it("points facade argument errors at the caller", function()
    assertReportedAtCaller("WidgetKit:RegisterType name must be a non-empty string", function(mark)
      mark()
      WidgetKit:RegisterType(nil, noop, 1)
    end)
    assertReportedAtCaller(
      'WidgetKit:RegisterType options contains unknown field "size"',
      function(mark)
        mark()
        WidgetKit:RegisterType("X", noop, 1, { size = 1 })
      end
    )
    assertReportedAtCaller("WidgetKit:Create must be called on the WidgetKit facade", function(mark)
      mark()
      WidgetKit.Create({}, "Label")
    end)
    assertReportedAtCaller("WidgetKit:Create name must not be a secret value", function(mark)
      local secret = TestEnv.NewSecret()
      mark()
      WidgetKit:Create(secret)
    end)
    assertReportedAtCaller("WidgetKit:RegisterLayout layout must be a function", function(mark)
      mark()
      WidgetKit:RegisterLayout("X", nil)
    end)
    assertReportedAtCaller("WidgetKit:SetFocus must be called on a WidgetKit widget", function(mark)
      mark()
      WidgetKit:SetFocus({})
    end)
  end)

  it("points release refusals at the caller", function()
    local label = WidgetKit:Create("Label")
    WidgetKit:Release(label)
    assertReportedAtCaller("WidgetKit:Release widget was already released", function(mark)
      mark()
      WidgetKit:Release(label)
    end)
    assertReportedAtCaller("WidgetKit:Release widget must be a WidgetKit widget", function(mark)
      mark()
      WidgetKit:Release({})
    end)
  end)

  it("points constructor contract failures at the caller of Create", function()
    WidgetKit:RegisterType("Bad", function()
      return {}
    end, 1)
    assertReportedAtCaller(
      'WidgetKit:Create constructor of type "Bad" must return a table whose frame field is a frame',
      function(mark)
        mark()
        WidgetKit:Create("Bad")
      end
    )
  end)

  it("points widget and container method errors at the caller", function()
    local label = WidgetKit:Create("Label")
    local group = WidgetKit:Create("Group")
    assertReportedAtCaller("WidgetKit.Widget:SetWidth width must be a number", function(mark)
      mark()
      label:SetWidth("wide")
    end)
    assertReportedAtCaller(
      "WidgetKit.Widget:SetCallback callback must be a function or nil",
      function(mark)
        mark()
        label:SetCallback("OnClick", 1)
      end
    )
    assertReportedAtCaller(
      "WidgetKit.Widget:SetWidth must be called on a WidgetKit widget",
      function(mark)
        mark()
        WidgetKit.Widget.SetWidth({}, 1)
      end
    )
    assertReportedAtCaller(
      "WidgetKit.Container:AddChild must be called on a WidgetKit container",
      function(mark)
        mark()
        WidgetKit.Container.AddChild(label, group)
      end
    )
    assertReportedAtCaller(
      "WidgetKit.Container:AddChild beforeWidget must be a child of this container",
      function(mark)
        mark()
        group:AddChild(label, WidgetKit:Create("Label"))
      end
    )
    assertReportedAtCaller(
      'WidgetKit.Container:SetLayout layout "Grid" is not registered',
      function(mark)
        mark()
        group:SetLayout("Grid")
      end
    )
  end)

  it("points base widget method errors at the caller", function()
    local label = WidgetKit:Create("Label")
    assertReportedAtCaller(
      "WidgetKit Label:SetText text must not be a secret value unless options.allowSecret is true",
      function(mark)
        local secret = TestEnv.NewSecret()
        mark()
        label:SetText(secret)
      end
    )
    assertReportedAtCaller(
      'WidgetKit Label:SetText options contains unknown field "x"',
      function(mark)
        mark()
        label:SetText("text", { x = 1 })
      end
    )
    local slider = WidgetKit:Create("Slider")
    assertReportedAtCaller("WidgetKit Slider:SetSliderValues step must be a number", function(mark)
      mark()
      slider:SetSliderValues(0, 1, "fine")
    end)
    local dropdown = WidgetKit:Create("Dropdown")
    assertReportedAtCaller("WidgetKit Dropdown:SetList labels must be strings", function(mark)
      mark()
      dropdown:SetList({ a = 1 })
    end)
    local window = WidgetKit:Create("Frame")
    assertReportedAtCaller(
      "WidgetKit Frame:BindPosition storageTable must be a table",
      function(mark)
        mark()
        window:BindPosition(nil)
      end
    )
    assertReportedAtCaller(
      'WidgetKit Frame:BindPosition options contains unknown field "delays"',
      function(mark)
        mark()
        window:BindPosition({}, { delays = 1 })
      end
    )
  end)

  it("points anchor, binding and rendering errors at the caller", function()
    local frame = TestEnv.GetGlobal("CreateFrame")("Frame")
    assertReportedAtCaller(
      "WidgetKit.Anchor.Normalize point must be one of the nine anchor points",
      function(mark)
        mark()
        WidgetKit.Anchor.Normalize(frame, "MIDDLE")
      end
    )
    assertReportedAtCaller("WidgetKit.Anchor.Apply anchor.y must be a number", function(mark)
      mark()
      WidgetKit.Anchor.Apply(frame, { point = "TOP", y = "up" })
    end)
    assertReportedAtCaller(
      "WidgetKit.Anchor.FromRect parentRect must be a table with left, bottom, width and height",
      function(mark)
        mark()
        WidgetKit.Anchor.FromRect({ left = 0, bottom = 0, width = 1, height = 1 }, nil)
      end
    )
    assertReportedAtCaller(
      "WidgetKit:BindPosition options.delay must not be negative",
      function(mark)
        mark()
        WidgetKit:BindPosition(frame, {}, { delay = -1 })
      end
    )
    local binding = WidgetKit:BindPosition(frame, {})
    assertReportedAtCaller("WidgetKit.Binding:OnMoved callback must be a function", function(mark)
      mark()
      binding:OnMoved(nil)
    end)
    assertReportedAtCaller(
      "WidgetKit.Binding:Capture must be called on a WidgetKit binding",
      function(mark)
        mark()
        WidgetKit.Binding.Capture({})
      end
    )
    assertReportedAtCaller(
      "WidgetKit:RenderOptions container must be an active WidgetKit container",
      function(mark)
        mark()
        WidgetKit:RenderOptions({
          Describe = noop,
          Get = noop,
          Set = noop,
          Validate = noop,
          Execute = noop,
          IsDisabled = noop,
          IsHidden = noop,
          OnChange = noop,
        }, nil)
      end
    )
    assertReportedAtCaller(
      "WidgetKit.Rendering:GetWidget must be called on a WidgetKit rendering",
      function(mark)
        mark()
        WidgetKit.Rendering.GetWidget({}, "x")
      end
    )
  end)
end)
