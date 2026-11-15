-- MoltenCodes Test: RangeKitSuite.lua
--
-- Real-client suites for the `rangeKit` package. The Busted specs under
-- packages/rangeKit/tests/ prove RangeKit against a stand-in world of spells
-- and units; these prove, inside the game client with the installed
-- MoltenCodes addon, what the stand-ins can only assume:
--
--   * the installed facade and its committed revision;
--   * the client's spellbook, `C_Spell.GetSpellInfo` and
--     `CheckInteractDistance` giving the player's class real checkers;
--   * `GetRange("player")` answering from the client's interact distance;
--   * the client's range checks bracketing the player's target, and the
--     bracket moving when the player walks away from it;
--   * a talent change reaching RangeKit as a rebuild event.
--
-- The last two tests wait for the player: up to 30 seconds to target a unit
-- (a training dummy is ideal) and walk away from it, and up to 60 seconds to
-- change a talent. Nothing is shown on screen and nothing is saved.
--
-- Run with `/mct run rangeKit`;
-- tests/client/MoltenCodesTest_RangeKit/EXPECTED.md lists what the chat
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

local PACKAGE_ID = "rangeKit"

--- Every method docs/API.md of rangeKit lists on the facade.
local FACADE_METHODS =
  { "GetRange", "IsInRange", "DescribeCheckers", "OnCheckersChanged", "SetLimits", "GetLimits" }

--- How long the walking test waits for the player.
local WALK_WAIT_SECONDS = 30

--- How long the talent test waits for the player.
local TALENT_WAIT_SECONDS = 60

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, 2)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- RangeKit is not in the language-server workspace of tests/client, so its
-- facade is typed `any` here.
---@type any
local RangeKit = Registry:Get(PACKAGE_ID, 1)
if type(RangeKit) == "nil" then
  error(addonName .. " requires RangeKit API 1 in the MoltenCodes addon; reinstall it", 0)
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

---Whether any checker of `kind` is a spell checker.
---@param kind string
---@return boolean
local function hasSpellChecker(kind)
  for _, checker in ipairs(RangeKit:DescribeCheckers(kind)) do
    if checker.source:find("^spell:") then
      return true
    end
  end
  return false
end

-- rangeKit.facade ----------------------------------------------------------

local facade = Harness:Suite(PACKAGE_ID, "facade", addonName)

facade:Test(
  "Registry:Get('rangeKit', 1) is the RangeKit facade with API 1 and every documented method",
  function(ctx)
    ctx:Expect(rawget(RangeKit, "API")):ToBe(1)
    for _, method in ipairs(FACADE_METHODS) do
      ctx:Expect(type(RangeKit[method])):ToBe("function")
    end
  end
)

facade:Test("the installed RangeKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      ctx:Expect(rawget(RangeKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list rangeKit")
end)

-- rangeKit.checkers --------------------------------------------------------

local checkers = Harness:Suite(PACKAGE_ID, "checkers", addonName)

checkers:Test("the player's spellbook gives the harm list at least one spell checker", function(ctx)
  ctx:Expect(hasSpellChecker("harm")):ToBe(true)
end)

checkers:Test("every list holds the interact checkers at 7 and 28 yards", function(ctx)
  for _, kind in ipairs({ "harm", "friend", "resurrect", "pet", "interact" }) do
    local ranges = {}
    for _, checker in ipairs(RangeKit:DescribeCheckers(kind)) do
      if checker.source:find("^interact:") then
        ranges[#ranges + 1] = checker.range
      end
    end
    ctx:Expect(table.concat(ranges, ",")):ToBe("7,28")
  end
end)

checkers:Test("GetRange('player') answers 0 to 7 yards from the interact distance", function(ctx)
  local minRange, maxRange = RangeKit:GetRange("player")
  ctx:Expect(minRange):ToBe(0)
  ctx:Expect(maxRange):ToBe(7)
end)

-- rangeKit.player ----------------------------------------------------------

local player = Harness:Suite(PACKAGE_ID, "player", addonName)

player:Test("the bracket of the target grows as the player walks away from it", function(ctx)
  print(
    "MoltenCodes Test: target a unit next to you (a training dummy), then walk at least 30 yards away from it, within "
      .. WALK_WAIT_SECONDS
      .. " seconds."
  )
  local nearest = nil
  ctx
    :Expect(waitUntil(ctx, function()
      local minRange, maxRange = RangeKit:GetRange("target")
      if minRange == nil then
        return false
      end
      if nearest == nil and maxRange ~= nil and maxRange <= 7 then
        nearest = maxRange
      end
      return nearest ~= nil and minRange >= 28
    end, WALK_WAIT_SECONDS))
    :ToBe(true)
end)

player:Test("a talent change rebuilds the lists through the client's events", function(ctx)
  local calls = 0
  local connection = RangeKit:OnCheckersChanged(function()
    calls = calls + 1
  end)
  print(
    "MoltenCodes Test: change a talent that grants or removes a spell, within "
      .. TALENT_WAIT_SECONDS
      .. " seconds."
  )
  local heard = waitUntil(ctx, function()
    return calls > 0
  end, TALENT_WAIT_SECONDS)
  connection:Disconnect()
  ctx:Expect(heard):ToBe(true)
end)
