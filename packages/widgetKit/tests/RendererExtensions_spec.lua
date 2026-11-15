local TestEnv = require("WidgetKitTestEnv")

-- The four registries a later part fills to add to the renderer (see
-- `docs/INTERNALS.md`, "Renderer extensions").

describe("WidgetKit renderer extensions", function()
  local WidgetKit, OptionsKit, renderer, store
  before_each(function()
    WidgetKit = TestEnv.NewPackage()
    OptionsKit = require("OptionsKit")
    renderer = WidgetKit._state.parts.Renderer
    store = { flag = true, ran = 0 }
  end)
  after_each(TestEnv.Reset)

  local trees = 0

  ---@param args table
  ---@param childGroups string?
  ---@return table tree
  local function define(args, childGroups)
    trees = trees + 1
    return OptionsKit:Define("SpecExtensions" .. trees, {
      type = "group",
      childGroups = childGroups,
      args = args,
    })
  end

  local function toggle()
    return {
      type = "toggle",
      name = "Flag",
      get = function()
        return store.flag
      end,
      set = function(_, value)
        store.flag = value
      end,
    }
  end

  it("refuses a registry it does not have and an entry without a revision", function()
    TestEnv.expectErrorContaining("registry must be kinds", function()
      renderer.registerExtension("widgets", "x", { revision = 1 })
    end)
    TestEnv.expectErrorContaining("must be a table with a revision", function()
      renderer.registerExtension("kinds", "toggle", {})
    end)
    TestEnv.expectErrorContaining("key must be a non-empty string", function()
      renderer.registerExtension("kinds", "", { revision = 1 })
    end)
  end)

  it("draws a kind with the widget type and functions a part registered", function()
    local applied = {}
    assert.is_true(renderer.registerExtension("kinds", "toggle", {
      revision = 1,
      type = "Label",
      configure = function(_, record, node)
        record.widget:SetText(node.name)
        return true
      end,
      apply = function(record, value)
        applied[#applied + 1] = value
        record.widget:SetText(value and "on" or "off")
      end,
    }))
    local group = WidgetKit:Create("Group") ---@cast group -nil
    local rendering = WidgetKit:RenderOptions(define({ flag = toggle() }), group)
    local widget = rendering:GetWidget("flag")
    assert.are.equal("Label", widget:GetType())
    assert.are.equal("on", widget:GetText())
    store.flag = false
    rendering:Refresh()
    assert.are.equal("off", widget:GetText())
    assert.are.same({ true, false }, applied)
    WidgetKit:Release(group)
  end)

  it("calls decorators in registration order, and reports one that raises", function()
    local calls = {}
    renderer.registerExtension("decorators", "first", {
      revision = 1,
      decorate = function(_, record)
        calls[#calls + 1] = "first " .. record.path
      end,
      refresh = function(_, record)
        calls[#calls + 1] = "refresh " .. record.path
      end,
    })
    renderer.registerExtension("decorators", "broken", {
      revision = 1,
      decorate = function()
        error("decorator failed")
      end,
    })
    local reported = {}
    TestEnv.SetGlobal("geterrorhandler", function()
      return function(failure)
        reported[#reported + 1] = failure
      end
    end)
    local group = WidgetKit:Create("Group") ---@cast group -nil
    WidgetKit:RenderOptions(define({ flag = toggle() }), group)
    assert.are.same({ "first flag", "refresh flag" }, calls)
    assert.are.equal(1, #reported)
    assert.is_truthy(tostring(reported[1]):find("decorator failed", 1, true))
    WidgetKit:Release(group)
  end)

  it("keeps the higher revision of an entry", function()
    local low = { revision = 1, render = function() end }
    local high = { revision = 2, render = function() end }
    assert.is_true(renderer.registerExtension("pageStyles", "spec", high))
    assert.is_false(renderer.registerExtension("pageStyles", "spec", low))
    assert.are.equal(high, renderer.extensions.pageStyles.spec)
    assert.is_true(
      renderer.registerExtension("confirm", nil, { revision = 3, ask = function() end })
    )
    assert.is_false(
      renderer.registerExtension("confirm", nil, { revision = 2, ask = function() end })
    )
  end)

  it("renders a group's children with a registered page style", function()
    local seen = nil
    renderer.registerExtension("pageStyles", "spec", {
      revision = 1,
      render = function(_, node, parent)
        seen = node
        parent:AddChild(WidgetKit:Create("Label"))
        return true
      end,
    })
    local group = WidgetKit:Create("Group") ---@cast group -nil
    WidgetKit:RenderOptions(define({ flag = toggle() }, "tab"), group)
    assert.is_nil(seen)
    WidgetKit:Release(group)
    -- OptionsKit accepts only Ace3's `childGroups` names, so the spec stands
    -- in for a widget-set part that registers one of them.
    renderer.registerExtension("pageStyles", "tab", {
      revision = 1,
      render = function(_, node, parent)
        seen = node
        parent:AddChild(WidgetKit:Create("Label"))
        return true
      end,
    })
    group = WidgetKit:Create("Group") ---@cast group -nil
    WidgetKit:RenderOptions(define({ flag = toggle() }, "tab"), group)
    assert.is_not_nil(seen)
    assert.are.equal(1, group:GetNumChildren())
    WidgetKit:Release(group)
  end)

  it("asks a registered confirm provider before running an execute option", function()
    local asked = {}
    local proceed = nil
    renderer.registerExtension("confirm", nil, {
      revision = 1,
      ask = function(_, record, question, onYes)
        asked[#asked + 1] = record.path .. ": " .. question
        proceed = onYes
      end,
    })
    local group = WidgetKit:Create("Group") ---@cast group -nil
    local rendering = WidgetKit:RenderOptions(
      define({
        run = {
          type = "execute",
          name = "Run",
          confirm = "Really?",
          func = function()
            store.ran = store.ran + 1
          end,
        },
      }),
      group
    )
    rendering:GetWidget("run"):Fire("OnClick")
    assert.are.same({ "run: Really?" }, asked)
    assert.are.equal(0, store.ran)
    assert.is_nil(rendering:GetMessage("run"))
    proceed()
    assert.are.equal(1, store.ran)
    WidgetKit:Release(group)
  end)
end)
