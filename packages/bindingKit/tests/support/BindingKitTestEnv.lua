--- Package-specific test environment for the BindingKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's module load order and the host surface
--- only BindingKit reads:
---
---   bindings       stand-ins for `SetOverrideBinding`,
---                  `SetOverrideBindingClick` and `ClearOverrideBindings` that
---                  keep each owner's bindings, read with `Bindings(owner)`;
---   combat         `InCombatLockdown`, answering what `SetCombat` set, and
---                  `EndCombat`, which clears it and emits
---                  `PLAYER_REGEN_ENABLED`;
---   secret values  `InstallSecretProbe` and `NewSecret`;
---   upgrades       `LoadRevision`.
local FrameworkTestEnv = require("FrameworkTestEnv")

local BindingKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "BindingKit" },
})

--- The host globals this environment installs and removes.
local OWNED_GLOBALS =
  { "InCombatLockdown", "SetOverrideBinding", "SetOverrideBindingClick", "ClearOverrideBindings" }

local secrets = setmetatable({}, { __mode = "k" })
local combat, bindings = false, {}
local sharedNewPackage = BindingKitTestEnv.NewPackage
local sharedReset = BindingKitTestEnv.Reset

---Read a host global.
---@param name string
---@return any
function BindingKitTestEnv.GetGlobal(name)
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Write a host global.
---@param name string
---@param value any
function BindingKitTestEnv.SetGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Install the binding and combat stand-ins.
function BindingKitTestEnv.InstallBindingApi()
  combat, bindings = false, {}
  BindingKitTestEnv.SetGlobal("InCombatLockdown", function()
    return combat
  end)
  BindingKitTestEnv.SetGlobal("SetOverrideBinding", function(owner, priority, key, command)
    bindings[owner] = bindings[owner] or {}
    bindings[owner][key] = { priority = priority, command = command }
  end)
  BindingKitTestEnv.SetGlobal(
    "SetOverrideBindingClick",
    function(owner, priority, key, buttonName, mouseButton)
      bindings[owner] = bindings[owner] or {}
      bindings[owner][key] = { priority = priority, click = buttonName, mouseButton = mouseButton }
    end
  )
  BindingKitTestEnv.SetGlobal("ClearOverrideBindings", function(owner)
    bindings[owner] = {}
  end)
end

---Reset, install the host stubs and the binding stand-ins, load the chain.
---@return table BindingKit
---@return table Registry
function BindingKitTestEnv.NewPackage()
  local BindingKit, Registry = sharedNewPackage()
  BindingKitTestEnv.InstallBindingApi()
  return BindingKit, Registry
end

---The override bindings the stand-ins hold for `owner`, key to entry.
---@param owner table
---@return table
function BindingKitTestEnv.Bindings(owner)
  return bindings[owner] or {}
end

---Enter combat: `InCombatLockdown` answers `true`.
function BindingKitTestEnv.SetCombat()
  combat = true
end

---Leave combat and emit `PLAYER_REGEN_ENABLED`, as the client does.
function BindingKitTestEnv.EndCombat()
  combat = false
  BindingKitTestEnv.Emit("PLAYER_REGEN_ENABLED")
end

---The values the host error handler received since the last call.
---@return any[]
function BindingKitTestEnv.TakeReportedValues()
  local values = {}
  for index, entry in ipairs(BindingKitTestEnv.TakeReportedErrors()) do
    values[index] = entry.value
  end
  return values
end

---Install `issecretvalue`, reporting the tables `NewSecret` returns.
function BindingKitTestEnv.InstallSecretProbe()
  BindingKitTestEnv.SetGlobal("issecretvalue", function(value)
    return secrets[value] == true
  end)
end

---A value `issecretvalue` reports as secret once the probe is installed.
---@return table secret
function BindingKitTestEnv.NewSecret()
  local secret = {}
  secrets[secret] = true
  return secret
end

---Clear everything the shared fixture clears, plus the stand-ins.
function BindingKitTestEnv.Reset()
  sharedReset()
  for index = 1, #OWNED_GLOBALS do
    BindingKitTestEnv.SetGlobal(OWNED_GLOBALS[index], nil)
  end
end

---Load the BindingKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client.
---@param revision integer
---@return table BindingKit
function BindingKitTestEnv.LoadRevision(revision)
  -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
  -- `require` does.
  local path = nil
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", "BindingKit")
    local file = io.open(candidate, "r")
    if file ~= nil then
      file:close()
      path = candidate
      break
    end
  end
  if path == nil then
    error("BindingKitTestEnv.LoadRevision could not find BindingKit.lua on package.path", 2)
  end

  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()

  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  if replacements ~= 1 then
    error("BindingKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
  end

  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

return BindingKitTestEnv
