-- MoltenCodes Test: MenuKitSuite.lua
--
-- Real-client suites for the `menuKit` package. The Busted specs under
-- packages/menuKit/tests/ prove MenuKit against a stand-in for Blizzard_Menu;
-- these prove, inside the game client with the installed MoltenCodes addon,
-- what that stand-in can only assume:
--
--   * the installed facade and its committed revision, and that the client
--     has the Blizzard_Menu functions MenuKit calls;
--   * a context menu of every entry kind, a submenu, a disabled line and a
--     tooltip accepted by the real `MenuUtil`, opened, and closed again by
--     `MenuKit:CloseMenus()`;
--   * a `DropdownButton` given its menu by `SetupDropdown`, opened and closed
--     through Blizzard's own `OpenMenu` and `CloseMenu`, with the menu
--     function called for each opening and `isSelected` asked by Blizzard;
--   * an extension of Blizzard's `MENU_UNIT_SELF` menu reached when the
--     player right-clicks their own unit frame, and removed again;
--   * a secret text, made by the client's `secretwrap`, refused at this
--     file's line.
--
-- Nothing is clicked for you: the menus open and close within the test step,
-- and the extension test waits up to 20 seconds for the right click it asks
-- for in the chat frame, and is skipped when none comes.
--
-- What a run leaves behind. The client never frees a frame, so the first run
-- of a session creates one hidden `Frame` (the context menu's owner) and one
-- hidden `DropdownButton`, which later runs reuse. Every extension is removed
-- by the After hook of its suite, and every menu is closed. Nothing is written
-- to a saved variable.
--
-- Run with `/mct run menuKit`; tests/client/MoltenCodesTest_MenuKit/EXPECTED.md
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

local PACKAGE_ID = "menuKit"

--- Every method docs/API.md of menuKit lists on the facade.
local FACADE_METHODS =
  { "OpenContextMenu", "SetupDropdown", "ExtendMenu", "CloseMenus", "SetLimits", "GetLimits" }

--- How long the extension test waits for the player's right click.
local RIGHT_CLICK_SECONDS = 20

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- MenuUtil, Menu, CreateFrame, UIParent, DEFAULT_CHAT_FRAME and the
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

-- MenuKit is not in the language-server workspace of tests/client, so its
-- facade is typed `any` here.
---@type any
local MenuKit = Registry:Get(PACKAGE_ID, 1)
if type(MenuKit) == "nil" then
  error(addonName .. " requires MenuKit API 1 in the MoltenCodes addon; reinstall it", 0)
end

local isSecretValue = readHost("issecretvalue")
local secretWrap = readHost("secretwrap")

-- Helpers ---------------------------------------------------------------------

local pendingReleases = {}

---Release everything the test created, last first; raise the first problem.
local function cleanUp()
  local firstProblem = nil
  for index = #pendingReleases, 1, -1 do
    local action = pendingReleases[index]
    pendingReleases[index] = nil
    local succeeded, problem = pcall(action)
    if not succeeded and type(firstProblem) == "nil" then
      firstProblem = problem
    end
  end
  if type(firstProblem) ~= "nil" then
    error(firstProblem, 0)
  end
end

---Run `action` in the After hook of the current test.
---@param action fun()
local function atCleanUp(action)
  pendingReleases[#pendingReleases + 1] = action
end

---Register a suite of this package whose tests all end released.
---@param part string
---@param options MoltenCodesTest.SuiteOptions|nil
---@return TestKit.Suite
local function newSuite(part, options)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName, options)
  suite:After(cleanUp)
  return suite
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

---The menu Blizzard's menu manager shows now, or `nil`.
---@return any
local function openMenu()
  return readHost("Menu").GetManager():GetOpenMenu()
end

--- The frames this addon creates, once per session.
local contextOwner = nil
local dropdownButton = nil

---Skip the test unless the player is out of combat.
---@param ctx TestKit.Context
local function requireOutOfCombat(ctx)
  local inCombat = readHost("InCombatLockdown")
  if type(inCombat) == "function" and inCombat() then
    Harness:SkipTest(ctx, "in combat; run it out of combat")
  end
end

-- menuKit.facade -------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('menuKit', 1) is the MenuKit facade with API 1 and every documented method",
  function(ctx)
    ctx:Expect(rawget(MenuKit, "API")):ToBe(1)
    for _, method in ipairs(FACADE_METHODS) do
      ctx:Expect(type(MenuKit[method])):ToBe("function")
    end
  end
)

facade:Test("the installed MenuKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      ctx:Expect(rawget(MenuKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list menuKit")
end)

facade:Test("the client has the Blizzard_Menu functions MenuKit calls", function(ctx)
  local menuUtil, menu = readHost("MenuUtil"), readHost("Menu")
  ctx:Expect(type(menuUtil) == "table" and type(menuUtil.CreateContextMenu)):ToBe("function")
  ctx:Expect(type(menu) == "table" and type(menu.ModifyMenu)):ToBe("function")
  ctx:Expect(type(menu) == "table" and type(menu.GetManager)):ToBe("function")
end)

-- menuKit.menus --------------------------------------------------------------

local menus = newSuite("menus")
menus:After(function()
  MenuKit:CloseMenus()
end)

menus:Test(
  "a context menu of every entry kind opens through MenuUtil and MenuKit:CloseMenus() closes it",
  function(ctx)
    requireOutOfCombat(ctx)
    if contextOwner == nil then
      contextOwner = readHost("CreateFrame")("Frame", nil, readHost("UIParent"))
      contextOwner:SetSize(1, 1)
      contextOwner:SetPoint("CENTER")
    end
    contextOwner:Show()
    atCleanUp(function()
      contextOwner:Hide()
    end)
    local selected = false
    local opened = 0
    local menu = MenuKit:OpenContextMenu(contextOwner, function(owner)
      opened = opened + 1
      ctx:Expect(owner):ToBe(contextOwner)
      return {
        { kind = "title", text = "MoltenCodes Test: MenuKit" },
        { kind = "button", text = "A button", onClick = function() end, tooltip = "A tooltip" },
        { kind = "button", text = "A disabled button", disabled = true },
        {
          kind = "checkbox",
          text = "A checkbox",
          isSelected = function()
            return selected
          end,
          setSelected = function()
            selected = not selected
          end,
        },
        {
          kind = "radio",
          text = "A radio",
          isSelected = function()
            return true
          end,
          setSelected = function() end,
        },
        { kind = "divider" },
        { kind = "spacer" },
        { kind = "button", text = "A submenu", entries = { { kind = "button", text = "Inside" } } },
      }
    end)
    ctx:Expect(opened):ToBe(1)
    ctx:Expect(menu ~= nil):ToBe(true)
    ctx:Expect(openMenu() ~= nil):ToBe(true)
    MenuKit:CloseMenus()
    ctx
      :Expect(waitUntil(ctx, function()
        return openMenu() == nil
      end, 2))
      :ToBe(true)
  end
)

menus:Test(
  "a DropdownButton set up by SetupDropdown opens and closes through Blizzard, calling the menu at each opening",
  function(ctx)
    requireOutOfCombat(ctx)
    if dropdownButton == nil then
      dropdownButton = readHost("CreateFrame")("DropdownButton", nil, readHost("UIParent"))
      dropdownButton:SetSize(120, 24)
      dropdownButton:SetPoint("CENTER")
    end
    dropdownButton:Show()
    atCleanUp(function()
      dropdownButton:CloseMenu()
      dropdownButton:Hide()
    end)
    local generated, asked = 0, 0
    MenuKit:SetupDropdown(dropdownButton, function()
      generated = generated + 1
      return {
        {
          kind = "radio",
          text = "Only choice",
          isSelected = function()
            asked = asked + 1
            return true
          end,
          setSelected = function() end,
        },
      }
    end)
    local generatedBefore = generated
    dropdownButton:OpenMenu()
    ctx:Expect(dropdownButton:IsMenuOpen()):ToBe(true)
    ctx:Expect(generated > generatedBefore):ToBe(true)
    dropdownButton:CloseMenu()
    ctx:Expect(dropdownButton:IsMenuOpen()):ToBe(false)
    ctx:Log("menu generated " .. generated .. " times, isSelected asked " .. asked .. " times")
    ctx:Expect(asked > 0):ToBe(true)
  end
)

-- menuKit.extensions ---------------------------------------------------------

local extensions = newSuite("extensions", { timeoutSeconds = RIGHT_CLICK_SECONDS + 10 })

extensions:Test(
  "an extension of MENU_UNIT_SELF is reached when you right-click your own unit frame, and removed",
  function(ctx)
    requireOutOfCombat(ctx)
    local reached = nil
    local extension = MenuKit:ExtendMenu("MENU_UNIT_SELF", function(_, contextData)
      reached = contextData
      return { { kind = "divider" }, { kind = "title", text = "MoltenCodes Test: MenuKit" } }
    end)
    -- `Menu.ModifyMenu` calls a new callback at once with the last
    -- `MENU_UNIT_SELF` menu Blizzard generated this session (Blizzard_Menu,
    -- Menu.lua, `generatedDescriptions`), so a right click made before the
    -- run would count as this one. Only a call after this line does.
    ctx:Log("filled at once from an earlier menu: " .. tostring(reached ~= nil))
    reached = nil
    atCleanUp(function()
      extension:Remove()
      MenuKit:CloseMenus()
    end)
    readHost("DEFAULT_CHAT_FRAME"):AddMessage(
      "MoltenCodes Test: right-click your own player frame within "
        .. RIGHT_CLICK_SECONDS
        .. ' seconds; the menu should end with "MoltenCodes Test: MenuKit".'
    )
    if not waitUntil(ctx, function()
      return reached ~= nil
    end, RIGHT_CLICK_SECONDS) then
      Harness:SkipTest(
        ctx,
        "no right click on your own unit frame came within " .. RIGHT_CLICK_SECONDS .. " seconds"
      )
    end
    ctx:Log("contextData.unit " .. tostring(type(reached) == "table" and reached.unit or nil))
    ctx:Expect(extension:Remove()):ToBe(true)
    ctx:Expect(extension:IsActive()):ToBe(false)
  end
)

-- menuKit.secrets ------------------------------------------------------------

local secrets = newSuite("secrets")

local SECRET_TEST = "OpenContextMenu refuses a secret entry text at this file's line"

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
    -- A statement, not `return MenuKit:OpenContextMenu(...)`: a tail call
    -- would take this function's frame off the stack, and the error would
    -- carry no file and line to look for.
    local succeeded, message = pcall(function()
      local menu = MenuKit:OpenContextMenu(nil, { { kind = "title", text = secret } })
      return menu
    end)
    ctx:Expect(succeeded):ToBe(false)
    ctx:Log("client message: " .. tostring(message))
    ctx
      :Expect(type(message) == "string" and message:find("MenuKitSuite.lua:", 1, true) ~= nil)
      :ToBe(true)
    ctx
      :Expect(
        type(message) == "string"
          and message:find(
              "MenuKit:OpenContextMenu menu[1].text must not be a secret value",
              1,
              true
            )
            ~= nil
      )
      :ToBe(true)
  end)
end
