--- Package-specific test environment for the EditModeKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's module load order and the host surface
--- only EditModeKit reads:
---
---   the screen      `UIParent`, 1920 x 1080 at the origin, centre (960, 540);
---   Edit Mode       a stand-in `EventRegistry` with `RegisterCallback` and
---                   `TriggerEvent`, and an `EditModeManagerFrame` whose
---                   active layout `SwitchLayout` sets; `EnterEditMode`,
---                   `ExitEditMode` and `SwitchLayout` do what the client does;
---   combat          `InCombatLockdown`, answering what `SetCombat` set;
---   secret values   `InstallSecretProbe` and `NewSecret`;
---   upgrades        `LoadRevision`.
local FrameworkTestEnv = require("FrameworkTestEnv")

local EditModeKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "EditModeKit" },
})

local OWNED_GLOBALS = { "EventRegistry", "EditModeManagerFrame", "InCombatLockdown" }

local secrets = setmetatable({}, { __mode = "k" })
local combat, layout, active = false, "Modern", false
local sharedNewPackage = EditModeKitTestEnv.NewPackage
local sharedReset = EditModeKitTestEnv.Reset

---Read a host global.
---@param name string
---@return any
function EditModeKitTestEnv.GetGlobal(name)
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Write a host global.
---@param name string
---@param value any
function EditModeKitTestEnv.SetGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---A stand-in `EventRegistry`: callbacks by event and owner, called as
---`func(owner, ...)` like `CallbackRegistryMixin`.
---@return table
local function newEventRegistry()
  local callbacks = {}
  local registry = {}
  function registry.RegisterCallback(_, event, func, owner)
    callbacks[event] = callbacks[event] or {}
    callbacks[event][owner] = func
    return owner
  end
  function registry.TriggerEvent(_, event, ...)
    for owner, func in pairs(callbacks[event] or {}) do
      func(owner, ...)
    end
  end
  function registry.CallbackCount(_, event)
    local count = 0
    for _ in pairs(callbacks[event] or {}) do
      count = count + 1
    end
    return count
  end
  return registry
end

---Reset, install the host stubs and the Edit Mode stand-ins, load the chain.
---@return table EditModeKit
---@return table Registry
function EditModeKitTestEnv.NewPackage()
  local EditModeKit, Registry = sharedNewPackage()
  local uiParent = EditModeKitTestEnv.GetGlobal("CreateFrame")("Frame", "UIParent")
  uiParent:SetSize(1920, 1080)
  combat, layout, active = false, "Modern", false
  EditModeKitTestEnv.SetGlobal("EventRegistry", newEventRegistry())
  EditModeKitTestEnv.SetGlobal("EditModeManagerFrame", {
    GetActiveLayoutInfo = function()
      return { layoutName = layout }
    end,
    IsEditModeActive = function()
      return active
    end,
  })
  EditModeKitTestEnv.SetGlobal("InCombatLockdown", function()
    return combat
  end)
  return EditModeKit, Registry
end

---Open Edit Mode as the client does.
function EditModeKitTestEnv.EnterEditMode()
  active = true
  EditModeKitTestEnv.GetGlobal("EventRegistry"):TriggerEvent("EditMode.Enter")
end

---Close Edit Mode as the client does.
function EditModeKitTestEnv.ExitEditMode()
  active = false
  EditModeKitTestEnv.GetGlobal("EventRegistry"):TriggerEvent("EditMode.Exit")
end

---Make `name` the active layout, as the client does, with the layouts event.
---@param name string
function EditModeKitTestEnv.SwitchLayout(name)
  layout = name
  EditModeKitTestEnv.Emit("EDIT_MODE_LAYOUTS_UPDATED")
end

---Enter combat: `InCombatLockdown` answers `true`.
function EditModeKitTestEnv.SetCombat()
  combat = true
end

---Leave combat and emit `PLAYER_REGEN_ENABLED`.
function EditModeKitTestEnv.EndCombat()
  combat = false
  EditModeKitTestEnv.Emit("PLAYER_REGEN_ENABLED")
end

---A 100 x 50 frame on `UIParent` with its centre at (`x`, `y`).
---@param x number
---@param y number
---@return table frame
function EditModeKitTestEnv.FrameAt(x, y)
  local uiParent = EditModeKitTestEnv.GetGlobal("UIParent")
  local frame = EditModeKitTestEnv.GetGlobal("CreateFrame")("Frame", nil, uiParent)
  frame:SetSize(100, 50)
  frame:SetPoint("CENTER", uiParent, "BOTTOMLEFT", x, y)
  return frame
end

---Run one of `frame`'s scripts as the client would.
---@param frame table
---@param scriptName string
---@param ... any
function EditModeKitTestEnv.Run(frame, scriptName, ...)
  local script = frame:GetScript(scriptName)
  assert(type(script) == "function", "the frame has no " .. scriptName .. " script")
  script(frame, ...)
end

---The values the host error handler received since the last call.
---@return any[]
function EditModeKitTestEnv.TakeReportedValues()
  local values = {}
  for index, entry in ipairs(EditModeKitTestEnv.TakeReportedErrors()) do
    values[index] = entry.value
  end
  return values
end

---Install `issecretvalue`, reporting the tables `NewSecret` returns.
function EditModeKitTestEnv.InstallSecretProbe()
  EditModeKitTestEnv.SetGlobal("issecretvalue", function(value)
    return secrets[value] == true
  end)
end

---A value `issecretvalue` reports as secret once the probe is installed.
---@return table secret
function EditModeKitTestEnv.NewSecret()
  local secret = {}
  secrets[secret] = true
  return secret
end

---Clear everything the shared fixture clears, plus the stand-ins.
function EditModeKitTestEnv.Reset()
  sharedReset()
  for index = 1, #OWNED_GLOBALS do
    EditModeKitTestEnv.SetGlobal(OWNED_GLOBALS[index], nil)
  end
end

---Load the EditModeKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client.
---@param revision integer
---@return table EditModeKit
function EditModeKitTestEnv.LoadRevision(revision)
  -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
  -- `require` does.
  local path = nil
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", "EditModeKit")
    local file = io.open(candidate, "r")
    if file ~= nil then
      file:close()
      path = candidate
      break
    end
  end
  if path == nil then
    error("EditModeKitTestEnv.LoadRevision could not find EditModeKit.lua on package.path", 2)
  end

  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()

  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  if replacements ~= 1 then
    error("EditModeKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
  end

  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

return EditModeKitTestEnv
