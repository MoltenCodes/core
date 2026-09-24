-- MoltenCodes ApiKit
--
-- The facade of the flavour-aware wrapper over the World of Warcraft API. The
-- wrapper itself is data: one generated file per client flavour
-- (`flavours/<Flavour>.lua`) that binds every documented Blizzard function to
-- a readable name by direct alias. This file is the small handwritten part:
-- it publishes the namespace tables (`MoltenCodes.wow.retail.api` and the
-- others), detects which flavour the running client is, and runs the one
-- generated installer that matches it. Everything else is in
-- `docs/API_KIT_DESIGN.md`.
--
-- ApiKit requires Registry and nothing else. It holds no growing state, so it
-- has no limits to open (design constitution, principle 4a).
--
-- Contents
-- --------
--   Constants ............. package identity, the flavour table
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry
--   Validation ............ public-surface and shared-state validation
--   Bootstrap ............. Registry registration and inherited state
--   Host probing .......... which flavour the running client is
--   Namespace tables ...... `MoltenCodes.wow` and the `wow` global
--   Package public API .... GetFlavor, GetGlobalStatus, RegisterFlavor,
--                           GetMetadataBuild
--   Commit ................ facade assignment and self-check

local PACKAGE_NAME = "apiKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 2
local REQUIRED_REGISTRY_API = 2
local STATE_SCHEMA = 1

-- The name of the short global the design brief's preferred usage relies on
-- (`local api = wow.retail.api`). It is published only when nothing else owns
-- it; `MoltenCodes.wow` is always there.
local SHORT_GLOBAL_NAME = "wow"

-- The host globals the flavour is derived from. `WOW_PROJECT_ID` separates
-- Retail from the Classic clients; the two probes separate Retail from its
-- test realm and beta builds. They are the probes `tooling/api/flavours.json`
-- names, and `tests/FlavourTable_spec.lua` holds this file to that table.
local PROJECT_ID_GLOBAL = "WOW_PROJECT_ID"
local TEST_BUILD_PROBE = "IsTestBuild"
local BETA_BUILD_PROBE = "IsBetaBuild"

-- The flavour a client matches when its facts fit no row below.
local UNSUPPORTED_FLAVOR = "unsupported"

-- Retail's `WOW_PROJECT_ID`: the one project whose test realm and beta builds
-- are flavours of their own, so the build facts are consulted for it alone.
local RETAIL_PROJECT_ID = 1

-- The supported flavours, in the order `tooling/api/flavours.json` lists them:
-- the flavour id, the segments of its namespace under `MoltenCodes.wow`, and
-- the facts a client of that flavour reports. Every row states all three
-- facts, so a client matches exactly one row or none.
local FLAVORS = {
    { id = "retail", path = { "retail" }, projectId = 1, testBuild = false, betaBuild = false },
    {
        id = "classic-era",
        path = { "classic", "era" },
        projectId = 2,
        testBuild = false,
        betaBuild = false,
    },
    {
        id = "classic-mop",
        path = { "classic", "mop" },
        projectId = 19,
        testBuild = false,
        betaBuild = false,
    },
    { id = "ptr", path = { "ptr" }, projectId = 1, testBuild = true, betaBuild = false },
    { id = "beta", path = { "beta" }, projectId = 1, testBuild = true, betaBuild = true },
}

local FLAVOR_BY_ID = {}
for index = 1, #FLAVORS do
    FLAVOR_BY_ID[FLAVORS[index].id] = FLAVORS[index]
end

-- Public types --------------------------------------------------------------

---A supported client flavour id, or `"unsupported"` for a client whose facts
---fit none (a Burning Crusade Classic client, for example).
---@alias ApiKit.Flavor "retail"|"classic-era"|"classic-mop"|"ptr"|"beta"|"unsupported"

---Whether the short `wow` global names `MoltenCodes.wow`.
---@alias ApiKit.GlobalStatus "published"|"taken"

---What a generated flavour file says about the metadata it was generated from.
---@class ApiKit.FlavorInfo
---@field version string? The client version the metadata was captured from (`"12.1.0"`).
---@field build integer? The client build the metadata was captured from.

---The installer a generated flavour file hands to `RegisterFlavor`. It fills
---`api` with direct aliases read from `host`, the global table.
---@alias ApiKit.Installer fun(api: table, host: table)

---The ApiKit package facade published through Registry.
---@class ApiKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field SUPPORTED_FLAVORS string[] Read-only view of the supported flavour ids, in table order; index from 1 to `SUPPORTED_FLAVOR_COUNT` (`#` and `ipairs` do not see through the view on Lua 5.1).
---@field SUPPORTED_FLAVOR_COUNT integer How many flavour ids `SUPPORTED_FLAVORS` holds.
---@field GetFlavor fun(self: ApiKit): ApiKit.Flavor
---@field GetGlobalStatus fun(self: ApiKit): ApiKit.GlobalStatus
---@field RegisterFlavor fun(self: ApiKit, flavor: string, install: ApiKit.Installer, info: ApiKit.FlavorInfo?): boolean
---@field GetMetadataBuild fun(self: ApiKit, flavor: string): string?, integer?

-- Dependencies --------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil

-- Ask for Registry by generation and fall back to the alias. A future Registry
-- API generation takes over `MoltenCodes.Registry`, so reading the alias first
-- would hand this file a facade whose contract it was not written against.
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
if type(Registry) == "nil" and type(namespace) == "table" then
    Registry = rawget(namespace, "Registry")
end
if type(Registry) ~= "table" or rawget(Registry, "API") ~= REQUIRED_REGISTRY_API then
    error("MoltenCodes ApiKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
if type(bootstrapPackage) ~= "function" then
    error("MoltenCodes ApiKit requires a valid Registry API 2 facade", 2)
end

-- Validation ----------------------------------------------------------------

---Whether `implementation` exposes the complete ApiKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
    return type(implementation) == "table"
        and rawget(implementation, "API") == API_GENERATION
        and type(rawget(implementation, "REVISION")) == "number"
        and type(rawget(implementation, "SUPPORTED_FLAVORS")) == "table"
        and type(rawget(implementation, "SUPPORTED_FLAVOR_COUNT")) == "number"
        and type(rawget(implementation, "GetFlavor")) == "function"
        and type(rawget(implementation, "GetGlobalStatus")) == "function"
        and type(rawget(implementation, "RegisterFlavor")) == "function"
        and type(rawget(implementation, "GetMetadataBuild")) == "function"
end

---Whether `currentState` has the fields every API 1 revision shares.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
    return type(currentState) == "table"
        and rawget(currentState, "schema") == STATE_SCHEMA
        and type(rawget(currentState, "root")) == "table"
        and type(rawget(currentState, "apis")) == "table"
        and type(rawget(currentState, "installed")) == "table"
        and type(rawget(currentState, "info")) == "table"
        and type(rawget(currentState, "supportedFlavors")) == "table"
        and type(rawget(currentState, "supportedFlavorsView")) == "table"
end

---Whether `implementation` carries package state of this revision's schema.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
    return validateStateBase(rawget(implementation, "_state"))
end

-- Bootstrap -----------------------------------------------------------------

local ApiKit, previousRevision, selected = bootstrapPackage(Registry, {
    package = PACKAGE_NAME,
    api = API_GENERATION,
    revision = IMPLEMENTATION_REVISION,
    label = "MoltenCodes ApiKit",
    validatePublicSurface = validatePublicSurface,
    validateState = validateCurrentState,
})

if ApiKit == nil then
    -- Equal or newer compatible revision already owns the shared package table.
    return selected
end

-- Host probing --------------------------------------------------------------

---Read one client global.
---@param name string
---@return any
local function readGlobal(name)
    -- The World of Warcraft client API is reachable only through the global table.
    -- selene: allow(global_usage)
    return rawget(_G, name)
end

---Call a boolean probe of the host, treating a missing probe as `false`.
---
---A client that predates `IsBetaBuild` is not a beta client; a probe that is
---not a function says the same.
---@param name string
---@return boolean
local function probeBoolean(name)
    local probe = readGlobal(name)
    if type(probe) ~= "function" then
        return false
    end
    return probe() == true
end

---Derive the flavour id from the host's facts.
---
---The build facts (`IsTestBuild`, `IsBetaBuild`) only separate Retail from
---its test realm and beta builds, which have flavours of their own. A Classic
---test realm has none: its client runs the Classic flavour's surface, so for a
---project id other than Retail's the facts are not consulted and the row is
---matched on the project id alone. A beta client is a test build whatever
---`IsTestBuild` says about it, so the beta probe folds into the test probe
---before the comparison.
---@return string flavorId one of the `FLAVORS` ids, or `UNSUPPORTED_FLAVOR`
local function probeFlavor()
    local projectId = readGlobal(PROJECT_ID_GLOBAL)
    if type(projectId) ~= "number" then
        return UNSUPPORTED_FLAVOR
    end
    local betaBuild = probeBoolean(BETA_BUILD_PROBE)
    local testBuild = betaBuild or probeBoolean(TEST_BUILD_PROBE)
    for index = 1, #FLAVORS do
        local row = FLAVORS[index]
        if row.projectId == projectId then
            local buildFactsApply = projectId == RETAIL_PROJECT_ID
            if
                not buildFactsApply or (row.testBuild == testBuild and row.betaBuild == betaBuild)
            then
                return row.id
            end
        end
    end
    return UNSUPPORTED_FLAVOR
end

-- Namespace tables ----------------------------------------------------------

---Build `MoltenCodes.wow`: one `api` table per flavour, reached through the
---flavour's path (`root.classic.era.api`). Every flavour's table exists on
---every client, so indexing another flavour's namespace yields an empty table
---rather than an error; only the running flavour's table is ever filled.
---@return table root, table<string, table> apis the `api` table of each flavour id
local function buildNamespaceRoot()
    local root = {}
    local apis = {}
    for index = 1, #FLAVORS do
        local row = FLAVORS[index]
        local node = root
        for segment = 1, #row.path do
            local key = row.path[segment]
            local child = rawget(node, key)
            if child == nil then
                child = {}
                rawset(node, key, child)
            end
            node = child
        end
        local api = {}
        rawset(node, "api", api)
        apis[row.id] = api
    end
    return root, apis
end

---Refuse every write to `ApiKit.SUPPORTED_FLAVORS`.
---@param _ table
---@param key any
local function refuseSupportedFlavorsWrite(_, key)
    error(
        'ApiKit.SUPPORTED_FLAVORS is read-only; index "' .. tostring(key) .. '" cannot be written',
        2
    )
end

---Publish `root` as the short global when nothing else owns that name.
---
---`wow` is generic enough that another addon may use it, and the framework
---never fights for a global: an existing value is left alone, and
---`MoltenCodes.wow` remains the way in. Whether the global names the root is
---read live by `GetGlobalStatus`, so a later replacement is reported too.
---@param root table
local function publishShortGlobal(root)
    -- selene: allow(global_usage)
    if type(rawget(_G, SHORT_GLOBAL_NAME)) == "nil" then
        -- selene: allow(global_usage)
        rawset(_G, SHORT_GLOBAL_NAME, root)
    end
end

---Make `MoltenCodes.wow` the root, refusing to overwrite something else.
---
---The namespace table is the framework's own, so a foreign value under `wow`
---there is corruption rather than a coexistence case: a consumer reading
---`MoltenCodes.wow.retail.api` must never be handed another table.
---@param root table
local function publishNamespaceRoot(root)
    if type(namespace) ~= "table" then
        return
    end
    local existing = rawget(namespace, SHORT_GLOBAL_NAME)
    if type(existing) == "nil" then
        rawset(namespace, SHORT_GLOBAL_NAME, root)
    elseif existing ~= root then
        error("MoltenCodes ApiKit found MoltenCodes.wow owned by something else", 2)
    end
end

local state = rawget(ApiKit, "_state")

if previousRevision == nil then
    if state ~= nil then
        error("MoltenCodes ApiKit package state is corrupted or incomplete", 2)
    end
    local root, apis = buildNamespaceRoot()
    local supportedFlavors = {}
    for index = 1, #FLAVORS do
        supportedFlavors[index] = FLAVORS[index].id
    end
    state = {
        schema = STATE_SCHEMA,
        flavor = UNSUPPORTED_FLAVOR,
        root = root,
        apis = apis,
        -- Per flavour id: `true` once its installer has run.
        installed = {},
        -- Per flavour id: the `info` its registration carried (`false` for none).
        info = {},
        supportedFlavors = supportedFlavors,
        supportedFlavorsView = setmetatable({}, {
            __index = supportedFlavors,
            __newindex = refuseSupportedFlavorsWrite,
            __metatable = false,
        }),
    }
    rawset(ApiKit, "_state", state)
    publishShortGlobal(root)
    publishNamespaceRoot(root)
elseif not validateStateBase(state) then
    error("MoltenCodes ApiKit package state is corrupted or incomplete", 2)
end

-- The flavour is probed on every bootstrap, first load and upgrade alike, as
-- ClientKit does: a newer revision that knows a flavour this one does not can
-- then recognise a client this one called unsupported. Installed flavours are
-- keyed by id, so a re-probe never runs an installer twice. A revision that
-- adds a flavour extends `FLAVORS` here and adds the new `api` table to `root`
-- and `apis` in place when they lack it.
rawset(state, "flavor", probeFlavor())

-- Package public API ----------------------------------------------------------

---Validate that `self` is the facade, at the caller's level.
---@param self any
---@param methodName string
local function validateReceiver(self, methodName)
    if self ~= ApiKit then
        error("ApiKit:" .. methodName .. " must be called on the ApiKit facade", 3)
    end
end

---Validate a flavour id argument, at the caller's level.
---@param flavor any
---@param methodName string
---@return table row
local function validateFlavorArgument(flavor, methodName)
    local row = type(flavor) == "string" and FLAVOR_BY_ID[flavor] or nil
    if row == nil then
        error(
            "ApiKit:"
                .. methodName
                .. " flavor must be one of "
                .. table.concat(rawget(state, "supportedFlavors"), ", "),
            3
        )
    end
    return row
end

---Validate the optional `info` table of a registration, at the caller's level.
---@param info any
---@return table|false
local function validateInfoArgument(info)
    if type(info) == "nil" then
        return false
    end
    if type(info) ~= "table" then
        error("ApiKit:RegisterFlavor info must be a table when given", 3)
    end
    local version = rawget(info, "version")
    local build = rawget(info, "build")
    if type(version) ~= "nil" and type(version) ~= "string" then
        error("ApiKit:RegisterFlavor info.version must be a string when given", 3)
    end
    if type(build) ~= "nil" and (type(build) ~= "number" or build % 1 ~= 0) then
        error("ApiKit:RegisterFlavor info.build must be an integer when given", 3)
    end
    return { version = version, build = build }
end

---Return the flavour of the running client.
---@param self ApiKit
---@return ApiKit.Flavor
local function packageGetFlavor(self)
    validateReceiver(self, "GetFlavor")
    return rawget(state, "flavor")
end

---Return whether the short `wow` global names `MoltenCodes.wow`, read live.
---@param self ApiKit
---@return ApiKit.GlobalStatus
local function packageGetGlobalStatus(self)
    validateReceiver(self, "GetGlobalStatus")
    -- selene: allow(global_usage)
    if rawget(_G, SHORT_GLOBAL_NAME) == rawget(state, "root") then
        return "published"
    end
    return "taken"
end

---Register a flavour's installer; the entry point every generated flavour
---file calls.
---
---The installer runs at once, and only, when `flavor` is the running client's
---flavour and no installer has run for it yet: the first file to arrive fills
---the namespace, a second copy of the same flavour (two addons embedding it)
---is dropped, and a file for another flavour costs nothing beyond this call.
---Whatever the installer raises propagates to the generated file's load, so a
---broken generated file is loud rather than half-installed and silent; the
---flavour's table is emptied and its registration forgotten first, so a later
---copy (another addon's working file) starts clean. `info` is recorded for
---`GetMetadataBuild` whether or not the installer runs, the first registration
---of a flavour winning; unknown `info` fields are ignored, so a file from a
---newer generator still registers.
---@param self ApiKit
---@param flavor string
---@param install ApiKit.Installer
---@param info ApiKit.FlavorInfo?
---@return boolean installed whether the installer ran
local function packageRegisterFlavor(self, flavor, install, info)
    validateReceiver(self, "RegisterFlavor")
    local row = validateFlavorArgument(flavor, "RegisterFlavor")
    if type(install) ~= "function" then
        error("ApiKit:RegisterFlavor install must be a function", 2)
    end
    local recordedInfo = validateInfoArgument(info)

    local infoTable = rawget(state, "info")
    if rawget(infoTable, row.id) == nil then
        rawset(infoTable, row.id, recordedInfo)
    end

    local installedTable = rawget(state, "installed")
    if row.id ~= rawget(state, "flavor") or rawget(installedTable, row.id) == true then
        return false
    end
    rawset(installedTable, row.id, true)
    local api = rawget(rawget(state, "apis"), row.id)
    -- The host is the global table: every alias the installer makes is read from it.
    -- selene: allow(global_usage)
    local ok, failure = pcall(install, api, _G)
    if not ok then
        for key in pairs(api) do
            rawset(api, key, nil)
        end
        rawset(installedTable, row.id, nil)
        rawset(infoTable, row.id, nil)
        error(failure, 0)
    end
    return true
end

---Return the client version and build the registered metadata of `flavor`
---was captured from, or nothing when no flavour file registered.
---@param self ApiKit
---@param flavor string
---@return string? version
---@return integer? build
local function packageGetMetadataBuild(self, flavor)
    validateReceiver(self, "GetMetadataBuild")
    local row = validateFlavorArgument(flavor, "GetMetadataBuild")
    local recorded = rawget(rawget(state, "info"), row.id)
    if type(recorded) ~= "table" then
        return nil, nil
    end
    return rawget(recorded, "version"), rawget(recorded, "build")
end

-- Commit -------------------------------------------------------------------

rawset(ApiKit, "API", API_GENERATION)
rawset(ApiKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(ApiKit, "SUPPORTED_FLAVORS", rawget(state, "supportedFlavorsView"))
rawset(ApiKit, "SUPPORTED_FLAVOR_COUNT", #rawget(state, "supportedFlavors"))
rawset(ApiKit, "GetFlavor", packageGetFlavor)
rawset(ApiKit, "GetGlobalStatus", packageGetGlobalStatus)
rawset(ApiKit, "RegisterFlavor", packageRegisterFlavor)
rawset(ApiKit, "GetMetadataBuild", packageGetMetadataBuild)

if not validatePublicSurface(ApiKit) or not validateCurrentState(ApiKit) then
    error("MoltenCodes ApiKit package state is corrupted or incomplete", 2)
end

return ApiKit
