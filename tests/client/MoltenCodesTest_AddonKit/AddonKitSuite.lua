-- MoltenCodes Test: AddonKitSuite.lua
--
-- Real-client suites for the `addonKit` package. The Busted specs under
-- packages/addonKit/tests/ prove AddonKit on the fake client; these prove,
-- inside the game client with the installed MoltenCodes addon, what the fake
-- client can only assume:
--
--   * the installed facade and its committed revision, with both parts;
--   * `MoltenCodes:For` and a Kit read through it in the client;
--   * an error raised through the facade's `__index` naming this file's line,
--     not AddonKit's (verified on host Lua only so far);
--   * the database gate against the client's own ADDON_LOADED: this addon
--     opens its database at file scope (refused) and in OnInitialize
--     (accepted), over its real saved variable;
--   * the options panel registered in Blizzard's settings and opened by its
--     slash command;
--   * the minimap button placed from the profile and moved by a profile switch.
--
-- This file is itself a small AddonKit addon: its addon object, database,
-- panel and launcher are made when it loads, as an author's would be. What a
-- run leaves behind: the panel in the settings list, the minimap button, the
-- slash command /mctaddonkit, and the saved variable MoltenCodesTestAddonKitDB.
--
-- Run with `/mct run addonKit`;
-- tests/client/MoltenCodesTest_AddonKit/EXPECTED.md lists what the chat frame
-- should show.

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

local PACKAGE_ID = "addonKit"
local SAVED_VARIABLE = "MoltenCodesTestAddonKitDB"
local SLASH = "mctaddonkit"
local OTHER_PROFILE = "MoltenCodes Test Other"

--- Every method docs/API.md of addonKit lists on the package facade.
local FACADE_METHODS = { "For", "GetCatalogue", "SetLimits", "GetLimits" }

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- SlashCmdList, SettingsPanel and Minimap are World of Warcraft client
  -- globals, reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, 2)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- AddonKit is not in the language-server workspace of tests/client, so its
-- facade is typed `any` here.
---@type any
local AddonKit = Registry:Get(PACKAGE_ID, 1)
if type(AddonKit) == "nil" then
  error(addonName .. " requires AddonKit API 1 in the MoltenCodes addon; reinstall it", 0)
end

-- The addon ----------------------------------------------------------------

---@type any
local MC = AddonKit:For(addonName)
local addon = MC:NewAddon()

-- At file scope the client has not restored the saved variable yet, so this
-- open must be refused; the test below checks the message.
local earlyOpened, earlyMessage = pcall(function()
  MC:Database(SAVED_VARIABLE, { profile = { scale = 1 } })
end)

local defaults = {
  profile = { scale = MC.Range(0.5, 2, 1), minimap = MC.LAUNCHER_DEFAULTS },
  global = { opens = 0 },
}

function addon:OnInitialize()
  self.db = MC:Database(SAVED_VARIABLE, defaults)
  self.db.global.opens = self.db.global.opens + 1
  self.panel = MC:Options({
    type = "group",
    name = "MoltenCodes Test AddonKit",
    args = {
      scale = {
        type = "range",
        name = "Scale",
        min = 0.5,
        max = 2,
        step = 0.1,
        bind = "profile.scale",
      },
    },
  }, { db = self.db, slash = SLASH })
  self.launcher = MC:Launcher({ icon = 134400 }, self.db)
end

---Run `/mctaddonkit` through the handler CommandKit registered.
---@return boolean ran
local function runSlash()
  local list = readHost("SlashCmdList")
  for key, handler in pairs(list) do
    local index = 1
    local alias = readHost("SLASH_" .. key .. index)
    while alias ~= nil do
      if string.lower(alias) == "/" .. SLASH then
        handler("")
        return true
      end
      index = index + 1
      alias = readHost("SLASH_" .. key .. index)
    end
  end
  return false
end

---Register a suite of this package.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
  return Harness:Suite(PACKAGE_ID, part, addonName)
end

-- addonKit.facade ----------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('addonKit', 1) is the AddonKit facade with API 1, every documented method and both parts",
  function(ctx)
    ctx:Expect(rawget(AddonKit, "API")):ToBe(1)
    for _, method in ipairs(FACADE_METHODS) do
      ctx:Expect(type(AddonKit[method])):ToBe("function")
    end
    ctx:Expect(type(MC.Database)):ToBe("function")
    ctx:Expect(type(MC.Options)):ToBe("function")
  end
)

facade:Test("the installed AddonKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      ctx:Expect(rawget(AddonKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list addonKit")
end)

-- addonKit.entry -----------------------------------------------------------

local entry = newSuite("entry")

entry:Test(
  "MoltenCodes:For answers this addon's facade, and a Kit read through it is the shared one",
  function(ctx)
    ctx:Expect(namespace:For(addonName)):ToBe(MC)
    ctx:Expect(MC.LifecycleKit):ToBe(Registry:Get("lifecycleKit", 1))
  end
)

entry:Test("an error through the facade names this file's line, not AddonKit's", function(ctx)
  local ok, message = pcall(function()
    return MC.NoSuchKitAnywhere
  end)
  ctx:Expect(ok):ToBe(false)
  ctx:Expect(string.find(tostring(message), "AddonKitSuite.lua:%d+:") ~= nil):ToBe(true)
  ctx:Expect(string.find(tostring(message), "AddonKit.lua:", 1, true) == nil):ToBe(true)
end)

entry:Test(
  "MC:SetDefaultModuleState(false) leaves the addon object enabled, and a module MC:NewModule makes after login is announced to MC:OnModuleCreated and initialized but not enabled",
  function(ctx)
    local announced = {}
    local connection = MC:OnModuleCreated(function(module)
      announced[#announced + 1] = module:GetName()
    end)
    -- ModuleKit keeps a module for the session, so a later run in the same
    -- session takes the next free name.
    local container = MC.ModuleKit:ForAddon(addonName)
    local serial = 1
    while container:HasModule("ClientDefaultsProbe" .. serial) do
      serial = serial + 1
    end
    local previous = MC:SetDefaultModuleState(false)
    local module = MC:NewModule("ClientDefaultsProbe" .. serial, {})
    MC:SetDefaultModuleState(previous)
    connection:Disconnect()

    ctx:Expect(addon:IsEnabled()):ToBe(true)
    ctx:Expect(announced):ToEqual({ module:GetName() })
    ctx:Expect(module:GetState()):ToBe("initialized")
  end
)

-- addonKit.database --------------------------------------------------------

local database = newSuite("database")

database:Test("an open at file scope, before ADDON_LOADED, was refused with the fix", function(ctx)
  ctx:Expect(earlyOpened):ToBe(false)
  ctx
    :Expect(
      string.find(tostring(earlyMessage), "before ADDON_LOADED; open it in OnInitialize", 1, true)
        ~= nil
    )
    :ToBe(true)
end)

database:Test("the open in OnInitialize wraps the client's restored saved variable", function(ctx)
  local saved = readHost(SAVED_VARIABLE)
  ctx:Expect(type(saved)):ToBe("table")
  ctx:Expect(saved.global.opens):ToBe(addon.db.global.opens)
  ctx
    :Expect(function()
      addon.db.profile.scale = 5
    end)
    :ToRaise("expected")
end)

-- addonKit.composition -----------------------------------------------------

local composition = newSuite("composition")

composition:Test("the panel is in the settings list and /mctaddonkit opens it", function(ctx)
  if Harness:IsCombatRun() then
    Harness:SkipTest(ctx, "the settings panel is not opened during a combat run")
    return
  end
  ctx:Expect(runSlash()):ToBe(true)
  local panel = readHost("SettingsPanel")
  ctx:Expect(type(panel) == "table" and panel:IsShown()):ToBe(true)
  if type(panel) == "table" and type(panel.Hide) == "function" then
    panel:Hide()
  end
end)

composition:Test(
  "the minimap button follows the profile and moves on a profile switch",
  function(ctx)
    local db, launcher = addon.db, addon.launcher
    local button = launcher:GetButton()
    local previous = db:GetProfile()
    db.profile.minimap.minimapPos = 90
    launcher:Refresh()
    local _, _, _, firstX, firstY = button:GetPoint(1)
    db:SetProfile(OTHER_PROFILE)
    local _, _, _, secondX, secondY = button:GetPoint(1)
    db:SetProfile(previous)
    db:DeleteProfile(OTHER_PROFILE)
    ctx:Expect(button:GetParent()):ToBe(readHost("Minimap"))
    ctx:Expect(firstX ~= secondX or firstY ~= secondY):ToBe(true)
  end
)
