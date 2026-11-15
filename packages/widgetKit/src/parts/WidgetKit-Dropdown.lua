-- MoltenCodes WidgetKit part Dropdown
--
-- The `Dropdown` type (a keyboard-free list of buttons, closed by one
-- full-screen catcher frame), and `CreateMediaPicker`, a Dropdown over a
-- MediaKit list.
--
-- Needs the WidgetKit core; MediaKit API 1 when registered. See `docs/API.md`, "Parts", and
-- `docs/INTERNALS.md`, "Parts", for how a part joins the core.

-- Constants ------------------------------------------------------------------

local PART_NAME = "Dropdown"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "widgetKit", 1
local OPTIONAL_MEDIAKIT_API = 1

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
  error("MoltenCodes WidgetKit part Dropdown requires WidgetKit API 1 to be loaded first", 2)
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
local UNBOUNDED
local activeRecord
local colourLabel
local createFrame
local dispatch
local findPackage
local isActive
local newLabelMethods
local newTopLabel
local readDisabled
local refuseSecret
local releaseParent
local restingParent
local showText
local validateFacade
local validateName
local validatePositiveInteger
local registerBuiltInType

---Assign the core helpers this part uses.
---@param helpers table the core's `state.helpers`
local function bind(helpers)
  UNBOUNDED = helpers.UNBOUNDED
  activeRecord = helpers.activeRecord
  colourLabel = helpers.colourLabel
  createFrame = helpers.createFrame
  dispatch = helpers.dispatch
  findPackage = helpers.findPackage
  isActive = helpers.isActive
  newLabelMethods = helpers.newLabelMethods
  newTopLabel = helpers.newTopLabel
  readDisabled = helpers.readDisabled
  refuseSecret = helpers.refuseSecret
  releaseParent = helpers.releaseParent
  restingParent = helpers.restingParent
  showText = helpers.showText
  validateFacade = helpers.validateFacade
  validateName = helpers.validateName
  validatePositiveInteger = helpers.validatePositiveInteger
  registerBuiltInType = helpers.registerBuiltInType
end

bind(rawget(state, "helpers"))

-- This part's constructors by type name, each defined in its own `do` block
-- below so that the helpers of one type are not visible to the others.
local BASE_CONSTRUCTORS = {}

-- Dropdown list catcher ------------------------------------------------------
--
-- While a dropdown list is open, one invisible full-screen frame owned by the
-- Kit sits just below it and closes it on a click anywhere else. One catcher
-- serves the whole session; its script calls through `dispatch`, so a newer
-- copy's code runs for a catcher an older copy created.

---The session's catcher frame, created on first use.
---@return WidgetKit.Frame
local function dropdownCatcher()
  local catcher = rawget(state, "dropdownCatcher")
  if catcher == nil or catcher == false then
    local uiParent = restingParent()
    catcher = createFrame("Frame", uiParent)
    catcher:SetFrameStrata("FULLSCREEN")
    catcher:ClearAllPoints()
    catcher:SetPoint("TOPLEFT", uiParent, "TOPLEFT", 0, 0)
    catcher:SetPoint("BOTTOMRIGHT", uiParent, "BOTTOMRIGHT", 0, 0)
    catcher:EnableMouse(true)
    catcher:SetScript("OnMouseDown", function()
      dispatch.closeOpenDropdown()
    end)
    catcher:Hide()
    rawset(state, "dropdownCatcher", catcher)
  end
  return catcher
end

---Close `widget`'s list, and hide the catcher when it was the open one.
---@param widget table
local function closeDropdownList(widget)
  widget.list:Hide()
  if rawget(state, "openDropdown") == widget then
    rawset(state, "openDropdown", false)
    local catcher = rawget(state, "dropdownCatcher")
    if catcher ~= nil and catcher ~= false then
      catcher:Hide()
    end
  end
end

---Close whichever dropdown list is open.
local function closeOpenDropdown()
  local open = rawget(state, "openDropdown")
  if open ~= nil and open ~= false then
    closeDropdownList(open)
  end
end

---Show `widget`'s list above the catcher, closing any other open list.
---@param widget table
local function openDropdownList(widget)
  local open = rawget(state, "openDropdown")
  if open ~= nil and open ~= false and open ~= widget then
    closeDropdownList(open)
  end
  rawset(state, "openDropdown", widget)
  dropdownCatcher():Show()
  widget.list:Show()
end

-- Widget: Dropdown -----------------------------------------------------------

do --
  local dropdownSetLabel, dropdownGetLabel = newLabelMethods("Dropdown")

  -- A button showing the selected entry, and a list frame of row buttons below
  -- it. Nothing takes the keyboard. The list keeps a fixed number of rows,
  -- created on first open and reused for the widget's whole life; entries past
  -- them are reached with the mouse wheel, which moves the window of entries the
  -- rows show.

  local DROPDOWN_ROW_HEIGHT = 18

  -- Rows a dropdown list shows at once; the rest is reached with the wheel.
  local DROPDOWN_VISIBLE_ROWS = 16

  ---The label shown for the selected key, or an empty string.
  ---@param widget table
  ---@return string
  local function dropdownSelectedLabel(widget)
    local value = widget._value
    if value == nil then
      return ""
    end
    local keys, labels = widget._keys, widget._labels
    for index = 1, widget._count do
      if keys[index] == value then
        return labels[index]
      end
    end
    return ""
  end

  ---Point every row at the entries from `_offset` on.
  ---@param widget table
  local function dropdownRenderRows(widget)
    local rows = widget._rows
    local keys, labels = widget._keys, widget._labels
    for index = 1, #rows do
      local entry = widget._offset + index
      local row = rows[index]
      if entry <= widget._count then
        row:SetText(labels[entry])
        if keys[entry] == widget._value then
          row:LockHighlight()
        else
          row:UnlockHighlight()
        end
        row:Show()
      else
        row:SetText("")
        row:Hide()
      end
    end
  end

  ---Select the entry a row shows, close the list and fire.
  ---@param widget table
  ---@param rowIndex integer
  local function dropdownPick(widget, rowIndex)
    if not isActive(widget) or widget._disabled then
      return
    end
    local entry = widget._offset + rowIndex
    if entry > widget._count then
      return
    end
    local key = widget._keys[entry]
    widget._value = key
    widget.button:SetText(widget._labels[entry])
    closeDropdownList(widget)
    widget:Fire("OnValueChanged", key)
  end

  ---Create the list's rows on first open.
  ---@param widget table
  local function dropdownEnsureRows(widget)
    local rows = widget._rows
    if #rows > 0 then
      return
    end
    local list = widget.list
    for index = 1, DROPDOWN_VISIBLE_ROWS do
      local row = createFrame("Button", list)
      row:SetHeight(DROPDOWN_ROW_HEIGHT)
      row:SetPoint("TOPLEFT", list, "TOPLEFT", 4, -4 - (index - 1) * DROPDOWN_ROW_HEIGHT)
      row:SetPoint("TOPRIGHT", list, "TOPRIGHT", -4, -4 - (index - 1) * DROPDOWN_ROW_HEIGHT)
      row:SetNormalFontObject("GameFontHighlightSmall")
      local highlight = row:CreateTexture(nil, "HIGHLIGHT")
      highlight:SetAllPoints(row)
      highlight:SetColorTexture(1, 1, 1, 0.15)
      row:SetScript("OnClick", function()
        dropdownPick(widget, index)
      end)
      rows[index] = row
    end
  end

  ---Replace the entries.
  ---
  ---`values` maps keys (strings or numbers) to labels; `order` lists the keys in
  ---display order. Without `order`, entries are sorted by label, then by key.
  ---@param values table
  ---@param order any[]?
  local function dropdownSetList(self, values, order)
    activeRecord(self, "WidgetKit Dropdown:SetList", 3)
    if type(values) ~= "table" then
      error("WidgetKit Dropdown:SetList values must be a table", 2)
    end
    if type(order) ~= "nil" and type(order) ~= "table" then
      error("WidgetKit Dropdown:SetList order must be an array or nil", 2)
    end

    -- Every entry is checked into staging arrays first; the widget's own
    -- entries change only once the whole list was accepted, so a refused
    -- entry leaves the dropdown as it was.
    local keys, labels = {}, {}
    local count = 0
    -- Read when the list is set, so `SetLimits` applies to the next list.
    local maxEntries = rawget(rawget(state, "limits"), "maxDropdownEntries")
    if maxEntries == UNBOUNDED then
      maxEntries = math.huge
    end
    local function add(key, label)
      -- `add` runs one call below `SetList`, so its caller is level 3.
      refuseSecret(key, "WidgetKit Dropdown:SetList key", 4)
      refuseSecret(label, "WidgetKit Dropdown:SetList label", 4)
      if type(key) ~= "string" and type(key) ~= "number" then
        error("WidgetKit Dropdown:SetList keys must be strings or numbers", 3)
      end
      if type(label) ~= "string" then
        error("WidgetKit Dropdown:SetList labels must be strings", 3)
      end
      if count >= maxEntries then
        error(
          "WidgetKit Dropdown:SetList holds at most "
            .. maxEntries
            .. " entries (WidgetKit:SetLimits maxDropdownEntries)",
          3
        )
      end
      count = count + 1
      keys[count] = key
      labels[count] = label
    end

    -- The staged position of each displayed entry, when sorting reorders them.
    local displayOrder = nil
    if type(order) ~= "nil" then
      for index = 1, #order do
        local key = order[index]
        -- Before the key indexes `values`: a secret used as a key raises.
        refuseSecret(key, "WidgetKit Dropdown:SetList key", 3)
        local label = values[key]
        if type(label) ~= "nil" then
          add(key, label)
        end
      end
    else
      for key, label in next, values do
        add(key, label)
      end
      -- Sort by label, then key, through an index array over the staged
      -- entries; the widget's arrays are then filled in that order.
      displayOrder = {}
      for index = 1, count do
        displayOrder[index] = index
      end
      table.sort(displayOrder, function(first, second)
        local firstLabel, secondLabel = labels[first], labels[second]
        if firstLabel ~= secondLabel then
          return firstLabel < secondLabel
        end
        local firstKey, secondKey = keys[first], keys[second]
        if type(firstKey) ~= type(secondKey) then
          return type(firstKey) == "number"
        end
        return firstKey < secondKey
      end)
    end

    local ownKeys, ownLabels = self._keys, self._labels
    for index = 1, count do
      local staged = index
      if displayOrder ~= nil then
        staged = displayOrder[index]
      end
      ownKeys[index] = keys[staged]
      ownLabels[index] = labels[staged]
    end
    for index = count + 1, self._count do
      ownKeys[index] = nil
      ownLabels[index] = nil
    end
    self._count = count
    self._offset = 0
    self.button:SetText(dropdownSelectedLabel(self))
    if self.list:IsShown() then
      dropdownRenderRows(self)
    end
  end

  ---@param key string|number|nil
  local function dropdownSetValue(self, key)
    activeRecord(self, "WidgetKit Dropdown:SetValue", 3)
    refuseSecret(key, "WidgetKit Dropdown:SetValue key", 3)
    self._value = key
    self.button:SetText(dropdownSelectedLabel(self))
    if self.list:IsShown() then
      dropdownRenderRows(self)
    end
  end

  ---@return string|number|nil
  local function dropdownGetValue(self)
    activeRecord(self, "WidgetKit Dropdown:GetValue", 3)
    return self._value
  end

  ---@return integer
  local function dropdownGetNumEntries(self)
    activeRecord(self, "WidgetKit Dropdown:GetNumEntries", 3)
    return self._count
  end

  ---Open the list, scrolled so that the selected entry is visible.
  ---@return boolean opened `false` when disabled or empty
  local function dropdownOpen(self)
    activeRecord(self, "WidgetKit Dropdown:Open", 3)
    if self._disabled or self._count == 0 then
      return false
    end
    dropdownEnsureRows(self)
    local visible = self._count < DROPDOWN_VISIBLE_ROWS and self._count or DROPDOWN_VISIBLE_ROWS
    self.list:SetHeight(visible * DROPDOWN_ROW_HEIGHT + 8)
    self._offset = 0
    local value = self._value
    for index = 1, self._count do
      if self._keys[index] == value and index > DROPDOWN_VISIBLE_ROWS then
        self._offset = index - DROPDOWN_VISIBLE_ROWS
      end
    end
    dropdownRenderRows(self)
    openDropdownList(self)
    return true
  end

  local function dropdownClose(self)
    activeRecord(self, "WidgetKit Dropdown:Close", 3)
    closeDropdownList(self)
  end

  ---@return boolean
  local function dropdownIsOpen(self)
    activeRecord(self, "WidgetKit Dropdown:IsOpen", 3)
    return self.list:IsShown() == true
  end

  ---Choose the entry at `index` in display order, as a click on its row does.
  ---@param index integer
  ---@return boolean picked
  local function dropdownPickIndex(self, index)
    activeRecord(self, "WidgetKit Dropdown:PickIndex", 3)
    validatePositiveInteger(index, "WidgetKit Dropdown:PickIndex index", 3)
    if index > self._count or self._disabled then
      return false
    end
    local previousOffset = self._offset
    self._offset = index - 1
    dropdownPick(self, 1)
    self._offset = previousOffset
    return true
  end

  ---@param disabled boolean? `true` greys the widget out and ignores input
  local function dropdownSetDisabled(self, disabled)
    disabled = readDisabled(self, disabled, "WidgetKit Dropdown:SetDisabled", 3)
    self._disabled = disabled
    self.button:SetEnabled(not disabled)
    colourLabel(self.labelText, disabled)
    if disabled then
      closeDropdownList(self)
    end
  end

  local function dropdownOnAcquire(self)
    self.frame:SetSize(200, 44)
    self._value = nil
    self._offset = 0
    self._disabled = false
    self.button:SetEnabled(true)
    self.button:SetText("")
    self.labelText:SetText("")
    colourLabel(self.labelText, false)
    closeDropdownList(self)
  end

  local function dropdownOnRelease(self)
    closeDropdownList(self)
    local keys, labels = self._keys, self._labels
    for index = 1, self._count do
      keys[index] = nil
      labels[index] = nil
    end
    self._count = 0
    self._value = nil
    self.button:SetText("")
    showText(self, "labelText", "", false)
    local rows = self._rows
    for index = 1, #rows do
      rows[index]:SetText("")
    end
  end

  ---@return table widget
  function BASE_CONSTRUCTORS.Dropdown()
    local frame = createFrame("Frame", releaseParent())
    local labelText = newTopLabel(frame)

    local button = createFrame("Button", frame, "UIPanelButtonTemplate")
    button:SetHeight(24)
    button:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -18)
    button:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -18)

    -- The list lives on UIParent, above everything, so a ScrollFrame or any
    -- other clipping parent of the dropdown cannot cut it off.
    local list = createFrame("Frame", restingParent() or frame)
    list:SetFrameStrata("FULLSCREEN_DIALOG")
    list:SetToplevel(true)
    list:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 0, 0)
    list:SetPoint("TOPRIGHT", button, "BOTTOMRIGHT", 0, 0)
    list:EnableMouse(true)
    list:EnableMouseWheel(true)
    local background = list:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(list)
    background:SetColorTexture(0.05, 0.05, 0.05, 0.95)
    list:Hide()

    local widget = {
      frame = frame,
      labelText = labelText,
      button = button,
      list = list,
      _keys = {},
      _labels = {},
      _rows = {},
      _count = 0,
      _offset = 0,
      _value = nil,
      _disabled = false,
      OnAcquire = dropdownOnAcquire,
      OnRelease = dropdownOnRelease,
      SetList = dropdownSetList,
      SetValue = dropdownSetValue,
      GetValue = dropdownGetValue,
      GetNumEntries = dropdownGetNumEntries,
      Open = dropdownOpen,
      Close = dropdownClose,
      IsOpen = dropdownIsOpen,
      PickIndex = dropdownPickIndex,
      SetLabel = dropdownSetLabel,
      GetLabel = dropdownGetLabel,
      SetDisabled = dropdownSetDisabled,
    }

    button:SetScript("OnClick", function()
      if not isActive(widget) then
        return
      end
      if list:IsShown() then
        closeDropdownList(widget)
      else
        widget:Open()
      end
    end)
    -- The list is not a child of the widget's frame, so it is closed when
    -- that frame hides.
    frame:SetScript("OnHide", function()
      closeDropdownList(widget)
    end)
    list:SetScript("OnMouseWheel", function(_, delta)
      if not isActive(widget) then
        return
      end
      local maximumOffset = widget._count - DROPDOWN_VISIBLE_ROWS
      if maximumOffset < 0 then
        maximumOffset = 0
      end
      local offset = widget._offset - delta
      if offset < 0 then
        offset = 0
      elseif offset > maximumOffset then
        offset = maximumOffset
      end
      widget._offset = offset
      dropdownRenderRows(widget)
    end)
    return widget
  end
end

-- Media pickers --------------------------------------------------------------

---Fill `dropdown` with the names MediaKit lists for `mediaType`.
---@param MediaKit table
---@param dropdown table
---@param mediaType string
---@return boolean filled `false` when MediaKit refused the type
local function fillMediaDropdown(MediaKit, dropdown, mediaType)
  local ok, names = pcall(MediaKit.List, MediaKit, mediaType)
  if not ok or type(names) ~= "table" then
    return false
  end
  local values = {}
  for index = 1, #names do
    values[names[index]] = names[index]
  end
  dropdown:SetList(values, names)
  return true
end

---A Dropdown listing MediaKit's names for `mediaType`, in MediaKit's order.
---@param mediaType string one of MediaKit's media types, such as `"font"` or `"statusbar"`
---@return WidgetKit.Widget|nil dropdown
---@return string? reason `"exhausted"` when no Dropdown can be created
local function createMediaPicker(self, mediaType)
  validateFacade(self, "WidgetKit:CreateMediaPicker", 3)
  validateName(mediaType, "WidgetKit:CreateMediaPicker mediaType", 3)
  local MediaKit = findPackage(Registry, "mediaKit", OPTIONAL_MEDIAKIT_API)
  if type(MediaKit) ~= "table" or type(MediaKit.List) ~= "function" then
    error("WidgetKit:CreateMediaPicker requires MediaKit API 1", 2)
  end
  local probe, names = pcall(MediaKit.List, MediaKit, mediaType)
  if not probe or type(names) ~= "table" then
    error("WidgetKit:CreateMediaPicker mediaType must be a MediaKit media type", 2)
  end
  -- Checked before a Dropdown is acquired: a list `SetList` would refuse must
  -- not leave a borrowed widget behind.
  local maxEntries = rawget(rawget(state, "limits"), "maxDropdownEntries")
  if maxEntries ~= UNBOUNDED and #names > maxEntries then
    error(
      "WidgetKit:CreateMediaPicker MediaKit lists more "
        .. mediaType
        .. " names than a Dropdown holds ("
        .. maxEntries
        .. "; WidgetKit:SetLimits maxDropdownEntries)",
      2
    )
  end

  local dropdown, reason = WidgetKit:Create("Dropdown")
  if dropdown == nil then
    return nil, reason
  end
  fillMediaDropdown(MediaKit, dropdown, mediaType)
  return dropdown
end

-- Commit ---------------------------------------------------------------------

registerBuiltInType("Dropdown", BASE_CONSTRUCTORS.Dropdown, 4)
rawset(dispatch, "closeOpenDropdown", closeOpenDropdown)
rawset(WidgetKit, "CreateMediaPicker", createMediaPicker)
rawset(rawget(state, "parts"), PART_NAME, {
  revision = PART_REVISION,
  bind = bind,
  -- The renderer fills a `select` over MediaKit through this.
  fillMediaDropdown = fillMediaDropdown,
})

return WidgetKit
