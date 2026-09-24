--- Package-specific test environment for the ClientKit suite.
---
--- The World of Warcraft stubs, including the per-flavour client profiles in
--- `framework/ClientStub.lua`, live in the shared `FrameworkTestEnv` fixture at
--- `tests/support/`. What stays here is this package's own module load order,
--- a loader that selects a profile first, a frame double for the restricted
--- frame probe, the source loader the upgrade specs use, and the host functions
--- only ClientKit reads: `GetLocale`, `GetAddOnInfo` and the two addon
--- dependency lists, in the `C_AddOns` form when the profile has that table and
--- the legacy global form otherwise. This environment installs them and
--- removes them again on `Reset`.
local FrameworkTestEnv = require("FrameworkTestEnv")

local ClientKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "ClientKit" },
})

--- Path of the runtime source, relative to the repository root the runner
--- starts Busted from.
ClientKitTestEnv.SOURCE_PATH = "packages/clientKit/src/ClientKit.lua"

--- The client locale `NewPackageFor` installs unless a spec asks for another.
ClientKitTestEnv.DEFAULT_CLIENT_LOCALE = "enUS"

--- The host functions this environment installs itself and therefore clears
--- on every reset, whichever form the profile placed them in.
local OWNED_GLOBALS = {
  "GetLocale",
  "GetAddOnInfo",
  "GetAddOnDependencies",
  "GetAddOnOptionalDependencies",
}

--- Lower-cased addon folder name to `{ name, dependencies,
--- optionalDependencies }` for every addon `RegisterAddOn` made the host list,
--- `name` being the spelling it was registered under. The host matches addon
--- names case-insensitively, so the stubs look names up the same way. Read at
--- call time.
local knownAddOns = {}

--- `"<addon>\0<field>"` to how many times the metadata call was asked for it.
local metadataReads = {}

--- Field names the metadata stub raises for, modelling a client whose
--- metadata call does not export that field.
local refusedFields = {}

local sharedReset = ClientKitTestEnv.Reset

---Install one client global.
---@param name string
---@param value any
local function setGlobal(name, value)
  -- The stub stands in for a World of Warcraft client API that only exists in the global table.
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Options for `NewPackageFor`.
---@class ClientKitTestEnv.HostOptions
---@field locale (string|false)? What `GetLocale()` answers; `false` installs no `GetLocale`. Defaults to `DEFAULT_CLIENT_LOCALE`.
---@field addOnInfo boolean? Whether the host has `GetAddOnInfo` and the two dependency-list calls. Defaults to `true`.
---@field secretStrings string[]? Strings the host's `issecretvalue` reports secret, in addition to what the profile already reports. Needs a profile with `issecretvalue`.

---Return the registered addon `addonName` names, matched case-insensitively
---as the host matches it, or `nil` when the host does not list it.
---@param addonName any
---@return table?
local function findKnownAddOn(addonName)
  if type(addonName) ~= "string" then
    return nil
  end
  return knownAddOns[string.lower(addonName)]
end

---Install `GetAddOnInfo`, `GetAddOnDependencies` and
---`GetAddOnOptionalDependencies` through `install`, into the `C_AddOns` table
---or the global table.
---
---`GetAddOnInfo` models the real call: it never raises for an unknown name but
---echoes the name back with `reason == "MISSING"`, and for a listed addon
---returns the folder name in the host's spelling with no reason.
---@param install fun(name: string, value: function)
local function installAddOnInfo(install)
  install("GetAddOnInfo", function(addonName)
    local known = findKnownAddOn(addonName)
    if known == nil then
      return addonName, addonName, nil, false, "MISSING", "INSECURE", false
    end
    return known.name, known.name, nil, true, nil, "INSECURE", false
  end)
  install("GetAddOnDependencies", function(addonName)
    local known = findKnownAddOn(addonName)
    if known == nil then
      return
    end
    return unpack(known.dependencies)
  end)
  install("GetAddOnOptionalDependencies", function(addonName)
    local known = findKnownAddOn(addonName)
    if known == nil then
      return
    end
    return unpack(known.optionalDependencies)
  end)
end

---Wrap the metadata call the profile installed so that every read is counted,
---a refused field raises, and a registered addon is found under any spelling
---of its name, without changing what the shared stub answers otherwise.
---@param read fun(name: string): function?
---@param install fun(name: string, value: function)
local function wrapMetadataCall(read, install)
  local hostCall = read("GetAddOnMetadata")
  if hostCall == nil then
    return
  end
  install("GetAddOnMetadata", function(addon, field)
    local known = findKnownAddOn(addon)
    local hostName = known and known.name or addon
    local key = tostring(hostName) .. "\0" .. tostring(field)
    metadataReads[key] = (metadataReads[key] or 0) + 1
    if refusedFields[field] then
      error("Usage: GetAddOnMetadata(index or name, field)", 2)
    end
    return hostCall(hostName, field)
  end)
end

---Make the profile's `issecretvalue` also report every string in
---`secretStrings` as secret. A profile without the probe cannot be extended.
---@param secretStrings string[]
local function extendSecretProbe(secretStrings)
  -- The stub stands in for a World of Warcraft client API that only exists in the global table.
  -- selene: allow(global_usage)
  local hostProbe = rawget(_G, "issecretvalue")
  if type(hostProbe) ~= "function" then
    error("ClientKitTestEnv secretStrings needs a profile with issecretvalue", 3)
  end
  local secrets = {}
  for index = 1, #secretStrings do
    secrets[secretStrings[index]] = true
  end
  setGlobal("issecretvalue", function(value)
    return secrets[value] == true or hostProbe(value)
  end)
end

---Install this environment's own host functions on the form the current
---profile uses: into `C_AddOns` when that table exists, else as globals.
---@param hostOptions ClientKitTestEnv.HostOptions
local function installClientKitHost(hostOptions)
  local locale = hostOptions.locale
  if locale == nil then
    locale = ClientKitTestEnv.DEFAULT_CLIENT_LOCALE
  end
  if locale ~= false then
    setGlobal("GetLocale", function()
      return locale
    end)
  end

  -- The stub stands in for a World of Warcraft client API that only exists in the global table.
  -- selene: allow(global_usage)
  local addOns = rawget(_G, "C_AddOns")
  local read, install
  if type(addOns) == "table" then
    read = function(name)
      return rawget(addOns, name)
    end
    install = function(name, value)
      rawset(addOns, name, value)
    end
  else
    read = function(name)
      -- The stub stands in for a World of Warcraft client API that only exists in the global table.
      -- selene: allow(global_usage)
      return rawget(_G, name)
    end
    install = setGlobal
  end

  wrapMetadataCall(read, install)
  if hostOptions.addOnInfo ~= false then
    installAddOnInfo(install)
  end
  if hostOptions.secretStrings ~= nil then
    extendSecretProbe(hostOptions.secretStrings)
  end
end

---Clear everything the shared fixture clears, plus this environment's own
---host functions and bookkeeping.
function ClientKitTestEnv.Reset()
  sharedReset()
  for index = 1, #OWNED_GLOBALS do
    setGlobal(OWNED_GLOBALS[index], nil)
  end
  knownAddOns = {}
  metadataReads = {}
  refusedFields = {}
end

---Reset, install the host as `profileName` models it plus this environment's
---own host functions, then load Registry only. An upgrade spec follows this
---with `LoadSourceAtRevision` to load an older revision against that host.
---@param profileName string? a name from `WOW_PROFILES`, or `nil` for the shared host with no client identity
---@param hostOptions ClientKitTestEnv.HostOptions? locale and addon-info surface; every field has a default
---@return table Registry
function ClientKitTestEnv.NewHostFor(profileName, hostOptions)
  ClientKitTestEnv.Reset()
  ClientKitTestEnv.SetWowProfile(profileName)
  ClientKitTestEnv.InstallWowApi()
  installClientKitHost(hostOptions or {})
  return require("Registry")
end

---`NewHostFor`, then load ClientKit against that host.
---@param profileName string? a name from `WOW_PROFILES`, or `nil` for the shared host with no client identity
---@param hostOptions ClientKitTestEnv.HostOptions? locale and addon-info surface; every field has a default
---@return table ClientKit
---@return table Registry
function ClientKitTestEnv.NewPackageFor(profileName, hostOptions)
  local Registry = ClientKitTestEnv.NewHostFor(profileName, hostOptions)
  return require("ClientKit"), Registry
end

---Options for `RegisterAddOn`.
---@class ClientKitTestEnv.AddOnOptions
---@field dependencies string[]? What the host's `GetAddOnDependencies` returns. Defaults to none.
---@field optionalDependencies string[]? What the host's `GetAddOnOptionalDependencies` returns. Defaults to none.

---Make the host list `addonName`, so `GetAddOnInfo` describes it instead of
---answering `"MISSING"`, under any spelling of its case. Its `.toc` fields are
---set separately with `SetAddOnMetadata`, under this spelling.
---@param addonName string the folder name as the host spells it
---@param options ClientKitTestEnv.AddOnOptions?
function ClientKitTestEnv.RegisterAddOn(addonName, options)
  options = options or {}
  knownAddOns[string.lower(addonName)] = {
    name = addonName,
    dependencies = options.dependencies or {},
    optionalDependencies = options.optionalDependencies or {},
  }
end

---Make the metadata call raise for `field`, as a client whose `.toc` reader
---does not export that field does.
---@param field string
function ClientKitTestEnv.RefuseMetadataField(field)
  refusedFields[field] = true
end

---How many times the host's metadata call was asked for `field` of `addon`
---since the last reset, under any spelling of a registered addon's name.
---@param addon string
---@param field string
---@return integer
function ClientKitTestEnv.MetadataReads(addon, field)
  local known = findKnownAddOn(addon)
  local hostName = known and known.name or addon
  return metadataReads[hostName .. "\0" .. field] or 0
end

---Options for `NewFrame`.
---@class ClientKitTestEnv.FrameOptions
---@field forbidden boolean? What `IsForbidden()` answers; the method is absent when `nil`.
---@field accessible boolean? What `CanBeAccessedInContext()` answers; the method is absent when `nil`.

---A stand-in for a frame found by enumeration, reduced to the two methods
---`ClientKit:CanAccessFrame` asks. Each method exists only when its option is
---given, which is how a spec models a client that predates it.
---@param options ClientKitTestEnv.FrameOptions?
---@return table frame
function ClientKitTestEnv.NewFrame(options)
  options = options or {}
  local frame = { calls = {} }

  if options.forbidden ~= nil then
    function frame:IsForbidden()
      self.calls[#self.calls + 1] = "IsForbidden"
      return options.forbidden
    end
  end

  if options.accessible ~= nil then
    function frame:CanBeAccessedInContext()
      self.calls[#self.calls + 1] = "CanBeAccessedInContext"
      return options.accessible
    end
  end

  return frame
end

---Load a copy of the ClientKit source that claims `revision`, against the
---state already published, exactly as a newer embedded copy would load.
---@param revision integer
---@return any
function ClientKitTestEnv.LoadSourceAtRevision(revision)
  local file = io.open(ClientKitTestEnv.SOURCE_PATH, "r")
  if file == nil then
    error("ClientKitTestEnv cannot read " .. ClientKitTestEnv.SOURCE_PATH, 2)
  end
  local source = file:read("*a")
  file:close()

  local patched, count = source:gsub(
    "local IMPLEMENTATION_REVISION = %d+",
    "local IMPLEMENTATION_REVISION = " .. revision,
    1
  )
  if count ~= 1 then
    error("ClientKitTestEnv found no IMPLEMENTATION_REVISION to patch", 2)
  end

  local chunk, message = loadstring(patched, "@" .. ClientKitTestEnv.SOURCE_PATH)
  if chunk == nil then
    error(message, 2)
  end
  return chunk()
end

return ClientKitTestEnv
