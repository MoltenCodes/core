local TestEnv = require("WidgetKitTestEnv")

---A Group laid out at a known width: anchored at the screen's top-left,
---`width` wide, so its content is `width - 16` wide.
local function groupAt(WidgetKit, width, layout)
  local group = WidgetKit:Create("Group")
  group:SetWidth(width)
  group:SetPoint("TOPLEFT", TestEnv.GetGlobal("UIParent"), "TOPLEFT", 0, 0)
  group:SetLayout(layout)
  return group
end

---A Spacer of a fixed size.
local function box(WidgetKit, width, height)
  local spacer = WidgetKit:Create("Spacer")
  spacer:SetWidth(width)
  spacer:SetHeight(height)
  return spacer
end

---The first anchor of a widget as `{ point, relativeTo, relativePoint, x, y }`.
local function anchorOf(widget, index)
  return { widget.frame:GetPoint(index or 1) }
end

describe("WidgetKit layouts", function()
  local WidgetKit
  before_each(function()
    WidgetKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("List stacks children vertically from the top of the content", function()
    local group = groupAt(WidgetKit, 216, "List")
    local content = group:GetContent()
    local first = box(WidgetKit, 50, 20)
    local second = box(WidgetKit, 60, 30)
    local third = box(WidgetKit, 70, 10)
    third:SetFullWidth(true)
    local log = TestEnv.RecordAnchorCalls()
    group:AddChildren(first, second, third)

    assert.are.same({ "TOPLEFT", content, "TOPLEFT", 0, 0 }, anchorOf(first))
    assert.are.same({ "TOPLEFT", content, "TOPLEFT", 0, -20 }, anchorOf(second))
    assert.are.same({ "TOPLEFT", content, "TOPLEFT", 0, -50 }, anchorOf(third))
    assert.are.same({ "TOPRIGHT", content, "TOPRIGHT", 0, -50 }, anchorOf(third, 2))
    assert.are.equal(200, third:GetWidth())
    assert.are.equal(50, first:GetWidth())

    -- The group grew to its content: 60 of children plus the insets.
    assert.are.equal(60 + 16, group:GetHeight())
    -- One pass for the three children, plus the group's own anchor rows.
    local childAnchors = 0
    for _, row in ipairs(log) do
      if row.relativeTo == content then
        childAnchors = childAnchors + 1
      end
    end
    assert.are.equal(4, childAnchors)
  end)

  it("List gives relative-width children a fraction of the content", function()
    local group = groupAt(WidgetKit, 216, "List")
    local half = box(WidgetKit, 10, 10)
    half:SetRelativeWidth(0.5)
    group:AddChild(half)
    assert.are.equal(100, half:GetWidth())
  end)

  it("Fill makes the first shown child fill the content", function()
    local window = WidgetKit:Create("Frame")
    window:SetLayout("Fill")
    local content = window:GetContent()
    local hidden = box(WidgetKit, 5, 5)
    local filler = box(WidgetKit, 5, 5)
    window:AddChild(hidden)
    hidden:Hide()
    window:AddChild(filler)
    window:PerformLayout()

    assert.are.same({ "TOPLEFT", content, "TOPLEFT", 0, 0 }, anchorOf(filler))
    assert.are.same({ "BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0 }, anchorOf(filler, 2))
    assert.are.equal(content:GetWidth(), filler:GetWidth())
    assert.are.equal(content:GetHeight(), filler:GetHeight())
    assert.are.equal(700 - 24, filler:GetWidth())
  end)

  it("Flow places children in rows and wraps at the content width", function()
    local group = groupAt(WidgetKit, 116, "Flow")
    local content = group:GetContent()
    local a = box(WidgetKit, 40, 10)
    local b = box(WidgetKit, 40, 20)
    local c = box(WidgetKit, 40, 15)
    local d = box(WidgetKit, 10, 5)
    d:SetFullWidth(true)
    local e = box(WidgetKit, 30, 5)
    group:AddChildren(a, b, c, d, e)

    -- Content is 100 wide: a and b share row one, c wraps, d takes a row
    -- of its own, e starts the next.
    assert.are.same({ "TOPLEFT", content, "TOPLEFT", 0, 0 }, anchorOf(a))
    assert.are.same({ "TOPLEFT", content, "TOPLEFT", 40, 0 }, anchorOf(b))
    assert.are.same({ "TOPLEFT", content, "TOPLEFT", 0, -20 }, anchorOf(c))
    assert.are.same({ "TOPLEFT", content, "TOPLEFT", 0, -35 }, anchorOf(d))
    assert.are.same({ "TOPRIGHT", content, "TOPRIGHT", 0, -35 }, anchorOf(d, 2))
    assert.are.same({ "TOPLEFT", content, "TOPLEFT", 0, -40 }, anchorOf(e))
    assert.are.equal(45 + 16, group:GetHeight())
  end)

  it("Flow gives a full-height child the height left below its row", function()
    local window = WidgetKit:Create("Frame")
    window:SetLayout("Flow")
    local top = box(WidgetKit, 700, 40)
    local rest = box(WidgetKit, 50, 5)
    rest:SetFullHeight(true)
    window:AddChildren(top, rest)
    assert.are.equal(window:GetContent():GetHeight() - 40, rest:GetHeight())
  end)

  it("lays nested containers out top-down and reports heights upward", function()
    local window = WidgetKit:Create("Frame")
    local outer = WidgetKit:Create("Group")
    outer:SetFullWidth(true)
    local inner = WidgetKit:Create("Group")
    inner:SetFullWidth(true)
    window:AddChild(outer)
    outer:AddChild(inner)
    assert.are.equal(16, inner:GetHeight())
    assert.are.equal(32, outer:GetHeight())

    -- Adding to the inner group grows it, and the report travels up.
    inner:AddChild(box(WidgetKit, 10, 50))
    assert.are.equal(66, inner:GetHeight())
    assert.are.equal(82, outer:GetHeight())
  end)

  it("never lays out on a size change; a paused container waits for PerformLayout", function()
    local group = groupAt(WidgetKit, 216, "List")
    group:PauseLayout()
    assert.is_true(group:IsLayoutPaused())
    local child = box(WidgetKit, 10, 10)
    group:AddChild(child)
    assert.are.equal(0, child.frame:GetNumPoints())
    local done, reason = group:PerformLayout()
    assert.is_false(done)
    assert.are.equal("paused", reason)

    group:ResumeLayout()
    assert.are.equal(0, child.frame:GetNumPoints())
    assert.is_true(group:PerformLayout())
    assert.are.equal(1, child.frame:GetNumPoints())
    assert.are.equal(group.frame:GetScript("OnSizeChanged"), nil)
  end)

  it("refuses a layout pass inside a pass of the same container", function()
    local results = {}
    local group = groupAt(WidgetKit, 216, function(_, _, container)
      results[#results + 1] = { container:PerformLayout() }
      return 100, 10
    end)
    assert.is_true(group:PerformLayout())
    assert.are.same({ false, "recursion" }, results[1])
    assert.are.equal(1, #results)
  end)

  it("refuses a layout pass nested 32 deep with depth", function()
    local groups = {}
    local results = {}
    for index = 1, 34 do
      groups[index] = WidgetKit:Create("Group")
    end
    for index = 1, 33 do
      groups[index]:SetLayout(function()
        results[index] = { groups[index + 1]:PerformLayout() }
        return 0, 0
      end)
    end
    assert.is_true(groups[1]:PerformLayout())
    assert.are.same({ false, "depth" }, results[32])
    assert.are.same({ true }, results[31])
    assert.is_nil(results[33])
  end)

  it("re-raises a layout error and leaves the container usable", function()
    local fail = true
    local group = groupAt(WidgetKit, 216, function()
      if fail then
        error("layout bug", 0)
      end
      return 0, 0
    end)
    local ok, failure = pcall(group.PerformLayout, group)
    assert.is_false(ok)
    assert.are.equal("layout bug", failure)
    fail = false
    assert.is_true(group:PerformLayout())
  end)

  it("inserts before a given child and moves a child between containers", function()
    local first = groupAt(WidgetKit, 216, "List")
    local second = groupAt(WidgetKit, 216, "List")
    local a, b, c = box(WidgetKit, 1, 1), box(WidgetKit, 1, 1), box(WidgetKit, 1, 1)
    first:AddChild(a)
    first:AddChild(c)
    first:AddChild(b, c)
    assert.are.same({ a, b, c }, first:GetChildren())

    second:AddChild(b)
    assert.are.same({ a, c }, first:GetChildren())
    assert.are.same({ b }, second:GetChildren())
    assert.are.equal(second, b:GetParentContainer())

    TestEnv.expectErrorContaining("beforeWidget must be a child", function()
      first:AddChild(box(WidgetKit, 1, 1), b)
    end)
    TestEnv.expectErrorContaining("must not be the container or a container above it", function()
      second:AddChild(second)
    end)
    local outer = groupAt(WidgetKit, 216, "List")
    outer:AddChild(first)
    TestEnv.expectErrorContaining("must not be the container or a container above it", function()
      first:AddChild(outer)
    end)
  end)

  it("holds at most 256 children per container", function()
    WidgetKit:RegisterType("Tiny", function()
      return { frame = TestEnv.GetGlobal("CreateFrame")("Frame") }
    end, 1, { maxCreated = 300 })
    local group = groupAt(WidgetKit, 216, "List")
    group:PauseLayout()
    for _ = 1, WidgetKit.MAX_CHILDREN do
      assert.is_true(group:AddChild(WidgetKit:Create("Tiny")))
    end
    local added, reason = group:AddChild(WidgetKit:Create("Tiny"))
    assert.is_nil(added)
    assert.are.equal("full", reason)
    local count, full = group:AddChildren(WidgetKit:Create("Tiny"))
    assert.are.equal(0, count)
    assert.are.equal("full", full)
    assert.are.equal(256, group:GetNumChildren())
  end)

  it("releases children without laying out, and keeps the container", function()
    local group = groupAt(WidgetKit, 216, "List")
    group:AddChildren(box(WidgetKit, 1, 10), box(WidgetKit, 1, 10))
    assert.are.equal(2, group:ReleaseChildren())
    assert.are.equal(0, group:GetNumChildren())
    assert.is_true(WidgetKit:IsWidget(group))
  end)

  it("registers custom layouts once and resolves layouts by name", function()
    local calls = 0
    local function columns(content, children, _, scratch)
      calls = calls + 1
      assert.are.same({}, scratch)
      scratch.used = true
      for index, child in ipairs(children) do
        child.frame:ClearAllPoints()
        child.frame:SetPoint("TOPLEFT", content, "TOPLEFT", (index - 1) * 10, 0)
      end
      return content:GetWidth(), 10
    end
    assert.is_true(WidgetKit:RegisterLayout("Columns", columns))
    local registered, reason = WidgetKit:RegisterLayout("Columns", columns)
    assert.is_false(registered)
    assert.are.equal("taken", reason)
    assert.is_false((WidgetKit:RegisterLayout("List", columns)))
    assert.are.equal(columns, WidgetKit:GetLayout("Columns"))

    local group = groupAt(WidgetKit, 216, "Columns")
    assert.are.equal("Columns", group:GetLayoutName())
    local second = box(WidgetKit, 5, 5)
    group:AddChildren(box(WidgetKit, 5, 5), second)
    assert.are.equal(1, calls)
    assert.are.equal(10, select(4, second.frame:GetPoint(1)))
    assert.are.equal(26, group:GetHeight())

    TestEnv.expectErrorContaining('layout "Nope" is not registered', function()
      group:SetLayout("Nope")
    end)
  end)

  it("Flow keeps children that exactly fill a row on that row", function()
    -- Ten tenths of a 107-wide content sum to a hair above 107 in floating
    -- point; the row must not wrap for it.
    local group = groupAt(WidgetKit, 123, "Flow")
    local content = group:GetContent()
    local children = {}
    for index = 1, 10 do
      children[index] = box(WidgetKit, 5, 10)
      children[index]:SetRelativeWidth(0.1)
    end
    group:AddChildren(unpack(children))
    local point, relativeTo, relativePoint, _, y = children[10].frame:GetPoint(1)
    assert.are.same({ "TOPLEFT", content, "TOPLEFT", 0 }, { point, relativeTo, relativePoint, y })
    assert.are.equal(10 + 16, group:GetHeight())
  end)

  it("never sizes a child below zero when insets leave the content no width", function()
    -- A Group 10 wide has a content 6 pixels narrower than nothing.
    for _, layout in ipairs({ "List", "Flow" }) do
      local group = groupAt(WidgetKit, 10, layout)
      assert.is_true(group:GetContent():GetWidth() < 0)
      local child = box(WidgetKit, 5, 5)
      child:SetRelativeWidth(0.5)
      group:AddChild(child)
      assert.are.equal(0, child:GetWidth())
      WidgetKit:Release(group)
    end
  end)

  it("refuses a layout its own OnLayoutStart hook asks for", function()
    local results = {}
    WidgetKit:RegisterType("SpecHookedContainer", function()
      local createFrame = TestEnv.GetGlobal("CreateFrame")
      local frame = createFrame("Frame")
      return {
        frame = frame,
        content = createFrame("Frame", frame),
        OnLayoutStart = function(self)
          results[#results + 1] = { self:PerformLayout() }
        end,
      }
    end, 1)
    local container = WidgetKit:Create("SpecHookedContainer")
    assert.is_true(container:PerformLayout())
    assert.are.same({ { false, "recursion" } }, results)
  end)
end)
