-- MoltenCodes TooltipKit
--
-- Tooltips laid out in columns: what LibQTip-1.0 gives addons that show a
-- table on hover, a guild list on a broker display or a currency summary. A
-- tooltip has a fixed number of columns, each with its own justification;
-- lines are rows of cells, with headers, separators, cells spanning several
-- columns, colours, and a click or hover handler per line. Past a height
-- limit the lines scroll with the mouse wheel. A tooltip anchors itself to the
-- frame that opened it on the side with room, and can hide itself once the
-- cursor has left both.
--
-- Tooltips are keyed: `Acquire("MyAddon", 3)` returns the open tooltip under
-- that key when there is one, so an `OnEnter` that runs twice does not stack
-- two. Every tooltip and line is a frame the client never frees, so both come
-- from PoolKit pools that keep every released frame for reuse; a released
-- tooltip and its lines are cleared, so no text, colour or handler survives
-- into the next use.
--
-- TooltipKit requires Registry API 2 and PoolKit API 1. It reads at call time
-- `CreateFrame`, `UIParent`, `issecretvalue` and `geterrorhandler`.
--
-- Contents
-- --------
--   Constants ............. identity, limits, look, fonts
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, PoolKit, host readers
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Host facilities ....... secret values, the error handler
--   Argument checks ....... receivers, keys, columns, texts, colours, limits
--   Frames ................ the tooltip and line factories and resets
--   Layout ................ column widths, line heights, scrolling
--   Scripts ............... line handlers, the wheel, auto-hide
--   Tooltip methods ....... AddLine, SetCell, SmartAnchorTo, ...
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment, self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "tooltipKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 2
local REQUIRED_REGISTRY_API = 2
local REQUIRED_POOLKIT_API = 1
local STATE_SCHEMA = 1

-- Every tooltip record carries the layout it was built with, so a later
-- revision that changes the layout can upgrade old records instead of guessing.
local RECORD_SCHEMA = 1

-- Defaults and ceilings of the limits. Tooltips, lines and the cells on them
-- are frames and font strings the session keeps, so none opens to unbounded.
local MAX_TOOLTIPS, TOOLTIPS_CEILING = 16, 64
local MAX_LINES, LINES_CEILING = 256, 1024
local MAX_COLUMNS, COLUMNS_CEILING = 16, 32

-- The limits `SetLimits` accepts and their ceilings, in `GetLimits` order.
local LIMIT_NAMES = { "maxTooltips", "maxLines", "maxColumns" }
local LIMIT_CEILINGS =
  { maxTooltips = TOOLTIPS_CEILING, maxLines = LINES_CEILING, maxColumns = COLUMNS_CEILING }

-- The look: padding inside the tooltip, the gap between columns, the space a
-- line keeps when it is empty, the default separator, the scroll step.
local PADDING = 10
local COLUMN_GAP = 10
local EMPTY_LINE_HEIGHT = 12
local SEPARATOR_HEIGHT = 1
local SEPARATOR_COLOR = { 1, 1, 1, 0.25 }
local WHEEL_STEP = 24
local BACKGROUND_COLOR = { 0.05, 0.05, 0.08, 0.92 }
local HIGHLIGHT_COLOR = { 1, 1, 1, 0.12 }

-- The client's tooltip fonts: every client defines both font objects.
local LINE_FONT = "GameTooltipText"
local HEADER_FONT = "GameTooltipHeaderText"

-- How a column or a cell may be justified.
local JUSTIFY = { LEFT = true, CENTER = true, RIGHT = true }

-- The scripts `SetLineScript` accepts.
local LINE_SCRIPTS = { OnMouseUp = true, OnEnter = true, OnLeave = true }

-- The options `SetCell` accepts.
local CELL_OPTIONS = { span = true, justify = true, font = true, allowSecret = true }

-- The `__metatable` of every tooltip handle. It hides the handle's metatable.
local TOOLTIP_METATABLE_TAG = "TooltipKit.Tooltip"

local FACADE_METHODS = { "Acquire", "Release", "IsAcquired", "SetLimits", "GetLimits" }
local TOOLTIP_METHODS = {
  "AddHeader",
  "AddLine",
  "AddSeparator",
  "SetCell",
  "SetCellTextColor",
  "SetLineColor",
  "SetLineScript",
  "Clear",
  "SetMaxHeight",
  "SmartAnchorTo",
  "SetAutoHideDelay",
  "Show",
  "Hide",
  "IsShown",
  "GetLineCount",
  "GetColumnCount",
  "GetFrame",
}

-- Public types ---------------------------------------------------------------

---What a cell may show: a string, or a number shown with `tostring`.
---@alias TooltipKit.Text string|number

---The options of `SetCell`.
---@class TooltipKit.CellOptions
---@field span integer? How many columns the cell covers, from its own; default `1`.
---@field justify ("LEFT"|"CENTER"|"RIGHT")? The cell's justification; default its column's.
---@field font (string|table)? A font object or its global name; default the line's font.
---@field allowSecret boolean? Draw a secret text instead of refusing it.

---Called for a line's script with the line's frame, the handler's argument and
---what the client passed (the mouse button for `OnMouseUp`).
---@alias TooltipKit.LineHandler fun(frame: table, arg: any, ...: any)

---A tooltip in columns.
---@class TooltipKit.Tooltip
---@field AddHeader fun(self: TooltipKit.Tooltip, ...: TooltipKit.Text?): integer
---@field AddLine fun(self: TooltipKit.Tooltip, ...: TooltipKit.Text?): integer
---@field AddSeparator fun(self: TooltipKit.Tooltip, height: number?, r: number?, g: number?, b: number?, a: number?): integer
---@field SetCell fun(self: TooltipKit.Tooltip, line: integer, column: integer, text: TooltipKit.Text?, options: TooltipKit.CellOptions?)
---@field SetCellTextColor fun(self: TooltipKit.Tooltip, line: integer, column: integer, r: number, g: number, b: number, a: number?)
---@field SetLineColor fun(self: TooltipKit.Tooltip, line: integer, r: number?, g: number?, b: number?, a: number?)
---@field SetLineScript fun(self: TooltipKit.Tooltip, line: integer, script: "OnMouseUp"|"OnEnter"|"OnLeave", handler: TooltipKit.LineHandler?, arg: any)
---@field Clear fun(self: TooltipKit.Tooltip)
---@field SetMaxHeight fun(self: TooltipKit.Tooltip, pixels: number?)
---@field SmartAnchorTo fun(self: TooltipKit.Tooltip, frame: table)
---@field SetAutoHideDelay fun(self: TooltipKit.Tooltip, seconds: number?, alternateFrame: table?)
---@field Show fun(self: TooltipKit.Tooltip)
---@field Hide fun(self: TooltipKit.Tooltip)
---@field IsShown fun(self: TooltipKit.Tooltip): boolean
---@field GetLineCount fun(self: TooltipKit.Tooltip): integer
---@field GetColumnCount fun(self: TooltipKit.Tooltip): integer
---@field GetFrame fun(self: TooltipKit.Tooltip): table

---The shared limits. `SetLimits` accepts any subset; `GetLimits` returns all.
---@class TooltipKit.Limits
---@field maxTooltips integer Tooltips acquired at once: 1 to 64; default `16`.
---@field maxLines integer Lines in one tooltip: 1 to 1024; default `256`.
---@field maxColumns integer Columns of one tooltip: 1 to 32; default `16`.

---The TooltipKit package facade published through Registry.
---@class TooltipKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field Acquire fun(self: TooltipKit, key: string, columns: integer, ...: ("LEFT"|"CENTER"|"RIGHT")?): TooltipKit.Tooltip
---@field Release fun(self: TooltipKit, tooltip: TooltipKit.Tooltip)
---@field IsAcquired fun(self: TooltipKit, key: string): boolean
---@field SetLimits fun(self: TooltipKit, limits: TooltipKit.Limits)
---@field GetLimits fun(self: TooltipKit): TooltipKit.Limits

-- Dependencies ---------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil

-- Ask for Registry by generation and fall back to the alias. A future Registry
-- API generation takes over `MoltenCodes.Registry`, so reading the alias first
-- would hand this file a facade whose contract it was not written against.
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
if Registry == nil and type(namespace) == "table" then
  Registry = rawget(namespace, "Registry")
end
if type(Registry) ~= "table" or rawget(Registry, "API") ~= REQUIRED_REGISTRY_API then
  error("MoltenCodes TooltipKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local getPackage = rawget(Registry, "Get")
if type(bootstrapPackage) ~= "function" or type(getPackage) ~= "function" then
  error("MoltenCodes TooltipKit requires a valid Registry API 2 facade", 2)
end

-- PoolKit keeps every tooltip and line frame for reuse.
local PoolKit = getPackage(Registry, "poolKit", REQUIRED_POOLKIT_API)
if
  type(PoolKit) ~= "table"
  or rawget(PoolKit, "API") ~= REQUIRED_POOLKIT_API
  or type(rawget(PoolKit, "New")) ~= "function"
then
  error("MoltenCodes TooltipKit requires PoolKit API 1 to be loaded first", 2)
end

---Read a host global without triggering a metatable, or `nil`.
---@param name string
---@return any
local function readGlobal(name)
  -- Host APIs are reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

local mathMax, mathMin, selectCount = math.max, math.min, select

-- Validation -----------------------------------------------------------------

---Whether `implementation` exposes the complete TooltipKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
  if
    type(implementation) ~= "table"
    or rawget(implementation, "API") ~= API_GENERATION
    or type(rawget(implementation, "REVISION")) ~= "number"
  then
    return false
  end
  for index = 1, #FACADE_METHODS do
    if type(rawget(implementation, FACADE_METHODS[index])) ~= "function" then
      return false
    end
  end
  return true
end

---Whether `value` is an exact integer from 1 to `ceiling`. `nan` fails every
---comparison.
---@param value any
---@param ceiling number
---@return boolean
local function isIntegerUpTo(value, ceiling)
  return type(value) == "number" and value >= 1 and value <= ceiling and value % 1 == 0
end

---Whether `currentState` has the fields every API 1 revision shares.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
  if type(currentState) ~= "table" or rawget(currentState, "schema") ~= STATE_SCHEMA then
    return false
  end
  local limits = rawget(currentState, "limits")
  if type(limits) ~= "table" then
    return false
  end
  for index = 1, #LIMIT_NAMES do
    local name = LIMIT_NAMES[index]
    if not isIntegerUpTo(rawget(limits, name), LIMIT_CEILINGS[name]) then
      return false
    end
  end
  return type(rawget(currentState, "runtimeRevision")) == "number"
    and type(rawget(currentState, "byKey")) == "table"
    and type(rawget(currentState, "records")) == "table"
    and type(rawget(currentState, "frames")) == "table"
    and type(rawget(currentState, "acquiredCount")) == "number"
    and type(rawget(currentState, "tooltipPrototype")) == "table"
    and type(rawget(currentState, "tooltipMetatable")) == "table"
    and type(rawget(currentState, "dispatch")) == "table"
    and type(rawget(currentState, "scripts")) == "table"
end

---Whether `implementation` carries package state of this revision's schema.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
  return validateStateBase(rawget(implementation, "_state"))
end

-- Bootstrap ------------------------------------------------------------------

-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. What stays here is what only TooltipKit can answer.
local TooltipKit, previousRevision, selected = bootstrapPackage(Registry, {
  package = PACKAGE_NAME,
  api = API_GENERATION,
  revision = IMPLEMENTATION_REVISION,
  label = "MoltenCodes TooltipKit",
  validatePublicSurface = validatePublicSurface,
  validateState = validateCurrentState,
})

if TooltipKit == nil then
  -- An equal or newer compatible revision already owns the shared package table.
  return selected
end

local state = rawget(TooltipKit, "_state")

if previousRevision == nil then
  if state ~= nil then
    error("MoltenCodes TooltipKit package state is corrupted or incomplete", 2)
  end

  -- Functions every loading revision rewrites. Pools and frames hold the
  -- closures below for the session, so they look their behaviour up here.
  local dispatch = {}
  local tooltipPrototype = {}

  state = {
    schema = STATE_SCHEMA,
    runtimeRevision = 0,
    limits = { maxTooltips = MAX_TOOLTIPS, maxLines = MAX_LINES, maxColumns = MAX_COLUMNS },
    -- Key to the record of the tooltip acquired under it; handle to record;
    -- tooltip frame to record.
    byKey = {},
    records = {},
    frames = {},
    acquiredCount = 0,
    -- The pools, made on first use (they need `CreateFrame`).
    tooltipPool = false,
    linePool = false,
    tooltipPrototype = tooltipPrototype,
    tooltipMetatable = { __index = tooltipPrototype, __metatable = TOOLTIP_METATABLE_TAG },
    dispatch = dispatch,
    -- One stable closure per script and pool hook.
    scripts = {
      buildTooltip = function()
        return dispatch.buildTooltip()
      end,
      resetTooltip = function(frame)
        dispatch.resetTooltip(frame)
      end,
      buildLine = function()
        return dispatch.buildLine()
      end,
      resetLine = function(line)
        dispatch.resetLine(line)
      end,
      OnMouseWheel = function(frame, delta)
        dispatch.wheel(frame, delta)
      end,
      OnUpdate = function(frame, elapsed)
        dispatch.autoHide(frame, elapsed)
      end,
      OnMouseUp = function(line, ...)
        dispatch.lineScript(line, "OnMouseUp", ...)
      end,
      OnEnter = function(line, ...)
        dispatch.lineScript(line, "OnEnter", ...)
      end,
      OnLeave = function(line, ...)
        dispatch.lineScript(line, "OnLeave", ...)
      end,
    },
  }
  rawset(TooltipKit, "_state", state)
elseif not validateStateBase(state) then
  error("MoltenCodes TooltipKit package state is corrupted or incomplete", 2)
end

local byKey = rawget(state, "byKey")
---@type table<table, table>
local records = rawget(state, "records")
---@type table<table, table>
local frames = rawget(state, "frames")
local dispatch = rawget(state, "dispatch")
local scripts = rawget(state, "scripts")
local TooltipPrototype = rawget(state, "tooltipPrototype")
local TOOLTIP_METATABLE = rawget(state, "tooltipMetatable")
local sharedLimits = rawget(state, "limits")

-- Host facilities ------------------------------------------------------------

---Whether `value` is a secret value (Retail 12.x). `issecretvalue` is looked
---up at every call, so a probe that appears after load is used at once.
---@param value any
---@return boolean
local function isSecret(value)
  local probe = readGlobal("issecretvalue")
  return type(probe) == "function" and probe(value) == true
end

---Hand `failure` to the host error handler without raising. Outside a client
---it is printed, as the client's own default handler would.
---@param failure any
local function reportError(failure)
  local getErrorHandler = readGlobal("geterrorhandler")
  if type(getErrorHandler) == "function" then
    local handler = getErrorHandler()
    if type(handler) == "function" then
      handler(failure)
      return
    end
  end
  print(failure)
end

---A size the client measured, or 0 when it answered a secret.
---@param value any
---@return number
local function plainSize(value)
  if isSecret(value) or type(value) ~= "number" then
    return 0
  end
  return value
end

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- TooltipKit. `level` is always the value `error` needs *inside the function
-- that receives it*, so every further hop towards `error` adds exactly one.
-- Secrets are checked first, because comparing one raises.

---@param receiver any the table the method was called on
---@param label string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
  -- `type` first: a secret receiver is never a table, and only a table is compared.
  if type(receiver) ~= "table" or receiver ~= TooltipKit then
    error(label .. " must be called on the TooltipKit facade; use " .. label .. "(...)", level)
  end
end

---@param value any
---@param label string
---@param level integer stack level the failure is reported at
local function validateKey(value, label, level)
  if isSecret(value) then
    error(label .. " key must not be a secret value", level)
  end
  if type(value) ~= "string" or value == "" then
    error(label .. " key must be a non-empty string", level)
  end
end

---The record of an acquired tooltip handle, or raise at the caller.
---@param receiver any
---@param label string
---@param level integer stack level the failure is reported at
---@return table record
local function requireRecord(receiver, label, level)
  local record = nil
  if not isSecret(receiver) and type(receiver) == "table" then
    record = records[receiver]
  end
  if record == nil then
    error(
      label
        .. " must be called on an acquired TooltipKit tooltip; use tooltip:"
        .. label:match("[^:]+$")
        .. "(...)",
      level
    )
  end
  return record
end

---Raise at the caller unless `value` is a cell text: `nil`, a string or a
---number, and not a secret unless `allowSecret`.
---@param value any
---@param where string
---@param allowSecret boolean
---@param level integer stack level the failure is reported at
local function validateText(value, where, allowSecret, level)
  if isSecret(value) then
    if not allowSecret then
      error(
        where .. " must not be a secret value; pass { allowSecret = true } to SetCell to draw one",
        level
      )
    end
    return
  end
  local kind = type(value)
  if kind ~= "nil" and kind ~= "string" and kind ~= "number" then
    error(where .. " must be a string, a number or nil", level)
  end
end

---Raise at the caller unless `value` is a colour component from 0 to 1, or
---`nil` when `optional`.
---@param value any
---@param where string
---@param optional boolean
---@param level integer stack level the failure is reported at
local function validateComponent(value, where, optional, level)
  if isSecret(value) then
    error(where .. " must not be a secret value", level)
  end
  if type(value) == "nil" and optional then
    return
  end
  if type(value) ~= "number" or not (value >= 0 and value <= 1) then
    error(where .. " must be a number from 0 to 1", level)
  end
end

---The line record at `line`, or raise at the caller.
---@param record table
---@param line any
---@param label string
---@param level integer stack level the failure is reported at
---@return table lineRecord
local function requireLine(record, line, label, level)
  if isSecret(line) then
    error(label .. " line must not be a secret value", level)
  end
  local lineRecord = type(line) == "number" and record.lines[line] or nil
  if lineRecord == nil then
    error(
      label .. " line must be the index of a line of this tooltip (1 to " .. #record.lines .. ")",
      level
    )
  end
  return lineRecord
end

---Raise at the caller unless `column` is a column of `record`.
---@param record table
---@param column any
---@param label string
---@param level integer stack level the failure is reported at
local function validateColumn(record, column, label, level)
  if isSecret(column) then
    error(label .. " column must not be a secret value", level)
  end
  if not isIntegerUpTo(column, record.columnCount) then
    error(label .. " column must be an integer from 1 to " .. record.columnCount, level)
  end
end

-- Frames ---------------------------------------------------------------------

---A tooltip frame with its background and its scrolling area.
---@return table frame
function dispatch.buildTooltip()
  local createFrame = readGlobal("CreateFrame")
  local uiParent = readGlobal("UIParent")
  if type(uiParent) ~= "table" then
    -- `Acquire` checked it; only a host that removed it since lands here.
    error("TooltipKit needs the client's UIParent", 0)
  end
  local frame = createFrame("Frame", nil, uiParent)
  frame:SetFrameStrata("TOOLTIP")
  frame:SetClampedToScreen(true)
  frame:Hide()
  local background = frame:CreateTexture(nil, "BACKGROUND")
  background:SetAllPoints(frame)
  background:SetColorTexture(
    BACKGROUND_COLOR[1],
    BACKGROUND_COLOR[2],
    BACKGROUND_COLOR[3],
    BACKGROUND_COLOR[4]
  )
  local scroll = createFrame("ScrollFrame", nil, frame)
  scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
  local content = createFrame("Frame", nil, scroll)
  scroll:SetScrollChild(content)
  frame.scroll, frame.content = scroll, content
  frame:SetScript("OnMouseWheel", scripts.OnMouseWheel)
  return frame
end

---Return a tooltip frame to its pool cleared.
---@param frame table
function dispatch.resetTooltip(frame)
  frame:Hide()
  frame:SetScript("OnUpdate", nil)
  frame:EnableMouseWheel(false)
  frame:ClearAllPoints()
  frame.scroll:SetVerticalScroll(0)
end

---A line frame: a background texture and font strings made as columns need.
---@return table line
function dispatch.buildLine()
  -- Parentless until `addLine` puts it in a tooltip's content.
  local line = readGlobal("CreateFrame")("Frame")
  line.background = line:CreateTexture(nil, "BACKGROUND")
  line.background:SetAllPoints(line)
  line.highlight = line:CreateTexture(nil, "HIGHLIGHT")
  line.highlight:SetAllPoints(line)
  line.highlight:SetColorTexture(
    HIGHLIGHT_COLOR[1],
    HIGHLIGHT_COLOR[2],
    HIGHLIGHT_COLOR[3],
    HIGHLIGHT_COLOR[4]
  )
  line.cells = {}
  return line
end

---Return a line to its pool with no text, colour, handler or mouse.
---@param line table
function dispatch.resetLine(line)
  line:Hide()
  line:ClearAllPoints()
  line:EnableMouse(false)
  for _, name in ipairs({ "OnMouseUp", "OnEnter", "OnLeave" }) do
    line:SetScript(name, nil)
  end
  line.background:SetColorTexture(0, 0, 0, 0)
  for _, cell in ipairs(line.cells) do
    cell:SetText(nil)
    cell:SetTextColor(1, 1, 1, 1)
    cell:Hide()
  end
end

---The two pools, made on first use.
---@return table tooltipPool
---@return table linePool
local function pools()
  local tooltipPool, linePool = rawget(state, "tooltipPool"), rawget(state, "linePool")
  if not tooltipPool then
    tooltipPool = PoolKit:New({
      create = scripts.buildTooltip,
      reset = scripts.resetTooltip,
      maxRetained = PoolKit.UNBOUNDED,
      maxCreated = TOOLTIPS_CEILING,
    })
    linePool = PoolKit:New({
      create = scripts.buildLine,
      reset = scripts.resetLine,
      maxRetained = PoolKit.UNBOUNDED,
      maxCreated = MAX_TOOLTIPS * MAX_LINES,
    })
    rawset(state, "tooltipPool", tooltipPool)
    rawset(state, "linePool", linePool)
  end
  return tooltipPool, linePool
end

---The font string of `column` on `line`, made the first time it is needed.
---@param line table
---@param column integer
---@return table
local function cellOf(line, column)
  local cell = line.cells[column]
  if cell == nil then
    cell = line:CreateFontString(nil, "ARTWORK")
    cell:SetWordWrap(false)
    line.cells[column] = cell
  end
  return cell
end

-- Layout ---------------------------------------------------------------------

---The width `cell`'s whole text needs. The client's `GetStringWidth` never
---answers more than the width the font string was given, and every cell was
---given one by the last layout (or by the tooltip a pooled line last served),
---so a text that grew would be measured truncated. `GetUnboundedStringWidth`
---ignores that width; Retail, Mists of Pandaria Classic and Classic Era all
---have it (`SimpleFontStringAPIDocumentation.lua`, branches `live`, `classic`
---and `classic_era`). A font string without it is measured as it is.
---@param cell table
---@return number
local function textWidth(cell)
  if type(cell.GetUnboundedStringWidth) == "function" then
    return plainSize(cell:GetUnboundedStringWidth())
  end
  return plainSize(cell:GetStringWidth())
end

---Lay the tooltip out: column widths from the widest single-column cell,
---spans widening their last column when they need more, line heights from
---their tallest cell, then the frame's size and the scroll range.
---@param record table
local function layout(record)
  local columnCount = record.columnCount
  local widths = {}
  for column = 1, columnCount do
    widths[column] = 0
  end
  local lines = record.lines
  for index = 1, #lines do
    local lineRecord = lines[index]
    if not lineRecord.separator then
      for column, cellRecord in pairs(lineRecord.cells) do
        if cellRecord.span == 1 then
          widths[column] = mathMax(widths[column], textWidth(lineRecord.frame.cells[column]))
        end
      end
    end
  end
  for index = 1, #lines do
    local lineRecord = lines[index]
    for column, cellRecord in pairs(lineRecord.cells) do
      local span = cellRecord.span
      if span > 1 then
        local covered = COLUMN_GAP * (span - 1)
        for spanned = column, column + span - 1 do
          covered = covered + widths[spanned]
        end
        local needed = textWidth(lineRecord.frame.cells[column])
        if needed > covered then
          local last = column + span - 1
          widths[last] = widths[last] + needed - covered
        end
      end
    end
  end

  local starts, contentWidth = {}, PADDING
  for column = 1, columnCount do
    starts[column] = contentWidth
    contentWidth = contentWidth + widths[column] + (column < columnCount and COLUMN_GAP or 0)
  end
  contentWidth = contentWidth + PADDING

  local content = record.frame.content
  local top = PADDING
  for index = 1, #lines do
    local lineRecord = lines[index]
    local line = lineRecord.frame
    local height = lineRecord.separator or EMPTY_LINE_HEIGHT
    if not lineRecord.separator then
      for column, cellRecord in pairs(lineRecord.cells) do
        local cell = line.cells[column]
        local span = cellRecord.span
        local width = COLUMN_GAP * (span - 1)
        for spanned = column, column + span - 1 do
          width = width + widths[spanned]
        end
        cell:ClearAllPoints()
        cell:SetPoint("LEFT", line, "LEFT", starts[column] - PADDING, 0)
        cell:SetWidth(width)
        cell:SetJustifyH(cellRecord.justify)
        height = mathMax(height, plainSize(cell:GetStringHeight()))
      end
    end
    line:ClearAllPoints()
    line:SetPoint("TOPLEFT", content, "TOPLEFT", PADDING, -top)
    line:SetSize(contentWidth - 2 * PADDING, height)
    line:Show()
    top = top + height
  end
  local contentHeight = top + PADDING
  content:SetSize(contentWidth, contentHeight)

  local frameHeight = contentHeight
  local maxHeight = record.maxHeight
  if maxHeight and contentHeight > maxHeight then
    frameHeight = maxHeight
  end
  record.scrollRange = contentHeight - frameHeight
  record.frame:EnableMouseWheel(record.scrollRange > 0)
  local scroll = record.frame.scroll
  if plainSize(scroll:GetVerticalScroll()) > record.scrollRange then
    scroll:SetVerticalScroll(record.scrollRange)
  end
  record.frame:SetSize(contentWidth, frameHeight)
end

---Lay out again now when the tooltip is shown; a hidden one lays out at
---`Show`.
---@param record table
local function changed(record)
  if record.frame:IsShown() then
    layout(record)
  end
end

-- Scripts --------------------------------------------------------------------

---The mouse wheel over a tooltip taller than its limit: scroll by a step.
---@param frame table
---@param delta number
function dispatch.wheel(frame, delta)
  local record = frames[frame]
  if record == nil or isSecret(delta) or type(delta) ~= "number" then
    return
  end
  local scroll = frame.scroll
  local offset = plainSize(scroll:GetVerticalScroll()) - delta * WHEEL_STEP
  scroll:SetVerticalScroll(mathMax(0, mathMin(offset, record.scrollRange)))
end

---Whether the cursor is over `frame`, treating a missing method or a secret
---answer as not over it.
---@param frame any
---@return boolean
local function cursorOver(frame)
  if type(frame) ~= "table" or type(frame.IsMouseOver) ~= "function" then
    return false
  end
  local over = frame:IsMouseOver()
  return not isSecret(over) and over == true
end

---Every frame of a shown auto-hiding tooltip: count the time the cursor is
---off the tooltip, its anchor and the alternate frame; release the tooltip
---once that reaches the delay.
---@param frame table
---@param elapsed number
function dispatch.autoHide(frame, elapsed)
  local record = frames[frame]
  if record == nil or not record.autoHideDelay then
    return
  end
  if cursorOver(frame) or cursorOver(record.anchor) or cursorOver(record.alternateFrame) then
    record.offFor = 0
    return
  end
  record.offFor = record.offFor + plainSize(elapsed)
  if record.offFor >= record.autoHideDelay then
    TooltipKit:Release(record.handle)
  end
end

---A line's script: its handler with the line frame, the argument and what
---the client passed, protected.
---@param line table
---@param script string
---@param ... any
function dispatch.lineScript(line, script, ...)
  local handlers = line.handlers
  local entry = handlers and handlers[script]
  if entry then
    local ok, failure = pcall(entry.handler, line, entry.arg, ...)
    if not ok then
      reportError(failure)
    end
  end
end

-- Tooltip methods ------------------------------------------------------------

---Add a line whose cells are `...`, one per column, in `font`.
---@param record table
---@param label string
---@param font string
---@param ... any
---@return integer index
local function addLine(record, label, font, ...)
  local count = selectCount("#", ...)
  if count > record.columnCount then
    error(label .. " got " .. count .. " values for " .. record.columnCount .. " columns", 3)
  end
  for column = 1, count do
    validateText((selectCount(column, ...)), label .. " value " .. column, false, 4)
  end
  local maxLines = rawget(sharedLimits, "maxLines")
  if #record.lines >= maxLines then
    error(
      label .. " holds at most " .. maxLines .. " lines; raise maxLines with TooltipKit:SetLimits",
      3
    )
  end
  local _, linePool = pools()
  local line, reason = linePool:Acquire()
  if line == nil then
    error(label .. " could not get a line frame: " .. tostring(reason), 3)
  end
  line:SetParent(record.frame.content)
  local lineRecord = { frame = line, cells = {}, font = font, separator = false }
  record.lines[#record.lines + 1] = lineRecord
  for column = 1, count do
    local value = (selectCount(column, ...))
    if type(value) ~= "nil" then
      local cell = cellOf(line, column)
      cell:SetFontObject(font)
      cell:SetText(type(value) == "number" and tostring(value) or value)
      cell:Show()
      lineRecord.cells[column] = { span = 1, justify = record.justify[column] }
    end
  end
  changed(record)
  return #record.lines
end

---Add a line in the client's tooltip header font.
---@param self TooltipKit.Tooltip
---@param ... TooltipKit.Text?
---@return integer index
local function tooltipAddHeader(self, ...)
  local record = requireRecord(self, "TooltipKit.Tooltip:AddHeader", 3)
  -- Not a tail call: `addLine` reports errors two levels up, at the caller.
  local index = addLine(record, "TooltipKit.Tooltip:AddHeader", HEADER_FONT, ...)
  return index
end

---Add a line, one value per column from the left; `nil` leaves a cell empty.
---@param self TooltipKit.Tooltip
---@param ... TooltipKit.Text?
---@return integer index
local function tooltipAddLine(self, ...)
  local record = requireRecord(self, "TooltipKit.Tooltip:AddLine", 3)
  -- Not a tail call: `addLine` reports errors two levels up, at the caller.
  local index = addLine(record, "TooltipKit.Tooltip:AddLine", LINE_FONT, ...)
  return index
end

---Add a thin coloured line across the tooltip.
---@param self TooltipKit.Tooltip
---@param height number?
---@param r number?
---@param g number?
---@param b number?
---@param a number?
---@return integer index
local function tooltipAddSeparator(self, height, r, g, b, a)
  local label = "TooltipKit.Tooltip:AddSeparator"
  local record = requireRecord(self, label, 3)
  if
    type(height) ~= "nil"
    and (isSecret(height) or type(height) ~= "number" or not (height > 0 and height <= 100))
  then
    error(label .. " height must be a number above 0 and at most 100, or nil", 2)
  end
  validateComponent(r, label .. " r", true, 3)
  validateComponent(g, label .. " g", true, 3)
  validateComponent(b, label .. " b", true, 3)
  validateComponent(a, label .. " a", true, 3)
  local index = addLine(record, label, LINE_FONT)
  local lineRecord = record.lines[index]
  lineRecord.separator = height or SEPARATOR_HEIGHT
  lineRecord.frame.background:SetColorTexture(
    r or SEPARATOR_COLOR[1],
    g or SEPARATOR_COLOR[2],
    b or SEPARATOR_COLOR[3],
    a or SEPARATOR_COLOR[4]
  )
  changed(record)
  return index
end

---Set one cell: its text and, through `options`, its span, justification,
---font and whether a secret text may be drawn.
---@param self TooltipKit.Tooltip
---@param line integer
---@param column integer
---@param text TooltipKit.Text?
---@param options TooltipKit.CellOptions?
local function tooltipSetCell(self, line, column, text, options)
  local label = "TooltipKit.Tooltip:SetCell"
  local record = requireRecord(self, label, 3)
  local lineRecord = requireLine(record, line, label, 3)
  validateColumn(record, column, label, 3)
  if lineRecord.separator then
    error(label .. " line " .. line .. " is a separator and has no cells", 2)
  end
  local span, justify, font, allowSecret = 1, record.justify[column], lineRecord.font, false
  if type(options) ~= "nil" then
    if isSecret(options) or type(options) ~= "table" then
      error(label .. " options must be a table or nil", 2)
    end
    for key in pairs(options) do
      if isSecret(key) or type(key) ~= "string" or not CELL_OPTIONS[key] then
        error(
          label .. " options holds an unknown field; it accepts span, justify, font and allowSecret",
          2
        )
      end
    end
    local wanted = rawget(options, "span")
    if type(wanted) ~= "nil" then
      if isSecret(wanted) or not isIntegerUpTo(wanted, record.columnCount - column + 1) then
        error(
          label
            .. " options.span must be an integer from 1 to "
            .. (record.columnCount - column + 1),
          2
        )
      end
      span = wanted
    end
    local wantedJustify = rawget(options, "justify")
    if type(wantedJustify) ~= "nil" then
      if isSecret(wantedJustify) or not JUSTIFY[wantedJustify] then
        error(label .. ' options.justify must be "LEFT", "CENTER" or "RIGHT"', 2)
      end
      justify = wantedJustify
    end
    local wantedFont = rawget(options, "font")
    if type(wantedFont) ~= "nil" then
      if isSecret(wantedFont) or (type(wantedFont) ~= "string" and type(wantedFont) ~= "table") then
        error(label .. " options.font must be a font object or its name", 2)
      end
      font = wantedFont
    end
    local wantedSecret = rawget(options, "allowSecret")
    if type(wantedSecret) ~= "nil" then
      if isSecret(wantedSecret) or type(wantedSecret) ~= "boolean" then
        error(label .. " options.allowSecret must be a boolean", 2)
      end
      allowSecret = wantedSecret
    end
  end
  validateText(text, label .. " text", allowSecret, 3)

  -- The cells a span now covers are emptied, and so is any span this cell
  -- started before.
  local cells = lineRecord.cells
  for covered = column + 1, column + span - 1 do
    if cells[covered] then
      cells[covered] = nil
      lineRecord.frame.cells[covered]:SetText(nil)
      lineRecord.frame.cells[covered]:Hide()
    end
  end
  for before = 1, column - 1 do
    local earlier = cells[before]
    if earlier and before + earlier.span - 1 >= column then
      earlier.span = column - before
    end
  end

  local cell = cellOf(lineRecord.frame, column)
  if type(text) == "nil" then
    cells[column] = nil
    cell:SetText(nil)
    cell:Hide()
  else
    cell:SetFontObject(font)
    cell:SetText((not isSecret(text) and type(text) == "number") and tostring(text) or text)
    cell:Show()
    cells[column] = { span = span, justify = justify }
  end
  changed(record)
end

---Colour one cell's text.
---@param self TooltipKit.Tooltip
---@param line integer
---@param column integer
---@param r number
---@param g number
---@param b number
---@param a number?
local function tooltipSetCellTextColor(self, line, column, r, g, b, a)
  local label = "TooltipKit.Tooltip:SetCellTextColor"
  local record = requireRecord(self, label, 3)
  local lineRecord = requireLine(record, line, label, 3)
  validateColumn(record, column, label, 3)
  validateComponent(r, label .. " r", false, 3)
  validateComponent(g, label .. " g", false, 3)
  validateComponent(b, label .. " b", false, 3)
  validateComponent(a, label .. " a", true, 3)
  cellOf(lineRecord.frame, column):SetTextColor(r, g, b, a or 1)
end

---Colour a line's background; no colour clears it.
---@param self TooltipKit.Tooltip
---@param line integer
---@param r number?
---@param g number?
---@param b number?
---@param a number?
local function tooltipSetLineColor(self, line, r, g, b, a)
  local label = "TooltipKit.Tooltip:SetLineColor"
  local record = requireRecord(self, label, 3)
  local lineRecord = requireLine(record, line, label, 3)
  if type(r) == "nil" and type(g) == "nil" and type(b) == "nil" and type(a) == "nil" then
    lineRecord.frame.background:SetColorTexture(0, 0, 0, 0)
    return
  end
  validateComponent(r, label .. " r", false, 3)
  validateComponent(g, label .. " g", false, 3)
  validateComponent(b, label .. " b", false, 3)
  validateComponent(a, label .. " a", true, 3)
  lineRecord.frame.background:SetColorTexture(r, g, b, a or 1)
end

---Give a line a handler for `OnMouseUp`, `OnEnter` or `OnLeave`; `nil`
---removes it. A line with a handler takes the mouse and highlights.
---@param self TooltipKit.Tooltip
---@param line integer
---@param script string
---@param handler TooltipKit.LineHandler?
---@param arg any
local function tooltipSetLineScript(self, line, script, handler, arg)
  local label = "TooltipKit.Tooltip:SetLineScript"
  local record = requireRecord(self, label, 3)
  local lineRecord = requireLine(record, line, label, 3)
  if isSecret(script) or not LINE_SCRIPTS[script] then
    error(label .. ' script must be "OnMouseUp", "OnEnter" or "OnLeave"', 2)
  end
  if type(handler) ~= "nil" and type(handler) ~= "function" then
    error(label .. " handler must be a function or nil", 2)
  end
  local frame = lineRecord.frame
  frame.handlers = frame.handlers or {}
  if handler then
    frame.handlers[script] = { handler = handler, arg = arg }
    frame:SetScript(script, scripts[script])
  else
    frame.handlers[script] = nil
    frame:SetScript(script, nil)
  end
  frame:EnableMouse(next(frame.handlers) ~= nil)
end

---Release every line; the tooltip stays acquired with its columns.
---@param record table
local function clearLines(record)
  local _, linePool = pools()
  for index = #record.lines, 1, -1 do
    local line = record.lines[index].frame
    line.handlers = nil
    linePool:Release(line)
    record.lines[index] = nil
  end
end

---Remove every line.
---@param self TooltipKit.Tooltip
local function tooltipClear(self)
  local record = requireRecord(self, "TooltipKit.Tooltip:Clear", 3)
  clearLines(record)
  changed(record)
end

---Limit the tooltip's height; taller content scrolls with the wheel. `nil`
---removes the limit.
---@param self TooltipKit.Tooltip
---@param pixels number?
local function tooltipSetMaxHeight(self, pixels)
  local label = "TooltipKit.Tooltip:SetMaxHeight"
  local record = requireRecord(self, label, 3)
  if
    type(pixels) ~= "nil"
    and (
      isSecret(pixels)
      or type(pixels) ~= "number"
      or not (pixels >= 2 * PADDING and pixels < math.huge)
    )
  then
    error(label .. " pixels must be a number of at least " .. 2 * PADDING .. ", or nil", 2)
  end
  record.maxHeight = pixels or false
  changed(record)
end

---Anchor the tooltip to `frame` on the side with room: below it when the
---frame is in the top half of the screen, above it otherwise, and aligned to
---its left edge in the left half, its right edge in the right half.
---@param self TooltipKit.Tooltip
---@param frame table
local function tooltipSmartAnchorTo(self, frame)
  local label = "TooltipKit.Tooltip:SmartAnchorTo"
  local record = requireRecord(self, label, 3)
  if isSecret(frame) or type(frame) ~= "table" or type(frame.GetCenter) ~= "function" then
    error(label .. " frame must be a frame", 2)
  end
  local uiParent = readGlobal("UIParent")
  local x, y = frame:GetCenter()
  local vertical, horizontal = "BOTTOM", "LEFT"
  -- `GetCenter` answers secrets for a frame anchored to a secret, and a
  -- client secret number is a `number` to `type`: each coordinate is asked
  -- about on its own, because comparing a secret raises.
  if
    not isSecret(x)
    and not isSecret(y)
    and type(x) == "number"
    and type(y) == "number"
    and type(frame.GetEffectiveScale) == "function"
    and type(uiParent) == "table"
    and type(uiParent.GetWidth) == "function"
    and type(uiParent.GetHeight) == "function"
    and type(uiParent.GetEffectiveScale) == "function"
  then
    -- The centre is in the frame's own scale; the screen in UIParent's.
    local scale = plainSize(frame:GetEffectiveScale()) / plainSize(uiParent:GetEffectiveScale())
    local width, height = plainSize(uiParent:GetWidth()), plainSize(uiParent:GetHeight())
    if scale > 0 and scale < math.huge then
      if y * scale > height / 2 then
        vertical = "TOP"
      end
      if x * scale > width / 2 then
        horizontal = "RIGHT"
      end
    end
  end
  local tooltipFrame = record.frame
  tooltipFrame:ClearAllPoints()
  if vertical == "TOP" then
    tooltipFrame:SetPoint("TOP" .. horizontal, frame, "BOTTOM" .. horizontal, 0, 0)
  else
    tooltipFrame:SetPoint("BOTTOM" .. horizontal, frame, "TOP" .. horizontal, 0, 0)
  end
  record.anchor = frame
end

---Release the tooltip once the cursor has been off it, its anchor and
---`alternateFrame` for `seconds`. `nil` stops it.
---@param self TooltipKit.Tooltip
---@param seconds number?
---@param alternateFrame table?
local function tooltipSetAutoHideDelay(self, seconds, alternateFrame)
  local label = "TooltipKit.Tooltip:SetAutoHideDelay"
  local record = requireRecord(self, label, 3)
  if
    type(seconds) ~= "nil"
    and (
      isSecret(seconds)
      or type(seconds) ~= "number"
      or not (seconds >= 0 and seconds < math.huge)
    )
  then
    error(label .. " seconds must be a number of 0 or more, or nil", 2)
  end
  if
    type(alternateFrame) ~= "nil" and (isSecret(alternateFrame) or type(alternateFrame) ~= "table")
  then
    error(label .. " alternateFrame must be a frame or nil", 2)
  end
  record.autoHideDelay = seconds or false
  record.alternateFrame = alternateFrame or false
  record.offFor = 0
  record.frame:SetScript("OnUpdate", seconds and scripts.OnUpdate or nil)
end

---Lay the tooltip out and show it.
---@param self TooltipKit.Tooltip
local function tooltipShow(self)
  local record = requireRecord(self, "TooltipKit.Tooltip:Show", 3)
  layout(record)
  record.frame:Show()
end

---Hide the tooltip; it stays acquired.
---@param self TooltipKit.Tooltip
local function tooltipHide(self)
  requireRecord(self, "TooltipKit.Tooltip:Hide", 3).frame:Hide()
end

---Whether the tooltip is shown.
---@param self TooltipKit.Tooltip
---@return boolean
local function tooltipIsShown(self)
  return requireRecord(self, "TooltipKit.Tooltip:IsShown", 3).frame:IsShown() == true
end

---How many lines the tooltip holds, separators included.
---@param self TooltipKit.Tooltip
---@return integer
local function tooltipGetLineCount(self)
  return #requireRecord(self, "TooltipKit.Tooltip:GetLineCount", 3).lines
end

---How many columns the tooltip has.
---@param self TooltipKit.Tooltip
---@return integer
local function tooltipGetColumnCount(self)
  return requireRecord(self, "TooltipKit.Tooltip:GetColumnCount", 3).columnCount
end

---The tooltip's frame, for an addon that styles or anchors it itself.
---@param self TooltipKit.Tooltip
---@return table
local function tooltipGetFrame(self)
  return requireRecord(self, "TooltipKit.Tooltip:GetFrame", 3).frame
end

-- Package public API ---------------------------------------------------------

---The tooltip acquired under `key`, or a new one with `columns` columns
---justified by `...` (each `"LEFT"`, `"CENTER"` or `"RIGHT"`; default left).
---@param self TooltipKit
---@param key string
---@param columns integer
---@param ... string?
---@return TooltipKit.Tooltip
local function packageAcquire(self, key, columns, ...)
  local label = "TooltipKit:Acquire"
  validateFacade(self, label, 3)
  validateKey(key, label, 3)
  local maxColumns = rawget(sharedLimits, "maxColumns")
  if isSecret(columns) or not isIntegerUpTo(columns, maxColumns) then
    error(label .. " columns must be an integer from 1 to " .. maxColumns, 2)
  end
  local justify = {}
  for column = 1, columns do
    local value = (selectCount(column, ...))
    if type(value) ~= "nil" and (isSecret(value) or not JUSTIFY[value]) then
      error(label .. " justify " .. column .. ' must be "LEFT", "CENTER", "RIGHT" or nil', 2)
    end
    justify[column] = value or "LEFT"
  end
  local existing = byKey[key]
  if existing then
    if existing.columnCount ~= columns then
      error(
        label
          .. " "
          .. key
          .. " is acquired with "
          .. existing.columnCount
          .. " columns, not "
          .. columns,
        2
      )
    end
    return existing.handle
  end
  local maxTooltips = rawget(sharedLimits, "maxTooltips")
  if rawget(state, "acquiredCount") >= maxTooltips then
    error(
      label
        .. " holds at most "
        .. maxTooltips
        .. " tooltips at once; release one, or raise maxTooltips",
      2
    )
  end
  if type(readGlobal("CreateFrame")) ~= "function" or type(readGlobal("UIParent")) ~= "table" then
    error(label .. " needs the client's CreateFrame and UIParent, which this host does not have", 2)
  end
  local tooltipPool = pools()
  local frame, reason = tooltipPool:Acquire()
  if frame == nil then
    error(label .. " could not get a tooltip frame: " .. tostring(reason), 2)
  end
  local handle = setmetatable({}, TOOLTIP_METATABLE)
  local record = {
    schema = RECORD_SCHEMA,
    key = key,
    handle = handle,
    frame = frame,
    columnCount = columns,
    justify = justify,
    lines = {},
    maxHeight = false,
    scrollRange = 0,
    anchor = false,
    autoHideDelay = false,
    alternateFrame = false,
    offFor = 0,
  }
  byKey[key] = record
  records[handle] = record
  frames[frame] = record
  rawset(state, "acquiredCount", rawget(state, "acquiredCount") + 1)
  return handle
end

---Give the tooltip, its lines and their cells back to their pools, cleared.
---@param self TooltipKit
---@param tooltip TooltipKit.Tooltip
local function packageRelease(self, tooltip)
  validateFacade(self, "TooltipKit:Release", 3)
  local record = nil
  if not isSecret(tooltip) and type(tooltip) == "table" then
    record = records[tooltip]
  end
  if record == nil then
    error("TooltipKit:Release tooltip must be an acquired TooltipKit tooltip", 2)
  end
  clearLines(record)
  byKey[record.key] = nil
  records[tooltip] = nil
  frames[record.frame] = nil
  rawset(state, "acquiredCount", rawget(state, "acquiredCount") - 1)
  local tooltipPool = pools()
  tooltipPool:Release(record.frame)
end

---Whether a tooltip is acquired under `key`.
---@param self TooltipKit
---@param key string
---@return boolean
local function packageIsAcquired(self, key)
  validateFacade(self, "TooltipKit:IsAcquired", 3)
  validateKey(key, "TooltipKit:IsAcquired", 3)
  return byKey[key] ~= nil
end

---Change any subset of the shared limits. Every value is checked before any
---changes. Raising `maxTooltips` or `maxLines` raises the line pool's
---creation cap to their product.
---@param self TooltipKit
---@param limits TooltipKit.Limits
local function packageSetLimits(self, limits)
  validateFacade(self, "TooltipKit:SetLimits", 3)
  if isSecret(limits) or type(limits) ~= "table" then
    error("TooltipKit:SetLimits limits must be a table", 2)
  end
  for key, value in pairs(limits) do
    if isSecret(key) or type(key) ~= "string" or not LIMIT_CEILINGS[key] then
      error(
        "TooltipKit:SetLimits limits holds an unknown field; it accepts maxTooltips, maxLines and maxColumns",
        2
      )
    end
    if isSecret(value) then
      error("TooltipKit:SetLimits limits." .. key .. " must not be a secret value", 2)
    end
    if not isIntegerUpTo(value, LIMIT_CEILINGS[key]) then
      error(
        "TooltipKit:SetLimits limits."
          .. key
          .. " must be an integer from 1 to "
          .. LIMIT_CEILINGS[key],
        2
      )
    end
  end
  for index = 1, #LIMIT_NAMES do
    local name = LIMIT_NAMES[index]
    if type(rawget(limits, name)) ~= "nil" then
      rawset(sharedLimits, name, rawget(limits, name))
    end
  end
  local _, linePool = pools()
  local wanted = rawget(sharedLimits, "maxTooltips") * rawget(sharedLimits, "maxLines")
  if wanted > linePool:GetMaxCreated() then
    linePool:SetMaxCreated(wanted)
  end
end

---Return a fresh copy of the shared limits. Allocates one table per call.
---@param self TooltipKit
---@return TooltipKit.Limits limits
local function packageGetLimits(self)
  validateFacade(self, "TooltipKit:GetLimits", 3)
  return {
    maxTooltips = rawget(sharedLimits, "maxTooltips"),
    maxLines = rawget(sharedLimits, "maxLines"),
    maxColumns = rawget(sharedLimits, "maxColumns"),
  }
end

-- Commit ---------------------------------------------------------------------

rawset(TooltipPrototype, "AddHeader", tooltipAddHeader)
rawset(TooltipPrototype, "AddLine", tooltipAddLine)
rawset(TooltipPrototype, "AddSeparator", tooltipAddSeparator)
rawset(TooltipPrototype, "SetCell", tooltipSetCell)
rawset(TooltipPrototype, "SetCellTextColor", tooltipSetCellTextColor)
rawset(TooltipPrototype, "SetLineColor", tooltipSetLineColor)
rawset(TooltipPrototype, "SetLineScript", tooltipSetLineScript)
rawset(TooltipPrototype, "Clear", tooltipClear)
rawset(TooltipPrototype, "SetMaxHeight", tooltipSetMaxHeight)
rawset(TooltipPrototype, "SmartAnchorTo", tooltipSmartAnchorTo)
rawset(TooltipPrototype, "SetAutoHideDelay", tooltipSetAutoHideDelay)
rawset(TooltipPrototype, "Show", tooltipShow)
rawset(TooltipPrototype, "Hide", tooltipHide)
rawset(TooltipPrototype, "IsShown", tooltipIsShown)
rawset(TooltipPrototype, "GetLineCount", tooltipGetLineCount)
rawset(TooltipPrototype, "GetColumnCount", tooltipGetColumnCount)
rawset(TooltipPrototype, "GetFrame", tooltipGetFrame)

rawset(TooltipKit, "API", API_GENERATION)
rawset(TooltipKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(TooltipKit, "MAX_TOOLTIPS", MAX_TOOLTIPS)
rawset(TooltipKit, "MAX_LINES", MAX_LINES)
rawset(TooltipKit, "MAX_COLUMNS", MAX_COLUMNS)
rawset(TooltipKit, "TOOLTIPS_CEILING", TOOLTIPS_CEILING)
rawset(TooltipKit, "LINES_CEILING", LINES_CEILING)
rawset(TooltipKit, "COLUMNS_CEILING", COLUMNS_CEILING)
rawset(TooltipKit, "Acquire", packageAcquire)
rawset(TooltipKit, "Release", packageRelease)
rawset(TooltipKit, "IsAcquired", packageIsAcquired)
rawset(TooltipKit, "SetLimits", packageSetLimits)
rawset(TooltipKit, "GetLimits", packageGetLimits)

rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(TooltipKit) or not validateCurrentState(TooltipKit) then
  error("MoltenCodes TooltipKit package state is corrupted or incomplete", 2)
end
for index = 1, #TOOLTIP_METHODS do
  if type(rawget(TooltipPrototype, TOOLTIP_METHODS[index])) ~= "function" then
    error("MoltenCodes TooltipKit package state is corrupted or incomplete", 2)
  end
end

return TooltipKit
