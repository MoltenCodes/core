-- MoltenCodes WidgetKit part EditBox
--
-- The `EditBox` type: single- and multi-line text entry.
--
-- Needs the WidgetKit core. See `docs/API.md`, "Parts", and
-- `docs/INTERNALS.md`, "Parts", for how a part joins the core.

-- Constants ------------------------------------------------------------------

local PART_NAME = "EditBox"
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
  error("MoltenCodes WidgetKit part EditBox requires WidgetKit API 1 to be loaded first", 2)
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
local isActive
local isSecret
local newLabelMethods
local newTopLabel
local readDisabled
local refuseSecret
local releaseParent
local showText
local validatePositiveInteger
local registerBuiltInType

---Assign the core helpers this part uses.
---@param helpers table the core's `state.helpers`
local function bind(helpers)
  activeRecord = helpers.activeRecord
  checkText = helpers.checkText
  colourLabel = helpers.colourLabel
  createFrame = helpers.createFrame
  isActive = helpers.isActive
  isSecret = helpers.isSecret
  newLabelMethods = helpers.newLabelMethods
  newTopLabel = helpers.newTopLabel
  readDisabled = helpers.readDisabled
  refuseSecret = helpers.refuseSecret
  releaseParent = helpers.releaseParent
  showText = helpers.showText
  validatePositiveInteger = helpers.validatePositiveInteger
  registerBuiltInType = helpers.registerBuiltInType
end

bind(rawget(state, "helpers"))

---A global string the client localises, or `fallback` outside the client.
---@param name string
---@param fallback string
---@return string
local function clientText(name, fallback)
  -- selene: allow(global_usage)
  local value = rawget(_G, name)
  if type(value) == "string" and not isSecret(value) then
    return value
  end
  return fallback
end

-- This part's constructors by type name, each defined in its own `do` block
-- below so that the helpers of one type are not visible to the others.
local BASE_CONSTRUCTORS = {}

-- Widget: EditBox ------------------------------------------------------------

do
  local editBoxSetLabel, editBoxGetLabel = newLabelMethods("EditBox")

  local EDIT_LINE_HEIGHT = 14

  ---The edit box currently in use: the multi-line one or the single-line one.
  ---@param widget table
  ---@return WidgetKit.Frame
  local function activeEditBox(widget)
    if widget._multiLine then
      return widget.multiBox
    end
    return widget.singleBox
  end

  ---Size the widget for its mode and line count.
  ---@param widget table
  local function editBoxUpdateHeight(widget)
    if widget._multiLine then
      local boxHeight = widget._lines * EDIT_LINE_HEIGHT + 8
      widget.multiBox:SetHeight(boxHeight)
      widget.frame:SetHeight(18 + boxHeight + 28)
    else
      widget.frame:SetHeight(44)
    end
  end

  ---@param text any
  ---@param options WidgetKit.TextOptions?
  local function editBoxSetText(self, text, options)
    activeRecord(self, "WidgetKit EditBox:SetText", 3)
    -- The client's edit box refuses a secret from addon code, `allowSecret`
    -- or not: `SetText` takes one only during untainted execution (measured
    -- on Retail 12.1.0 b69933). It is refused here, at the caller's line.
    if isSecret(text) then
      error(
        "WidgetKit EditBox:SetText text must not be a secret value:"
          .. " the client's edit box takes one only from untainted code",
        2
      )
    end
    local value = checkText(self, text, options, "WidgetKit EditBox:SetText", 3)
    self._settingText = true
    activeEditBox(self):SetText(value)
    self._settingText = false
  end

  ---@return any
  local function editBoxGetText(self)
    activeRecord(self, "WidgetKit EditBox:GetText", 3)
    -- The client's edit box answers `""` when empty (measured on Retail
    -- 12.1.0 b69933); a client that answers `nil` gets the same promise.
    local text = activeEditBox(self):GetText()
    if type(text) == "nil" then
      return ""
    end
    return text
  end

  ---@param multiLine boolean
  ---@param lines integer? visible lines of a multi-line box; default 4
  local function editBoxSetMultiLine(self, multiLine, lines)
    activeRecord(self, "WidgetKit EditBox:SetMultiLine", 3)
    refuseSecret(multiLine, "WidgetKit EditBox:SetMultiLine multiLine", 3)
    if type(multiLine) ~= "boolean" then
      error("WidgetKit EditBox:SetMultiLine multiLine must be a boolean", 2)
    end
    if type(lines) ~= "nil" then
      validatePositiveInteger(lines, "WidgetKit EditBox:SetMultiLine lines", 3)
    end
    local text = activeEditBox(self):GetText()
    self._multiLine = multiLine
    self._lines = lines or 4
    self.singleBox:SetShown(not multiLine)
    self.multiBox:SetShown(multiLine)
    self.acceptButton:SetShown(multiLine)
    self._settingText = true
    activeEditBox(self):SetText(text)
    self._settingText = false
    editBoxUpdateHeight(self)
  end

  ---@return boolean
  local function editBoxIsMultiLine(self)
    activeRecord(self, "WidgetKit EditBox:IsMultiLine", 3)
    return self._multiLine == true
  end

  ---@param letters integer `0` for no limit
  local function editBoxSetMaxLetters(self, letters)
    activeRecord(self, "WidgetKit EditBox:SetMaxLetters", 3)
    refuseSecret(letters, "WidgetKit EditBox:SetMaxLetters letters", 3)
    if letters ~= 0 then
      validatePositiveInteger(letters, "WidgetKit EditBox:SetMaxLetters letters", 3)
    end
    self.singleBox:SetMaxLetters(letters)
    self.multiBox:SetMaxLetters(letters)
  end

  ---@param disabled boolean? `true` greys the widget out and ignores input
  local function editBoxSetDisabled(self, disabled)
    disabled = readDisabled(self, disabled, "WidgetKit EditBox:SetDisabled", 3)
    self.singleBox:SetEnabled(not disabled)
    self.multiBox:SetEnabled(not disabled)
    self.acceptButton:SetEnabled(not disabled)
    colourLabel(self.labelText, disabled)
    if disabled then
      activeEditBox(self):ClearFocus()
    end
  end

  ---Give the edit box keyboard focus and make it WidgetKit's focused widget.
  local function editBoxSetFocus(self)
    activeRecord(self, "WidgetKit EditBox:SetFocus", 3)
    WidgetKit:SetFocus(self)
    activeEditBox(self):SetFocus()
  end

  ---Called by `WidgetKit:ClearFocus` when another widget takes the focus.
  local function editBoxOnFocusLost(self)
    self.singleBox:ClearFocus()
    self.multiBox:ClearFocus()
  end

  ---Fire `OnEnterPressed` with the current text.
  ---@param widget table
  local function editBoxSubmit(widget)
    if not isActive(widget) then
      return
    end
    widget:Fire("OnEnterPressed", activeEditBox(widget):GetText())
  end

  local function editBoxOnAcquire(self)
    self.frame:SetWidth(200)
    self._multiLine = false
    self._lines = 4
    self._settingText = true
    self.singleBox:SetText("")
    self.multiBox:SetText("")
    self._settingText = false
    self.singleBox:SetMaxLetters(0)
    self.multiBox:SetMaxLetters(0)
    self.singleBox:SetEnabled(true)
    self.multiBox:SetEnabled(true)
    self.acceptButton:SetEnabled(true)
    self.singleBox:Show()
    self.multiBox:Hide()
    self.acceptButton:Hide()
    self.labelText:SetText("")
    colourLabel(self.labelText, false)
    editBoxUpdateHeight(self)
  end

  ---Clear both boxes, so a pooled edit box never carries a secret into its next
  ---use.
  local function editBoxOnRelease(self)
    self._settingText = true
    self.singleBox:SetText("")
    self.multiBox:SetText("")
    self._settingText = false
    self.singleBox:ClearFocus()
    self.multiBox:ClearFocus()
    showText(self, "labelText", "", false)
  end

  ---@return table widget
  function BASE_CONSTRUCTORS.EditBox()
    local frame = createFrame("Frame", releaseParent())
    local labelText = newTopLabel(frame)

    local singleBox = createFrame("EditBox", frame, "InputBoxTemplate")
    singleBox:SetAutoFocus(false)
    singleBox:SetFontObject("ChatFontNormal")
    singleBox:SetHeight(20)
    singleBox:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -20)
    singleBox:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -20)

    local multiBox = createFrame("EditBox", frame)
    multiBox:SetMultiLine(true)
    multiBox:SetAutoFocus(false)
    multiBox:SetFontObject("ChatFontNormal")
    multiBox:SetTextInsets(4, 4, 4, 4)
    multiBox:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -18)
    multiBox:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -18)
    local multiBackground = multiBox:CreateTexture(nil, "BACKGROUND")
    multiBackground:SetAllPoints(multiBox)
    multiBackground:SetColorTexture(0, 0, 0, 0.5)
    multiBox:Hide()

    local acceptButton = createFrame("Button", frame, "UIPanelButtonTemplate")
    acceptButton:SetSize(80, 22)
    acceptButton:SetPoint("TOPLEFT", multiBox, "BOTTOMLEFT", 0, -3)
    acceptButton:SetText(clientText("ACCEPT", "Accept"))
    acceptButton:Hide()

    local widget = {
      frame = frame,
      labelText = labelText,
      singleBox = singleBox,
      multiBox = multiBox,
      acceptButton = acceptButton,
      _multiLine = false,
      _lines = 4,
      _settingText = false,
      OnAcquire = editBoxOnAcquire,
      OnRelease = editBoxOnRelease,
      OnFocusLost = editBoxOnFocusLost,
      SetText = editBoxSetText,
      GetText = editBoxGetText,
      SetMultiLine = editBoxSetMultiLine,
      IsMultiLine = editBoxIsMultiLine,
      SetMaxLetters = editBoxSetMaxLetters,
      SetLabel = editBoxSetLabel,
      GetLabel = editBoxGetLabel,
      SetDisabled = editBoxSetDisabled,
      SetFocus = editBoxSetFocus,
    }

    local function onTextChanged(box, userInput)
      if widget._settingText or not userInput or not isActive(widget) then
        return
      end
      widget:Fire("OnTextChanged", box:GetText())
    end
    local function onEscapePressed(box)
      box:ClearFocus()
      if isActive(widget) then
        widget:Fire("OnEscapePressed")
      end
    end
    local function onFocusGained()
      if isActive(widget) then
        WidgetKit:SetFocus(widget)
      end
    end
    local function onFocusLost()
      if rawget(state, "focus") == widget then
        rawset(state, "focus", false)
      end
    end

    singleBox:SetScript("OnEnterPressed", function(box)
      box:ClearFocus()
      editBoxSubmit(widget)
    end)
    for _, box in ipairs({ singleBox, multiBox }) do
      box:SetScript("OnTextChanged", onTextChanged)
      box:SetScript("OnEscapePressed", onEscapePressed)
      box:SetScript("OnEditFocusGained", onFocusGained)
      box:SetScript("OnEditFocusLost", onFocusLost)
    end
    acceptButton:SetScript("OnClick", function()
      multiBox:ClearFocus()
      editBoxSubmit(widget)
    end)
    return widget
  end
end

-- Commit ---------------------------------------------------------------------

registerBuiltInType("EditBox", BASE_CONSTRUCTORS.EditBox, 4)
rawset(rawget(state, "parts"), PART_NAME, {
  revision = PART_REVISION,
  bind = bind,
})

return WidgetKit
