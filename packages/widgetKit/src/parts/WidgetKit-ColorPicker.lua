-- MoltenCodes WidgetKit part ColorPicker
--
-- The `ColorPicker` type: a swatch over the client colour picker.
--
-- Needs the WidgetKit core. See `docs/API.md`, "Parts", and
-- `docs/INTERNALS.md`, "Parts", for how a part joins the core.

-- Constants ------------------------------------------------------------------

local PART_NAME = "ColorPicker"
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
  error("MoltenCodes WidgetKit part ColorPicker requires WidgetKit API 1 to be loaded first", 2)
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
local canTouchFrame
local createFrame
local isActive
local isSecret
local newLabelMethods
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
  canTouchFrame = helpers.canTouchFrame
  createFrame = helpers.createFrame
  isActive = helpers.isActive
  isSecret = helpers.isSecret
  newLabelMethods = helpers.newLabelMethods
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

---Read a global from the host at call time, or `nil`: host APIs and named
---client frames are reachable only through the global table, and reading at
---call time lets a facility that appears later be used at once.
---@param name string
---@return any
local function readGlobal(name)
  -- World of Warcraft client APIs and named frames exist only in the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

-- This part's constructors by type name, each defined in its own `do` block
-- below so that the helpers of one type are not visible to the others.
local BASE_CONSTRUCTORS = {}

-- Widget: ColorPicker --------------------------------------------------------

do --
  local colorPickerSetLabel, colorPickerGetLabel = newLabelMethods("ColorPicker")

  -- A swatch. A click opens the client's `ColorPickerFrame` through its
  -- `SetupColorPickerAndShow` method when the client has one and the frame may
  -- be touched; WidgetKit writes no field onto that frame. Without it, a click
  -- fires `OnValueChanged` with the current colour.

  ---Show the stored colour on the swatch.
  ---@param widget table
  local function colorShow(widget)
    widget.swatch:SetColorTexture(widget._red, widget._green, widget._blue, widget._alpha)
  end

  ---@param red number
  ---@param green number
  ---@param blue number
  ---@param alpha number?
  local function colorSetColor(self, red, green, blue, alpha)
    activeRecord(self, "WidgetKit ColorPicker:SetColor", 3)
    validateNumber(red, "WidgetKit ColorPicker:SetColor red", 3)
    validateNumber(green, "WidgetKit ColorPicker:SetColor green", 3)
    validateNumber(blue, "WidgetKit ColorPicker:SetColor blue", 3)
    if type(alpha) ~= "nil" then
      validateNumber(alpha, "WidgetKit ColorPicker:SetColor alpha", 3)
    end
    self._red, self._green, self._blue, self._alpha = red, green, blue, alpha or 1
    colorShow(self)
  end

  ---@return number red, number green, number blue, number alpha
  local function colorGetColor(self)
    activeRecord(self, "WidgetKit ColorPicker:GetColor", 3)
    return self._red, self._green, self._blue, self._alpha
  end

  ---@param hasAlpha boolean
  local function colorSetHasAlpha(self, hasAlpha)
    activeRecord(self, "WidgetKit ColorPicker:SetHasAlpha", 3)
    refuseSecret(hasAlpha, "WidgetKit ColorPicker:SetHasAlpha hasAlpha", 3)
    if type(hasAlpha) ~= "boolean" then
      error("WidgetKit ColorPicker:SetHasAlpha hasAlpha must be a boolean", 2)
    end
    self._hasAlpha = hasAlpha
  end

  ---@param disabled boolean? `true` greys the widget out and ignores input
  local function colorSetDisabled(self, disabled)
    disabled = readDisabled(self, disabled, "WidgetKit ColorPicker:SetDisabled", 3)
    self._disabled = disabled
    self.button:SetEnabled(not disabled)
    if disabled then
      self.labelText:SetTextColor(DISABLED_RED, DISABLED_GREEN, DISABLED_BLUE)
    else
      self.labelText:SetTextColor(TEXT_RED, TEXT_GREEN, TEXT_BLUE)
    end
  end

  ---Store a colour chosen in the client picker and fire.
  ---@param widget table
  ---@param red number
  ---@param green number
  ---@param blue number
  ---@param alpha number
  local function colorChosen(widget, red, green, blue, alpha)
    if not isActive(widget) then
      return
    end
    if isSecret(red) or isSecret(green) or isSecret(blue) or isSecret(alpha) then
      return
    end
    widget._red, widget._green, widget._blue, widget._alpha = red, green, blue, alpha
    colorShow(widget)
    widget:Fire("OnValueChanged", red, green, blue, alpha)
  end

  ---Open the client colour picker, or fire with the current colour without one.
  ---@return boolean opened `true` when the client picker was opened
  local function colorOpenPicker(self)
    activeRecord(self, "WidgetKit ColorPicker:OpenPicker", 3)
    if self._disabled then
      return false
    end
    local picker = readGlobal("ColorPickerFrame")
    local setup = type(picker) == "table" and picker.SetupColorPickerAndShow or nil
    if type(setup) ~= "function" or not canTouchFrame(picker) then
      self:Fire("OnValueChanged", self._red, self._green, self._blue, self._alpha)
      return false
    end
    local info = self._pickerInfo
    info.r, info.g, info.b = self._red, self._green, self._blue
    info.opacity = self._alpha
    info.hasOpacity = self._hasAlpha
    self._previousRed, self._previousGreen = self._red, self._green
    self._previousBlue, self._previousAlpha = self._blue, self._alpha
    -- The client picker calls back later; it only reaches this use of the
    -- widget, never a later one after a release.
    self._pickerSession = self._session
    setup(picker, info)
    return true
  end

  local function colorOnAcquire(self)
    self.frame:SetSize(200, 24)
    self._red, self._green, self._blue, self._alpha = 1, 1, 1, 1
    self._hasAlpha = false
    self._disabled = false
    self.button:SetEnabled(true)
    self.labelText:SetText("")
    self.labelText:SetTextColor(TEXT_RED, TEXT_GREEN, TEXT_BLUE)
    colorShow(self)
  end

  local function colorOnRelease(self)
    showText(self, "labelText", "", false)
    -- Disarm the client picker's callbacks for this use of the widget.
    self._session = self._session + 1
  end

  ---@return table widget
  function BASE_CONSTRUCTORS.ColorPicker()
    local frame = createFrame("Frame", releaseParent())
    local button = createFrame("Button", frame)
    button:SetSize(20, 20)
    button:SetPoint("LEFT", frame, "LEFT", 2, 0)
    local border = button:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints(button)
    border:SetColorTexture(0.8, 0.8, 0.8, 1)
    local swatch = button:CreateTexture(nil, "OVERLAY")
    swatch:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -2)
    swatch:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 2)

    local labelText = frame:CreateFontString(nil, "OVERLAY")
    labelText:SetFontObject("GameFontHighlight")
    labelText:SetJustifyH("LEFT")
    labelText:SetPoint("LEFT", button, "RIGHT", 6, 0)
    labelText:SetPoint("RIGHT", frame, "RIGHT", 0, 0)

    local widget = {
      frame = frame,
      button = button,
      swatch = swatch,
      labelText = labelText,
      _red = 1,
      _green = 1,
      _blue = 1,
      _alpha = 1,
      _hasAlpha = false,
      _session = 0,
      _pickerSession = -1,
      _disabled = false,
      OnAcquire = colorOnAcquire,
      OnRelease = colorOnRelease,
      SetColor = colorSetColor,
      GetColor = colorGetColor,
      SetHasAlpha = colorSetHasAlpha,
      OpenPicker = colorOpenPicker,
      SetLabel = colorPickerSetLabel,
      GetLabel = colorPickerGetLabel,
      SetDisabled = colorSetDisabled,
    }

    ---Whether the client picker was opened by the current use of the widget.
    local function pickerIsCurrent()
      return isActive(widget) and widget._pickerSession == widget._session
    end

    ---Read the colour the client picker shows now. Without alpha, the
    ---stored alpha is kept.
    local function readPicker()
      if not pickerIsCurrent() then
        return
      end
      local picker = readGlobal("ColorPickerFrame")
      if type(picker) ~= "table" or type(picker.GetColorRGB) ~= "function" then
        return
      end
      local red, green, blue = picker:GetColorRGB()
      local alpha = widget._alpha
      if widget._hasAlpha and type(picker.GetColorAlpha) == "function" then
        alpha = picker:GetColorAlpha()
      end
      colorChosen(widget, red, green, blue, alpha)
    end

    -- One info table per widget, built once: `SetupColorPickerAndShow` reads
    -- it, and opening the picker again only rewrites its fields.
    widget._pickerInfo = {
      swatchFunc = readPicker,
      opacityFunc = readPicker,
      cancelFunc = function()
        if not pickerIsCurrent() then
          return
        end
        colorChosen(
          widget,
          widget._previousRed,
          widget._previousGreen,
          widget._previousBlue,
          widget._previousAlpha
        )
      end,
    }

    button:SetScript("OnClick", function()
      if isActive(widget) then
        widget:OpenPicker()
      end
    end)
    return widget
  end
end

-- Commit ---------------------------------------------------------------------

registerBuiltInType("ColorPicker", BASE_CONSTRUCTORS.ColorPicker, 4)
rawset(rawget(state, "parts"), PART_NAME, {
  revision = PART_REVISION,
  bind = bind,
})

return WidgetKit
