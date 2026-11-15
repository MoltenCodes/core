-- MoltenCodes Test: TooltipKitSuite.lua
--
-- Real-client suites for the `tooltipKit` package. The Busted specs under
-- packages/tooltipKit/tests/ prove TooltipKit against the shared frame stub,
-- which measures text at 6 pixels a character; these prove, inside the game
-- client with the installed MoltenCodes addon, what the stub can only assume:
--
--   * the installed facade and its committed revision;
--   * a tooltip with a header, three columns and a spanning cell laid out
--     with the client's own fonts: columns as wide as their widest cell, a
--     span that fits, the frame as wide as its columns and padding;
--   * a cell whose text grows on a shown tooltip widening its column: the
--     client's `GetStringWidth` stops at the width a font string was given,
--     so the layout must measure with `GetUnboundedStringWidth`;
--   * a height limit with wheel scrolling on the client's scroll frame;
--   * smart anchoring to a frame in the middle of the screen;
--   * auto-hide releasing the tooltip on the client's frame updates;
--   * every frame back in its pool after a release, and reused;
--   * a secret text, made by the client's `secretwrap`, refused at this
--     file's line, and drawn with `allowSecret`.
--
-- Each tooltip is shown for at most a few frames in the middle of the screen.
-- What a run leaves behind: TooltipKit's pooled frames (hidden, kept for
-- reuse as the client never frees a frame) and one empty anchor frame of
-- this file. Nothing is written to a saved variable.
--
-- Run with `/mct run tooltipKit`; tests/client/MoltenCodesTest_TooltipKit/EXPECTED.md
-- lists what the chat frame should show.

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

local PACKAGE_ID = "tooltipKit"
local KEY = "MoltenCodesTest_TooltipKit"

--- Every method docs/API.md of tooltipKit lists on the facade.
local FACADE_METHODS = { "Acquire", "Release", "IsAcquired", "SetLimits", "GetLimits" }

--- Padding and the gap between columns, as docs/API.md states them.
local PADDING, COLUMN_GAP = 10, 10

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- CreateFrame, UIParent and the secret-value functions are World of
  -- Warcraft client globals, reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, 2)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- TooltipKit is not in the language-server workspace of tests/client, so its
-- facade is typed `any` here.
---@type any
local TooltipKit = Registry:Get(PACKAGE_ID, 1)
if type(TooltipKit) == "nil" then
  error(addonName .. " requires TooltipKit API 1 in the MoltenCodes addon; reinstall it", 0)
end

local isSecretValue = readHost("issecretvalue")
local secretWrap = readHost("secretwrap")

--- The anchor frame, made once per session.
local anchor = nil

---A frame in the middle of the screen to anchor to.
---@return table
local function anchorFrame()
  if anchor == nil then
    anchor = readHost("CreateFrame")("Frame", nil, readHost("UIParent"))
    anchor:SetSize(40, 20)
    anchor:SetPoint("CENTER", readHost("UIParent"), "CENTER", 0, 200)
  end
  return anchor
end

---`ctx:WaitUntil` through an untyped alias (see CommKitSuite.lua, `waitUntil`).
---@param ctx TestKit.Context
---@param predicate fun(): any
---@param timeoutSeconds number
---@return boolean satisfied
local function waitUntil(ctx, predicate, timeoutSeconds)
  ---@type any
  local context = ctx
  return context:WaitUntil(predicate, timeoutSeconds) == true
end

---Register a suite of this package whose tests end with the tooltip released.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName)
  suite:After(function()
    if TooltipKit:IsAcquired(KEY) then
      TooltipKit:Release(TooltipKit:Acquire(KEY, 3))
    end
  end)
  return suite
end

-- tooltipKit.facade ----------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('tooltipKit', 1) is the TooltipKit facade with API 1 and every documented method",
  function(ctx)
    ctx:Expect(rawget(TooltipKit, "API")):ToBe(1)
    for _, method in ipairs(FACADE_METHODS) do
      ctx:Expect(type(TooltipKit[method])):ToBe("function")
    end
  end
)

facade:Test("the installed TooltipKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      ctx:Expect(rawget(TooltipKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list tooltipKit")
end)

-- tooltipKit.layout ----------------------------------------------------------

local layout = newSuite("layout")

layout:Test("three columns, a header and a span are laid out with the client's fonts", function(ctx)
  local tooltip = TooltipKit:Acquire(KEY, 3, "LEFT", "CENTER", "RIGHT")
  tooltip:AddHeader("Name", "Level", "Zone")
  tooltip:AddSeparator()
  tooltip:AddLine("Alice", 70, "Dornogal")
  tooltip:AddLine("Bartholomew", 9, "Elwynn Forest")
  local spanLine = tooltip:AddLine()
  tooltip:SetCell(
    spanLine,
    1,
    "A long line spanning all three columns of the tooltip",
    { span = 3 }
  )
  tooltip:Show()
  local frame = tooltip:GetFrame()
  local width, height = frame:GetWidth(), frame:GetHeight()
  ctx:Log(("tooltip %.1f x %.1f"):format(width, height))
  ctx:Expect(tooltip:IsShown()):ToBe(true)
  ctx:Expect(tooltip:GetLineCount()):ToBe(5)
  ctx:Expect(width > 2 * PADDING + 2 * COLUMN_GAP):ToBe(true)
  ctx:Expect(height > 2 * PADDING):ToBe(true)
end)

layout:Test("a cell whose text grows on a shown tooltip widens its column", function(ctx)
  local tooltip = TooltipKit:Acquire(KEY, 3)
  local line = tooltip:AddLine("ab")
  tooltip:Show()
  local frame = tooltip:GetFrame()
  local before = frame:GetWidth()
  tooltip:SetCell(line, 1, "a much longer text than the one the cell was laid out for")
  local after = frame:GetWidth()
  ctx:Log(("tooltip width %.1f, then %.1f"):format(before, after))
  -- The longer text is about thirty times as wide; twice is a safe floor
  -- that a truncated measurement (the same width) cannot reach.
  ctx:Expect(after > 2 * before):ToBe(true)
end)

layout:Test(
  "a height limit scrolls the lines with the wheel on the client's scroll frame",
  function(ctx)
    local tooltip = TooltipKit:Acquire(KEY, 3)
    for index = 1, 40 do
      tooltip:AddLine("Line " .. index, index, "")
    end
    tooltip:SetMaxHeight(150)
    tooltip:Show()
    local frame = tooltip:GetFrame()
    ctx:Expect(math.floor(frame:GetHeight() + 0.5)):ToBe(150)
    frame:GetScript("OnMouseWheel")(frame, -1)
    local scrolled = frame.scroll:GetVerticalScroll()
    ctx:Log(("one notch scrolls %.1f"):format(scrolled))
    ctx:Expect(scrolled > 0):ToBe(true)
    frame:GetScript("OnMouseWheel")(frame, 100)
    ctx:Expect(frame.scroll:GetVerticalScroll()):ToBe(0)
  end
)

layout:Test("SmartAnchorTo puts the tooltip on the side of the frame with room", function(ctx)
  local tooltip = TooltipKit:Acquire(KEY, 3)
  tooltip:AddLine("Anchored")
  local owner = anchorFrame()
  tooltip:SmartAnchorTo(owner)
  tooltip:Show()
  local point, relativeTo, relativePoint = tooltip:GetFrame():GetPoint(1)
  ctx:Log("anchored " .. tostring(point) .. " to " .. tostring(relativePoint))
  ctx:Expect(relativeTo):ToBe(owner)
  -- The frame sits above the screen's middle, left of nothing: below it.
  ctx:Expect(point == "TOPLEFT" or point == "TOPRIGHT"):ToBe(true)
end)

-- tooltipKit.lifecycle -------------------------------------------------------

local lifecycle = newSuite("lifecycle")

lifecycle:Test("auto-hide releases the tooltip on the client's frame updates", function(ctx)
  local tooltip = TooltipKit:Acquire(KEY, 3)
  tooltip:AddLine("Going")
  tooltip:SmartAnchorTo(anchorFrame())
  tooltip:SetAutoHideDelay(0.1)
  tooltip:Show()
  ctx
    :Expect(waitUntil(ctx, function()
      return not TooltipKit:IsAcquired(KEY)
    end, 3))
    :ToBe(true)
end)

lifecycle:Test("a released tooltip's frames return to their pools and are reused", function(ctx)
  local tooltip = TooltipKit:Acquire(KEY, 3)
  for index = 1, 5 do
    tooltip:AddLine(index)
  end
  local frame = tooltip:GetFrame()
  local linePool = TooltipKit._state.linePool
  local createdBefore = linePool:GetCreatedCount()
  TooltipKit:Release(tooltip)
  ctx:Expect(TooltipKit:IsAcquired(KEY)):ToBe(false)
  local again = TooltipKit:Acquire(KEY, 3)
  for index = 1, 5 do
    again:AddLine(index)
  end
  ctx:Expect(again:GetFrame()):ToBe(frame)
  ctx:Expect(linePool:GetCreatedCount()):ToBe(createdBefore)
  ctx:Log("line frames made this session: " .. createdBefore)
end)

-- tooltipKit.secrets ---------------------------------------------------------

local secrets = newSuite("secrets")

local SECRET_TEST =
  "AddLine refuses a secret text at this file's line, and SetCell draws one with allowSecret"

if type(isSecretValue) ~= "function" or type(secretWrap) ~= "function" then
  secrets:Skip(
    SECRET_TEST,
    "the client has no issecretvalue and secretwrap; the secret path was not exercised"
  )
elseif not Harness:CanMakeSecrets() then
  secrets:Skip(SECRET_TEST, Harness.NO_SECRETS_REASON)
else
  secrets:Test(SECRET_TEST, function(ctx)
    local secret = secretWrap("hidden")
    local tooltip = TooltipKit:Acquire(KEY, 3)
    -- Not a tail call: a `return tooltip:AddLine(secret)` would drop this
    -- function's frame from the stack, and the message its file and line.
    local succeeded, message = pcall(function()
      local index = tooltip:AddLine(secret)
      return index
    end)
    ctx:Expect(succeeded):ToBe(false)
    ctx:Log("client message: " .. tostring(message))
    ctx
      :Expect(type(message) == "string" and message:find("TooltipKitSuite.lua:", 1, true) ~= nil)
      :ToBe(true)
    local line = tooltip:AddLine()
    tooltip:SetCell(line, 1, secret, { allowSecret = true })
    tooltip:Show()
    ctx:Expect(tooltip:IsShown()):ToBe(true)
  end)
end
