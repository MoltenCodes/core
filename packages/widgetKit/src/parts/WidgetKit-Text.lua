-- MoltenCodes WidgetKit part Text
--
-- The display types: `Label` (one font string), `Heading` (a centred title
-- between two lines) and `Spacer` (empty space).
--
-- Needs the WidgetKit core. See `docs/API.md`, "Parts", and
-- `docs/INTERNALS.md`, "Parts", for how a part joins the core.

-- Constants ------------------------------------------------------------------

local PART_NAME = "Text"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "widgetKit", 1

-- Core -----------------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
local WidgetKit = nil
if type(Registry) == "table" and type(rawget(Registry, "Get")) == "function" then
  WidgetKit = Registry:Get(CORE_PACKAGE, CORE_API)
end
local state = type(WidgetKit) == "table" and rawget(WidgetKit, "_state") or nil
if
  type(state) ~= "table"
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
then
  error("MoltenCodes WidgetKit part Text requires WidgetKit API 1 to be loaded first", 2)
end
---@cast WidgetKit WidgetKit

local installed = rawget(rawget(state, "parts"), PART_NAME)
if
  type(installed) == "table"
  and type(installed.revision) == "number"
  and installed.revision >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every widget.
  return WidgetKit
end

-- The core's helpers and shared tables, assigned by `bind` from
-- `state.helpers`. A newer core calls `bind` again, so this part runs its
-- helpers from then on (`docs/INTERNALS.md`, "Parts").
local activeRecord
local checkText
local colourLabel
local createFrame
local isSecret
local readDisabled
local refuseSecret
local releaseParent
local showText
local validateNumber
local registerBuiltInType
local DISABLED_BLUE
local DISABLED_GREEN
local DISABLED_RED
local TEXT_BLUE
local TEXT_GREEN
local TEXT_RED

---Assign the core helpers this part uses.
---@param helpers table the core's `state.helpers`
local function bind(helpers)
  activeRecord = helpers.activeRecord
  checkText = helpers.checkText
  colourLabel = helpers.colourLabel
  createFrame = helpers.createFrame
  isSecret = helpers.isSecret
  readDisabled = helpers.readDisabled
  refuseSecret = helpers.refuseSecret
  releaseParent = helpers.releaseParent
  showText = helpers.showText
  validateNumber = helpers.validateNumber
  registerBuiltInType = helpers.registerBuiltInType
  local colours = helpers.colours
  local text, disabled = colours.text, colours.disabled
  DISABLED_BLUE = disabled[3]
  DISABLED_GREEN = disabled[2]
  DISABLED_RED = disabled[1]
  TEXT_BLUE = text[3]
  TEXT_GREEN = text[2]
  TEXT_RED = text[1]
end

bind(rawget(state, "helpers"))

-- This part's constructors by type name, each defined in its own `do` block
-- below so that the helpers of one type are not visible to the others.
local BASE_CONSTRUCTORS = {}

-- Widget: Label --------------------------------------------------------------

do
  -- One line of the default fonts, used where a text height cannot be measured.
  local LINE_HEIGHT = 12

  -- The width a label has from `Create` on, until `SetWidth` or a layout
  -- gives it another.
  local LABEL_WIDTH = 200

  ---Size the label to its text. A secret text is not measured, and a
  ---measurement the client answers as a secret is not used: `SetHeight`
  ---takes a secret only from untainted code (Retail 12.1.0 b69933). A plain
  ---text is shown by a font string that never showed a secret (`showText`),
  ---so its measurement is plain; the check stays as the last guard. Either
  ---way a label whose height cannot be measured is one line high.
  ---@param widget table
  local function labelUpdateHeight(widget)
    local height = LINE_HEIGHT
    if not widget._secret then
      local measured = widget.text:GetStringHeight()
      if not isSecret(measured) then
        height = measured
      end
    end
    widget.frame:SetHeight(height)
  end

  ---Give the font string the label's width and size the label again.
  ---
  ---The font string wraps at a width of its own rather than at its anchors:
  ---the client measures a wrapped text only against a width it has already
  ---resolved, and a label laid out before it was ever drawn (measured on
  ---Retail 12.1.0 b69933) still measured one unwrapped line after its anchors
  ---spanned the content. `width` is a plain number: `SetWidth` refuses a
  ---secret, and a layout tells a child no width it could not read. It is
  ---kept, so the font string `showText` switches to wraps at it too.
  ---@param widget table
  ---@param width number
  local function labelSetWrapWidth(widget, width)
    widget._wrapWidth = width
    widget.text:SetWidth(width)
    labelUpdateHeight(widget)
  end

  ---@param text any
  ---@param options WidgetKit.TextOptions?
  local function labelSetText(self, text, options)
    local value, secret = checkText(self, text, options, "WidgetKit Label:SetText", 3)
    self._secret = secret
    showText(self, "text", value, secret)
    -- The font string showing the text may have changed.
    labelSetWrapWidth(self, self._wrapWidth)
  end

  ---@return any
  local function labelGetText(self)
    activeRecord(self, "WidgetKit Label:GetText", 3)
    -- The client's font string answers `nil` for an empty text.
    local text = self.text:GetText()
    if type(text) == "nil" then
      return ""
    end
    return text
  end

  ---@param fontObject any a font object or its global name
  local function labelSetFontObject(self, fontObject)
    activeRecord(self, "WidgetKit Label:SetFontObject", 3)
    if type(fontObject) ~= "string" and type(fontObject) ~= "table" then
      error("WidgetKit Label:SetFontObject fontObject must be a font object or its name", 2)
    end
    self.text:SetFontObject(fontObject)
    labelUpdateHeight(self)
  end

  ---@param red number
  ---@param green number
  ---@param blue number
  ---@param alpha number?
  local function labelSetColor(self, red, green, blue, alpha)
    activeRecord(self, "WidgetKit Label:SetColor", 3)
    validateNumber(red, "WidgetKit Label:SetColor red", 3)
    validateNumber(green, "WidgetKit Label:SetColor green", 3)
    validateNumber(blue, "WidgetKit Label:SetColor blue", 3)
    if type(alpha) ~= "nil" then
      validateNumber(alpha, "WidgetKit Label:SetColor alpha", 3)
    end
    self._red, self._green, self._blue, self._alpha = red, green, blue, alpha or 1
    if not self._disabled then
      self.text:SetTextColor(red, green, blue, alpha or 1)
    end
  end

  ---@param justify string `"LEFT"`, `"CENTER"` or `"RIGHT"`
  local function labelSetJustifyH(self, justify)
    activeRecord(self, "WidgetKit Label:SetJustifyH", 3)
    refuseSecret(justify, "WidgetKit Label:SetJustifyH justify", 3)
    if justify ~= "LEFT" and justify ~= "CENTER" and justify ~= "RIGHT" then
      error('WidgetKit Label:SetJustifyH justify must be "LEFT", "CENTER" or "RIGHT"', 2)
    end
    self.text:SetJustifyH(justify)
  end

  ---@param disabled boolean? `true` greys the text out; the widget takes no input
  local function labelSetDisabled(self, disabled)
    disabled = readDisabled(self, disabled, "WidgetKit Label:SetDisabled", 3)
    self._disabled = disabled
    if disabled then
      self.text:SetTextColor(DISABLED_RED, DISABLED_GREEN, DISABLED_BLUE, 1)
    else
      self.text:SetTextColor(self._red, self._green, self._blue, self._alpha)
    end
  end

  ---@param width number
  local function labelOnWidthSet(self, width)
    labelSetWrapWidth(self, width)
  end

  local function labelOnAcquire(self)
    self.frame:SetWidth(LABEL_WIDTH)
    self._secret = false
    self._disabled = false
    self._red, self._green, self._blue, self._alpha = TEXT_RED, TEXT_GREEN, TEXT_BLUE, 1
    self.text:SetFontObject("GameFontHighlightSmall")
    self.text:SetJustifyH("LEFT")
    self.text:SetTextColor(TEXT_RED, TEXT_GREEN, TEXT_BLUE, 1)
    self.text:SetText("")
    labelSetWrapWidth(self, LABEL_WIDTH)
  end

  ---Clear the text and go back to the font string that never showed a
  ---secret, so the next use measures its texts (`showText`).
  local function labelOnRelease(self)
    showText(self, "text", "", false)
    self._secret = false
  end

  ---@return table widget
  function BASE_CONSTRUCTORS.Label()
    local frame = createFrame("Frame", releaseParent())
    local text = frame:CreateFontString(nil, "OVERLAY")
    -- One anchor: the width is the font string's own (`labelSetWrapWidth`).
    text:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    text:SetWordWrap(true)
    return {
      frame = frame,
      text = text,
      _secret = false,
      _wrapWidth = LABEL_WIDTH,
      _disabled = false,
      _red = TEXT_RED,
      _green = TEXT_GREEN,
      _blue = TEXT_BLUE,
      _alpha = 1,
      OnAcquire = labelOnAcquire,
      OnRelease = labelOnRelease,
      OnWidthSet = labelOnWidthSet,
      SetText = labelSetText,
      GetText = labelGetText,
      SetFontObject = labelSetFontObject,
      SetColor = labelSetColor,
      SetJustifyH = labelSetJustifyH,
      SetDisabled = labelSetDisabled,
    }
  end
end

-- Widget: Heading ------------------------------------------------------------

do
  ---@param text any
  ---@param options WidgetKit.TextOptions?
  local function headingSetText(self, text, options)
    local value, secret = checkText(self, text, options, "WidgetKit Heading:SetText", 3)
    showText(self, "text", value, secret)
    -- The lines meet in the middle when there is no text.
    local empty = not secret and value == ""
    self.leftLine:ClearAllPoints()
    self.rightLine:ClearAllPoints()
    self.leftLine:SetPoint("LEFT", self.frame, "LEFT", 0, 0)
    self.rightLine:SetPoint("RIGHT", self.frame, "RIGHT", 0, 0)
    if empty then
      self.leftLine:SetPoint("RIGHT", self.frame, "CENTER", 0, 0)
      self.rightLine:SetPoint("LEFT", self.frame, "CENTER", 0, 0)
    else
      self.leftLine:SetPoint("RIGHT", self.text, "LEFT", -6, 0)
      self.rightLine:SetPoint("LEFT", self.text, "RIGHT", 6, 0)
    end
  end

  ---@return any
  local function headingGetText(self)
    activeRecord(self, "WidgetKit Heading:GetText", 3)
    local text = self.text:GetText()
    if type(text) == "nil" then
      return ""
    end
    return text
  end

  ---@param disabled boolean? `true` greys the text out; the widget takes no input
  local function headingSetDisabled(self, disabled)
    colourLabel(self.text, readDisabled(self, disabled, "WidgetKit Heading:SetDisabled", 3))
  end

  local function headingOnAcquire(self)
    self.frame:SetSize(200, 18)
    self:SetFullWidth(true)
    colourLabel(self.text, false)
    headingSetText(self, "")
  end

  local function headingOnRelease(self)
    showText(self, "text", "", false)
  end

  ---@return table widget
  function BASE_CONSTRUCTORS.Heading()
    local frame = createFrame("Frame", releaseParent())
    local text = frame:CreateFontString(nil, "OVERLAY")
    text:SetFontObject("GameFontNormal")
    text:SetPoint("CENTER", frame, "CENTER", 0, 0)
    local leftLine = frame:CreateTexture(nil, "BACKGROUND")
    leftLine:SetHeight(1)
    leftLine:SetColorTexture(0.6, 0.6, 0.6, 0.6)
    local rightLine = frame:CreateTexture(nil, "BACKGROUND")
    rightLine:SetHeight(1)
    rightLine:SetColorTexture(0.6, 0.6, 0.6, 0.6)
    return {
      frame = frame,
      text = text,
      leftLine = leftLine,
      rightLine = rightLine,
      OnAcquire = headingOnAcquire,
      OnRelease = headingOnRelease,
      SetText = headingSetText,
      GetText = headingGetText,
      SetDisabled = headingSetDisabled,
    }
  end
end

-- Widget: Spacer -------------------------------------------------------------

do
  local function spacerOnAcquire(self)
    self.frame:SetSize(10, 8)
  end

  ---@return table widget
  function BASE_CONSTRUCTORS.Spacer()
    return {
      frame = createFrame("Frame", releaseParent()),
      OnAcquire = spacerOnAcquire,
    }
  end
end

-- Commit ---------------------------------------------------------------------

registerBuiltInType("Label", BASE_CONSTRUCTORS.Label, 3)
registerBuiltInType("Heading", BASE_CONSTRUCTORS.Heading, 3)
registerBuiltInType("Spacer", BASE_CONSTRUCTORS.Spacer, 1)
rawset(rawget(state, "parts"), PART_NAME, {
  revision = PART_REVISION,
  bind = bind,
})

return WidgetKit
