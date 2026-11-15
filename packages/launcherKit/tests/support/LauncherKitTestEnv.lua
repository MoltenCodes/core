--- Package-specific test environment for the LauncherKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`;
--- its `FrameStub` models buttons, textures, anchors and scripts. What stays
--- here is this package's module load order and the host surface only
--- LauncherKit reads, which the shared fixture does not model:
---
---   the screen          `UIParent`, 1920 x 1080 at the origin, and `Minimap`,
---                       a named 140 x 140 frame whose centre is at
---                       (`MINIMAP_X`, `MINIMAP_Y`);
---   `GameTooltip`       a tooltip that records its owner, lines and shown state;
---   the cursor          `GetCursorPosition`, answering what `SetCursor` set;
---   AddonCompartment    `InstallCompartment` puts a stand-in for Retail's
---                       `AddonCompartmentFrame` in place;
---   secret values       `InstallSecretProbe` and `NewSecret`;
---   upgrades            `LoadRevision`.
---
--- `Reset` removes every global this file installs.
local FrameworkTestEnv = require("FrameworkTestEnv")

local LauncherKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "SignalKit", "BrokerKit", "LauncherKit" },
})

--- Where the minimap's centre is, and its size.
LauncherKitTestEnv.MINIMAP_X = 1070
LauncherKitTestEnv.MINIMAP_Y = 570
LauncherKitTestEnv.MINIMAP_SIZE = 140

--- The host globals this environment installs and removes.
local OWNED_GLOBALS =
  { "GameTooltip", "GetCursorPosition", "GetMinimapShape", "AddonCompartmentFrame" }

--- Tables the `issecretvalue` stub reports as secret.
local secrets = setmetatable({}, { __mode = "k" })

local cursorX, cursorY = 0, 0

local sharedReset = LauncherKitTestEnv.Reset
local sharedNewPackage = LauncherKitTestEnv.NewPackage

---Read a host global.
---@param name string
---@return any
function LauncherKitTestEnv.GetGlobal(name)
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Write a host global.
---@param name string
---@param value any
function LauncherKitTestEnv.SetGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Put the cursor at screen coordinates `x`, `y` (unscaled, as the client
---reports them).
---@param x number
---@param y number
function LauncherKitTestEnv.SetCursor(x, y)
  cursorX, cursorY = x, y
end

---A tooltip that records what it was given.
---@return table tooltip
local function newTooltip()
  local tooltip = { lines = {}, shown = false, owner = nil }
  function tooltip.SetOwner(self, owner, anchor)
    self.owner, self.anchor, self.lines = owner, anchor, {}
  end
  function tooltip.GetOwner(self)
    return self.owner
  end
  function tooltip.AddLine(self, text)
    self.lines[#self.lines + 1] = text
  end
  function tooltip.Show(self)
    self.shown = true
  end
  function tooltip.Hide(self)
    self.shown = false
    self.owner = nil
  end
  return tooltip
end

---Install a stand-in for Retail's `AddonCompartmentFrame` and return it. Its
---`RegisterAddon` keeps every table it is given in `registered`, as
---Blizzard's does (Blizzard_Minimap, branch `live`, 2026-11-15).
---@return table frame
function LauncherKitTestEnv.InstallCompartment()
  local frame = { registered = {} }
  function frame.RegisterAddon(self, data)
    self.registered[#self.registered + 1] = data
  end
  LauncherKitTestEnv.SetGlobal("AddonCompartmentFrame", frame)
  return frame
end

---Reset, install the host stubs, load the module chain, and create the
---screen, the minimap, the tooltip and the cursor.
---@return table LauncherKit
---@return table BrokerKit
---@return table Registry
function LauncherKitTestEnv.NewPackage()
  local LauncherKit, Registry, _, BrokerKit = sharedNewPackage()
  local createFrame = LauncherKitTestEnv.GetGlobal("CreateFrame")
  local uiParent = createFrame("Frame", "UIParent")
  uiParent:SetSize(1920, 1080)
  local half = LauncherKitTestEnv.MINIMAP_SIZE / 2
  local minimap = createFrame("Frame", "Minimap", uiParent)
  minimap:SetSize(LauncherKitTestEnv.MINIMAP_SIZE, LauncherKitTestEnv.MINIMAP_SIZE)
  minimap:SetPoint(
    "BOTTOMLEFT",
    uiParent,
    "BOTTOMLEFT",
    LauncherKitTestEnv.MINIMAP_X - half,
    LauncherKitTestEnv.MINIMAP_Y - half
  )
  LauncherKitTestEnv.SetGlobal("GameTooltip", newTooltip())
  LauncherKitTestEnv.SetGlobal("GetCursorPosition", function()
    return cursorX, cursorY
  end)
  cursorX, cursorY = 0, 0
  return LauncherKit, BrokerKit, Registry
end

---The offset of `button`'s centre from the minimap's centre, as `SetPoint`
---put it.
---@param button table
---@return number x
---@return number y
function LauncherKitTestEnv.Offset(button)
  local point, relativeTo, relativePoint, x, y = button:GetPoint(1)
  assert(
    point == "CENTER" and relativePoint == "CENTER",
    "the button is not centred on the minimap"
  )
  assert(
    relativeTo == LauncherKitTestEnv.GetGlobal("Minimap"),
    "the button is not anchored to the minimap"
  )
  return x, y
end

---Run one of `button`'s scripts as the client would.
---@param button table
---@param scriptName string
---@param ... any
function LauncherKitTestEnv.Run(button, scriptName, ...)
  local script = button:GetScript(scriptName)
  assert(type(script) == "function", "the button has no " .. scriptName .. " script")
  script(button, ...)
end

---The values the host error handler received since the last call.
---@return any[]
function LauncherKitTestEnv.TakeReportedValues()
  local values = {}
  for index, entry in ipairs(LauncherKitTestEnv.TakeReportedErrors()) do
    values[index] = entry.value
  end
  return values
end

---Install `issecretvalue`, reporting the tables `NewSecret` returns.
function LauncherKitTestEnv.InstallSecretProbe()
  LauncherKitTestEnv.SetGlobal("issecretvalue", function(value)
    return secrets[value] == true
  end)
end

---A value `issecretvalue` reports as secret once the probe is installed.
---@return table secret
function LauncherKitTestEnv.NewSecret()
  local secret = {}
  secrets[secret] = true
  return secret
end

---Clear everything the shared fixture clears, plus this file's globals.
function LauncherKitTestEnv.Reset()
  sharedReset()
  for index = 1, #OWNED_GLOBALS do
    LauncherKitTestEnv.SetGlobal(OWNED_GLOBALS[index], nil)
  end
end

---Load the LauncherKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client.
---@param revision integer
---@return table LauncherKit
function LauncherKitTestEnv.LoadRevision(revision)
  -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
  -- `require` does.
  local path = nil
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", "LauncherKit")
    local file = io.open(candidate, "r")
    if file ~= nil then
      file:close()
      path = candidate
      break
    end
  end
  if path == nil then
    error("LauncherKitTestEnv.LoadRevision could not find LauncherKit.lua on package.path", 2)
  end

  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()

  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  if replacements ~= 1 then
    error("LauncherKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
  end

  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

return LauncherKitTestEnv
