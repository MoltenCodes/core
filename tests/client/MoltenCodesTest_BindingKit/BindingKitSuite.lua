-- MoltenCodes Test: BindingKitSuite.lua
--
-- Real-client suites for the `bindingKit` package. The Busted specs under
-- packages/bindingKit/tests/ prove BindingKit against stand-ins for the
-- override binding functions; these prove, inside the game client with the
-- installed MoltenCodes addon, what the stand-ins can only assume:
--
--   * the installed facade and its committed revision, and the client's
--     override binding functions;
--   * a function key bound through the real `SetOverrideBindingClick`: the
--     client's `GetBindingAction` reports the click on BindingKit's button,
--     and clicking that button calls the function;
--   * the key cleared again, the client reporting no action for it.
--
-- The key is `CTRL-ALT-SHIFT-F12`, which no default binding uses; it is bound
-- for a moment and cleared by the After hook. What a run leaves behind: one
-- scope's owner frame and one hidden button. Nothing is saved: override
-- bindings are dropped at logout.
--
-- Run with `/mct run bindingKit`; tests/client/MoltenCodesTest_BindingKit/EXPECTED.md
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

local PACKAGE_ID = "bindingKit"
local TEST_KEY = "CTRL-ALT-SHIFT-F12"

--- Every method docs/API.md of bindingKit lists on the facade.
local FACADE_METHODS = { "CreateScope", "GetScope", "SetLimits", "GetLimits" }

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- The binding functions and the hidden button are World of Warcraft client
  -- globals, reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, 2)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- BindingKit is not in the language-server workspace of tests/client, so its
-- facade is typed `any` here.
---@type any
local BindingKit = Registry:Get(PACKAGE_ID, 1)
if type(BindingKit) == "nil" then
  error(addonName .. " requires BindingKit API 1 in the MoltenCodes addon; reinstall it", 0)
end

---The test's scope.
---@return any
local function testScope()
  return BindingKit:CreateScope("MoltenCodesTest_BindingKit")
end

---Register a suite of this package whose tests end with the test key cleared.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName)
  suite:After(function()
    local scope = BindingKit:GetScope("MoltenCodesTest_BindingKit")
    if scope then
      scope:ClearAll()
    end
  end)
  return suite
end

-- bindingKit.facade ----------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('bindingKit', 1) is the BindingKit facade with API 1 and every documented method",
  function(ctx)
    ctx:Expect(rawget(BindingKit, "API")):ToBe(1)
    for _, method in ipairs(FACADE_METHODS) do
      ctx:Expect(type(BindingKit[method])):ToBe("function")
    end
  end
)

facade:Test("the installed BindingKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      ctx:Expect(rawget(BindingKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list bindingKit")
end)

-- bindingKit.keys ------------------------------------------------------------

local keys = newSuite("keys")

keys:Test(
  "a function key is bound through SetOverrideBindingClick, runs its function and is cleared",
  function(ctx)
    local inCombat = readHost("InCombatLockdown")
    if type(inCombat) == "function" and inCombat() then
      Harness:SkipTest(ctx, "in combat; run it out of combat")
    end
    local getAction = readHost("GetBindingAction")
    local pressed = 0
    local scope = testScope()
    scope:BindFunction(TEST_KEY, function()
      pressed = pressed + 1
    end)
    ctx:Expect(scope:IsPending()):ToBe(false)
    local action = type(getAction) == "function" and getAction(TEST_KEY, true) or nil
    ctx:Log("GetBindingAction: " .. tostring(action))
    ctx
      :Expect(
        type(action) == "string" and action:find("MoltenCodesBindingKitButton", 1, true) ~= nil
      )
      :ToBe(true)
    local buttonName = action and action:match("CLICK ([^:]+)")
    local button = buttonName and readHost(buttonName)
    ctx:Expect(type(button)):ToBe("table")
    if type(button) == "table" then
      button:Click()
    end
    ctx:Expect(pressed):ToBe(1)
    scope:ClearAll()
    local cleared = type(getAction) == "function" and getAction(TEST_KEY, true) or ""
    ctx:Expect(cleared == "" or cleared == nil):ToBe(true)
  end
)
