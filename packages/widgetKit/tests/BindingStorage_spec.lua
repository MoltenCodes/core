local TestEnv = require("WidgetKitTestEnv")

-- Where a binding saves (implementation revision 8): the storage is resolved
-- at every save and restore, so a storage function follows a SettingsKit
-- profile switch, and a storage that fails is reported, never raised from the
-- drag handler that already moved the frame. These specs run without
-- SchedulerKit, so every capture saves at once; `BindingHost_spec.lua` covers
-- the debounced save.

---The anchor fields a SettingsKit schema declares for a binding.
---@param S table SchemaKit
---@return table schema
local function anchorSchema(S)
  return S.optional(S.table({
    fields = {
      point = S.optional(S.string()),
      relativeTo = S.optional(S.string()),
      relativePoint = S.optional(S.string()),
      x = S.optional(S.number()),
      y = S.optional(S.number()),
      scale = S.optional(S.number()),
    },
  }))
end

---Drag a window's title bar so the window's bottom-left corner lands at
---(`left`, `bottom`), as the client runs the drag scripts.
---@param window table a `Frame` widget
---@param left number
---@param bottom number
local function drag(window, left, bottom)
  TestEnv.RunScript(window.titleBar, "OnDragStart")
  TestEnv.MoveFrame(window.frame, left, bottom)
  TestEnv.RunScript(window.titleBar, "OnDragStop")
end

---Whether any reported error contains `text`.
---@param reported { value: any }[]
---@param text string
---@return boolean
local function reportedContaining(reported, text)
  for _, entry in ipairs(reported) do
    if tostring(entry.value):find(text, 1, true) then
      return true
    end
  end
  return false
end

describe("WidgetKit position binding storage", function()
  local WidgetKit
  before_each(function()
    WidgetKit = TestEnv.NewPackage()
    TestEnv.TakeReportedErrors()
  end)
  after_each(function()
    TestEnv.SetGlobal("WidgetKitSpecProfileDB", nil)
    package.loaded["SettingsKit"] = nil
    TestEnv.Reset()
  end)

  it("resolves a storage function at every save and restore", function()
    local first, second = {}, {}
    local current = first
    local window = WidgetKit:Create("Frame")
    local binding = window:BindPosition(function()
      return current
    end)

    drag(window, 20, 560)
    assert.are.equal("TOPLEFT", first.anchor.point)

    current = second
    drag(window, 1800, 20)
    assert.are.equal("BOTTOMRIGHT", second.anchor.point)
    assert.are.equal("TOPLEFT", first.anchor.point)

    current = first
    assert.is_true(binding:Restore())
    assert.are.equal("TOPLEFT", (window.frame:GetPoint(1)))
  end)

  it("follows a SettingsKit profile switch through db.profile and OnProfileChanged", function()
    local S = require("SchemaKit")
    local SettingsKit = require("SettingsKit")
    local db = SettingsKit:Open("WidgetKitSpecProfileDB", {
      profile = S.table({ fields = { anchor = anchorSchema(S) } }),
    })
    local window = WidgetKit:Create("Frame")
    local binding = window:BindPosition(function()
      return db.profile
    end)
    db:OnProfileChanged(function()
      binding:Restore()
    end)

    drag(window, 20, 560)
    db:SetProfile("Second")
    -- The new profile saved no anchor: the window stays where it is.
    assert.are.equal("TOPLEFT", (window.frame:GetPoint(1)))
    drag(window, 1800, 20)

    local saved = TestEnv.GetGlobal("WidgetKitSpecProfileDB").profiles
    assert.are.equal("TOPLEFT", saved.Default.anchor.point)
    assert.are.equal("BOTTOMRIGHT", saved.Second.anchor.point)

    db:SetProfile("Default")
    assert.are.equal("TOPLEFT", (window.frame:GetPoint(1)))
    db:SetProfile("Second")
    assert.are.equal("BOTTOMRIGHT", (window.frame:GetPoint(1)))
    assert.are.equal(0, #TestEnv.TakeReportedErrors())
  end)

  it(
    "reports a save into a detached profile view and keeps the window where it was dropped",
    function()
      local S = require("SchemaKit")
      local SettingsKit = require("SettingsKit")
      local db = SettingsKit:Open("WidgetKitSpecProfileDB", {
        profile = S.table({ fields = { anchor = anchorSchema(S) } }),
      })
      local window = WidgetKit:Create("Frame")
      local moved = 0
      window:SetCallback("OnMoved", function()
        moved = moved + 1
      end)
      -- A view captured once keeps writing into the profile it was made for.
      window:BindPosition(db.profile)
      db:SetProfile("Second")
      db:DeleteProfile("Default")

      TestEnv.RunScript(window.titleBar, "OnDragStart")
      TestEnv.MoveFrame(window.frame, 20, 560)
      assert.has_no.errors(function()
        TestEnv.RunScript(window.titleBar, "OnDragStop")
      end)

      local reported = TestEnv.TakeReportedErrors()
      assert.are.equal(1, #reported)
      assert.is_true(reportedContaining(reported, "deleted or reset away"))
      local point, _, _, x, y = window.frame:GetPoint(1)
      assert.are.same({ "TOPLEFT", 20, -20 }, { point, x, y })
      assert.are.equal(1, window.frame:GetNumPoints())
      assert.are.equal(1, moved)
      local saved = TestEnv.GetGlobal("WidgetKitSpecProfileDB").profiles
      assert.is_nil(saved.Second.anchor)
    end
  )

  it("reports a storage function that raises or returns no table", function()
    local frame = TestEnv.GetGlobal("CreateFrame")("Frame", nil, TestEnv.GetGlobal("UIParent"))
    frame:SetSize(100, 100)
    frame:SetPoint("CENTER")

    local binding = WidgetKit:BindPosition(frame, function()
      error("storage is gone", 0)
    end)
    assert.are.same({ { value = "storage is gone" } }, TestEnv.TakeReportedErrors())
    assert.is_false(binding:Restore())
    assert.are.equal(1, #TestEnv.TakeReportedErrors())
    local anchor = binding:Capture()
    assert.are.equal("CENTER", anchor.point)
    assert.are.same({ { value = "storage is gone" } }, TestEnv.TakeReportedErrors())

    local empty = WidgetKit:BindPosition(frame, function()
      return nil
    end)
    assert.is_false(empty:Restore())
    empty:Capture()
    local reported = TestEnv.TakeReportedErrors()
    assert.are.equal(3, #reported)
    for _, entry in ipairs(reported) do
      assert.are.equal(
        "WidgetKit.Binding storage function must return a table; it returned a nil",
        entry.value
      )
    end
    assert.are.equal("CENTER", (frame:GetPoint(1)))
  end)

  it("reports a storage table whose write or read raises", function()
    local frame = TestEnv.GetGlobal("CreateFrame")("Frame", nil, TestEnv.GetGlobal("UIParent"))
    frame:SetSize(100, 100)
    frame:SetPoint("CENTER")
    local refusing = setmetatable({}, {
      __index = function()
        error("read refused", 0)
      end,
      __newindex = function()
        error("write refused", 0)
      end,
    })
    local binding = WidgetKit:BindPosition(frame, refusing)
    assert.are.same({ { value = "read refused" } }, TestEnv.TakeReportedErrors())
    assert.are.equal("CENTER", binding:Capture().point)
    assert.are.same({ { value = "write refused" } }, TestEnv.TakeReportedErrors())
  end)

  it("refuses a storage that is neither a table nor a function at the caller", function()
    local frame = TestEnv.GetGlobal("CreateFrame")("Frame", nil, TestEnv.GetGlobal("UIParent"))
    TestEnv.expectErrorContaining(
      "WidgetKit:BindPosition storage must be a table or a function that returns one",
      function()
        WidgetKit:BindPosition(frame, "db.profile")
      end
    )
  end)
end)
