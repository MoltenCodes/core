--- Package-specific test environment for the PanelKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's module load order and the host surface
--- only PanelKit reads, which the shared fixture does not model:
---
---   the screen      `UIParent`, a named 1920 x 1080 frame at the origin;
---   `Settings`      a stand-in for Blizzard's settings panel (see
---                   `InstallSettings`): canvas categories and subcategories,
---                   the AddOns list, one page shown at a time, `OnRefresh`
---                   and `OnDefault` called on the shown canvas;
---   secret values   `InstallSecretProbe` installs `issecretvalue`, which
---                   reports the tables `NewSecret` returns;
---   upgrades        `LoadRevision` loads the source again as another revision.
---
--- `Reset` removes `Settings`, which is not among the globals the shared
--- fixture owns.
local FrameworkTestEnv = require("FrameworkTestEnv")

local PanelKitTestEnv = FrameworkTestEnv.New({
  modules = {
    "Registry",
    "SignalKit",
    "PoolKit",
    "SchemaKit",
    "OptionsKit",
    "WidgetKit",
    "PanelKit",
  },
})

--- The size Blizzard's panel gives a canvas in this stand-in.
PanelKitTestEnv.CANVAS_WIDTH = 600
PanelKitTestEnv.CANVAS_HEIGHT = 500

--- The host globals this environment installs and removes.
local OWNED_GLOBALS = { "Settings" }

--- Tables the `issecretvalue` stub reports as secret. Weak-keyed so a spec's
--- secrets never outlive it.
local secrets = setmetatable({}, { __mode = "k" })

local sharedReset = PanelKitTestEnv.Reset
local sharedNewPackage = PanelKitTestEnv.NewPackage

---Read a host global.
---@param name string
---@return any
function PanelKitTestEnv.GetGlobal(name)
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Write a host global.
---@param name string
---@param value any
function PanelKitTestEnv.SetGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Install a stand-in for Blizzard's `Settings` table and return it.
---
---The code is this suite's own; the behaviour follows Blizzard's
---`Blizzard_Settings_Shared` as read on 2026-11-15 (branches `live`,
---`classic` and `classic_era`):
---
---* `RegisterCanvasLayoutCategory(frame, name)` and
---  `RegisterCanvasLayoutSubcategory(parent, frame, name)` return a category
---  with `GetID()` and `GetName()`; `RegisterAddOnCategory(category)` puts a
---  top-level one in the AddOns list.
---* `OpenToCategory(id)` opens the panel on that category: the canvas shown
---  before is hidden, the new one is parented, sized and shown, which runs
---  its `OnShow`, and then given `OnRefresh`, as `DisplayLayout` does. An
---  unknown ID opens the panel on nothing.
---
---Extra fields for the specs: `categories` (every registration, in order),
---`addOns` (what `RegisterAddOnCategory` received), `opened` (every ID
---`OpenToCategory` received), `Close()` (hides the panel and the shown
---canvas), `Refresh()` and `Default()` (call `OnRefresh` / `OnDefault` on
---the shown canvas, as the panel does), `DefaultAll()` (`OnDefault` on every
---canvas, shown or not, as the panel's reset of all settings does through
---`CallDefaultOnCanvases`), `Shown()` (the shown category).
---@return table settings
function PanelKitTestEnv.InstallSettings()
  local settings = { categories = {}, addOns = {}, opened = {} }
  local byID = {}
  local shown = nil
  local nextID = 0

  local function newCategory(frame, name, parent)
    nextID = nextID + 1
    local category = { ID = nextID, frame = frame, name = name, parent = parent }
    function category.GetID(self)
      return self.ID
    end
    function category.GetName(self)
      return self.name
    end
    byID[category.ID] = category
    settings.categories[#settings.categories + 1] = category
    return category
  end

  function settings.RegisterCanvasLayoutCategory(frame, name)
    return newCategory(frame, name, nil), {}
  end

  function settings.RegisterCanvasLayoutSubcategory(parent, frame, name)
    if type(parent) ~= "table" or byID[parent.ID] ~= parent then
      error("Settings stand-in: parentCategory is not a category", 2)
    end
    return newCategory(frame, name, parent), {}
  end

  function settings.RegisterAddOnCategory(category)
    settings.addOns[#settings.addOns + 1] = category
  end

  function settings.Close()
    if shown ~= nil then
      shown.frame:Hide()
      shown = nil
    end
  end

  function settings.OpenToCategory(categoryID)
    settings.opened[#settings.opened + 1] = categoryID
    local category = byID[categoryID]
    if category == shown then
      return
    end
    settings.Close()
    if category == nil then
      return
    end
    local frame = category.frame
    frame:SetParent(PanelKitTestEnv.GetGlobal("UIParent"))
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", PanelKitTestEnv.GetGlobal("UIParent"), "TOPLEFT", 0, 0)
    frame:SetSize(PanelKitTestEnv.CANVAS_WIDTH, PanelKitTestEnv.CANVAS_HEIGHT)
    shown = category
    frame:Show()
    -- Blizzard's `SettingsPanelMixin:DisplayLayout` refreshes a canvas right
    -- after showing it.
    if frame.OnRefresh then
      frame:OnRefresh()
    end
  end

  function settings.Refresh()
    if shown ~= nil and shown.frame.OnRefresh then
      shown.frame:OnRefresh()
    end
  end

  function settings.Default()
    if shown ~= nil and shown.frame.OnDefault then
      shown.frame:OnDefault()
    end
  end

  function settings.DefaultAll()
    for index = 1, #settings.categories do
      local frame = settings.categories[index].frame
      if frame.OnDefault then
        frame:OnDefault()
      end
    end
  end

  function settings.Shown()
    return shown
  end

  PanelKitTestEnv.SetGlobal("Settings", settings)
  return settings
end

---Reset, install the host stubs, load the module chain, create the screen
---and install `Settings`.
---@return table PanelKit
---@return table settings the `Settings` stand-in
---@return table WidgetKit
---@return table OptionsKit
---@return table Registry
function PanelKitTestEnv.NewPackage()
  local PanelKit, Registry, _, _, _, OptionsKit, WidgetKit = sharedNewPackage()
  local uiParent = PanelKitTestEnv.GetGlobal("CreateFrame")("Frame", "UIParent")
  uiParent:SetSize(1920, 1080)
  local settings = PanelKitTestEnv.InstallSettings()
  return PanelKit, settings, WidgetKit, OptionsKit, Registry
end

---Install `issecretvalue`, reporting the tables `NewSecret` returns.
function PanelKitTestEnv.InstallSecretProbe()
  PanelKitTestEnv.SetGlobal("issecretvalue", function(value)
    return secrets[value] == true
  end)
end

---A value `issecretvalue` reports as secret once the probe is installed.
---@return table secret
function PanelKitTestEnv.NewSecret()
  local secret = {}
  secrets[secret] = true
  return secret
end

---Define a small OptionsKit tree under `addonName` over a plain table, and
---return the tree and the table.
---@param OptionsKit table
---@param addonName string
---@return table tree
---@return table values
function PanelKitTestEnv.DefineTree(OptionsKit, addonName)
  local values = { enabled = true, scale = 1 }
  local tree = OptionsKit:Define(addonName, {
    type = "group",
    args = {
      enabled = {
        type = "toggle",
        name = "Enabled",
        order = 1,
        get = function()
          return values.enabled
        end,
        set = function(_, value)
          values.enabled = value
        end,
      },
      scale = {
        type = "range",
        name = "Scale",
        order = 2,
        min = 0.5,
        max = 2,
        step = 0.1,
        get = function()
          return values.scale
        end,
        set = function(_, value)
          values.scale = value
        end,
      },
    },
  })
  return tree, values
end

---Clear everything the shared fixture clears, plus `Settings`.
function PanelKitTestEnv.Reset()
  sharedReset()
  for index = 1, #OWNED_GLOBALS do
    PanelKitTestEnv.SetGlobal(OWNED_GLOBALS[index], nil)
  end
end

---Load the PanelKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client.
---@param revision integer
---@return table PanelKit
function PanelKitTestEnv.LoadRevision(revision)
  -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
  -- `require` does.
  local path = nil
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", "PanelKit")
    local file = io.open(candidate, "r")
    if file ~= nil then
      file:close()
      path = candidate
      break
    end
  end
  if path == nil then
    error("PanelKitTestEnv.LoadRevision could not find PanelKit.lua on package.path", 2)
  end

  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()

  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  if replacements ~= 1 then
    error("PanelKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
  end

  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

return PanelKitTestEnv
