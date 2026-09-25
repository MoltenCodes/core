-- MoltenCodes Test: WidgetKitSuite.lua
--
-- Real-client suites for the `widgetKit` package. The Busted specs under
-- packages/widgetKit/tests/ prove WidgetKit against a fake frame API that
-- stores points and sizes in tables; these prove, inside the game client with
-- the installed MoltenCodes addon, what that fixture can only simulate:
--
--   * the installed facade and its committed revision, the twelve base types at
--     the versions docs/API.md gives, and the client facilities WidgetKit
--     builds on;
--   * each of the twelve base widget types on real frames: `Create` acquires it
--     with the documented defaults, setters and getters round-trip through the
--     client's frames, programmatic setters fire no callback while the
--     documented stand-ins for user input do (`Dropdown:PickIndex`, `Click` on
--     the widget's own buttons, the client's own slider and edit-box scripts),
--     and a release hides the frame, re-parents it to `UIParent`, and the next
--     `Create` hands back the same widget on the same frame at its defaults;
--   * the `List`, `Fill` and `Flow` layouts, read back with `GetPoint` and
--     `GetRect` from real frames, with the client's own font metrics (string
--     widths and heights are logged);
--   * anchors: `Anchor.Normalize`, `Anchor.Read` and `Anchor.Apply` on real
--     frames, an anchor the client's `SetPoint` refuses (the frame itself, an
--     anchor cycle) leaving the frame on its points and scale, and a position
--     binding that captures the nearest point of `UIParent`, saves a plain
--     table and restores it on another frame;
--   * the media picker over MediaKit's real font and status-bar lists;
--   * `RenderOptions` of a small OptionsKit tree into a hidden container, with
--     writes through the widgets, an inline refusal and in-place refreshes;
--   * the allocation-free `Create`/`Release` cycle of every base type, and
--     `PerformLayout` and `Fire`, on the client's collector;
--   * argument errors pointing at this file as the client names it, and
--     secret values made by the client's `secretwrap` refused or shown as
--     docs/API.md ("Secret values") says;
--   * what the client reports about taint while the suites run.
--
-- The owner is not disturbed. Every widget is created with alpha 0 and placed
-- on a stage frame of this file's own: alpha 0, off-screen (its top-left
-- corner 4000 pixels left of and above the screen's), not mouse-enabled and
-- hidden again by the After hook. The `Frame` window type is clamped to the
-- screen by WidgetKit, so the tests unclamp it while they hold it and clamp it
-- again once it is back in its pool. Two tests show something on screen for
-- the length of one synchronous step, and say why where they do it: the
-- `Dropdown` test opens a list (it lives on `UIParent`, as documented) and
-- closes it before the step ends, and the `ColorPicker` test opens the
-- client's `ColorPickerFrame` through WidgetKit and hides it before the step
-- ends. The client draws nothing in the middle of a step, so neither is ever
-- rendered. No key, click or mouse movement of the player is needed or
-- intercepted.
--
-- The suites run unchanged on Retail, Classic Era and Mists of Pandaria
-- Classic: every function, widget method and event they use that the Retail
-- apiKit metadata documents is documented for both Classic flavours too; the
-- core globals (CreateFrame, issecurevariable, geterrorhandler) and FrameXML
-- (templates, font objects) are outside the metadata and present on all three.
-- The one FrameXML facility docs/API.md calls optional,
-- `ColorPickerFrame:SetupColorPickerAndShow`, is asked of the client by the
-- `ColorPicker` test, which skips, naming it, when it is absent.
--
-- Run with `/mct run widgetKit`; tests/client/MoltenCodesTest_WidgetKit/EXPECTED.md
-- lists what the chat frame should show.
--
-- What a run leaves behind. Every widget, binding, rendering and options tree
-- a test creates is released or undefined by the After hook of its suite,
-- whatever the test's outcome, and every frame this file set to alpha 0 or
-- unclamped gets its alpha and clamping back once it is in its pool again.
-- What stays in the session: the frames WidgetKit's pools built (the client
-- never frees a frame; they are pooled for the next `Create`), the dropdown
-- catcher and the sixteen list rows of a `Dropdown` once opened, and ten
-- plain frames of this file's own (the stage, eight probes for the anchor,
-- binding and secret tests, and the event listener below), created once and
-- reused by later runs. The event listener
-- stays registered for `ADDON_ACTION_BLOCKED` and `ADDON_ACTION_FORBIDDEN`
-- so the taint test can report them. WidgetKit's package-wide limits are not
-- changed: every `SetLimits` call here is a refusal the tests check. No type
-- or layout is registered, nothing is written to a global or a saved
-- variable, and no client setting changes.

local addonName = ...

-- The harness is this addon's dependency and publishes one documented global.
-- selene: allow(global_usage)
local Harness = rawget(_G, "MoltenCodesTest")
-- The shared MoltenCodes namespace is the one documented global handoff point.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
if type(Harness) ~= "table" or type(namespace) ~= "table" then
  error(addonName .. " requires the MoltenCodesTest harness and the MoltenCodes addon", 0)
end

local REGISTRY_API = 2
local WIDGET_KIT_API = 1
local OPTIONS_KIT_API = 1
local MEDIA_KIT_API = 1
local SCHEDULER_KIT_API = 1
local PACKAGE_ID = "widgetKit"

--- The file name the client puts in front of every error raised at a line of
--- this file.
local THIS_FILE = "WidgetKitSuite.lua"

--- The twelve base widget types docs/API.md ("Base widgets") lists.
local BASE_TYPES = {
  "Frame",
  "Group",
  "ScrollFrame",
  "Label",
  "Button",
  "CheckBox",
  "Slider",
  "EditBox",
  "Dropdown",
  "ColorPicker",
  "Heading",
  "Spacer",
}

--- The version docs/API.md ("Base widgets") gives each base type: revision 6
--- raised every type whose constructor it changed to 2, revision 7 raised the
--- same ten to 3 (secret texts on a font string of their own), and revision 8
--- raised `Frame` to 4 (its `BindPosition` takes a storage function).
local BASE_TYPE_VERSIONS = {
  Frame = 4,
  Group = 3,
  ScrollFrame = 1,
  Label = 3,
  Button = 3,
  CheckBox = 3,
  Slider = 3,
  EditBox = 3,
  Dropdown = 3,
  ColorPicker = 3,
  Heading = 3,
  Spacer = 1,
}

--- The stage every root widget is placed on: its top-left corner this far
--- left of and above the screen's top-left corner, so nothing on it is on
--- screen whatever the resolution and UI scale, and this large, so every
--- layout below fits on it.
local STAGE_OFFSET = 4000
local STAGE_SIZE = 1000

--- How far apart two numbers WidgetKit computed and the client stored (an
--- anchor offset, a size set by `SetWidth`) may be and still count as equal.
local PIXEL_TOLERANCE = 0.01

--- How far a rect the client computed from anchors may be from the one the
--- layout asked for. The client may snap a frame's edges to the physical
--- pixel grid, which at a UI scale below 1 moves an edge by up to one
--- interface unit; the exact offsets are checked with `GetPoint` instead, and
--- each layout test logs the largest deviation it saw.
local RECT_TOLERANCE = 1

--- How many cycles each allocation guard measures, and the kilobytes it
--- tolerates. One table per cycle would cost well over ten kilobytes; the
--- tolerance absorbs a stray allocation by the client between two readings.
local ALLOCATION_CYCLES = 500
local ALLOCATION_TOLERANCE_KB = 1

--- Why the `ColorPicker` test is skipped on a client whose colour picker
--- lacks the optional facility docs/API.md names for `OpenPicker`.
local COLOR_PICKER_SKIP_REASON =
  "the client has no ColorPickerFrame:SetupColorPickerAndShow; the client picker path was not exercised"

--- A sentence long enough to wrap at every width a test gives a Label.
local LONG_TEXT = "WidgetKit lays its children out only when asked, so this sentence"
  .. " must wrap onto several lines of the label's width before the List layout"
  .. " reads the label's height and places the next child below it."

--- The short text whose width the metrics test measures in three fonts.
local SHORT_TEXT = "Molten Codes"

--- A frame name that no client and no addon defines, for `unknownRelative`.
local UNKNOWN_FRAME_NAME = "MoltenCodesTest_WidgetKit_NoSuchFrame"

-- Resolving the client and the framework ---------------------------------------------

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- CreateFrame, UIParent, the font objects, ColorPickerFrame, the error
  -- handler and the secret-value and taint functions are World of Warcraft
  -- client globals, reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, REGISTRY_API)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- WidgetKit, OptionsKit and MediaKit are not in the language-server workspace
-- of tests/client (its .luarc.json lists TestKit's dependency closure only),
-- so their facades, widgets and the client's frames are typed `any` here;
-- each package's docs/API.md is the contract.

---@type any
local WidgetKit = Registry:Get(PACKAGE_ID, WIDGET_KIT_API)
if type(WidgetKit) == "nil" then
  error(addonName .. " requires WidgetKit API 1 in the MoltenCodes addon; reinstall it", 0)
end

---@type any
local OptionsKit = Registry:Get("optionsKit", OPTIONS_KIT_API)
---@type any
local MediaKit = Registry:Get("mediaKit", MEDIA_KIT_API)

local createFrame = readHost("CreateFrame")
local uiParent = readHost("UIParent")
if type(createFrame) ~= "function" or type(uiParent) ~= "table" then
  error(addonName .. " requires the client's CreateFrame and UIParent", 0)
end

--- Read once at load: the secrets suite registers its tests as skipped when
--- the client cannot make a secret value.
local isSecretValue = readHost("issecretvalue")
local secretWrap = readHost("secretwrap")
local SECRETS_AVAILABLE = type(isSecretValue) == "function" and type(secretWrap) == "function"

---Whether `value` is a secret, asking the client's `issecretvalue`.
---@param value any
---@return boolean
local function isSecret(value)
  if type(isSecretValue) ~= "function" then
    return false
  end
  return isSecretValue(value) == true
end

-- Frames of this file ---------------------------------------------------------------------

--- The stage, created on first use and reused by later runs.
---@type any
local stageFrame = nil

---The stage frame, shown: alpha 0, off-screen, not mouse-enabled. Every root
---widget is parented to it, so everything on it inherits its alpha of 0.
---@return any
local function stage()
  if stageFrame == nil then
    local frame = createFrame("Frame", nil, uiParent)
    frame:SetSize(STAGE_SIZE, STAGE_SIZE)
    frame:SetPoint("TOPLEFT", uiParent, "TOPLEFT", -STAGE_OFFSET, STAGE_OFFSET)
    frame:SetAlpha(0)
    frame:EnableMouse(false)
    stageFrame = frame
  end
  stageFrame:Show()
  return stageFrame
end

--- Plain probe frames by purpose, created once and reused by later runs,
--- because the client never frees a frame.
---@type table<string, any>
local probeFrames = {}

---A plain probe frame: 10 by 10, alpha 0, no texture, not mouse-enabled,
---parented to `UIParent`, shown and without anchors. Nothing is drawn for it.
---@param purpose string
---@return any
local function probeFrame(purpose)
  local frame = probeFrames[purpose]
  if frame == nil then
    frame = createFrame("Frame", nil, uiParent)
    frame:SetAlpha(0)
    frame:EnableMouse(false)
    probeFrames[purpose] = frame
  end
  frame:SetParent(uiParent)
  frame:SetScale(1)
  frame:SetSize(10, 10)
  frame:ClearAllPoints()
  frame:Show()
  return frame
end

---Park every probe frame: no anchors, hidden.
local function parkProbeFrames()
  for _, frame in pairs(probeFrames) do
    frame:ClearAllPoints()
    frame:SetScale(1)
    frame:Hide()
  end
end

--- What the client reported about blocked or forbidden actions since this
--- file loaded: one entry per `ADDON_ACTION_BLOCKED` or
--- `ADDON_ACTION_FORBIDDEN`, with the addon and function the client named.
---@type { event: string, addon: any, action: any }[]
local blockedActions = {}

-- The listener is a hidden frame of this file's own; it only records.
do
  local listener = createFrame("Frame")
  listener:Hide()
  listener:RegisterEvent("ADDON_ACTION_BLOCKED")
  listener:RegisterEvent("ADDON_ACTION_FORBIDDEN")
  listener:SetScript("OnEvent", function(_, event, blockedAddon, action)
    if #blockedActions < 64 then
      blockedActions[#blockedActions + 1] = { event = event, addon = blockedAddon, action = action }
    end
  end)
end

-- Objects of the running test ------------------------------------------------------------

--- Widgets the running test created, in order; the After hook releases the
--- ones still active.
---@type any[]
local trackedWidgets = {}

--- Bindings, renderings and tree names the running test created.
---@type any[]
local trackedBindings = {}
---@type any[]
local trackedRenderings = {}
---@type string[]
local definedTrees = {}

--- Frames this file changed, with what to put back once their widget is back
--- in its pool: `{ widget, alpha, clamped }`.
---@type table<any, { widget: any, alpha: number, clamped: boolean|nil }>
local hushedFrames = {}

--- Whether the running test opened the client's ColorPickerFrame.
local openedColorPicker = false

---Make a widget's frame invisible for the length of the test: alpha 0 and,
---for a `Frame` window (which WidgetKit clamps to the screen), unclamped so it
---can sit off-screen. What was there is recorded for `restoreFrame`.
---@param widget any
local function hush(widget)
  local frame = widget:GetFrame()
  if hushedFrames[frame] == nil then
    local clamped = nil
    if widget:GetType() == "Frame" then
      clamped = frame:IsClampedToScreen() == true
    end
    hushedFrames[frame] = { widget = widget, alpha = frame:GetAlpha(), clamped = clamped }
  end
  frame:SetAlpha(0)
  if widget:GetType() == "Frame" then
    frame:SetClampedToScreen(false)
  end
end

---Put a hushed frame's alpha and clamping back, unless its widget is in use
---again (which only a later `Create` of this file does).
---@param frame any
local function restoreFrame(frame)
  local saved = hushedFrames[frame]
  if saved == nil or WidgetKit:IsWidget(saved.widget) then
    return
  end
  hushedFrames[frame] = nil
  frame:SetAlpha(saved.alpha)
  if type(saved.clamped) == "boolean" then
    frame:SetClampedToScreen(saved.clamped)
  end
end

---Create a widget of `typeName` for the running test, hushed, or fail.
---@param ctx TestKit.Context
---@param typeName string
---@return any widget
local function create(ctx, typeName)
  local widget, reason = WidgetKit:Create(typeName)
  if type(widget) == "nil" then
    ctx:Fail(("WidgetKit:Create(%q) answered nil, %s"):format(typeName, tostring(reason)))
  end
  hush(widget)
  trackedWidgets[#trackedWidgets + 1] = widget
  return widget
end

---Put a root widget on the stage: parented to it, top-left corner at its own.
---@param widget any
---@return any widget
local function place(widget)
  local frame = stage()
  widget:SetParent(frame)
  widget:ClearAllPoints()
  widget:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  return widget
end

---Create a root widget on the stage.
---@param ctx TestKit.Context
---@param typeName string
---@return any widget
local function createPlaced(ctx, typeName)
  return place(create(ctx, typeName))
end

---Close every open dropdown list, release every rendering, binding and widget
---the running test created, undefine its trees, put every hushed frame back,
---hide the client's colour picker when the test left it open, and park the
---stage and the probes. The After hook of every suite.
local function cleanUp()
  for index = #trackedRenderings, 1, -1 do
    local rendering = trackedRenderings[index]
    trackedRenderings[index] = nil
    pcall(rendering.Release, rendering)
  end
  for index = #trackedBindings, 1, -1 do
    local binding = trackedBindings[index]
    trackedBindings[index] = nil
    pcall(binding.Release, binding)
  end
  for index = #trackedWidgets, 1, -1 do
    local widget = trackedWidgets[index]
    trackedWidgets[index] = nil
    if WidgetKit:IsWidget(widget) and not widget:IsReleasing() then
      if widget:GetType() == "Dropdown" then
        pcall(widget.Close, widget)
      end
      pcall(WidgetKit.Release, WidgetKit, widget)
    end
  end
  for frame in pairs(hushedFrames) do
    restoreFrame(frame)
  end
  for index = #definedTrees, 1, -1 do
    local name = definedTrees[index]
    definedTrees[index] = nil
    if type(OptionsKit) == "table" then
      pcall(OptionsKit.Undefine, OptionsKit, name)
    end
  end
  if openedColorPicker then
    openedColorPicker = false
    local picker = readHost("ColorPickerFrame")
    if type(picker) == "table" and picker:IsShown() then
      picker:Hide()
    end
  end
  parkProbeFrames()
  if stageFrame ~= nil then
    stageFrame:Hide()
  end
end

---Register a suite of this package whose tests all end cleaned up.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName)
  suite:After(cleanUp)
  return suite
end

---Release a widget the running test holds, and put its frame back at once.
---@param widget any
local function releaseNow(widget)
  local frame = widget:GetFrame()
  WidgetKit:Release(widget)
  restoreFrame(frame)
end

-- Callbacks -----------------------------------------------------------------------------

---A callback that records every call: `calls[i]` is `{ name, n, args }` with
---the callback name, the number of arguments after it and those arguments.
---@return table[] calls
---@return fun(widget: any, name: string, ...: any) callback
local function recorder()
  local calls = {}
  local function callback(_, name, ...)
    calls[#calls + 1] = { name = name, n = select("#", ...), args = { ... } }
  end
  return calls, callback
end

-- Numbers and positions -------------------------------------------------------------------

---Fail the test naming `label` unless `actual` is a number within `tolerance`
---of `expected`.
---@param ctx TestKit.Context
---@param label string
---@param actual any
---@param expected number
---@param tolerance number|nil default `PIXEL_TOLERANCE`
local function expectNear(ctx, label, actual, expected, tolerance)
  tolerance = tolerance or PIXEL_TOLERANCE
  if type(actual) ~= "number" or isSecret(actual) then
    ctx:Fail(("%s: expected a number near %s, got %s"):format(label, expected, type(actual)))
    return
  end
  if math.abs(actual - expected) > tolerance then
    ctx:Fail(("%s: expected %.4f, got %.4f"):format(label, expected, actual))
  end
end

---Check a frame's anchor at `point`: its relative frame, relative point and
---offsets, as `GetPoint` answers them. The anchor is looked up by its point
---rather than by index, because the client lists a frame's anchors in its
---own order.
---@param ctx TestKit.Context
---@param label string
---@param frame any
---@param point string
---@param relativeTo any
---@param relativePoint string
---@param x number
---@param y number
local function expectPoint(ctx, label, frame, point, relativeTo, relativePoint, x, y)
  for index = 1, frame:GetNumPoints() do
    local actualPoint, actualRelative, actualRelativePoint, actualX, actualY = frame:GetPoint(index)
    if actualPoint == point then
      if actualRelativePoint ~= relativePoint then
        ctx:Fail(
          ("%s: %s is anchored to %s, expected %s"):format(
            label,
            point,
            tostring(actualRelativePoint),
            relativePoint
          )
        )
      end
      if actualRelative ~= relativeTo then
        ctx:Fail(("%s: %s is anchored to another frame"):format(label, point))
      end
      expectNear(ctx, label .. " x", actualX, x)
      expectNear(ctx, label .. " y", actualY, y)
      return
    end
  end
  ctx:Fail(("%s: the frame has no %s anchor"):format(label, point))
end

---What a text getter answered, with `nil` read as the empty text. The type
---tests compare through this, so that the one test of the documented `""`
---(`text getters answer ""`, in the types suite) is the only place the
---difference between `""` and `nil` can fail.
---@param text any
---@return any
local function cleared(text)
  if type(text) == "nil" then
    return ""
  end
  return text
end

---`left, top, width, height` of a frame, as the client computes them.
---@param frame any
---@return number left
---@return number top
---@return number width
---@return number height
local function rectOf(frame)
  local left, _, width, height = frame:GetRect()
  return left, frame:GetTop(), width, height
end

---A frame's rect for the log.
---@param frame any
---@return string
local function describeRect(frame)
  local left, bottom, width, height = frame:GetRect()
  if type(left) ~= "number" or isSecret(left) then
    return "no rect"
  end
  return ("left %.2f bottom %.2f width %.2f height %.2f"):format(left, bottom, width, height)
end

--- The largest distance between a rect the client computed and the one a
--- layout asked for, since the running test last reset it.
local largestRectDeviation = 0

---Compare one rect measure with what the layout asked for, within
---`RECT_TOLERANCE`, and remember the largest deviation.
---@param ctx TestKit.Context
---@param label string
---@param actual number
---@param expected number
local function expectRectMeasure(ctx, label, actual, expected)
  local deviation = math.abs(actual - expected)
  if deviation > largestRectDeviation then
    largestRectDeviation = deviation
  end
  expectNear(ctx, label, actual, expected, RECT_TOLERANCE)
end

---Check that `frame` sits at `x`, `y` (right and down) from the top-left
---corner of `content`, is `width` wide and `height` high, on the rects the
---client computed.
---@param ctx TestKit.Context
---@param label string
---@param frame any
---@param content any
---@param x number
---@param y number
---@param width number
---@param height number
local function expectRect(ctx, label, frame, content, x, y, width, height)
  local left, top, actualWidth, actualHeight = rectOf(frame)
  local contentLeft, contentTop = rectOf(content)
  if
    type(left) ~= "number"
    or type(contentLeft) ~= "number"
    or isSecret(left)
    or isSecret(contentLeft)
  then
    ctx:Fail(label .. ": the client computed no rect")
    return
  end
  expectRectMeasure(ctx, label .. " left", left - contentLeft, x)
  expectRectMeasure(ctx, label .. " top", contentTop - top, y)
  expectRectMeasure(ctx, label .. " width", actualWidth, width)
  expectRectMeasure(ctx, label .. " height", actualHeight, height)
end

---Log the largest rect deviation of the running test and start again.
---@param ctx TestKit.Context
local function logRectDeviation(ctx)
  ctx:Log(
    ("largest distance between a client rect and the layout's: %.4f"):format(largestRectDeviation)
  )
  largestRectDeviation = 0
end

---Wait until at least one more frame was rendered.
---@param ctx TestKit.Context
local function waitOneFrame(ctx)
  local asked = 0
  ---@type any
  local context = ctx
  context:WaitUntil(function()
    asked = asked + 1
    return asked >= 2
  end, 2)
end

-- Positions and errors ------------------------------------------------------------------------

---Split a `file:line: ` prefix into the file as the client names it and the line.
---@param position string
---@return string|nil file
---@return integer|nil line
local function splitPosition(position)
  local file, line = position:match("^(.-):(%d+): ")
  return file, tonumber(line)
end

---The line of the caller of this function, as the client numbers it.
---
---`error` with level 3, raised under `pcall`, names the caller of this
---function: level 1 is `pcall` itself, 2 is this function, 3 its caller.
---@return integer
local function currentLine()
  local _, position = pcall(error, "", 3)
  local _, line = splitPosition(position or "")
  return line or 0
end

---Check that `message` is a string naming this file, and return its line.
---@param ctx TestKit.Context
---@param message any
---@return integer|nil line
local function expectThisFile(ctx, message)
  ctx:Expect(type(message)):ToBe("string")
  if type(message) ~= "string" then
    return nil
  end
  local file, line = splitPosition(message)
  ctx:Expect(type(file)):ToBe("string")
  ctx:Expect((file or ""):sub(-#THIS_FILE)):ToBe(THIS_FILE)
  return line
end

---Call `raise`, which must record its start line with `currentLine()` and
---raise on the next line, and check that the message names this file at that
---next line and ends with `expected`.
---@param ctx TestKit.Context
---@param raise fun() Records its start line in `lineBox.start`, then raises on the next line.
---@param lineBox { start: integer }
---@param expected string The message after the position, compared literally.
local function expectErrorAtCallingLine(ctx, raise, lineBox, expected)
  local succeeded, message = pcall(raise)
  ctx:Expect(succeeded):ToBe(false)
  ctx:Log("client message: " .. tostring(message))

  local line = expectThisFile(ctx, message)
  ctx:Expect(tostring(message):sub(-#expected)):ToBe(expected)
  ctx:Expect(line):ToBe(lineBox.start + 1)
end

---Run `action` with the client's error handler replaced by a collector, and
---return what was reported and whether the replacement took.
---
---WidgetKit reports callback, hook and restore failures by calling the handler
---`geterrorhandler` returns. The handler is swapped with `seterrorhandler` for
---this call only and put back at once (tests/client/README.md, "Catching an
---error a Kit reports instead of raising"); an error-capturing addon such as
---BugGrabber may refuse the swap, which the caller turns into a failure.
---@param action fun()
---@return any[] reported
---@return boolean observed
local function collectReportedErrors(action)
  local reported = {}
  local setErrorHandler = readHost("seterrorhandler")
  local getErrorHandler = readHost("geterrorhandler")
  if type(setErrorHandler) ~= "function" or type(getErrorHandler) ~= "function" then
    action()
    return reported, false
  end
  local function collector(message)
    reported[#reported + 1] = message
  end
  local previous = getErrorHandler()
  setErrorHandler(collector)
  local observed = getErrorHandler() == collector
  local succeeded, problem = pcall(action)
  setErrorHandler(previous)
  if not succeeded then
    error(problem, 0)
  end
  return reported, observed
end

-- Allocation ----------------------------------------------------------------------------------

---Collect in a step of its own, run `operation` once unmeasured (the first
---call after a full collection can regrow pool bookkeeping), then run it
---`ALLOCATION_CYCLES` times, log how far the heap grew and hold it to the
---tolerance.
---@param ctx TestKit.Context
---@param label string what `operation` does, for the log
---@param operation fun()
local function expectNoAllocation(ctx, label, operation)
  collectgarbage("collect")
  ctx:Yield()
  operation()
  local before = collectgarbage("count")
  for _ = 1, ALLOCATION_CYCLES do
    operation()
  end
  local grownKilobytes = collectgarbage("count") - before
  ctx:Log(
    ("memory delta over %d cycles of %s: %.3f KB"):format(ALLOCATION_CYCLES, label, grownKilobytes)
  )
  ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
end

-- Reuse -------------------------------------------------------------------------------------

---Release `widget`, check the release contract on its real frame, create the
---same type again and check that the pool handed back the same widget on the
---same frame. Returns the reacquired widget (placed on the stage).
---@param ctx TestKit.Context
---@param widget any
---@return any reacquired
local function expectReleasedAndReused(ctx, widget)
  local typeName = widget:GetType()
  local frame = widget:GetFrame()
  local released = {}
  widget:SetCallback("OnRelease", function()
    released[#released + 1] = widget:IsReleasing()
  end)
  widget:SetUserData("probe", 42)

  ctx:Expect(WidgetKit:Release(widget)):ToBe(true)
  ctx:Expect(released):ToEqual({ true })
  ctx:Expect(WidgetKit:IsWidget(widget)):ToBe(false)
  ctx:Expect(frame:IsShown() == true):ToBe(false)
  ctx:Expect(frame:GetParent()):ToBe(uiParent)
  ctx:Expect(frame:GetNumPoints()):ToBe(0)
  ctx:Expect(widget:GetType()):ToBe(typeName)
  ctx:Expect(widget:Fire("OnRelease")):ToBe(false)

  local reacquired = create(ctx, typeName)
  ctx:Expect(reacquired):ToBe(widget)
  ctx:Expect(reacquired:GetFrame()):ToBe(frame)
  ctx:Expect(frame:IsShown() == true):ToBe(true)
  ctx:Expect(reacquired:GetUserData("probe")):ToBeNil()
  ctx:Expect(reacquired:IsFullHeight()):ToBe(false)
  ctx:Expect(reacquired:GetRelativeWidth()):ToBeNil()
  -- The OnRelease callback of the previous use was cleared.
  ctx:Expect(reacquired:Fire("OnRelease")):ToBe(false)
  return place(reacquired)
end

-- widgetKit.facade --------------------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('widgetKit', 1) is the WidgetKit facade with API 1, its sixteen methods, the four Anchor functions, the defaults 256/256/16 and UNBOUNDED, and the twelve base types at their documented versions (Frame 4, nine at 3, ScrollFrame and Spacer 1)",
  function(ctx)
    ctx:Expect(rawget(WidgetKit, "API")):ToBe(WIDGET_KIT_API)
    for _, methodName in ipairs({
      "RegisterType",
      "GetTypeVersion",
      "Create",
      "Release",
      "IsWidget",
      "RegisterLayout",
      "GetLayout",
      "SetFocus",
      "ClearFocus",
      "GetFocus",
      "GetStatistics",
      "BindPosition",
      "RenderOptions",
      "CreateMediaPicker",
      "SetLimits",
      "GetLimits",
    }) do
      ctx:Expect(type(WidgetKit[methodName])):ToBe("function")
    end
    for _, functionName in ipairs({ "FromRect", "Normalize", "Apply", "Read" }) do
      ctx:Expect(type(WidgetKit.Anchor[functionName])):ToBe("function")
    end
    ctx:Expect(#WidgetKit.Anchor.POINTS):ToBe(9)
    ctx:Expect(WidgetKit.MAX_CREATED):ToBe(256)
    ctx:Expect(WidgetKit.MAX_CHILDREN):ToBe(256)
    ctx:Expect(WidgetKit.MAX_CALLBACKS):ToBe(16)
    ctx:Expect(type(WidgetKit.UNBOUNDED)):ToBe("table")
    for _, layoutName in ipairs({ "List", "Fill", "Flow" }) do
      ctx:Expect(type(WidgetKit:GetLayout(layoutName))):ToBe("function")
    end
    for _, typeName in ipairs(BASE_TYPES) do
      ctx:Expect(WidgetKit:GetTypeVersion(typeName)):ToBe(BASE_TYPE_VERSIONS[typeName])
    end

    local limits = WidgetKit:GetLimits()
    ctx:Log(
      ("limits in this session: maxCreatedCeiling %s, maxDropdownEntries %s"):format(
        tostring(limits.maxCreatedCeiling),
        tostring(limits.maxDropdownEntries)
      )
    )
    local statistics = WidgetKit:GetStatistics()
    ctx:Log(
      ("statistics before the run: %d types, %d frames built, %d active, %d available"):format(
        statistics.types,
        statistics.created,
        statistics.active,
        statistics.available
      )
    )
  end
)

facade:Test("the installed WidgetKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      local _, revision = Registry:Get(PACKAGE_ID, WIDGET_KIT_API)
      ctx:Log("WidgetKit.REVISION is " .. tostring(rawget(WidgetKit, "REVISION")))
      ctx:Expect(revision):ToBe(expected.revision)
      ctx:Expect(rawget(WidgetKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list widgetKit")
end)

facade:Test(
  "the client has CreateFrame and UIParent, and OptionsKit, MediaKit and SchedulerKit are registered; ColorPickerFrame, the secret functions, ACCEPT, NOT_BOUND and UIParent's rect and scale are logged",
  function(ctx)
    ctx:Expect(type(createFrame)):ToBe("function")
    ctx:Expect(type(uiParent)):ToBe("table")
    ctx:Expect(type(OptionsKit)):ToBe("table")
    ctx:Expect(type(MediaKit)):ToBe("table")
    ctx:Expect(type(Registry:Get("schedulerKit", SCHEDULER_KIT_API))):ToBe("table")

    local picker = readHost("ColorPickerFrame")
    ctx:Log("ColorPickerFrame: " .. type(picker))
    if type(picker) == "table" then
      ctx:Log(
        ("SetupColorPickerAndShow %s, GetColorRGB %s, GetColorAlpha %s, IsForbidden %s"):format(
          type(picker.SetupColorPickerAndShow),
          type(picker.GetColorRGB),
          type(picker.GetColorAlpha),
          tostring(picker:IsForbidden())
        )
      )
    end
    ctx:Log("issecretvalue: " .. type(isSecretValue) .. ", secretwrap: " .. type(secretWrap))
    ctx:Log(
      ("ACCEPT: %s, NOT_BOUND: %s"):format(
        tostring(readHost("ACCEPT")),
        tostring(readHost("NOT_BOUND"))
      )
    )
    local effectiveScale = uiParent:GetEffectiveScale()
    ctx:Log(("UIParent: %s, effective scale %.4f"):format(describeRect(uiParent), effectiveScale))
  end
)

-- widgetKit.types -------------------------------------------------------------------------

local types = newSuite("types")

types:Test(
  'text getters answer "" once cleared, as docs/API.md says, on the client\'s font strings, buttons and edit boxes: Label, Heading, Button, EditBox and Dropdown texts, Frame and Group titles and a CheckBox label, after a fresh Create and after SetText(nil)',
  function(ctx)
    ---@type { name: string, read: (fun(): any), clear: fun() }[]
    local probes = {}
    ---@param name string
    ---@param widget any
    ---@param getter string
    ---@param setter string
    local function probe(name, widget, getter, setter)
      probes[#probes + 1] = {
        name = name,
        read = function()
          return widget[getter](widget)
        end,
        clear = function()
          widget[setter](widget, "filled")
          widget[setter](widget, nil)
        end,
      }
    end
    probe("Label:GetText", create(ctx, "Label"), "GetText", "SetText")
    probe("Heading:GetText", create(ctx, "Heading"), "GetText", "SetText")
    probe("Button:GetText", create(ctx, "Button"), "GetText", "SetText")
    probe("EditBox:GetText", create(ctx, "EditBox"), "GetText", "SetText")
    probe("Frame:GetTitle", createPlaced(ctx, "Frame"), "GetTitle", "SetTitle")
    probe("Group:GetTitle", create(ctx, "Group"), "GetTitle", "SetTitle")
    probe("CheckBox:GetLabel", create(ctx, "CheckBox"), "GetLabel", "SetLabel")
    probe("Dropdown:GetLabel", create(ctx, "Dropdown"), "GetLabel", "SetLabel")

    -- Every answer is logged before any is checked, so one run shows them all.
    local answers = {}
    for index, entry in ipairs(probes) do
      local fresh = entry.read()
      entry.clear()
      local afterNil = entry.read()
      answers[index] = { fresh = fresh, afterNil = afterNil }
      ctx:Log(
        ("%s: %s after Create, %s after SetText(nil)"):format(
          entry.name,
          type(fresh) == "string" and ("%q"):format(fresh) or tostring(fresh),
          type(afterNil) == "string" and ("%q"):format(afterNil) or tostring(afterNil)
        )
      )
    end
    for _, answer in ipairs(answers) do
      ctx:Expect(answer.fresh):ToBe("")
      ctx:Expect(answer.afterNil):ToBe("")
    end
  end
)

types:Test(
  "Frame: a 700x500 movable, resizable window with an empty title; SetTitle, SetMovable and SetResizable reach the frame; its close button, title-bar drag stop and sizer fire OnClose, OnMoved and OnResize; release and reuse give the same frame back at its defaults",
  function(ctx)
    local window = createPlaced(ctx, "Frame")
    local frame = window:GetFrame()
    expectNear(ctx, "window width", window:GetWidth(), 700)
    expectNear(ctx, "window height", window:GetHeight(), 500)
    ctx:Expect(cleared(window:GetTitle())):ToBe("")
    ctx:Expect(frame:IsMovable() == true):ToBe(true)
    ctx:Expect(frame:IsResizable() == true):ToBe(true)
    ctx:Expect(window.sizer:IsShown() == true):ToBe(true)
    -- The window sits on the MEDIUM stage: `SetParent` would have handed it
    -- that strata had WidgetKit not fixed its own.
    local hasFixed = frame.HasFixedFrameStrata
    ctx:Log(
      ("window strata on the stage (%s): %s; fixed strata: %s"):format(
        tostring(stage():GetFrameStrata()),
        tostring(frame:GetFrameStrata()),
        type(hasFixed) == "function" and tostring(hasFixed(frame)) or "no HasFixedFrameStrata"
      )
    )
    ctx:Expect(frame:GetFrameStrata()):ToBe("DIALOG")

    local calls, callback = recorder()
    window:SetCallback("OnClose", callback)
    window:SetCallback("OnMoved", callback)
    window:SetCallback("OnResize", callback)
    window:SetTitle("Molten Codes")
    ctx:Expect(window:GetTitle()):ToBe("Molten Codes")
    window:SetTitle(42)
    ctx:Expect(window:GetTitle()):ToBe("42")
    window:SetMovable(false)
    ctx:Expect(frame:IsMovable() == true):ToBe(false)
    window:SetResizable(false)
    ctx:Expect(frame:IsResizable() == true):ToBe(false)
    ctx:Expect(window.sizer:IsShown() == true):ToBe(false)
    window:SetMovable(true)
    window:SetResizable(true)
    ctx:Expect(#calls):ToBe(0)

    -- Stand-ins for the player's mouse: the drag-stop and mouse-up scripts
    -- WidgetKit set on its own title bar and sizer, called as the client
    -- would, and a real click on its close button.
    window.titleBar:GetScript("OnDragStop")(window.titleBar)
    window.sizer:GetScript("OnMouseUp")(window.sizer, "LeftButton")
    window.closeButton:Click("LeftButton")
    ctx:Expect(#calls):ToBe(3)
    ctx:Expect(calls[1].name):ToBe("OnMoved")
    ctx:Expect(calls[2].name):ToBe("OnResize")
    expectNear(ctx, "OnResize width", calls[2].args[1], 700)
    expectNear(ctx, "OnResize height", calls[2].args[2], 500)
    ctx:Expect(calls[3].name):ToBe("OnClose")
    ctx:Expect(frame:IsShown() == true):ToBe(false)
    window:Show()

    local reused = expectReleasedAndReused(ctx, window)
    ctx:Expect(cleared(reused:GetTitle())):ToBe("")
    ctx:Expect(frame:IsMovable() == true):ToBe(true)
    ctx:Expect(frame:IsResizable() == true):ToBe(true)
    expectNear(ctx, "reused width", reused:GetWidth(), 700)
    ctx:Expect(reused:GetBinding()):ToBeNil()
  end
)

types:Test(
  "Group: 300x16 with no title, a List layout and room for 256 children; a title moves the content 18 pixels down and a layout grows the group to its content plus insets; release and reuse give the same frame back at its defaults",
  function(ctx)
    local group = createPlaced(ctx, "Group")
    local content = group:GetContent()
    expectNear(ctx, "group width", group:GetWidth(), 300)
    expectNear(ctx, "group height", group:GetHeight(), 16)
    ctx:Expect(cleared(group:GetTitle())):ToBe("")
    ctx:Expect(group:GetLayoutName()):ToBe("List")
    ctx:Expect(group:GetNumChildren()):ToBe(0)
    ctx:Expect(group:GetMaxChildren()):ToBe(256)
    ctx:Expect(group:IsLayoutPaused()):ToBe(false)
    expectPoint(
      ctx,
      "content without title",
      content,
      "TOPLEFT",
      group:GetFrame(),
      "TOPLEFT",
      8,
      -8
    )

    group:SetTitle("Section")
    ctx:Expect(group:GetTitle()):ToBe("Section")
    expectPoint(ctx, "content with title", content, "TOPLEFT", group:GetFrame(), "TOPLEFT", 8, -26)
    ctx:Expect(group:PerformLayout()):ToBe(true)
    expectNear(ctx, "titled empty group height", group:GetHeight(), 34)

    local spacer = create(ctx, "Spacer")
    spacer:SetHeight(40)
    ctx:Expect(group:AddChild(spacer)):ToBe(true)
    expectNear(ctx, "group height around a 40-pixel child", group:GetHeight(), 74)
    group:SetDisabled(true)
    local red = group.titleText:GetTextColor()
    expectNear(ctx, "disabled title red", red, 0.5)
    group:SetDisabled(false)
    group:SetMaxChildren(1)
    local other = create(ctx, "Spacer")
    local added, reason = group:AddChild(other)
    ctx:Expect(added):ToBeNil()
    ctx:Expect(reason):ToBe("full")

    local reused = expectReleasedAndReused(ctx, group)
    ctx:Expect(WidgetKit:IsWidget(spacer)):ToBe(false)
    ctx:Expect(cleared(reused:GetTitle())):ToBe("")
    ctx:Expect(reused:GetNumChildren()):ToBe(0)
    ctx:Expect(reused:GetMaxChildren()):ToBe(256)
    expectNear(ctx, "reused height", reused:GetHeight(), 16)
    expectPoint(ctx, "reused content", content, "TOPLEFT", reused:GetFrame(), "TOPLEFT", 8, -8)
  end
)

types:Test(
  "ScrollFrame: 300x200 with nothing to scroll; a 500-pixel child gives a 280-pixel scroll child, a 300-pixel range and a shown scrollbar; SetScroll clamps; the client's mouse-wheel script scrolls 40 pixels; release and reuse reset the scroll",
  function(ctx)
    local scroll = createPlaced(ctx, "ScrollFrame")
    expectNear(ctx, "scroll width", scroll:GetWidth(), 300)
    expectNear(ctx, "scroll height", scroll:GetHeight(), 200)
    ctx:Expect(scroll:GetContentHeight()):ToBe(0)
    ctx:Expect(scroll:GetScrollRange()):ToBe(0)
    ctx:Expect(scroll:GetScroll()):ToBe(0)
    ctx:Expect(scroll.scrollbar:IsShown() == true):ToBe(false)

    local tall = create(ctx, "Spacer")
    tall:SetHeight(500)
    ctx:Expect(scroll:AddChild(tall)):ToBe(true)
    local viewport = scroll.scroll
    ctx:Log(
      ("viewport %s; scroll child %s; client scroll range %s"):format(
        describeRect(viewport),
        describeRect(scroll:GetContent()),
        tostring(viewport:GetVerticalScrollRange())
      )
    )
    expectNear(ctx, "scroll child width", scroll:GetContent():GetWidth(), 280)
    ctx:Expect(scroll:GetContentHeight()):ToBe(500)
    expectNear(ctx, "scroll range", scroll:GetScrollRange(), 300)
    ctx:Expect(scroll.scrollbar:IsShown() == true):ToBe(true)

    scroll:SetScroll(1000)
    expectNear(ctx, "scroll clamped to the range", scroll:GetScroll(), 300)
    scroll:SetScroll(-5)
    expectNear(ctx, "scroll clamped to 0", scroll:GetScroll(), 0)
    scroll:SetScroll(100)
    -- The client's own wheel script, as a wheel notch down would call it.
    viewport:GetScript("OnMouseWheel")(viewport, -1)
    expectNear(ctx, "scroll after one notch down", scroll:GetScroll(), 140)

    local reused = expectReleasedAndReused(ctx, scroll)
    ctx:Expect(reused:GetNumChildren()):ToBe(0)
    ctx:Expect(reused:GetScrollRange()):ToBe(0)
    ctx:Expect(reused:GetScroll()):ToBe(0)
    ctx:Expect(reused.scrollbar:IsShown() == true):ToBe(false)
  end
)

types:Test(
  "Label: 200 wide and empty in GameFontHighlightSmall; its height follows the client's measure of its text and grows when the text wraps; SetColor, SetJustifyH, SetFontObject and SetDisabled reach the font string; release and reuse give an empty label",
  function(ctx)
    local label = createPlaced(ctx, "Label")
    local text = label.text
    expectNear(ctx, "label width", label:GetWidth(), 200)
    ctx:Expect(cleared(label:GetText())):ToBe("")
    ctx:Expect(text:GetFontObject()):ToBe(readHost("GameFontHighlightSmall"))

    label:SetText(SHORT_TEXT)
    ctx:Expect(label:GetText()):ToBe(SHORT_TEXT)
    local oneLine = label:GetHeight()
    ctx:Log(
      ("'%s' in GameFontHighlightSmall: string width %.2f, height %.2f"):format(
        SHORT_TEXT,
        text:GetStringWidth(),
        oneLine
      )
    )
    ctx:Expect(oneLine > 0):ToBe(true)
    expectNear(ctx, "label height is the string height", oneLine, text:GetStringHeight())

    label:SetText(LONG_TEXT)
    local wrapped = label:GetHeight()
    ctx:Log(
      ("long text at 200 pixels: height %.2f, about %.1f lines"):format(wrapped, wrapped / oneLine)
    )
    ctx:Expect(wrapped >= 2 * oneLine - 0.5):ToBe(true)
    label:SetText(7)
    ctx:Expect(label:GetText()):ToBe("7")
    label:SetText(nil)
    ctx:Expect(cleared(label:GetText())):ToBe("")

    label:SetText(SHORT_TEXT)
    label:SetColor(0.25, 0.5, 0.75)
    local red, green, blue, alpha = text:GetTextColor()
    expectNear(ctx, "red", red, 0.25)
    expectNear(ctx, "green", green, 0.5)
    expectNear(ctx, "blue", blue, 0.75)
    expectNear(ctx, "alpha", alpha, 1)
    label:SetDisabled(true)
    expectNear(ctx, "disabled red", (text:GetTextColor()), 0.5)
    label:SetDisabled(false)
    expectNear(ctx, "enabled red again", (text:GetTextColor()), 0.25)
    label:SetJustifyH("RIGHT")
    ctx:Expect(text:GetJustifyH()):ToBe("RIGHT")
    label:SetFontObject("GameFontHighlightLarge")
    ctx:Log(
      ("'%s' in GameFontHighlightLarge: string width %.2f, height %.2f"):format(
        SHORT_TEXT,
        text:GetStringWidth(),
        label:GetHeight()
      )
    )
    ctx:Expect(label:GetHeight() > oneLine):ToBe(true)

    local reused = expectReleasedAndReused(ctx, label)
    ctx:Expect(cleared(reused:GetText())):ToBe("")
    ctx:Expect(text:GetFontObject()):ToBe(readHost("GameFontHighlightSmall"))
    ctx:Expect(text:GetJustifyH()):ToBe("LEFT")
    expectNear(ctx, "reused red", (text:GetTextColor()), 1)
  end
)

types:Test(
  "Button: 200x24, empty and enabled; SetText fires nothing while a real Click fires OnClick with the mouse button; a disabled button ignores clicks; key capture listens after a click, takes F, cancels on ESCAPE and unbinds on a right click; release and reuse clear the text",
  function(ctx)
    local button = createPlaced(ctx, "Button")
    local frame = button:GetFrame()
    expectNear(ctx, "button width", button:GetWidth(), 200)
    expectNear(ctx, "button height", button:GetHeight(), 24)
    ctx:Expect(cleared(button:GetText())):ToBe("")
    ctx:Expect(frame:IsEnabled() == true):ToBe(true)
    ctx:Expect(button:IsCapturing()):ToBe(false)

    local calls, callback = recorder()
    for _, name in ipairs({ "OnClick", "OnKeyCaptured", "OnKeyCaptureCancelled" }) do
      button:SetCallback(name, callback)
    end
    button:SetText("Apply")
    ctx:Expect(button:GetText()):ToBe("Apply")
    ctx:Log(
      ("'Apply' on a UIPanelButtonTemplate: string width %.2f"):format(
        frame:GetFontString():GetStringWidth()
      )
    )
    ctx:Expect(#calls):ToBe(0)

    frame:Click("LeftButton")
    frame:Click("RightButton")
    ctx:Expect(#calls):ToBe(2)
    ctx:Expect(calls[1].name):ToBe("OnClick")
    ctx:Expect(calls[1].args[1]):ToBe("LeftButton")
    ctx:Expect(calls[2].args[1]):ToBe("RightButton")

    button:SetDisabled(true)
    ctx:Expect(frame:IsEnabled() == true):ToBe(false)
    frame:Click("LeftButton")
    ctx:Expect(#calls):ToBe(2)
    button:SetDisabled(false)

    -- Key capture enables the keyboard on the button while it listens, so
    -- every capture below starts and ends in this one step: the player's
    -- keys are never taken. The key is handed to the OnKeyDown script
    -- WidgetKit set, as the client would.
    local onKeyDown = frame:GetScript("OnKeyDown")
    button:SetKeyCapture(true)
    frame:Click("LeftButton")
    ctx:Expect(button:IsCapturing()):ToBe(true)
    onKeyDown(frame, "LSHIFT")
    ctx:Expect(button:IsCapturing()):ToBe(true)
    onKeyDown(frame, "F")
    ctx:Expect(button:IsCapturing()):ToBe(false)
    frame:Click("LeftButton")
    onKeyDown(frame, "ESCAPE")
    ctx:Expect(button:IsCapturing()):ToBe(false)
    frame:Click("RightButton")
    ctx:Expect(#calls):ToBe(5)
    ctx:Expect(calls[3].name):ToBe("OnKeyCaptured")
    ctx:Log("captured key: " .. tostring(calls[3].args[1]))
    ctx:Expect(tostring(calls[3].args[1]):sub(-1)):ToBe("F")
    ctx:Expect(calls[4].name):ToBe("OnKeyCaptureCancelled")
    ctx:Expect(calls[5].name):ToBe("OnKeyCaptured")
    ctx:Expect(calls[5].args[1]):ToBe("")
    frame:Click("LeftButton")
    button:SetKeyCapture(false)
    ctx:Expect(button:IsCapturing()):ToBe(false)
    ctx:Expect(frame:IsKeyboardEnabled() == true):ToBe(false)

    local reused = expectReleasedAndReused(ctx, button)
    ctx:Expect(cleared(reused:GetText())):ToBe("")
    ctx:Expect(frame:IsEnabled() == true):ToBe(true)
    reused:GetFrame():Click("LeftButton")
    ctx:Expect(#calls):ToBe(5)
  end
)

types:Test(
  "CheckBox: 200x24, unchecked with an empty label; SetValue shows the value on the real check button and fires nothing; a real Click cycles unchecked, checked and, with three states, the third, firing OnValueChanged; a disabled box ignores clicks; release and reuse uncheck it",
  function(ctx)
    local box = createPlaced(ctx, "CheckBox")
    local button = box.button
    ctx:Expect(box:GetValue()):ToBe(false)
    ctx:Expect(cleared(box:GetLabel())):ToBe("")
    ctx:Expect(button:GetChecked() == true):ToBe(false)

    local calls, callback = recorder()
    box:SetCallback("OnValueChanged", callback)
    box:SetLabel("Enabled")
    ctx:Expect(box:GetLabel()):ToBe("Enabled")
    box:SetValue(true)
    ctx:Expect(box:GetValue()):ToBe(true)
    ctx:Expect(button:GetChecked() == true):ToBe(true)
    box:SetValue(nil)
    ctx:Expect(box:GetValue()):ToBe(false)
    ctx:Expect(#calls):ToBe(0)

    button:Click()
    ctx:Expect(box:GetValue()):ToBe(true)
    ctx:Expect(button:GetChecked() == true):ToBe(true)
    button:Click()
    ctx:Expect(box:GetValue()):ToBe(false)
    box:SetTriState(true)
    button:Click()
    button:Click()
    ctx:Expect(box:GetValue()):ToBeNil()
    ctx:Expect(box.indeterminate:IsShown() == true):ToBe(true)
    ctx:Expect(#calls):ToBe(4)
    ctx:Expect(calls[1].args[1]):ToBe(true)
    ctx:Expect(calls[2].args[1]):ToBe(false)
    ctx:Expect(calls[3].args[1]):ToBe(true)
    ctx:Expect(calls[4].n):ToBe(1)
    ctx:Expect(calls[4].args[1]):ToBeNil()
    box:SetTriState(false)
    ctx:Expect(box:GetValue()):ToBe(false)

    box:SetDisabled(true)
    ctx:Expect(button:IsEnabled() == true):ToBe(false)
    button:Click()
    ctx:Expect(#calls):ToBe(4)
    ctx:Expect(box:GetValue()):ToBe(false)
    box:SetDisabled(false)
    box:SetValue(true)

    local reused = expectReleasedAndReused(ctx, box)
    ctx:Expect(reused:GetValue()):ToBe(false)
    ctx:Expect(cleared(reused:GetLabel())):ToBe("")
    ctx:Expect(button:GetChecked() == true):ToBe(false)
    ctx:Expect(button:IsEnabled() == true):ToBe(true)
  end
)

types:Test(
  "Slider: 0 to 100 in steps of 1 at 0; SetSliderValues and SetValue snap, clamp and show the value without firing; the client's slider and the value box's Enter script fire OnValueChanged once per change; percent mode shows 35%; release and reuse restore 0 to 100",
  function(ctx)
    local slider = createPlaced(ctx, "Slider")
    local bar, valueBox = slider.slider, slider.valueBox
    ctx:Expect(slider:GetValue()):ToBe(0)
    ctx:Expect(valueBox:GetText()):ToBe("0")
    local minimum, maximum = bar:GetMinMaxValues()
    ctx:Expect(minimum):ToBe(0)
    ctx:Expect(maximum):ToBe(100)

    local calls, callback = recorder()
    slider:SetCallback("OnValueChanged", callback)
    slider:SetLabel("Scale")
    ctx:Expect(slider:GetLabel()):ToBe("Scale")
    slider:SetSliderValues(0, 1, 0.05)
    slider:SetValue(0.337)
    expectNear(ctx, "snapped value", slider:GetValue(), 0.35, 1e-9)
    expectNear(ctx, "the client's slider value", bar:GetValue(), 0.35, 1e-6)
    ctx:Expect(valueBox:GetText()):ToBe("0.35")
    slider:SetValue(7)
    ctx:Expect(slider:GetValue()):ToBe(1)
    slider:SetIsPercent(true)
    slider:SetValue(0.35)
    ctx:Expect(valueBox:GetText()):ToBe("35%")
    ctx:Expect(#calls):ToBe(0)

    -- The client's Slider, moved as a drag would move it, and the value box's
    -- Enter script WidgetKit set, called as the client would.
    bar:SetValue(0.6)
    expectNear(ctx, "value after the slider moved", slider:GetValue(), 0.6, 1e-9)
    bar:SetValue(0.6)
    valueBox:SetText("80%")
    valueBox:GetScript("OnEnterPressed")(valueBox)
    expectNear(ctx, "value typed as a percentage", slider:GetValue(), 0.8, 1e-9)
    ctx:Expect(valueBox:GetText()):ToBe("80%")
    ctx:Expect(#calls):ToBe(2)
    expectNear(ctx, "first user value", calls[1].args[1], 0.6, 1e-9)
    expectNear(ctx, "second user value", calls[2].args[1], 0.8, 1e-9)

    slider:SetDisabled(true)
    ctx:Expect(bar:IsEnabled() == true):ToBe(false)
    ctx:Expect(valueBox:IsEnabled() == true):ToBe(false)
    slider:SetDisabled(false)

    local reused = expectReleasedAndReused(ctx, slider)
    ctx:Expect(reused:GetValue()):ToBe(0)
    ctx:Expect(cleared(reused:GetLabel())):ToBe("")
    ctx:Expect(valueBox:GetText()):ToBe("0")
    minimum, maximum = bar:GetMinMaxValues()
    ctx:Expect(minimum):ToBe(0)
    ctx:Expect(maximum):ToBe(100)
  end
)

types:Test(
  "EditBox: 200x44, single-line and empty; SetText and the client's own SetText fire nothing; the Enter and Escape scripts fire OnEnterPressed and OnEscapePressed; multi-line mode keeps the text and its accept button fires; SetFocus bookkeeping follows the widget; release and reuse empty it",
  function(ctx)
    local edit = createPlaced(ctx, "EditBox")
    local single, multi = edit.singleBox, edit.multiBox
    expectNear(ctx, "edit width", edit:GetWidth(), 200)
    expectNear(ctx, "edit height", edit:GetHeight(), 44)
    ctx:Expect(cleared(edit:GetText())):ToBe("")
    ctx:Expect(edit:IsMultiLine()):ToBe(false)
    ctx:Expect(single:IsShown() == true):ToBe(true)
    ctx:Expect(multi:IsShown() == true):ToBe(false)

    local calls, callback = recorder()
    for _, name in ipairs({ "OnTextChanged", "OnEnterPressed", "OnEscapePressed" }) do
      edit:SetCallback(name, callback)
    end
    edit:SetLabel("Name")
    edit:SetText("hello")
    ctx:Expect(edit:GetText()):ToBe("hello")
    -- The client passes userInput = false for text set from code.
    single:SetText("hello there")
    ctx:Expect(#calls):ToBe(0)

    single:GetScript("OnEnterPressed")(single)
    single:GetScript("OnEscapePressed")(single)
    ctx:Expect(#calls):ToBe(2)
    ctx:Expect(calls[1].name):ToBe("OnEnterPressed")
    ctx:Expect(calls[1].args[1]):ToBe("hello there")
    ctx:Expect(calls[2].name):ToBe("OnEscapePressed")

    edit:SetMultiLine(true, 3)
    ctx:Expect(edit:IsMultiLine()):ToBe(true)
    ctx:Expect(edit:GetText()):ToBe("hello there")
    ctx:Expect(multi:IsShown() == true):ToBe(true)
    ctx:Expect(edit.acceptButton:IsShown() == true):ToBe(true)
    expectNear(ctx, "multi-line height", edit:GetHeight(), 18 + 3 * 14 + 8 + 28)
    edit.acceptButton:Click("LeftButton")
    ctx:Expect(#calls):ToBe(3)
    ctx:Expect(calls[3].args[1]):ToBe("hello there")
    edit:SetMultiLine(false)
    edit:SetMaxLetters(5)
    ctx:Expect(single:GetMaxLetters()):ToBe(5)

    -- WidgetKit's focus bookkeeping only: nothing here gives the edit box
    -- the keyboard.
    local label = create(ctx, "Label")
    WidgetKit:SetFocus(edit)
    ctx:Expect(WidgetKit:GetFocus()):ToBe(edit)
    WidgetKit:SetFocus(label)
    ctx:Expect(WidgetKit:GetFocus()):ToBe(label)
    label:Hide()
    ctx:Expect(WidgetKit:GetFocus()):ToBeNil()
    ctx:Expect(WidgetKit:ClearFocus()):ToBe(false)

    edit:SetDisabled(true)
    ctx:Expect(single:IsEnabled() == true):ToBe(false)
    edit:SetDisabled(false)

    local reused = expectReleasedAndReused(ctx, edit)
    ctx:Expect(cleared(reused:GetText())):ToBe("")
    ctx:Expect(cleared(reused:GetLabel())):ToBe("")
    ctx:Expect(reused:IsMultiLine()):ToBe(false)
    ctx:Expect(single:GetMaxLetters()):ToBe(0)
    expectNear(ctx, "reused height", reused:GetHeight(), 44)
  end
)

types:Test(
  "Dropdown: 200x44 and empty; SetList sorts by label then key, SetValue shows the label and fires nothing; PickIndex and a real click on a list row fire OnValueChanged; the list opens on UIParent at FULLSCREEN_DIALOG with the catcher and closes; release and reuse empty it",
  function(ctx)
    local dropdown = createPlaced(ctx, "Dropdown")
    local button, list = dropdown.button, dropdown.list
    ctx:Expect(dropdown:GetValue()):ToBeNil()
    ctx:Expect(dropdown:GetNumEntries()):ToBe(0)
    ctx:Expect(dropdown:IsOpen()):ToBe(false)
    ctx:Expect(dropdown:Open()):ToBe(false)
    ctx:Expect(list:GetParent()):ToBe(uiParent)
    ctx:Expect(list:GetFrameStrata()):ToBe("FULLSCREEN_DIALOG")

    local calls, callback = recorder()
    dropdown:SetCallback("OnValueChanged", callback)
    dropdown:SetList({ a = "Alpha", b = "Beta", c = "Gamma", [1] = "Beta" })
    ctx:Expect(dropdown:GetNumEntries()):ToBe(4)
    dropdown:SetValue("b")
    ctx:Expect(dropdown:GetValue()):ToBe("b")
    ctx:Expect(button:GetText()):ToBe("Beta")
    dropdown:SetValue("missing")
    ctx:Expect(cleared(button:GetText())):ToBe("")
    ctx:Expect(#calls):ToBe(0)

    -- Display order: Alpha (a), Beta (1, numbers first), Beta (b), Gamma (c).
    ctx:Expect(dropdown:PickIndex(2)):ToBe(true)
    ctx:Expect(dropdown:PickIndex(4)):ToBe(true)
    ctx:Expect(dropdown:PickIndex(5)):ToBe(false)
    ctx:Expect(#calls):ToBe(2)
    ctx:Expect(calls[1].args[1]):ToBe(1)
    ctx:Expect(calls[2].args[1]):ToBe("c")
    ctx:Expect(button:GetText()):ToBe("Gamma")

    -- The list and the full-screen catcher are frames on UIParent, so they
    -- are shown only inside this one synchronous step, which the client never
    -- draws in the middle of: opened, checked, clicked, closed.
    ctx:Expect(dropdown:Open()):ToBe(true)
    local opened = dropdown:IsOpen()
    -- The catcher is WidgetKit's own frame, kept in its package state
    -- (docs/INTERNALS.md, "Shared state").
    local catcher = rawget(rawget(WidgetKit, "_state"), "dropdownCatcher")
    local catcherShown = type(catcher) == "table" and catcher:IsShown() == true
    local rows = dropdown._rows
    local rowCount = #rows
    local secondRowText = rowCount >= 2 and rows[2]:GetText() or nil
    if rowCount >= 3 then
      rows[3]:Click("LeftButton")
    end
    local closedByRow = not dropdown:IsOpen()
    dropdown:Open()
    dropdown:Close()
    local catcherHidden = type(catcher) == "table" and catcher:IsShown() ~= true
    ctx:Expect(opened):ToBe(true)
    ctx:Expect(catcherShown):ToBe(true)
    ctx:Expect(rowCount):ToBe(16)
    ctx:Expect(secondRowText):ToBe("Beta")
    ctx:Expect(closedByRow):ToBe(true)
    ctx:Expect(dropdown:IsOpen()):ToBe(false)
    ctx:Expect(catcherHidden):ToBe(true)
    ctx:Expect(#calls):ToBe(3)
    ctx:Expect(calls[3].args[1]):ToBe("b")
    ctx:Log("list anchored below the button: " .. describeRect(list))

    dropdown:SetList({ a = "Alpha", c = "Gamma" }, { "c", "zz", "a" })
    ctx:Expect(dropdown:GetNumEntries()):ToBe(2)
    dropdown:PickIndex(1)
    ctx:Expect(calls[4].args[1]):ToBe("c")
    dropdown:SetDisabled(true)
    ctx:Expect(dropdown:PickIndex(1)):ToBe(false)
    ctx:Expect(dropdown:Open()):ToBe(false)
    ctx:Expect(#calls):ToBe(4)
    dropdown:SetDisabled(false)

    local reused = expectReleasedAndReused(ctx, dropdown)
    ctx:Expect(reused:GetNumEntries()):ToBe(0)
    ctx:Expect(reused:GetValue()):ToBeNil()
    ctx:Expect(cleared(button:GetText())):ToBe("")
    ctx:Expect(reused:IsOpen()):ToBe(false)
  end
)

types:Test(
  "ColorPicker: white and opaque; SetColor fires nothing; OpenPicker opens the client's ColorPickerFrame with the colour, its swatch and cancel callbacks fire OnValueChanged, a disabled picker opens nothing, and a release disarms the callbacks of the previous use",
  function(ctx)
    local picker = readHost("ColorPickerFrame")
    -- docs/API.md lists `ColorPickerFrame` with `SetupColorPickerAndShow` as
    -- an optional host facility: without it `OpenPicker` fires the current
    -- colour and opens nothing, so the client picker path cannot be proven.
    -- It is FrameXML, not in the apiKit metadata, so the client is asked.
    if type(picker) ~= "table" or type(picker.SetupColorPickerAndShow) ~= "function" then
      Harness:SkipTest(ctx, COLOR_PICKER_SKIP_REASON)
    end
    if picker:IsShown() then
      Harness:SkipTest(ctx, "the client's ColorPickerFrame is open; it was not touched")
    end
    local color = createPlaced(ctx, "ColorPicker")
    local red, green, blue, alpha = color:GetColor()
    ctx:Expect({ red, green, blue, alpha }):ToEqual({ 1, 1, 1, 1 })
    ctx:Expect(cleared(color:GetLabel())):ToBe("")

    local calls, callback = recorder()
    color:SetCallback("OnValueChanged", callback)
    color:SetLabel("Tint")
    color:SetColor(0.2, 0.4, 0.6)
    red, green, blue, alpha = color:GetColor()
    ctx:Expect({ red, green, blue, alpha }):ToEqual({ 0.2, 0.4, 0.6, 1 })
    ctx:Expect(#calls):ToBe(0)

    color:SetDisabled(true)
    ctx:Expect(color:OpenPicker()):ToBe(false)
    ctx:Expect(#calls):ToBe(0)
    color:SetDisabled(false)

    -- The client's ColorPickerFrame is opened through WidgetKit and hidden
    -- again inside this one synchronous step, so it is never drawn. Its two
    -- callbacks, which the client calls when the player picks a colour or
    -- cancels, are called here as the client would.
    local info = color._pickerInfo
    openedColorPicker = true
    local opened = color:OpenPicker()
    local callsAfterOpen = #calls
    local shown = type(picker) == "table" and picker:IsShown() == true
    local pickerRed, pickerGreen, pickerBlue = nil, nil, nil
    if shown and type(picker.GetColorRGB) == "function" then
      pickerRed, pickerGreen, pickerBlue = picker:GetColorRGB()
    end
    info.swatchFunc()
    info.cancelFunc()
    local callsBeforeHide = #calls
    if type(picker) == "table" then
      picker:Hide()
    end
    openedColorPicker = false
    ctx:Expect(opened):ToBe(true)
    ctx:Expect(shown):ToBe(true)
    ctx:Log(
      ("client picker colour: %s %s %s"):format(
        tostring(pickerRed),
        tostring(pickerGreen),
        tostring(pickerBlue)
      )
    )
    -- The client's picker may call the swatch callback itself while it is
    -- set up; that count is logged, and the two calls made here are checked.
    ctx:Log(("callbacks while the client picker was set up: %d"):format(callsAfterOpen))
    ctx:Expect(callsBeforeHide - callsAfterOpen):ToBe(2)
    local picked = (calls[callsAfterOpen + 1] or { args = {} }).args
    local cancelled = (calls[callsAfterOpen + 2] or { args = {} }).args
    expectNear(ctx, "picked red", picked[1], 0.2, 0.01)
    expectNear(ctx, "picked green", picked[2], 0.4, 0.01)
    expectNear(ctx, "picked blue", picked[3], 0.6, 0.01)
    ctx:Expect(picked[4]):ToBe(1)
    ctx
      :Expect({ cancelled[1], cancelled[2], cancelled[3], cancelled[4] })
      :ToEqual({ 0.2, 0.4, 0.6, 1 })
    ctx:Log(("callbacks after ColorPickerFrame:Hide(): %d"):format(#calls - callsBeforeHide))
    local isSecureVariable = readHost("issecurevariable")
    if type(isSecureVariable) == "function" and type(picker) == "table" then
      for _, field in ipairs({ "swatchFunc", "cancelFunc", "opacityFunc" }) do
        local secure, taintedBy = isSecureVariable(picker, field)
        ctx:Log(
          ("issecurevariable(ColorPickerFrame, %q): %s %s"):format(
            field,
            tostring(secure),
            tostring(taintedBy)
          )
        )
      end
    end

    local reused = expectReleasedAndReused(ctx, color)
    local reusedCalls, reusedCallback = recorder()
    reused:SetCallback("OnValueChanged", reusedCallback)
    info.swatchFunc()
    info.cancelFunc()
    ctx:Expect(#reusedCalls):ToBe(0)
    red, green, blue, alpha = reused:GetColor()
    ctx:Expect({ red, green, blue, alpha }):ToEqual({ 1, 1, 1, 1 })
    ctx:Expect(cleared(reused:GetLabel())):ToBe("")
  end
)

types:Test(
  "Heading: 200x18, full width and empty with its two lines meeting in the middle; SetText centres the text between the lines, measured by the client; SetDisabled greys it; release and reuse give an empty full-width heading",
  function(ctx)
    local heading = createPlaced(ctx, "Heading")
    expectNear(ctx, "heading width", heading:GetWidth(), 200)
    expectNear(ctx, "heading height", heading:GetHeight(), 18)
    ctx:Expect(heading:IsFullWidth()):ToBe(true)
    ctx:Expect(cleared(heading:GetText())):ToBe("")
    expectPoint(
      ctx,
      "left line, empty",
      heading.leftLine,
      "RIGHT",
      heading:GetFrame(),
      "CENTER",
      0,
      0
    )

    heading:SetText("General")
    ctx:Expect(heading:GetText()):ToBe("General")
    expectPoint(ctx, "left line, titled", heading.leftLine, "RIGHT", heading.text, "LEFT", -6, 0)
    expectPoint(ctx, "right line, titled", heading.rightLine, "LEFT", heading.text, "RIGHT", 6, 0)
    local width = heading.text:GetStringWidth()
    ctx:Log(("'General' in GameFontNormal: string width %.2f"):format(width))
    ctx:Expect(width > 0):ToBe(true)
    heading:SetDisabled(true)
    expectNear(ctx, "disabled red", (heading.text:GetTextColor()), 0.5)
    heading:SetDisabled(false)
    heading:SetFullWidth(false)

    local reused = expectReleasedAndReused(ctx, heading)
    ctx:Expect(cleared(reused:GetText())):ToBe("")
    ctx:Expect(reused:IsFullWidth()):ToBe(true)
  end
)

types:Test(
  "Spacer: 10x8; SetWidth, SetHeight, SetFullWidth and SetRelativeWidth reach the frame and the size requests, a full width clears a relative one and back; release and reuse give a 10x8 spacer with no requests",
  function(ctx)
    local spacer = createPlaced(ctx, "Spacer")
    expectNear(ctx, "spacer width", spacer:GetWidth(), 10)
    expectNear(ctx, "spacer height", spacer:GetHeight(), 8)
    ctx:Expect(spacer:IsFullWidth()):ToBe(false)
    ctx:Expect(spacer:GetRelativeWidth()):ToBeNil()

    spacer:SetWidth(33)
    spacer:SetHeight(21)
    expectNear(ctx, "frame width", spacer:GetFrame():GetWidth(), 33)
    expectNear(ctx, "frame height", spacer:GetFrame():GetHeight(), 21)
    spacer:SetRelativeWidth(0.5)
    ctx:Expect(spacer:GetRelativeWidth()):ToBe(0.5)
    spacer:SetFullWidth(true)
    ctx:Expect(spacer:IsFullWidth()):ToBe(true)
    ctx:Expect(spacer:GetRelativeWidth()):ToBeNil()
    spacer:SetRelativeWidth(0.25)
    ctx:Expect(spacer:IsFullWidth()):ToBe(false)
    spacer:SetFullHeight(true)
    spacer:SetDisabled(true)

    local reused = expectReleasedAndReused(ctx, spacer)
    expectNear(ctx, "reused width", reused:GetWidth(), 10)
    expectNear(ctx, "reused height", reused:GetHeight(), 8)
    ctx:Expect(reused:IsFullWidth()):ToBe(false)
  end
)

-- widgetKit.layout ----------------------------------------------------------------------------

local layout = newSuite("layout")

layout:Test(
  "List stacks shown children from the content's top on real frames: explicit heights, a full-width child across the content, a half-width child, a hidden child left unanchored, a wrapped Label measured by the client and a nested Group whose growth moves the parent in the same pass",
  function(ctx)
    local container = createPlaced(ctx, "Group")
    container:SetWidth(316)
    local content = container:GetContent()
    container:PauseLayout()

    local first = create(ctx, "Spacer")
    first:SetHeight(20)
    local wide = create(ctx, "Spacer")
    wide:SetFullWidth(true)
    wide:SetHeight(30)
    local half = create(ctx, "Spacer")
    half:SetRelativeWidth(0.5)
    half:SetHeight(10)
    local hidden = create(ctx, "Spacer")
    local label = create(ctx, "Label")
    label:SetFullWidth(true)
    label:SetText(SHORT_TEXT)
    local oneLine = label:GetHeight()
    label:SetText(LONG_TEXT)
    local inner = create(ctx, "Group")
    inner:SetFullWidth(true)
    inner:SetTitle("Inner")
    local innerChild = create(ctx, "Spacer")
    innerChild:SetHeight(40)
    inner:AddChild(innerChild)

    ctx:Expect(container:AddChildren(first, wide, half, hidden, label, inner)):ToBe(6)
    hidden:Hide()
    container:ResumeLayout()
    ctx:Expect(container:PerformLayout()):ToBe(true)

    local labelHeight = label:GetHeight()
    ctx:Log(
      (
        "content %s; label at full width: font string width %.2f, string width %.2f,"
        .. " height %.2f (one line %.2f)"
      ):format(
        describeRect(content),
        label.text:GetWidth(),
        label.text:GetStringWidth(),
        labelHeight,
        oneLine
      )
    )
    expectNear(ctx, "content width", content:GetWidth(), 300)
    expectPoint(ctx, "first", first:GetFrame(), "TOPLEFT", content, "TOPLEFT", 0, 0)
    expectPoint(ctx, "wide", wide:GetFrame(), "TOPLEFT", content, "TOPLEFT", 0, -20)
    expectPoint(ctx, "wide right", wide:GetFrame(), "TOPRIGHT", content, "TOPRIGHT", 0, -20)
    expectPoint(ctx, "half", half:GetFrame(), "TOPLEFT", content, "TOPLEFT", 0, -50)
    ctx:Expect(hidden:GetNumPoints()):ToBe(0)
    expectPoint(ctx, "label", label:GetFrame(), "TOPLEFT", content, "TOPLEFT", 0, -60)
    local innerTop = 60 + labelHeight
    expectPoint(ctx, "inner", inner:GetFrame(), "TOPLEFT", content, "TOPLEFT", 0, -innerTop)
    expectNear(ctx, "inner height", inner:GetHeight(), 40 + 26 + 8)
    expectNear(ctx, "container height", container:GetHeight(), innerTop + 74 + 16)
    ctx:Expect(labelHeight >= 2 * oneLine - 0.5):ToBe(true)

    expectRect(ctx, "first rect", first:GetFrame(), content, 0, 0, 10, 20)
    expectRect(ctx, "wide rect", wide:GetFrame(), content, 0, 20, 300, 30)
    expectRect(ctx, "half rect", half:GetFrame(), content, 0, 50, 150, 10)
    expectRect(ctx, "label rect", label:GetFrame(), content, 0, 60, 300, labelHeight)
    expectRect(ctx, "inner rect", inner:GetFrame(), content, 0, innerTop, 300, 74)

    -- A child added to the nested group grows it; the growth reaches the
    -- outer container through LayoutFinished in the same call.
    local added = create(ctx, "Spacer")
    added:SetHeight(25)
    inner:AddChild(added)
    expectNear(ctx, "inner height after the addition", inner:GetHeight(), 99)
    expectNear(
      ctx,
      "container height after the addition",
      container:GetHeight(),
      innerTop + 99 + 16
    )

    -- The same rects after the client rendered a frame.
    waitOneFrame(ctx)
    expectRect(ctx, "label rect a frame later", label:GetFrame(), content, 0, 60, 300, labelHeight)
    expectRect(ctx, "inner rect a frame later", inner:GetFrame(), content, 0, innerTop, 300, 99)
    ctx:Log("inner group a frame later: " .. describeRect(inner:GetFrame()))
    logRectDeviation(ctx)
  end
)

layout:Test(
  "Fill anchors the first shown child to the content's corners, skipping a hidden one, and a nested ScrollFrame then sizes its scroll child to the 280-pixel viewport with a 300-pixel range",
  function(ctx)
    local container = createPlaced(ctx, "Group")
    container:SetLayout("Fill")
    container:SetFullHeight(true)
    container:SetWidth(316)
    container:SetHeight(216)
    local content = container:GetContent()

    local hidden = create(ctx, "Spacer")
    container:AddChild(hidden)
    hidden:Hide()
    local scroll = create(ctx, "ScrollFrame")
    local tall = create(ctx, "Spacer")
    tall:SetHeight(500)
    scroll:AddChild(tall)
    ctx:Expect(container:AddChild(scroll)):ToBe(true)

    expectPoint(ctx, "scroll top left", scroll:GetFrame(), "TOPLEFT", content, "TOPLEFT", 0, 0)
    expectPoint(
      ctx,
      "scroll bottom right",
      scroll:GetFrame(),
      "BOTTOMRIGHT",
      content,
      "BOTTOMRIGHT",
      0,
      0
    )
    expectRect(ctx, "scroll rect", scroll:GetFrame(), content, 0, 0, 300, 200)
    expectNear(ctx, "scroll child width", scroll:GetContent():GetWidth(), 280)
    expectNear(ctx, "scroll range", scroll:GetScrollRange(), 300)
    expectNear(ctx, "container keeps its full height", container:GetHeight(), 216)
    ctx:Log("filled scroll frame: " .. describeRect(scroll:GetFrame()))
    logRectDeviation(ctx)
  end
)

layout:Test(
  "Flow places children left to right on real frames and wraps before one that would pass the edge, gives a full-width child a row of its own and a full-height child the height left, and keeps ten tenths of a 107-pixel row on one row",
  function(ctx)
    local container = createPlaced(ctx, "Group")
    container:SetLayout("Flow")
    container:SetFullHeight(true)
    container:SetWidth(316)
    container:SetHeight(216)
    local content = container:GetContent()
    container:PauseLayout()

    ---@param width number
    ---@param height number
    ---@return any
    local function block(width, height)
      local spacer = create(ctx, "Spacer")
      spacer:SetWidth(width)
      spacer:SetHeight(height)
      container:AddChild(spacer)
      return spacer
    end
    local a = block(120, 20)
    local b = block(120, 30)
    local c = block(120, 10)
    local d = block(10, 8)
    d:SetRelativeWidth(0.5)
    local e = block(10, 12)
    e:SetFullWidth(true)
    local g = block(50, 10)
    g:SetFullHeight(true)
    container:ResumeLayout()
    ctx:Expect(container:PerformLayout()):ToBe(true)

    expectRect(ctx, "a", a:GetFrame(), content, 0, 0, 120, 20)
    expectRect(ctx, "b", b:GetFrame(), content, 120, 0, 120, 30)
    expectRect(ctx, "c wraps", c:GetFrame(), content, 0, 30, 120, 10)
    expectRect(ctx, "d half width", d:GetFrame(), content, 120, 30, 150, 8)
    expectRect(ctx, "e full width", e:GetFrame(), content, 0, 40, 300, 12)
    expectPoint(ctx, "e right", e:GetFrame(), "TOPRIGHT", content, "TOPRIGHT", 0, -40)
    expectRect(ctx, "g full height", g:GetFrame(), content, 0, 52, 50, 148)
    expectPoint(ctx, "b", b:GetFrame(), "TOPLEFT", content, "TOPLEFT", 120, 0)
    expectPoint(ctx, "c", c:GetFrame(), "TOPLEFT", content, "TOPLEFT", 0, -30)
    expectPoint(ctx, "d", d:GetFrame(), "TOPLEFT", content, "TOPLEFT", 120, -30)
    expectPoint(ctx, "g", g:GetFrame(), "TOPLEFT", content, "TOPLEFT", 0, -52)
    expectNear(ctx, "d width", d:GetWidth(), 150)
    expectNear(ctx, "g height", g:GetHeight(), 148)

    local row = createPlaced(ctx, "Group")
    row:SetLayout("Flow")
    row:SetWidth(123)
    row:PauseLayout()
    local tenths = {}
    for index = 1, 10 do
      local spacer = create(ctx, "Spacer")
      spacer:SetRelativeWidth(0.1)
      spacer:SetHeight(5)
      row:AddChild(spacer)
      tenths[index] = spacer
    end
    row:ResumeLayout()
    row:PerformLayout()
    local rowContent = row:GetContent()
    for index = 1, 10 do
      expectPoint(
        ctx,
        "tenth " .. index,
        tenths[index]:GetFrame(),
        "TOPLEFT",
        rowContent,
        "TOPLEFT",
        10.7 * (index - 1),
        0
      )
      expectRect(
        ctx,
        "tenth " .. index,
        tenths[index]:GetFrame(),
        rowContent,
        10.7 * (index - 1),
        0,
        10.7,
        5
      )
    end
    -- `GetPoint` answers point, relative frame, relative point, x and y.
    local _, _, _, lastX = tenths[10]:GetPoint(1)
    ctx:Log(
      ("row content %s; the tenth starts at x %.6f"):format(describeRect(rowContent), lastX or 0)
    )
    expectNear(ctx, "row group height", row:GetHeight(), 5 + 16)
    logRectDeviation(ctx)
  end
)

-- widgetKit.anchors ---------------------------------------------------------------------------

local anchors = newSuite("anchors")

anchors:Test(
  "Anchor.Normalize turns the SetPoint argument forms into anchors on a real frame: nil as the parent, UIParent as its global name, an unnamed parent as the frame itself, missing offsets as 0 and the frame's scale",
  function(ctx)
    local Anchor = WidgetKit.Anchor
    local frame = probeFrame("normalize")
    frame:SetParent(stage())
    frame:SetScale(0.8)

    local cases = {
      { args = { "TOPLEFT" }, expected = { "TOPLEFT", stageFrame, "TOPLEFT", 0, 0 } },
      { args = { "TOP", 5, -6 }, expected = { "TOP", stageFrame, "TOP", 5, -6 } },
      { args = { "LEFT", uiParent, 7, 8 }, expected = { "LEFT", "UIParent", "LEFT", 7, 8 } },
      {
        args = { "RIGHT", uiParent, "BOTTOMRIGHT", -1, 2 },
        expected = { "RIGHT", "UIParent", "BOTTOMRIGHT", -1, 2 },
      },
      {
        args = { "CENTER", "UIParent", "CENTER" },
        expected = { "CENTER", "UIParent", "CENTER", 0, 0 },
      },
      { args = { "BOTTOM", nil, "TOP", 3, 4 }, expected = { "BOTTOM", stageFrame, "TOP", 3, 4 } },
    }
    for index, case in ipairs(cases) do
      local args = case.args
      local anchor = Anchor.Normalize(frame, args[1], args[2], args[3], args[4], args[5])
      local expected = case.expected
      ctx:Expect(anchor.point):ToBe(expected[1])
      ctx:Expect(anchor.relativeTo):ToBe(expected[2])
      ctx:Expect(anchor.relativePoint):ToBe(expected[3])
      ctx:Expect(anchor.x):ToBe(expected[4])
      ctx:Expect(anchor.y):ToBe(expected[5])
      expectNear(ctx, "scale of form " .. index, anchor.scale, 0.8, 1e-6)
    end
  end
)

anchors:Test(
  "Anchor.Read of a real frame names UIParent by its global name; Anchor.Apply of that anchor puts another frame on the same rect with the anchor's scale; an unknown relative name leaves the frame alone",
  function(ctx)
    local Anchor = WidgetKit.Anchor
    local source = probeFrame("anchorSource")
    local target = probeFrame("anchorTarget")
    source:SetPoint("TOPLEFT", uiParent, "TOPLEFT", -3500, 3600)
    target:SetPoint("CENTER", stage(), "CENTER", 0, 0)

    local anchor = Anchor.Read(source)
    ctx:Expect(type(anchor)):ToBe("table")
    ctx:Expect(anchor.point):ToBe("TOPLEFT")
    ctx:Expect(anchor.relativeTo):ToBe("UIParent")
    ctx:Expect(anchor.relativePoint):ToBe("TOPLEFT")
    expectNear(ctx, "read x", anchor.x, -3500)
    expectNear(ctx, "read y", anchor.y, 3600)
    ctx:Expect(anchor.scale):ToBe(1)

    ctx:Expect(Anchor.Apply(target, anchor)):ToBe(true)
    local sourceLeft, sourceTop = rectOf(source)
    local targetLeft, targetTop = rectOf(target)
    expectNear(ctx, "applied left", targetLeft, sourceLeft)
    expectNear(ctx, "applied top", targetTop, sourceTop)
    expectPoint(ctx, "applied anchor", target, "TOPLEFT", uiParent, "TOPLEFT", -3500, 3600)

    local scaled = {
      point = "CENTER",
      relativeTo = "UIParent",
      relativePoint = "CENTER",
      x = -5000,
      y = 0,
      scale = 0.5,
    }
    ctx:Expect(Anchor.Apply(target, scaled)):ToBe(true)
    expectNear(ctx, "applied scale", target:GetScale(), 0.5, 1e-6)

    local applied, reason = Anchor.Apply(target, {
      point = "TOP",
      relativeTo = UNKNOWN_FRAME_NAME,
      x = 1,
      y = 1,
    })
    ctx:Expect(applied):ToBe(false)
    ctx:Expect(reason):ToBe("unknownRelative")
    expectPoint(ctx, "left alone", target, "CENTER", uiParent, "CENTER", -5000, 0)
    ctx:Expect(Anchor.Read(probeFrame("unanchored"))):ToBeNil()
  end
)

anchors:Test(
  "a window's position binding captures the nearest point of UIParent from the client's rects (TOPLEFT, BOTTOMRIGHT, CENTER, TOP), saves a plain table after Flush, and a second binding restores that anchor onto another frame",
  function(ctx)
    local window = create(ctx, "Frame")
    local frame = window:GetFrame()
    frame:SetParent(uiParent)
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", uiParent, "TOPLEFT", -3000, 3000)

    local storage = {}
    local binding = window:BindPosition(storage, { key = "pos" })
    trackedBindings[#trackedBindings + 1] = binding
    ctx:Expect(window:GetBinding()):ToBe(binding)
    ctx:Expect(storage.pos):ToBeNil()

    local moved = {}
    binding:OnMoved(function(_, anchor)
      moved[#moved + 1] = { point = anchor.point, x = anchor.x, y = anchor.y }
    end)
    local calls, callback = recorder()
    window:SetCallback("OnMoved", callback)
    -- The drag-stop script WidgetKit set on the title bar, as the client
    -- calls it when a drag ends: it captures, then fires OnMoved.
    window.titleBar:GetScript("OnDragStop")(window.titleBar)
    ctx:Expect(#moved):ToBe(1)
    ctx:Expect(#calls):ToBe(1)
    ctx:Expect(moved[1].point):ToBe("TOPLEFT")
    expectNear(ctx, "captured x", moved[1].x, -3000, 0.5)
    expectNear(ctx, "captured y", moved[1].y, 3000, 0.5)
    ctx:Log(
      ("window effective scale %.4f; captured TOPLEFT %.3f, %.3f"):format(
        frame:GetEffectiveScale(),
        moved[1].x,
        moved[1].y
      )
    )
    ctx:Expect(storage.pos):ToBeNil()
    ctx:Expect(binding:Flush()):ToBe(true)
    local saved = storage.pos
    ctx:Expect(type(saved)):ToBe("table")
    ctx:Expect(getmetatable(saved)):ToBeNil()
    ctx:Expect(saved.point):ToBe("TOPLEFT")
    ctx:Expect(saved.relativeTo):ToBe("UIParent")
    ctx:Expect(saved.relativePoint):ToBe("TOPLEFT")
    ctx:Expect(saved.scale):ToBe(1)

    frame:ClearAllPoints()
    frame:SetPoint("BOTTOMRIGHT", uiParent, "BOTTOMRIGHT", 3000, -3000)
    local anchor = binding:Capture()
    ctx:Expect(anchor.point):ToBe("BOTTOMRIGHT")
    expectNear(ctx, "BOTTOMRIGHT x", anchor.x, 3000, 0.5)

    -- A 10x10 probe with no texture and alpha 0 near the centre and the top
    -- edge: on screen, but nothing is drawn for it.
    local probe = probeFrame("election")
    local probeBinding = WidgetKit:BindPosition(probe, {}, { restore = false })
    trackedBindings[#trackedBindings + 1] = probeBinding
    probe:SetPoint("CENTER", uiParent, "CENTER", 10, 10)
    ctx:Expect(probeBinding:Capture().point):ToBe("CENTER")
    probe:ClearAllPoints()
    probe:SetPoint("TOP", uiParent, "TOP", 0, -5)
    local top = probeBinding:Capture()
    ctx:Expect(top.point):ToBe("TOP")
    expectNear(ctx, "TOP y", top.y, -5, 0.5)
    local rect = { left = 0, bottom = 0, width = 10, height = 10 }
    local parentRect = { left = 0, bottom = 0, width = 100, height = 100 }
    ctx:Expect(WidgetKit.Anchor.FromRect(rect, parentRect).point):ToBe("BOTTOMLEFT")

    ctx:Expect(binding:Release()):ToBe(true)
    ctx:Expect(binding:Release()):ToBe(false)
    ctx:Expect(binding:IsReleased()):ToBe(true)
    ctx:Expect(storage.pos.point):ToBe("BOTTOMRIGHT")

    local restoredFrame = probeFrame("restored")
    local restoring = WidgetKit:BindPosition(restoredFrame, storage, { key = "pos" })
    trackedBindings[#trackedBindings + 1] = restoring
    local savedPos = storage.pos
    expectPoint(
      ctx,
      "restored",
      restoredFrame,
      "BOTTOMRIGHT",
      uiParent,
      "BOTTOMRIGHT",
      savedPos.x,
      savedPos.y
    )
    ctx:Expect(restoring:Restore()):ToBe(true)
  end
)

anchors:Test(
  "Anchor.Apply of an anchor the client refuses answers false, refused: to the frame itself before anything changes, and into an anchor cycle after the client's SetPoint raised, with the frame's two points and scale put back; a binding restoring such an anchor keeps the frame in place and reports nothing",
  function(ctx)
    local Anchor = WidgetKit.Anchor
    local frame = probeFrame("anchorSource")
    frame:SetPoint("TOPLEFT", stage(), "TOPLEFT", 10, -10)
    frame:SetPoint("BOTTOMRIGHT", stageFrame, "TOPLEFT", 60, -60)
    local follower = probeFrame("anchorTarget")
    follower:SetPoint("TOP", frame, "BOTTOM", 0, 0)

    ---The frame is on its two original points at scale 1.
    ---@param label string
    local function expectUnchanged(label)
      ctx:Expect(frame:GetNumPoints()):ToBe(2)
      expectPoint(ctx, label .. " TOPLEFT", frame, "TOPLEFT", stageFrame, "TOPLEFT", 10, -10)
      expectPoint(
        ctx,
        label .. " BOTTOMRIGHT",
        frame,
        "BOTTOMRIGHT",
        stageFrame,
        "TOPLEFT",
        60,
        -60
      )
      expectNear(ctx, label .. " scale", frame:GetScale(), 1, 1e-6)
    end

    -- What the client's own SetPoint does with both, logged: it raises, and
    -- WidgetKit's refusal rests on that.
    local selfOk, selfProblem = pcall(frame.SetPoint, frame, "TOP", frame, "BOTTOM", 0, 0)
    local cycleOk, cycleProblem = pcall(frame.SetPoint, frame, "TOP", follower, "BOTTOM", 0, 0)
    ctx:Expect(selfOk):ToBe(false)
    ctx:Expect(cycleOk):ToBe(false)
    ctx:Log("client SetPoint to itself: " .. tostring(selfProblem))
    ctx:Log("client SetPoint into a cycle: " .. tostring(cycleProblem))
    expectUnchanged("after the client's refusals")

    local applied, reason = Anchor.Apply(frame, { point = "TOP", relativeTo = frame, scale = 3 })
    ctx:Expect(applied):ToBe(false)
    ctx:Expect(reason):ToBe("refused")
    expectUnchanged("itself")

    applied, reason = Anchor.Apply(frame, { point = "TOP", relativeTo = follower, scale = 3 })
    ctx:Expect(applied):ToBe(false)
    ctx:Expect(reason):ToBe("refused")
    expectUnchanged("cycle")

    local storage = { anchor = { point = "CENTER", relativeTo = follower, scale = 2 } }
    local binding
    local reported, observed = collectReportedErrors(function()
      binding = WidgetKit:BindPosition(frame, storage)
      trackedBindings[#trackedBindings + 1] = binding
    end)
    ctx:Expect(observed):ToBe(true)
    ctx:Expect(#reported):ToBe(0)
    expectUnchanged("restored")
    ctx:Expect(binding:Restore()):ToBe(false)
    expectUnchanged("restored again")
  end
)

-- widgetKit.media -----------------------------------------------------------------------------

local media = newSuite("media")

media:Test(
  "CreateMediaPicker lists MediaKit's font and statusbar names in MediaKit's order, PickIndex fires each name, and RenderOptions with options.media draws a select over MediaKit's fonts that writes the picked name",
  function(ctx)
    for _, mediaType in ipairs({ "font", "statusbar" }) do
      local names = MediaKit:List(mediaType)
      local picker = place(WidgetKit:CreateMediaPicker(mediaType))
      hush(picker)
      trackedWidgets[#trackedWidgets + 1] = picker
      ctx:Expect(picker:GetType()):ToBe("Dropdown")
      ctx:Expect(picker:GetNumEntries()):ToBe(#names)
      ctx:Log(
        ("%s: %d names, first %s, last %s"):format(
          mediaType,
          #names,
          tostring(names[1]),
          tostring(names[#names])
        )
      )
      local calls, callback = recorder()
      picker:SetCallback("OnValueChanged", callback)
      local checked = math.min(#names, 32)
      for index = 1, checked do
        picker:PickIndex(index)
      end
      ctx:Expect(#calls):ToBe(checked)
      for index = 1, checked do
        ctx:Expect(calls[index].args[1]):ToBe(names[index])
      end
      releaseNow(picker)
    end

    local fonts = MediaKit:List("font")
    local chosen = nil
    definedTrees[#definedTrees + 1] = addonName
    local tree = OptionsKit:Define(addonName, {
      type = "group",
      args = {
        font = {
          type = "select",
          name = "Font",
          values = function()
            local values = {}
            for index = 1, #fonts do
              values[fonts[index]] = fonts[index]
            end
            return values
          end,
          get = function()
            return chosen
          end,
          set = function(_, value)
            chosen = value
          end,
        },
      },
    })
    local container = createPlaced(ctx, "Group")
    container:Hide()
    local rendering = WidgetKit:RenderOptions(tree, container, { media = { font = "font" } })
    trackedRenderings[#trackedRenderings + 1] = rendering
    local dropdown = rendering:GetWidget("font")
    ctx:Expect(dropdown:GetNumEntries()):ToBe(#fonts)
    dropdown:PickIndex(1)
    ctx:Expect(chosen):ToBe(fonts[1])
    ctx:Expect(rendering:GetMessage("font")):ToBeNil()
  end
)

-- widgetKit.renderer --------------------------------------------------------------------------

local renderer = newSuite("renderer")

--- The values the renderer tests read and write, by option path.
---@type table<string, any>
local store = {}

---Reset `store` to the values a rendering starts from.
local function resetStore()
  store.enabled = true
  store.scale = 1
  store.mode = "b"
  store.nickname = "Molten"
  store.tint = { r = 1, g = 0.5, b = 0, a = 1 }
  store.flags = { x = true }
  store["advanced.level"] = 3
  store.hiddenOption = false
  store.runs = 0
end

---The `get` of every value option: the store entry at the option's path.
---@param info table
---@return any
local function storeGet(info)
  return store[info.path]
end

---The `set` of every value option.
---@param info table
---@param value any
local function storeSet(info, value)
  store[info.path] = value
end

---Define the renderer tests' tree: one option of every kind but keybinding,
---a hidden option and an inline group.
---@return any tree
local function defineRendererTree()
  resetStore()
  definedTrees[#definedTrees + 1] = addonName
  return OptionsKit:Define(addonName, {
    type = "group",
    args = {
      heading = { type = "header", name = "General", order = 1 },
      enabled = { type = "toggle", name = "Enabled", order = 2, get = storeGet, set = storeSet },
      scale = {
        type = "range",
        name = "Scale",
        order = 3,
        min = 0.5,
        max = 2,
        step = 0.25,
        get = storeGet,
        set = storeSet,
      },
      mode = {
        type = "select",
        name = "Mode",
        order = 4,
        values = { a = "Alpha", b = "Beta", c = "Gamma" },
        get = storeGet,
        set = storeSet,
      },
      nickname = {
        type = "input",
        name = "Nickname",
        order = 5,
        get = storeGet,
        set = storeSet,
        validate = function(_, value)
          if value == "bad" then
            return false, "no bad names"
          end
          return true
        end,
      },
      tint = {
        type = "color",
        name = "Tint",
        order = 6,
        hasAlpha = true,
        get = storeGet,
        set = storeSet,
      },
      flags = {
        type = "multiselect",
        name = "Flags",
        order = 7,
        values = { x = "X", y = "Y" },
        get = storeGet,
        set = storeSet,
      },
      run = {
        type = "execute",
        name = "Run",
        order = 8,
        func = function()
          store.runs = store.runs + 1
        end,
      },
      note = { type = "description", name = "Some words", order = 9, fontSize = "small" },
      hiddenOption = {
        type = "toggle",
        name = "Hidden",
        order = 10,
        hidden = true,
        get = storeGet,
        set = storeSet,
      },
      advanced = {
        type = "group",
        name = "Advanced",
        order = 11,
        inline = true,
        args = {
          level = {
            type = "range",
            name = "Level",
            min = 1,
            max = 10,
            step = 1,
            get = storeGet,
            set = storeSet,
          },
        },
      },
    },
  })
end

renderer:Test(
  "RenderOptions draws one widget per visible option into a hidden container, in order, hidden ones skipped, each showing the value Get returns",
  function(ctx)
    local tree = defineRendererTree()
    local container = createPlaced(ctx, "Group")
    container:Hide()
    local rendering = WidgetKit:RenderOptions(tree, container)
    trackedRenderings[#trackedRenderings + 1] = rendering

    local expectedTypes = {
      heading = "Heading",
      enabled = "CheckBox",
      scale = "Slider",
      mode = "Dropdown",
      nickname = "EditBox",
      tint = "ColorPicker",
      flags = "Group",
      run = "Button",
      note = "Label",
      advanced = "Group",
      ["advanced.level"] = "Slider",
    }
    for path, typeName in pairs(expectedTypes) do
      local widget = rendering:GetWidget(path)
      ctx:Expect(type(widget)):ToBe("table")
      if type(widget) == "table" then
        ctx:Expect(widget:GetType()):ToBe(typeName)
        ctx:Expect(widget:IsFullWidth()):ToBe(true)
      end
    end
    ctx:Expect(rendering:GetWidget("hiddenOption")):ToBeNil()
    local children = container:GetChildren()
    ctx:Expect(#children):ToBe(10)
    ctx:Expect(children[1]):ToBe(rendering:GetWidget("heading"))
    ctx:Expect(children[10]):ToBe(rendering:GetWidget("advanced"))
    ctx
      :Expect(rendering:GetWidget("advanced"):GetChildren()[1])
      :ToBe(rendering:GetWidget("advanced.level"))

    ctx:Expect(rendering:GetWidget("enabled"):GetValue()):ToBe(true)
    ctx:Expect(rendering:GetWidget("scale"):GetValue()):ToBe(1)
    ctx:Expect(rendering:GetWidget("mode"):GetValue()):ToBe("b")
    ctx:Expect(rendering:GetWidget("nickname"):GetText()):ToBe("Molten")
    local red, green, blue, alpha = rendering:GetWidget("tint"):GetColor()
    ctx:Expect({ red, green, blue, alpha }):ToEqual({ 1, 0.5, 0, 1 })
    local boxes = rendering:GetWidget("flags"):GetChildren()
    ctx:Expect(#boxes):ToBe(2)
    ctx:Expect(boxes[1]:GetValue()):ToBe(true)
    ctx:Expect(boxes[2]:GetValue()):ToBe(false)
    ctx:Expect(rendering:GetWidget("run"):GetText()):ToBe("Run")
    ctx:Expect(rendering:GetWidget("note"):GetText()):ToBe("Some words")
    ctx:Expect(rendering:GetWidget("advanced.level"):GetValue()):ToBe(3)
    ctx:Log(
      ("container height after one layout: %.2f; note label height %.2f"):format(
        container:GetHeight(),
        rendering:GetWidget("note"):GetHeight()
      )
    )
    ctx:Expect(container:IsVisible() == true):ToBe(false)
  end
)

renderer:Test(
  "user input through the rendered widgets reaches tree:Set, a Validate refusal is shown in a Label right below the edit box and cleared by the next accepted write, tree:Set from code refreshes the widget in place, and a real click on the execute Button runs func",
  function(ctx)
    local tree = defineRendererTree()
    local container = createPlaced(ctx, "Group")
    container:Hide()
    local rendering = WidgetKit:RenderOptions(tree, container)
    trackedRenderings[#trackedRenderings + 1] = rendering

    rendering:GetWidget("mode"):PickIndex(3)
    ctx:Expect(store.mode):ToBe("c")
    rendering:GetWidget("enabled").button:Click()
    ctx:Expect(store.enabled):ToBe(false)
    rendering:GetWidget("scale").slider:SetValue(1.5)
    ctx:Expect(store.scale):ToBe(1.5)
    rendering:GetWidget("flags"):GetChildren()[2].button:Click()
    ctx:Expect(store.flags):ToEqual({ x = true, y = true })
    rendering:GetWidget("run"):GetFrame():Click("LeftButton")
    ctx:Expect(store.runs):ToBe(1)

    local edit = rendering:GetWidget("nickname")
    local box = edit.singleBox
    local enter = box:GetScript("OnEnterPressed")
    box:SetText("bad")
    enter(box)
    ctx:Expect(store.nickname):ToBe("Molten")
    ctx:Expect(rendering:GetMessage("nickname")):ToBe("no bad names")
    ctx:Expect(edit:GetText()):ToBe("Molten")
    local children = container:GetChildren()
    local editIndex = 0
    for index = 1, #children do
      if children[index] == edit then
        editIndex = index
      end
    end
    ctx:Expect(children[editIndex + 1]:GetType()):ToBe("Label")
    ctx:Expect(#children):ToBe(11)
    box:SetText("Friday")
    enter(box)
    ctx:Expect(store.nickname):ToBe("Friday")
    ctx:Expect(rendering:GetMessage("nickname")):ToBeNil()
    ctx:Expect(container:GetNumChildren()):ToBe(10)

    ctx:Expect(tree:Set("scale", 0.75)):ToBe(true)
    ctx:Expect(rendering:GetWidget("scale"):GetValue()):ToBe(0.75)
    ctx:Expect(tree:Set("mode", "a")):ToBe(true)
    ctx:Expect(rendering:GetWidget("mode"):GetValue()):ToBe("a")
  end
)

renderer:Test(
  "Release gives every rendered widget back and empties the container; releasing a container releases a rendering drawn into it first",
  function(ctx)
    local tree = defineRendererTree()
    local container = createPlaced(ctx, "Group")
    container:Hide()
    local rendering = WidgetKit:RenderOptions(tree, container)
    trackedRenderings[#trackedRenderings + 1] = rendering
    local enabled = rendering:GetWidget("enabled")
    local statisticsBefore = WidgetKit:GetStatistics()

    ctx:Expect(rendering:Release()):ToBe(true)
    ctx:Expect(rendering:Release()):ToBe(false)
    ctx:Expect(rendering:IsReleased()):ToBe(true)
    ctx:Expect(container:GetNumChildren()):ToBe(0)
    ctx:Expect(WidgetKit:IsWidget(enabled)):ToBe(false)
    ctx:Expect(rendering:GetWidget("enabled")):ToBeNil()
    local statisticsAfter = WidgetKit:GetStatistics()
    ctx:Log(
      ("active widgets: %d with the rendering, %d after its release"):format(
        statisticsBefore.active,
        statisticsAfter.active
      )
    )
    -- Ten widgets in the container, the two CheckBoxes of the multiselect
    -- and the Slider of the inline group.
    ctx:Expect(statisticsBefore.active - statisticsAfter.active):ToBe(13)

    local second = WidgetKit:RenderOptions(tree, container)
    trackedRenderings[#trackedRenderings + 1] = second
    releaseNow(container)
    ctx:Expect(second:IsReleased()):ToBe(true)
    ctx:Expect(second:Release()):ToBe(false)
  end
)

-- widgetKit.allocation ------------------------------------------------------------------------

local allocation = newSuite("allocation")

allocation:Test(
  "Create and Release of each of the twelve base types again allocate nothing and hand back the same widget, 500 cycles each",
  function(ctx)
    for _, typeName in ipairs(BASE_TYPES) do
      local widget = create(ctx, typeName)
      local frame = widget:GetFrame()
      WidgetKit:Release(widget)
      local mismatches = 0
      expectNoAllocation(ctx, typeName .. " Create/Release", function()
        local again = WidgetKit:Create(typeName)
        if again ~= widget then
          mismatches = mismatches + 1
        end
        WidgetKit:Release(again)
      end)
      ctx:Expect(mismatches):ToBe(0)
      restoreFrame(frame)
    end
  end
)

allocation:Test(
  "PerformLayout of a List of ten children again and Fire of a set callback allocate nothing, 500 calls each",
  function(ctx)
    local container = createPlaced(ctx, "Group")
    container:PauseLayout()
    for _ = 1, 10 do
      local spacer = create(ctx, "Spacer")
      spacer:SetFullWidth(true)
      container:AddChild(spacer)
    end
    container:ResumeLayout()
    expectNoAllocation(ctx, "PerformLayout", function()
      container:PerformLayout()
    end)
    local fired = 0
    container:SetCallback("OnProbe", function()
      fired = fired + 1
    end)
    expectNoAllocation(ctx, "Fire", function()
      container:Fire("OnProbe", 1, 2)
    end)
    ctx:Expect(fired):ToBe(ALLOCATION_CYCLES + 1)
  end
)

-- widgetKit.errors --------------------------------------------------------------------------

local errors = newSuite("errors")

errors:Test(
  "Create called with a dot, a second Release, Release of a plain table and a method of a released widget are refused at the calling line; an unknown type answers nil and unknownType",
  function(ctx)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      WidgetKit.Create("Label")
    end, lines, "WidgetKit:Create must be called on the WidgetKit facade")

    local label = create(ctx, "Label")
    WidgetKit:Release(label)
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      WidgetKit:Release(label)
    end, lines, "WidgetKit:Release widget was already released")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      WidgetKit:Release({})
    end, lines, "WidgetKit:Release widget must be a WidgetKit widget")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      label:SetText("late")
    end, lines, "WidgetKit Label:SetText cannot be called on a released widget")

    local widget, reason = WidgetKit:Create("MoltenCodesTestNoSuchType")
    ctx:Expect(widget):ToBeNil()
    ctx:Expect(reason):ToBe("unknownType")
  end
)

errors:Test(
  "bad arguments to widget methods are refused at the calling line with docs/API.md's wording: SetSliderValues with minimum over maximum, SetText with a table, SetRelativeWidth(0), an unregistered layout and a beforeWidget that is no child",
  function(ctx)
    local lines = { start = 0 }
    local slider = create(ctx, "Slider")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      slider:SetSliderValues(10, 5)
    end, lines, "WidgetKit Slider:SetSliderValues minimum must not be greater than maximum")
    local label = create(ctx, "Label")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      label:SetText({})
    end, lines, "WidgetKit Label:SetText text must be a string, a number or nil")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      label:SetRelativeWidth(0)
    end, lines, "WidgetKit.Widget:SetRelativeWidth fraction must be above 0 and at most 1")
    local group = createPlaced(ctx, "Group")
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        group:SetLayout("MoltenCodesTestNoSuchLayout")
      end,
      lines,
      'WidgetKit.Container:SetLayout layout "MoltenCodesTestNoSuchLayout" is not registered'
    )
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      group:AddChild(label, slider)
    end, lines, "WidgetKit.Container:AddChild beforeWidget must be a child of this container")
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        group:AddChild(group)
      end,
      lines,
      "WidgetKit.Container:AddChild child must not be the container or a container above it"
    )
  end
)

errors:Test(
  "a Dropdown list past maxDropdownEntries and SetLimits with an unknown name or UNBOUNDED for maxCreatedCeiling are refused at the calling line, and the limits and the list stay as they were",
  function(ctx)
    local lines = { start = 0 }
    local limitsBefore = WidgetKit:GetLimits()
    local maxEntries = limitsBefore.maxDropdownEntries
    local dropdown = create(ctx, "Dropdown")
    dropdown:SetList({ a = "Alpha" })
    if type(maxEntries) == "number" then
      local values = {}
      for index = 1, maxEntries + 1 do
        values[index] = "entry " .. index
      end
      local expected = ("WidgetKit Dropdown:SetList holds at most %d entries (WidgetKit:SetLimits maxDropdownEntries)"):format(
        maxEntries
      )
      expectErrorAtCallingLine(ctx, function()
        lines.start = currentLine()
        dropdown:SetList(values)
      end, lines, expected)
      ctx:Expect(dropdown:GetNumEntries()):ToBe(1)
    else
      ctx:Log("maxDropdownEntries is UNBOUNDED in this session; the list bound was not exercised")
    end
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      WidgetKit:SetLimits({ maxWidgets = 3 })
    end, lines, "WidgetKit:SetLimits limits.maxWidgets is not a recognised limit")
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        WidgetKit:SetLimits({ maxCreatedCeiling = WidgetKit.UNBOUNDED })
      end,
      lines,
      "WidgetKit:SetLimits limits.maxCreatedCeiling cannot be WidgetKit.UNBOUNDED: the client never frees a frame"
    )
    ctx:Expect(WidgetKit:GetLimits()):ToEqual(limitsBefore)
  end
)

errors:Test(
  "a callback that raises is reported through the client's error handler once per call, from a real Click and from Fire, naming WidgetKitSuite.lua at its line, and Fire returns false without raising",
  function(ctx)
    local button = createPlaced(ctx, "Button")
    local failingLine = 0
    button:SetCallback("OnClick", function()
      failingLine = currentLine()
      error("widget callback failure")
    end)
    local fired = nil
    local reported, observed = collectReportedErrors(function()
      button:GetFrame():Click("LeftButton")
      fired = button:Fire("OnClick", "LeftButton")
    end)
    if not observed then
      ctx:Fail(
        "the client's error handler could not be replaced (an error-capturing addon such as BugGrabber keeps it); the failure went to that addon"
      )
      return
    end
    ctx:Expect(fired):ToBe(false)
    ctx:Expect(#reported):ToBe(2)
    ctx:Log("reported: " .. tostring(reported[1]))
    local line = expectThisFile(ctx, reported[1])
    ctx:Expect(line):ToBe(failingLine + 1)
    ctx
      :Expect(tostring(reported[1]):sub(-#"widget callback failure"))
      :ToBe("widget callback failure")
  end
)

-- widgetKit.secrets ---------------------------------------------------------------------------

local secrets = newSuite("secrets")

--- Why the secrets tests are skipped on a client without the two functions.
local SECRETS_SKIP_REASON =
  "the client has no issecretvalue and secretwrap; the secret path was not exercised"

---Register `body` as a test when the client can make a secret value, and as a
---skipped test naming why otherwise: the client lacks `issecretvalue` and
---`secretwrap`, or it has both (Classic Era and Mists Classic document them)
---but `issecretvalue` does not report what `secretwrap` returns as secret,
---which `Harness:CanMakeSecrets` measures once.
---@param name string
---@param body fun(ctx: TestKit.Context)
local function secretTest(name, body)
  if not SECRETS_AVAILABLE then
    secrets:Skip(name, SECRETS_SKIP_REASON)
  elseif not Harness:CanMakeSecrets() then
    secrets:Skip(name, Harness.NO_SECRETS_REASON)
  else
    secrets:Test(name, body)
  end
end

---A genuine secret value made by the client's `secretwrap`, or a failed test.
---@param ctx TestKit.Context
---@param value any
---@return any secret
local function makeSecret(ctx, value)
  local succeeded, secret = pcall(secretWrap, value)
  if not succeeded then
    ctx:Fail("secretwrap raised, so the secret path was not exercised: " .. tostring(secret))
  end
  if not isSecret(secret) then
    ctx:Fail("secretwrap returned a value issecretvalue does not report as secret")
  end
  return secret
end

secretTest(
  "text setters refuse a secretwrap string at the calling line; with allowSecret a Label shows it one line high on a font string of its own, and the next use of the same Label shows a plain empty text and measures plain texts again, wrapped ones included",
  function(ctx)
    local secretText = makeSecret(ctx, "hunter2")
    local lines = { start = 0 }
    local label = createPlaced(ctx, "Label")
    local button = create(ctx, "Button")
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        label:SetText(secretText)
      end,
      lines,
      "WidgetKit Label:SetText text must not be a secret value unless options.allowSecret is true"
    )
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        button:SetText(secretText)
      end,
      lines,
      "WidgetKit Button:SetText text must not be a secret value unless options.allowSecret is true"
    )

    local plainText = label.text
    label:SetText(secretText, { allowSecret = true })
    expectNear(ctx, "secret label height", label:GetHeight(), 12)
    -- Revision 7 shows a secret on a font string of its own: a font string
    -- that showed one measures every later text as a secret, `ClearText` or
    -- not (the run of 2026-09-25, 11:09).
    local secretFontString = label.text
    ctx:Expect(secretFontString ~= plainText):ToBe(true)
    ctx:Log(
      "Label:GetText() after a secret text is secret: " .. tostring(isSecret(label:GetText()))
    )
    local heading = create(ctx, "Heading")
    local headed, headingProblem =
      pcall(heading.SetText, heading, secretText, { allowSecret = true })
    ctx:Log("Heading with a secret text: " .. (headed and "shown" or tostring(headingProblem)))
    ctx:Expect(headed):ToBe(true)

    local frame = label:GetFrame()
    WidgetKit:Release(label)
    local reused = create(ctx, "Label")
    ctx:Expect(reused:GetFrame()):ToBe(frame)
    -- The next use is back on the font string that never showed the secret.
    ctx:Expect(reused.text):ToBe(plainText)
    local text = reused:GetText()
    reused:SetText(SHORT_TEXT)
    local measured = reused.text:GetStringHeight()
    ctx:Log(
      ("reused Label: GetText() secret %s, GetStringHeight() secret %s; the secret font string's GetStringHeight() secret %s"):format(
        tostring(isSecret(text)),
        tostring(isSecret(measured)),
        tostring(isSecret(secretFontString:GetStringHeight()))
      )
    )
    ctx:Expect(isSecret(text)):ToBe(false)
    ctx:Expect(cleared(text)):ToBe("")
    ctx:Expect(isSecret(measured)):ToBe(false)
    if isSecret(measured) then
      return
    end
    -- The height is the client's measure of the plain text, not one line.
    local oneLine = reused:GetHeight()
    expectNear(ctx, "reused label height is the string height", oneLine, measured)
    reused:SetText(LONG_TEXT)
    local wrapped = reused:GetHeight()
    ctx:Log(("reused Label, long text: height %.2f, one line %.2f"):format(wrapped, oneLine))
    expectNear(
      ctx,
      "reused wrapped height is the string height",
      wrapped,
      reused.text:GetStringHeight()
    )
    ctx:Expect(wrapped >= 2 * oneLine - 0.5):ToBe(true)
  end
)

secretTest(
  "a secretwrap boolean handed to SetDisabled, SetFullWidth, SetIsPercent, SetKeyCapture, SetTriState, SetMultiLine, SetHasAlpha, SetResizable or options.allowSecret is refused at the calling line",
  function(ctx)
    local secretTrue = makeSecret(ctx, true)
    local lines = { start = 0 }
    local label = create(ctx, "Label")
    local spacer = create(ctx, "Spacer")
    local slider = create(ctx, "Slider")
    local button = create(ctx, "Button")
    local box = create(ctx, "CheckBox")
    local edit = create(ctx, "EditBox")
    local color = create(ctx, "ColorPicker")
    local window = createPlaced(ctx, "Frame")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      label:SetDisabled(secretTrue)
    end, lines, "WidgetKit Label:SetDisabled disabled must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      spacer:SetDisabled(secretTrue)
    end, lines, "WidgetKit.Widget:SetDisabled disabled must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      spacer:SetFullWidth(secretTrue)
    end, lines, "WidgetKit.Widget:SetFullWidth fullWidth must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      slider:SetIsPercent(secretTrue)
    end, lines, "WidgetKit Slider:SetIsPercent isPercent must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      button:SetKeyCapture(secretTrue)
    end, lines, "WidgetKit Button:SetKeyCapture enabled must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      box:SetTriState(secretTrue)
    end, lines, "WidgetKit CheckBox:SetTriState enabled must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      edit:SetMultiLine(secretTrue)
    end, lines, "WidgetKit EditBox:SetMultiLine multiLine must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      color:SetHasAlpha(secretTrue)
    end, lines, "WidgetKit ColorPicker:SetHasAlpha hasAlpha must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      window:SetResizable(secretTrue)
    end, lines, "WidgetKit Frame:SetResizable resizable must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      label:SetText("x", { allowSecret = secretTrue })
    end, lines, "WidgetKit Label:SetText options.allowSecret must not be a secret value")
    ctx:Expect(spacer:IsFullWidth()):ToBe(false)
  end
)

secretTest(
  "secret values WidgetKit would compare or use as a key are refused at the calling line (CheckBox and Dropdown values, a SetList order key and label, a user-data key, sizes, an index, a letter count, a justification, a type name), while a secret user-data value is kept",
  function(ctx)
    local secretTrue = makeSecret(ctx, true)
    local secretKey = makeSecret(ctx, "a")
    local secretNumber = makeSecret(ctx, 3)
    local lines = { start = 0 }
    local box = create(ctx, "CheckBox")
    local dropdown = create(ctx, "Dropdown")
    local edit = create(ctx, "EditBox")
    local label = create(ctx, "Label")
    local group = create(ctx, "Group")
    dropdown:SetList({ a = "Alpha" })
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      box:SetValue(secretTrue)
    end, lines, "WidgetKit CheckBox:SetValue value must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      dropdown:SetValue(secretKey)
    end, lines, "WidgetKit Dropdown:SetValue key must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      dropdown:SetList({ a = "Alpha" }, { secretKey })
    end, lines, "WidgetKit Dropdown:SetList key must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      dropdown:SetList({ b = secretKey })
    end, lines, "WidgetKit Dropdown:SetList label must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      dropdown:PickIndex(secretNumber)
    end, lines, "WidgetKit Dropdown:PickIndex index must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      label:SetUserData(secretKey, 1)
    end, lines, "WidgetKit.Widget:SetUserData key must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      label:SetRelativeWidth(secretNumber)
    end, lines, "WidgetKit.Widget:SetRelativeWidth fraction must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      label:SetWidth(secretNumber)
    end, lines, "WidgetKit.Widget:SetWidth width must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      edit:SetMaxLetters(secretNumber)
    end, lines, "WidgetKit EditBox:SetMaxLetters letters must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      label:SetJustifyH(secretKey)
    end, lines, "WidgetKit Label:SetJustifyH justify must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      group:SetMaxChildren(secretNumber)
    end, lines, "WidgetKit.Container:SetMaxChildren limit must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      WidgetKit:Create(secretKey)
    end, lines, "WidgetKit:Create name must not be a secret value")

    ctx:Expect(dropdown:GetNumEntries()):ToBe(1)
    ctx:Expect(box:GetValue()):ToBe(false)
    label:SetUserData("kept", secretNumber)
    ctx:Expect(isSecret(label:GetUserData("kept"))):ToBe(true)
    local limitsBefore = WidgetKit:GetLimits()
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      WidgetKit:SetLimits({ maxDropdownEntries = secretNumber })
    end, lines, "WidgetKit:SetLimits limits.maxDropdownEntries must not be a secret value")
    ctx:Expect(WidgetKit:GetLimits()):ToEqual(limitsBefore)
  end
)

secretTest(
  "Anchor.Normalize and Anchor.Apply refuse a secret offset at the calling line, and a binding's Restore of a saved anchor with a secret offset reports it through the error handler and leaves the frame where it was",
  function(ctx)
    local secretNumber = makeSecret(ctx, 5)
    local lines = { start = 0 }
    local frame = probeFrame("secretAnchor")
    frame:SetPoint("CENTER", stage(), "CENTER", 1, 2)
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      WidgetKit.Anchor.Normalize(frame, "TOPLEFT", secretNumber, 0)
    end, lines, "WidgetKit.Anchor.Normalize x must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      WidgetKit.Anchor.Apply(frame, { point = "TOPLEFT", x = secretNumber, y = 0 })
    end, lines, "WidgetKit.Anchor.Apply anchor.x must not be a secret value")

    local storage =
      { saved = { point = "TOPLEFT", relativeTo = "UIParent", x = secretNumber, y = 0 } }
    local reported, observed = collectReportedErrors(function()
      local binding = WidgetKit:BindPosition(frame, storage, { key = "saved" })
      trackedBindings[#trackedBindings + 1] = binding
    end)
    if not observed then
      ctx:Fail(
        "the client's error handler could not be replaced (an error-capturing addon such as BugGrabber keeps it); the report went to that addon"
      )
      return
    end
    ctx:Expect(#reported):ToBe(1)
    ctx:Log("reported: " .. tostring(reported[1]))
    ctx
      :Expect(tostring(reported[1]):sub(-#"must not be a secret value"))
      :ToBe("must not be a secret value")
    expectPoint(ctx, "frame left in place", frame, "CENTER", stageFrame, "CENTER", 1, 2)
  end
)

secretTest(
  "a layout function that returns secret sizes is ignored like any non-number, so the group keeps its insets; the client's answer to SetWidth with a secret from addon code is logged",
  function(ctx)
    local secretWidth = makeSecret(ctx, 123)
    local secretHeight = makeSecret(ctx, 456)
    local group = createPlaced(ctx, "Group")
    group:SetLayout(function()
      return secretWidth, secretHeight
    end)
    ctx:Expect(group:GetLayoutName()):ToBeNil()
    ctx:Expect(group:PerformLayout()):ToBe(true)
    expectNear(ctx, "group height from insets alone", group:GetHeight(), 16)

    local probe = probeFrame("secretWidth")
    local accepted, problem = pcall(probe.SetWidth, probe, secretWidth)
    if accepted then
      local width = probe:GetWidth()
      ctx:Log("SetWidth(secret) accepted; GetWidth() is secret: " .. tostring(isSecret(width)))
    else
      ctx:Log("SetWidth(secret) refused by the client: " .. tostring(problem))
    end
    probe:SetWidth(10)
  end
)

secretTest(
  "RenderOptions shows a secret input value as '<secret value>' and disables it, disables a toggle whose value is secret, and refuses a secret options.allowSecret at the calling line",
  function(ctx)
    local secretText = makeSecret(ctx, "hunter2")
    local secretTrue = makeSecret(ctx, true)
    definedTrees[#definedTrees + 1] = addonName
    local tree = OptionsKit:Define(addonName, {
      type = "group",
      args = {
        password = {
          type = "input",
          name = "Password",
          get = function()
            return secretText
          end,
          set = function() end,
        },
        flag = {
          type = "toggle",
          name = "Flag",
          get = function()
            return secretTrue
          end,
          set = function() end,
        },
      },
    })
    local container = createPlaced(ctx, "Group")
    container:Hide()
    local rendering = WidgetKit:RenderOptions(tree, container)
    trackedRenderings[#trackedRenderings + 1] = rendering
    local edit = rendering:GetWidget("password")
    ctx:Expect(edit:GetText()):ToBe("<secret value>")
    ctx:Expect(edit.singleBox:IsEnabled() == true):ToBe(false)
    local box = rendering:GetWidget("flag")
    ctx:Expect(box.button:IsEnabled() == true):ToBe(false)
    ctx:Expect(box:GetValue()):ToBe(false)
    rendering:Release()

    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      WidgetKit:RenderOptions(tree, container, { allowSecret = secretTrue })
    end, lines, "WidgetKit:RenderOptions options.allowSecret must not be a secret value")
  end
)

secretTest(
  "EditBox:SetText refuses a secret at the calling line even with allowSecret, as the client's edit box refuses one from addon code (logged), and RenderOptions with allowSecret shows a secret input value as '<secret value>', disabled",
  function(ctx)
    local secretText = makeSecret(ctx, "hunter2")
    local lines = { start = 0 }
    local edit = create(ctx, "EditBox")
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        edit:SetText(secretText, { allowSecret = true })
      end,
      lines,
      "WidgetKit EditBox:SetText text must not be a secret value:"
        .. " the client's edit box takes one only from untainted code"
    )
    ctx:Expect(edit:GetText()):ToBe("")
    -- The client's own answer, on the widget's edit box, for the record.
    local accepted, problem = pcall(edit.singleBox.SetText, edit.singleBox, secretText)
    ctx:Log(
      "client EditBox:SetText(secret) from addon code: "
        .. (accepted and "accepted" or ("refused: " .. tostring(problem)))
    )
    edit.singleBox:SetText("")

    definedTrees[#definedTrees + 1] = addonName
    local tree = OptionsKit:Define(addonName, {
      type = "group",
      args = {
        password = {
          type = "input",
          name = "Password",
          get = function()
            return secretText
          end,
          set = function() end,
        },
      },
    })
    local container = createPlaced(ctx, "Group")
    container:Hide()
    local rendered, rendering = pcall(WidgetKit.RenderOptions, WidgetKit, tree, container, {
      allowSecret = true,
    })
    if not rendered then
      ctx:Log("RenderOptions raised: " .. tostring(rendering))
      ctx:Fail("RenderOptions with allowSecret raised; see the log for the client's message")
      return
    end
    trackedRenderings[#trackedRenderings + 1] = rendering
    local input = rendering:GetWidget("password")
    ctx:Expect(input:GetText()):ToBe("<secret value>")
    ctx:Expect(input.singleBox:IsEnabled() == true):ToBe(false)
  end
)

-- widgetKit.taint -----------------------------------------------------------------------------

local taint = newSuite("taint")

taint:Test(
  "the client reported no ADDON_ACTION_BLOCKED or ADDON_ACTION_FORBIDDEN for a MoltenCodes addon since this addon loaded; every report and the security of the client globals WidgetKit reads are logged",
  function(ctx)
    ctx:Log(("blocked or forbidden actions reported: %d"):format(#blockedActions))
    local ours = 0
    for _, entry in ipairs(blockedActions) do
      ctx:Log(
        ("%s: addon %s, action %s"):format(
          entry.event,
          tostring(entry.addon),
          tostring(entry.action)
        )
      )
      if type(entry.addon) == "string" and entry.addon:find("^MoltenCodes") then
        ours = ours + 1
      end
    end
    local isSecureVariable = readHost("issecurevariable")
    if type(isSecureVariable) == "function" then
      for _, name in ipairs({ "UIParent", "ColorPickerFrame", "CreateFrame", "GameFontNormal" }) do
        local secure, taintedBy = isSecureVariable(name)
        ctx:Log(("issecurevariable(%q): %s %s"):format(name, tostring(secure), tostring(taintedBy)))
      end
    end
    ctx:Expect(ours):ToBe(0)
  end
)
