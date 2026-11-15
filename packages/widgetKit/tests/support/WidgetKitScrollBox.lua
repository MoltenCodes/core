--- A stand-in for the client's ScrollBox framework (`Blizzard_SharedXML`), for
--- the `ScrollList` specs.
---
--- It models what WidgetKit relies on, as Blizzard's own code does it on
--- Retail 12.1.5, Mists of Pandaria Classic 5.5.4 and Classic Era 1.15.9
--- (`Shared/Scroll/ScrollBox.lua`, `ScrollBoxListView.lua`,
--- `ScrollBoxLinearView.lua`, `ScrollUtil.lua` and `DataProvider.lua`, read
--- 2026-11-15), and records what WidgetKit calls so a spec can assert it:
---
---   templates       `CreateFrame(..., "WowScrollBoxList")` gives a frame with
---                   the scroll box methods below and a `ScrollTarget` child;
---                   `CreateFrame("EventFrame", ..., "MinimalScrollBar")` a
---                   frame with `SetHideIfUnscrollable`. The shared stub has
---                   no `EventFrame` type, so one is a `Frame` here;
---   the view        `CreateScrollBoxListLinearView()` with
---                   `SetElementInitializer(frameType, initializer)` and
---                   `SetElementExtent(extent)` (at least 1, as Blizzard's);
---                   its row frames come from a pool of its own, are parented
---                   to the scroll target, never freed, and carry the
---                   accessors Blizzard writes on them (`GetElementData`,
---                   `GetOrderIndex`, `SetOrderIndex`, `GetElementDataIndex`)
---                   while acquired; a released row loses them and is hidden;
---   the update      every data change, and every scroll, works out the rows
---                   on display (the box's height over the row height, plus
---                   one), releases the rows whose element left that range,
---                   acquires rows for elements that entered it (reusing a row
---                   whose element stayed, as Blizzard does for table
---                   elements), sizes each acquired row to the extent, and then
---                   runs the initializer for the acquired rows only;
---   data providers  `CreateDataProvider(array)` copies the array; `Insert`,
---                   `InsertAtIndex`, `Remove` (answering the removed index),
---                   `Flush`, `GetSize`, `Find`, `FindIndex`; every change
---                   updates the scroll box that holds the provider.
---
--- `ScrollUtil.InitScrollBoxListWithScrollBar` binds the box, the bar and the
--- view. `WidgetKitScrollBox.ScrollTo(scrollBox, firstIndex)` moves the first
--- row on display, as the mouse wheel does in the client.

local WidgetKitScrollBox = {}

---Read a host global: the fixture stands in for the client, whose API only
---exists in the global table.
---@param name string
---@return any
local function readGlobal(name)
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

--- The globals `Install` writes, removed again by `Remove`.
WidgetKitScrollBox.GLOBALS = { "CreateScrollBoxListLinearView", "ScrollUtil", "CreateDataProvider" }

-- Data provider ------------------------------------------------------------

local DataProvider = {}
DataProvider.__index = DataProvider

---Tell the scroll box holding this provider that its contents changed.
---@param provider table
local function contentsChanged(provider)
  provider.changes = provider.changes + 1
  local scrollBox = provider.scrollBox
  if scrollBox ~= nil then
    scrollBox:Update(false)
  end
end

function DataProvider:GetSize()
  return #self.collection
end

function DataProvider:Find(index)
  return self.collection[index]
end

function DataProvider:FindIndex(element)
  local collection = self.collection
  for index = 1, #collection do
    if collection[index] == element then
      return index, element
    end
  end
  return nil
end

function DataProvider:Insert(...)
  for index = 1, select("#", ...) do
    table.insert(self.collection, (select(index, ...)))
  end
  contentsChanged(self)
end

function DataProvider:InsertAtIndex(element, index)
  table.insert(self.collection, index, element)
  contentsChanged(self)
end

function DataProvider:Remove(element)
  local index = self:FindIndex(element)
  if index == nil then
    return nil
  end
  table.remove(self.collection, index)
  contentsChanged(self)
  return index
end

function DataProvider:Flush()
  self.collection = {}
  contentsChanged(self)
end

---@param array table?
---@return table provider
local function createDataProvider(array)
  local provider = setmetatable({ collection = {}, changes = 0, scrollBox = nil }, DataProvider)
  if array ~= nil then
    for index = 1, #array do
      provider.collection[index] = array[index]
    end
  end
  return provider
end

-- View -----------------------------------------------------------------------

local View = {}
View.__index = View

function View:SetElementInitializer(frameType, initializer)
  self.frameType = frameType
  self.initializer = initializer
end

function View:SetElementExtent(extent)
  self.extent = math.max(extent, 1)
  self.extentCalls[#self.extentCalls + 1] = extent
end

---A row frame from the view's pool, made when the pool is empty.
---@param view table
---@return table row
---@return boolean new
local function acquireRow(view)
  local free = view.free
  local row = free[#free]
  if row ~= nil then
    free[#free] = nil
    return row, false
  end
  local createFrame = readGlobal("CreateFrame")
  row = createFrame(view.frameType, nil, view.scrollBox.ScrollTarget)
  view.created = view.created + 1
  return row, true
end

---Write the accessors Blizzard's `AssignAccessors` writes on a row.
---@param view table
---@param row table
---@param element table
---@param index integer
local function assignAccessors(view, row, element, index)
  local orderIndex = index
  row.GetElementData = function()
    return element
  end
  row.GetOrderIndex = function()
    return orderIndex
  end
  row.SetOrderIndex = function(_, value)
    orderIndex = value
  end
  row.GetElementDataIndex = function()
    return view.provider ~= nil and view.provider:FindIndex(element) or nil
  end
end

---Give `row` back to the pool, as Blizzard's `Release` does.
---@param view table
---@param row table
local function releaseRow(view, row)
  row.GetElementData = nil
  row.GetOrderIndex = nil
  row.SetOrderIndex = nil
  row.GetElementDataIndex = nil
  row:Hide()
  row:ClearAllPoints()
  view.free[#view.free + 1] = row
end

-- Scroll box -----------------------------------------------------------------

local ScrollBoxMethods = {}

---The rows the box shows at once: its height over the row height, plus one.
---@param scrollBox table
---@return integer
local function visibleCount(scrollBox)
  local height = scrollBox:GetHeight()
  return math.floor(height / scrollBox.view.extent) + 1
end

---Bring the rows on display in line with the provider and the first index.
---@param forceAll boolean release every row first, as a reassigned provider does
function ScrollBoxMethods:Update(forceAll)
  local view = self.view
  self.updates = self.updates + 1
  local provider = view.provider
  local size = provider ~= nil and provider:GetSize() or 0
  local visible = visibleCount(self)
  local maximumFirst = math.max(1, size - visible + 1)
  if self.firstIndex > maximumFirst then
    self.firstIndex = maximumFirst
  end
  local first = self.firstIndex
  local last = math.min(size, first + visible - 1)

  local kept = {}
  local frames = view.frames
  for index = #frames, 1, -1 do
    local row = frames[index]
    local element = row:GetElementData()
    local dataIndex = provider ~= nil and provider:FindIndex(element) or nil
    if forceAll or dataIndex == nil or dataIndex < first or dataIndex > last then
      table.remove(frames, index)
      releaseRow(view, row)
    else
      row:SetOrderIndex(dataIndex)
      kept[element] = row
    end
  end

  local acquired = {}
  for dataIndex = first, last do
    local element = provider:Find(dataIndex)
    if kept[element] == nil then
      local row = acquireRow(view)
      assignAccessors(view, row, element, dataIndex)
      row:SetHeight(view.extent)
      row:Show()
      frames[#frames + 1] = row
      acquired[#acquired + 1] = row
    end
  end
  -- Blizzard runs initializers once layout is done, for acquired rows only.
  for index = 1, #acquired do
    local row = acquired[index]
    view.initializer(row, row:GetElementData())
  end
end

function ScrollBoxMethods:SetDataProvider(provider, retainScrollPosition)
  local view = self.view
  if view.provider ~= nil then
    view.provider.scrollBox = nil
  end
  view.provider = provider
  provider.scrollBox = self
  self.providersSet = self.providersSet + 1
  if not retainScrollPosition then
    self.firstIndex = 1
  end
  self:Update(true)
end

function ScrollBoxMethods:GetDataProvider()
  return self.view.provider
end

function ScrollBoxMethods:Flush()
  local view = self.view
  local frames = view.frames
  for index = #frames, 1, -1 do
    releaseRow(view, frames[index])
    frames[index] = nil
  end
  if view.provider ~= nil then
    view.provider.scrollBox = nil
  end
  view.provider = nil
  self.flushes = self.flushes + 1
end

function ScrollBoxMethods:ReinitializeFrames()
  local view = self.view
  self.reinitializations = self.reinitializations + 1
  local frames = view.frames
  for index = 1, #frames do
    local row = frames[index]
    view.initializer(row, row:GetElementData())
  end
end

function ScrollBoxMethods:Rebuild(retainScrollPosition)
  self.rebuilds = self.rebuilds + 1
  local provider = self.view.provider
  if provider ~= nil then
    self:SetDataProvider(provider, retainScrollPosition)
  end
end

function ScrollBoxMethods:ScrollToElementDataIndex(dataIndex, alignment, offset, noInterpolation)
  self.scrollCalls[#self.scrollCalls + 1] = {
    index = dataIndex,
    alignment = alignment,
    offset = offset,
    noInterpolation = noInterpolation,
  }
  local visible = visibleCount(self)
  local first = self.firstIndex
  -- `AlignNearest` (-1) becomes the edge the element is past, or nothing
  -- when it is already in view, as `ScrollToElementDataIndex` does.
  if alignment == -1 then
    if dataIndex < first then
      alignment = 0
    elseif dataIndex > first + visible - 1 then
      alignment = 1
    end
  end
  if alignment == 0 then
    first = dataIndex
  elseif alignment == 1 then
    first = dataIndex - visible + 1
  elseif alignment == 0.5 then
    first = dataIndex - math.floor(visible / 2)
  end
  self.firstIndex = math.max(1, first)
  self:Update(false)
end

---Apply the scroll box template to `frame`.
---@param frame table
local function applyScrollBox(frame)
  local createFrame = readGlobal("CreateFrame")
  frame.ScrollTarget = createFrame("Frame", nil, frame)
  frame.firstIndex = 1
  frame.updates = 0
  frame.flushes = 0
  frame.rebuilds = 0
  frame.reinitializations = 0
  frame.providersSet = 0
  frame.scrollCalls = {}
  for name, method in next, ScrollBoxMethods do
    frame[name] = method
  end
end

---Apply the `MinimalScrollBar` template to `frame`.
---@param frame table
local function applyScrollBar(frame)
  frame.hideIfUnscrollable = false
  frame.SetHideIfUnscrollable = function(self, hide)
    self.hideIfUnscrollable = hide
  end
end

-- Installation ---------------------------------------------------------------

---Install the framework's globals and wrap `CreateFrame` for its templates.
---Call it after the fixture's World of Warcraft API and the client rules.
---@param setGlobal fun(name: string, value: any) the environment's global writer
function WidgetKitScrollBox.Install(setGlobal)
  local createFrame = readGlobal("CreateFrame")
  if type(createFrame) ~= "function" then
    error("WidgetKitScrollBox.Install needs the fixture's CreateFrame installed first", 2)
  end
  setGlobal("CreateFrame", function(frameType, name, parent, template)
    local frame
    if frameType == "EventFrame" then
      frame = createFrame("Frame", name, parent, template)
      frame.frameType = "EventFrame"
    else
      frame = createFrame(frameType, name, parent, template)
    end
    if template == "WowScrollBoxList" then
      applyScrollBox(frame)
    elseif template == "MinimalScrollBar" then
      applyScrollBar(frame)
    end
    return frame
  end)

  setGlobal("CreateScrollBoxListLinearView", function()
    return setmetatable({
      extent = 1,
      extentCalls = {},
      frames = {},
      free = {},
      created = 0,
      provider = nil,
      scrollBox = nil,
    }, View)
  end)
  setGlobal("ScrollUtil", {
    InitScrollBoxListWithScrollBar = function(scrollBox, scrollBar, view)
      scrollBox.view = view
      scrollBox.scrollBar = scrollBar
      view.scrollBox = scrollBox
    end,
  })
  setGlobal("CreateDataProvider", createDataProvider)
end

---Remove the framework's globals again; the next `Reset` removes the
---`CreateFrame` wrapper.
---@param setGlobal fun(name: string, value: any) the environment's global writer
function WidgetKitScrollBox.Remove(setGlobal)
  for index = 1, #WidgetKitScrollBox.GLOBALS do
    setGlobal(WidgetKitScrollBox.GLOBALS[index], nil)
  end
end

---Move the first row on display to `firstIndex`, as the mouse wheel does.
---@param scrollBox table
---@param firstIndex integer
function WidgetKitScrollBox.ScrollTo(scrollBox, firstIndex)
  scrollBox.firstIndex = firstIndex
  scrollBox:Update(false)
end

return WidgetKitScrollBox
