local TestEnv = require("WidgetKitTestEnv")

-- Secret texts on their own font strings (implementation revision 7).
--
-- The second real-client run on Retail 12.1.0 b69933 (2026-09-25, 11:09)
-- showed that a font string which displayed a secret keeps secret
-- measurements after `ClearText`: a reused `Label` answered `GetText()` plainly
-- and `GetStringHeight()` as a secret for a plain text. The client rules of
-- `support/WidgetKitClientRules.lua` model that, so these specs prove every
-- text slot a text setter may give a secret shows it on a font string of its
-- own, never shows a plain text there again, and needs at most one such font
-- string per slot for the widget's life.

--- Each text slot a text setter reaches with `allowSecret`: the type, the
--- setter, the getter and the widget field naming the region that shows it.
local SLOTS = {
  { "Label", "SetText", "GetText", "text" },
  { "Heading", "SetText", "GetText", "text" },
  { "Button", "SetText", "GetText", "text" },
  { "Frame", "SetTitle", "GetTitle", "titleText" },
  { "Group", "SetTitle", "GetTitle", "titleText" },
  { "CheckBox", "SetLabel", "GetLabel", "labelText" },
  { "Slider", "SetLabel", "GetLabel", "labelText" },
  { "EditBox", "SetLabel", "GetLabel", "labelText" },
  { "Dropdown", "SetLabel", "GetLabel", "labelText" },
  { "ColorPicker", "SetLabel", "GetLabel", "labelText" },
}

describe("WidgetKit secret texts", function()
  local WidgetKit
  before_each(function()
    WidgetKit = TestEnv.NewPackage()
    TestEnv.InstallSecretProbe()
    TestEnv.TakeReportedErrors()
  end)
  after_each(TestEnv.Reset)

  it(
    "measures a plain text on the next use of a Label that showed a secret, as the client test does",
    function()
      local secret = TestEnv.NewSecret()
      local label = WidgetKit:Create("Label") --[[@as WidgetKit.Label]]
      label:SetText(secret, { allowSecret = true })
      assert.are.equal(secret, label:GetText())
      assert.are.equal(12, label:GetHeight())
      WidgetKit:Release(label)

      local reused = WidgetKit:Create("Label") --[[@as WidgetKit.Label]]
      assert.are.equal(label, reused)
      assert.are.equal("", reused:GetText())
      reused:SetText("first line\nsecond line")
      local height = reused.text:GetStringHeight()
      assert.is_false(TestEnv.GetGlobal("issecretvalue")(height))
      assert.are.equal(24, height)
      assert.are.equal(24, reused:GetHeight())
      assert.are.same({}, TestEnv.TakeReportedErrors())
    end
  )

  it("measures a plain text again within the same use, after a secret", function()
    local secret = TestEnv.NewSecret()
    local label = WidgetKit:Create("Label") --[[@as WidgetKit.Label]]
    local plainText = label.text
    label:SetText(secret, { allowSecret = true })
    assert.are_not.equal(plainText, label.text)
    label:SetText("a\nb\nc")
    assert.are.equal(plainText, label.text)
    assert.are.equal(36, label:GetHeight())
    -- The font string that showed the secret is empty, cleared and hidden.
    local secretText = label._secretTexts.text.secret
    assert.is_nil(secretText:GetText())
    assert.is_false(secretText:IsShown())
  end)

  it("keeps one secret font string per slot, however often a secret comes back", function()
    local label = WidgetKit:Create("Label") --[[@as WidgetKit.Label]]
    label:SetText(TestEnv.NewSecret(), { allowSecret = true })
    local secretText = label.text
    local frame = label.frame
    local created = 0
    local createFontString = frame.CreateFontString
    frame.CreateFontString = function(...)
      created = created + 1
      return createFontString(...)
    end
    for _ = 1, 50 do
      label:SetText("plain")
      label:SetText(TestEnv.NewSecret(), { allowSecret = true })
      assert.are.equal(secretText, label.text)
      WidgetKit:Release(label)
      label = WidgetKit:Create("Label") --[[@as WidgetKit.Label]]
      label:SetText(TestEnv.NewSecret(), { allowSecret = true })
    end
    assert.are.equal(0, created)
    assert.are.equal(secretText, label.text)
  end)

  it(
    "never shows a plain text on a font string that showed a secret, in every text slot",
    function()
      local isSecret = TestEnv.GetGlobal("issecretvalue")
      for _, slot in ipairs(SLOTS) do
        local typeName, setter, getter, key = slot[1], slot[2], slot[3], slot[4]
        local secret = TestEnv.NewSecret()
        local widget = WidgetKit:Create(typeName) ---@cast widget -nil
        local plain = widget[key]
        widget[setter](widget, secret, { allowSecret = true })
        assert.are.equal(secret, widget[getter](widget), typeName .. ":" .. getter)
        assert.are_not.equal(plain, widget[key], typeName)
        assert.is_true(widget[key]:IsShown(), typeName)
        WidgetKit:Release(widget)

        local reused = WidgetKit:Create(typeName) ---@cast reused -nil
        assert.are.equal(widget, reused, typeName)
        assert.are.equal(plain, reused[key], typeName)
        assert.are.equal("", reused[getter](reused), typeName .. ":" .. getter .. " reused")
        reused[setter](reused, "plain")
        assert.are.equal("plain", reused[getter](reused), typeName)
        local fontString = reused[key]
        if fontString:GetObjectType() == "Button" then
          fontString = fontString:GetFontString()
        end
        assert.is_false(isSecret(fontString:GetStringHeight()), typeName)
        assert.is_false(isSecret(fontString:GetStringWidth()), typeName)
        WidgetKit:Release(reused)
      end
      assert.are.same({}, TestEnv.TakeReportedErrors())
    end
  )

  it("gives the secret font string the slot's anchors, font, justification and colour", function()
    local label = WidgetKit:Create("Label") --[[@as WidgetKit.Label]]
    label:SetFontObject("GameFontNormal")
    label:SetJustifyH("RIGHT")
    label:SetColor(0.25, 0.5, 0.75, 1)
    label:SetWidth(150)
    local plain = label.text
    label:SetText(TestEnv.NewSecret(), { allowSecret = true })
    local secretText = label.text
    assert.are.equal(plain:GetNumPoints(), secretText:GetNumPoints())
    assert.are.same({ plain:GetPoint(1) }, { secretText:GetPoint(1) })
    assert.are.equal("GameFontNormal", secretText:GetFontObject())
    assert.are.equal("RIGHT", secretText:GetJustifyH())
    assert.is_true(secretText:GetWordWrap())
    assert.are.same({ 0.25, 0.5, 0.75, 1 }, { secretText:GetTextColor() })
    assert.are.equal(150, secretText:GetWidth())

    -- A style set while the secret shows moves back with the next plain text.
    label:SetDisabled(true)
    label:SetJustifyH("CENTER")
    label:SetText("plain")
    assert.are.equal(plain, label.text)
    assert.are.equal("CENTER", plain:GetJustifyH())
    assert.are.same({ 0.5, 0.5, 0.5, 1 }, { plain:GetTextColor() })
    label:SetDisabled(false)
    assert.are.same({ 0.25, 0.5, 0.75, 1 }, { plain:GetTextColor() })
  end)

  it("anchors a Heading's lines to the font string showing its text", function()
    local heading = WidgetKit:Create("Heading")
    heading:SetText(TestEnv.NewSecret(), { allowSecret = true })
    local secretText = heading.text
    local _, relativeTo = heading.leftLine:GetPoint(2)
    assert.are.equal(secretText, relativeTo)
    heading:SetText("plain")
    _, relativeTo = heading.leftLine:GetPoint(2)
    assert.are.equal(heading.text, relativeTo)
    assert.are_not.equal(secretText, relativeTo)
  end)

  it("shows a Button's secret text on its own font string, with the button's font", function()
    local button = WidgetKit:Create("Button") --[[@as WidgetKit.Button]]
    local frame = button.frame
    frame:GetFontString():SetFontObject("GameFontNormal")
    local secret = TestEnv.NewSecret()
    button:SetText(secret, { allowSecret = true })
    assert.are.equal(secret, button:GetText())
    assert.is_nil(frame:GetText())
    assert.are.equal("GameFontNormal", button.text:GetFontObject())
    assert.are.equal(frame, button.text:GetParent())

    -- Disabled, the secret text takes the font the button's own text has.
    frame:GetFontString():SetFontObject("GameFontDisable")
    button:SetDisabled(true)
    assert.are.equal("GameFontDisable", button.text:GetFontObject())

    button:SetText("plain")
    assert.are.equal(frame, button.text)
    assert.are.equal("plain", frame:GetText())
    assert.are.equal("plain", button:GetText())
  end)

  it("moves a Group's content below a secret title and back up when it is cleared", function()
    local group = WidgetKit:Create("Group") --[[@as WidgetKit.Group]]
    group:SetTitle(TestEnv.NewSecret(), { allowSecret = true })
    local _, _, _, _, top = group.content:GetPoint(1)
    assert.are.equal(-26, top)
    group:SetTitle(nil)
    _, _, _, _, top = group.content:GetPoint(1)
    assert.are.equal(-8, top)
  end)
end)
