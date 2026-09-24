local TestEnv = require("WidgetKitTestEnv")

-- `GetWidth`, `GetHeight` and `GetSize` carry `SecretWhenAnchoringSecret` in
-- the client's documentation: a frame anchored to a secret answers its size as
-- a secret, and arithmetic or a comparison on it raises inside the code that
-- does it. Plain Lua never raises there, so these specs mark plain numbers as
-- secret through the `issecretvalue` stub and override one frame's size
-- methods to return them. An outcome that differs from what the number's plain
-- meaning would give shows the Kit asked the probe before computing with it,
-- following the rule in `docs/API.md` ("Secret sizes").

-- Numbers no other size in these specs takes, so the probe reports only these.
local SECRET_WIDTH = 123.25
local SECRET_HEIGHT = 77.75

---A Spacer of a fixed size.
local function box(WidgetKit, width, height)
  local spacer = WidgetKit:Create("Spacer")
  spacer:SetWidth(width)
  spacer:SetHeight(height)
  return spacer
end

---A Group at the screen's top-left, `width` wide, laid out with `layout`.
local function groupAt(WidgetKit, width, layout)
  local group = WidgetKit:Create("Group")
  group:SetWidth(width)
  group:SetPoint("TOPLEFT", TestEnv.GetGlobal("UIParent"), "TOPLEFT", 0, 0)
  group:SetLayout(layout)
  return group
end

---Make `frame` answer `GetWidth` with the secret width.
local function secretWidth(frame)
  function frame.GetWidth()
    return SECRET_WIDTH
  end
end

---Make `frame` answer `GetHeight` with the secret height.
local function secretHeight(frame)
  function frame.GetHeight()
    return SECRET_HEIGHT
  end
end

---The first anchor of a widget as `{ point, relativeTo, relativePoint, x, y }`.
local function anchorOf(widget, index)
  return { widget.frame:GetPoint(index or 1) }
end

describe("WidgetKit and secret sizes", function()
  local WidgetKit
  before_each(function()
    WidgetKit = TestEnv.NewPackage()
    TestEnv.SetGlobal("issecretvalue", function(value)
      return value == SECRET_WIDTH or value == SECRET_HEIGHT
    end)
  end)
  after_each(TestEnv.Reset)

  it("List sizes no relative-width child from a secret content width", function()
    local group = groupAt(WidgetKit, 216, "List")
    group:PauseLayout()
    local half = box(WidgetKit, 10, 10)
    half:SetRelativeWidth(0.5)
    local full = box(WidgetKit, 10, 10)
    full:SetFullWidth(true)
    group:AddChildren(half, full)
    local content = group:GetContent()
    secretWidth(content)
    group:ResumeLayout()
    assert.is_true(group:PerformLayout())

    -- Without the probe it would be 61.625 wide.
    assert.are.equal(10, half:GetWidth())
    assert.are.same({ "TOPRIGHT", content, "TOPRIGHT", 0, -10 }, anchorOf(full, 2))
  end)

  it("List counts a secret child height as 0", function()
    local group = groupAt(WidgetKit, 216, "List")
    local first = box(WidgetKit, 10, 10)
    local second = box(WidgetKit, 10, 10)
    secretHeight(first.frame)
    group:AddChildren(first, second)
    assert.are.same({ "TOPLEFT", group:GetContent(), "TOPLEFT", 0, 0 }, anchorOf(second))
  end)

  it("Fill anchors its child and reports no size when the content size is secret", function()
    local window = WidgetKit:Create("Frame")
    window:SetLayout("Fill")
    local content = window:GetContent()
    secretWidth(content)
    secretHeight(content)
    local filler = box(WidgetKit, 5, 5)
    window:AddChild(filler)
    assert.is_true(window:PerformLayout())
    assert.are.same({ "TOPLEFT", content, "TOPLEFT", 0, 0 }, anchorOf(filler))
    assert.are.same({ "BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0 }, anchorOf(filler, 2))
  end)

  it("Flow wraps every child after the first when the content width is secret", function()
    local group = groupAt(WidgetKit, 216, "Flow")
    group:PauseLayout()
    local a = box(WidgetKit, 40, 10)
    local b = box(WidgetKit, 40, 20)
    local c = box(WidgetKit, 10, 5)
    c:SetRelativeWidth(0.5)
    group:AddChildren(a, b, c)
    local content = group:GetContent()
    secretWidth(content)
    group:ResumeLayout()
    assert.is_true(group:PerformLayout())

    assert.are.same({ "TOPLEFT", content, "TOPLEFT", 0, 0 }, anchorOf(a))
    assert.are.same({ "TOPLEFT", content, "TOPLEFT", 0, -10 }, anchorOf(b))
    assert.are.same({ "TOPLEFT", content, "TOPLEFT", 0, -30 }, anchorOf(c))
    assert.are.equal(10, c:GetWidth())
  end)

  it("Flow counts a secret child width or height as 0", function()
    local group = groupAt(WidgetKit, 116, "Flow")
    local a = box(WidgetKit, 40, 10)
    local b = box(WidgetKit, 40, 20)
    local c = box(WidgetKit, 40, 15)
    secretWidth(a.frame)
    secretHeight(b.frame)
    group:AddChildren(a, b, c)
    local content = group:GetContent()
    -- `a` adds no width, so `b` starts at 0; `b` adds no height to its row.
    assert.are.same({ "TOPLEFT", content, "TOPLEFT", 0, 0 }, anchorOf(b))
    assert.are.same({ "TOPLEFT", content, "TOPLEFT", 40, 0 }, anchorOf(c))
    assert.are.equal(15 + 16, group:GetHeight())
  end)

  it("Flow sizes no full-height child from a secret content height", function()
    local window = WidgetKit:Create("Frame")
    window:SetLayout("Flow")
    secretHeight(window:GetContent())
    local rest = box(WidgetKit, 50, 5)
    rest:SetFullHeight(true)
    window:AddChild(rest)
    assert.is_true(window:PerformLayout())
    assert.are.equal(5, rest:GetHeight())
  end)

  it("does not lay out the parent again when a nested height is secret", function()
    local outer = groupAt(WidgetKit, 216, "List")
    local inner = WidgetKit:Create("Group")
    inner:SetFullWidth(true)
    outer:AddChild(inner)
    local passes = 0
    local list = WidgetKit:GetLayout("List")
    outer:SetLayout(function(...)
      passes = passes + 1
      return list(...)
    end)
    assert.is_true(outer:PerformLayout())
    passes = 0

    -- Two different secret heights: compared, they would read as a change.
    local answers = { SECRET_HEIGHT, SECRET_WIDTH }
    local calls = 0
    function inner.frame.GetHeight()
      calls = calls + 1
      return answers[math.min(calls, 2)]
    end
    assert.is_true(inner:PerformLayout())
    assert.are.equal(0, passes)
  end)

  it("ScrollFrame keeps its content width and counts a secret viewport height as 0", function()
    local scroll = WidgetKit:Create("ScrollFrame")
    scroll:SetPoint("TOPLEFT", TestEnv.GetGlobal("UIParent"), "TOPLEFT", 0, 0)
    local spacer = box(WidgetKit, 10, 100)
    scroll:AddChild(spacer)
    local contentWidth = scroll:GetContent():GetWidth()
    secretWidth(scroll.scroll)
    secretHeight(scroll.scroll)
    assert.is_true(scroll:PerformLayout())
    assert.are.equal(contentWidth, scroll:GetContent():GetWidth())
    assert.are.equal(100, scroll:GetScrollRange())
  end)
end)
