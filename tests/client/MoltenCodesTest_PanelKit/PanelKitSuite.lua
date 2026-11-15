-- MoltenCodes Test: PanelKitSuite.lua
--
-- Real-client suites for the `panelKit` package. The Busted specs under
-- packages/panelKit/tests/ prove PanelKit against a stand-in for Blizzard's
-- `Settings`; these prove, inside the game client with the installed
-- MoltenCodes addon, what that stand-in can only assume:
--
--   * the installed facade and its committed revision, and that the client
--     has the four `Settings` functions PanelKit calls;
--   * a category and a subcategory registered with the real Settings API, each
--     opened by its category ID with `panel:Open()`;
--   * the page drawn by WidgetKit when Blizzard shows it, and every widget back
--     in its pool when the settings panel closes;
--   * what `panel:Open()` does in combat, which Blizzard does not document
--     (`C_SettingsUtil.OpenSettingsPanel` is flagged `HasRestrictions`):
--     measured only when the run starts in combat, and logged, not judged;
--   * a secret tree name, made by the client's `secretwrap`, refused at this
--     file's line.
--
-- The page tests open the settings panel on the test's page and close it
-- again with `HideUIPanel(SettingsPanel)`; run them out of combat, with no
-- other window open. They change no setting.
--
-- What a run leaves behind. Blizzard cannot remove a category, so the first
-- run of a session registers two pages for the rest of it, `MoltenCodes Test:
-- PanelKit` in the AddOns list and `Subpage` under it, and later runs reuse
-- them. Both count against PanelKit's shared `maxPanels`. The two OptionsKit
-- trees the pages draw are undefined by the After hook of their suite, so a
-- page shown after a run says that no options are defined. Nothing is written
-- to a saved variable.
--
-- Run with `/mct run panelKit`; tests/client/MoltenCodesTest_PanelKit/EXPECTED.md
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

local PACKAGE_ID = "panelKit"

--- Every method docs/API.md of panelKit lists on the facade and on a panel.
local FACADE_METHODS = { "Register", "Get", "SetLimits", "GetLimits" }
local PANEL_METHODS = { "Open", "GetName", "GetCategoryID", "GetRendering", "SetDefaultHandler" }

--- The `Settings` functions PanelKit calls (docs/API.md, "Host facilities").
local SETTINGS_FUNCTIONS = {
  "RegisterCanvasLayoutCategory",
  "RegisterCanvasLayoutSubcategory",
  "RegisterAddOnCategory",
  "OpenToCategory",
}

--- The two pages and the OptionsKit trees they draw.
local PAGE_NAME = "MoltenCodes Test: PanelKit"
local SUBPAGE_NAME = "Subpage"
local TREE_NAME = "MoltenCodesTest_PanelKit"
local SUBTREE_NAME = "MoltenCodesTest_PanelKit Subpage"

--- How long a page has to be drawn or released after the client was asked.
local WAIT_SECONDS = 2

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- Settings, SettingsPanel, HideUIPanel, InCombatLockdown and the
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
local PanelKit = Registry:Get(PACKAGE_ID, 1)
---@type any
local OptionsKit = Registry:Get("optionsKit", 1)
---@type any
local WidgetKit = Registry:Get("widgetKit", 1)
if type(PanelKit) == "nil" or type(OptionsKit) == "nil" or type(WidgetKit) == "nil" then
  error(
    addonName
      .. " requires PanelKit, OptionsKit and WidgetKit API 1 in the MoltenCodes addon; reinstall it",
    0
  )
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
---@return TestKit.Suite
local function newSuite(part)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName)
  suite:After(cleanUp)
  return suite
end

---`ctx:WaitUntil` through an untyped alias (see CommKitSuite.lua, `waitUntil`).
---@param ctx TestKit.Context
---@param predicate fun(): any
---@return boolean satisfied
local function waitUntil(ctx, predicate)
  ---@type any
  local context = ctx
  return context:WaitUntil(predicate, WAIT_SECONDS) == true
end

---Whether Blizzard's settings panel is on screen.
---@return boolean
local function settingsPanelShown()
  local panel = readHost("SettingsPanel")
  return type(panel) == "table" and panel:IsShown() == true
end

---Close Blizzard's settings panel when it is open.
local function closeSettingsPanel()
  local panel = readHost("SettingsPanel")
  local hide = readHost("HideUIPanel")
  if type(panel) == "table" and type(hide) == "function" and panel:IsShown() then
    hide(panel)
  end
end

---Skip the test unless the client can open and close its settings panel and
---the player is out of combat.
---@param ctx TestKit.Context
local function requireIdleSettingsPanel(ctx)
  local inCombat = readHost("InCombatLockdown")
  if type(inCombat) == "function" and inCombat() then
    Harness:SkipTest(ctx, "in combat; run it out of combat")
  end
  if type(readHost("SettingsPanel")) ~= "table" or type(readHost("HideUIPanel")) ~= "function" then
    Harness:SkipTest(ctx, "the client has no SettingsPanel or HideUIPanel to close the panel with")
  end
  if settingsPanelShown() then
    Harness:SkipTest(ctx, "the settings panel was already open; close it and run again")
  end
end

---Define a one-option tree under `treeName` for the current test.
---@param treeName string
local function defineTree(treeName)
  local value = true
  OptionsKit:Define(treeName, {
    type = "group",
    args = {
      enabled = {
        type = "toggle",
        name = "Enabled",
        get = function()
          return value
        end,
        set = function(_, newValue)
          value = newValue
        end,
      },
    },
  })
  atCleanUp(function()
    OptionsKit:Undefine(treeName)
  end)
end

---The test's two panels, registered by the first run of the session.
---@return any page
---@return any subpage
local function testPanels()
  local page = PanelKit:Get(PAGE_NAME) or PanelKit:Register(TREE_NAME, { name = PAGE_NAME })
  local subpage = PanelKit:Get(SUBPAGE_NAME, page)
    or PanelKit:Register(SUBTREE_NAME, { name = SUBPAGE_NAME, parent = page })
  return page, subpage
end

-- panelKit.facade ------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('panelKit', 1) is the PanelKit facade with API 1 and every documented method",
  function(ctx)
    ctx:Expect(rawget(PanelKit, "API")):ToBe(1)
    for _, method in ipairs(FACADE_METHODS) do
      ctx:Expect(type(PanelKit[method])):ToBe("function")
    end
    ctx:Log("maxPanels " .. tostring(PanelKit:GetLimits().maxPanels))
  end
)

facade:Test("the installed PanelKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      ctx:Expect(rawget(PanelKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list panelKit")
end)

facade:Test("the client's Settings table has the four functions PanelKit calls", function(ctx)
  local settings = readHost("Settings")
  ctx:Expect(type(settings)):ToBe("table")
  if type(settings) ~= "table" then
    return
  end
  for _, name in ipairs(SETTINGS_FUNCTIONS) do
    ctx:Expect(type(settings[name])):ToBe("function")
  end
end)

-- panelKit.pages -------------------------------------------------------------

local pages = newSuite("pages")
pages:After(closeSettingsPanel)

pages:Test(
  "a category opened with panel:Open() is drawn by WidgetKit, and every widget returns to its pool when the panel closes",
  function(ctx)
    requireIdleSettingsPanel(ctx)
    defineTree(TREE_NAME)
    local page = testPanels()
    for _, method in ipairs(PANEL_METHODS) do
      ctx:Expect(type(page[method])):ToBe("function")
    end
    ctx:Log("category ID " .. tostring(page:GetCategoryID()))
    local activeBefore = WidgetKit:GetStatistics().active

    ctx:Expect(page:Open()):ToBe(true)
    ctx
      :Expect(waitUntil(ctx, function()
        return page:GetRendering() ~= nil
      end))
      :ToBe(true)
    ctx:Expect(settingsPanelShown()):ToBe(true)
    local rendering = page:GetRendering()
    ctx:Expect(rendering ~= nil and rendering:GetWidget("enabled") ~= nil):ToBe(true)
    ctx:Log("widgets while shown " .. tostring(WidgetKit:GetStatistics().active - activeBefore))

    closeSettingsPanel()
    ctx
      :Expect(waitUntil(ctx, function()
        return page:GetRendering() == nil
      end))
      :ToBe(true)
    ctx:Expect(WidgetKit:GetStatistics().active):ToBe(activeBefore)
  end
)

pages:Test(
  "a subcategory opened by its own category ID draws its own tree, not its parent's",
  function(ctx)
    requireIdleSettingsPanel(ctx)
    defineTree(TREE_NAME)
    defineTree(SUBTREE_NAME)
    local page, subpage = testPanels()
    ctx:Expect(subpage:Open()):ToBe(true)
    ctx
      :Expect(waitUntil(ctx, function()
        return subpage:GetRendering() ~= nil
      end))
      :ToBe(true)
    ctx:Expect(page:GetRendering()):ToBeNil()
  end
)

local COMBAT_TEST = "what panel:Open() does in combat is logged"
local inCombatLockdown = readHost("InCombatLockdown")
if type(inCombatLockdown) ~= "function" then
  pages:Skip(COMBAT_TEST, "the client has no InCombatLockdown")
else
  pages:Test(COMBAT_TEST, function(ctx)
    if not inCombatLockdown() then
      Harness:SkipTest(
        ctx,
        "not in combat; start combat (a training dummy) and run /mct run panelKit again"
      )
    end
    local page = testPanels()
    local succeeded, opened, reason = pcall(page.Open, page)
    ctx:Log(
      "Open in combat: "
        .. tostring(succeeded)
        .. ", "
        .. tostring(opened)
        .. ", "
        .. tostring(reason)
    )
    ctx:Log("settings panel shown: " .. tostring(waitUntil(ctx, settingsPanelShown)))
  end)
end

-- panelKit.secrets -----------------------------------------------------------

local secrets = newSuite("secrets")

local SECRET_TEST = "Register refuses a secret tree name at this file's line"

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
    local succeeded, message = pcall(function()
      return PanelKit:Register(secret)
    end)
    ctx:Expect(succeeded):ToBe(false)
    ctx:Log("client message: " .. tostring(message))
    ctx
      :Expect(type(message) == "string" and message:find("PanelKitSuite.lua:", 1, true) ~= nil)
      :ToBe(true)
    ctx
      :Expect(
        type(message) == "string"
          and message:find("PanelKit:Register treeName must not be a secret value", 1, true)
            ~= nil
      )
      :ToBe(true)
  end)
end
