-- MoltenCodes DialogKit
--
-- Confirmation and input dialogs without `StaticPopupDialogs`. An addon that
-- adds entries to Blizzard's `StaticPopupDialogs` table and calls
-- `StaticPopup_Show` runs its code inside Blizzard's popup system and can taint
-- it. DialogKit draws its own dialog on one frame of its own, with the client's
-- button and input-box templates: a text, one or two buttons, an optional
-- input line and an optional timeout.
--
-- One dialog is shown at a time; the others wait in a bounded queue and are
-- shown in order. Escape closes the shown dialog through `UISpecialFrames`, the
-- client's list of frames Escape hides. Every dialog ends exactly once, by its
-- accept button (`onAccept`) or by anything else (`onCancel` with the reason),
-- and the callback runs protected.
--
-- DialogKit requires Registry API 2. It reads at call time `CreateFrame`,
-- `UIParent`, `UISpecialFrames`, `GetTime`, `issecretvalue` and
-- `geterrorhandler`.
--
-- Contents
-- --------
--   Constants ............. identity, limits, look, reasons
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, host readers
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Host facilities ....... secret values, the error handler, the clock
--   Argument checks ....... receivers, options, limits
--   Frame ................. the one dialog frame
--   Queue ................. showing, ending and advancing
--   Dialog methods ........ Hide, IsShown, IsQueued, GetInput
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment, self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "dialogKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 2
local REQUIRED_REGISTRY_API = 2
local STATE_SCHEMA = 1

-- Every dialog record carries the layout it was built with, so a later
-- revision that changes the layout can upgrade old records instead of guessing.
local RECORD_SCHEMA = 1

-- The default of `maxQueued`, the dialogs that may wait behind the shown one.
-- A waiting dialog is a Lua table, so the bound opens to `UNBOUNDED`.
local MAX_QUEUED = 16

-- The dialog frame's global name: `UISpecialFrames` lists frames by name.
local FRAME_NAME = "MoltenCodesDialogKitFrame"

-- The look.
local WIDTH = 320
local PADDING = 16
local BUTTON_WIDTH, BUTTON_HEIGHT = 120, 22
local INPUT_HEIGHT = 20
local GAP = 10
local BACKGROUND_COLOR = { 0.05, 0.05, 0.08, 0.95 }

-- Why a dialog was cancelled.
local REASON_CANCEL = "cancel"
local REASON_ESCAPE = "escape"
local REASON_TIMEOUT = "timeout"
local REASON_HIDDEN = "hidden"

-- The options `Show` accepts.
local SHOW_OPTIONS = {
  text = true,
  accept = true,
  cancel = true,
  onAccept = true,
  onCancel = true,
  data = true,
  input = true,
  inputText = true,
  maxLetters = true,
  timeout = true,
  key = true,
  allowSecret = true,
}

-- The `__metatable` of every dialog handle. It hides the handle's metatable.
local DIALOG_METATABLE_TAG = "DialogKit.Dialog"

local FACADE_METHODS = { "Show", "HideAll", "SetLimits", "GetLimits" }
local DIALOG_METHODS = { "Hide", "IsShown", "IsQueued", "GetInput" }

-- Public types ---------------------------------------------------------------

---Why a dialog was cancelled.
---@alias DialogKit.Reason "cancel"|"escape"|"timeout"|"hidden"

---The options of `Show`.
---@class DialogKit.ShowOptions
---@field text string|number The dialog's text; required.
---@field accept string? The accept button's text; default `"OK"`.
---@field cancel (string|false)? The cancel button's text; default `"Cancel"`; `false` for one button.
---@field onAccept fun(data: any, inputText: string?)? Called when the accept button (or Enter) is pressed.
---@field onCancel fun(data: any, reason: DialogKit.Reason)? Called when the dialog ends any other way.
---@field data any Handed to the callbacks.
---@field input boolean? Show an input line.
---@field inputText string? The input line's starting text.
---@field maxLetters integer? The input line's letter limit; default none.
---@field timeout number? Cancel with `"timeout"` after this many seconds shown.
---@field key string? A dialog shown or waiting under this key is returned instead of a second.
---@field allowSecret boolean? Draw a secret `text` instead of refusing it.

---A dialog, shown or waiting.
---@class DialogKit.Dialog
---@field Hide fun(self: DialogKit.Dialog): boolean
---@field IsShown fun(self: DialogKit.Dialog): boolean
---@field IsQueued fun(self: DialogKit.Dialog): boolean
---@field GetInput fun(self: DialogKit.Dialog): string?

---The shared limits.
---@class DialogKit.Limits
---@field maxQueued integer|table Dialogs waiting at once: a positive integer or `DialogKit.UNBOUNDED`; default `16`.

---The DialogKit package facade published through Registry.
---@class DialogKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field MAX_QUEUED integer Default of `maxQueued` (`16`).
---@field FRAME_NAME string The dialog frame's global name.
---@field UNBOUNDED table Sentinel that lifts `maxQueued`; the same table for every revision.
---@field Show fun(self: DialogKit, options: DialogKit.ShowOptions): DialogKit.Dialog
---@field HideAll fun(self: DialogKit): integer
---@field SetLimits fun(self: DialogKit, limits: DialogKit.Limits)
---@field GetLimits fun(self: DialogKit): DialogKit.Limits

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
  error("MoltenCodes DialogKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
if type(bootstrapPackage) ~= "function" then
  error("MoltenCodes DialogKit requires a valid Registry API 2 facade", 2)
end

---Read a host global without triggering a metatable, or `nil`.
---@param name string
---@return any
local function readGlobal(name)
  -- Host APIs are reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

local tableRemove = table.remove

-- Validation -----------------------------------------------------------------

---Whether `implementation` exposes the complete DialogKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
  if
    type(implementation) ~= "table"
    or rawget(implementation, "API") ~= API_GENERATION
    or type(rawget(implementation, "REVISION")) ~= "number"
    or type(rawget(implementation, "UNBOUNDED")) ~= "table"
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

---Whether `value` is an exact integer of one or more.
---@param value any
---@return boolean
local function isPositiveInteger(value)
  return type(value) == "number" and value >= 1 and value ~= math.huge and value % 1 == 0
end

---Whether `currentState` has the fields every API 1 revision shares.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
  if type(currentState) ~= "table" or rawget(currentState, "schema") ~= STATE_SCHEMA then
    return false
  end
  local limits = rawget(currentState, "limits")
  local unbounded = rawget(currentState, "unbounded")
  if type(limits) ~= "table" or type(unbounded) ~= "table" then
    return false
  end
  local maxQueued = rawget(limits, "maxQueued")
  return type(rawget(currentState, "runtimeRevision")) == "number"
    and (maxQueued == unbounded or isPositiveInteger(maxQueued))
    and type(rawget(currentState, "queue")) == "table"
    and type(rawget(currentState, "records")) == "table"
    and type(rawget(currentState, "byKey")) == "table"
    and type(rawget(currentState, "dialogPrototype")) == "table"
    and type(rawget(currentState, "dialogMetatable")) == "table"
    and type(rawget(currentState, "dispatch")) == "table"
    and type(rawget(currentState, "scripts")) == "table"
end

---Whether `implementation` carries package state of this revision's schema,
---and publishes the sentinel that state owns.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
  local currentState = rawget(implementation, "_state")
  return validateStateBase(currentState)
    and rawget(implementation, "UNBOUNDED") == rawget(currentState, "unbounded")
end

-- Bootstrap ------------------------------------------------------------------

-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. What stays here is what only DialogKit can answer.
local DialogKit, previousRevision, selected = bootstrapPackage(Registry, {
  package = PACKAGE_NAME,
  api = API_GENERATION,
  revision = IMPLEMENTATION_REVISION,
  label = "MoltenCodes DialogKit",
  validatePublicSurface = validatePublicSurface,
  validateState = validateCurrentState,
})

if DialogKit == nil then
  -- An equal or newer compatible revision already owns the shared package table.
  return selected
end

local state = rawget(DialogKit, "_state")

if previousRevision == nil then
  if state ~= nil then
    error("MoltenCodes DialogKit package state is corrupted or incomplete", 2)
  end

  -- Functions every loading revision rewrites. The frame holds the closures
  -- below as its scripts for the session, so they look their behaviour up here.
  local dispatch = {}
  local dialogPrototype = {}

  state = {
    schema = STATE_SCHEMA,
    runtimeRevision = 0,
    unbounded = {},
    limits = { maxQueued = MAX_QUEUED },
    -- The dialog shown now (its record), or `false`; the records waiting.
    shown = false,
    queue = {},
    -- Handle to record, and key to record, while shown or waiting.
    records = {},
    byKey = {},
    -- The frame, made on first use.
    frame = false,
    dialogPrototype = dialogPrototype,
    dialogMetatable = { __index = dialogPrototype, __metatable = DIALOG_METATABLE_TAG },
    dispatch = dispatch,
    scripts = {
      accept = function()
        dispatch.accept()
      end,
      cancel = function()
        dispatch.cancel()
      end,
      escape = function()
        dispatch.escape()
      end,
      OnHide = function()
        dispatch.frameHidden()
      end,
      OnUpdate = function()
        dispatch.tick()
      end,
    },
  }
  rawset(DialogKit, "_state", state)
elseif not validateStateBase(state) then
  error("MoltenCodes DialogKit package state is corrupted or incomplete", 2)
end

local queue = rawget(state, "queue")
---@type table<table, table>
local records = rawget(state, "records")
local byKey = rawget(state, "byKey")
local dispatch = rawget(state, "dispatch")
local scripts = rawget(state, "scripts")
local DialogPrototype = rawget(state, "dialogPrototype")
local DIALOG_METATABLE = rawget(state, "dialogMetatable")
local sharedLimits = rawget(state, "limits")
local UNBOUNDED = rawget(state, "unbounded")

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

---The client's time in seconds, `GetTime`, or 0 without it.
---@return number
local function now()
  local getTime = readGlobal("GetTime")
  if type(getTime) ~= "function" then
    return 0
  end
  return getTime()
end

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- DialogKit. `level` is always the value `error` needs *inside the function
-- that receives it*, so every further hop towards `error` adds exactly one.
-- Secrets are checked first, because comparing one raises.

---@param receiver any the table the method was called on
---@param label string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
  -- The secret probe first, so a secret receiver is never compared.
  if isSecret(receiver) or type(receiver) ~= "table" or receiver ~= DialogKit then
    error(label .. " must be called on the DialogKit facade; use " .. label .. "(...)", level)
  end
end

---The record of a dialog handle (shown, waiting or ended), or raise.
---@param receiver any
---@param label string
---@param level integer stack level the failure is reported at
---@return table record
local function requireRecord(receiver, label, level)
  local record = nil
  if
    not isSecret(receiver)
    and type(receiver) == "table"
    and getmetatable(receiver) == DIALOG_METATABLE_TAG
  then
    record = rawget(receiver, "_record")
  end
  if type(record) ~= "table" then
    error(
      label
        .. " must be called on a DialogKit dialog; use dialog:"
        .. label:match("[^:]+$")
        .. "(...)",
      level
    )
  end
  return record
end

---Raise at the caller unless `value` is a non-empty string or a number.
---@param value any
---@param where string
---@param allowSecret boolean|nil `true` accepts a secret; `false` refuses it
---and names the `allowSecret` option; `nil` refuses it for a text that option
---never covers (the button texts)
---@param level integer stack level the failure is reported at
local function validateText(value, where, allowSecret, level)
  if isSecret(value) then
    if allowSecret == nil then
      error(where .. " must not be a secret value", level)
    elseif not allowSecret then
      error(where .. " must not be a secret value; pass allowSecret = true to draw one", level)
    end
    return
  end
  if type(value) == "number" then
    return
  end
  if type(value) ~= "string" or value == "" then
    error(where .. " must be a non-empty string or a number", level)
  end
end

---Check `Show`'s options and return a record for them.
---@param options any
---@param level integer stack level the failure is reported at
---@return table record
local function readShowOptions(options, level)
  local label = "DialogKit:Show"
  if isSecret(options) or type(options) ~= "table" then
    error(label .. " options must be a table", level)
  end
  for key in pairs(options) do
    if isSecret(key) or type(key) ~= "string" or not SHOW_OPTIONS[key] then
      error(
        label .. " options holds an unknown field; see docs/API.md for the fields it accepts",
        level
      )
    end
  end
  local allowSecret = options.allowSecret
  if type(allowSecret) ~= "nil" and (isSecret(allowSecret) or type(allowSecret) ~= "boolean") then
    error(label .. " options.allowSecret must be a boolean", level)
  end
  validateText(options.text, label .. " options.text", allowSecret == true, level + 1)
  local accept = options.accept
  if type(accept) ~= "nil" then
    validateText(accept, label .. " options.accept", nil, level + 1)
  end
  -- `false` asks for one button. A secret is refused before that comparison,
  -- because comparing a secret raises inside DialogKit, not at the caller.
  local cancel = options.cancel
  if isSecret(cancel) then
    error(label .. " options.cancel must not be a secret value", level)
  end
  if type(cancel) ~= "nil" and cancel ~= false then
    validateText(cancel, label .. " options.cancel", nil, level + 1)
  end
  for _, field in ipairs({ "onAccept", "onCancel" }) do
    local callback = options[field]
    if type(callback) ~= "nil" and type(callback) ~= "function" then
      error(label .. " options." .. field .. " must be a function or nil", level)
    end
  end
  local input = options.input
  if type(input) ~= "nil" and (isSecret(input) or type(input) ~= "boolean") then
    error(label .. " options.input must be a boolean", level)
  end
  local inputText = options.inputText
  if type(inputText) ~= "nil" and (isSecret(inputText) or type(inputText) ~= "string") then
    error(label .. " options.inputText must be a string", level)
  end
  local maxLetters = options.maxLetters
  if type(maxLetters) ~= "nil" and (isSecret(maxLetters) or not isPositiveInteger(maxLetters)) then
    error(label .. " options.maxLetters must be a positive integer", level)
  end
  local timeout = options.timeout
  if
    type(timeout) ~= "nil"
    and (
      isSecret(timeout)
      or type(timeout) ~= "number"
      or not (timeout > 0 and timeout < math.huge)
    )
  then
    error(label .. " options.timeout must be a number above 0", level)
  end
  local key = options.key
  if type(key) ~= "nil" and (isSecret(key) or type(key) ~= "string" or key == "") then
    error(label .. " options.key must be a non-empty string", level)
  end
  return {
    schema = RECORD_SCHEMA,
    text = options.text,
    accept = accept or "OK",
    cancel = cancel == nil and "Cancel" or cancel,
    onAccept = options.onAccept or false,
    onCancel = options.onCancel or false,
    data = options.data,
    input = input == true,
    inputText = inputText or "",
    maxLetters = maxLetters or 0,
    timeout = timeout or false,
    key = key or false,
    ended = false,
    handle = false,
    shownAt = 0,
  }
end

-- Frame ----------------------------------------------------------------------

---The dialog frame, made the first time a dialog is shown.
---@return table frame
local function dialogFrame()
  local frame = rawget(state, "frame")
  if frame then
    return frame
  end
  local createFrame, uiParent = readGlobal("CreateFrame"), readGlobal("UIParent")
  if type(uiParent) ~= "table" then
    -- `Show` checked it; only a host that removed it since lands here.
    error("DialogKit needs the client's UIParent", 0)
  end
  frame = createFrame("Frame", FRAME_NAME, uiParent)
  frame:SetFrameStrata("DIALOG")
  frame:SetPoint("TOP", uiParent, "TOP", 0, -135)
  frame:SetWidth(WIDTH)
  frame:EnableMouse(true)
  frame:Hide()
  local background = frame:CreateTexture(nil, "BACKGROUND")
  background:SetAllPoints(frame)
  background:SetColorTexture(
    BACKGROUND_COLOR[1],
    BACKGROUND_COLOR[2],
    BACKGROUND_COLOR[3],
    BACKGROUND_COLOR[4]
  )
  local text = frame:CreateFontString(nil, "ARTWORK")
  text:SetFontObject("GameFontHighlight")
  text:SetPoint("TOP", frame, "TOP", 0, -PADDING)
  text:SetWidth(WIDTH - 2 * PADDING)
  text:SetJustifyH("CENTER")
  frame.text = text
  local input = createFrame("EditBox", nil, frame, "InputBoxTemplate")
  input:SetSize(WIDTH - 2 * PADDING - 10, INPUT_HEIGHT)
  input:SetAutoFocus(false)
  input:SetScript("OnEnterPressed", scripts.accept)
  input:SetScript("OnEscapePressed", scripts.escape)
  frame.input = input
  local acceptButton = createFrame("Button", nil, frame, "UIPanelButtonTemplate")
  acceptButton:SetSize(BUTTON_WIDTH, BUTTON_HEIGHT)
  acceptButton:SetScript("OnClick", scripts.accept)
  frame.acceptButton = acceptButton
  local cancelButton = createFrame("Button", nil, frame, "UIPanelButtonTemplate")
  cancelButton:SetSize(BUTTON_WIDTH, BUTTON_HEIGHT)
  cancelButton:SetScript("OnClick", scripts.cancel)
  frame.cancelButton = cancelButton
  frame:SetScript("OnHide", scripts.OnHide)
  -- Escape hides every frame named in this list; the frame's OnHide then
  -- cancels the dialog with "escape".
  local special = readGlobal("UISpecialFrames")
  if type(special) == "table" then
    special[#special + 1] = FRAME_NAME
  end
  rawset(state, "frame", frame)
  return frame
end

---Lay the frame out for `record` and show it.
---@param record table
local function present(record)
  local frame = dialogFrame()
  local text, input = frame.text, frame.input
  local acceptButton, cancelButton = frame.acceptButton, frame.cancelButton
  -- A secret (only with `allowSecret`) goes to the font string as it is: the
  -- client draws a secret there, while converting it would raise. A plain
  -- number is drawn as its text.
  local shownText = record.text
  if not isSecret(shownText) and type(shownText) == "number" then
    shownText = tostring(shownText)
  end
  text:SetText(shownText)
  local textHeight = text:GetStringHeight()
  if isSecret(textHeight) or type(textHeight) ~= "number" then
    textHeight = 12
  end
  local top = PADDING + textHeight + GAP
  if record.input then
    input:ClearAllPoints()
    input:SetPoint("TOP", frame, "TOP", 0, -top)
    input:SetMaxLetters(record.maxLetters)
    input:SetText(record.inputText)
    input:Show()
    top = top + INPUT_HEIGHT + GAP
  else
    input:SetText("")
    input:Hide()
  end
  acceptButton:SetText(record.accept)
  acceptButton:ClearAllPoints()
  cancelButton:ClearAllPoints()
  if record.cancel then
    cancelButton:SetText(record.cancel)
    acceptButton:SetPoint("TOPRIGHT", frame, "TOP", -GAP / 2, -top)
    cancelButton:SetPoint("TOPLEFT", frame, "TOP", GAP / 2, -top)
    cancelButton:Show()
  else
    acceptButton:SetPoint("TOP", frame, "TOP", 0, -top)
    cancelButton:Hide()
  end
  frame:SetHeight(top + BUTTON_HEIGHT + PADDING)
  record.shownAt = now()
  frame:SetScript("OnUpdate", record.timeout and scripts.OnUpdate or nil)
  rawset(state, "shown", record)
  frame:Show()
  if record.input then
    input:SetFocus()
  end
end

-- Queue ----------------------------------------------------------------------

---Run a dialog's callback once, protected.
---@param callback function|false
---@param ... any
local function runCallback(callback, ...)
  if callback then
    local ok, failure = pcall(callback, ...)
    if not ok then
      reportError(failure)
    end
  end
end

---Forget a record: it is no longer shown, waiting or keyed.
---@param record table
local function forget(record)
  record.ended = true
  records[record.handle] = nil
  if record.key and byKey[record.key] == record then
    byKey[record.key] = nil
  end
end

---Show the next waiting dialog, if any.
local function advance()
  local nextRecord = tableRemove(queue, 1)
  if nextRecord then
    present(nextRecord)
  end
end

---End the shown dialog: accepted, or cancelled for `reason`; then show the
---next one. The frame is hidden first, so a callback that shows a dialog
---queues or shows it normally.
---@param accepted boolean
---@param reason string?
local function finishShown(accepted, reason)
  local record = rawget(state, "shown")
  if not record then
    return
  end
  rawset(state, "shown", false)
  local frame = rawget(state, "frame")
  local inputText = record.input and frame.input:GetText() or nil
  forget(record)
  frame:SetScript("OnUpdate", nil)
  -- The frame's OnHide sees no shown dialog now, so it does nothing.
  frame:Hide()
  if accepted then
    runCallback(record.onAccept, record.data, inputText)
  else
    runCallback(record.onCancel, record.data, reason)
  end
  if not rawget(state, "shown") then
    advance()
  end
end

---The accept button, or Enter in the input line.
function dispatch.accept()
  finishShown(true)
end

---The cancel button.
function dispatch.cancel()
  finishShown(false, REASON_CANCEL)
end

---Escape in the input line.
function dispatch.escape()
  finishShown(false, REASON_ESCAPE)
end

---The frame was hidden by something else than DialogKit: Escape through
---`UISpecialFrames`, or another addon.
---
---The client also runs `OnHide` when only a parent hides, the frame's own
---shown flag staying set: the player hiding the interface (Alt+Z) hides
---`UIParent`. That is not the dialog being dismissed, so it stays and shows
---again with its parent.
function dispatch.frameHidden()
  if not rawget(state, "shown") then
    return
  end
  local frame = rawget(state, "frame")
  if frame and type(frame.IsShown) == "function" and frame:IsShown() then
    return
  end
  finishShown(false, REASON_ESCAPE)
end

---Every frame of a shown dialog with a timeout.
function dispatch.tick()
  local record = rawget(state, "shown")
  if record and record.timeout and now() - record.shownAt >= record.timeout then
    finishShown(false, REASON_TIMEOUT)
  end
end

-- Dialog methods -------------------------------------------------------------

---End the dialog with `onCancel(data, "hidden")`: the shown one makes way for
---the next, a waiting one leaves the queue. `false` when it already ended.
---@param self DialogKit.Dialog
---@return boolean
local function dialogHide(self)
  local record = requireRecord(self, "DialogKit.Dialog:Hide", 3)
  if record.ended then
    return false
  end
  if rawget(state, "shown") == record then
    finishShown(false, REASON_HIDDEN)
    return true
  end
  for index = 1, #queue do
    if queue[index] == record then
      tableRemove(queue, index)
      break
    end
  end
  forget(record)
  runCallback(record.onCancel, record.data, REASON_HIDDEN)
  return true
end

---Whether the dialog is the one on screen.
---@param self DialogKit.Dialog
---@return boolean
local function dialogIsShown(self)
  return rawget(state, "shown") == requireRecord(self, "DialogKit.Dialog:IsShown", 3)
end

---Whether the dialog waits behind the shown one.
---@param self DialogKit.Dialog
---@return boolean
local function dialogIsQueued(self)
  local record = requireRecord(self, "DialogKit.Dialog:IsQueued", 3)
  return not record.ended and rawget(state, "shown") ~= record
end

---The input line's text while the dialog is shown with one, else `nil`.
---@param self DialogKit.Dialog
---@return string?
local function dialogGetInput(self)
  local record = requireRecord(self, "DialogKit.Dialog:GetInput", 3)
  if rawget(state, "shown") ~= record or not record.input then
    return nil
  end
  return rawget(state, "frame").input:GetText()
end

-- Package public API ---------------------------------------------------------

---Show a dialog now, or queue it behind the one shown. A dialog shown or
---waiting under `options.key` is returned instead of a second one.
---@param self DialogKit
---@param options DialogKit.ShowOptions
---@return DialogKit.Dialog
local function packageShow(self, options)
  validateFacade(self, "DialogKit:Show", 3)
  local record = readShowOptions(options, 3)
  if record.key and byKey[record.key] then
    return byKey[record.key].handle
  end
  if type(readGlobal("CreateFrame")) ~= "function" or type(readGlobal("UIParent")) ~= "table" then
    error(
      "DialogKit:Show needs the client's CreateFrame and UIParent, which this host does not have",
      2
    )
  end
  local shown = rawget(state, "shown")
  local maxQueued = rawget(sharedLimits, "maxQueued")
  if shown and maxQueued ~= UNBOUNDED and #queue >= maxQueued then
    error(
      "DialogKit:Show holds at most "
        .. maxQueued
        .. " waiting dialogs; raise maxQueued with DialogKit:SetLimits",
      2
    )
  end
  local handle = setmetatable({ _record = record }, DIALOG_METATABLE)
  record.handle = handle
  records[handle] = record
  if record.key then
    byKey[record.key] = record
  end
  if shown then
    queue[#queue + 1] = record
  else
    present(record)
  end
  return handle
end

---End every dialog, the waiting ones first, each with `onCancel(data,
---"hidden")`. Returns how many ended.
---@param self DialogKit
---@return integer
local function packageHideAll(self)
  validateFacade(self, "DialogKit:HideAll", 3)
  local count = 0
  while #queue > 0 do
    local record = tableRemove(queue)
    forget(record)
    runCallback(record.onCancel, record.data, REASON_HIDDEN)
    count = count + 1
  end
  if rawget(state, "shown") then
    finishShown(false, REASON_HIDDEN)
    count = count + 1
    -- A callback may have shown or queued dialogs; they end too.
    count = count + packageHideAll(self)
  end
  return count
end

---Change `maxQueued`. Lowering it keeps every waiting dialog and refuses
---the next.
---@param self DialogKit
---@param limits DialogKit.Limits
local function packageSetLimits(self, limits)
  validateFacade(self, "DialogKit:SetLimits", 3)
  if isSecret(limits) or type(limits) ~= "table" then
    error("DialogKit:SetLimits limits must be a table", 2)
  end
  for key, value in pairs(limits) do
    if isSecret(key) or key ~= "maxQueued" then
      error("DialogKit:SetLimits limits holds an unknown field; it accepts maxQueued", 2)
    end
    if isSecret(value) then
      error("DialogKit:SetLimits limits.maxQueued must not be a secret value", 2)
    end
    if value ~= UNBOUNDED and not isPositiveInteger(value) then
      error(
        "DialogKit:SetLimits limits.maxQueued must be a positive integer or DialogKit.UNBOUNDED",
        2
      )
    end
  end
  if type(limits.maxQueued) ~= "nil" then
    rawset(sharedLimits, "maxQueued", limits.maxQueued)
  end
end

---Return a fresh copy of the shared limits. Allocates one table per call.
---@param self DialogKit
---@return DialogKit.Limits
local function packageGetLimits(self)
  validateFacade(self, "DialogKit:GetLimits", 3)
  return { maxQueued = rawget(sharedLimits, "maxQueued") }
end

-- Commit ---------------------------------------------------------------------

rawset(DialogPrototype, "Hide", dialogHide)
rawset(DialogPrototype, "IsShown", dialogIsShown)
rawset(DialogPrototype, "IsQueued", dialogIsQueued)
rawset(DialogPrototype, "GetInput", dialogGetInput)

rawset(DialogKit, "API", API_GENERATION)
rawset(DialogKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(DialogKit, "MAX_QUEUED", MAX_QUEUED)
rawset(DialogKit, "FRAME_NAME", FRAME_NAME)
rawset(DialogKit, "UNBOUNDED", UNBOUNDED)
rawset(DialogKit, "Show", packageShow)
rawset(DialogKit, "HideAll", packageHideAll)
rawset(DialogKit, "SetLimits", packageSetLimits)
rawset(DialogKit, "GetLimits", packageGetLimits)

rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(DialogKit) or not validateCurrentState(DialogKit) then
  error("MoltenCodes DialogKit package state is corrupted or incomplete", 2)
end
for index = 1, #DIALOG_METHODS do
  if type(rawget(DialogPrototype, DIALOG_METHODS[index])) ~= "function" then
    error("MoltenCodes DialogKit package state is corrupted or incomplete", 2)
  end
end

return DialogKit
