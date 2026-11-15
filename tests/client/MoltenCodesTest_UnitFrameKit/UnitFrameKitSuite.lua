-- MoltenCodes Test: UnitFrameKitSuite.lua
--
-- Real-client suites for the `unitFrameKit` package. The Busted specs under
-- packages/unitFrameKit/tests/ prove UnitFrameKit against a stand-in
-- `EnumerateFrames` and stand-in frames; these prove, inside the game client
-- with the installed MoltenCodes addon, what the stand-ins can only assume:
--
--   * the installed facade and its committed revision;
--   * the client's `EnumerateFrames` handing out a secure unit button this
--     file makes, its `unit` attribute read, and the scan ending within the
--     client's frames;
--   * `OnChange` reporting that button gone once it is hidden;
--   * Blizzard's `PlayerFrame` answering for `player`;
--   * in a party, `party1` answering a shown Blizzard party frame, compact or
--     not.
--
-- The button is a 60 by 20 secure unit button for `player`, made out of
-- combat and shown only while the suite runs. What a run leaves behind: that
-- hidden button. Nothing is saved.
--
-- Run with `/mct run unitFrameKit`, out of combat;
-- tests/client/MoltenCodesTest_UnitFrameKit/EXPECTED.md lists what the chat
-- frame should show.

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

local PACKAGE_ID = "unitFrameKit"

--- Every method docs/API.md of unitFrameKit lists on the facade.
local FACADE_METHODS = {
  "GetUnitFrame",
  "GetUnitFrames",
  "GetNamePlate",
  "Rescan",
  "IsScanning",
  "OnChange",
  "GetKindPatterns",
  "SetLimits",
  "GetLimits",
}

--- The test button's global name, and the pattern that names it alone.
local BUTTON_NAME = "MoltenCodesTestUnitFrameKitButton"
local BUTTON_PATTERN = "^" .. BUTTON_NAME .. "$"

--- How long a test waits for a scan to end.
local SCAN_WAIT_SECONDS = 10

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- CreateFrame, UIParent and the unit functions are World of Warcraft client
  -- globals, reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, 2)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- UnitFrameKit is not in the language-server workspace of tests/client, so its
-- facade is typed `any` here.
---@type any
local UnitFrameKit = Registry:Get(PACKAGE_ID, 1)
if type(UnitFrameKit) == "nil" then
  error(addonName .. " requires UnitFrameKit API 1 in the MoltenCodes addon; reinstall it", 0)
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

---Ask for a scan and wait until it has ended.
---@param ctx TestKit.Context
---@return boolean ended
local function scanned(ctx)
  UnitFrameKit:Rescan()
  return waitUntil(ctx, function()
    return not UnitFrameKit:IsScanning()
  end, SCAN_WAIT_SECONDS)
end

--- The test button, made once per session.
local button = nil

---The test button above the middle of the screen, shown, for `player`.
---@return table button
local function shownButton()
  if button == nil then
    local uiParent = readHost("UIParent")
    button = readHost("CreateFrame")("Button", BUTTON_NAME, uiParent, "SecureUnitButtonTemplate")
    button:SetSize(60, 20)
    button:SetPoint("CENTER", uiParent, "CENTER", 0, 200)
    button:SetAttribute("unit", "player")
  end
  button:Show()
  return button
end

---Whether `frames` holds `frame`.
---@param frames table[]
---@param frame table
---@return boolean
local function holds(frames, frame)
  for _, candidate in ipairs(frames) do
    if candidate == frame then
      return true
    end
  end
  return false
end

---Register a suite of this package whose tests end with the button hidden.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName)
  suite:After(function()
    if button and not readHost("InCombatLockdown")() then
      button:Hide()
    end
  end)
  return suite
end

-- unitFrameKit.facade ------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('unitFrameKit', 1) is the UnitFrameKit facade with API 1 and every documented method",
  function(ctx)
    ctx:Expect(rawget(UnitFrameKit, "API")):ToBe(1)
    for _, method in ipairs(FACADE_METHODS) do
      ctx:Expect(type(UnitFrameKit[method])):ToBe("function")
    end
  end
)

facade:Test(
  "the installed UnitFrameKit carries the revision of the committed manifest",
  function(ctx)
    local expectedPackages = Harness:GetExpectedPackages()
    if type(expectedPackages) == "nil" then
      ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
      return
    end
    for _, expected in ipairs(expectedPackages) do
      if expected.id == PACKAGE_ID then
        ctx:Expect(rawget(UnitFrameKit, "REVISION")):ToBe(expected.revision)
        return
      end
    end
    ctx:Fail("Expected.lua does not list unitFrameKit")
  end
)

-- unitFrameKit.scan --------------------------------------------------------

local scanSuite = newSuite("scan")

scanSuite:Test("a scan finds this suite's secure unit button for player", function(ctx)
  if readHost("InCombatLockdown")() then
    ctx:Fail("run this suite out of combat")
    return
  end
  local frame = shownButton()
  ctx:Expect(scanned(ctx)):ToBe(true)
  ctx:Expect(holds(UnitFrameKit:GetUnitFrames("player"), frame)):ToBe(true)
  ctx:Expect(UnitFrameKit:GetUnitFrame("player", { priorities = { BUTTON_PATTERN } })):ToBe(frame)
end)

scanSuite:Test("OnChange reports the button gone once it is hidden", function(ctx)
  if readHost("InCombatLockdown")() then
    ctx:Fail("run this suite out of combat")
    return
  end
  local frame = shownButton()
  ctx:Expect(scanned(ctx)):ToBe(true)
  local gone = false
  local connection = UnitFrameKit:OnChange(function(changed, unit, previousUnit)
    if changed == frame and unit == nil and previousUnit == "player" then
      gone = true
    end
  end)
  frame:Hide()
  ctx:Expect(scanned(ctx)):ToBe(true)
  connection:Disconnect()
  ctx:Expect(gone):ToBe(true)
end)

scanSuite:Test("Blizzard's PlayerFrame answers for player", function(ctx)
  ctx:Expect(scanned(ctx)):ToBe(true)
  local playerFrame = readHost("PlayerFrame")
  ctx:Expect(holds(UnitFrameKit:GetUnitFrames("player"), playerFrame)):ToBe(true)
end)

-- unitFrameKit.party -------------------------------------------------------

local partySuite = newSuite("party")

partySuite:Test("in a party, party1 answers a shown Blizzard party frame", function(ctx)
  if not readHost("UnitExists")("party1") then
    ctx:Fail("join a party to run this test")
    return
  end
  ctx:Expect(scanned(ctx)):ToBe(true)
  local frame = UnitFrameKit:GetUnitFrame("party1")
  ctx:Expect(type(frame)):ToBe("table")
  if type(frame) ~= "table" then
    return
  end
  ctx:Expect(frame:IsVisible()):ToBe(true)
  ctx:Expect(readHost("UnitIsUnit")(frame:GetAttribute("unit"), "party1")):ToBe(true)
  local name = frame:GetName() or (frame:GetParent():GetName() .. "." .. frame:GetParentKey())
  local blizzard = name:find("^CompactPartyFrameMember%d$") ~= nil
    or name:find("^CompactRaidFrame%d+$") ~= nil
    or name:find("^PartyFrame%.MemberFrame%d$") ~= nil
  ctx:Expect(blizzard):ToBe(true)
end)
