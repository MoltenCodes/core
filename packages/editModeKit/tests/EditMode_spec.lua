local TestEnv = require("EditModeKitTestEnv")

describe("EditModeKit in Edit Mode", function()
  local EditModeKit
  before_each(function()
    EditModeKit = TestEnv.NewPackage()
    TestEnv.InstallHostErrorHandler()
  end)
  after_each(TestEnv.Reset)

  local function overlayOf(registration)
    return rawget(registration, "_record").overlay
  end

  ---Drag `registration`'s frame so its centre lands at (`x`, `y`).
  local function drag(registration, x, y)
    local overlay = overlayOf(registration)
    local frame = registration:GetFrame()
    TestEnv.Run(overlay, "OnDragStart")
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", TestEnv.GetGlobal("UIParent"), "BOTTOMLEFT", x, y)
    TestEnv.Run(overlay, "OnDragStop")
  end

  it("lays a labelled overlay over the frame, shown only while Edit Mode is open", function()
    local frame = TestEnv.FrameAt(300, 300)
    frame:SetFrameLevel(2)
    local registration = EditModeKit:Register(frame, {}, { label = "My Bars" })
    local overlay = overlayOf(registration)
    assert.are.equal(frame, overlay:GetParent())
    assert.are.equal(22, overlay:GetFrameLevel())
    assert.are.equal("My Bars", overlay.text:GetText())
    assert.is_false(overlay:IsShown())
    TestEnv.EnterEditMode()
    assert.is_true(EditModeKit:IsEditing())
    assert.is_true(overlay:IsShown())
    TestEnv.ExitEditMode()
    assert.is_false(overlay:IsShown())
    assert.is_false(EditModeKit:IsEditing())
    assert.are.equal("EditModeKit.Registration", getmetatable(registration))
  end)

  it("names the overlay after the frame, or Frame", function()
    local named =
      TestEnv.GetGlobal("CreateFrame")("Frame", "MyAddonBars", TestEnv.GetGlobal("UIParent"))
    named:SetSize(10, 10)
    assert.are.equal("MyAddonBars", overlayOf(EditModeKit:Register(named, {})).text:GetText())
    assert.are.equal(
      "Frame",
      overlayOf(EditModeKit:Register(TestEnv.FrameAt(1, 1), {})).text:GetText()
    )
  end)

  it("shows the overlay of a frame registered while Edit Mode is open", function()
    TestEnv.EnterEditMode()
    local registration = EditModeKit:Register(TestEnv.FrameAt(300, 300), {})
    assert.is_true(overlayOf(registration):IsShown())
  end)

  it("drags the frame and saves its centre offset under the active layout", function()
    local storage = {}
    local frame = TestEnv.FrameAt(300, 300)
    local registration = EditModeKit:Register(frame, storage)
    TestEnv.EnterEditMode()
    TestEnv.Run(overlayOf(registration), "OnDragStart")
    assert.is_true(frame.moving)
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", TestEnv.GetGlobal("UIParent"), "BOTTOMLEFT", 1060, 640)
    TestEnv.Run(overlayOf(registration), "OnDragStop")
    assert.is_nil(frame.moving)
    assert.are.same({ Modern = { x = 100, y = 100 } }, storage)
    assert.are.same(
      { "CENTER", TestEnv.GetGlobal("UIParent"), "CENTER", 100, 100 },
      { frame:GetPoint(1) }
    )
    assert.are.equal("Modern", EditModeKit:GetLayoutName())
  end)

  it("puts each layout's position back when the player switches layout", function()
    local storage = {}
    local frame = TestEnv.FrameAt(300, 300)
    local registration = EditModeKit:Register(frame, storage)
    drag(registration, 1060, 640)
    TestEnv.SwitchLayout("Raid")
    -- No position for Raid yet: the frame stays where it is.
    assert.are.same(
      { "CENTER", TestEnv.GetGlobal("UIParent"), "CENTER", 100, 100 },
      { frame:GetPoint(1) }
    )
    drag(registration, 860, 440)
    assert.are.same({ x = -100, y = -100 }, storage.Raid)
    TestEnv.SwitchLayout("Modern")
    assert.are.same(
      { "CENTER", TestEnv.GetGlobal("UIParent"), "CENTER", 100, 100 },
      { frame:GetPoint(1) }
    )
  end)

  it("puts the saved position back at Register and on Refresh, in the frame's scale", function()
    local storage = { Modern = { x = 50, y = -20 } }
    local frame = TestEnv.FrameAt(300, 300)
    local registration = EditModeKit:Register(frame, storage)
    assert.are.same(
      { "CENTER", TestEnv.GetGlobal("UIParent"), "CENTER", 50, -20 },
      { frame:GetPoint(1) }
    )
    storage.Modern = { x = 80, y = 40 }
    frame:SetScale(2)
    registration:Refresh()
    assert.are.same(
      { "CENTER", TestEnv.GetGlobal("UIParent"), "CENTER", 40, 20 },
      { frame:GetPoint(1) }
    )
  end)

  it("reads and writes through a storage function, and reports one that fails", function()
    local profiles = { first = {}, second = {} }
    local current = "first"
    local frame = TestEnv.FrameAt(300, 300)
    local registration = EditModeKit:Register(frame, function()
      return profiles[current]
    end)
    drag(registration, 1060, 640)
    current = "second"
    drag(registration, 960, 540)
    assert.are.same({ Modern = { x = 100, y = 100 } }, profiles.first)
    assert.are.same({ Modern = { x = 0, y = 0 } }, profiles.second)
    local broken = EditModeKit:Register(TestEnv.FrameAt(5, 5), function()
      error("storage failed", 0)
    end)
    broken:Refresh()
    local odd = EditModeKit:Register(TestEnv.FrameAt(6, 6), function()
      return "storage"
    end, { label = "Odd" })
    odd:Refresh()
    assert.are.same({
      "storage failed",
      "storage failed",
      "EditModeKit storage for Odd must return a table",
      "EditModeKit storage for Odd must return a table",
    }, TestEnv.TakeReportedValues())
  end)

  it("keeps a protected frame where it is in combat and moves it when combat ends", function()
    local storage = { Modern = { x = 10, y = 10 } }
    local frame = TestEnv.FrameAt(300, 300)
    frame.IsProtected = function()
      return true
    end
    TestEnv.SetCombat()
    local registration = EditModeKit:Register(frame, storage)
    assert.are.same(
      { "CENTER", TestEnv.GetGlobal("UIParent"), "BOTTOMLEFT", 300, 300 },
      { frame:GetPoint(1) }
    )
    TestEnv.Run(overlayOf(registration), "OnDragStart")
    assert.is_nil(frame.moving)
    TestEnv.EndCombat()
    assert.are.same(
      { "CENTER", TestEnv.GetGlobal("UIParent"), "CENTER", 10, 10 },
      { frame:GetPoint(1) }
    )
  end)

  it("unregisters once, hides the overlay and reuses it for the next frame", function()
    local frame = TestEnv.FrameAt(300, 300)
    local registration = EditModeKit:Register(frame, {})
    local overlay = overlayOf(registration)
    TestEnv.EnterEditMode()
    assert.is_true(registration:Unregister())
    assert.is_false(registration:Unregister())
    assert.is_false(overlay:IsShown())
    TestEnv.ExitEditMode()
    TestEnv.EnterEditMode()
    assert.is_false(overlay:IsShown())
    local again = EditModeKit:Register(frame, {})
    assert.are.equal(overlay, overlayOf(again))
    registration:Refresh()
    assert.are.equal(1, TestEnv.GetGlobal("EventRegistry"):CallbackCount("EditMode.Enter"))
  end)

  it("names the layout default without the client's Edit Mode manager", function()
    TestEnv.SetGlobal("EditModeManagerFrame", nil)
    local storage = {}
    local registration = EditModeKit:Register(TestEnv.FrameAt(300, 300), storage)
    drag(registration, 960, 540)
    assert.are.same({ default = { x = 0, y = 0 } }, storage)
    assert.are.equal("default", EditModeKit:GetLayoutName())
  end)

  it("holds at most maxRegistrations frames", function()
    assert.are.same({ maxRegistrations = 64 }, EditModeKit:GetLimits())
    EditModeKit:SetLimits({ maxRegistrations = 1 })
    EditModeKit:Register(TestEnv.FrameAt(1, 1), {})
    TestEnv.expectErrorContaining(
      "EditModeKit:Register holds at most 1 frames; raise maxRegistrations with EditModeKit:SetLimits",
      function()
        EditModeKit:Register(TestEnv.FrameAt(2, 2), {})
      end
    )
    EditModeKit:SetLimits({ maxRegistrations = 256 })
    EditModeKit:Register(TestEnv.FrameAt(2, 2), {})
  end)
end)
