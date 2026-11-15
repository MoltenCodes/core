-- MoltenCodes Test: GlowKitSuite.lua
--
-- Real-client suites for the `glowKit` package. The Busted specs under
-- packages/glowKit/tests/ prove GlowKit against the shared frame stub; these
-- prove, inside the game client with the installed MoltenCodes addon, what
-- the stub can only assume:
--
--   * the installed facade and its committed revision;
--   * a pixel glow on a frame on screen, its lines moved by the client's own
--     frame updates;
--   * a pulse glow breathing on the client's frames;
--   * both stopped, and their overlay handed out again.
--
-- The glowing frame is a 64 by 64 square in the middle of the screen, shown
-- for about a second. What a run leaves behind: that hidden frame and
-- GlowKit's pooled overlays. Nothing is written to a saved variable.
--
-- Run with `/mct run glowKit`; tests/client/MoltenCodesTest_GlowKit/EXPECTED.md
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

local PACKAGE_ID = "glowKit"

--- Every method docs/API.md of glowKit lists on the facade.
local FACADE_METHODS = { "Start", "Stop", "StopAll", "IsGlowing", "SetLimits", "GetLimits" }

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- CreateFrame and UIParent are World of Warcraft client globals, reachable
  -- only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, 2)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- GlowKit is not in the language-server workspace of tests/client, so its
-- facade is typed `any` here.
---@type any
local GlowKit = Registry:Get(PACKAGE_ID, 1)
if type(GlowKit) == "nil" then
  error(addonName .. " requires GlowKit API 1 in the MoltenCodes addon; reinstall it", 0)
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

--- The glowing square, made once per session.
local square = nil

---The square in the middle of the screen, shown.
---@return table
local function target()
  if square == nil then
    square = readHost("CreateFrame")("Frame", nil, readHost("UIParent"))
    square:SetSize(64, 64)
    square:SetPoint("CENTER", readHost("UIParent"), "CENTER", 0, 120)
    local fill = square:CreateTexture(nil, "BACKGROUND")
    fill:SetAllPoints(square)
    fill:SetColorTexture(0.1, 0.1, 0.1, 0.8)
  end
  square:Show()
  return square
end

---Register a suite of this package whose tests end with no glow left.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName)
  suite:After(function()
    if square then
      GlowKit:StopAll(square)
      square:Hide()
    end
  end)
  return suite
end

-- glowKit.facade -------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('glowKit', 1) is the GlowKit facade with API 1 and every documented method",
  function(ctx)
    ctx:Expect(rawget(GlowKit, "API")):ToBe(1)
    for _, method in ipairs(FACADE_METHODS) do
      ctx:Expect(type(GlowKit[method])):ToBe("function")
    end
  end
)

facade:Test("the installed GlowKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      ctx:Expect(rawget(GlowKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list glowKit")
end)

-- glowKit.glows --------------------------------------------------------------

local glows = newSuite("glows")

glows:Test("a pixel glow's lines move on the client's frame updates", function(ctx)
  local glow = GlowKit:Start(target(), { lines = 4, frequency = 1 })
  local line = rawget(glow, "_record").overlay.lines[1]
  local _, _, _, startX, startY = line:GetPoint(1)
  ctx
    :Expect(waitUntil(ctx, function()
      local _, _, _, x, y = line:GetPoint(1)
      return x ~= startX or y ~= startY
    end, 2))
    :ToBe(true)
end)

glows:Test("a pulse glow breathes on the client's frame updates", function(ctx)
  local glow = GlowKit:Start(target(), { kind = "pulse", frequency = 2 })
  local overlay = rawget(glow, "_record").overlay
  local first = overlay:GetAlpha()
  ctx
    :Expect(waitUntil(ctx, function()
      return math.abs(overlay:GetAlpha() - first) > 0.05
    end, 2))
    :ToBe(true)
end)

glows:Test("stopped glows give their overlay back and the next glow reuses it", function(ctx)
  local glow = GlowKit:Start(target())
  local overlay = rawget(glow, "_record").overlay
  local created = GlowKit._state.pool:GetCreatedCount()
  ctx:Expect(GlowKit:Stop(target())):ToBe(true)
  ctx:Expect(overlay:IsShown()):ToBe(false)
  local again = GlowKit:Start(target())
  ctx:Expect(rawget(again, "_record").overlay):ToBe(overlay)
  ctx:Expect(GlowKit._state.pool:GetCreatedCount()):ToBe(created)
end)
