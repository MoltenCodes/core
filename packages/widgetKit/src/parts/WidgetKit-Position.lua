-- MoltenCodes WidgetKit part Position
--
-- `WidgetKit.Anchor` (`FromRect`, `Normalize`, `Apply`, `Read`, `POINTS`), the
-- normalised anchor value type, and `BindPosition`, which keeps a frame's
-- position in a storage table, with the binding handle's methods. SignalKit
-- carries a binding's `OnMoved` listeners; SchedulerKit's `Coalescing` part,
-- when an addon embeds it, debounces the saves.
--
-- Needs SignalKit API 1, after the WidgetKit core. See `docs/API.md`, "Parts", and
-- `docs/INTERNALS.md`, "Parts", for how a part joins the core.

-- Constants ------------------------------------------------------------------

local PART_NAME = "Position"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "widgetKit", 1
-- Default debounce of a position save, in seconds.
local DEFAULT_SAVE_DELAY = 0.2

-- Accepted option fields, as a set, so option validation allocates nothing.
local BINDING_OPTION_KEYS = { key = true, delay = true, restore = true }

local OPTIONAL_SCHEDULERKIT_API = 1
local REQUIRED_SIGNALKIT_API = 1

-- The nine anchor points in election order. `FromRect` keeps the first of
-- equally near points, so this order is the tie-break: the centre, then the
-- edge midpoints, then the corners.
local POINTS = {
  "CENTER",
  "TOP",
  "BOTTOM",
  "LEFT",
  "RIGHT",
  "TOPLEFT",
  "TOPRIGHT",
  "BOTTOMLEFT",
  "BOTTOMRIGHT",
}

-- Where each point sits on a rect, as fractions of its width and height from
-- the bottom-left corner.
local POINT_HORIZONTAL = {
  CENTER = 0.5,
  TOP = 0.5,
  BOTTOM = 0.5,
  LEFT = 0,
  RIGHT = 1,
  TOPLEFT = 0,
  TOPRIGHT = 1,
  BOTTOMLEFT = 0,
  BOTTOMRIGHT = 1,
}
local POINT_VERTICAL = {
  CENTER = 0.5,
  TOP = 1,
  BOTTOM = 0,
  LEFT = 0.5,
  RIGHT = 0.5,
  TOPLEFT = 1,
  TOPRIGHT = 1,
  BOTTOMLEFT = 0,
  BOTTOMRIGHT = 0,
}

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
  error("MoltenCodes WidgetKit part Position requires WidgetKit API 1 to be loaded first", 2)
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

-- SignalKit carries a binding's `OnMoved` listeners.
local SignalKit = Registry:Get("signalKit", REQUIRED_SIGNALKIT_API)
if
  type(SignalKit) ~= "table"
  or rawget(SignalKit, "API") ~= REQUIRED_SIGNALKIT_API
  or type(rawget(SignalKit, "New")) ~= "function"
then
  error("MoltenCodes WidgetKit part Position requires SignalKit API 1 to be loaded first", 2)
end

-- The core's helpers and shared tables, assigned by `bind` from
-- `state.helpers`. A newer core calls `bind` again, so this part runs its
-- helpers from then on (`docs/INTERNALS.md`, "Parts").
local BINDING_METATABLE
local BindingPrototype
local canTouchFrame
local dispatch
local findPackage
local isSecret
local refuseSecret
local reportError
local restingParent
local validateFacade
local validateName
local validateNumber
local validateOptionKeys
local acquireScratch
local releaseScratch
local AnchorFunctions

---Assign the core helpers this part uses.
---@param helpers table the core's `state.helpers`
local function bind(helpers)
  BINDING_METATABLE = helpers.BINDING_METATABLE
  BindingPrototype = helpers.BindingPrototype
  canTouchFrame = helpers.canTouchFrame
  dispatch = helpers.dispatch
  findPackage = helpers.findPackage
  isSecret = helpers.isSecret
  refuseSecret = helpers.refuseSecret
  reportError = helpers.reportError
  restingParent = helpers.restingParent
  validateFacade = helpers.validateFacade
  validateName = helpers.validateName
  validateNumber = helpers.validateNumber
  validateOptionKeys = helpers.validateOptionKeys
  acquireScratch = helpers.acquireScratch
  releaseScratch = helpers.releaseScratch
  AnchorFunctions = helpers.AnchorFunctions
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

-- Anchors --------------------------------------------------------------------
--
-- An anchor is a plain table `{ point, relativeTo, relativePoint, x, y, scale }`
-- that `SetPoint` can consume and a saved variable can hold. `relativeTo` is a
-- global frame name whenever the frame has one.

---Validate a rect and return its four numbers.
---@param rect any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
---@return number left, number bottom, number width, number height
local function readRect(rect, label, level)
  if type(rect) ~= "table" then
    error(label .. " must be a table with left, bottom, width and height", level)
  end
  local left, bottom, width, height = rect.left, rect.bottom, rect.width, rect.height
  if
    type(left) ~= "number"
    or type(bottom) ~= "number"
    or type(width) ~= "number"
    or type(height) ~= "number"
  then
    error(label .. " must be a table with left, bottom, width and height", level)
  end
  return left, bottom, width, height
end

---Elect the point of the parent nearest to the same point of the rect and
---return the anchor that keeps the rect where it is.
---
---The distance compared is between a point of the rect and the same point of
---the parent, squared, so the centre, the four edge midpoints and the four
---corners compete on one scale. Equally near points go to the earlier one in
---`POINTS`. Pure: it reads only its arguments and allocates only the anchor,
---or nothing when `into` is given.
---@param rect WidgetKit.Rect
---@param parentRect WidgetKit.Rect
---@param into table? filled in place and returned
---@return WidgetKit.Anchor
local function anchorFromRect(rect, parentRect, into)
  local left, bottom, width, height = readRect(rect, "WidgetKit.Anchor.FromRect rect", 3)
  local parentLeft, parentBottom, parentWidth, parentHeight =
    readRect(parentRect, "WidgetKit.Anchor.FromRect parentRect", 3)
  if type(into) ~= "nil" and type(into) ~= "table" then
    error("WidgetKit.Anchor.FromRect into must be a table or nil", 2)
  end

  local bestPoint, bestDistance, bestX, bestY = nil, nil, 0, 0
  for index = 1, #POINTS do
    local point = POINTS[index]
    local horizontal = POINT_HORIZONTAL[point]
    local vertical = POINT_VERTICAL[point]
    local offsetX = (left + width * horizontal) - (parentLeft + parentWidth * horizontal)
    local offsetY = (bottom + height * vertical) - (parentBottom + parentHeight * vertical)
    local distance = offsetX * offsetX + offsetY * offsetY
    if bestDistance == nil or distance < bestDistance then
      bestPoint, bestDistance, bestX, bestY = point, distance, offsetX, offsetY
    end
  end

  local anchor = into or {}
  anchor.point = bestPoint
  anchor.relativeTo = nil
  anchor.relativePoint = bestPoint
  anchor.x = bestX
  anchor.y = bestY
  anchor.scale = nil
  return anchor
end

---Validate a point name.
---@param point any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validatePoint(point, label, level)
  if isSecret(point) or type(point) ~= "string" or POINT_HORIZONTAL[point] == nil then
    error(label .. " must be one of the nine anchor points", level)
  end
end

---Validate a frame argument: a table with the methods an anchor needs.
---@param frame any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateAnchorFrame(frame, label, level)
  if
    type(frame) ~= "table"
    or type(frame.SetPoint) ~= "function"
    or type(frame.ClearAllPoints) ~= "function"
    or type(frame.GetPoint) ~= "function"
  then
    error(label .. " must be a frame", level)
  end
end

---The name to store for a relative frame, or the frame itself when unnamed.
---@param relative any
---@return string|table|nil
local function relativeName(relative)
  if type(relative) == "table" and type(relative.GetName) == "function" then
    local name = relative:GetName()
    if type(name) == "string" and not isSecret(name) and name ~= "" then
      return name
    end
  end
  return relative
end

---Turn any of the five `SetPoint` argument forms into an anchor, with the
---relative frame as its global name when it has one. `nil` as the relative
---frame means the frame's parent, as for `SetPoint`, and is resolved to it.
---@param frame WidgetKit.Frame
---@param point string
---@return WidgetKit.Anchor
local function anchorNormalize(frame, point, first, second, third, fourth)
  validateAnchorFrame(frame, "WidgetKit.Anchor.Normalize frame", 3)
  validatePoint(point, "WidgetKit.Anchor.Normalize point", 3)

  local relativeTo, relativePoint, x, y
  if type(first) == "nil" then
    -- `(point)`, or the full form with the parent written as `nil`.
    if type(second) == "string" then
      relativeTo, relativePoint, x, y = nil, second, third, fourth
    else
      relativeTo, relativePoint, x, y = nil, point, 0, 0
    end
  elseif type(first) == "number" then
    relativeTo, relativePoint, x, y = nil, point, first, second
  elseif type(second) == "number" then
    relativeTo, relativePoint, x, y = first, point, second, third
  else
    relativeTo, relativePoint, x, y = first, second, third, fourth
    if not isSecret(relativePoint) and not relativePoint then
      relativePoint = point
    end
  end
  -- A missing offset is 0, as for `SetPoint`. The secret check comes first:
  -- `x or 0` would test a secret as a boolean and raise here; validation
  -- below refuses it at the caller's line instead.
  if not isSecret(x) and not x then
    x = 0
  end
  if not isSecret(y) and not y then
    y = 0
  end

  validatePoint(relativePoint, "WidgetKit.Anchor.Normalize relativePoint", 3)
  validateNumber(x, "WidgetKit.Anchor.Normalize x", 3)
  validateNumber(y, "WidgetKit.Anchor.Normalize y", 3)
  if type(relativeTo) ~= "nil" and type(relativeTo) ~= "table" and type(relativeTo) ~= "string" then
    error("WidgetKit.Anchor.Normalize relativeTo must be a frame, a frame name or nil", 2)
  end
  if type(relativeTo) == "nil" and type(frame.GetParent) == "function" then
    relativeTo = frame:GetParent()
  end

  local scale = 1
  if type(frame.GetScale) == "function" then
    scale = frame:GetScale()
  end

  return {
    point = point,
    relativeTo = relativeName(relativeTo),
    relativePoint = relativePoint,
    x = x,
    y = y,
    scale = scale,
  }
end

---Read the fields of an anchor, which may be a saved-variable view.
---@param anchor any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
---@return string point, any relativeTo, string relativePoint, number x, number y, number? scale
local function readAnchor(anchor, label, level)
  if type(anchor) ~= "table" then
    error(label .. " must be an anchor table", level)
  end
  local point = anchor.point
  validatePoint(point, label .. ".point", level + 1)
  local relativePoint = anchor.relativePoint
  if type(relativePoint) == "nil" then
    relativePoint = point
  end
  validatePoint(relativePoint, label .. ".relativePoint", level + 1)
  -- Not `anchor.x or 0`: a secret offset is refused by validation, not
  -- tested as a boolean.
  local x, y = anchor.x, anchor.y
  if not isSecret(x) and not x then
    x = 0
  end
  if not isSecret(y) and not y then
    y = 0
  end
  validateNumber(x, label .. ".x", level + 1)
  validateNumber(y, label .. ".y", level + 1)
  local relativeTo = anchor.relativeTo
  if isSecret(relativeTo) then
    error(label .. ".relativeTo must not be a secret value", level)
  end
  if type(relativeTo) ~= "nil" and type(relativeTo) ~= "string" and type(relativeTo) ~= "table" then
    error(label .. ".relativeTo must be a frame, a frame name or nil", level)
  end
  local scale = anchor.scale
  if type(scale) ~= "nil" then
    validateNumber(scale, label .. ".scale", level + 1)
    if scale <= 0 then
      error(label .. ".scale must be above 0", level)
    end
  end
  return point, relativeTo, relativePoint, x, y, scale
end

---Anchor `frame` at `anchor`, replacing its anchors and applying its scale.
---A frame `IsForbidden` or `CanBeAccessedInContext` refuses is left alone, and
---so is one whose anchor the client refuses: the frame keeps its points and
---scale.
---@param frame WidgetKit.Frame
---@param anchor WidgetKit.Anchor
---@return boolean applied
---@return string? reason `"forbidden"`, `"unknownRelative"` when `relativeTo` names no frame, or `"refused"` when the client refuses the anchor
local function anchorApply(frame, anchor)
  validateAnchorFrame(frame, "WidgetKit.Anchor.Apply frame", 3)
  local point, relativeTo, relativePoint, x, y, scale =
    readAnchor(anchor, "WidgetKit.Anchor.Apply anchor", 3)
  if not canTouchFrame(frame) then
    return false, "forbidden"
  end
  if type(relativeTo) == "string" then
    local resolved = readGlobal(relativeTo)
    if type(resolved) ~= "table" then
      return false, "unknownRelative"
    end
    relativeTo = resolved
  end
  -- The client refuses a frame anchored to itself (`Cannot anchor to
  -- itself`); a saved anchor naming the frame is refused before anything
  -- changes. `readAnchor` refused a secret `relativeTo`, so this compares a
  -- plain value.
  if rawequal(relativeTo, frame) then
    return false, "refused"
  end

  -- An anchor into a frame that depends on this one (an anchor cycle) is
  -- refused by `SetPoint` only after `ClearAllPoints` ran, which would leave
  -- the frame with no point at all: not drawn, and never draggable back.
  -- The current points and scale are kept in a scratch table first, so a
  -- refusal puts them back. The count and the scale are plain numbers in the
  -- client's documentation; `GetPoint` answers are secret while the frame's
  -- anchoring is, and then cannot be set again from addon code, so each
  -- point is put back under `pcall` and a secret one stays lost.
  local count = 0
  if type(frame.GetNumPoints) == "function" then
    count = frame:GetNumPoints()
  end
  if type(count) ~= "number" or isSecret(count) then
    count = 0
  end
  local canScale = type(scale) ~= "nil" and type(frame.SetScale) == "function"
  local kept = acquireScratch()
  for index = 1, count do
    local base = (index - 1) * 5
    kept[base + 1], kept[base + 2], kept[base + 3], kept[base + 4], kept[base + 5] =
      frame:GetPoint(index)
  end
  if canScale and type(frame.GetScale) == "function" then
    kept.scale = frame:GetScale()
  end

  if canScale then
    frame:SetScale(scale)
  end
  frame:ClearAllPoints()
  local applied = pcall(frame.SetPoint, frame, point, relativeTo, relativePoint, x, y)
  if not applied then
    frame:ClearAllPoints()
    for index = 1, count do
      local base = (index - 1) * 5
      pcall(
        frame.SetPoint,
        frame,
        kept[base + 1],
        kept[base + 2],
        kept[base + 3],
        kept[base + 4],
        kept[base + 5]
      )
    end
    local previousScale = kept.scale
    if type(previousScale) == "number" and not isSecret(previousScale) then
      frame:SetScale(previousScale)
    end
  end
  releaseScratch(kept)
  if not applied then
    return false, "refused"
  end
  return true
end

---The frame's first anchor, normalised; `nil` when it has none, or when the
---client answers it with secret values (`GetPoint` is secret while the frame's
---anchoring is secret), which can be neither inspected nor saved.
---@param frame WidgetKit.Frame
---@return WidgetKit.Anchor?
local function anchorRead(frame)
  validateAnchorFrame(frame, "WidgetKit.Anchor.Read frame", 3)
  local point, relativeTo, relativePoint, x, y = frame:GetPoint(1)
  if
    isSecret(point)
    or isSecret(relativeTo)
    or isSecret(relativePoint)
    or isSecret(x)
    or isSecret(y)
  then
    return nil
  end
  if type(point) == "nil" then
    return nil
  end
  return anchorNormalize(frame, point, relativeTo, relativePoint, x or 0, y or 0)
end

-- Position binding -----------------------------------------------------------

---A frame's rect in screen coordinates: its own rect times its effective
---scale. `nil` when the frame is not positioned.
---@param frame WidgetKit.Frame
---@return number? left, number bottom, number width, number height
local function screenRect(frame)
  local left, bottom, width, height = frame:GetRect()
  -- `GetRect` is secret while the frame's anchoring is secret: such a rect
  -- cannot be measured, so the frame counts as not positioned.
  if
    type(left) == "nil"
    or isSecret(left)
    or isSecret(bottom)
    or isSecret(width)
    or isSecret(height)
  then
    return nil, 0, 0, 0
  end
  local scale = 1
  if type(frame.GetEffectiveScale) == "function" then
    scale = frame:GetEffectiveScale()
  end
  return left * scale, bottom * scale, width * scale, height * scale
end

---@param binding any
---@param methodName string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateBinding(binding, methodName, level)
  if type(binding) ~= "table" or getmetatable(binding) ~= BINDING_METATABLE then
    error(methodName .. " must be called on a WidgetKit binding", level)
  end
end

-- The storage a binding saves into is resolved at every save and restore: a
-- storage function (`function() return db.profile end`) follows a SettingsKit
-- profile switch, where a view captured once would keep writing into the
-- profile it was made for, and turn detached once that profile is deleted or
-- reset away. A save runs from a drag handler or a SchedulerKit debounce,
-- after the frame already moved, so a storage that fails is reported through
-- the host error handler, never raised: the frame stays where the user put
-- it. The helpers live in this block because the main chunk is close to Lua
-- 5.1's limit of 200 active locals.
local saveBinding
do
  ---The binding's storage table, or `nil` and the failure to report.
  ---@param binding table
  ---@return table? storage
  ---@return any failure
  local function resolveStorage(binding)
    local storage = binding._storage
    if type(storage) == "function" then
      local ok, resolved = pcall(storage)
      if not ok then
        return nil, resolved
      end
      if type(resolved) ~= "table" then
        return nil,
          "WidgetKit.Binding storage function must return a table; it returned a " .. type(resolved)
      end
      return resolved
    end
    return storage
  end

  ---`storage[key] = value`, as a function `pcall` can call without a closure.
  ---@param storage table
  ---@param key string
  ---@param value table
  local function store(storage, key, value)
    storage[key] = value
  end

  ---`storage[key]`, likewise: a storage table's `__index` may raise.
  ---@param storage table
  ---@param key string
  ---@return any
  local function fetch(storage, key)
    return storage[key]
  end

  ---Write the binding's current anchor into its storage as a fresh plain
  ---table, so a SettingsKit view validates and stores it like any record. A
  ---storage that cannot be resolved or refuses the write is reported.
  ---@param binding table
  function saveBinding(binding)
    local anchor = binding._anchor
    if type(anchor.point) == "nil" then
      return
    end
    local storage, failure = resolveStorage(binding)
    if type(storage) == "nil" then
      reportError(failure)
      return
    end
    local relativeTo = anchor.relativeTo
    if type(relativeTo) ~= "string" then
      relativeTo = nil
    end
    local ok, refusal = pcall(store, storage, binding._key, {
      point = anchor.point,
      relativeTo = relativeTo,
      relativePoint = anchor.relativePoint,
      x = anchor.x,
      y = anchor.y,
      scale = anchor.scale,
    })
    if not ok then
      reportError(refusal)
    end
  end

  ---Apply the saved anchor, when the storage holds a valid one. A storage
  ---that cannot be resolved, or an anchor that cannot be read, is reported;
  ---an anchor the client refuses is not applied. Either way the frame keeps
  ---its place.
  ---@return boolean restored
  function BindingPrototype:Restore()
    validateBinding(self, "WidgetKit.Binding:Restore", 3)
    if self._released then
      return false
    end
    local storage, failure = resolveStorage(self)
    if type(storage) == "nil" then
      reportError(failure)
      return false
    end
    local ok, saved = pcall(fetch, storage, self._key)
    if not ok then
      reportError(saved)
      return false
    end
    if type(saved) ~= "table" or not canTouchFrame(self._frame) then
      return false
    end
    local applied
    ok, applied = pcall(anchorApply, self._frame, saved)
    if not ok then
      -- A saved anchor this copy cannot read is reported, never raised:
      -- the frame keeps the position it had.
      reportError(applied)
      return false
    end
    if applied then
      local anchor = self._anchor
      anchor.point = saved.point
      anchor.relativeTo = saved.relativeTo
      anchor.relativePoint = saved.relativePoint or saved.point
      anchor.x = saved.x or 0
      anchor.y = saved.y or 0
      anchor.scale = saved.scale
    end
    return applied == true
  end
end

---SchedulerKit when it can debounce, or `nil`. `Debounce` is in SchedulerKit's
---`Coalescing` part: a SchedulerKit that has parts answers `HasPart`, since the
---core of such a SchedulerKit holds a raising stand-in for a part's member;
---an older one is asked whether `Debounce` is a function.
---@return table? SchedulerKit
local function findDebouncer()
  local SchedulerKit = findPackage(Registry, "schedulerKit", OPTIONAL_SCHEDULERKIT_API)
  if type(SchedulerKit) ~= "table" then
    return nil
  end
  if type(SchedulerKit.HasPart) == "function" then
    if SchedulerKit:HasPart("Coalescing") == true then
      return SchedulerKit
    end
    return nil
  end
  if type(SchedulerKit.Debounce) == "function" then
    return SchedulerKit
  end
  return nil
end

---Build a binding. Shared by `WidgetKit:BindPosition` and the `Frame`
---widget's `BindPosition`, so both report argument errors at their caller.
---@param frame WidgetKit.Frame
---@param storage any a table, or a function returning the table at each save and restore
---@param options any
---@param methodName string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@return WidgetKit.Binding
local function newBinding(frame, storage, options, methodName, level)
  validateAnchorFrame(frame, methodName .. " frame", level + 1)
  if type(frame.GetRect) ~= "function" then
    error(methodName .. " frame must be a frame", level)
  end
  if type(storage) ~= "table" and type(storage) ~= "function" then
    error(methodName .. " storage must be a table or a function that returns one", level)
  end

  local key, delay, restore = "anchor", DEFAULT_SAVE_DELAY, true
  if type(options) ~= "nil" then
    validateOptionKeys(options, BINDING_OPTION_KEYS, methodName .. " options", level + 1)
    if type(options.key) ~= "nil" then
      validateName(options.key, methodName .. " options.key", level + 1)
      key = options.key
    end
    if type(options.delay) ~= "nil" then
      validateNumber(options.delay, methodName .. " options.delay", level + 1)
      if options.delay < 0 then
        error(methodName .. " options.delay must not be negative", level)
      end
      delay = options.delay
    end
    if type(options.restore) ~= "nil" then
      -- `type` answers "boolean" for a secret; `if restore` would raise.
      refuseSecret(options.restore, methodName .. " options.restore", level + 1)
      if type(options.restore) ~= "boolean" then
        error(methodName .. " options.restore must be a boolean", level)
      end
      restore = options.restore
    end
  end

  local binding = setmetatable({
    _frame = frame,
    _storage = storage,
    _key = key,
    _anchor = {},
    _signal = SignalKit:New(),
    _debounce = nil,
    _released = false,
  }, BINDING_METATABLE)

  -- SchedulerKit, when an addon embeds it, coalesces a burst of moves into
  -- one save. Without it every capture saves at once. The debounced save
  -- calls through `dispatch`, so a newer revision replaces how a pending
  -- save of this binding is written.
  local SchedulerKit = findDebouncer()
  if SchedulerKit ~= nil then
    binding._debounce = SchedulerKit:Debounce(function()
      dispatch.saveBinding(binding)
    end, delay)
  end

  if restore then
    BindingPrototype.Restore(binding)
  end
  return binding
end

---Bind `frame`'s position to `storage[options.key or "anchor"]`.
---@param frame WidgetKit.Frame
---@param storage table|(fun(): table) a plain table or a SettingsKit scope view, or a function returning one at each save and restore (`function() return db.profile end`)
---@param options WidgetKit.BindingOptions?
---@return WidgetKit.Binding
local function bindPosition(self, frame, storage, options)
  validateFacade(self, "WidgetKit:BindPosition", 3)
  return newBinding(frame, storage, options, "WidgetKit:BindPosition", 3)
end

---Read the frame's position, re-anchor it at the nearest point of its parent,
---save that anchor (debounced when SchedulerKit is present) and fire
---`OnMoved(binding, anchor)`.
---@return WidgetKit.Anchor|nil anchor the binding's own anchor table; copy what you keep
---@return string? reason `"released"`, `"forbidden"` or `"notPositioned"`
function BindingPrototype:Capture()
  validateBinding(self, "WidgetKit.Binding:Capture", 3)
  if self._released then
    return nil, "released"
  end

  local frame = self._frame
  if not canTouchFrame(frame) then
    return nil, "forbidden"
  end
  local left, bottom, width, height = screenRect(frame)
  if type(left) == "nil" then
    return nil, "notPositioned"
  end
  local parent = type(frame.GetParent) == "function" and frame:GetParent() or nil
  if type(parent) == "nil" then
    parent = restingParent()
  end
  if type(parent) ~= "table" or type(parent.GetRect) ~= "function" then
    return nil, "notPositioned"
  end
  local parentLeft, parentBottom, parentWidth, parentHeight = screenRect(parent)
  if type(parentLeft) == "nil" then
    return nil, "notPositioned"
  end

  -- `FromRect` reads plain rect fields; reuse two tables kept on the binding.
  local rect = self._rect
  if rect == nil then
    rect = {}
    self._rect = rect
    self._parentRect = {}
  end
  local parentRect = self._parentRect
  rect.left, rect.bottom, rect.width, rect.height = left, bottom, width, height
  parentRect.left, parentRect.bottom = parentLeft, parentBottom
  parentRect.width, parentRect.height = parentWidth, parentHeight

  local anchor = anchorFromRect(rect, parentRect, self._anchor)
  local scale = type(frame.GetEffectiveScale) == "function" and frame:GetEffectiveScale() or 1
  anchor.x = anchor.x / scale
  anchor.y = anchor.y / scale
  anchor.relativeTo = relativeName(parent)
  anchor.scale = type(frame.GetScale) == "function" and frame:GetScale() or 1

  frame:ClearAllPoints()
  frame:SetPoint(anchor.point, parent, anchor.relativePoint, anchor.x, anchor.y)

  local debounce = self._debounce
  if debounce ~= nil then
    debounce()
  else
    saveBinding(self)
  end
  self._signal:Fire(self, anchor)
  return anchor
end

---Save a debounced anchor now.
---@return boolean saved `false` when nothing was pending
function BindingPrototype:Flush()
  validateBinding(self, "WidgetKit.Binding:Flush", 3)
  local debounce = self._debounce
  if debounce == nil or self._released then
    return false
  end
  return debounce:Flush() == true
end

---Connect `callback(binding, anchor)` to every capture.
---@param callback fun(binding: WidgetKit.Binding, anchor: WidgetKit.Anchor)
---@return table connection a SignalKit connection
function BindingPrototype:OnMoved(callback)
  validateBinding(self, "WidgetKit.Binding:OnMoved", 3)
  if type(callback) ~= "function" then
    error("WidgetKit.Binding:OnMoved callback must be a function", 2)
  end
  if self._released then
    error("WidgetKit.Binding:OnMoved cannot be called on a released binding", 2)
  end
  return self._signal:Connect(callback)
end

---Save what is pending and stop listening.
---@return boolean released `false` when it was already released
function BindingPrototype:Release()
  validateBinding(self, "WidgetKit.Binding:Release", 3)
  if self._released then
    return false
  end
  local debounce = self._debounce
  if debounce ~= nil then
    debounce:Flush()
    debounce:Close()
    self._debounce = nil
  end
  self._signal:DisconnectAll()
  self._released = true
  return true
end

---@return boolean
function BindingPrototype:IsReleased()
  validateBinding(self, "WidgetKit.Binding:IsReleased", 3)
  return self._released == true
end

-- Commit ---------------------------------------------------------------------

rawset(AnchorFunctions, "POINTS", POINTS)
rawset(AnchorFunctions, "FromRect", anchorFromRect)
rawset(AnchorFunctions, "Normalize", anchorNormalize)
rawset(AnchorFunctions, "Apply", anchorApply)
rawset(AnchorFunctions, "Read", anchorRead)
rawset(WidgetKit, "BindPosition", bindPosition)
rawset(dispatch, "saveBinding", saveBinding)
rawset(rawget(state, "parts"), PART_NAME, {
  revision = PART_REVISION,
  bind = bind,
  -- `Frame:BindPosition` builds its binding through this.
  newBinding = newBinding,
})

return WidgetKit
