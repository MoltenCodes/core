local TestEnv = require("WidgetKitTestEnv")

---A small options tree over `store`, with a toggle, an input whose validate
---may raise, and an execute option confirmed with `confirm = true`.
local function defineTree(OptionsKit, store)
  return OptionsKit:Define("OwnershipSpec", {
    type = "group",
    args = {
      enabled = {
        type = "toggle",
        name = "Enabled",
        order = 1,
        get = function()
          return store.enabled
        end,
        set = function(_, value)
          store.enabled = value
        end,
      },
      label = {
        type = "input",
        name = "Label",
        order = 2,
        get = function()
          return store.label
        end,
        set = function(_, value)
          store.label = value
        end,
        validate = function(_, value)
          if value == "boom" then
            error("validate exploded", 0)
          end
          return true
        end,
      },
      reset = {
        type = "execute",
        name = "Reset",
        order = 3,
        confirm = true,
        func = function()
          store.resets = (store.resets or 0) + 1
        end,
      },
    },
  })
end

describe("WidgetKit rendering ownership", function()
  local WidgetKit, OptionsKit, store, tree
  before_each(function()
    local _
    WidgetKit, _, _, _, _, OptionsKit = TestEnv.NewPackage()
    TestEnv.TakeReportedErrors()
    store = { enabled = true, label = "main" }
    tree = defineTree(OptionsKit, store)
  end)
  after_each(TestEnv.Reset)

  it("releases the rendering when its container is released", function()
    local group = WidgetKit:Create("Group")
    local rendering = WidgetKit:RenderOptions(tree, group)
    local checkBox = rendering:GetWidget("enabled")
    WidgetKit:Release(group)
    assert.is_true(rendering:IsReleased())
    assert.is_false(WidgetKit:IsWidget(checkBox))
    assert.are.equal(0, WidgetKit:GetStatistics().active)
  end)

  it("never writes into a widget re-acquired after its container was released", function()
    local group = WidgetKit:Create("Group")
    WidgetKit:RenderOptions(tree, group)
    WidgetKit:Release(group)

    -- Take every pooled CheckBox back, as another addon would.
    local reacquired = {}
    for index = 1, WidgetKit:GetStatistics().byType.CheckBox.available do
      local box = WidgetKit:Create("CheckBox")
      box:SetTriState(true)
      box:SetValue(nil)
      reacquired[index] = box
    end
    assert.is_true(#reacquired > 0)

    -- Neither a write nor a refresh reaches them, and nothing raises.
    tree:Set("enabled", false)
    tree:Set("enabled", true)
    for _, box in ipairs(reacquired) do
      assert.is_nil(box:GetValue())
    end
    assert.are.same({}, TestEnv.TakeReportedErrors())
  end)

  it("makes Release after the container's release a no-op returning false", function()
    local group = WidgetKit:Create("Group")
    local rendering = WidgetKit:RenderOptions(tree, group)
    WidgetKit:Release(group)
    local other = WidgetKit:Create("Group")
    local label = WidgetKit:Create("CheckBox")
    other:AddChild(label)
    assert.is_false(rendering:Release())
    assert.is_true(WidgetKit:IsWidget(label))
    assert.is_true(WidgetKit:IsWidget(other))
    assert.is_false(rendering:Refresh())
    assert.is_nil(rendering:GetWidget("enabled"))
  end)

  it("leaves alone a rendered widget someone else released and re-acquired", function()
    local window = WidgetKit:Create("Frame")
    local rendering = WidgetKit:RenderOptions(tree, window)
    local stolen = rendering:GetWidget("enabled")
    WidgetKit:Release(stolen)
    local reused = WidgetKit:Create("CheckBox")
    assert.are.equal(stolen, reused)
    reused:SetValue(false)

    tree:Set("enabled", true)
    assert.is_false(reused:GetValue())
    assert.is_nil(rendering:GetWidget("enabled"))
    rendering:Release()
    assert.is_true(WidgetKit:IsWidget(reused))
  end)

  it("releases its renderings with a container released through an ancestor", function()
    local window = WidgetKit:Create("Frame")
    local group = WidgetKit:Create("Group")
    window:AddChild(group)
    local rendering = WidgetKit:RenderOptions(tree, group)
    WidgetKit:Release(window)
    assert.is_true(rendering:IsReleased())
    assert.are.equal(0, WidgetKit:GetStatistics().active)
  end)

  it("shows and reports a raising validate, and does not stay busy", function()
    local window = WidgetKit:Create("Frame")
    local rendering = WidgetKit:RenderOptions(tree, window)
    local edit = rendering:GetWidget("label")
    edit.singleBox:SetText("boom")
    TestEnv.RunScript(edit.singleBox, "OnEnterPressed")
    assert.are.equal("validate exploded", rendering:GetMessage("label"))
    assert.are.equal(1, #TestEnv.TakeReportedErrors())
    assert.are.equal("main", store.label)

    -- A later change still refreshes the widgets.
    tree:Set("enabled", false)
    assert.is_false(rendering:GetWidget("enabled"):GetValue())
  end)

  it("resumes the container and raises at the caller when building raises", function()
    WidgetKit:RegisterType("CheckBox", function()
      return {
        frame = TestEnv.GetGlobal("CreateFrame")("Frame"),
        OnAcquire = function()
          error("acquire exploded", 0)
        end,
      }
    end, 3)
    local window = WidgetKit:Create("Frame")
    TestEnv.expectErrorContaining("WidgetKit:RenderOptions acquire exploded", function()
      WidgetKit:RenderOptions(tree, window)
    end)
    assert.is_false(window:IsLayoutPaused())
    assert.are.equal(0, window:GetNumChildren())
    assert.are.equal(1, WidgetKit:GetStatistics().active)
  end)

  it("disarms an armed confirmation at the next refresh without SchedulerKit", function()
    local window = WidgetKit:Create("Frame")
    local rendering = WidgetKit:RenderOptions(tree, window, { confirmText = "Sure?" })
    local reset = rendering:GetWidget("reset")
    reset.frame:Click()
    assert.are.equal("Sure?", rendering:GetMessage("reset"))
    rendering:Refresh()
    assert.is_nil(rendering:GetMessage("reset"))
    reset.frame:Click()
    assert.is_nil(store.resets)
    reset.frame:Click()
    assert.are.equal(1, store.resets)
  end)

  it("asks the English default for confirm = true", function()
    local rendering = WidgetKit:RenderOptions(tree, WidgetKit:Create("Frame"))
    rendering:GetWidget("reset").frame:Click()
    assert.are.equal("Click again to confirm.", rendering:GetMessage("reset"))
  end)
end)
