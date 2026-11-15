-- MoltenCodes Test: BarKitSuite.lua
--
-- Real-client suites for the `barKit` package. The Busted specs under
-- packages/barKit/tests/ prove BarKit against the shared frame stub's
-- `StatusBar` and a scripted clock; these prove, inside the game client with
-- the installed MoltenCodes addon, what those can only assume:
--
--   * the installed facade and its committed revision;
--   * the client's `StatusBar` taking a secret value, made by `secretwrap`,
--     through `SetValue` and `SetMinMax` without an error;
--   * a timer bar run to its end on the client's own frame updates and
--     clock, `onFinished` called once and the bar released;
--   * a released bar's frame handed out again.
--
-- Each bar is shown for at most a second in the middle of the screen. What a
-- run leaves behind: BarKit's pooled frames (hidden, kept for reuse as the
-- client never frees a frame). Nothing is written to a saved variable.
--
-- Run with `/mct run barKit`; tests/client/MoltenCodesTest_BarKit/EXPECTED.md
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

local PACKAGE_ID = "barKit"

--- Every method docs/API.md of barKit lists on the facade.
local FACADE_METHODS = { "Acquire", "Release", "SetLimits", "GetLimits" }

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- UIParent and the secret-value functions are World of Warcraft client
  -- globals, reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, 2)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- BarKit is not in the language-server workspace of tests/client, so its
-- facade is typed `any` here.
---@type any
local BarKit = Registry:Get(PACKAGE_ID, 1)
if type(BarKit) == "nil" then
  error(addonName .. " requires BarKit API 1 in the MoltenCodes addon; reinstall it", 0)
end

local isSecretValue = readHost("issecretvalue")
local secretWrap = readHost("secretwrap")

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

local held = {}

---Register a suite of this package whose tests end with their bars released.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName)
  suite:After(function()
    for index = #held, 1, -1 do
      local bar = held[index]
      held[index] = nil
      if BarKit._state.records[bar] then
        BarKit:Release(bar)
      end
    end
  end)
  return suite
end

---A bar in the middle of the screen, released after the test.
---@return any
local function centredBar()
  local bar = BarKit:Acquire()
  bar:GetFrame():SetPoint("CENTER", readHost("UIParent"), "CENTER", 0, 150)
  held[#held + 1] = bar
  return bar
end

-- barKit.facade --------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('barKit', 1) is the BarKit facade with API 1 and every documented method",
  function(ctx)
    ctx:Expect(rawget(BarKit, "API")):ToBe(1)
    for _, method in ipairs(FACADE_METHODS) do
      ctx:Expect(type(BarKit[method])):ToBe("function")
    end
  end
)

facade:Test("the installed BarKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      ctx:Expect(rawget(BarKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list barKit")
end)

-- barKit.status --------------------------------------------------------------

local status = newSuite("status")

local SECRET_TEST =
  "the client's StatusBar takes a secret value and range through SetValue and SetMinMax"

if type(isSecretValue) ~= "function" or type(secretWrap) ~= "function" then
  status:Skip(
    SECRET_TEST,
    "the client has no issecretvalue and secretwrap; the secret path was not exercised"
  )
elseif not Harness:CanMakeSecrets() then
  status:Skip(SECRET_TEST, Harness.NO_SECRETS_REASON)
else
  status:Test(SECRET_TEST, function(ctx)
    local bar = centredBar()
    local value, maximum = secretWrap(60), secretWrap(100)
    local ok, failure = pcall(function()
      bar:SetMinMax(0, maximum)
      bar:SetValue(value)
    end)
    ctx:Log("result: " .. tostring(ok) .. " " .. tostring(failure))
    ctx:Expect(ok):ToBe(true)
  end)
end

status:Test("a status bar shows a plain value, label, icon and colour", function(ctx)
  local bar = centredBar()
  bar:SetMinMax(0, 200)
  bar:SetValue(150)
  bar:SetLabel("Health")
  bar:SetValueText("150 / 200")
  bar:SetIcon(136243)
  bar:SetColor(0.1, 0.8, 0.1)
  local frame = bar:GetFrame()
  ctx:Expect(frame:GetValue()):ToBe(150)
  ctx:Expect(frame.label:GetText()):ToBe("Health")
  ctx:Expect(frame.icon:IsShown()):ToBe(true)
end)

-- barKit.timer ---------------------------------------------------------------

local timer = newSuite("timer")

timer:Test(
  "a timer bar runs to its end on the client's frames, calls onFinished once and releases itself",
  function(ctx)
    local bar = centredBar()
    local calls = 0
    local frame = bar:GetFrame()
    bar:Start(0.5, {
      releaseOnFinish = true,
      onFinished = function()
        calls = calls + 1
      end,
    })
    ctx:Expect(bar:IsRunning()):ToBe(true)
    ctx
      :Expect(waitUntil(ctx, function()
        return calls > 0
      end, 3))
      :ToBe(true)
    ctx:Expect(calls):ToBe(1)
    ctx:Expect(frame:IsShown()):ToBe(false)
    ctx:Expect(frame.valueText:GetText()):ToBe(nil)
  end
)

timer:Test("a released bar's frame is handed out again", function(ctx)
  local first = centredBar()
  local frame = first:GetFrame()
  local created = BarKit._state.pool:GetCreatedCount()
  BarKit:Release(first)
  local second = centredBar()
  ctx:Expect(second:GetFrame()):ToBe(frame)
  ctx:Expect(BarKit._state.pool:GetCreatedCount()):ToBe(created)
end)
