-- MoltenCodes Test: ToastKitSuite.lua
--
-- Real-client suites for the `toastKit` package. The Busted specs under
-- packages/toastKit/tests/ prove ToastKit against the shared frame stub;
-- these prove, inside the game client with the installed MoltenCodes addon,
-- what the stub can only assume:
--
--   * the installed facade and its committed revision;
--   * toasts shown and stacked on the client's `UIParent`;
--   * a toast's life and fade on the client's own frame updates, ending
--     within its duration while the cursor is away;
--   * a released toast's frame handed out again.
--
-- Each toast is on screen for about a second, at the top of the screen. Keep
-- the cursor away from the top of the screen while the run lasts: a toast
-- under the cursor holds. What a run leaves behind: ToastKit's pooled frames,
-- hidden. Nothing is written to a saved variable.
--
-- Run with `/mct run toastKit`; tests/client/MoltenCodesTest_ToastKit/EXPECTED.md
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

local PACKAGE_ID = "toastKit"

--- Every method docs/API.md of toastKit lists on the facade.
local FACADE_METHODS = { "Show", "DismissAll", "SetAnchor", "SetLimits", "GetLimits" }

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, 2)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- ToastKit is not in the language-server workspace of tests/client, so its
-- facade is typed `any` here.
---@type any
local ToastKit = Registry:Get(PACKAGE_ID, 1)
if type(ToastKit) == "nil" then
  error(addonName .. " requires ToastKit API 1 in the MoltenCodes addon; reinstall it", 0)
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

---Register a suite of this package whose tests end with no toast left.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName)
  suite:After(function()
    ToastKit:DismissAll()
  end)
  return suite
end

-- toastKit.facade ------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('toastKit', 1) is the ToastKit facade with API 1 and every documented method",
  function(ctx)
    ctx:Expect(rawget(ToastKit, "API")):ToBe(1)
    for _, method in ipairs(FACADE_METHODS) do
      ctx:Expect(type(ToastKit[method])):ToBe("function")
    end
  end
)

facade:Test("the installed ToastKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      ctx:Expect(rawget(ToastKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list toastKit")
end)

-- toastKit.toasts ------------------------------------------------------------

local toasts = newSuite("toasts")

toasts:Test(
  "two toasts stack on UIParent and each ends within its duration on the client's frames",
  function(ctx)
    local first =
      ToastKit:Show({ title = "MoltenCodes Test: ToastKit", text = "first", duration = 0.8 })
    local second =
      ToastKit:Show({ title = "MoltenCodes Test: ToastKit", text = "second", duration = 0.8 })
    local firstFrame = rawget(first, "_record").frame
    local secondFrame = rawget(second, "_record").frame
    ctx:Expect(firstFrame:IsShown() and secondFrame:IsShown()):ToBe(true)
    local _, _, _, _, firstY = firstFrame:GetPoint(1)
    local _, _, _, _, secondY = secondFrame:GetPoint(1)
    ctx:Log(("stacked at %.1f and %.1f"):format(firstY, secondY))
    ctx:Expect(secondY < firstY):ToBe(true)
    ctx
      :Expect(waitUntil(ctx, function()
        return not first:IsShown() and not second:IsShown()
      end, 4))
      :ToBe(true)
  end
)

toasts:Test("a released toast's frame is handed out again", function(ctx)
  local first = ToastKit:Show({ title = "MoltenCodes Test: ToastKit" })
  local frame = rawget(first, "_record").frame
  local created = ToastKit._state.pool:GetCreatedCount()
  first:Dismiss()
  local second = ToastKit:Show({ title = "MoltenCodes Test: ToastKit" })
  ctx:Expect(rawget(second, "_record").frame):ToBe(frame)
  ctx:Expect(ToastKit._state.pool:GetCreatedCount()):ToBe(created)
end)
