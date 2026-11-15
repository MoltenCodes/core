-- MoltenCodes WidgetKit part CheckBox
--
-- The `CheckBox` type: a two- or three-state check box.
--
-- Needs the WidgetKit core. See `docs/API.md`, "Parts", and
-- `docs/INTERNALS.md`, "Parts", for how a part joins the core.

-- Constants ------------------------------------------------------------------

local PART_NAME = "CheckBox"
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
  error("MoltenCodes WidgetKit part CheckBox requires WidgetKit API 1 to be loaded first", 2)
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
local createFrame
local isActive
local newLabelMethods
local readDisabled
local refuseSecret
local releaseParent
local showText
local registerBuiltInType
local DISABLED_BLUE
local DISABLED_GREEN
local DISABLED_RED
local LABEL_BLUE
local LABEL_GREEN
local LABEL_RED
local TEXT_BLUE
local TEXT_GREEN
local TEXT_RED

---Assign the core helpers this part uses.
---@param helpers table the core's `state.helpers`
local function bind(helpers)
  activeRecord = helpers.activeRecord
  createFrame = helpers.createFrame
  isActive = helpers.isActive
  newLabelMethods = helpers.newLabelMethods
  readDisabled = helpers.readDisabled
  refuseSecret = helpers.refuseSecret
  releaseParent = helpers.releaseParent
  showText = helpers.showText
  registerBuiltInType = helpers.registerBuiltInType
  local colours = helpers.colours
  local label, text, disabled = colours.label, colours.text, colours.disabled
  DISABLED_BLUE = disabled[3]
  DISABLED_GREEN = disabled[2]
  DISABLED_RED = disabled[1]
  LABEL_BLUE = label[3]
  LABEL_GREEN = label[2]
  LABEL_RED = label[1]
  TEXT_BLUE = text[3]
  TEXT_GREEN = text[2]
  TEXT_RED = text[1]
end

bind(rawget(state, "helpers"))

-- This part's constructors by type name, each defined in its own `do` block
-- below so that the helpers of one type are not visible to the others.
local BASE_CONSTRUCTORS = {}

-- Widget: CheckBox -----------------------------------------------------------

do
  local checkBoxSetLabel, checkBoxGetLabel = newLabelMethods("CheckBox")

  ---Show `value` on the check button: checked, unchecked, or the third state.
  ---@param widget table
  local function checkBoxShowValue(widget)
    local value = widget._value
    widget.button:SetChecked(value == true)
    widget.indeterminate:SetShown(value == nil and widget._triState)
  end

  ---@param value boolean? `nil` is the third state, and means `false` without it
  local function checkBoxSetValue(self, value)
    activeRecord(self, "WidgetKit CheckBox:SetValue", 3)
    refuseSecret(value, "WidgetKit CheckBox:SetValue value", 3)
    if type(value) ~= "nil" and type(value) ~= "boolean" then
      error("WidgetKit CheckBox:SetValue value must be a boolean or nil", 2)
    end
    if type(value) == "nil" and not self._triState then
      value = false
    end
    self._value = value
    checkBoxShowValue(self)
  end

  ---@return boolean?
  local function checkBoxGetValue(self)
    activeRecord(self, "WidgetKit CheckBox:GetValue", 3)
    return self._value
  end

  ---@param enabled boolean
  local function checkBoxSetTriState(self, enabled)
    activeRecord(self, "WidgetKit CheckBox:SetTriState", 3)
    refuseSecret(enabled, "WidgetKit CheckBox:SetTriState enabled", 3)
    if type(enabled) ~= "boolean" then
      error("WidgetKit CheckBox:SetTriState enabled must be a boolean", 2)
    end
    self._triState = enabled
    if not enabled and self._value == nil then
      self._value = false
    end
    checkBoxShowValue(self)
  end

  ---@param disabled boolean? `true` greys the widget out and ignores input
  local function checkBoxSetDisabled(self, disabled)
    disabled = readDisabled(self, disabled, "WidgetKit CheckBox:SetDisabled", 3)
    self.button:SetEnabled(not disabled)
    if disabled then
      self.labelText:SetTextColor(DISABLED_RED, DISABLED_GREEN, DISABLED_BLUE)
    else
      self.labelText:SetTextColor(TEXT_RED, TEXT_GREEN, TEXT_BLUE)
    end
  end

  local function checkBoxOnAcquire(self)
    self.frame:SetSize(200, 24)
    self._value = false
    self._triState = false
    self.button:SetEnabled(true)
    self.labelText:SetText("")
    self.labelText:SetTextColor(TEXT_RED, TEXT_GREEN, TEXT_BLUE)
    checkBoxShowValue(self)
  end

  local function checkBoxOnRelease(self)
    showText(self, "labelText", "", false)
    self._value = false
  end

  ---@return table widget
  function BASE_CONSTRUCTORS.CheckBox()
    local frame = createFrame("Frame", releaseParent())
    local button = createFrame("CheckButton", frame, "UICheckButtonTemplate")
    button:SetSize(24, 24)
    button:SetPoint("LEFT", frame, "LEFT", 0, 0)

    local indeterminate = button:CreateTexture(nil, "OVERLAY")
    indeterminate:SetSize(10, 10)
    indeterminate:SetPoint("CENTER", button, "CENTER", 0, 0)
    indeterminate:SetColorTexture(LABEL_RED, LABEL_GREEN, LABEL_BLUE, 1)
    indeterminate:Hide()

    local labelText = frame:CreateFontString(nil, "OVERLAY")
    labelText:SetFontObject("GameFontHighlight")
    labelText:SetJustifyH("LEFT")
    labelText:SetPoint("LEFT", button, "RIGHT", 4, 0)
    labelText:SetPoint("RIGHT", frame, "RIGHT", 0, 0)

    local widget = {
      frame = frame,
      button = button,
      indeterminate = indeterminate,
      labelText = labelText,
      _value = false,
      _triState = false,
      OnAcquire = checkBoxOnAcquire,
      OnRelease = checkBoxOnRelease,
      SetValue = checkBoxSetValue,
      GetValue = checkBoxGetValue,
      SetTriState = checkBoxSetTriState,
      SetLabel = checkBoxSetLabel,
      GetLabel = checkBoxGetLabel,
      SetDisabled = checkBoxSetDisabled,
    }

    button:SetScript("OnClick", function()
      if not isActive(widget) then
        return
      end
      -- The cycle is unchecked, checked, then (with three states) the third.
      local value = widget._value
      if value == false then
        value = true
      elseif value == true and widget._triState then
        value = nil
      else
        value = false
      end
      widget._value = value
      checkBoxShowValue(widget)
      widget:Fire("OnValueChanged", value)
    end)
    return widget
  end
end

-- Commit ---------------------------------------------------------------------

registerBuiltInType("CheckBox", BASE_CONSTRUCTORS.CheckBox, 4)
rawset(rawget(state, "parts"), PART_NAME, {
  revision = PART_REVISION,
  bind = bind,
})

return WidgetKit
