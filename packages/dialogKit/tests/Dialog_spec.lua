local TestEnv = require("DialogKitTestEnv")

describe("DialogKit dialogs", function()
  local DialogKit, events
  before_each(function()
    DialogKit = TestEnv.NewPackage()
    TestEnv.InstallHostErrorHandler()
    events = {}
  end)
  after_each(TestEnv.Reset)

  local function frame()
    return TestEnv.GetGlobal(DialogKit.FRAME_NAME)
  end

  ---Options that record each callback in `events`.
  local function recording(text, extra)
    local options = {
      text = text,
      data = text,
      onAccept = function(data, inputText)
        events[#events + 1] = { "accept", data, inputText }
      end,
      onCancel = function(data, reason)
        events[#events + 1] = { "cancel", data, reason }
      end,
    }
    for key, value in pairs(extra or {}) do
      options[key] = value
    end
    return options
  end

  it("shows the text and two buttons on its own named frame, listed for Escape", function()
    local dialog = DialogKit:Show(recording("Delete the profile?", { accept = "Delete" }))
    local dialogFrame = frame()
    assert.is_true(dialogFrame:IsShown())
    assert.are.equal("DIALOG", dialogFrame:GetFrameStrata())
    assert.are.equal("Delete the profile?", dialogFrame.text:GetText())
    assert.are.equal("Delete", dialogFrame.acceptButton:GetText())
    assert.are.equal("Cancel", dialogFrame.cancelButton:GetText())
    assert.is_true(dialogFrame.cancelButton:IsShown())
    assert.is_false(dialogFrame.input:IsShown())
    assert.are.equal("UIPanelButtonTemplate", dialogFrame.acceptButton.template)
    assert.are.same(
      { "ItemRefTooltip", DialogKit.FRAME_NAME },
      TestEnv.GetGlobal("UISpecialFrames")
    )
    assert.is_true(dialog:IsShown())
    assert.is_false(dialog:IsQueued())
    assert.are.equal("DialogKit.Dialog", getmetatable(dialog))
  end)

  it("shows one button with cancel = false, and numbers as text", function()
    DialogKit:Show({ text = 42, cancel = false })
    assert.are.equal("42", frame().text:GetText())
    assert.is_false(frame().cancelButton:IsShown())
    assert.are.equal("OK", frame().acceptButton:GetText())
  end)

  it("accepts with the button or Enter and cancels with the button, each once", function()
    local dialog = DialogKit:Show(recording("first"))
    TestEnv.Run(frame().acceptButton, "OnClick", "LeftButton")
    assert.are.same({ { "accept", "first" } }, events)
    assert.is_false(dialog:IsShown())
    assert.is_false(frame():IsShown())
    assert.is_false(dialog:Hide())
    DialogKit:Show(recording("second"))
    TestEnv.Run(frame().cancelButton, "OnClick", "LeftButton")
    assert.are.same({ "cancel", "second", "cancel" }, events[2])
  end)

  it("hands the input line's text to onAccept, starting from inputText", function()
    local dialog =
      DialogKit:Show(recording("Name?", { input = true, inputText = "Default", maxLetters = 12 }))
    local input = frame().input
    assert.is_true(input:IsShown())
    assert.are.equal("Default", input:GetText())
    assert.are.equal("InputBoxTemplate", input.template)
    input:SetText("Raid")
    assert.are.equal("Raid", dialog:GetInput())
    TestEnv.Run(input, "OnEnterPressed")
    assert.are.same({ { "accept", "Name?", "Raid" } }, events)
    assert.is_nil(dialog:GetInput())
  end)

  it("cancels with escape from the input line and through UISpecialFrames", function()
    DialogKit:Show(recording("one", { input = true }))
    TestEnv.Run(frame().input, "OnEscapePressed")
    DialogKit:Show(recording("two"))
    TestEnv.PressEscape()
    assert.are.same({ { "cancel", "one", "escape" }, { "cancel", "two", "escape" } }, events)
    assert.is_false(frame():IsShown())
  end)

  it("cancels with timeout once the time has passed", function()
    DialogKit:Show(recording("soon", { timeout = 5 }))
    TestEnv.Advance(frame(), 4)
    assert.are.same({}, events)
    TestEnv.Advance(frame(), 1)
    assert.are.same({ { "cancel", "soon", "timeout" } }, events)
    assert.is_nil(frame():GetScript("OnUpdate"))
  end)

  it("queues dialogs behind the shown one and shows them in order", function()
    local first = DialogKit:Show(recording("first"))
    local second = DialogKit:Show(recording("second"))
    local third = DialogKit:Show(recording("third"))
    assert.is_true(second:IsQueued())
    assert.are.equal("first", frame().text:GetText())
    TestEnv.Run(frame().acceptButton, "OnClick", "LeftButton")
    assert.is_true(second:IsShown())
    assert.are.equal("second", frame().text:GetText())
    assert.is_true(third:Hide())
    assert.are.same({ "cancel", "third", "hidden" }, events[2])
    assert.is_true(second:Hide())
    assert.is_false(frame():IsShown())
    assert.is_false(first:IsShown())
    assert.are.equal(3, #events)
  end)

  it("returns the dialog shown or waiting under the same key", function()
    local first = DialogKit:Show(recording("keyed", { key = "MyAddonReset" }))
    assert.are.equal(first, DialogKit:Show(recording("again", { key = "MyAddonReset" })))
    TestEnv.Run(frame().acceptButton, "OnClick", "LeftButton")
    assert.are_not.equal(first, DialogKit:Show(recording("later", { key = "MyAddonReset" })))
  end)

  it("lets a callback show the next dialog at once", function()
    DialogKit:Show({
      text = "first",
      onAccept = function()
        DialogKit:Show({ text = "from the callback" })
      end,
    })
    DialogKit:Show({ text = "waiting" })
    TestEnv.Run(frame().acceptButton, "OnClick", "LeftButton")
    assert.are.equal("from the callback", frame().text:GetText())
  end)

  it("ends every dialog with HideAll, the waiting ones first", function()
    DialogKit:Show(recording("a"))
    DialogKit:Show(recording("b"))
    DialogKit:Show(recording("c"))
    assert.are.equal(3, DialogKit:HideAll())
    assert.are.same({
      { "cancel", "c", "hidden" },
      { "cancel", "b", "hidden" },
      { "cancel", "a", "hidden" },
    }, events)
    assert.are.equal(0, DialogKit:HideAll())
  end)

  it("reports callbacks that raise and goes on to the next dialog", function()
    DialogKit:Show({
      text = "broken",
      onAccept = function()
        error("accept failed", 0)
      end,
    })
    DialogKit:Show({ text = "next" })
    TestEnv.Run(frame().acceptButton, "OnClick", "LeftButton")
    assert.are.same({ "accept failed" }, TestEnv.TakeReportedValues())
    assert.are.equal("next", frame().text:GetText())
  end)

  it("holds at most maxQueued waiting dialogs, and UNBOUNDED lifts it", function()
    assert.are.same({ maxQueued = 16 }, DialogKit:GetLimits())
    DialogKit:SetLimits({ maxQueued = 1 })
    DialogKit:Show({ text = "shown" })
    DialogKit:Show({ text = "waiting" })
    TestEnv.expectErrorContaining(
      "DialogKit:Show holds at most 1 waiting dialogs; raise maxQueued with DialogKit:SetLimits",
      function()
        DialogKit:Show({ text = "refused" })
      end
    )
    DialogKit:SetLimits({ maxQueued = DialogKit.UNBOUNDED })
    for index = 1, 40 do
      DialogKit:Show({ text = "more " .. index })
    end
    assert.are.equal(42, DialogKit:HideAll())
  end)
end)
