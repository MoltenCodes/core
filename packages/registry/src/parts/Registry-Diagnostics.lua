-- MoltenCodes Registry part Diagnostics
--
-- The read-only views of the registry meant for consoles, options pages and
-- bridges: `Registry:GetInfo` and `Registry:Packages`. Packages resolve each
-- other with `Get` and `Find`, which stay in the core; an addon that lists or
-- inspects registrations embeds this file after `registry\Registry.lua`
-- (docs/decisions/0001-kit-core-and-parts.md).
--
-- The part records itself in the core's state as `parts.Diagnostics` with its
-- revision and its facade methods, and reads the core's validators and entry
-- accessors from `state.helpers` at call time, so a core upgraded after this
-- part loaded serves it. Two addons may embed different revisions of the part;
-- the highest wins.
--
-- Contents
--
--   Constants ................ Identity and the state keys.
--   Core ..................... Finding the loaded core and its state.
--   Diagnostics .............. GetInfo and Packages.
--   Commit ................... Recording the part and installing its methods.

-- Constants ---------------------------------------------------------------

local PART_NAME = "Diagnostics"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local GLOBAL_STATE_KEY = "__MOLTENCODES_REGISTRY_STATE_V2"

local STATUS_ACTIVE = "active"

-- Core --------------------------------------------------------------------

local type = type
local rawget = rawget
local rawset = rawset

-- The shared namespace and the Registry state are the documented hand-off points between
-- independently embedded copies; both exist only in the global table.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
-- selene: allow(global_usage)
local state = rawget(_G, GLOBAL_STATE_KEY)
if
  type(Registry) ~= "table"
  or type(rawget(Registry, "HasPart")) ~= "function"
  or type(state) ~= "table"
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
then
  error("MoltenCodes Registry part Diagnostics requires Registry API 2 to be loaded first", 2)
end

local parts = rawget(state, "parts")
local installed = rawget(parts, PART_NAME)
if
  type(installed) == "table"
  and type(rawget(installed, "revision")) == "number"
  and rawget(installed, "revision") >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every copy.
  return Registry
end

-- Diagnostics -------------------------------------------------------------

---Returns a freshly allocated metadata snapshot for one registration.
---@param packageName string
---@param api integer
---@return Registry.PackageInfo|nil
local function getInfo(_, packageName, api)
  local helpers = rawget(state, "helpers")
  helpers.validatePackageName(packageName, "GetInfo")
  helpers.validatePositiveInteger(api, "GetInfo", "api")
  local entry = helpers.findEntry(packageName, api, 4)
  if entry == nil then
    return nil
  end
  return {
    package = packageName,
    api = api,
    revision = rawget(entry, "revision"),
    implementation = rawget(entry, "implementation"),
  }
end

---Order two `Packages` rows by package name, then API generation.
---@param left Registry.PackageRow
---@param right Registry.PackageRow
---@return boolean
local function packageRowBefore(left, right)
  if left.package ~= right.package then
    return left.package < right.package
  end
  return left.api < right.api
end

---Diagnostic enumeration of every registration, sorted by package then API.
---
---Allocates a fresh array of fresh rows on every call by design; it is meant for consoles and
---options pages, never for a hot path. Malformed private state raises the same corruption error
---`Get` raises, at the caller, instead of being listed as data or failing inside `table.sort`.
---@return Registry.PackageRow[]
local function packages()
  local helpers = rawget(state, "helpers")
  local entries = rawget(state, "entries")
  local rows = {}
  for packageName in next, entries do
    if type(packageName) ~= "string" then
      error(helpers.corrupted, 2)
    end
    local packageEntries = helpers.getPackageEntries(packageName, 3) --[[@as table]]
    for api in next, packageEntries do
      if not helpers.isBoundedInteger(api, 1) then
        error(helpers.corrupted, 2)
      end
      local entry = helpers.getEntry(packageEntries, api, 3) --[[@as table]]
      rows[#rows + 1] = {
        package = packageName,
        api = api,
        revision = rawget(entry, "revision"),
        status = rawget(entry, "status") or STATUS_ACTIVE,
      }
    end
  end
  table.sort(rows, packageRowBefore)
  return rows
end

-- Commit ------------------------------------------------------------------

rawset(parts, PART_NAME, {
  revision = PART_REVISION,
  methods = { GetInfo = getInfo, Packages = packages },
})
rawset(Registry, "GetInfo", getInfo)
rawset(Registry, "Packages", packages)

return Registry
