local TestEnv = require("WidgetKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

-- Which part holds each widget type WidgetKit ships, and its version.
local TYPES = {
  { "Frame", "Containers", 4 },
  { "Group", "Containers", 3 },
  { "ScrollFrame", "Containers", 1 },
  { "Label", "Text", 3 },
  { "Heading", "Text", 3 },
  { "Spacer", "Text", 1 },
  { "Button", "Button", 3 },
  { "CheckBox", "CheckBox", 4 },
  { "Slider", "Slider", 4 },
  { "EditBox", "EditBox", 4 },
  { "Dropdown", "Dropdown", 4 },
  { "ColorPicker", "ColorPicker", 4 },
  { "ScrollList", "ScrollList", 2 },
}

---The message a member of a part that is not loaded raises.
---@param member string
---@param part string
---@return string
local function missing(member, part)
  return member
    .. " is in WidgetKit's "
    .. part
    .. " part, which is not loaded: add widgetKit\\parts\\WidgetKit-"
    .. part
    .. ".lua to embeds.xml (or rebuild it with python3 -m tooling.package.embeds)"
end

---Run `action` and assert it raised `message` at the line after `mark()`.
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

describe("WidgetKit parts", function()
  after_each(TestEnv.Reset)

  describe("with the core alone", function()
    local WidgetKit
    before_each(function()
      WidgetKit = TestEnv.NewCore()
    end)

    it("reports no part loaded and no base type registered", function()
      for index = 1, #TestEnv.PARTS do
        assert.is_nil(WidgetKit:GetPartRevision(TestEnv.PARTS[index]))
      end
      for index = 1, #TYPES do
        assert.is_nil(WidgetKit:GetTypeVersion(TYPES[index][1]))
      end
      assert.is_nil(WidgetKit:GetPartRevision("NotAPart"))
      assert.are.same({}, WidgetKit:GetStatistics().byType)
    end)

    it("names the part to embed when a base type is created", function()
      for index = 1, #TYPES do
        local typeName, part = TYPES[index][1], TYPES[index][2]
        assertReportedAtCaller(missing("WidgetKit:Create " .. typeName, part), function(mark)
          mark()
          WidgetKit:Create(typeName)
        end)
      end
      -- A name WidgetKit does not ship is still only unknown.
      local widget, reason = WidgetKit:Create("SpecUnknown")
      assert.is_nil(widget)
      assert.are.equal("unknownType", reason)
    end)

    it("keeps the whole surface with stand-ins that name their part", function()
      assertReportedAtCaller(missing("WidgetKit:RenderOptions", "Renderer"), function(mark)
        mark()
        WidgetKit:RenderOptions({}, {})
      end)
      assertReportedAtCaller(missing("WidgetKit:CreateMediaPicker", "Dropdown"), function(mark)
        mark()
        WidgetKit:CreateMediaPicker("font")
      end)
      assertReportedAtCaller(missing("WidgetKit:BindPosition", "Position"), function(mark)
        mark()
        WidgetKit:BindPosition({}, {})
      end)
      for _, name in ipairs({ "FromRect", "Normalize", "Apply", "Read" }) do
        assertReportedAtCaller(missing("WidgetKit.Anchor." .. name, "Position"), function(mark)
          mark()
          WidgetKit.Anchor[name]()
        end)
      end
      assert.is_nil(WidgetKit.Anchor.POINTS)
      for _, name in ipairs({ "Capture", "Restore", "Flush", "OnMoved", "Release", "IsReleased" }) do
        assert.are.equal("function", type(WidgetKit.Binding[name]))
        TestEnv.expectErrorContaining(missing("WidgetKit.Binding:" .. name, "Position"), function()
          WidgetKit.Binding[name]({})
        end)
      end
      for _, name in ipairs({
        "Refresh",
        "Rebuild",
        "Release",
        "IsReleased",
        "GetWidget",
        "GetMessage",
      }) do
        TestEnv.expectErrorContaining(
          missing("WidgetKit.Rendering:" .. name, "Renderer"),
          function()
            WidgetKit.Rendering[name]({})
          end
        )
      end
    end)

    it("refuses a part name that is not a non-empty string", function()
      assertReportedAtCaller(
        "WidgetKit:GetPartRevision partName must be a non-empty string",
        function(mark)
          mark()
          WidgetKit:GetPartRevision(1)
        end
      )
      assertReportedAtCaller(
        "WidgetKit:GetPartRevision must be called on the WidgetKit facade",
        function(mark)
          mark()
          WidgetKit.GetPartRevision({}, "Text")
        end
      )
    end)

    it("lays out a custom type in a custom container without any part", function()
      local function constructor()
        local createFrame = TestEnv.GetGlobal("CreateFrame")
        local frame = createFrame("Frame")
        return { frame = frame, content = createFrame("Frame", frame) }
      end
      assert.is_true(WidgetKit:RegisterType("SpecBox", constructor, 1))
      local box = WidgetKit:Create("SpecBox") ---@cast box -nil
      local child = WidgetKit:Create("SpecBox") ---@cast child -nil
      box:AddChild(child)
      assert.is_true(box:PerformLayout())
      WidgetKit:Release(box)
      assert.is_false(WidgetKit:IsWidget(child))
    end)
  end)

  it("loads each part alone after the core", function()
    for index = 1, #TYPES do
      local typeName, part, version = TYPES[index][1], TYPES[index][2], TYPES[index][3]
      local WidgetKit = TestEnv.NewCore({ part })
      if typeName == "ScrollList" then
        TestEnv.InstallScrollBox()
      end
      assert.are.equal(1, WidgetKit:GetPartRevision(part))
      assert.are.equal(version, WidgetKit:GetTypeVersion(typeName))
      local widget = WidgetKit:Create(typeName) ---@cast widget -nil
      assert.is_true(WidgetKit:IsWidget(widget))
      WidgetKit:Release(widget)
    end
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("WidgetKit")
    local WidgetKit = TestEnv.LoadParts({ "Position" })
    assert.are.equal(1, WidgetKit:GetPartRevision("Position"))
    assert.are.equal(9, #WidgetKit.Anchor.POINTS)
  end)

  it("refuses a part loaded before its core", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    TestEnv.expectErrorContaining(
      "MoltenCodes WidgetKit part Text requires WidgetKit API 1 to be loaded first",
      function()
        require("WidgetKit-Text")
      end
    )
  end)

  it("refuses the Position part without SignalKit", function()
    TestEnv.NewCore()
    TestEnv.expectErrorContaining(
      "MoltenCodes WidgetKit part Position requires SignalKit API 1 to be loaded first",
      function()
        require("WidgetKit-Position")
      end
    )
  end)

  it("names the missing type part when the renderer draws without it", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    for _, name in ipairs({ "Registry", "SignalKit", "SchemaKit", "OptionsKit", "WidgetKit" }) do
      require(name)
    end
    TestEnv.InstallClientRules()
    TestEnv.InstallScreen()
    local WidgetKit = TestEnv.LoadParts({ "Containers", "Text", "Renderer" })
    local OptionsKit = require("OptionsKit")
    local tree = OptionsKit:Define("SpecPartsAddon", {
      type = "group",
      args = {
        pick = {
          type = "select",
          name = "Pick",
          values = { a = "A" },
          get = function()
            return "a"
          end,
          set = function() end,
        },
      },
    })
    local group = WidgetKit:Create("Group")
    TestEnv.expectErrorContaining("Dropdown part, which is not loaded", function()
      WidgetKit:RenderOptions(tree, group)
    end)
  end)

  it("leaves Frame:BindPosition to the Position part", function()
    local WidgetKit = TestEnv.NewCore({ "Containers" })
    local window = WidgetKit:Create("Frame") ---@cast window -nil
    assertReportedAtCaller(missing("WidgetKit Frame:BindPosition", "Position"), function(mark)
      mark()
      window:BindPosition({})
    end)
  end)

  it("keeps an installed part when the same revision loads again", function()
    local WidgetKit = TestEnv.NewPackage()
    local record = WidgetKit._state.parts.Text
    local constructor = WidgetKit._state.types.Label.constructor
    package.loaded["WidgetKit-Text"] = nil
    assert.are.equal(WidgetKit, require("WidgetKit-Text"))
    assert.are.equal(record, WidgetKit._state.parts.Text)
    assert.are.equal(constructor, WidgetKit._state.types.Label.constructor)
  end)

  it("lets a higher part revision take over members, constructors and its record", function()
    local WidgetKit = TestEnv.NewPackage()
    local renderOptions = WidgetKit.RenderOptions
    local labelConstructor = WidgetKit._state.types.Label.constructor
    local pooled = WidgetKit:Create("Label")
    WidgetKit:Release(pooled)

    TestEnv.LoadPart("Renderer", 2)
    TestEnv.LoadPart("Text", 2)
    assert.are.equal(2, WidgetKit:GetPartRevision("Renderer"))
    assert.are_not.equal(renderOptions, WidgetKit.RenderOptions)
    -- An equal version takes the newer constructor; the idle widget the older
    -- one built stays in use, as the versioning rule allows.
    assert.are_not.equal(labelConstructor, WidgetKit._state.types.Label.constructor)
    assert.are.equal(3, WidgetKit:GetTypeVersion("Label"))
    assert.are.equal(pooled, WidgetKit:Create("Label"))
  end)

  it("binds every loaded part to a newer core's helpers", function()
    local WidgetKit = TestEnv.NewPackage()
    local bound = {}
    for name, part in pairs(WidgetKit._state.parts) do
      local bind = part.bind
      part.bind = function(helpers)
        bound[name] = helpers
        bind(helpers)
      end
    end
    local renderOptions = WidgetKit.RenderOptions
    TestEnv.LoadCore(WidgetKit.REVISION + 1)
    for index = 1, #TestEnv.PARTS do
      assert.are.equal(WidgetKit._state.helpers, bound[TestEnv.PARTS[index]])
    end
    -- A part's member stays the part's; stand-ins are only for absent parts.
    assert.are.equal(renderOptions, WidgetKit.RenderOptions)
    local label = WidgetKit:Create("Label") ---@cast label -nil
    label:SetText("bound")
    assert.are.equal("bound", label:GetText())
  end)

  it("replaces an earlier core's stand-ins with its own", function()
    local WidgetKit = TestEnv.NewCore()
    local standIn = WidgetKit.RenderOptions
    TestEnv.LoadCore(WidgetKit.REVISION + 1)
    assert.are_not.equal(standIn, WidgetKit.RenderOptions)
    TestEnv.expectErrorContaining("Renderer part, which is not loaded", function()
      WidgetKit:RenderOptions({}, {})
    end)
  end)
end)
