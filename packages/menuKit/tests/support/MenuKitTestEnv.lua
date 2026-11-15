--- Package-specific test environment for the MenuKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's module load order and the host surface
--- only MenuKit reads, which the shared fixture does not model:
---
---   `MenuUtil`, `Menu`  a stand-in for Blizzard_Menu (see `InstallMenu`):
---                       descriptions that record what was added, context
---                       menus, dropdown buttons, tagged menus and their
---                       `ModifyMenu` handles, and clicks;
---   secret values       `InstallSecretProbe` installs `issecretvalue`, which
---                       reports the tables `NewSecret` returns;
---   upgrades            `LoadRevision` loads the source again as another
---                       revision.
---
--- `Reset` removes `MenuUtil` and `Menu`, which are not among the globals the
--- shared fixture owns.
local FrameworkTestEnv = require("FrameworkTestEnv")

local MenuKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "MenuKit" },
})

--- The host globals this environment installs and removes.
local OWNED_GLOBALS = { "MenuUtil", "Menu" }

--- Tables the `issecretvalue` stub reports as secret. Weak-keyed so a spec's
--- secrets never outlive it.
local secrets = setmetatable({}, { __mode = "k" })

local sharedReset = MenuKitTestEnv.Reset
local sharedNewPackage = MenuKitTestEnv.NewPackage

---Read a host global.
---@param name string
---@return any
function MenuKitTestEnv.GetGlobal(name)
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Write a host global.
---@param name string
---@param value any
function MenuKitTestEnv.SetGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---A description that records what is added to it, as Blizzard's element
---and root descriptions are filled: `kind`, `text`, `responder`, `data`,
---`isSelected`, `enabled` (a boolean or a function), `tooltip` (the function
---`SetTooltip` received) and `children`.
---@param kind string
---@param text string?
---@return table description
local function newDescription(kind, text)
  local description = { kind = kind, text = text, children = {} }

  local function add(child)
    description.children[#description.children + 1] = child
    return child
  end

  function description.CreateButton(_, buttonText, responder, data)
    local child = newDescription("button", buttonText)
    child.responder = responder
    child.data = data
    return add(child)
  end

  function description.CreateCheckbox(_, boxText, isSelected, setSelected, data)
    local child = newDescription("checkbox", boxText)
    child.isSelected = isSelected
    child.responder = setSelected
    child.data = data
    return add(child)
  end

  function description.CreateRadio(_, radioText, isSelected, setSelected, data)
    local child = newDescription("radio", radioText)
    child.isSelected = isSelected
    child.responder = setSelected
    child.data = data
    return add(child)
  end

  function description.CreateTitle(_, titleText)
    return add(newDescription("title", titleText))
  end

  function description.CreateDivider()
    return add(newDescription("divider"))
  end

  function description.CreateSpacer()
    return add(newDescription("spacer"))
  end

  function description.SetEnabled(self, enabled)
    self.enabled = enabled
  end

  ---As Blizzard's `IsEnabled`: `true` when never set, the boolean, or the
  ---function called with the description.
  function description.IsEnabled(self)
    if self.enabled == nil then
      return true
    end
    if type(self.enabled) == "boolean" then
      return self.enabled
    end
    return self.enabled(self)
  end

  function description.SetTooltip(self, initializer)
    self.tooltip = initializer
  end

  ---Click the line as Blizzard's `Pick` does: the responder with the data,
  ---an input table and the menu.
  function description.Click(self)
    return self.responder(self.data, { context = 1, buttonName = "LeftButton" }, {})
  end

  ---What the tooltip initializer writes into a tooltip.
  function description.TooltipText(self)
    local written = nil
    self.tooltip({
      SetText = function(_, value)
        written = value
      end,
    }, self)
    return written
  end

  ---The kinds and texts of the children, `"kind:text"` each.
  function description.Outline(self)
    local outline = {}
    for index, child in ipairs(self.children) do
      outline[index] = child.text and (child.kind .. ":" .. child.text) or child.kind
    end
    return outline
  end

  return description
end

---Install a stand-in for Blizzard_Menu and return it.
---
---The code is this suite's own; the behaviour follows Blizzard's
---`Blizzard_Menu` as read on 2026-11-15 (branch `live`):
---
---* `MenuUtil.CreateContextMenu(owner, generator)` fills a root description
---  with `generator(owner, root)` and returns a menu table;
---* `Menu.ModifyMenu(tag, callback)` registers `callback(owner, root,
---  contextData)` for menus tagged `tag` and returns a handle whose
---  `Unregister` removes it; when a menu with that tag was filled before, it
---  first calls `callback` at once with the last one, as Blizzard does with
---  its `generatedDescriptions`;
---* `Menu.GetManager():CloseMenus()` closes every menu.
---
---Extra fields for the specs: `contextMenus` (every root description a
---context menu was filled into, with its `owner`), `NewDropdown()` (a
---dropdown button with `SetupMenu` and `Open()`), `OpenTagged(tag, owner,
---contextData)` (fills a tagged menu as Blizzard does, its own entries first,
---then every extension in registration order), `CallbackCount(tag)` and
---`closed` (how many times `CloseMenus` ran).
---@return table menuApi
function MenuKitTestEnv.InstallMenu()
  local api = { contextMenus = {}, closed = 0 }
  local callbacks = {}
  -- The last menu filled per tag, with its owner and context data.
  local generated = {}

  local menuUtil = {}
  function menuUtil.CreateContextMenu(owner, generator)
    local root = newDescription("root")
    root.owner = owner
    generator(owner, root)
    api.contextMenus[#api.contextMenus + 1] = root
    return { root = root }
  end

  local menu = {}
  function menu.ModifyMenu(tag, callback)
    if type(tag) ~= "string" then
      error("Menu stand-in: tag must be a string", 2)
    end
    local last = generated[tag]
    if last ~= nil then
      callback(last.owner, last.root, last.contextData)
    end
    callbacks[tag] = callbacks[tag] or {}
    local entry = { callback = callback }
    table.insert(callbacks[tag], entry)
    return {
      Unregister = function()
        for index, registered in ipairs(callbacks[tag]) do
          if registered == entry then
            table.remove(callbacks[tag], index)
            return
          end
        end
      end,
    }
  end

  function menu.GetManager()
    return {
      CloseMenus = function()
        api.closed = api.closed + 1
      end,
    }
  end

  function api.OpenTagged(tag, owner, contextData)
    local root = newDescription("root")
    root:CreateButton("Blizzard's own line")
    generated[tag] = { owner = owner, root = root, contextData = contextData }
    for _, entry in ipairs(callbacks[tag] or {}) do
      entry.callback(owner, root, contextData)
    end
    return root
  end

  function api.CallbackCount(tag)
    return #(callbacks[tag] or {})
  end

  function api.NewDropdown()
    local dropdown = {}
    function dropdown.SetupMenu(self, generator)
      if type(generator) ~= "function" then
        error("DropdownButton stand-in: generator must be a function", 2)
      end
      self.generator = generator
    end
    function dropdown.Open(self)
      local root = newDescription("root")
      self.generator(self, root)
      return root
    end
    return dropdown
  end

  api.MenuUtil = menuUtil
  api.Menu = menu
  MenuKitTestEnv.SetGlobal("MenuUtil", menuUtil)
  MenuKitTestEnv.SetGlobal("Menu", menu)
  return api
end

---Reset, install the host stubs, load the module chain and install the menu
---stand-in.
---@return table MenuKit
---@return table menuApi the stand-in from `InstallMenu`
---@return table Registry
function MenuKitTestEnv.NewPackage()
  local MenuKit, Registry = sharedNewPackage()
  return MenuKit, MenuKitTestEnv.InstallMenu(), Registry
end

---The values the host error handler received since the last call.
---@return any[]
function MenuKitTestEnv.TakeReportedValues()
  local values = {}
  for index, entry in ipairs(MenuKitTestEnv.TakeReportedErrors()) do
    values[index] = entry.value
  end
  return values
end

---Install `issecretvalue`, reporting the tables `NewSecret` returns.
function MenuKitTestEnv.InstallSecretProbe()
  MenuKitTestEnv.SetGlobal("issecretvalue", function(value)
    return secrets[value] == true
  end)
end

---A value `issecretvalue` reports as secret once the probe is installed.
---@return table secret
function MenuKitTestEnv.NewSecret()
  local secret = {}
  secrets[secret] = true
  return secret
end

---Clear everything the shared fixture clears, plus the menu stand-in.
function MenuKitTestEnv.Reset()
  sharedReset()
  for index = 1, #OWNED_GLOBALS do
    MenuKitTestEnv.SetGlobal(OWNED_GLOBALS[index], nil)
  end
end

---Load the MenuKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client.
---@param revision integer
---@return table MenuKit
function MenuKitTestEnv.LoadRevision(revision)
  -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
  -- `require` does.
  local path = nil
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", "MenuKit")
    local file = io.open(candidate, "r")
    if file ~= nil then
      file:close()
      path = candidate
      break
    end
  end
  if path == nil then
    error("MenuKitTestEnv.LoadRevision could not find MenuKit.lua on package.path", 2)
  end

  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()

  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  if replacements ~= 1 then
    error("MenuKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
  end

  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

return MenuKitTestEnv
