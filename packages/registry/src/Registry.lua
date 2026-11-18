-- MoltenCodes Registry
--
-- Zero-dependency bootstrap resolver for independently embedded framework
-- packages. The core invariants are: one shared facade per Registry API
-- generation, one stable implementation table per (package, API) pair, and
-- highest-revision-wins selection without replacing shared table identity.
--
-- Every API generation owns a private bootstrap state and publishes itself at
-- `MoltenCodes.Registries[<generation>]`; `MoltenCodes.Registry` aliases the newest.
--
-- Budget: at most 600 code lines (lines that are neither blank nor comments)
-- and at most 24 KB resident with debug information kept. Registry sits at the
-- bottom of every dependency chain and is loaded by every addon that embeds a
-- Kit, so it holds what every Kit needs and stays small and boring. Comments
-- cost nothing resident and are not counted; `tests/Budget_spec.lua` counts
-- the code lines. A change that would break the budget moves behaviour into a
-- part or a package of its own (as the LibStub bridge did: it is `interopKit`)
-- or first shrinks what is here.
--
-- This file is the core (docs/decisions/0001-kit-core-and-parts.md). Two
-- parts load after it and hold what only some packages use: `Handover`
-- (`parts/Registry-Handover.lua`: `request.retire`, `request.migrations`,
-- `request.sealFacade` and `OnRetire`) and `Diagnostics`
-- (`parts/Registry-Diagnostics.lua`: `GetInfo` and `Packages`).
--
-- Contents
--
--   Validation ............... Identifier and revision checks.
--   Bootstrap state .......... Finding or creating the generation-private state.
--   Package-state access ..... Reading entries without trusting their shape, and
--                              the lookup fast path.
--   Public types ............. LuaCATS declarations for the facade.
--   Lookup ................... Register, Get, Find.
--   Parts .................... HasPart, the members of a part that is not
--                              loaded, and the helpers parts call.
--   Bootstrap ................ The reconciliation every Kit calls.
--   Commit ................... Installing the methods and the facade self-check.
--   Public namespace ......... `MoltenCodes.Registries[n]` and the alias.

-- Read once: a global read is a hash lookup in `_G` on every call, a local is not.
local type = type
local rawget = rawget
local rawset = rawset
local select = select
-- The global table is where `issecretvalue`, `geterrorhandler` and the shared state live.
-- selene: allow(global_usage)
local globals = _G

local GLOBAL_STATE_KEY = "__MOLTENCODES_REGISTRY_STATE_V2"
local PUBLIC_NAMESPACE_KEY = "MoltenCodes"
local PUBLIC_GENERATIONS_KEY = "Registries"
local PUBLIC_ALIAS_KEY = "Registry"

local STATE_SCHEMA = 1
local API_GENERATION = 2
local IMPLEMENTATION_REVISION = 17

-- Lua 5.1 doubles represent consecutive integers exactly only up to 2^53; past it
-- distinct values compare equal, and a revision such as `1e300` would become one
-- no future embedded copy could replace. Identifiers are therefore bounded.
local MAXIMUM_INTEGER = 2 ^ 53
local MAXIMUM_INTEGER_TEXT = "2^53"

local PACKAGE_NAME_PATTERN = "^[a-z][A-Za-z0-9]*$"

-- The fixed vocabulary `Registry:Find` explains a miss with.
local FIND_ABSENT = "absent"
local FIND_RETIRED = "retired"
local FIND_GENERATION_MISMATCH = "generation_mismatch"

-- Entry status values. An entry is `retired` from the moment its outgoing copy
-- is asked to hand over until the incoming copy's migrations have all run.
local STATUS_ACTIVE = "active"
local STATUS_RETIRED = "retired"

-- The one message every accessor raises for malformed package state, and the
-- one `Bootstrap` raises, after the request's label, for a malformed copy.
local CORRUPTED = "Registry: package state is corrupted"
local INCOMPLETE = " package state is corrupted or incomplete"

-- The parts (docs/decisions/0001-kit-core-and-parts.md) and the members each
-- provides on the facade. A member whose part is not loaded stays on the
-- facade as a stub naming the file to embed, so the facade self-check of every
-- older copy keeps accepting it.
local PART_MEMBERS = {
  OnRetire = "Handover",
  GetInfo = "Diagnostics",
  Packages = "Diagnostics",
}

-- Validation ---------------------------------------------------------------

-- issecretvalue is a World of Warcraft client API reachable only through the global table.
local loadedProbe = rawget(globals, "issecretvalue")
loadedProbe = type(loadedProbe) == "function" and loadedProbe or nil
---`issecretvalue` as resolved at load or, when absent then, as the global is now (a probe
---installed later is honoured); `nil` when there is none.
---@return function|nil
local function readProbe()
  local isSecretValue = loadedProbe or rawget(globals, "issecretvalue")
  return type(isSecretValue) == "function" and isSecretValue or nil
end

---Whether the client reports `value` as secret; always `false` elsewhere. Comparing a secret with
---a value of its own type raises inside Registry, so outside values are tested with `type` and
---`isSecret` first; a secret is never valid.
---@param value any
---@return boolean
local function isSecret(value)
  local isSecretValue = loadedProbe or readProbe()
  return isSecretValue ~= nil and isSecretValue(value) == true
end

---Whether `hook(value)` answers truthy; a secret answer cannot be tested, so it never does.
---@param hook function
---@param value any
---@return boolean
local function passes(hook, value)
  local verdict = hook(value)
  return not isSecret(verdict) and verdict and true or false
end

---Whether `value` is an exact integer from `minimum` up to 2^53. `nan` fails the
---`% 1` comparison and infinity fails the bound, with no special case.
---@param value any
---@param minimum 0|1
---@return boolean
local function isBoundedInteger(value, minimum)
  return type(value) == "number"
    and not isSecret(value)
    and value % 1 == 0
    and value >= minimum
    and value <= MAXIMUM_INTEGER
end

---@param packageName any
---@param methodName string
local function validatePackageName(packageName, methodName)
  if type(packageName) ~= "string" or isSecret(packageName) or packageName == "" then
    error("Registry:" .. methodName .. " packageName must be a non-empty string", 3)
  end
  if not string.match(packageName, PACKAGE_NAME_PATTERN) then
    error("Registry:" .. methodName .. " packageName must match ^[a-z][A-Za-z0-9]*$", 3)
  end
end

---Refuse an `api` or `revision` argument that is not a bounded positive integer, at the caller of
---the public method (level 3: this function, the method, its caller).
---@param value any
---@param methodName string
---@param fieldName "api"|"revision"
local function validatePositiveInteger(value, methodName, fieldName)
  if not isBoundedInteger(value, 1) then
    local problem = " must be a positive integer up to " .. MAXIMUM_INTEGER_TEXT
    error("Registry:" .. methodName .. " " .. fieldName .. problem, 3)
  end
end

-- Bootstrap state ---------------------------------------------------------
--
-- This runs at file scope, where a stack level would name whichever addon TOC
-- is loading the file, so load-time failures use level 0 and carry an explicit
-- `Registry:` prefix instead.

-- Independently embedded Registry copies find each other only through this global key.
local state = rawget(globals, GLOBAL_STATE_KEY)

if state == nil then
  state = {
    schema = STATE_SCHEMA,
    registryApi = API_GENERATION,
    registryRevision = 0,
    entries = {},
    facade = {},
  }
  -- The first copy to load publishes the shared state under that same global key.
  rawset(globals, GLOBAL_STATE_KEY, state)
elseif type(state) ~= "table" then
  error("Registry: bootstrap state is incompatible", 0)
end

local stateSchema = rawget(state, "schema")
local stateApi = rawget(state, "registryApi")
local stateRevision = rawget(state, "registryRevision")
local entries = rawget(state, "entries")
local facade = rawget(state, "facade")
if stateSchema ~= STATE_SCHEMA then
  error("Registry: bootstrap state is incompatible", 0)
end
if stateApi ~= API_GENERATION then
  error("Registry: API generation is incompatible", 0)
end
if
  not isBoundedInteger(stateRevision, 0)
  or type(entries) ~= "table"
  or type(facade) ~= "table"
then
  error("Registry: bootstrap state is corrupted", 0)
end

-- Revision 17 adds `parts` (part name to `{ revision, methods, ... }`) and
-- `helpers` (the core functions a part calls). The state `schema` stays 1:
-- every older copy refuses any other schema, and never reads these fields.
local parts = rawget(state, "parts")
if type(parts) == "nil" then
  parts = {}
  rawset(state, "parts", parts)
elseif type(parts) ~= "table" then
  error("Registry: bootstrap state is corrupted", 0)
end

-- Package-state access ----------------------------------------------------
--
-- An entry is `{ revision, implementation }`. Revisions 7 and 8 add optional fields that older
-- entries simply lack: `status`, `retire` (the selected copy's hand-over hook), `migratedThrough`
-- (the revision whose layout the state is in), `migrating` and `pendingState` (an unfinished
-- migration run and the state it had reached) and `seal` (the sealed-facade metatable). The core
-- keeps `status` and `migratedThrough`; the Handover part owns the others.
--
-- Corrupted state found while serving a public call is raised at that call's caller, like an
-- argument error. The accessors therefore take the stack level the public method needs, counted
-- from the accessor itself.

---@param packageName string
---@param level integer error level, counted from this function
---@return table|nil
local function getPackageEntries(packageName, level)
  local packageEntries = rawget(entries, packageName)
  if packageEntries ~= nil and type(packageEntries) ~= "table" then
    error(CORRUPTED, level)
  end
  return packageEntries
end

---@param packageEntries table
---@param api integer
---@param level integer error level, counted from this function
---@return table|nil
local function getEntry(packageEntries, api, level)
  local entry = rawget(packageEntries, api)
  if entry == nil then
    return nil
  end
  if
    type(entry) ~= "table"
    or not isBoundedInteger(rawget(entry, "revision"), 1)
    or type(rawget(entry, "implementation")) ~= "table"
  then
    error(CORRUPTED, level)
  end
  return entry
end

---The entry for `(packageName, api)`, or `nil`. `level` counts from the
---accessors: the accessor, this function, every Registry frame up to the public
---method, then its caller. A public method calling this directly passes 4 and
---`adopt`, one frame deeper in `Bootstrap`, passes 5, so corruption is always
---raised at the line that called Registry.
---@param packageName string
---@param api integer
---@param level integer error level, counted from the accessors
---@return table|nil
local function findEntry(packageName, api, level)
  local packageEntries = getPackageEntries(packageName, level)
  if packageEntries == nil then
    return nil
  end
  return getEntry(packageEntries, api, level)
end

---The fast path of `Register`, `Get` and `Find`: look up before validating.
---
---Every Registry revision validated a name and an API before either became a key, so a hit needs
---no pattern match; the probe still runs before either is used as a key. A hit returns the
---well-formed entry and its fields; anything else returns `nil` and whether the arguments are
---valid, so the full path raises, or explains the miss, without probing again.
---@param packageName any
---@param api any
---@return table|nil entry
---@return boolean validArguments
---@return table|nil implementation
---@return integer|nil revision
local function lookUp(packageName, api)
  local probe = loadedProbe or readProbe()
  if probe ~= nil and (probe(packageName) == true or probe(api) == true) then
    return nil, false
  end
  -- Plain indexing: the state, its buckets and entries are Registry's own tables and carry no
  -- metatable. Every field is still shape-checked before a hit is returned.
  local packageEntries = entries[packageName]
  local entry = type(packageEntries) == "table" and packageEntries[api] or nil
  if type(entry) == "table" then
    local implementation, revision = entry.implementation, entry.revision
    if
      type(implementation) == "table"
      and type(revision) == "number"
      and not (probe ~= nil and probe(revision) == true)
      and revision % 1 == 0
      and revision > 0
      and revision <= MAXIMUM_INTEGER
    then
      return entry, true, implementation, revision
    end
  end
  if type(packageName) ~= "string" or type(api) ~= "number" or packageName == "" then
    return nil, false
  end
  local validName = string.match(packageName, PACKAGE_NAME_PATTERN) ~= nil
  return nil, validName and api % 1 == 0 and api > 0 and api <= MAXIMUM_INTEGER
end

-- Public types ------------------------------------------------------------

---Metadata snapshot returned by `Registry:GetInfo`.
---@class Registry.PackageInfo
---@field ["package"] string Package identifier the snapshot describes.
---@field api integer API generation the snapshot describes.
---@field revision integer Currently selected implementation revision.
---@field implementation table The live shared package table.

---One row of the diagnostic listing `Registry:Packages` returns.
---@class Registry.PackageRow
---@field ["package"] string Package identifier.
---@field api integer API generation.
---@field revision integer Currently selected implementation revision.
---@field status "active"|"retired" Whether the selected copy finished taking over.

---Why `Registry:Find` found nothing.
---@alias Registry.FindReason "absent"|"retired"|"generation_mismatch"

---Everything `Registry:Bootstrap` needs in order to reconcile one embedded copy.
---
---`package`, `api` and `revision` are the package's identity; `label` prefixes the
---failures Registry raises on its behalf, so an author sees which package refused.
---@class Registry.BootstrapRequest
---@field ["package"] string Package identifier, as in `Registry:Register`.
---@field api integer API generation this copy implements.
---@field revision integer Implementation revision this copy carries.
---@field label string Error-message prefix, for example `"MoltenCodes SignalKit"`.
---@field validatePublicSurface fun(implementation: any): boolean Whether a table exposes the complete public API of this generation.
---@field validateState (fun(implementation: table): boolean)? Whether a same-revision copy already finished committing its private state.
---@field resume (fun(implementation: table, complete: boolean): integer|nil)? Same-revision repair hook; see `Registry:Bootstrap`.
---@field retire (fun(implementation: table, incomingRevision: integer): any)? This copy's hand-over hook, called once when a newer revision replaces it.
---@field migrations table<integer, fun(state: any, implementation: table): any>? Per-revision migration steps, keyed by the revision that introduced them.
---@field sealFacade boolean? Refuse new fields written to the facade from outside the package.

---The Registry facade shared by every compatible embedded copy.
---@class Registry
---@field API integer Registry API generation this facade implements.
---@field REVISION integer Registry implementation revision currently installed.
---@field Register fun(self: Registry, packageName: string, api: integer, revision: integer): table|nil, integer|nil
---@field Get fun(self: Registry, packageName: string, api: integer): table|nil, integer|nil
---@field GetInfo fun(self: Registry, packageName: string, api: integer): Registry.PackageInfo|nil
---@field Find fun(self: Registry, packageName: string, api: integer): table|nil, integer|Registry.FindReason
---@field Packages fun(self: Registry): Registry.PackageRow[]
---@field OnRetire fun(self: Registry, packageName: string, api: integer, retire: fun(implementation: table, incomingRevision: integer): any)
---@field Bootstrap fun(self: Registry, request: Registry.BootstrapRequest): table|nil, integer|nil, table|nil, any
---@field HasPart fun(self: Registry, name: string): boolean Whether the named part (`"Handover"`, `"Diagnostics"`) is loaded.

---@type Registry
local Registry = facade

-- Lookup ------------------------------------------------------------------

---Select `revision` over an existing entry's `currentRevision`, or refuse it.
---@param entry table
---@param implementation table the entry's shared package table
---@param currentRevision integer
---@param revision integer
---@return table|nil sharedPackageTable
---@return integer|nil previousRevision
local function selectRevision(entry, implementation, currentRevision, revision)
  if revision <= currentRevision then
    return nil
  end
  rawset(entry, "revision", revision)
  -- A retire hook belongs to the revision that registered it. Once another revision is selected the
  -- hook describes state that no longer exists, so it must never be handed the newer copy's table.
  rawset(entry, "retire", nil)
  -- The implementation table is never replaced: packages upgrade it in place,
  -- so consumers holding older references observe the newer revision at once.
  return implementation, currentRevision
end

---Select `revision` for `(packageName, api)` once the arguments are known to
---be valid: the work behind both `Register` and `Bootstrap`.
---
---`level` counts from the accessors, as for `findEntry`; both callers pass 4
---(the accessor, this function, the public method, its caller).
---@param packageName string
---@param api integer
---@param revision integer
---@param level integer error level, counted from the accessors
---@return table|nil sharedPackageTable
---@return integer|nil previousRevision
local function registerEntry(packageName, api, revision, level)
  local packageEntries = getPackageEntries(packageName, level)
  if packageEntries == nil then
    packageEntries = {}
    rawset(entries, packageName, packageEntries)
  end
  local entry = getEntry(packageEntries, api, level)
  if entry == nil then
    local implementation = {}
    rawset(packageEntries, api, {
      revision = revision,
      implementation = implementation,
    })
    return implementation, nil
  end
  return selectRevision(entry, rawget(entry, "implementation"), rawget(entry, "revision"), revision)
end

---Requests initialization rights for one package revision.
---@param packageName string
---@param api integer
---@param revision integer
---@return table|nil sharedPackageTable `nil` when an equal or newer revision already won.
---@return integer|nil previousRevision `nil` for the first accepted revision.
local function register(_, packageName, api, revision, ...)
  if select("#", ...) ~= 0 then
    error(
      "Registry:Register does not accept an implementation argument; "
        .. "initialize the returned shared package table instead",
      2
    )
  end
  local entry, validArguments, implementation, currentRevision = lookUp(packageName, api)
  if entry ~= nil and isBoundedInteger(revision, 1) then
    -- A hit returns both fields; the casts say so to the type checker.
    local current = currentRevision --[[@as integer]]
    return selectRevision(entry, implementation --[[@as table]], current, revision)
  end
  if not validArguments then
    validatePackageName(packageName, "Register")
    validatePositiveInteger(api, "Register", "api")
  end
  validatePositiveInteger(revision, "Register", "revision")
  -- Not a tail call: a tail call would drop this frame, and the level
  -- `registerEntry` raises at counts it.
  local selected, previousRevision = registerEntry(packageName, api, revision, 4)
  return selected, previousRevision
end

---Returns the selected shared package table and its revision.
---@param packageName string
---@param api integer
---@return table|nil implementation
---@return integer|nil revision
local function get(_, packageName, api)
  local entry, validArguments, implementation, revision = lookUp(packageName, api)
  if entry ~= nil then
    return implementation, revision
  end
  if not validArguments then
    validatePackageName(packageName, "Get")
    validatePositiveInteger(api, "Get", "api")
  end
  entry = findEntry(packageName, api, 4)
  if entry == nil then
    return nil
  end
  return rawget(entry, "implementation"), rawget(entry, "revision")
end

---Silent lookup for an optional dependency. Never raises for a package that is not there; raises
---at the caller only for malformed arguments. Allocation-free, so it is safe on any path.
---@param packageName string
---@param api integer
---@return table|nil implementation
---@return integer|Registry.FindReason revisionOrReason the revision, or why nothing was found
local function find(_, packageName, api)
  local entry, validArguments, implementation, revision = lookUp(packageName, api)
  if entry == nil then
    if not validArguments then
      validatePackageName(packageName, "Find")
      validatePositiveInteger(api, "Find", "api")
    end
    local packageEntries = getPackageEntries(packageName, 3)
    if packageEntries == nil or next(packageEntries) == nil then
      return nil, FIND_ABSENT
    end
    entry = getEntry(packageEntries, api, 3) --[[@as table|nil]]
    if entry == nil then
      return nil, FIND_GENERATION_MISMATCH
    end
    implementation, revision = rawget(entry, "implementation"), rawget(entry, "revision")
  end
  if rawget(entry, "status") == STATUS_RETIRED then
    return nil, FIND_RETIRED
  end
  return implementation, revision
end

-- Parts -------------------------------------------------------------------
--
-- A part records itself in `parts.<Part>` with its revision and its facade
-- methods, and calls the core through `state.helpers`, read at call time so a
-- core upgraded after the part loaded serves it. The commit below installs a
-- stub for every member and then the methods of every installed part, so
-- whichever loaded first, the part serves.

-- shared:begin reportError 1
-- Copied from tooling/shared/lua/reportError.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Report `failure` through the host error handler, or print it.
---@param failure any
local function reportError(failure)
  -- geterrorhandler is a client API reachable only through the global table.
  -- selene: allow(global_usage)
  local getErrorHandler = rawget(_G, "geterrorhandler")
  if type(getErrorHandler) == "function" then
    local handler = getErrorHandler()
    if type(handler) == "function" and pcall(handler, failure) then
      return
    end
  end
  print(failure)
end
-- shared:end reportError

---The message a member of `partName` raises while that part is not loaded.
---@param member string the member as its caller wrote it
---@param partName string
---@return string
local function missingPart(member, partName)
  return member
    .. " is in Registry's "
    .. partName
    .. " part, which is not loaded: add registry\\parts\\Registry-"
    .. partName
    .. ".lua to embeds.xml after registry\\Registry.lua"
end

---A facade method that raises at its caller, naming the part to embed. The
---message is built when it raises, so no stub keeps a long string resident.
---@param member string the facade member
---@return function
local function newPartStub(member)
  return function()
    error(missingPart("Registry:" .. member, PART_MEMBERS[member]), 2)
  end
end

---Whether the named part is loaded in this session: `"Handover"` or
---`"Diagnostics"`. Code that uses a part only when it is there asks this; every
---member stays on the facade whether its part is loaded or not.
---@param name string
---@return boolean
local function hasPart(_, name)
  if type(name) ~= "string" or isSecret(name) then
    error("Registry:HasPart name must be a string", 2)
  end
  return type(rawget(parts, name)) == "table"
end

---Report, once per entry, hand-over state an older revision left that only the
---Handover part can run: a retire hook, an unfinished migration run or a seal.
---It is left as it is, so the part finds it when it loads.
---@param entry table
---@param label string
local function reportStrandedHandover(entry, label)
  if
    rawget(entry, "handoverReported") == true
    or (
      type(rawget(entry, "retire")) == "nil"
      and rawget(entry, "migrating") ~= true
      and type(rawget(entry, "seal")) == "nil"
    )
  then
    return
  end
  rawset(entry, "handoverReported", true)
  reportError(
    label
      .. " inherited a retire hook, a migration run or a seal; "
      .. missingPart("running it", "Handover")
  )
end

-- Bootstrap ---------------------------------------------------------------

---@param field any
---@param fieldName string
---@param expectedType string
local function validateOptionalField(field, fieldName, expectedType)
  if type(field) ~= "nil" and (type(field) ~= expectedType or isSecret(field)) then
    error("Registry:Bootstrap request." .. fieldName .. " must be a " .. expectedType, 3)
  end
end

---Perform the reconciliation every embedded package repeats verbatim.
---
---Does a copy of `(package, api)` exist, is it newer, and did a same-revision
---copy finish? Asked out of order, an older copy reinterprets private state it
---does not own, so the order lives here once rather than in every package.
---
---`validateState`, `resume`, `retire`, `migrations` and `sealFacade` are optional;
---`docs/API.md` documents each and the decision table. The last three need the
---Handover part. Registry never calls this itself: its own bootstrap runs
---before the facade exists.
---@param request Registry.BootstrapRequest
---@return table|nil implementation the table to initialize; `nil`: return `selected` unchanged
---@return integer|nil previousRevision the inherited revision, as `Register` reports it
---@return table|nil selected the copy Registry selected
---@return any state the hand-over after every migration step; `nil` when none
local function bootstrap(_, request)
  if type(request) ~= "table" then
    error("Registry:Bootstrap request must be a table", 2)
  end
  local packageName = rawget(request, "package")
  local api = rawget(request, "api")
  local revision = rawget(request, "revision")
  local label = rawget(request, "label")
  local validateSurface = rawget(request, "validatePublicSurface")
  local validateState = rawget(request, "validateState")
  local resume = rawget(request, "resume")
  local retire = rawget(request, "retire")
  local migrations = rawget(request, "migrations")
  local sealFacade = rawget(request, "sealFacade")
  validatePackageName(packageName, "Bootstrap")
  validatePositiveInteger(api, "Bootstrap", "api")
  validatePositiveInteger(revision, "Bootstrap", "revision")
  if type(label) ~= "string" or isSecret(label) or label == "" then
    error("Registry:Bootstrap request.label must be a non-empty string", 2)
  end
  if type(validateSurface) ~= "function" then
    error("Registry:Bootstrap request.validatePublicSurface must be a function", 2)
  end
  validateOptionalField(validateState, "validateState", "function")
  validateOptionalField(resume, "resume", "function")
  validateOptionalField(retire, "retire", "function")
  validateOptionalField(migrations, "migrations", "table")
  validateOptionalField(sealFacade, "sealFacade", "boolean")
  local handoverPart = rawget(parts, "Handover")
  if handoverPart == nil then
    local field = (type(retire) ~= "nil" and "retire")
      or (type(migrations) ~= "nil" and "migrations")
      or (sealFacade == true and "sealFacade")
    if field then
      error(missingPart("Registry:Bootstrap request." .. field, "Handover"), 2)
    end
  end

  ---Finish handing `implementation` to the caller. The Handover part runs the
  ---migration steps not run yet, records the retire hook and applies the seal
  ---asked for; without it only the bookkeeping is done.
  ---@param implementation table
  ---@param inheritedRevision integer|nil
  ---@param handover any
  ---@return any state
  local function adopt(implementation, inheritedRevision, handover)
    -- `register` or the existing-copy lookup just proved the entry exists.
    -- Level 5: one frame deeper than `bootstrap`, which calls this.
    local entry = findEntry(packageName, api, 5) --[[@as table]]
    if handoverPart == nil then
      -- The bookkeeping a migration run leaves when it has no step to run; an
      -- unfinished run an older revision left waits for the part.
      if rawget(entry, "migrating") ~= true then
        rawset(entry, "migratedThrough", revision)
      end
      rawset(entry, "status", STATUS_ACTIVE)
      return nil
    end
    local ok, result =
      handoverPart.adopt(entry, implementation, inheritedRevision, handover, request)
    if not ok then
      error(label .. " " .. result, 3)
    end
    return result
  end

  -- The entry is read directly rather than through `get`, so corruption is
  -- raised at the package file's `Bootstrap` call, not inside Registry.
  local existingEntry = findEntry(packageName, api, 4)
  local existing, existingRevision = nil, nil
  if existingEntry ~= nil then
    existing = rawget(existingEntry, "implementation")
    existingRevision = rawget(existingEntry, "revision")
    if rawget(existing, "API") ~= api then
      error(label .. INCOMPLETE, 2)
    end

    -- The facade publishes its revision only once it has committed the
    -- matching implementation, so a facade claiming to be newer than
    -- the revision Registry accepted cannot be trusted at all.
    local facadeRevision = rawget(existing, "REVISION")
    if type(facadeRevision) ~= "number" or facadeRevision > existingRevision then
      error(label .. INCOMPLETE, 2)
    end
    if existingRevision > revision then
      -- A newer compatible embedded revision owns its own private
      -- state schema. Older copies validate the stable API surface
      -- and must not reinterpret state they do not understand.
      if facadeRevision ~= existingRevision or not passes(validateSurface, existing) then
        error(label .. INCOMPLETE, 2)
      end
      return nil, nil, existing
    end

    -- An older revision is deliberately not held to this revision's
    -- public surface. It is about to be upgraded in place, and the
    -- caller validates whatever it inherits before it reuses it.
    if existingRevision == revision then
      if not passes(validateSurface, existing) then
        error(label .. INCOMPLETE, 2)
      end

      -- A secret verdict cannot be compared, so it counts as "not complete".
      local complete = facadeRevision == existingRevision
      if complete and type(validateState) ~= "nil" then
        local verdict = validateState(existing)
        complete = not isSecret(verdict) and verdict == true
      end
      if type(resume) ~= "nil" then
        local inherited = resume(existing, complete)
        if type(inherited) ~= "nil" then
          if not isBoundedInteger(inherited, 0) then
            error("Registry:Bootstrap request.resume must return a revision", 2)
          end
          return existing, inherited, existing, adopt(existing, inherited, nil)
        end
        return nil, nil, existing
      end
      if not complete then
        error(label .. INCOMPLETE, 2)
      end
      return nil, nil, existing
    end
  end

  -- An older revision is selected: its copy hands over before this one
  -- registers, so the hook still sees the state it owns.
  local handover = nil
  if existingEntry ~= nil then
    if handoverPart == nil then
      reportStrandedHandover(existingEntry, label)
    else
      handover = handoverPart.retireOutgoing(existingEntry, existing, revision, label)
    end
  end
  local implementation, previousRevision = registerEntry(packageName, api, revision, 4)
  if implementation == nil then
    -- An equal or newer compatible revision owns the shared table.
    return nil, nil, existing
  end
  if previousRevision ~= existingRevision then
    error(label .. " Registry state changed unexpectedly during bootstrap", 2)
  end
  return implementation,
    previousRevision,
    existing,
    adopt(implementation, previousRevision, handover)
end

-- Commit ------------------------------------------------------------------

-- Compatible copies share this facade. A newer revision replaces its methods in
-- place, so references taken from older copies reach the upgraded Registry.
if stateRevision < IMPLEMENTATION_REVISION then
  rawset(Registry, "Register", register)
  rawset(Registry, "Get", get)
  rawset(Registry, "Find", find)
  rawset(Registry, "Bootstrap", bootstrap)
  rawset(Registry, "HasPart", hasPart)
  for member in next, PART_MEMBERS do
    rawset(Registry, member, newPartStub(member))
  end
  -- A part loaded before this core keeps serving: its methods replace the stubs.
  for _, part in next, parts do
    local methods = type(part) == "table" and rawget(part, "methods") or nil
    if type(methods) == "table" then
      for member, method in next, methods do
        rawset(Registry, member, method)
      end
    end
  end
  -- What the parts call, read by them at call time.
  rawset(state, "helpers", {
    corrupted = CORRUPTED,
    isBoundedInteger = isBoundedInteger,
    validatePackageName = validatePackageName,
    validatePositiveInteger = validatePositiveInteger,
    getPackageEntries = getPackageEntries,
    getEntry = getEntry,
    findEntry = findEntry,
    missingPart = missingPart,
  })
  rawset(Registry, "API", API_GENERATION)
  rawset(Registry, "REVISION", IMPLEMENTATION_REVISION)
  rawset(state, "registryRevision", IMPLEMENTATION_REVISION)
  stateRevision = IMPLEMENTATION_REVISION
end

-- A compatible future revision must preserve this surface. Validating it here
-- makes corrupted or incompatible state fail now, not as a later nil call.
if
  rawget(Registry, "API") ~= API_GENERATION
  or not isBoundedInteger(rawget(Registry, "REVISION"), 1)
  or rawget(Registry, "REVISION") ~= stateRevision
  or type(rawget(Registry, "Register")) ~= "function"
  or type(rawget(Registry, "Get")) ~= "function"
  or type(rawget(Registry, "GetInfo")) ~= "function"
  or type(rawget(Registry, "Find")) ~= "function"
  or type(rawget(Registry, "Packages")) ~= "function"
  or type(rawget(Registry, "OnRetire")) ~= "function"
  or type(rawget(Registry, "Bootstrap")) ~= "function"
  or type(rawget(Registry, "HasPart")) ~= "function"
then
  error("Registry: facade is corrupted or incompatible", 0)
end

-- Public namespace --------------------------------------------------------

-- The public MoltenCodes namespace is the documented global entry point for consumers.
local namespace = rawget(globals, PUBLIC_NAMESPACE_KEY)
if type(namespace) == "nil" then
  namespace = {}
  -- The first copy to load creates that documented public namespace.
  rawset(globals, PUBLIC_NAMESPACE_KEY, namespace)
elseif type(namespace) ~= "table" then
  error("Registry: MoltenCodes global namespace is owned by an incompatible value", 0)
end

-- Generation-exact publication. A consumer written against one Registry API
-- generation reads `MoltenCodes.Registries[<generation>]` and is therefore never
-- handed a different contract, whichever generation owns the alias.
local generations = rawget(namespace, PUBLIC_GENERATIONS_KEY)
if type(generations) == "nil" then
  generations = {}
  rawset(namespace, PUBLIC_GENERATIONS_KEY, generations)
elseif type(generations) ~= "table" then
  error("Registry: MoltenCodes.Registries is owned by an incompatible value", 0)
end

local publishedGeneration = rawget(generations, API_GENERATION)
if type(publishedGeneration) ~= "nil" and publishedGeneration ~= Registry then
  error("Registry: MoltenCodes.Registries[" .. API_GENERATION .. "] is not this facade", 0)
end
rawset(generations, API_GENERATION, Registry)

-- `MoltenCodes.Registry` is an alias for the newest generation that has loaded.
-- Claiming or yielding it is deliberately silent: a generation mismatch is a
-- migration state, not a corruption, and must never abort either addon's load.
local aliased = rawget(namespace, PUBLIC_ALIAS_KEY)
if type(aliased) == "nil" or aliased == Registry then
  rawset(namespace, PUBLIC_ALIAS_KEY, Registry)
else
  local aliasedApi = nil
  if type(aliased) == "table" then
    aliasedApi = rawget(aliased, "API")
  end
  if not isBoundedInteger(aliasedApi, 1) then
    error("Registry: MoltenCodes.Registry is owned by an incompatible value", 0)
  end
  if aliasedApi == API_GENERATION then
    -- Same generation, different table: the bootstrap state above proved
    -- this facade is the shared one, so the alias cannot also be correct.
    local claim = "Registry: MoltenCodes.Registry claims API " .. API_GENERATION
    error(claim .. " but is not the shared facade", 0)
  end
  if aliasedApi < API_GENERATION then
    -- Park the displaced generation under its own key. Generations older
    -- than this one predate `MoltenCodes.Registries` and would otherwise
    -- become unreachable the moment this copy claims the alias.
    if type(rawget(generations, aliasedApi)) == "nil" then
      rawset(generations, aliasedApi, aliased)
    end
    rawset(namespace, PUBLIC_ALIAS_KEY, Registry)
  end

  -- A newer generation already owns the alias. This copy stays fully usable
  -- through `MoltenCodes.Registries[API_GENERATION]` and returns normally.
end

return Registry
