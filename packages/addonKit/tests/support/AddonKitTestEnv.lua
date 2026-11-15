--- Package-specific test environment for the AddonKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's module chain and the host surface only
--- AddonKit's specs need:
---
---   the Kits         `LoadKits(chain)` requires the Kits a spec uses after
---                    AddonKit's core, in dependency order; `CHAINS` names the
---                    usual sets; `LoadParts()` loads both parts;
---   the addon        `LogIn(addonName)` marks the addon loaded, sends its
---                    `ADDON_LOADED`, then logs in;
---   the client       `InstallSettings()` (a stand-in for Blizzard's
---                    `Settings`), `InstallMinimap()` (`UIParent`, `Minimap`,
---                    `GetCursorPosition`), `InstallSlashCommands()`
---                    (`SlashCmdList`) and `RunSlash(name)`;
---   secret values    `InstallSecretProbe` and `NewSecret`;
---   upgrades         `LoadRevision(n)` and `LoadPartRevision(part, n)`.
---
--- Part files are loaded with `require("AddonKit-Database")`: the test runner
--- puts every package's `src/parts/` on the path.
local FrameworkTestEnv = require("FrameworkTestEnv")

local CORE_SOURCE = "packages/addonKit/src/AddonKit.lua"
local PART_SOURCES = {
  Database = "packages/addonKit/src/parts/AddonKit-Database.lua",
  Composition = "packages/addonKit/src/parts/AddonKit-Composition.lua",
}

local AddonKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "AddonKit" },
  wowProfile = "mainline",
})

--- The Kit module chains specs load after the core, dependency first.
AddonKitTestEnv.CHAINS = {
  modules = { "SignalKit", "EventKit", "LifecycleKit", "ModuleKit" },
  database = { "SignalKit", "EventKit", "LifecycleKit", "SchemaKit", "SettingsKit" },
  composition = {
    "SignalKit",
    "EventKit",
    "LifecycleKit",
    "SchemaKit",
    "SettingsKit",
    "PoolKit",
    "OptionsKit",
    "WidgetKit",
    "PanelKit",
    "CommandKit",
    "BrokerKit",
    "LauncherKit",
  },
}

local OWNED_GLOBALS = {
  "Settings",
  "Minimap",
  "SlashCmdList",
  "GetCursorPosition",
  "issecretvalue",
  "hooksecurefunc",
  "ToggleGameMenu",
  "GetLocale",
  "C_ChatInfo",
  "Enum",
  "GetFramerate",
  "MyAddonDB",
  "FirstAddonDB",
}
local OWNED_MODULES = {
  "AddonKit-Database",
  "AddonKit-Composition",
  "SignalKit",
  "EventKit",
  "LifecycleKit",
  "ModuleKit",
  "SchemaKit",
  "SettingsKit",
  "PoolKit",
  "OptionsKit",
  "WidgetKit",
  "PanelKit",
  "CommandKit",
  "BrokerKit",
  "LauncherKit",
}

local secrets = setmetatable({}, { __mode = "k" })
local sharedReset = AddonKitTestEnv.Reset

---Read a host global.
---@param name string
---@return any
function AddonKitTestEnv.GetGlobal(name)
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Write a host global.
---@param name string
---@param value any
function AddonKitTestEnv.SetGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Clear the modules and globals this environment owns, then the shared ones.
function AddonKitTestEnv.Reset()
  for index = 1, #OWNED_MODULES do
    package.loaded[OWNED_MODULES[index]] = nil
  end
  for index = 1, #OWNED_GLOBALS do
    AddonKitTestEnv.SetGlobal(OWNED_GLOBALS[index], nil)
  end
  -- CommandKit's `SLASH_<key><n>` globals.
  local slashNames = {}
  -- selene: allow(global_usage)
  for name in pairs(_G) do
    if type(name) == "string" and string.find(name, "^SLASH_MOLTENCODES") then
      slashNames[#slashNames + 1] = name
    end
  end
  for index = 1, #slashNames do
    AddonKitTestEnv.SetGlobal(slashNames[index], nil)
  end
  sharedReset()
end

---Require each module of `chain` that is not loaded yet, in order.
---@param chain string[]
function AddonKitTestEnv.LoadKits(chain)
  for index = 1, #chain do
    require(chain[index])
  end
end

---Load both parts after the core.
---@return table AddonKit
function AddonKitTestEnv.LoadParts()
  require("AddonKit-Database")
  return require("AddonKit-Composition")
end

---Reset and load the core, the parts and every Kit the helpers use.
---@return table AddonKit
---@return table Registry
function AddonKitTestEnv.NewFullPackage()
  local AddonKit, Registry = AddonKitTestEnv.NewPackage()
  AddonKitTestEnv.LoadKits(AddonKitTestEnv.CHAINS.modules)
  AddonKitTestEnv.LoadKits(AddonKitTestEnv.CHAINS.composition)
  AddonKitTestEnv.LoadParts()
  return AddonKit, Registry
end

---Mark `addonName` loaded, send its `ADDON_LOADED`, then log in.
---@param addonName string
function AddonKitTestEnv.LogIn(addonName)
  AddonKitTestEnv.LoadAddon(addonName)
  AddonKitTestEnv.Login()
end

---The shared namespace table.
---@return table
function AddonKitTestEnv.Namespace()
  return AddonKitTestEnv.GetGlobal(AddonKitTestEnv.NAMESPACE_KEY)
end

---Install a stand-in for Blizzard's `Settings` table and return it. It
---records categories, the AddOns list and every `OpenToCategory` call, which
---is what PanelKit's `Register` and `panel:Open` use.
---@return table settings
function AddonKitTestEnv.InstallSettings()
  local settings = { categories = {}, addOns = {}, opened = {} }
  local nextID = 0
  local function newCategory(frame, name, parent)
    nextID = nextID + 1
    local category = { ID = nextID, frame = frame, name = name, parent = parent }
    function category.GetID(self)
      return self.ID
    end
    settings.categories[#settings.categories + 1] = category
    return category
  end
  function settings.RegisterCanvasLayoutCategory(frame, name)
    return newCategory(frame, name, nil), {}
  end
  function settings.RegisterCanvasLayoutSubcategory(parent, frame, name)
    return newCategory(frame, name, parent), {}
  end
  function settings.RegisterAddOnCategory(category)
    settings.addOns[#settings.addOns + 1] = category
  end
  function settings.OpenToCategory(categoryID)
    settings.opened[#settings.opened + 1] = categoryID
  end
  AddonKitTestEnv.SetGlobal("Settings", settings)
  return settings
end

---Install `UIParent`, a round `Minimap` at its centre and a cursor at the origin.
function AddonKitTestEnv.InstallMinimap()
  local createFrame = AddonKitTestEnv.GetGlobal("CreateFrame")
  local uiParent = createFrame("Frame", "UIParent")
  uiParent:SetSize(1920, 1080)
  local minimap = createFrame("Frame", "Minimap", uiParent)
  minimap:SetSize(140, 140)
  minimap:SetPoint("CENTER", uiParent, "CENTER", 0, 0)
  AddonKitTestEnv.SetGlobal("GetCursorPosition", function()
    return 0, 0
  end)
end

---Install an empty `SlashCmdList`, the table CommandKit writes its handlers to.
function AddonKitTestEnv.InstallSlashCommands()
  AddonKitTestEnv.SetGlobal("SlashCmdList", {})
end

---Run the slash command `/name` as the client would; `false` when none is set.
---@param name string with the leading slash
---@param text string?
---@return boolean
function AddonKitTestEnv.RunSlash(name, text)
  for key, handler in pairs(AddonKitTestEnv.GetGlobal("SlashCmdList")) do
    local index = 1
    local alias = AddonKitTestEnv.GetGlobal("SLASH_" .. key .. index)
    while alias ~= nil do
      if string.lower(alias) == string.lower(name) then
        handler(text or "")
        return true
      end
      index = index + 1
      alias = AddonKitTestEnv.GetGlobal("SLASH_" .. key .. index)
    end
  end
  return false
end

---Install `issecretvalue`, answering `true` for the values `NewSecret` returns.
function AddonKitTestEnv.InstallSecretProbe()
  AddonKitTestEnv.SetGlobal("issecretvalue", function(value)
    return secrets[value] == true
  end)
end

---A table the probe reports as secret.
---@return table
function AddonKitTestEnv.NewSecret()
  local secret = {}
  secrets[secret] = true
  return secret
end

---Read a source file.
---@param path string
---@return string
local function readSource(path)
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return text
end

---Load the core source again as revision `revision`, the way a newer copy
---embedded by another addon loads.
---@param revision integer
---@return table AddonKit
function AddonKitTestEnv.LoadRevision(revision)
  local source = readSource(CORE_SOURCE)
  local patched, count = string.gsub(
    source,
    "local IMPLEMENTATION_REVISION = %d+",
    "local IMPLEMENTATION_REVISION = " .. revision
  )
  assert(count == 1, "the core declares IMPLEMENTATION_REVISION once")
  local chunk = assert(loadstring(patched, "@" .. CORE_SOURCE))
  return chunk()
end

---Load a part's source again as revision `revision`.
---@param part string `"Database"` or `"Composition"`
---@param revision integer
---@return table AddonKit
function AddonKitTestEnv.LoadPartRevision(part, revision)
  local path = PART_SOURCES[part]
  local patched, count =
    string.gsub(readSource(path), "local PART_REVISION = %d+", "local PART_REVISION = " .. revision)
  assert(count == 1, "a part declares PART_REVISION once")
  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

---Run `callback` and return the message it raised; fail when it did not raise.
---@param callback fun()
---@return string
function AddonKitTestEnv.ErrorOf(callback)
  local ok, message = pcall(callback)
  assert(not ok, "expected an error")
  return tostring(message)
end

---Assert that `callback` raises a message containing `expected` at the
---first line of its own body: the line that calls the public surface. The
---line is found from the function itself, so a formatter that splits the
---closure over several lines changes nothing.
---@param expected string
---@param callback fun()
---@return string message
function AddonKitTestEnv.ExpectRaisedInside(expected, callback)
  local info = debug.getinfo(callback, "S")
  local where = string.match(info.short_src, "[^/]+$") .. ":" .. (info.linedefined + 1) .. ":"
  local message = AddonKitTestEnv.ErrorOf(callback)
  assert(string.find(message, expected, 1, true), message)
  local position = string.match(message, "^([^\n]-:%d+:) ")
  assert(
    position ~= nil and string.sub(position, -#where) == where,
    "expected the error at " .. where .. ": " .. message
  )
  return message
end

---Read a whole file.
---@param path string
---@return string
local function readFile(path)
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return text
end

---Reset and install the client surface an addon folder run touches: the
---shared stubs, `UIParent` and `Minimap`, `SlashCmdList`, `Settings`,
---`hooksecurefunc`, `ToggleGameMenu`, `GetLocale` (`enUS`), `C_ChatInfo` with
---its result enums, and `GetFramerate`.
---@return table sent every addon message sent, as `{ prefix, text, distribution }`
---@return table settings the `Settings` stand-in
function AddonKitTestEnv.InstallClient()
  AddonKitTestEnv.Reset()
  AddonKitTestEnv.InstallWowApi()
  AddonKitTestEnv.InstallMinimap()
  AddonKitTestEnv.InstallSlashCommands()
  local settings = AddonKitTestEnv.InstallSettings()
  AddonKitTestEnv.SetGlobal("hooksecurefunc", function(name, hook)
    local original = AddonKitTestEnv.GetGlobal(name)
    AddonKitTestEnv.SetGlobal(name, function(...)
      original(...)
      hook(...)
    end)
  end)
  AddonKitTestEnv.SetGlobal("ToggleGameMenu", function() end)
  AddonKitTestEnv.SetGlobal("GetLocale", function()
    return "enUS"
  end)
  local sent = {}
  AddonKitTestEnv.SetGlobal("C_ChatInfo", {
    RegisterAddonMessagePrefix = function()
      return 0
    end,
    IsAddonMessagePrefixRegistered = function()
      return false
    end,
    SendAddonMessage = function(prefix, text, distribution)
      sent[#sent + 1] = { prefix, text, distribution }
      return 0
    end,
  })
  AddonKitTestEnv.SetGlobal("Enum", {
    SendAddonMessageResult = { Success = 0 },
    RegisterAddonMessagePrefixResult = {
      Success = 0,
      DuplicatePrefix = 1,
      InvalidPrefix = 2,
      MaxPrefixes = 3,
    },
  })
  AddonKitTestEnv.SetGlobal("GetFramerate", function()
    return 60
  end)
  return sent, settings
end

---Load an addon folder as the client would: every file its `embeds.xml`
---lists, from package source (`Libs\MoltenCodes\<id>\<file>` is
---`packages/<id>/src/<file>`), then its own `.lua` files in `.toc` order with
---`...` set to the addon's name and private table.
---@param directory string the folder, from the repository root
---@param addonName string the folder's addon name (its `.toc` is `<addonName>.toc`)
function AddonKitTestEnv.LoadAddonFolder(directory, addonName)
  for reference in string.gmatch(readFile(directory .. "/embeds.xml"), '<Script%s+file="([^"]+)"') do
    local path = string.match(string.gsub(reference, "\\", "/"), "MoltenCodes/(.+)$")
    local packageId, rest = string.match(path, "^([^/]+)/(.+%.lua)$")
    assert(loadfile("packages/" .. packageId .. "/src/" .. rest))()
  end
  local private = {}
  for line in string.gmatch(readFile(directory .. "/" .. addonName .. ".toc"), "[^\r\n]+") do
    local entry = string.match(line, "^%s*([^#%s][^\r\n]-)%s*$")
    if entry ~= nil and string.find(entry, "%.lua$") then
      assert(loadfile(directory .. "/" .. string.gsub(entry, "\\", "/")))(addonName, private)
    end
  end
end

AddonKitTestEnv.ReadFile = readFile

return AddonKitTestEnv
