local TestEnv = require("WidgetKitTestEnv")

-- Kilobytes a guarded workload may allocate: the collector's own accounting
-- noise, far below one table per iteration.
local BUDGET = 1

describe("WidgetKit allocation guards #allocation", function()
  local WidgetKit
  before_each(function()
    WidgetKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("allocates nothing on warm acquire and release cycles", function()
    for _, typeName in ipairs({
      "Label",
      "Group",
      "Button",
      "CheckBox",
      "Slider",
      "EditBox",
      "Heading",
      "Spacer",
    }) do
      -- Warm: build the widget and its lazily created tables. Twice: the
      -- fixture's slider stub stores its first `SetEnabled` in a new field of
      -- the frame table, which grows that table once, on the second use.
      for _ = 1, 2 do
        local warm = WidgetKit:Create(typeName)
        warm:SetCallback("OnClick", function() end)
        warm:SetUserData("key", true)
        WidgetKit:Release(warm)
      end

      local allocated = TestEnv.AllocatedKilobytes(function()
        for _ = 1, 200 do
          local widget = WidgetKit:Create(typeName)
          WidgetKit:Release(widget)
        end
      end)
      assert.is_true(
        allocated < BUDGET,
        typeName .. " acquire/release allocated " .. allocated .. " KB"
      )
    end
  end)

  it("allocates nothing to acquire, fill and release the benchmark's five types", function()
    -- The fills `tooling/bench` gives each type: the calls an options dialog
    -- makes, through the text setters, the slider's snapping and formatting
    -- and the edit box, on the paths revision 9 made inline.
    local fills = {
      Label = function(widget)
        widget:SetText("Scale of the frame")
      end,
      Button = function(widget)
        widget:SetText("Reset")
      end,
      CheckBox = function(widget)
        widget:SetLabel("Show in combat")
        widget:SetValue(true)
      end,
      Slider = function(widget)
        widget:SetLabel("Scale")
        widget:SetSliderValues(0, 100, 1)
        widget:SetValue(50)
      end,
      EditBox = function(widget)
        widget:SetLabel("Name")
        widget:SetText("Tester")
      end,
    }
    for _, typeName in ipairs({ "Label", "Button", "CheckBox", "Slider", "EditBox" }) do
      local fill = fills[typeName]
      -- Twice, for the slider stub's one-time growth (see above).
      for _ = 1, 2 do
        local warm = WidgetKit:Create(typeName)
        fill(warm)
        WidgetKit:Release(warm)
      end

      local allocated = TestEnv.AllocatedKilobytes(function()
        for _ = 1, 200 do
          local widget = WidgetKit:Create(typeName)
          fill(widget)
          WidgetKit:Release(widget)
        end
      end)
      assert.is_true(
        allocated < BUDGET,
        typeName .. " acquire, fill and release allocated " .. allocated .. " KB"
      )
    end
  end)

  it("allocates nothing to fill a group with labels, lay it out and release it", function()
    local function cycle()
      local group = WidgetKit:Create("Group")
      group:SetWidth(300)
      group:SetTitle("General")
      group:PauseLayout()
      for _ = 1, 10 do
        local label = WidgetKit:Create("Label")
        label:SetText("An option described in one line")
        label:SetFullWidth(true)
        group:AddChild(label)
      end
      group:ResumeLayout()
      group:PerformLayout()
      WidgetKit:Release(group)
    end
    cycle()
    local allocated = TestEnv.AllocatedKilobytes(function()
      for _ = 1, 50 do
        cycle()
      end
    end)
    assert.is_true(allocated < BUDGET, "group cycle allocated " .. allocated .. " KB")
  end)

  it("allocates nothing when PerformLayout runs over unchanged children", function()
    local window = WidgetKit:Create("Frame")
    local group = WidgetKit:Create("Group")
    group:SetFullWidth(true)
    window:AddChild(group)
    for _ = 1, 10 do
      local label = WidgetKit:Create("Label")
      label:SetText("text")
      label:SetFullWidth(true)
      group:AddChild(label)
    end
    for _, layout in ipairs({ "List", "Flow", "Fill" }) do
      window:SetLayout(layout)
      group:SetLayout(layout)
      window:PerformLayout()
      local allocated = TestEnv.AllocatedKilobytes(function()
        for _ = 1, 100 do
          window:PerformLayout()
        end
      end)
      assert.is_true(allocated < BUDGET, layout .. " layout allocated " .. allocated .. " KB")
    end
  end)

  it("allocates nothing to fire a callback", function()
    local button = WidgetKit:Create("Button")
    button:SetCallback("OnClick", function() end)
    local allocated = TestEnv.AllocatedKilobytes(function()
      for _ = 1, 500 do
        button:Fire("OnClick", "LeftButton")
      end
    end)
    assert.is_true(allocated < BUDGET, "Fire allocated " .. allocated .. " KB")
  end)
end)
