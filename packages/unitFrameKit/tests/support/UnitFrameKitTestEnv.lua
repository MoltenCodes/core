--- Package-specific test environment for the UnitFrameKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- The Kit's own event frame comes from that fixture's `CreateFrame`, so
--- `Emit` delivers events to it and `Tick` runs its `OnUpdate`. What stays
--- here is this package's module load order and the host surface only
--- UnitFrameKit reads:
---
---   unit frames     `UnitButton` and `Widget`: stand-ins with attributes,
---                   visibility, names, parent keys and object types, in a
---                   creation-ordered list that `EnumerateFrames` walks and
---                   counts (`VisitCount`);
---   units           `SetUnits` names which token is which unit, for
---                   `UnitIsUnit` and `UnitExists`;
---   nameplates      `C_NamePlate.GetNamePlateForUnit` over `SetNamePlate`;
---   scanning        `RunScan`, ticks until a scan is done;
---   secret values   `InstallSecretProbe` and `NewSecret`;
---   upgrades        `LoadRevision`.
local FrameworkTestEnv = require("FrameworkTestEnv")

local UnitFrameKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "UnitFrameKit" },
})

local OWNED_GLOBALS = { "EnumerateFrames", "UnitIsUnit", "UnitExists", "C_NamePlate" }

local secrets = setmetatable({}, { __mode = "k" })
local frames, positions, identities, namePlates = {}, {}, {}, {}
local visits = 0
local sharedNewPackage = UnitFrameKitTestEnv.NewPackage
local sharedReset = UnitFrameKitTestEnv.Reset

---Read a host global.
---@param name string
---@return any
function UnitFrameKitTestEnv.GetGlobal(name)
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Write a host global.
---@param name string
---@param value any
function UnitFrameKitTestEnv.SetGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

local WidgetMethods = {}
local WIDGET_METATABLE = { __index = WidgetMethods }

function WidgetMethods:GetObjectType()
  return self.objectType
end

function WidgetMethods:IsForbidden()
  return self.forbidden
end

function WidgetMethods:GetAttribute(name)
  return self.attributes[name]
end

function WidgetMethods:SetAttribute(name, value)
  self.attributes[name] = value
end

function WidgetMethods:IsVisible()
  return self.visible
end

function WidgetMethods:GetName()
  return self.name
end

function WidgetMethods:GetParent()
  return self.parent
end

function WidgetMethods:GetParentKey()
  return self.parentKey
end

---A stand-in widget the client's `EnumerateFrames` would walk, appended to
---the creation order. Fields: `objectType`, `name`, `parent`, `parentKey`,
---`visible` (default `true`), `forbidden` (default `false`), `attributes`.
---@param fields table?
---@return table widget
function UnitFrameKitTestEnv.Widget(fields)
  local widget = setmetatable({
    objectType = "Frame",
    visible = true,
    forbidden = false,
    attributes = {},
  }, WIDGET_METATABLE)
  for key, value in pairs(fields or {}) do
    widget[key] = value
  end
  frames[#frames + 1] = widget
  positions[widget] = #frames
  return widget
end

---A shown `Button` called `name` with `unit` as its `unit` attribute.
---@param name string?
---@param unit string?
---@param fields table? more widget fields
---@return table button
function UnitFrameKitTestEnv.UnitButton(name, unit, fields)
  local button = UnitFrameKitTestEnv.Widget(fields)
  button.objectType = "Button"
  button.name = name
  button.attributes.unit = unit
  return button
end

---Name which token is which unit: `{ player = "Me", party1 = "Ann" }`.
---Tokens naming the same unit are the same to `UnitIsUnit`.
---@param map table<string, string>
function UnitFrameKitTestEnv.SetUnits(map)
  identities = map
end

---Make `plate` the nameplate `GetNamePlateForUnit(unit)` answers.
---@param unit string
---@param plate any
function UnitFrameKitTestEnv.SetNamePlate(unit, plate)
  namePlates[unit] = plate
end

---How many frames `EnumerateFrames` has handed out since the last call.
---@return integer
function UnitFrameKitTestEnv.VisitCount()
  local count = visits
  visits = 0
  return count
end

---Install the unit, frame and nameplate stand-ins.
local function installHost()
  UnitFrameKitTestEnv.SetGlobal("EnumerateFrames", function(current)
    local index = current == nil and 1 or positions[current] + 1
    local frame = frames[index]
    if frame ~= nil then
      visits = visits + 1
    end
    return frame
  end)
  UnitFrameKitTestEnv.SetGlobal("UnitIsUnit", function(first, second)
    local identity = identities[first]
    return identity ~= nil and identity == identities[second]
  end)
  UnitFrameKitTestEnv.SetGlobal("UnitExists", function(unit)
    return identities[unit] ~= nil
  end)
  UnitFrameKitTestEnv.SetGlobal("C_NamePlate", {
    GetNamePlateForUnit = function(unit)
      return namePlates[unit]
    end,
  })
end

---Reset, install the host stubs and the stand-ins, load the chain.
---@return table UnitFrameKit
---@return table Registry
function UnitFrameKitTestEnv.NewPackage()
  local UnitFrameKit, Registry = sharedNewPackage()
  frames, positions, namePlates, visits = {}, {}, {}, 0
  identities = { player = "Me", party1 = "Ann", party2 = "Bob", target = "Bob", focus = "Cid" }
  installHost()
  return UnitFrameKit, Registry
end

---Tick the client until no scan is due or running; at most `limit` ticks.
---@param UnitFrameKit table
---@param limit integer?
---@return integer ticks
function UnitFrameKitTestEnv.RunScan(UnitFrameKit, limit)
  local ticks = 0
  UnitFrameKit:Rescan()
  while UnitFrameKit:IsScanning() do
    ticks = ticks + 1
    if ticks > (limit or 100) then
      error("UnitFrameKitTestEnv.RunScan: the scan did not end", 2)
    end
    UnitFrameKitTestEnv.Tick(0.016)
  end
  return ticks
end

---The values the host error handler received since the last call.
---@return any[]
function UnitFrameKitTestEnv.TakeReportedValues()
  local values = {}
  for index, entry in ipairs(UnitFrameKitTestEnv.TakeReportedErrors()) do
    values[index] = entry.value
  end
  return values
end

---Install `issecretvalue`, reporting the tables `NewSecret` returns.
function UnitFrameKitTestEnv.InstallSecretProbe()
  UnitFrameKitTestEnv.SetGlobal("issecretvalue", function(value)
    return secrets[value] == true
  end)
end

---A value `issecretvalue` reports as secret once the probe is installed.
---@return table secret
function UnitFrameKitTestEnv.NewSecret()
  local secret = {}
  secrets[secret] = true
  return secret
end

---Clear everything the shared fixture clears, plus the stand-ins.
function UnitFrameKitTestEnv.Reset()
  sharedReset()
  for index = 1, #OWNED_GLOBALS do
    UnitFrameKitTestEnv.SetGlobal(OWNED_GLOBALS[index], nil)
  end
end

---Load the UnitFrameKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client.
---@param revision integer
---@return table UnitFrameKit
function UnitFrameKitTestEnv.LoadRevision(revision)
  -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
  -- `require` does.
  local path = nil
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", "UnitFrameKit")
    local file = io.open(candidate, "r")
    if file ~= nil then
      file:close()
      path = candidate
      break
    end
  end
  if path == nil then
    error("UnitFrameKitTestEnv.LoadRevision could not find UnitFrameKit.lua on package.path", 2)
  end

  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()

  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  if replacements ~= 1 then
    error("UnitFrameKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
  end

  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

return UnitFrameKitTestEnv
