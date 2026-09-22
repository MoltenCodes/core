-- MoltenCodes Registry
--
-- Zero-dependency bootstrap resolver for independently embedded framework
-- packages. The core invariants are: one shared facade per Registry API
-- generation, one stable implementation table per (package, API) pair, and
-- highest-revision-wins selection without replacing shared table identity.

local GLOBAL_STATE_KEY = "__MOLTENCODES_REGISTRY_STATE_V2"
local PUBLIC_NAMESPACE_KEY = "MoltenCodes"

local STATE_SCHEMA = 1
local API_GENERATION = 2
local IMPLEMENTATION_REVISION = 4

-- Validation ---------------------------------------------------------------

local function isPositiveInteger(value)
    return type(value) == "number" and value > 0 and value % 1 == 0
end

local function isNonNegativeInteger(value)
    return type(value) == "number" and value >= 0 and value % 1 == 0
end

local function validatePackageName(packageName, methodName)
    if type(packageName) ~= "string" or packageName == "" then
        error("Registry:" .. methodName .. " packageName must be a non-empty string", 3)
    end

    if not string.match(packageName, "^[a-z][A-Za-z0-9]*$") then
        error("Registry:" .. methodName .. " packageName must match ^[a-z][A-Za-z0-9]*$", 3)
    end
end

local function validateApi(api, methodName)
    if not isPositiveInteger(api) then
        error("Registry:" .. methodName .. " api must be a positive integer", 3)
    end
end

local function validateRevision(revision)
    if not isPositiveInteger(revision) then
        error("Registry:Register revision must be a positive integer", 3)
    end
end

-- Bootstrap state ---------------------------------------------------------

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
    error("MoltenCodes Registry bootstrap state is incompatible", 2)
end

local stateSchema = rawget(state, "schema")
local stateApi = rawget(state, "registryApi")
local stateRevision = rawget(state, "registryRevision")
local entries = rawget(state, "entries")
local facade = rawget(state, "facade")

if stateSchema ~= STATE_SCHEMA then
    error("MoltenCodes Registry bootstrap state is incompatible", 2)
end

if stateApi ~= API_GENERATION then
    error("MoltenCodes Registry API generation is incompatible", 2)
end

if
    not isNonNegativeInteger(stateRevision)
    or type(entries) ~= "table"
    or type(facade) ~= "table"
then
    error("MoltenCodes Registry bootstrap state is corrupted", 2)
end

-- Package-state access ----------------------------------------------------

local function getPackageEntries(packageName)
    local packageEntries = rawget(entries, packageName)
    if packageEntries ~= nil and type(packageEntries) ~= "table" then
        error("MoltenCodes Registry package state is corrupted", 3)
    end

    return packageEntries
end

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
        error("MoltenCodes Registry package state is corrupted", 3)
    end

    return entry
end

-- Shared facade -----------------------------------------------------------

local Registry = facade

-- Every compatible embedded Registry copy shares this facade. A newer
-- implementation revision replaces methods on the same table, so references
-- acquired from older compatible copies continue to point at the upgraded
-- Registry facade.
if stateRevision < IMPLEMENTATION_REVISION then
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

    rawset(Registry, "Register", register)
    rawset(Registry, "Get", get)
    rawset(Registry, "GetInfo", getInfo)
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
then
    error("MoltenCodes Registry facade is corrupted or incompatible", 2)
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
    error("MoltenCodes global namespace is owned by an incompatible value", 2)
end

local publishedRegistry = rawget(namespace, "Registry")
if publishedRegistry ~= nil and publishedRegistry ~= Registry then
    local publishedApi = nil
    if type(publishedRegistry) == "table" then
        publishedApi = rawget(publishedRegistry, "API")
    end

    if publishedApi ~= nil then
        error(
            "MoltenCodes.Registry API generation conflict: loaded "
                .. tostring(publishedApi)
                .. ", requested "
                .. tostring(API_GENERATION),
            2
        )
    end

    error("MoltenCodes.Registry is owned by an incompatible value", 2)
end
rawset(namespace, "Registry", Registry)

return Registry
