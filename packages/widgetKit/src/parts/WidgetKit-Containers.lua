-- MoltenCodes WidgetKit part Containers
--
-- The three container types: `Frame` (a movable, resizable window with a
-- title), `Group` (an inline group with a title) and `ScrollFrame` (a scroll
-- child with a scrollbar). `Frame:BindPosition` needs the `Position` part.
--
-- Needs the WidgetKit core. See `docs/API.md`, "Parts", and
-- `docs/INTERNALS.md`, "Parts", for how a part joins the core.

-- Constants ------------------------------------------------------------------

local PART_NAME = "Containers"
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
  error("MoltenCodes WidgetKit part Containers requires WidgetKit API 1 to be loaded first", 2)
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
local readDisabled
local records
local refuseSecret
local releaseParent
local showText
local validateNumber
local parts
local missingPartMessage
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
  readDisabled = helpers.readDisabled
  records = helpers.records
  refuseSecret = helpers.refuseSecret
  releaseParent = helpers.releaseParent
  showText = helpers.showText
  validateNumber = helpers.validateNumber
  parts = helpers.parts
  missingPartMessage = helpers.missingPartMessage
  registerBuiltInType = helpers.registerBuiltInType
end

bind(rawget(state, "helpers"))

-- This part's constructors by type name, each defined in its own `do` block
-- below so that the helpers of one type are not visible to the others.
local BASE_CONSTRUCTORS = {}

-- Widget: Frame --------------------------------------------------------------

do
  local WINDOW_WIDTH, WINDOW_HEIGHT = 700, 500
  local WINDOW_TITLE_HEIGHT = 24
  local WINDOW_INSET = 12

  ---@param text any
  ---@param options WidgetKit.TextOptions?
  local function windowSetTitle(self, text, options)
    local value, secret = checkText(self, text, options, "WidgetKit Frame:SetTitle", 3)
    showText(self, "titleText", value, secret)
  end

  ---@return any
  local function windowGetTitle(self)
    activeRecord(self, "WidgetKit Frame:GetTitle", 3)
    local text = self.titleText:GetText()
    if type(text) == "nil" then
      return ""
    end
    return text
  end

  ---@param resizable boolean
  local function windowSetResizable(self, resizable)
    activeRecord(self, "WidgetKit Frame:SetResizable", 3)
    refuseSecret(resizable, "WidgetKit Frame:SetResizable resizable", 3)
    if type(resizable) ~= "boolean" then
      error("WidgetKit Frame:SetResizable resizable must be a boolean", 2)
    end
    self.frame:SetResizable(resizable)
    self.sizer:SetShown(resizable)
  end

  ---@param movable boolean
  local function windowSetMovable(self, movable)
    activeRecord(self, "WidgetKit Frame:SetMovable", 3)
    refuseSecret(movable, "WidgetKit Frame:SetMovable movable", 3)
    if type(movable) ~= "boolean" then
      error("WidgetKit Frame:SetMovable movable must be a boolean", 2)
    end
    self.frame:SetMovable(movable)
  end

  ---Bind the window's position, replacing a binding it already had. The binding
  ---is released with the window.
  ---@param storage table|(fun(): table) a table, or a function returning one at each save and restore
  ---@param options WidgetKit.BindingOptions?
  ---@return WidgetKit.Binding
  local function windowBindPosition(self, storage, options)
    activeRecord(self, "WidgetKit Frame:BindPosition", 3)
    -- The binding is the `Position` part's; without it the window cannot bind.
    local position = parts.Position
    if position == nil then
      error(missingPartMessage("WidgetKit Frame:BindPosition", "Position"), 2)
    end
    local binding =
      position.newBinding(self.frame, storage, options, "WidgetKit Frame:BindPosition", 3)
    local previous = self._binding
    if previous ~= nil then
      previous:Release()
    end
    self._binding = binding
    return binding
  end

  ---@return WidgetKit.Binding?
  local function windowGetBinding(self)
    activeRecord(self, "WidgetKit Frame:GetBinding", 3)
    return self._binding
  end

  local function windowOnAcquire(self)
    local frame = self.frame
    -- A restored anchor applies its saved scale to the frame; the next
    -- use of the window starts at the default one.
    frame:SetScale(1)
    frame:SetFrameStrata("DIALOG")
    frame:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
    frame:ClearAllPoints()
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:SetResizable(true)
    self.sizer:Show()
    self.titleText:SetText("")
  end

  local function windowOnRelease(self)
    local binding = self._binding
    if binding ~= nil then
      binding:Release()
      self._binding = nil
    end
    showText(self, "titleText", "", false)
    local frame = self.frame
    frame:StopMovingOrSizing()
  end

  ---@return table widget
  function BASE_CONSTRUCTORS.Frame()
    local frame = createFrame("Frame", releaseParent())
    frame:SetFrameStrata("DIALOG")
    -- `SetParent` gives a frame its new parent's strata (measured on Retail
    -- 12.1.0 b69933: a window put on a MEDIUM frame answered MEDIUM), so the
    -- window keeps its own strata wherever a consumer parents it.
    if type(frame.SetFixedFrameStrata) == "function" then
      frame:SetFixedFrameStrata(true)
    end
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    if type(frame.SetResizeBounds) == "function" then
      frame:SetResizeBounds(240, 160)
    end

    local background = frame:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(frame)
    background:SetColorTexture(0.05, 0.05, 0.05, 0.92)

    local titleBar = createFrame("Frame", frame)
    titleBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -WINDOW_TITLE_HEIGHT, 0)
    titleBar:SetHeight(WINDOW_TITLE_HEIGHT)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")

    local titleText = titleBar:CreateFontString(nil, "OVERLAY")
    titleText:SetFontObject("GameFontNormal")
    titleText:SetJustifyH("LEFT")
    titleText:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
    titleText:SetPoint("RIGHT", titleBar, "RIGHT", -8, 0)

    local close = createFrame("Button", frame, "UIPanelCloseButton")
    close:SetSize(WINDOW_TITLE_HEIGHT, WINDOW_TITLE_HEIGHT)
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)

    local sizer = createFrame("Button", frame)
    sizer:SetSize(16, 16)
    sizer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    sizer:EnableMouse(true)
    local grip = sizer:CreateTexture(nil, "OVERLAY")
    grip:SetAllPoints(sizer)
    grip:SetColorTexture(0.6, 0.6, 0.6, 0.5)

    local content = createFrame("Frame", frame)
    content:SetPoint("TOPLEFT", frame, "TOPLEFT", WINDOW_INSET, -(WINDOW_TITLE_HEIGHT + 8))
    content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -WINDOW_INSET, WINDOW_INSET)

    local widget = {
      frame = frame,
      content = content,
      titleBar = titleBar,
      titleText = titleText,
      closeButton = close,
      sizer = sizer,
      OnAcquire = windowOnAcquire,
      OnRelease = windowOnRelease,
      SetTitle = windowSetTitle,
      GetTitle = windowGetTitle,
      SetResizable = windowSetResizable,
      SetMovable = windowSetMovable,
      BindPosition = windowBindPosition,
      GetBinding = windowGetBinding,
    }

    titleBar:SetScript("OnDragStart", function()
      if isActive(widget) and frame:IsMovable() then
        frame:StartMoving()
      end
    end)
    titleBar:SetScript("OnDragStop", function()
      frame:StopMovingOrSizing()
      if not isActive(widget) then
        return
      end
      local binding = widget._binding
      if binding ~= nil then
        binding:Capture()
      end
      widget:Fire("OnMoved")
    end)
    close:SetScript("OnClick", function()
      if not isActive(widget) then
        return
      end
      frame:Hide()
      widget:Fire("OnClose")
    end)
    sizer:SetScript("OnMouseDown", function()
      if isActive(widget) and frame:IsResizable() then
        frame:StartSizing("BOTTOMRIGHT")
      end
    end)
    sizer:SetScript("OnMouseUp", function()
      frame:StopMovingOrSizing()
      if not isActive(widget) then
        return
      end
      -- Layout is explicit: a finished resize is the moment to run it.
      widget:PerformLayout()
      widget:Fire("OnResize", frame:GetWidth(), frame:GetHeight())
    end)
    return widget
  end
end

-- Widget: Group --------------------------------------------------------------

do
  local GROUP_INSET = 8
  local GROUP_TITLE_HEIGHT = 18

  ---Anchor the content frame below the title, or at the top without one.
  ---@param widget table
  local function groupPlaceContent(widget)
    local title = widget.titleText:GetText()
    local hasTitle = type(title) ~= "nil" and (isSecret(title) or title ~= "")
    local top = hasTitle and (GROUP_TITLE_HEIGHT + GROUP_INSET) or GROUP_INSET
    widget._topInset = top
    local content = widget.content
    content:ClearAllPoints()
    content:SetPoint("TOPLEFT", widget.frame, "TOPLEFT", GROUP_INSET, -top)
    content:SetPoint("BOTTOMRIGHT", widget.frame, "BOTTOMRIGHT", -GROUP_INSET, GROUP_INSET)
  end

  ---@param text any
  ---@param options WidgetKit.TextOptions?
  local function groupSetTitle(self, text, options)
    local value, secret = checkText(self, text, options, "WidgetKit Group:SetTitle", 3)
    showText(self, "titleText", value, secret)
    groupPlaceContent(self)
  end

  ---@return any
  local function groupGetTitle(self)
    activeRecord(self, "WidgetKit Group:GetTitle", 3)
    local text = self.titleText:GetText()
    if type(text) == "nil" then
      return ""
    end
    return text
  end

  ---@param disabled boolean? `true` greys the text out; the widget takes no input
  local function groupSetDisabled(self, disabled)
    colourLabel(self.titleText, readDisabled(self, disabled, "WidgetKit Group:SetDisabled", 3))
  end

  ---A group grows to its content unless it is full height.
  local function groupOnLayoutFinished(self, _, height)
    local record = records[self]
    if record.fullHeight then
      return
    end
    self.frame:SetHeight((height or 0) + self._topInset + GROUP_INSET)
  end

  local function groupOnAcquire(self)
    self.frame:SetSize(300, 2 * GROUP_INSET)
    self.titleText:SetText("")
    colourLabel(self.titleText, false)
    groupPlaceContent(self)
  end

  local function groupOnRelease(self)
    showText(self, "titleText", "", false)
  end

  ---@return table widget
  function BASE_CONSTRUCTORS.Group()
    local frame = createFrame("Frame", releaseParent())
    local background = frame:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(frame)
    background:SetColorTexture(0.1, 0.1, 0.1, 0.5)

    local titleText = frame:CreateFontString(nil, "OVERLAY")
    titleText:SetFontObject("GameFontNormal")
    titleText:SetJustifyH("LEFT")
    titleText:SetPoint("TOPLEFT", frame, "TOPLEFT", GROUP_INSET, -4)
    titleText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -GROUP_INSET, -4)
    titleText:SetHeight(GROUP_TITLE_HEIGHT)

    local content = createFrame("Frame", frame)

    return {
      frame = frame,
      content = content,
      titleText = titleText,
      _topInset = GROUP_INSET,
      OnAcquire = groupOnAcquire,
      OnRelease = groupOnRelease,
      OnLayoutFinished = groupOnLayoutFinished,
      SetTitle = groupSetTitle,
      GetTitle = groupGetTitle,
      SetDisabled = groupSetDisabled,
    }
  end
end

-- Widget: ScrollFrame --------------------------------------------------------

do
  local SCROLLBAR_WIDTH = 16
  local SCROLL_STEP = 40

  ---@return number
  local function scrollGetContentHeight(self)
    activeRecord(self, "WidgetKit ScrollFrame:GetContentHeight", 3)
    return self._contentHeight
  end

  ---@return number
  local function scrollGetScrollRange(self)
    activeRecord(self, "WidgetKit ScrollFrame:GetScrollRange", 3)
    return self._range
  end

  ---@return number
  local function scrollGetScroll(self)
    activeRecord(self, "WidgetKit ScrollFrame:GetScroll", 3)
    return self.scroll:GetVerticalScroll()
  end

  ---Scroll to `offset`, clamped to the range.
  ---@param offset number
  local function scrollSetScroll(self, offset)
    activeRecord(self, "WidgetKit ScrollFrame:SetScroll", 3)
    validateNumber(offset, "WidgetKit ScrollFrame:SetScroll offset", 3)
    if offset < 0 then
      offset = 0
    elseif offset > self._range then
      offset = self._range
    end
    self.scroll:SetVerticalScroll(offset)
    self.scrollbar:SetValue(offset)
  end

  ---The scroll child has no anchors, so its width is set before each pass.
  local function scrollOnLayoutStart(self)
    -- `SetWidth` takes a secret argument only from untainted code, so a
    -- secret viewport width is unknown and the content keeps its width.
    local viewportWidth = self.scroll:GetWidth()
    if not isSecret(viewportWidth) then
      self.content:SetWidth(viewportWidth)
    end
  end

  ---Size the scroll child to what the layout used and update the scrollbar.
  local function scrollOnLayoutFinished(self, _, height)
    height = height or 0
    self._contentHeight = height
    self.content:SetHeight(height)
    -- A secret viewport height is unknown and counts as 0: every pixel of
    -- the content is then scrollable.
    local viewportHeight = self.scroll:GetHeight()
    if isSecret(viewportHeight) then
      viewportHeight = 0
    end
    local range = height - viewportHeight
    if range < 0 then
      range = 0
    end
    self._range = range
    local scrollbar = self.scrollbar
    scrollbar:SetMinMaxValues(0, range)
    scrollbar:SetShown(range > 0)
    local offset = self.scroll:GetVerticalScroll()
    if offset > range then
      self.scroll:SetVerticalScroll(range)
    end
  end

  local function scrollOnAcquire(self)
    self.frame:SetSize(300, 200)
    self._contentHeight = 0
    self._range = 0
    self.scroll:SetVerticalScroll(0)
    self.scrollbar:SetMinMaxValues(0, 0)
    self.scrollbar:SetValue(0)
    self.scrollbar:Hide()
  end

  ---@return table widget
  function BASE_CONSTRUCTORS.ScrollFrame()
    local frame = createFrame("Frame", releaseParent())

    local scroll = createFrame("ScrollFrame", frame)
    scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -(SCROLLBAR_WIDTH + 4), 0)
    scroll:EnableMouseWheel(true)

    local content = createFrame("Frame", scroll)
    scroll:SetScrollChild(content)

    local scrollbar = createFrame("Slider", frame)
    scrollbar:SetOrientation("VERTICAL")
    scrollbar:SetWidth(SCROLLBAR_WIDTH)
    scrollbar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    scrollbar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    scrollbar:SetValueStep(1)
    local track = scrollbar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints(scrollbar)
    track:SetColorTexture(0, 0, 0, 0.4)
    local thumb = scrollbar:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(0.5, 0.5, 0.5, 0.9)
    thumb:SetSize(SCROLLBAR_WIDTH - 4, 24)
    scrollbar:SetThumbTexture(thumb)

    local widget = {
      frame = frame,
      content = content,
      scroll = scroll,
      scrollbar = scrollbar,
      _contentHeight = 0,
      _range = 0,
      OnAcquire = scrollOnAcquire,
      OnLayoutStart = scrollOnLayoutStart,
      OnLayoutFinished = scrollOnLayoutFinished,
      GetContentHeight = scrollGetContentHeight,
      GetScrollRange = scrollGetScrollRange,
      GetScroll = scrollGetScroll,
      SetScroll = scrollSetScroll,
    }

    scrollbar:SetScript("OnValueChanged", function(_, value)
      scroll:SetVerticalScroll(value)
    end)
    scroll:SetScript("OnMouseWheel", function(_, delta)
      if isActive(widget) then
        widget:SetScroll(scroll:GetVerticalScroll() - delta * SCROLL_STEP)
      end
    end)
    return widget
  end
end

-- Commit ---------------------------------------------------------------------

registerBuiltInType("Frame", BASE_CONSTRUCTORS.Frame, 4)
registerBuiltInType("Group", BASE_CONSTRUCTORS.Group, 3)
registerBuiltInType("ScrollFrame", BASE_CONSTRUCTORS.ScrollFrame, 1)
rawset(rawget(state, "parts"), PART_NAME, {
  revision = PART_REVISION,
  bind = bind,
})

return WidgetKit
