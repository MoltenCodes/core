-- MoltenCodes Registry
--
-- Zero-dependency bootstrap resolver for independently embedded framework
-- packages. The core invariants are: one shared facade per Registry API
-- generation, one stable implementation table per (package, API) pair, and
-- highest-revision-wins selection without replacing shared table identity.
--
-- Registry generations publish side by side. Every generation owns a private
-- bootstrap state keyed by its own generation number and publishes itself at
-- `MoltenCodes.Registries[<generation>]`. `MoltenCodes.Registry` is an alias for
-- the newest generation present, so loading a second generation never aborts the
-- load of an addon that embedded the other one.

local GLOBAL_STATE_KEY = "__MOLTENCODES_REGISTRY_STATE_V2"
local PUBLIC_NAMESPACE_KEY = "MoltenCodes"
local PUBLIC_GENERATIONS_KEY = "Registries"
local PUBLIC_ALIAS_KEY = "Registry"

local STATE_SCHEMA = 1
local API_GENERATION = 2
local IMPLEMENTATION_REVISION = 6

-- Lua 5.1 numbers are doubles, which represent consecutive integers exactly only
-- up to 2^53. Past that boundary distinct values start comparing equal, so a
-- revision such as `1e300` would silently become an unbeatable revision that no
-- future embedded copy could ever replace. Identifiers are therefore bounded.
local MAXIMUM_INTEGER = 2 ^ 53
local MAXIMUM_INTEGER_TEXT = "2^53"

-- Validation ---------------------------------------------------------------

---Whether `value` is a number that represents an exact integer in range.
---
---`nan` fails the `% 1` comparison and both infinities fail the bound, so no
---explicit special-casing is required.
---@param value any
---@return boolean
local function isBoundedInteger(value)
    return type(value) == "number"
        and value % 1 == 0
        and value <= MAXIMUM_INTEGER
        and value >= -MAXIMUM_INTEGER
end

---Whether `value` is an exact integer greater than zero and within range.
---@param value any
---@return boolean
local function isPositiveInteger(value)
    return isBoundedInteger(value) and value > 0
end

---Whether `value` is an exact integer of zero or more and within range.
---@param value any
---@return boolean
local function isNonNegativeInteger(value)
    return isBoundedInteger(value) and value >= 0
end

---@param packageName any
---@param methodName string
local function validatePackageName(packageName, methodName)
    if type(packageName) ~= "string" or packageName == "" then
        error("Registry:" .. methodName .. " packageName must be a non-empty string", 3)
    end

    if not string.match(packageName, "^[a-z][A-Za-z0-9]*$") then
        error("Registry:" .. methodName .. " packageName must match ^[a-z][A-Za-z0-9]*$", 3)
    end
end

---@param api any
---@param methodName string
local function validateApi(api, methodName)
    if not isPositiveInteger(api) then
        error(
            "Registry:"
                .. methodName
                .. " api must be a positive integer up to "
                .. MAXIMUM_INTEGER_TEXT,
            3
        )
    end
end

---@param revision any
local function validateRevision(revision)
    if not isPositiveInteger(revision) then
        error(
            "Registry:Register revision must be a positive integer up to " .. MAXIMUM_INTEGER_TEXT,
            3
        )
    end
end

-- Bootstrap state ---------------------------------------------------------
--
-- Everything below runs at file scope, where the "caller" is whichever addon TOC
-- happens to be loading this file. A stack level would therefore point at an
-- arbitrary consumer line, so load-time failures use level 0 and carry an
-- explicit `Registry:` prefix instead.

-- Independently embedded Registry copies find each other only through this global key.
-- selene: allow(global_usage)
local state = rawget(_G, GLOBAL_STATE_KEY)

if state == nil then
    state = {
        schema = STATE_SCHEMA,
        registryApi = API_GENERATION,
        registryRevision = 0,
        entries = {},
        facade = {},
    }
    -- The first copy to load publishes the shared state under that same global key.
    -- selene: allow(global_usage)
    rawset(_G, GLOBAL_STATE_KEY, state)
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
    not isNonNegativeInteger(stateRevision)
    or type(entries) ~= "table"
    or type(facade) ~= "table"
then
    error("Registry: bootstrap state is corrupted", 0)
end

-- Package-state access ----------------------------------------------------

---@param packageName string
---@return table|nil
local function getPackageEntries(packageName)
    local packageEntries = rawget(entries, packageName)
    if packageEntries ~= nil and type(packageEntries) ~= "table" then
        error("Registry: package state is corrupted", 3)
    end

    return packageEntries
end

---@param packageEntries table
---@param api integer
---@return table|nil
local function getEntry(packageEntries, api)
    local entry = rawget(packageEntries, api)
    if entry == nil then
        return nil
    end

    if
        type(entry) ~= "table"
        or not isPositiveInteger(rawget(entry, "revision"))
        or type(rawget(entry, "implementation")) ~= "table"
    then
        error("Registry: package state is corrupted", 3)
    end

    return entry
end

-- Shared facade -----------------------------------------------------------

---Metadata snapshot returned by `Registry:GetInfo`.
---@class Registry.PackageInfo
---@field ["package"] string Package identifier the snapshot describes.
---@field api integer API generation the snapshot describes.
---@field revision integer Currently selected implementation revision.
---@field implementation table The live shared package table.

---Everything `Registry:Bootstrap` needs in order to reconcile one embedded copy.
---
---`package`, `api` and `revision` are the package's own identity. `label` is the
---human-readable prefix Registry puts in front of the failures it raises on the
---package's behalf, so an addon author sees which package refused to load.
---@class Registry.BootstrapRequest
---@field ["package"] string Package identifier, as in `Registry:Register`.
---@field api integer API generation this copy implements.
---@field revision integer Implementation revision this copy carries.
---@field label string Error-message prefix, for example `"MoltenCodes SignalKit"`.
---@field validatePublicSurface fun(implementation: any): boolean Whether a table exposes the complete public API of this generation.
---@field validateState (fun(implementation: table): boolean)? Whether a same-revision copy already finished committing its private state.
---@field resume (fun(implementation: table, complete: boolean): integer|nil)? Same-revision repair hook; see `Registry:Bootstrap`.

---The Registry facade shared by every compatible embedded copy.
---@class Registry
---@field API integer Registry API generation this facade implements.
---@field REVISION integer Registry implementation revision currently installed.
---@field Register fun(self: Registry, packageName: string, api: integer, revision: integer): table|nil, integer|nil
---@field Get fun(self: Registry, packageName: string, api: integer): table|nil, integer|nil
---@field GetInfo fun(self: Registry, packageName: string, api: integer): Registry.PackageInfo|nil
---@field Bootstrap fun(self: Registry, request: Registry.BootstrapRequest): table|nil, integer|nil, table|nil

---@type Registry
local Registry = facade

-- Every compatible embedded Registry copy shares this facade. A newer
-- implementation revision replaces methods on the same table, so references
-- acquired from older compatible copies continue to point at the upgraded
-- Registry facade.
if stateRevision < IMPLEMENTATION_REVISION then
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

        validatePackageName(packageName, "Register")
        validateApi(api, "Register")
        validateRevision(revision)

        local packageEntries = getPackageEntries(packageName)
        if packageEntries == nil then
            packageEntries = {}
            rawset(entries, packageName, packageEntries)
        end

        local entry = getEntry(packageEntries, api)
        if entry == nil then
            local implementation = {}
            rawset(packageEntries, api, {
                revision = revision,
                implementation = implementation,
            })
            return implementation, nil
        end

        local currentRevision = rawget(entry, "revision")
        if revision <= currentRevision then
            return nil
        end

        rawset(entry, "revision", revision)

        -- The implementation table is intentionally never replaced. Packages
        -- upgrade this shared table in place so consumers holding older
        -- references immediately observe the newer revision.
        return rawget(entry, "implementation"), currentRevision
    end

    ---Returns the selected shared package table and its revision.
    ---@param packageName string
    ---@param api integer
    ---@return table|nil implementation
    ---@return integer|nil revision
    local function get(_, packageName, api)
        validatePackageName(packageName, "Get")
        validateApi(api, "Get")

        local packageEntries = getPackageEntries(packageName)
        if packageEntries == nil then
            return nil
        end

        local entry = getEntry(packageEntries, api)
        if entry == nil then
            return nil
        end

        return rawget(entry, "implementation"), rawget(entry, "revision")
    end

    ---Returns a freshly allocated metadata snapshot for one registration.
    ---@param packageName string
    ---@param api integer
    ---@return Registry.PackageInfo|nil
    local function getInfo(_, packageName, api)
        validatePackageName(packageName, "GetInfo")
        validateApi(api, "GetInfo")

        local packageEntries = getPackageEntries(packageName)
        if packageEntries == nil then
            return nil
        end

        local entry = getEntry(packageEntries, api)
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

    ---@param field any
    ---@param fieldName string
    local function validateBootstrapFunction(field, fieldName)
        if field ~= nil and type(field) ~= "function" then
            error("Registry:Bootstrap request." .. fieldName .. " must be a function", 3)
        end
    end

    ---Perform the reconciliation every embedded package repeats verbatim.
    ---
    ---A package bootstrap always answers the same three questions in the same
    ---order: does a copy of this `(package, api)` pair already exist, is it
    ---newer than this one, and did the copy that registered this same revision
    ---actually finish. Getting that order wrong is how an older embedded copy
    ---reinterprets private state it does not own, so the order lives here once
    ---rather than in every package.
    ---
    ---The three return values are what the caller needs to finish:
    ---
    ---* `implementation` is the shared package table to initialize. When it is
    ---  `nil` the caller is done and must `return selected` unchanged.
    ---* `previousRevision` is `nil` for a first registration and otherwise the
    ---  revision whose state this copy inherits, exactly as `Registry:Register`
    ---  reports it.
    ---* `selected` is the copy Registry has selected, which is what the caller
    ---  returns when `implementation` is `nil`.
    ---
    ---`validateState` describes what "finished" means for a copy that carries
    ---this exact revision. Without it, a same-revision copy that passed
    ---`validatePublicSurface` is taken as complete.
    ---
    ---`resume` is the escape hatch for packages whose bootstrap installs shared
    ---runtime state that a failed earlier attempt can leave half-built. It runs
    ---only when Registry already holds this exact revision, receives whether
    ---that copy looks complete, and returns either `nil` to accept the copy as
    ---it is, or the revision to inherit so the caller re-runs its own setup
    ---against the existing shared table. It may also raise on state it judges
    ---unrepairable.
    ---
    ---Registry never calls this helper for itself: it is the file that
    ---publishes the facade the helper lives on, so its own bootstrap has to run
    ---before any facade method exists.
    ---@param request Registry.BootstrapRequest
    ---@return table|nil implementation
    ---@return integer|nil previousRevision
    ---@return table|nil selected
    local function bootstrap(self, request)
        if type(request) ~= "table" then
            error("Registry:Bootstrap request must be a table", 2)
        end

        local packageName = rawget(request, "package")
        local api = rawget(request, "api")
        local revision = rawget(request, "revision")
        local label = rawget(request, "label")
        local validatePublicSurface = rawget(request, "validatePublicSurface")
        local validateState = rawget(request, "validateState")
        local resume = rawget(request, "resume")

        validatePackageName(packageName, "Bootstrap")
        validateApi(api, "Bootstrap")
        if not isPositiveInteger(revision) then
            error(
                "Registry:Bootstrap revision must be a positive integer up to "
                    .. MAXIMUM_INTEGER_TEXT,
                2
            )
        end
        if type(label) ~= "string" or label == "" then
            error("Registry:Bootstrap request.label must be a non-empty string", 2)
        end
        if type(validatePublicSurface) ~= "function" then
            error("Registry:Bootstrap request.validatePublicSurface must be a function", 2)
        end
        validateBootstrapFunction(validateState, "validateState")
        validateBootstrapFunction(resume, "resume")

        -- Level 3 points at the package file that called `Registry:Bootstrap`,
        -- which is the caller of this helper: level 1 is `refuse` itself and
        -- level 2 is `bootstrap`.
        local function refuse(reason)
            error(label .. " " .. reason, 3)
        end

        local existing, existingRevision = get(self, packageName, api)
        if existing ~= nil then
            if type(existing) ~= "table" or rawget(existing, "API") ~= api then
                refuse("package state is corrupted or incomplete")
            end

            -- The facade publishes its revision only once it has committed the
            -- matching implementation, so a facade claiming to be newer than
            -- the revision Registry accepted cannot be trusted at all.
            local facadeRevision = rawget(existing, "REVISION")
            if type(facadeRevision) ~= "number" or facadeRevision > existingRevision then
                refuse("package state is corrupted or incomplete")
            end

            if existingRevision > revision then
                -- A newer compatible embedded revision owns its own private
                -- state schema. Older copies validate the stable API surface
                -- and must not reinterpret state they do not understand.
                if facadeRevision ~= existingRevision or not validatePublicSurface(existing) then
                    refuse("package state is corrupted or incomplete")
                end
                return nil, nil, existing
            end

            -- An older revision is deliberately not held to this revision's
            -- public surface. It is about to be upgraded in place, and the
            -- caller validates whatever it inherits before it reuses it.
            if existingRevision == revision then
                if not validatePublicSurface(existing) then
                    refuse("package state is corrupted or incomplete")
                end

                local complete = facadeRevision == existingRevision
                    and (validateState == nil or validateState(existing) == true)

                if resume ~= nil then
                    local inherited = resume(existing, complete)
                    if inherited ~= nil then
                        if not isPositiveInteger(inherited) and inherited ~= 0 then
                            error("Registry:Bootstrap request.resume must return a revision", 2)
                        end
                        return existing, inherited, existing
                    end
                    return nil, nil, existing
                end

                if not complete then
                    refuse("package state is corrupted or incomplete")
                end
                return nil, nil, existing
            end
        end

        local implementation, previousRevision = register(self, packageName, api, revision)
        if implementation == nil then
            -- An equal or newer compatible revision owns the shared table.
            return nil, nil, existing
        end

        if previousRevision ~= existingRevision then
            refuse("Registry state changed unexpectedly during bootstrap")
        end

        return implementation, previousRevision, existing
    end

    rawset(Registry, "Register", register)
    rawset(Registry, "Get", get)
    rawset(Registry, "GetInfo", getInfo)
    rawset(Registry, "Bootstrap", bootstrap)
    rawset(Registry, "API", API_GENERATION)
    rawset(Registry, "REVISION", IMPLEMENTATION_REVISION)
    rawset(state, "registryRevision", IMPLEMENTATION_REVISION)
    stateRevision = IMPLEMENTATION_REVISION
end

-- A compatible future implementation revision must preserve this public
-- surface. Validate it after bootstrap so corrupted or incompatible state fails
-- deterministically instead of producing delayed nil-call errors elsewhere.
if
    rawget(Registry, "API") ~= API_GENERATION
    or not isPositiveInteger(rawget(Registry, "REVISION"))
    or rawget(Registry, "REVISION") ~= stateRevision
    or type(rawget(Registry, "Register")) ~= "function"
    or type(rawget(Registry, "Get")) ~= "function"
    or type(rawget(Registry, "GetInfo")) ~= "function"
    or type(rawget(Registry, "Bootstrap")) ~= "function"
then
    error("Registry: facade is corrupted or incompatible", 0)
end

-- Public namespace --------------------------------------------------------

-- The public MoltenCodes namespace is the documented global entry point for consumers.
-- selene: allow(global_usage)
local namespace = rawget(_G, PUBLIC_NAMESPACE_KEY)
if namespace == nil then
    namespace = {}
    -- The first copy to load creates that documented public namespace.
    -- selene: allow(global_usage)
    rawset(_G, PUBLIC_NAMESPACE_KEY, namespace)
elseif type(namespace) ~= "table" then
    error("Registry: MoltenCodes global namespace is owned by an incompatible value", 0)
end

-- Generation-exact publication. A consumer written against one Registry API
-- generation reads `MoltenCodes.Registries[<generation>]` and is therefore never
-- handed a different contract, whichever generation owns the alias.
local generations = rawget(namespace, PUBLIC_GENERATIONS_KEY)
if generations == nil then
    generations = {}
    rawset(namespace, PUBLIC_GENERATIONS_KEY, generations)
elseif type(generations) ~= "table" then
    error("Registry: MoltenCodes.Registries is owned by an incompatible value", 0)
end

local publishedGeneration = rawget(generations, API_GENERATION)
if publishedGeneration ~= nil and publishedGeneration ~= Registry then
    error("Registry: MoltenCodes.Registries[" .. API_GENERATION .. "] is not this facade", 0)
end
rawset(generations, API_GENERATION, Registry)

-- `MoltenCodes.Registry` is an alias for the newest generation that has loaded.
-- Claiming or yielding it is deliberately silent: a generation mismatch is a
-- migration state, not a corruption, and must never abort either addon's load.
local aliased = rawget(namespace, PUBLIC_ALIAS_KEY)
if aliased == nil or aliased == Registry then
    rawset(namespace, PUBLIC_ALIAS_KEY, Registry)
else
    local aliasedApi = nil
    if type(aliased) == "table" then
        aliasedApi = rawget(aliased, "API")
    end

    if not isPositiveInteger(aliasedApi) then
        error("Registry: MoltenCodes.Registry is owned by an incompatible value", 0)
    end

    if aliasedApi == API_GENERATION then
        -- Same generation, different table: the bootstrap state above proved
        -- this facade is the shared one, so the alias cannot also be correct.
        error(
            "Registry: MoltenCodes.Registry claims API "
                .. API_GENERATION
                .. " but is not the shared facade",
            0
        )
    end

    if aliasedApi < API_GENERATION then
        -- Park the displaced generation under its own key. Generations older
        -- than this one predate `MoltenCodes.Registries` and would otherwise
        -- become unreachable the moment this copy claims the alias.
        if rawget(generations, aliasedApi) == nil then
            rawset(generations, aliasedApi, aliased)
        end
        rawset(namespace, PUBLIC_ALIAS_KEY, Registry)
    end

    -- A newer generation already owns the alias. This copy stays fully usable
    -- through `MoltenCodes.Registries[API_GENERATION]` and returns normally.
end

return Registry
