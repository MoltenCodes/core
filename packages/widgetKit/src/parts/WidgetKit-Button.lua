-- MoltenCodes WidgetKit part Button
--
-- The `Button` type: a push button that can capture a key.
--
-- Needs the WidgetKit core. See `docs/API.md`, "Parts", and
-- `docs/INTERNALS.md`, "Parts", for how a part joins the core.

-- Constants ------------------------------------------------------------------

local PART_NAME = "Button"
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
  error("MoltenCodes WidgetKit part Button requires WidgetKit API 1 to be loaded first", 2)
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
local createFrame
local isActive
local readDisabled
local refuseSecret
local releaseParent
local showText
local registerBuiltInType

---Assign the core helpers this part uses.
---@param helpers table the core's `state.helpers`
local function bind(helpers)
  activeRecord = helpers.activeRecord
  checkText = helpers.checkText
  createFrame = helpers.createFrame
  isActive = helpers.isActive
  readDisabled = helpers.readDisabled
  refuseSecret = helpers.refuseSecret
  releaseParent = helpers.releaseParent
  showText = helpers.showText
  registerBuiltInType = helpers.registerBuiltInType
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

-- Widget: Button -------------------------------------------------------------

do
  -- Keys the client reports while a modifier alone is held; a key capture waits
  -- for the key that comes with them.
  local MODIFIER_KEYS = {
    LSHIFT = true,
    RSHIFT = true,
    LCTRL = true,
    RCTRL = true,
    LALT = true,
    RALT = true,
    LMETA = true,
    RMETA = true,
    UNKNOWN = true,
  }

  ---@param text any
  ---@param options WidgetKit.TextOptions?
  local function buttonSetText(self, text, options)
    local value, secret = checkText(self, text, options, "WidgetKit Button:SetText", 3)
    showText(self, "text", value, secret)
  end

  ---@return any
  local function buttonGetText(self)
    activeRecord(self, "WidgetKit Button:GetText", 3)
    local text = self.text:GetText()
    if type(text) == "nil" then
      return ""
    end
    return text
  end

  ---Leave key-capture mode without firing anything.
  ---@param widget table
  local function buttonStopCapture(widget)
    if widget._capturing then
      widget._capturing = false
      widget.frame:EnableKeyboard(false)
      widget.frame:UnlockHighlight()
    end
  end

  ---@param disabled boolean? `true` greys the widget out and ignores input
  local function buttonSetDisabled(self, disabled)
    disabled = readDisabled(self, disabled, "WidgetKit Button:SetDisabled", 3)
    if disabled then
      buttonStopCapture(self)
    end
    self.frame:SetEnabled(not disabled)
    -- A secret text is on a font string of its own (`showText`), which the
    -- button does not style: it takes the font the button's text has now.
    if self.text ~= self.frame then
      local fontObject = self.frame:GetFontString():GetFontObject()
      if type(fontObject) ~= "nil" then
        self.text:SetFontObject(fontObject)
      end
    end
  end

  ---Turn key capture on or off. With it on, a left click starts listening for
  ---one key (with its modifiers), `ESCAPE` cancels, and a right click fires
  ---`OnKeyCaptured` with `""` to unbind.
  ---@param enabled boolean
  local function buttonSetKeyCapture(self, enabled)
    activeRecord(self, "WidgetKit Button:SetKeyCapture", 3)
    refuseSecret(enabled, "WidgetKit Button:SetKeyCapture enabled", 3)
    if type(enabled) ~= "boolean" then
      error("WidgetKit Button:SetKeyCapture enabled must be a boolean", 2)
    end
    self._captureEnabled = enabled
    if not enabled then
      buttonStopCapture(self)
    end
  end

  ---@return boolean
  local function buttonIsCapturing(self)
    activeRecord(self, "WidgetKit Button:IsCapturing", 3)
    return self._capturing == true
  end

  ---The binding string for `key` with the modifiers held now.
  ---@param key string
  ---@return string
  local function keyWithModifiers(key)
    local prefix = ""
    local isAltKeyDown = readGlobal("IsAltKeyDown")
    local isControlKeyDown = readGlobal("IsControlKeyDown")
    local isShiftKeyDown = readGlobal("IsShiftKeyDown")
    if type(isAltKeyDown) == "function" and isAltKeyDown() then
      prefix = prefix .. "ALT-"
    end
    if type(isControlKeyDown) == "function" and isControlKeyDown() then
      prefix = prefix .. "CTRL-"
    end
    if type(isShiftKeyDown) == "function" and isShiftKeyDown() then
      prefix = prefix .. "SHIFT-"
    end
    return prefix .. key
  end

  local function buttonOnAcquire(self)
    local frame = self.frame
    frame:SetSize(200, 24)
    frame:SetText("")
    frame:SetEnabled(true)
    self._captureEnabled = false
    self._capturing = false
    frame:EnableKeyboard(false)
  end

  local function buttonOnRelease(self)
    buttonStopCapture(self)
    self._captureEnabled = false
    showText(self, "text", "", false)
  end

  ---@return table widget
  function BASE_CONSTRUCTORS.Button()
    local frame = createFrame("Button", releaseParent(), "UIPanelButtonTemplate")
    frame:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local widget = {
      frame = frame,
      -- The region showing the text: the button itself, or the font string
      -- `showText` shows a secret text on.
      text = frame,
      _captureEnabled = false,
      _capturing = false,
      OnAcquire = buttonOnAcquire,
      OnRelease = buttonOnRelease,
      SetText = buttonSetText,
      GetText = buttonGetText,
      SetDisabled = buttonSetDisabled,
      SetKeyCapture = buttonSetKeyCapture,
      IsCapturing = buttonIsCapturing,
    }

    frame:SetScript("OnClick", function(_, mouseButton)
      if not isActive(widget) then
        return
      end
      if widget._captureEnabled then
        if mouseButton == "RightButton" then
          buttonStopCapture(widget)
          widget:Fire("OnKeyCaptured", "")
          return
        end
        if not widget._capturing then
          widget._capturing = true
          frame:EnableKeyboard(true)
          frame:LockHighlight()
        end
        return
      end
      widget:Fire("OnClick", mouseButton)
    end)
    frame:SetScript("OnKeyDown", function(_, key)
      if not widget._capturing or not isActive(widget) then
        return
      end
      if MODIFIER_KEYS[key] then
        return
      end
      buttonStopCapture(widget)
      if key == "ESCAPE" then
        widget:Fire("OnKeyCaptureCancelled")
        return
      end
      widget:Fire("OnKeyCaptured", keyWithModifiers(key))
    end)
    return widget
  end
end

-- Commit ---------------------------------------------------------------------

registerBuiltInType("Button", BASE_CONSTRUCTORS.Button, 3)
rawset(rawget(state, "parts"), PART_NAME, {
  revision = PART_REVISION,
  bind = bind,
})

return WidgetKit
