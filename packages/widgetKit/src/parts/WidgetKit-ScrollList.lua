-- MoltenCodes WidgetKit part ScrollList
--
-- The `ScrollList` type: a virtualised list over Blizzard's ScrollBox
-- framework.
--
-- Needs the WidgetKit core. See `docs/API.md`, "Parts", and
-- `docs/INTERNALS.md`, "Parts", for how a part joins the core.

-- Constants ------------------------------------------------------------------

local PART_NAME = "ScrollList"
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
  error("MoltenCodes WidgetKit part ScrollList requires WidgetKit API 1 to be loaded first", 2)
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
local capacityOf
local createFrame
local dispatch
local isActive
local isSecret
local readDisabled
local refuseSecret
local releaseParent
local reportError
local validateNumber
local validatePositiveInteger
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
  capacityOf = helpers.capacityOf
  createFrame = helpers.createFrame
  dispatch = helpers.dispatch
  isActive = helpers.isActive
  isSecret = helpers.isSecret
  readDisabled = helpers.readDisabled
  refuseSecret = helpers.refuseSecret
  releaseParent = helpers.releaseParent
  reportError = helpers.reportError
  validateNumber = helpers.validateNumber
  validatePositiveInteger = helpers.validatePositiveInteger
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

-- Widget: ScrollList ---------------------------------------------------------
--
-- A virtualised list over Blizzard's ScrollBox framework
-- (`Blizzard_SharedXML/Shared/Scroll` and `DataProvider.lua`, the same code on
-- Retail, Mists of Pandaria Classic and Classic Era; see `docs/INTERNALS.md`,
-- "ScrollList"). Only the rows the list shows exist as frames: the view makes
-- them from its own frame pool, parented to the scroll box's scroll target,
-- and points them at other elements as the list scrolls. WidgetKit builds each
-- row's parts (text, icon, highlight, selected texture) the first time the
-- view hands it that frame, and keeps them in `_rowParts`, never on the frame.
--
-- Rows are standard rows on purpose: the widget is pooled, so its rows go to
-- the next consumer of the widget, and a row an addon built itself would carry
-- its children into another addon's list.
--
-- Selection is one field, `_value`, rather than Blizzard's
-- `ScrollUtil.AddSelectionBehavior`: a select there walks the whole data
-- provider and allocates, and it reads an element's own `selected` field as
-- selected.

do
  -- `MinimalScrollBar`'s own width (`MinimalScrollBar.xml`) and the gap
  -- between it and the rows.
  local SCROLL_LIST_BAR_WIDTH = 8
  local SCROLL_LIST_BAR_GAP = 4

  local DEFAULT_ROW_HEIGHT = 20

  -- Rows below 8 pixels are unreadable, and the bound keeps the rows one
  -- list holds near its height divided by 8: the view makes a frame for
  -- every row the list shows, and the client never frees one.
  local MINIMUM_ROW_HEIGHT = 8

  -- The view's frame type for rows. A native type has no template info, so
  -- the row height must be given with `SetElementExtent`.
  local ROW_FRAME_TYPE = "Button"

  -- The space between a row's edge, its icon and its text.
  local ROW_INSET = 4

  -- `ScrollBoxConstants.AlignBegin`, `AlignCenter`, `AlignEnd` and
  -- `AlignNearest` (`ScrollBox.lua`, the same on every promised client).
  local ALIGNMENTS = { begin = 0, center = 0.5, ["end"] = 1, nearest = -1 }

  local NO_FRAMEWORK = " needs the client's ScrollBox framework (Blizzard_SharedXML),"
    .. " which this host does not have"

  ---The ScrollBox framework's entry points, or `nil` on a host without them.
  ---@return function? createView `CreateScrollBoxListLinearView`
  ---@return table? scrollUtil `ScrollUtil`
  local function scrollBoxFramework()
    local createView = readGlobal("CreateScrollBoxListLinearView")
    local scrollUtil = readGlobal("ScrollUtil")
    local createDataProvider = readGlobal("CreateDataProvider")
    if
      type(createView) ~= "function"
      or type(scrollUtil) ~= "table"
      or type(scrollUtil.InitScrollBoxListWithScrollBar) ~= "function"
      or type(createDataProvider) ~= "function"
    then
      return nil, nil
    end
    return createView, scrollUtil
  end

  ---A new Blizzard data provider over a copy of `elements`, or an error at
  ---the caller of the public method `methodName`.
  ---@param elements table?
  ---@param methodName string
  ---@param level integer stack level the failure is reported at
  ---@return table provider
  local function newProvider(elements, methodName, level)
    local createDataProvider = readGlobal("CreateDataProvider")
    if type(createDataProvider) ~= "function" then
      error(methodName .. NO_FRAMEWORK, level)
    end
    -- `CreateDataProvider` copies the array through `InsertTable`, so the
    -- caller's array stays the caller's.
    return createDataProvider(elements)
  end

  ---The list's data provider, made and handed to the scroll box on first
  ---use, so an empty list costs nothing.
  ---@param widget table
  ---@param methodName string
  ---@param level integer stack level the failure is reported at
  ---@return table provider
  local function scrollListProvider(widget, methodName, level)
    local provider = widget._provider
    if provider == nil then
      provider = newProvider(nil, methodName, level + 1)
      widget._provider = provider
      widget.scrollBox:SetDataProvider(provider)
    end
    return provider
  end

  ---Refuse anything but a non-secret table as an element.
  ---@param element any
  ---@param label string argument description, used in the argument error
  ---@param level integer stack level the failure is reported at
  local function checkElement(element, label, level)
    refuseSecret(element, label, level + 1)
    if type(element) ~= "table" then
      error(label .. " must be a table", level)
    end
  end

  ---The most elements one list holds now, as a number.
  ---@return number
  local function maximumElements()
    return capacityOf(rawget(rawget(state, "limits"), "maxListElements"))
  end

  ---The formatter used without `SetFormatter`.
  ---@param element table
  ---@return any text
  ---@return any icon
  local function defaultFormatter(element)
    return element.text, element.icon
  end

  ---The text a row shows for what a formatter returned: a string or number,
  ---or `""` for `nil`. Anything else, a secret included, is reported and
  ---shown as `""`: the formatter runs inside Blizzard's update, where raising
  ---would break the list.
  ---@param text any
  ---@return string|number
  local function rowText(text)
    if isSecret(text) then
      reportError("WidgetKit ScrollList formatter text must not be a secret value")
      return ""
    end
    local kind = type(text)
    if kind == "string" or kind == "number" then
      return text
    end
    if kind ~= "nil" then
      reportError("WidgetKit ScrollList formatter text must be a string or nil; it was a " .. kind)
    end
    return ""
  end

  ---The icon a row shows for what a formatter returned: a texture path or
  ---file ID, or `nil`. Anything else is reported and shows no icon.
  ---@param icon any
  ---@return string|number|nil
  local function rowIcon(icon)
    if isSecret(icon) then
      reportError("WidgetKit ScrollList formatter icon must not be a secret value")
      return nil
    end
    local kind = type(icon)
    if kind == "string" or kind == "number" then
      return icon
    end
    if kind ~= "nil" then
      reportError(
        "WidgetKit ScrollList formatter icon must be a string, a number or nil; it was a " .. kind
      )
    end
    return nil
  end

  ---Colour a row's text for the list's enabled or disabled state.
  ---@param text WidgetKit.Frame
  ---@param disabled boolean
  local function colourRowText(text, disabled)
    if disabled then
      text:SetTextColor(DISABLED_RED, DISABLED_GREEN, DISABLED_BLUE)
    else
      text:SetTextColor(TEXT_RED, TEXT_GREEN, TEXT_BLUE)
    end
  end

  ---Build the parts of a row frame the view handed this list for the first
  ---time. Runs once per row frame for the widget's whole life.
  ---@param widget table
  ---@param row WidgetKit.Frame
  ---@return table parts
  local function buildRowParts(widget, row)
    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints(row)
    highlight:SetColorTexture(1, 1, 1, 0.15)

    local selectedTexture = row:CreateTexture(nil, "BACKGROUND")
    selectedTexture:SetAllPoints(row)
    selectedTexture:SetColorTexture(LABEL_RED, LABEL_GREEN, LABEL_BLUE, 0.25)
    selectedTexture:Hide()

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("LEFT", row, "LEFT", ROW_INSET, 0)
    icon:Hide()

    local text = row:CreateFontString(nil, "OVERLAY")
    text:SetFontObject("GameFontHighlightSmall")
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)

    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    -- Through `dispatch`, so a newer revision's click handling takes over a
    -- row this one built.
    row:SetScript("OnClick", function(_, mouseButton)
      dispatch.clickScrollListRow(widget, row, mouseButton)
    end)

    -- `inset` is the text's left offset now, `-1` until it is first set.
    local parts = { text = text, icon = icon, selected = selectedTexture, inset = -1 }
    widget._rowParts[row] = parts
    return parts
  end

  ---Draw `row` for `element`: the view calls this, through the initializer,
  ---for every row it acquires and on `ReinitializeFrames`.
  ---@param widget table
  ---@param row WidgetKit.Frame
  ---@param element table
  local function initializeRow(widget, row, element)
    if not isActive(widget) then
      return
    end
    local parts = widget._rowParts[row] or buildRowParts(widget, row)

    -- The view keeps the element's index as the row's order index, so the
    -- index costs nothing; `GetElementDataIndex` would search the list.
    local index = 0
    if type(row.GetOrderIndex) == "function" then
      index = row:GetOrderIndex()
    end
    local ok, text, icon = pcall(widget._formatter or defaultFormatter, element, index)
    if not ok then
      reportError(text)
      text, icon = "", nil
    end
    text = rowText(text)
    icon = rowIcon(icon)

    local rowHeight = widget._rowHeight
    local inset = ROW_INSET
    local iconTexture = parts.icon
    if icon ~= nil then
      iconTexture:SetTexture(icon)
      iconTexture:SetSize(rowHeight - 2, rowHeight - 2)
      iconTexture:Show()
      inset = ROW_INSET + rowHeight - 2 + ROW_INSET
    else
      iconTexture:SetTexture(nil)
      iconTexture:Hide()
    end
    local textString = parts.text
    if parts.inset ~= inset then
      parts.inset = inset
      textString:ClearAllPoints()
      textString:SetPoint("LEFT", row, "LEFT", inset, 0)
      textString:SetPoint("RIGHT", row, "RIGHT", -ROW_INSET, 0)
    end
    textString:SetText(text)
    colourRowText(textString, widget._disabled)
    parts.selected:SetShown(element == widget._value)
  end

  ---Show the selection and the enabled state on every row on display,
  ---without asking the formatter again.
  ---@param widget table
  local function refreshRowStates(widget)
    local value, disabled = widget._value, widget._disabled
    for row, parts in next, widget._rowParts do
      -- A row back in the view's pool has lost its accessors.
      if type(row.GetElementData) == "function" and row:IsShown() then
        local element = row:GetElementData()
        parts.selected:SetShown(element ~= nil and element == value)
        colourRowText(parts.text, disabled)
      end
    end
  end

  ---A click on a row: a left click selects its element, firing
  ---`OnValueChanged` when the selection changed; every click fires `OnClick`.
  ---@param widget table
  ---@param row WidgetKit.Frame
  ---@param mouseButton string
  local function clickRow(widget, row, mouseButton)
    if not isActive(widget) or widget._disabled then
      return
    end
    if type(row.GetElementData) ~= "function" then
      return
    end
    local element = row:GetElementData()
    if element == nil then
      return
    end
    if mouseButton == "LeftButton" and element ~= widget._value then
      widget._value = element
      refreshRowStates(widget)
      widget:Fire("OnValueChanged", element)
      -- The callback may have released the list.
      if not isActive(widget) then
        return
      end
    end
    widget:Fire("OnClick", element, mouseButton)
  end

  ---After an `Insert` before the end or a `Remove`: ask a custom formatter
  ---again for the rows on display. Blizzard's view keeps the row of an
  ---element that stays on display when the data provider changes and only
  ---moves its order index (`ScrollBoxListView.lua`, `ValidateDataRange`),
  ---without running the initializer, so the index a formatter was handed
  ---would be stale. The default formatter shows no index and needs nothing.
  ---@param widget table
  local function redrawShiftedRows(widget)
    if widget._formatter ~= nil then
      widget.scrollBox:ReinitializeFrames()
    end
  end

  rawset(dispatch, "initializeScrollListRow", initializeRow)
  rawset(dispatch, "clickScrollListRow", clickRow)

  ---Replace the elements with a copy of the array `elements`.
  ---
  ---Every element is checked first: a table, not secret, at most once, and
  ---no more than `maxListElements` of them; a refused array leaves the list
  ---as it was. The selection is kept when its element is in the new list.
  ---@param elements table[]
  ---@param retainScroll boolean? keep the scroll offset; default `false`, back to the top
  local function scrollListSetElements(self, elements, retainScroll)
    activeRecord(self, "WidgetKit ScrollList:SetElements", 3)
    refuseSecret(elements, "WidgetKit ScrollList:SetElements elements", 3)
    if type(elements) ~= "table" then
      error("WidgetKit ScrollList:SetElements elements must be an array of tables", 2)
    end
    refuseSecret(retainScroll, "WidgetKit ScrollList:SetElements retainScroll", 3)
    if type(retainScroll) ~= "nil" and type(retainScroll) ~= "boolean" then
      error("WidgetKit ScrollList:SetElements retainScroll must be a boolean", 2)
    end
    local count = #elements
    local maximum = maximumElements()
    if count > maximum then
      error(
        "WidgetKit ScrollList:SetElements holds at most "
          .. maximum
          .. " elements (WidgetKit:SetLimits maxListElements)",
        2
      )
    end

    -- A set rather than a pooled scratch table: a wiped table keeps its
    -- size, and a pool would hold one as large as the longest list.
    local seen = {}
    local keepsValue = false
    local value = self._value
    for index = 1, count do
      local element = elements[index]
      if isSecret(element) then
        error(
          "WidgetKit ScrollList:SetElements elements[" .. index .. "] must not be a secret value",
          2
        )
      end
      if type(element) ~= "table" then
        error("WidgetKit ScrollList:SetElements elements[" .. index .. "] must be a table", 2)
      end
      -- The view tells rows apart by their element, so one element twice
      -- would leave a row behind on screen.
      if seen[element] then
        error("WidgetKit ScrollList:SetElements elements[" .. index .. "] appears twice", 2)
      end
      seen[element] = true
      if element == value then
        keepsValue = true
      end
    end

    local provider = newProvider(elements, "WidgetKit ScrollList:SetElements", 3)
    self._provider = provider
    if not keepsValue then
      self._value = nil
    end
    self.scrollBox:SetDataProvider(provider, retainScroll == true)
  end

  ---Add `element` at `index` (default: the end).
  ---@param element table
  ---@param index integer?
  local function scrollListInsert(self, element, index)
    activeRecord(self, "WidgetKit ScrollList:Insert", 3)
    checkElement(element, "WidgetKit ScrollList:Insert element", 3)
    local provider = self._provider
    local size = provider ~= nil and provider:GetSize() or 0
    if type(index) ~= "nil" then
      validatePositiveInteger(index, "WidgetKit ScrollList:Insert index", 3)
      if index > size + 1 then
        error("WidgetKit ScrollList:Insert index must be at most the element count plus one", 2)
      end
    end
    local maximum = maximumElements()
    if size >= maximum then
      error(
        "WidgetKit ScrollList:Insert holds at most "
          .. maximum
          .. " elements (WidgetKit:SetLimits maxListElements)",
        2
      )
    end
    if provider ~= nil and provider:FindIndex(element) ~= nil then
      error("WidgetKit ScrollList:Insert element is already in the list", 2)
    end
    provider = scrollListProvider(self, "WidgetKit ScrollList:Insert", 3)
    if type(index) == "nil" or index > size then
      provider:Insert(element)
    else
      provider:InsertAtIndex(element, index)
      redrawShiftedRows(self)
    end
  end

  ---Remove `element`.
  ---@param element table
  ---@return boolean removed `false` when it was not in the list
  local function scrollListRemove(self, element)
    activeRecord(self, "WidgetKit ScrollList:Remove", 3)
    checkElement(element, "WidgetKit ScrollList:Remove element", 3)
    local provider = self._provider
    if provider == nil or provider:Remove(element) == nil then
      return false
    end
    if element == self._value then
      self._value = nil
    end
    redrawShiftedRows(self)
    return true
  end

  ---Remove every element and the selection.
  local function scrollListClear(self)
    activeRecord(self, "WidgetKit ScrollList:Clear", 3)
    self._value = nil
    local provider = self._provider
    if provider ~= nil then
      provider:Flush()
    end
  end

  ---@return integer
  local function scrollListGetNumElements(self)
    activeRecord(self, "WidgetKit ScrollList:GetNumElements", 3)
    local provider = self._provider
    if provider == nil then
      return 0
    end
    return provider:GetSize()
  end

  ---@param index integer
  ---@return table? element `nil` past the last element
  local function scrollListGetElement(self, index)
    activeRecord(self, "WidgetKit ScrollList:GetElement", 3)
    validatePositiveInteger(index, "WidgetKit ScrollList:GetElement index", 3)
    local provider = self._provider
    if provider == nil then
      return nil
    end
    return provider:Find(index)
  end

  ---Draw the rows on display again, asking the formatter: for elements that
  ---changed in place.
  local function scrollListRefresh(self)
    activeRecord(self, "WidgetKit ScrollList:Refresh", 3)
    if self._provider ~= nil then
      self.scrollBox:ReinitializeFrames()
    end
  end

  ---Scroll so that `element` is on display.
  ---@param element table
  ---@param alignment ("begin"|"center"|"end"|"nearest")? default `"center"`
  ---@return boolean scrolled `false` when the element is not in the list
  local function scrollListScrollToElement(self, element, alignment)
    activeRecord(self, "WidgetKit ScrollList:ScrollToElement", 3)
    checkElement(element, "WidgetKit ScrollList:ScrollToElement element", 3)
    -- Before the lookup: indexing with a secret raises.
    refuseSecret(alignment, "WidgetKit ScrollList:ScrollToElement alignment", 3)
    local alignmentValue = ALIGNMENTS.center ---@type number?
    if type(alignment) ~= "nil" then
      alignmentValue = type(alignment) == "string" and ALIGNMENTS[alignment] or nil
      if alignmentValue == nil then
        error(
          'WidgetKit ScrollList:ScrollToElement alignment must be "begin", "center", "end" or "nearest"',
          2
        )
      end
    end
    local provider = self._provider
    local index = provider ~= nil and provider:FindIndex(element) or nil
    if index == nil then
      return false
    end
    -- By index: `ScrollToElementData` would search the list a second time,
    -- and answers nothing for an element already in view.
    self.scrollBox:ScrollToElementDataIndex(index, alignmentValue, 0, true)
    return true
  end

  ---Select `element`, or nothing with `nil`. Fires no callback.
  ---@param element table?
  local function scrollListSetValue(self, element)
    activeRecord(self, "WidgetKit ScrollList:SetValue", 3)
    refuseSecret(element, "WidgetKit ScrollList:SetValue element", 3)
    if type(element) ~= "nil" and type(element) ~= "table" then
      error("WidgetKit ScrollList:SetValue element must be a table or nil", 2)
    end
    self._value = element
    refreshRowStates(self)
  end

  ---@return table?
  local function scrollListGetValue(self)
    activeRecord(self, "WidgetKit ScrollList:GetValue", 3)
    return self._value
  end

  ---Set every row's height, in pixels: at least 8.
  ---@param pixels number
  local function scrollListSetRowHeight(self, pixels)
    activeRecord(self, "WidgetKit ScrollList:SetRowHeight", 3)
    validateNumber(pixels, "WidgetKit ScrollList:SetRowHeight pixels", 3)
    if pixels < MINIMUM_ROW_HEIGHT or pixels == math.huge then
      error(
        "WidgetKit ScrollList:SetRowHeight pixels must be a finite number of at least "
          .. MINIMUM_ROW_HEIGHT,
        2
      )
    end
    if pixels == self._rowHeight then
      return
    end
    self._rowHeight = pixels
    self.view:SetElementExtent(pixels)
    -- The view sizes a row when it acquires it, so the rows on display are
    -- acquired again at the new height.
    if self._provider ~= nil then
      self.scrollBox:Rebuild(true)
    end
  end

  ---Set the formatter, `callback(element, index)` → text, icon?; `nil`
  ---restores the default, `element.text` and `element.icon`.
  ---@param callback (fun(element: table, index: integer): any, any)?
  local function scrollListSetFormatter(self, callback)
    activeRecord(self, "WidgetKit ScrollList:SetFormatter", 3)
    refuseSecret(callback, "WidgetKit ScrollList:SetFormatter callback", 3)
    if type(callback) ~= "nil" and type(callback) ~= "function" then
      error("WidgetKit ScrollList:SetFormatter callback must be a function or nil", 2)
    end
    self._formatter = callback
    if self._provider ~= nil then
      self.scrollBox:ReinitializeFrames()
    end
  end

  ---@param disabled boolean? `true` greys the rows and ignores clicks
  local function scrollListSetDisabled(self, disabled)
    self._disabled = readDisabled(self, disabled, "WidgetKit ScrollList:SetDisabled", 3)
    refreshRowStates(self)
  end

  local function scrollListOnAcquire(self)
    self.frame:SetSize(300, 200)
    self._provider = nil
    self._value = nil
    self._formatter = nil
    self._disabled = false
    if self._rowHeight ~= DEFAULT_ROW_HEIGHT then
      self._rowHeight = DEFAULT_ROW_HEIGHT
      self.view:SetElementExtent(DEFAULT_ROW_HEIGHT)
    end
  end

  local function scrollListOnRelease(self)
    -- Every row goes back to the view's pool and the data provider is
    -- removed, so the list keeps no element of the consumer's.
    self.scrollBox:Flush()
    self._provider = nil
    self._value = nil
    self._formatter = nil
    for _, parts in next, self._rowParts do
      parts.text:SetText("")
      parts.icon:SetTexture(nil)
      parts.icon:Hide()
      parts.selected:Hide()
    end
  end

  ---@return table widget
  function BASE_CONSTRUCTORS.ScrollList()
    -- Checked before any frame exists: a constructor that raises after
    -- `CreateFrame` would leave that frame behind outside the cap.
    local createView, scrollUtil = scrollBoxFramework()
    if createView == nil or scrollUtil == nil then
      local message = "ScrollList" .. NO_FRAMEWORK
      rawset(state, "buildProblem", message)
      error(message, 0)
    end

    local frame = createFrame("Frame", releaseParent())
    local scrollBox = createFrame("Frame", frame, "WowScrollBoxList")
    scrollBox:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    scrollBox:SetPoint(
      "BOTTOMRIGHT",
      frame,
      "BOTTOMRIGHT",
      -(SCROLL_LIST_BAR_WIDTH + SCROLL_LIST_BAR_GAP),
      0
    )
    local scrollBar = createFrame("EventFrame", frame, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", SCROLL_LIST_BAR_GAP, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", SCROLL_LIST_BAR_GAP, 0)
    if type(scrollBar.SetHideIfUnscrollable) == "function" then
      scrollBar:SetHideIfUnscrollable(true)
    end

    local view = createView()
    view:SetElementExtent(DEFAULT_ROW_HEIGHT)

    local widget = {
      frame = frame,
      scrollBox = scrollBox,
      scrollBar = scrollBar,
      view = view,
      -- Row frame to its parts; the frames are this view's for the session.
      _rowParts = {},
      _provider = nil,
      _value = nil,
      _formatter = nil,
      _disabled = false,
      _rowHeight = DEFAULT_ROW_HEIGHT,
      OnAcquire = scrollListOnAcquire,
      OnRelease = scrollListOnRelease,
      SetElements = scrollListSetElements,
      Insert = scrollListInsert,
      Remove = scrollListRemove,
      Clear = scrollListClear,
      GetNumElements = scrollListGetNumElements,
      GetElement = scrollListGetElement,
      Refresh = scrollListRefresh,
      ScrollToElement = scrollListScrollToElement,
      SetValue = scrollListSetValue,
      GetValue = scrollListGetValue,
      SetRowHeight = scrollListSetRowHeight,
      SetFormatter = scrollListSetFormatter,
      SetDisabled = scrollListSetDisabled,
    }

    -- Through `dispatch`, so a newer revision draws rows for a list this
    -- one built.
    view:SetElementInitializer(ROW_FRAME_TYPE, function(row, element)
      dispatch.initializeScrollListRow(widget, row, element)
    end)
    scrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
    return widget
  end
end

-- Commit ---------------------------------------------------------------------

registerBuiltInType("ScrollList", BASE_CONSTRUCTORS.ScrollList, 2)
rawset(rawget(state, "parts"), PART_NAME, {
  revision = PART_REVISION,
  bind = bind,
})

return WidgetKit
