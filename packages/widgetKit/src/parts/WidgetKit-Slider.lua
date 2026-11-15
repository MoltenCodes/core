-- MoltenCodes WidgetKit part Slider
--
-- The `Slider` type: a slider with a value box.
--
-- Needs the WidgetKit core. See `docs/API.md`, "Parts", and
-- `docs/INTERNALS.md`, "Parts", for how a part joins the core.

-- Constants ------------------------------------------------------------------

local PART_NAME = "Slider"
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
  error("MoltenCodes WidgetKit part Slider requires WidgetKit API 1 to be loaded first", 2)
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
local colourLabel
local createFrame
local isActive
local isSecret
local secretProbe
local newLabelMethods
local newTopLabel
local readDisabled
local refuseSecret
local releaseParent
local showText
local validateNumber
local registerBuiltInType

---Assign the core helpers this part uses.
---@param helpers table the core's `state.helpers`
local function bind(helpers)
  activeRecord = helpers.activeRecord
  colourLabel = helpers.colourLabel
  createFrame = helpers.createFrame
  isActive = helpers.isActive
  isSecret = helpers.isSecret
  secretProbe = helpers.secretProbe
  newLabelMethods = helpers.newLabelMethods
  newTopLabel = helpers.newTopLabel
  readDisabled = helpers.readDisabled
  refuseSecret = helpers.refuseSecret
  releaseParent = helpers.releaseParent
  showText = helpers.showText
  validateNumber = helpers.validateNumber
  registerBuiltInType = helpers.registerBuiltInType
end

bind(rawget(state, "helpers"))

-- This part's constructors by type name, each defined in its own `do` block
-- below so that the helpers of one type are not visible to the others.
local BASE_CONSTRUCTORS = {}

-- Widget: Slider -------------------------------------------------------------

do
  local sliderSetLabel, sliderGetLabel = newLabelMethods("Slider")

  ---Snap `value` to the widget's step and clamp it to its range.
  ---@param widget table
  ---@param value number
  ---@return number
  local function sliderSnap(widget, value)
    local minimum, maximum, step = widget._minimum, widget._maximum, widget._step
    if step > 0 then
      value = minimum + math.floor((value - minimum) / step + 0.5) * step
    end
    if value < minimum then
      value = minimum
    elseif value > maximum then
      value = maximum
    end
    return value
  end

  ---Show the value in the edit box: a percentage for percent sliders.
  ---
  ---The text is formatted only when the value or the percent mode changed
  ---since the last time: the widget keeps the value and the mode it formatted
  ---and the text it got. The box is written every time, because the user may
  ---have typed into it.
  ---@param widget table
  local function sliderShowValue(widget)
    local value = widget._value
    local isPercent = widget._isPercent
    local text = widget._shownText
    if value ~= widget._shownValue or isPercent ~= widget._shownPercent then
      if isPercent then
        text = string.format("%d%%", math.floor(value * 100 + 0.5))
      else
        text = string.format("%.10g", value)
      end
      widget._shownValue, widget._shownPercent, widget._shownText = value, isPercent, text
    end
    widget.valueBox:SetText(text)
  end

  ---Give the slider frame its range and step, only where they changed: the
  ---widget's `_minimum`, `_maximum` and `_step` are what the frame holds.
  ---@param widget table
  ---@param minimum number
  ---@param maximum number
  ---@param step number
  local function sliderApplyRange(widget, minimum, maximum, step)
    if minimum ~= widget._minimum or maximum ~= widget._maximum then
      widget._minimum, widget._maximum = minimum, maximum
      widget._updating = true
      widget.slider:SetMinMaxValues(minimum, maximum)
      widget._updating = false
    end
    if step ~= widget._step then
      widget._step = step
      widget._updating = true
      widget.slider:SetValueStep(step > 0 and step or 0)
      widget._updating = false
    end
  end

  ---Write the range labels, only where they changed.
  ---@param widget table
  ---@param minimum number
  ---@param maximum number
  local function sliderShowRange(widget, minimum, maximum)
    if minimum ~= widget._shownMinimum then
      widget._shownMinimum = minimum
      widget.lowText:SetText(string.format("%.10g", minimum))
    end
    if maximum ~= widget._shownMaximum then
      widget._shownMaximum = maximum
      widget.highText:SetText(string.format("%.10g", maximum))
    end
  end

  ---Store `value` and move the slider without firing `OnValueChanged`.
  ---@param widget table
  ---@param value number
  local function sliderStore(widget, value)
    widget._value = value
    widget._updating = true
    widget.slider:SetValue(value)
    widget._updating = false
    sliderShowValue(widget)
  end

  ---@param minimum number
  ---@param maximum number
  ---@param step number? `0` or `nil` for no snapping
  local function sliderSetSliderValues(self, minimum, maximum, step)
    activeRecord(self, "WidgetKit Slider:SetSliderValues", 3)
    -- `validateNumber` three times, written out with the probe resolved once:
    -- the same checks in the same order, with the same messages.
    local probe = secretProbe()
    if probe ~= nil and probe(minimum) == true then
      error("WidgetKit Slider:SetSliderValues minimum must not be a secret value", 2)
    end
    if type(minimum) ~= "number" or minimum ~= minimum then
      error("WidgetKit Slider:SetSliderValues minimum must be a number", 2)
    end
    if probe ~= nil and probe(maximum) == true then
      error("WidgetKit Slider:SetSliderValues maximum must not be a secret value", 2)
    end
    if type(maximum) ~= "number" or maximum ~= maximum then
      error("WidgetKit Slider:SetSliderValues maximum must be a number", 2)
    end
    if minimum > maximum then
      error("WidgetKit Slider:SetSliderValues minimum must not be greater than maximum", 2)
    end
    -- Tested with `type`, not `step or 0`: a truth test of a secret raises
    -- here, inside WidgetKit, before the secret check can refuse it.
    if type(step) == "nil" then
      step = 0
    end
    if probe ~= nil and probe(step) == true then
      error("WidgetKit Slider:SetSliderValues step must not be a secret value", 2)
    end
    if type(step) ~= "number" or step ~= step then
      error("WidgetKit Slider:SetSliderValues step must be a number", 2)
    end
    if step < 0 then
      error("WidgetKit Slider:SetSliderValues step must not be negative", 2)
    end
    sliderApplyRange(self, minimum, maximum, step)
    sliderShowRange(self, minimum, maximum)
    sliderStore(self, sliderSnap(self, self._value))
  end

  ---@param value number
  local function sliderSetValue(self, value)
    activeRecord(self, "WidgetKit Slider:SetValue", 3)
    validateNumber(value, "WidgetKit Slider:SetValue value", 3)
    sliderStore(self, sliderSnap(self, value))
  end

  ---@return number
  local function sliderGetValue(self)
    activeRecord(self, "WidgetKit Slider:GetValue", 3)
    return self._value
  end

  ---@param isPercent boolean
  local function sliderSetIsPercent(self, isPercent)
    activeRecord(self, "WidgetKit Slider:SetIsPercent", 3)
    refuseSecret(isPercent, "WidgetKit Slider:SetIsPercent isPercent", 3)
    if type(isPercent) ~= "boolean" then
      error("WidgetKit Slider:SetIsPercent isPercent must be a boolean", 2)
    end
    self._isPercent = isPercent
    sliderShowValue(self)
  end

  ---@param disabled boolean? `true` greys the widget out and ignores input
  local function sliderSetDisabled(self, disabled)
    disabled = readDisabled(self, disabled, "WidgetKit Slider:SetDisabled", 3)
    self._disabled = disabled
    self.slider:SetEnabled(not disabled)
    self.valueBox:SetEnabled(not disabled)
    colourLabel(self.labelText, disabled)
  end

  ---Accept a user change: snap, store, and fire when it moved.
  ---@param widget table
  ---@param value number
  local function sliderAccept(widget, value)
    value = sliderSnap(widget, value)
    local changed = value ~= widget._value
    sliderStore(widget, value)
    if changed then
      widget:Fire("OnValueChanged", value)
    end
  end

  local function sliderOnAcquire(self)
    self.frame:SetSize(200, 50)
    sliderApplyRange(self, 0, 100, 1)
    self._value = 0
    self._isPercent = false
    -- Enabled and coloured again only when the last use disabled it: only
    -- `SetDisabled` changes either.
    if self._disabled then
      self._disabled = false
      self.slider:SetEnabled(true)
      self.valueBox:SetEnabled(true)
      colourLabel(self.labelText, false)
    end
    self.labelText:SetText("")
    sliderShowRange(self, 0, 100)
    -- `sliderStore(self, 0)` with the text `sliderShowValue` would format for
    -- 0 on a slider that is not a percent one, written out: acquire is hot.
    self._value = 0
    self._updating = true
    self.slider:SetValue(0)
    self._updating = false
    self._shownValue, self._shownPercent, self._shownText = 0, false, "0"
    self.valueBox:SetText("0")
  end

  local function sliderOnRelease(self)
    showText(self, "labelText", "", false)
    self.valueBox:ClearFocus()
  end

  ---@return table widget
  function BASE_CONSTRUCTORS.Slider()
    local frame = createFrame("Frame", releaseParent())
    local labelText = newTopLabel(frame)
    -- Enabled colours from the start; afterwards only `SetDisabled` and the
    -- acquire after a disabled use change them.
    colourLabel(labelText, false)

    local slider = createFrame("Slider", frame)
    slider:SetOrientation("HORIZONTAL")
    slider:SetHeight(16)
    slider:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -18)
    slider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -18)
    if type(slider.SetObeyStepOnDrag) == "function" then
      slider:SetObeyStepOnDrag(true)
    end
    slider:EnableMouseWheel(false)
    -- The range and step `_minimum`, `_maximum` and `_step` start at, so
    -- `sliderApplyRange` can tell the frame already holds them.
    slider:SetMinMaxValues(0, 100)
    slider:SetValueStep(1)
    local track = slider:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints(slider)
    track:SetColorTexture(0, 0, 0, 0.5)
    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(0.8, 0.8, 0.8, 1)
    thumb:SetSize(10, 16)
    slider:SetThumbTexture(thumb)

    local lowText = frame:CreateFontString(nil, "OVERLAY")
    lowText:SetFontObject("GameFontHighlightSmall")
    lowText:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 0, -2)
    local highText = frame:CreateFontString(nil, "OVERLAY")
    highText:SetFontObject("GameFontHighlightSmall")
    highText:SetPoint("TOPRIGHT", slider, "BOTTOMRIGHT", 0, -2)

    local valueBox = createFrame("EditBox", frame, "InputBoxTemplate")
    valueBox:SetSize(70, 14)
    valueBox:SetPoint("TOP", slider, "BOTTOM", 0, -2)
    valueBox:SetAutoFocus(false)
    valueBox:SetFontObject("GameFontHighlightSmall")
    valueBox:SetJustifyH("CENTER")

    local widget = {
      frame = frame,
      labelText = labelText,
      slider = slider,
      valueBox = valueBox,
      lowText = lowText,
      highText = highText,
      _minimum = 0,
      _maximum = 100,
      _step = 1,
      _value = 0,
      _isPercent = false,
      _updating = false,
      _disabled = false,
      -- What the value box and the range labels show, and what they were
      -- formatted from (`sliderShowValue`, `sliderShowRange`).
      _shownValue = 0,
      _shownPercent = false,
      _shownText = "0",
      _shownMinimum = false,
      _shownMaximum = false,
      OnAcquire = sliderOnAcquire,
      OnRelease = sliderOnRelease,
      SetSliderValues = sliderSetSliderValues,
      SetValue = sliderSetValue,
      GetValue = sliderGetValue,
      SetIsPercent = sliderSetIsPercent,
      SetLabel = sliderSetLabel,
      GetLabel = sliderGetLabel,
      SetDisabled = sliderSetDisabled,
    }

    slider:SetScript("OnValueChanged", function(_, value)
      if widget._updating or not isActive(widget) then
        return
      end
      sliderAccept(widget, value)
    end)
    valueBox:SetScript("OnEnterPressed", function()
      valueBox:ClearFocus()
      if not isActive(widget) then
        return
      end
      local text = valueBox:GetText()
      if isSecret(text) then
        sliderShowValue(widget)
        return
      end
      local number = tonumber((text:gsub("%%", "")))
      if number == nil then
        sliderShowValue(widget)
        return
      end
      if widget._isPercent then
        number = number / 100
      end
      sliderAccept(widget, number)
    end)
    valueBox:SetScript("OnEscapePressed", function()
      valueBox:ClearFocus()
      if isActive(widget) then
        sliderShowValue(widget)
      end
    end)
    return widget
  end
end

-- Commit ---------------------------------------------------------------------

registerBuiltInType("Slider", BASE_CONSTRUCTORS.Slider, 4)
rawset(rawget(state, "parts"), PART_NAME, {
  revision = PART_REVISION,
  bind = bind,
})

return WidgetKit
