local TestEnv = require("WidgetKitTestEnv")

-- Revision 9 made `Create`, `Release`, the text setters and the `List` layout
-- do inline what their helpers did, and read the host's secret probe once per
-- call or pass. These specs pin that every step, order and message stayed the
-- same on those paths, including the edge cases the inlined code handles
-- itself.

---Register a container type whose hooks and callbacks record what ran.
---@param WidgetKit table
---@param typeName string
---@param record string[] the order things ran in
---@param onRelease fun(self: table)? extra work for the type's `OnRelease` hook
local function registerRecordingContainer(WidgetKit, typeName, record, onRelease)
  WidgetKit:RegisterType(typeName, function()
    local createFrame = TestEnv.GetGlobal("CreateFrame")
    local frame = createFrame("Frame")
    return {
      frame = frame,
      content = createFrame("Frame", frame),
      OnRelease = function(self)
        record[#record + 1] = "hook"
        if onRelease ~= nil then
          onRelease(self)
        end
      end,
    }
  end, 1)
end

describe("WidgetKit fast paths", function()
  local WidgetKit
  before_each(function()
    WidgetKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  describe("Release", function()
    it("runs the OnRelease callback, the children last first, then the type's hook", function()
      local order = {}
      registerRecordingContainer(WidgetKit, "SpecRecording", order)
      local container = WidgetKit:Create("SpecRecording")
      container:SetCallback("OnRelease", function(_, name)
        order[#order + 1] = "callback " .. name
      end)
      container:PauseLayout()
      for index = 1, 3 do
        local label = WidgetKit:Create("Label")
        label:SetCallback("OnRelease", function()
          order[#order + 1] = "child " .. index
        end)
        container:AddChild(label)
      end
      WidgetKit:Release(container)
      assert.are.same({ "callback OnRelease", "child 3", "child 2", "child 1", "hook" }, order)
      assert.are.equal(0, #WidgetKit._state.records[container].children)
    end)

    it("clears a callback and user data the type's hook sets while releasing", function()
      local order = {}
      registerRecordingContainer(WidgetKit, "SpecLateCallback", order, function(self)
        -- The widget had no callback table until now.
        self:SetCallback("OnClick", function()
          order[#order + 1] = "late click"
        end)
        self:SetUserData("late", true)
      end)
      local container = WidgetKit:Create("SpecLateCallback")
      WidgetKit:Release(container)
      local reused = WidgetKit:Create("SpecLateCallback")
      assert.are.equal(container, reused)
      assert.is_false(reused:Fire("OnClick"))
      assert.is_nil(reused:GetUserData("late"))
      assert.are.same({ "hook" }, order)
    end)

    it("reports an OnRelease callback error and still releases the widget", function()
      local button = WidgetKit:Create("Button")
      button:SetCallback("OnRelease", function()
        error("callback failure", 0)
      end)
      TestEnv.TakeReportedErrors()
      assert.is_true(WidgetKit:Release(button))
      local reported = TestEnv.TakeReportedErrors()
      assert.are.equal(1, #reported)
      assert.are.equal("callback failure", reported[1].value)
      assert.is_false(button:IsReleasing())
      assert.has_error(function()
        button:GetFrame()
      end)
    end)

    it("parks a released frame on UIParent, or on the holder when there is none", function()
      local uiParent = TestEnv.GetGlobal("UIParent")
      local label = WidgetKit:Create("Label")
      WidgetKit:Release(label)
      assert.are.equal(uiParent, label.frame:GetParent())

      -- A `UIParent` that is not a frame counts as none, at every release.
      TestEnv.SetGlobal("UIParent", {})
      label = WidgetKit:Create("Label")
      WidgetKit:Release(label)
      local holder = WidgetKit._state.holder
      assert.are.equal(holder, label.frame:GetParent())
      assert.is_false(holder:IsShown())

      TestEnv.SetGlobal("UIParent", uiParent)
      label = WidgetKit:Create("Label")
      WidgetKit:Release(label)
      assert.are.equal(uiParent, label.frame:GetParent())
    end)

    it("counts borrowed widgets per version on every acquire and release", function()
      local borrowed = WidgetKit._state.types.Button.borrowed
      local before = borrowed[3] or 0
      local first = WidgetKit:Create("Button")
      local second = WidgetKit:Create("Button")
      assert.are.equal(before + 2, borrowed[3])
      first:Release()
      WidgetKit:Release(second)
      assert.are.equal(before, borrowed[3])
    end)
  end)

  describe("Create", function()
    it("refuses a bad name before it indexes the types, and answers unknown types", function()
      TestEnv.InstallSecretProbe()
      local secret = TestEnv.NewSecret()
      assert.has_error(function()
        WidgetKit:Create(secret)
      end)
      assert.has_error(function()
        WidgetKit:Create("")
      end)
      assert.has_error(function()
        WidgetKit:Create(42)
      end)
      local widget, reason = WidgetKit:Create("SpecNoSuchType")
      assert.is_nil(widget)
      assert.are.equal("unknownType", reason)
    end)

    it("hands out a new serial on every acquire", function()
      local label = WidgetKit:Create("Label")
      local first = WidgetKit._state.serial
      WidgetKit:Release(label)
      assert.are.equal(label, WidgetKit:Create("Label"))
      assert.are.equal(first + 1, WidgetKit._state.serial)
    end)
  end)

  describe("text setters", function()
    it("check the widget before the text, with the widget messages", function()
      TestEnv.InstallSecretProbe()
      local secret = TestEnv.NewSecret()
      local button = WidgetKit:Create("Button")
      WidgetKit:Release(button)
      local ok, message = pcall(button.SetText, button, secret)
      assert.is_false(ok)
      assert.is_truthy(
        message:find("WidgetKit Button:SetText cannot be called on a released widget", 1, true)
      )
      ok, message = pcall(button.SetText, {}, "text")
      assert.is_false(ok)
      assert.is_truthy(
        message:find("WidgetKit Button:SetText must be called on a WidgetKit widget", 1, true)
      )
    end)

    it("show strings and numbers, clear on nil and refuse other types", function()
      local label = WidgetKit:Create("Label")
      label:SetText("words")
      assert.are.equal("words", label:GetText())
      label:SetText(42)
      assert.are.equal(42, tonumber(label:GetText()))
      label:SetText(nil)
      assert.are.equal("", label:GetText())
      local ok, message = pcall(label.SetText, label, {})
      assert.is_false(ok)
      assert.is_truthy(
        message:find("WidgetKit Label:SetText text must be a string, a number or nil", 1, true)
      )
    end)
  end)

  describe("SetCallback", function()
    it("clears without creating a table, replaces in place and refuses non-functions", function()
      local button = WidgetKit:Create("Button")
      button:SetCallback("OnClick", nil)
      assert.is_nil(WidgetKit._state.records[button].callbacks)
      local calls = {}
      button:SetCallback("OnClick", function()
        calls[#calls + 1] = "first"
      end)
      button:SetCallback("OnClick", function()
        calls[#calls + 1] = "second"
      end)
      assert.are.equal(1, WidgetKit._state.records[button].callbackCount)
      button:Fire("OnClick")
      button:SetCallback("OnClick", nil)
      assert.are.equal(0, WidgetKit._state.records[button].callbackCount)
      assert.is_false(button:Fire("OnClick"))
      assert.are.same({ "second" }, calls)
      assert.has_error(function()
        button:SetCallback("OnClick", true)
      end, "WidgetKit.Widget:SetCallback callback must be a function or nil")
    end)
  end)

  describe("List", function()
    ---A container holding the children given, laid out once after they are added.
    ---@return table group
    local function listOf(width, ...)
      local group = WidgetKit:Create("Group")
      group:SetWidth(width)
      -- Anchored, so the content has a width to read.
      group:SetPoint("TOPLEFT", TestEnv.GetGlobal("UIParent"), "TOPLEFT", 0, 0)
      group:PauseLayout()
      group:AddChildren(...)
      group:ResumeLayout()
      return group
    end

    it("tells full-width and relative-width children their width, and skips hidden ones", function()
      local told = {}
      WidgetKit:RegisterType("SpecSized", function()
        local frame = TestEnv.GetGlobal("CreateFrame")("Frame")
        frame:SetHeight(10)
        local widget = { frame = frame }
        widget.OnWidthSet = function(_, width)
          told[#told + 1] = width
        end
        return widget
      end, 1)
      local full = WidgetKit:Create("SpecSized")
      full:SetFullWidth(true)
      local half = WidgetKit:Create("SpecSized")
      half:SetRelativeWidth(0.5)
      local hidden = WidgetKit:Create("SpecSized")
      hidden:SetFullWidth(true)
      local plain = WidgetKit:Create("SpecSized")
      local group = listOf(212, full, half, hidden, plain)
      -- Hidden after `AddChild`, which shows a child.
      hidden:Hide()
      local contentWidth = group:GetContent():GetWidth()
      assert.is_true(contentWidth > 0)
      told = {}
      assert.is_true(group:PerformLayout())
      assert.are.same({ contentWidth, contentWidth * 0.5 }, told)
      assert.are.equal(contentWidth * 0.5, half:GetWidth())
      -- Three shown children of 10 pixels each, stacked.
      local _, _, _, _, y = plain:GetPoint(1)
      assert.are.equal(-20, y)
    end)

    it("reports an OnWidthSet error and goes on with the pass", function()
      WidgetKit:RegisterType("SpecFailingWidth", function()
        local frame = TestEnv.GetGlobal("CreateFrame")("Frame")
        frame:SetHeight(7)
        return {
          frame = frame,
          OnWidthSet = function()
            error("width failure", 0)
          end,
        }
      end, 1)
      local failing = WidgetKit:Create("SpecFailingWidth")
      failing:SetFullWidth(true)
      local after = WidgetKit:Create("Label")
      local group = listOf(200, failing, after)
      TestEnv.TakeReportedErrors()
      assert.is_true(group:PerformLayout())
      local reported = TestEnv.TakeReportedErrors()
      assert.are.equal(1, #reported)
      assert.are.equal("width failure", reported[1].value)
      local _, _, _, _, y = after:GetPoint(1)
      assert.are.equal(-7, y)
    end)

    it("lays a nested container out before reading its height", function()
      local inner = WidgetKit:Create("Group")
      inner:SetFullWidth(true)
      inner:PauseLayout()
      local label = WidgetKit:Create("Label")
      label:SetText("inside")
      inner:AddChild(label)
      inner:ResumeLayout()
      local below = WidgetKit:Create("Label")
      local outer = listOf(300, inner, below)
      assert.is_true(outer:PerformLayout())
      local _, _, _, _, y = below:GetPoint(1)
      assert.are.equal(-inner:GetHeight(), y)
    end)

    it("refuses a pass whose hook released the container, and lays out again after", function()
      local releaseOnStart = true
      WidgetKit:RegisterType("SpecSelfReleasing", function()
        local createFrame = TestEnv.GetGlobal("CreateFrame")
        local frame = createFrame("Frame")
        return {
          frame = frame,
          content = createFrame("Frame", frame),
          OnLayoutStart = function(self)
            if releaseOnStart then
              WidgetKit:Release(self)
            end
          end,
        }
      end, 1)
      local container = WidgetKit:Create("SpecSelfReleasing")
      local ok, message = pcall(container.PerformLayout, container)
      assert.is_false(ok)
      assert.is_truthy(
        message:find(
          "WidgetKit.Container:LayoutFinished cannot be called on a released widget",
          1,
          true
        )
      )
      assert.are.equal(0, WidgetKit._state.layoutDepth)
      releaseOnStart = false
      local fresh = WidgetKit:Create("SpecSelfReleasing")
      assert.is_true(fresh:PerformLayout())
    end)
  end)

  describe("AddChild", function()
    it("appends in order and inserts before a given child", function()
      local group = WidgetKit:Create("Group")
      group:PauseLayout()
      local first, second, third =
        WidgetKit:Create("Label"), WidgetKit:Create("Label"), WidgetKit:Create("Label")
      group:AddChild(first)
      group:AddChild(third)
      group:AddChild(second, third)
      assert.are.same({ first, second, third }, group:GetChildren())
    end)
  end)

  describe("Slider", function()
    it("starts every use at 0 of 0 to 100, shown as 0", function()
      local slider = WidgetKit:Create("Slider")
      slider:SetSliderValues(-5, 5, 0.5)
      slider:SetValue(2.5)
      WidgetKit:Release(slider)
      local reused = WidgetKit:Create("Slider")
      assert.are.equal(slider, reused)
      assert.are.equal(0, reused:GetValue())
      assert.are.equal("0", reused.valueBox:GetText())
      assert.are.equal("0", reused.lowText:GetText())
      assert.are.equal("100", reused.highText:GetText())
      assert.are.equal(0, reused.slider:GetValue())
    end)
  end)
end)
