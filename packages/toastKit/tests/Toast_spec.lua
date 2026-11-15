local TestEnv = require("ToastKitTestEnv")

describe("ToastKit toasts", function()
  local ToastKit
  before_each(function()
    ToastKit = TestEnv.NewPackage()
    TestEnv.InstallHostErrorHandler()
  end)
  after_each(TestEnv.Reset)

  local function frameOf(toast)
    return rawget(toast, "_record").frame
  end

  it("shows a title, a text and an icon at the anchor", function()
    local toast =
      ToastKit:Show({ title = "Profile copied", text = "Raid → Default", icon = 134400 })
    local frame = frameOf(toast)
    assert.is_true(toast:IsShown())
    assert.is_false(toast:IsQueued())
    assert.is_true(frame:IsShown())
    assert.are.equal("HIGH", frame:GetFrameStrata())
    assert.are.equal("Profile copied", frame.title:GetText())
    assert.are.equal("Raid → Default", frame.text:GetText())
    assert.are.equal(134400, frame.icon:GetTexture())
    assert.are.same({ "TOP", TestEnv.GetGlobal("UIParent"), "TOP", 0, -120 }, { frame:GetPoint(1) })
    assert.are.equal("ToastKit.Toast", getmetatable(toast))
  end)

  it("shows a title alone, centred, and numbers as text", function()
    local frame = frameOf(ToastKit:Show({ title = 42 }))
    assert.are.equal("42", frame.title:GetText())
    assert.is_nil(frame.text:GetText())
    assert.is_false(frame.icon:IsShown())
    assert.are.equal("LEFT", (frame.title:GetPoint(1)))
  end)

  it("stacks toasts down from the anchor, or up, and closes the gap when one ends", function()
    local first = ToastKit:Show({ title = "one" })
    local second = ToastKit:Show({ title = "two" })
    assert.are.equal(-120 - 54, select(5, frameOf(second):GetPoint(1)))
    first:Dismiss()
    assert.are.equal(-120, select(5, frameOf(second):GetPoint(1)))
    ToastKit:SetAnchor("BOTTOMRIGHT", -20, 40, "UP")
    local third = ToastKit:Show({ title = "three" })
    assert.are.same(
      { "BOTTOMRIGHT", TestEnv.GetGlobal("UIParent"), "BOTTOMRIGHT", -20, 40 },
      { frameOf(second):GetPoint(1) }
    )
    assert.are.equal(40 + 54, select(5, frameOf(third):GetPoint(1)))
  end)

  it("lives its duration, fades in its last half second and ends", function()
    local toast = ToastKit:Show({ title = "x", duration = 2 })
    local frame = frameOf(toast)
    TestEnv.SetMouseOver(frame, false)
    TestEnv.Run(frame, "OnUpdate", 1.25)
    assert.are.equal(1, frame:GetAlpha())
    TestEnv.Run(frame, "OnUpdate", 0.5)
    assert.are.equal(0.5, frame:GetAlpha())
    TestEnv.Run(frame, "OnUpdate", 0.25)
    assert.is_false(toast:IsShown())
    assert.is_false(frame:IsShown())
    assert.are.equal(1, frame:GetAlpha())
  end)

  it("holds while the cursor rests on it", function()
    local toast = ToastKit:Show({ title = "x", duration = 1 })
    local frame = frameOf(toast)
    TestEnv.SetMouseOver(frame, true)
    TestEnv.Run(frame, "OnUpdate", 10)
    assert.is_true(toast:IsShown())
    TestEnv.SetMouseOver(frame, false)
    TestEnv.Run(frame, "OnUpdate", 1)
    assert.is_false(toast:IsShown())
  end)

  it("runs onClick with its data on a click and ends, reporting one that raises", function()
    local seen = nil
    local toast = ToastKit:Show({
      title = "x",
      data = "payload",
      onClick = function(data)
        seen = data
      end,
    })
    TestEnv.Run(frameOf(toast), "OnMouseUp", "LeftButton")
    assert.are.equal("payload", seen)
    assert.is_false(toast:IsShown())
    local broken = ToastKit:Show({
      title = "y",
      onClick = function()
        error("click failed", 0)
      end,
    })
    TestEnv.Run(frameOf(broken), "OnMouseUp", "LeftButton")
    assert.are.same({ "click failed" }, TestEnv.TakeReportedValues())
  end)

  it("queues past maxVisible and shows the waiting ones as places free", function()
    ToastKit:SetLimits({ maxVisible = 2 })
    local toasts = {}
    for index = 1, 4 do
      toasts[index] = ToastKit:Show({ title = "t" .. index })
    end
    assert.is_true(toasts[3]:IsQueued())
    toasts[1]:Dismiss()
    assert.is_true(toasts[3]:IsShown())
    assert.is_true(toasts[4]:Dismiss())
    assert.is_false(toasts[4]:Dismiss())
    ToastKit:SetLimits({ maxVisible = 5 })
    assert.are.equal(2, ToastKit:DismissAll())
    assert.are.equal(0, ToastKit:DismissAll())
  end)

  it(
    "updates and restarts the toast under the same key, clearing what the new options leave out",
    function()
      local toast =
        ToastKit:Show({ key = "MyAddonSync", title = "Syncing", text = "1 of 3", duration = 2 })
      local frame = frameOf(toast)
      TestEnv.SetMouseOver(frame, false)
      TestEnv.Run(frame, "OnUpdate", 1.8)
      assert.are.equal(
        toast,
        ToastKit:Show({ key = "MyAddonSync", title = "Synced", duration = 2 })
      )
      assert.are.equal("Synced", frame.title:GetText())
      assert.is_nil(frame.text:GetText())
      assert.are.equal(1, frame:GetAlpha())
      TestEnv.Run(frame, "OnUpdate", 1.8)
      assert.is_true(toast:IsShown())
      toast:Dismiss()
      assert.are_not.equal(toast, ToastKit:Show({ key = "MyAddonSync", title = "Again" }))
    end
  )

  it(
    "counts time on a frame without IsMouseOver, and ignores scripts of a frame it gave back",
    function()
      local toast = ToastKit:Show({ title = "x", duration = 1 })
      local frame = rawget(toast, "_record").frame
      TestEnv.Run(frame, "OnUpdate", 2)
      assert.is_false(toast:IsShown())
      local onUpdate, onMouseUp =
        ToastKit._state.scripts.OnUpdate, ToastKit._state.scripts.OnMouseUp
      onUpdate(frame, 1)
      onMouseUp(frame)
      assert.is_false(frame:IsShown())
    end
  )

  it("reuses frames and refuses past maxQueued, which UNBOUNDED lifts", function()
    assert.are.same({ maxVisible = 5, maxQueued = 32 }, ToastKit:GetLimits())
    ToastKit:SetLimits({ maxVisible = 1, maxQueued = 1 })
    ToastKit:Show({ title = "shown" })
    ToastKit:Show({ title = "waiting" })
    TestEnv.expectErrorContaining(
      "ToastKit:Show holds at most 1 waiting toasts; raise maxQueued with ToastKit:SetLimits",
      function()
        ToastKit:Show({ title = "refused" })
      end
    )
    ToastKit:SetLimits({ maxQueued = ToastKit.UNBOUNDED })
    for index = 1, 50 do
      ToastKit:Show({ title = "more " .. index })
    end
    assert.are.equal(52, ToastKit:DismissAll())
    assert.are.equal(1, ToastKit._state.pool:GetCreatedCount())
  end)
end)
