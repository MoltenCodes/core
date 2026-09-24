local TestEnv = require("WidgetKitTestEnv")

describe("WidgetKit position binding without SchedulerKit", function()
  local WidgetKit
  before_each(function()
    WidgetKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("saves the elected anchor at once when the window is dragged", function()
    local window = WidgetKit:Create("Frame")
    local storage = {}
    local moved = {}
    local binding = window:BindPosition(storage)
    binding:OnMoved(function(_, anchor)
      moved[#moved + 1] = anchor.point
    end)
    assert.is_nil(storage.anchor)

    TestEnv.RunScript(window.titleBar, "OnDragStart")
    assert.is_true(window.frame.moving)
    TestEnv.MoveFrame(window.frame, 20, 560)
    TestEnv.RunScript(window.titleBar, "OnDragStop")

    assert.are.same({
      point = "TOPLEFT",
      relativeTo = "UIParent",
      relativePoint = "TOPLEFT",
      x = 20,
      y = -20,
      scale = 1,
    }, storage.anchor)
    assert.are.same({ "TOPLEFT" }, moved)
    -- The frame itself is re-anchored at the elected point.
    local point, relativeTo, relativePoint, x, y = window.frame:GetPoint(1)
    assert.are.same({ "TOPLEFT", TestEnv.GetGlobal("UIParent"), "TOPLEFT", 20, -20 }, {
      point,
      relativeTo,
      relativePoint,
      x,
      y,
    })
    assert.are.equal(1, window.frame:GetNumPoints())
  end)

  it("restores a saved anchor when binding, unless asked not to", function()
    local storage = {
      place = { point = "BOTTOMRIGHT", relativePoint = "BOTTOMRIGHT", x = -5, y = 6 },
    }
    local window = WidgetKit:Create("Frame")
    window:BindPosition(storage, { key = "place" })
    local point, _, relativePoint, x, y = window.frame:GetPoint(1)
    assert.are.same({ "BOTTOMRIGHT", "BOTTOMRIGHT", -5, 6 }, { point, relativePoint, x, y })

    local other = WidgetKit:Create("Frame")
    other:BindPosition(storage, { key = "place", restore = false })
    assert.are.equal("CENTER", (other.frame:GetPoint(1)))
  end)

  it("elects the anchor in screen coordinates when the frame is scaled", function()
    local frame = TestEnv.GetGlobal("CreateFrame")("Frame", nil, TestEnv.GetGlobal("UIParent"))
    frame:SetSize(100, 100)
    frame:SetScale(2)
    frame:SetPoint("BOTTOMLEFT", 10, 10)
    local storage = {}
    local binding = WidgetKit:BindPosition(frame, storage)
    local anchor = binding:Capture()
    -- On screen the frame sits at (20, 20); the offset is stored in the
    -- frame's own units.
    assert.are.equal("BOTTOMLEFT", anchor.point)
    assert.are.equal(10, storage.anchor.x)
    assert.are.equal(10, storage.anchor.y)
    assert.are.equal(2, storage.anchor.scale)
  end)

  it("does nothing for a frame that is not positioned and after release", function()
    local frame = TestEnv.GetGlobal("CreateFrame")("Frame", nil, TestEnv.GetGlobal("UIParent"))
    local storage = {}
    local binding = WidgetKit:BindPosition(frame, storage)
    local anchor, reason = binding:Capture()
    assert.is_nil(anchor)
    assert.are.equal("notPositioned", reason)

    assert.is_true(binding:Release())
    assert.is_false(binding:Release())
    assert.is_true(binding:IsReleased())
    anchor, reason = binding:Capture()
    assert.is_nil(anchor)
    assert.are.equal("released", reason)
    assert.is_false(binding:Flush())
    assert.is_nil(storage.anchor)
  end)

  it("leaves a frame the current code may not touch alone", function()
    local frame = TestEnv.GetGlobal("CreateFrame")("Frame", nil, TestEnv.GetGlobal("UIParent"))
    frame:SetSize(10, 10)
    frame:SetPoint("CENTER")
    function frame.IsForbidden()
      return true
    end
    local storage = { anchor = { point = "TOPLEFT" } }
    local binding = WidgetKit:BindPosition(frame, storage)
    assert.are.equal("CENTER", (frame:GetPoint(1)))
    local anchor, reason = binding:Capture()
    assert.is_nil(anchor)
    assert.are.equal("forbidden", reason)
    assert.are.equal("TOPLEFT", storage.anchor.point)
  end)

  it("reports a saved anchor it cannot read and keeps the frame where it is", function()
    TestEnv.TakeReportedErrors()
    local frame = TestEnv.GetGlobal("CreateFrame")("Frame", nil, TestEnv.GetGlobal("UIParent"))
    frame:SetPoint("CENTER")
    local binding = WidgetKit:BindPosition(frame, { anchor = { point = "NOWHERE" } })
    assert.is_false(binding:Restore())
    assert.are.equal("CENTER", (frame:GetPoint(1)))
    assert.are.equal(2, #TestEnv.TakeReportedErrors())
  end)

  it("releases the window's binding with the window", function()
    local window = WidgetKit:Create("Frame")
    local binding = window:BindPosition({})
    assert.are.equal(binding, window:GetBinding())
    WidgetKit:Release(window)
    assert.is_true(binding:IsReleased())
  end)

  it("gives the next use of a window the default scale a restored anchor changed", function()
    local window = WidgetKit:Create("Frame")
    window:BindPosition({ anchor = { point = "CENTER", x = 0, y = 0, scale = 0.75 } })
    assert.are.equal(0.75, window.frame:GetScale())
    WidgetKit:Release(window)

    local again = WidgetKit:Create("Frame")
    assert.are.equal(window, again)
    assert.are.equal(1, again.frame:GetScale())
    assert.is_nil(again:GetBinding())
  end)
end)
