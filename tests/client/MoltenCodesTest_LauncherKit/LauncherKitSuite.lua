-- MoltenCodes Test: LauncherKitSuite.lua
--
-- Real-client suites for the `launcherKit` package. The Busted specs under
-- packages/launcherKit/tests/ prove LauncherKit against stand-ins for the
-- minimap, the tooltip and the addon compartment; these prove, inside the
-- game client with the installed MoltenCodes addon, what those stand-ins can
-- only assume:
--
--   * the installed facade and its committed revision, and the client
--     facilities LauncherKit reads (logged per flavour);
--   * a button on the real `Minimap`, placed at a saved angle, shown and
--     hidden with `hide` written back, and moved by `Refresh`;
--   * its tooltip filled in the client's own `GameTooltip` by the object's
--     `OnTooltipShow`, and hidden again in the same step;
--   * the addon compartment: an entry on Retail, `"unavailable"` where the
--     client has none;
--   * a secret object name, made by the client's `secretwrap`, refused at
--     this file's line.
--
-- What a run leaves behind. The client never frees a frame and Blizzard
-- cannot remove a compartment entry, so the first run of a session creates
-- the BrokerKit object `MoltenCodesTest_LauncherKit`, its minimap button and
-- (on Retail) its compartment entry, all until `/reload`; later runs reuse
-- them. The button is hidden at the end of each test. Nothing is written to a
-- saved variable: the button's state lives in a table of this file.
--
-- Run with `/mct run launcherKit`; tests/client/MoltenCodesTest_LauncherKit/EXPECTED.md
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

local PACKAGE_ID = "launcherKit"
local OBJECT_NAME = "MoltenCodesTest_LauncherKit"
local TOOLTIP_LINE = "MoltenCodes Test: LauncherKit"

--- Every method docs/API.md of launcherKit lists on the facade.
local FACADE_METHODS = { "Register", "Get", "AddToCompartment", "SetLimits", "GetLimits" }

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- Minimap, GameTooltip, AddonCompartmentFrame, GetMinimapShape and the
  -- secret-value functions are World of Warcraft client globals, reachable
  -- only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, 2)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- The Kits below are not in the language-server workspace of tests/client,
-- so their facades are typed `any` here.
---@type any
local LauncherKit = Registry:Get(PACKAGE_ID, 1)
---@type any
local BrokerKit = Registry:Get("brokerKit", 1)
if type(LauncherKit) == "nil" or type(BrokerKit) == "nil" then
  error(
    addonName .. " requires LauncherKit and BrokerKit API 1 in the MoltenCodes addon; reinstall it",
    0
  )
end

local isSecretValue = readHost("issecretvalue")
local secretWrap = readHost("secretwrap")

--- The button's state, this file's own, never a saved variable.
local storage = { minimapPos = 0, hide = true }

---The test's launcher, created by the first run of the session.
---@return any launcher
local function testLauncher()
  if BrokerKit:Get(OBJECT_NAME) == nil then
    BrokerKit:New(OBJECT_NAME, {
      type = "launcher",
      icon = 134400,
      OnTooltipShow = function(tooltip)
        tooltip:AddLine(TOOLTIP_LINE)
      end,
    })
  end
  return LauncherKit:Get(OBJECT_NAME) or LauncherKit:Register(OBJECT_NAME, storage)
end

---Register a suite of this package whose tests end with the button hidden.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName)
  suite:After(function()
    local launcher = LauncherKit:Get(OBJECT_NAME)
    if launcher ~= nil then
      launcher:Hide()
    end
    local tooltip = readHost("GameTooltip")
    if
      type(tooltip) == "table"
      and launcher ~= nil
      and tooltip:GetOwner() == launcher:GetButton()
    then
      tooltip:Hide()
    end
  end)
  return suite
end

-- launcherKit.facade ---------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('launcherKit', 1) is the LauncherKit facade with API 1 and every documented method",
  function(ctx)
    ctx:Expect(rawget(LauncherKit, "API")):ToBe(1)
    for _, method in ipairs(FACADE_METHODS) do
      ctx:Expect(type(LauncherKit[method])):ToBe("function")
    end
  end
)

facade:Test(
  "the installed LauncherKit carries the revision of the committed manifest",
  function(ctx)
    local expectedPackages = Harness:GetExpectedPackages()
    if type(expectedPackages) == "nil" then
      ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
      return
    end
    for _, expected in ipairs(expectedPackages) do
      if expected.id == PACKAGE_ID then
        ctx:Expect(rawget(LauncherKit, "REVISION")):ToBe(expected.revision)
        return
      end
    end
    ctx:Fail("Expected.lua does not list launcherKit")
  end
)

facade:Test(
  "the client has Minimap, GameTooltip and GetCursorPosition; the optional facilities are logged",
  function(ctx)
    ctx:Expect(type(readHost("Minimap"))):ToBe("table")
    ctx:Expect(type(readHost("GameTooltip"))):ToBe("table")
    ctx:Expect(type(readHost("GetCursorPosition"))):ToBe("function")
    -- Another addon defines `GetMinimapShape`, so it is called protected, as
    -- LauncherKit calls it.
    local getShape = readHost("GetMinimapShape")
    local shape = "absent (round)"
    if type(getShape) == "function" then
      local answered, answer = pcall(getShape)
      shape = answered and tostring(answer) or ("raised: " .. tostring(answer))
    end
    ctx:Log("GetMinimapShape: " .. shape)
    ctx:Log("AddonCompartmentFrame: " .. type(readHost("AddonCompartmentFrame")))
  end
)

-- launcherKit.button ---------------------------------------------------------

local button = newSuite("button")

button:Test(
  "a button on the real minimap is placed at its saved angle, shown, hidden and moved",
  function(ctx)
    local launcher = testLauncher()
    local frame = launcher:GetButton()
    ctx:Expect(frame:GetParent()):ToBe(readHost("Minimap"))
    storage.minimapPos = 0
    launcher:Refresh()
    local point, relativeTo, _, x, y = frame:GetPoint(1)
    ctx:Expect(point):ToBe("CENTER")
    ctx:Expect(relativeTo):ToBe(readHost("Minimap"))
    ctx:Log(("angle 0 puts the button at %.1f, %.1f"):format(x, y))
    ctx:Expect(x > 0 and math.abs(y) < 1):ToBe(true)

    launcher:Show()
    ctx:Expect(launcher:IsShown()):ToBe(true)
    ctx:Expect(storage.hide):ToBe(false)
    storage.minimapPos = 90
    launcher:Refresh()
    local _, _, _, movedX, movedY = frame:GetPoint(1)
    ctx:Expect(math.abs(movedX) < 1 and movedY > 0):ToBe(true)
    launcher:Hide()
    ctx:Expect(launcher:IsShown()):ToBe(false)
    ctx:Expect(storage.hide):ToBe(true)
  end
)

button:Test(
  "hovering the button fills GameTooltip through the object's OnTooltipShow",
  function(ctx)
    local launcher = testLauncher()
    launcher:Show()
    local frame = launcher:GetButton()
    local tooltip = readHost("GameTooltip")
    frame:GetScript("OnEnter")(frame)
    ctx:Expect(tooltip:IsShown()):ToBe(true)
    ctx:Expect(tooltip:GetOwner()):ToBe(frame)
    ctx:Expect(tooltip:NumLines() >= 1):ToBe(true)
    frame:GetScript("OnLeave")(frame)
    ctx:Expect(tooltip:IsShown()):ToBe(false)
  end
)

-- launcherKit.compartment ----------------------------------------------------

local compartment = newSuite("compartment")

compartment:Test(
  "AddToCompartment adds an entry on Retail and answers unavailable without one",
  function(ctx)
    testLauncher()
    local added, reason = LauncherKit:AddToCompartment(OBJECT_NAME)
    ctx:Log("AddToCompartment: " .. tostring(added) .. ", " .. tostring(reason))
    local frame = readHost("AddonCompartmentFrame")
    if type(frame) == "table" and type(frame.RegisterAddon) == "function" then
      ctx:Expect(added == true or reason == "already"):ToBe(true)
      ctx:Expect(select(2, LauncherKit:AddToCompartment(OBJECT_NAME))):ToBe("already")
    else
      ctx:Expect(reason):ToBe("unavailable")
    end
  end
)

-- launcherKit.secrets --------------------------------------------------------

local secrets = newSuite("secrets")

local SECRET_TEST = "Register refuses a secret object name at this file's line"

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
    -- Not a tail call: `return LauncherKit:Register(...)` would drop this
    -- function's frame in Lua 5.1, and the error, raised at the caller's
    -- level, would then carry no file and line to look for below.
    local succeeded, message = pcall(function()
      local launcher = LauncherKit:Register(secret, {})
      return launcher
    end)
    ctx:Expect(succeeded):ToBe(false)
    ctx:Log("client message: " .. tostring(message))
    ctx
      :Expect(type(message) == "string" and message:find("LauncherKitSuite.lua:", 1, true) ~= nil)
      :ToBe(true)
    ctx
      :Expect(
        type(message) == "string"
          and message:find("LauncherKit:Register objectName must not be a secret value", 1, true)
            ~= nil
      )
      :ToBe(true)
  end)
end
