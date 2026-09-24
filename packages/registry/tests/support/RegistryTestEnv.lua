--- Package-specific test environment for the Registry suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order and the
--- bootstrap-state accessors only Registry's own specs need.
local FrameworkTestEnv = require("FrameworkTestEnv")

local RegistryTestEnv = FrameworkTestEnv.New({
  modules = { "Registry" },
  -- Registry is zero-dependency pure Lua.
  wowApi = false,
  legacyRegistryState = true,
})

--- Registry's specs name the state keys without the `REGISTRY_` prefix that the
--- other packages use, because here the state is the subject rather than a
--- dependency's implementation detail.
RegistryTestEnv.STATE_KEY = RegistryTestEnv.REGISTRY_STATE_KEY
RegistryTestEnv.LEGACY_STATE_KEY = RegistryTestEnv.LEGACY_REGISTRY_STATE_KEY

--- Reset, then load a Registry with no prior bootstrap state.
---@return Registry
function RegistryTestEnv.NewRegistry()
  return RegistryTestEnv.NewPackage()
end

--- Load Registry again over whatever state is already published.
---@return Registry
function RegistryTestEnv.Reload()
  return RegistryTestEnv.ReloadPackage()
end

--- The private bootstrap state Registry publishes, or `nil`.
---@return table|nil
function RegistryTestEnv.GetState()
  -- Registry publishes its bootstrap state and public namespace in the global table; reading them is how a spec inspects it.
  -- selene: allow(global_usage)
  return rawget(_G, RegistryTestEnv.STATE_KEY)
end

--- The public `MoltenCodes` namespace, or `nil`.
---@return table|nil
function RegistryTestEnv.GetNamespace()
  -- Registry publishes its bootstrap state and public namespace in the global table; reading them is how a spec inspects it.
  -- selene: allow(global_usage)
  return rawget(_G, RegistryTestEnv.NAMESPACE_KEY)
end

return RegistryTestEnv
