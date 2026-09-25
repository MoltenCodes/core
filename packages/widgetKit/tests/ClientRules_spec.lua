local TestEnv = require("WidgetKitTestEnv")

-- What the Retail 12.1.0 b69933 client showed WidgetKit on 2026-09-25
-- (tests/client/MoltenCodesTest_WidgetKit), and the fixes implementation
-- revision 6 made for it. Every loader of `WidgetKitTestEnv` installs the
-- client rules of `support/WidgetKitClientRules.lua`, so these specs run
-- against a fixture that behaves as the client did there: frame setters refuse
-- a secret, an empty font string or button answers `GetText()` with `nil`, a
-- font string that showed a secret keeps its secret aspect until `ClearText`,
-- and `SetParent` hands a frame its parent's strata.

describe("WidgetKit fixture client rules", function()
  before_each(function()
    TestEnv.NewPackage()
    TestEnv.InstallSecretProbe()
  end)
  after_each(TestEnv.Reset)

  it("refuse a secret in a frame setter with the client's message at the caller's line", function()
    local frame = TestEnv.GetGlobal("CreateFrame")("Frame")
    local secret = TestEnv.NewSecret()
    local ok, failure = pcall(function()
      frame:SetHeight(secret)
    end)
    assert.is_false(ok)
    assert.is_truthy(
      tostring(failure):find(
        "ClientRules_spec.lua:%d+: bad argument #1 to 'SetHeight' %(Usage: self:SetHeight%(height%)%."
          .. " Secret values are only allowed during untainted execution for this argument%.%)$"
      )
    )
    ok = pcall(frame.SetPoint, frame, "TOPLEFT", nil, "TOPLEFT", 0, secret)
    assert.is_false(ok)
    local box = TestEnv.GetGlobal("CreateFrame")("EditBox")
    ok, failure = pcall(box.SetText, box, secret)
    assert.is_false(ok)
    assert.is_truthy(tostring(failure):find("bad argument #1 to 'SetText'", 1, true))
  end)

  it("answer nil for an empty font string and keep a secret aspect until ClearText", function()
    local frame = TestEnv.GetGlobal("CreateFrame")("Frame")
    local fontString = frame:CreateFontString()
    fontString:SetText("")
    assert.is_nil(fontString:GetText())
    local secret = TestEnv.NewSecret()
    fontString:SetText(secret)
    fontString:SetText("")
    assert.are.equal(secret, fontString:GetText())
    assert.are.equal(secret, fontString:GetStringHeight())
    fontString:ClearText()
    assert.is_nil(fontString:GetText())
    assert.are.equal(0, fontString:GetStringHeight())
  end)

  it("give a re-parented frame its parent's strata unless its strata is fixed", function()
    local createFrame = TestEnv.GetGlobal("CreateFrame")
    local parent = createFrame("Frame")
    parent:SetFrameStrata("LOW")
    local follower = createFrame("Frame")
    follower:SetFrameStrata("DIALOG")
    follower:SetParent(parent)
    assert.are.equal("LOW", follower:GetFrameStrata())
    local fixed = createFrame("Frame")
    fixed:SetFrameStrata("DIALOG")
    fixed:SetFixedFrameStrata(true)
    fixed:SetParent(parent)
    assert.are.equal("DIALOG", fixed:GetFrameStrata())
  end)
end)

describe("WidgetKit under the client rules", function()
  local WidgetKit
  before_each(function()
    WidgetKit = TestEnv.NewPackage()
    TestEnv.TakeReportedErrors()
  end)
  after_each(TestEnv.Reset)

  it(
    "answers every text getter with an empty string after Create and after SetText(nil)",
    function()
      local probes = {
        { "Label", "GetText", "SetText" },
        { "Heading", "GetText", "SetText" },
        { "Button", "GetText", "SetText" },
        { "EditBox", "GetText", "SetText" },
        { "Frame", "GetTitle", "SetTitle" },
        { "Group", "GetTitle", "SetTitle" },
        { "CheckBox", "GetLabel", "SetLabel" },
        { "Slider", "GetLabel", "SetLabel" },
        { "EditBox", "GetLabel", "SetLabel" },
        { "Dropdown", "GetLabel", "SetLabel" },
        { "ColorPicker", "GetLabel", "SetLabel" },
      }
      for _, probe in ipairs(probes) do
        local typeName, getter, setter = probe[1], probe[2], probe[3]
        local widget = WidgetKit:Create(typeName)
        assert.are.equal("", widget[getter](widget), typeName .. ":" .. getter .. " after Create")
        widget[setter](widget, "shown")
        assert.are.equal("shown", widget[getter](widget), typeName .. ":" .. getter)
        widget[setter](widget, nil)
        assert.are.equal("", widget[getter](widget), typeName .. ":" .. getter .. " after nil")
        WidgetKit:Release(widget)
      end
      assert.are.same({}, TestEnv.TakeReportedErrors())
    end
  )

  it("keeps a Frame window at the DIALOG strata under any parent, and on reuse", function()
    local stage = TestEnv.GetGlobal("CreateFrame")("Frame", nil, TestEnv.GetGlobal("UIParent"))
    stage:SetFrameStrata("MEDIUM")
    local window = WidgetKit:Create("Frame")
    window:SetParent(stage)
    assert.are.equal("DIALOG", window.frame:GetFrameStrata())
    assert.is_true(window.frame:HasFixedFrameStrata())
    local frame = window.frame
    WidgetKit:Release(window)
    local reused = WidgetKit:Create("Frame")
    assert.are.equal(frame, reused.frame)
    assert.are.equal("DIALOG", reused.frame:GetFrameStrata())
  end)

  it(
    "gives a Label's font string the label's width: at Create, from SetWidth and from a layout",
    function()
      local label = WidgetKit:Create("Label") --[[@as WidgetKit.Label]]
      -- One anchor: the font string's width is its own, so it wraps at a width
      -- the client knows before the label was ever drawn.
      assert.are.equal(1, label.text:GetNumPoints())
      assert.are.equal(200, label.text:GetWidth())
      label:SetWidth(150)
      assert.are.equal(150, label.text:GetWidth())

      local group = WidgetKit:Create("Group")
      group:SetWidth(316)
      group:SetPoint("TOPLEFT", TestEnv.GetGlobal("UIParent"), "TOPLEFT", 0, 0)
      label:SetFullWidth(true)
      label:SetText("wrapped")
      group:AddChild(label)
      assert.are.equal(300, label.text:GetWidth())
      assert.are.equal(300, label:GetWidth())
    end
  )

  it("never hands the client's secret measurement of a Label to SetHeight", function()
    TestEnv.InstallSecretProbe()
    local label = WidgetKit:Create("Label") --[[@as WidgetKit.Label]]
    local secret = TestEnv.NewSecret()
    label:SetText(secret, { allowSecret = true })
    -- The font string now measures every text as a secret, as the reused
    -- label in the client did; the rules raise if it reaches `SetHeight`.
    label.text:SetText("")
    label:SetText("plain")
    assert.are.equal(12, label:GetHeight())

    local group = WidgetKit:Create("Group")
    group:SetPoint("TOPLEFT", TestEnv.GetGlobal("UIParent"), "TOPLEFT", 0, 0)
    label:SetFullWidth(true)
    group:AddChild(label)
    assert.are.equal(12, label:GetHeight())
    assert.are.same({}, TestEnv.TakeReportedErrors())
  end)
end)
