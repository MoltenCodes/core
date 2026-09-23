-- MoltenCodes InteropKit
--
-- The LibStub bridge. It lets a LibStub consumer find a MoltenCodes Kit with
-- `LibStub("MoltenCodes-EventKit-1")`, and lets MoltenCodes code find a LibStub
-- library (LibDataBroker, LibSharedMedia, CallbackHandler) through one silent
-- lookup that mirrors `Registry:Find`, so an addon that embeds both needs one
-- lookup idiom rather than two.
--
-- The roadmap first placed this bridge inside `registry`. The registry file's
-- 1000-line budget is spent, and its header says the bridge moves into its own
-- package in that case, so it lives here and Registry does not know about it.
--
-- What the bridge does to LibStub's tables is deliberately small and written
-- down in docs/API.md: it calls `LibStub:NewLibrary(major, revision)` so LibStub
-- records the major and its minor the usual way, and then writes the Kit's
-- facade into `LibStub.libs[major]` in place of the empty table LibStub just
-- created. That one write is the only place InteropKit touches LibStub's
-- internals. It never writes a major another library already holds, never
-- lowers a minor, and never touches a LibStub library it adopts.
--
-- Everything is load-time work: nothing here runs per frame and nothing needs
-- tearing down, because LibStub entries are permanent by LibStub's design.
--
-- Contents
-- --------
--   Constants ............. identity, reason vocabulary, default major
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry
--   Bootstrap ............. surface/state validation, registration, state
--   Validation helpers .... argument checks that report at the caller
--   LibStub access ........ presence and the internal tables the bridge needs
--   Package lookup ........ a Kit's facade and revision through Registry
--   Exposing .............. IsLibStubPresent, ExposeToLibStub, ExposeAll
--   Adopting .............. AdoptFromLibStub, Find, Adopted
--   Commit ................ facade assignment and self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "interopKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local STATE_SCHEMA = 1

-- The global LibStub publishes itself under. Read on every call rather than
-- once at load, because LibStub may be loaded by an addon that loads later.
local LIBSTUB_GLOBAL = "LibStub"

-- The prefix of the default LibStub major: `"MoltenCodes-EventKit-1"`.
local DEFAULT_MAJOR_PREFIX = "MoltenCodes-"

-- Package identifiers, as Registry accepts them.
local PACKAGE_NAME_PATTERN = "^[a-z][A-Za-z0-9]*$"

-- The name Registry publishes itself under. It is not an entry of its own
-- package table, so the bridge resolves it through the public namespace.
local REGISTRY_PACKAGE_NAME = "registry"

-- Lua 5.1 numbers are doubles; integers are exact only up to 2^53, the bound
-- Registry uses for API generations.
local MAXIMUM_INTEGER = 2 ^ 53

-- The fixed vocabulary of refusals. See docs/API.md "Results and reasons".
local REASON_ABSENT = "absent"
local REASON_UNKNOWN = "unknown"
local REASON_TAKEN = "taken"
local REASON_UNSUPPORTED = "unsupported"

-- The Registry status of an entry whose copy finished taking over.
local STATUS_ACTIVE = "active"

-- Public types ---------------------------------------------------------------
--
-- InteropKit publishes its methods by writing them onto a Registry-owned facade
-- table, so the editor-facing contract is declared here as LuaCATS classes
-- rather than inferred from those assignments.

---Why an InteropKit call did not do what was asked.
---@alias InteropKit.Reason "absent"|"unknown"|"taken"|"unsupported"

---Options accepted by `InteropKit:ExposeAll`.
---@class InteropKit.ExposeAllOptions
---@field except string[]? Package identifiers to leave out, for example `{ "hookKit" }`.

---One row of the diagnostic listing `InteropKit:Adopted` returns.
---@class InteropKit.AdoptedRow
---@field major string The LibStub major the library was adopted under.
---@field minor number The minor LibStub reported when the library was adopted.

---The InteropKit package facade published through Registry.
---@class InteropKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field IsLibStubPresent fun(self: InteropKit): boolean
---@field ExposeToLibStub fun(self: InteropKit, packageName: string, api: integer, major: string?): boolean, string|InteropKit.Reason, string?
---@field ExposeAll fun(self: InteropKit, options: InteropKit.ExposeAllOptions?): exposed: integer, skipped: integer, refused: integer
---@field AdoptFromLibStub fun(self: InteropKit, major: string): table|nil, number|InteropKit.Reason
---@field Find fun(self: InteropKit, major: string): table|nil, number|InteropKit.Reason
---@field Adopted fun(self: InteropKit): InteropKit.AdoptedRow[]

-- Dependencies ---------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil

-- Ask for Registry by generation and fall back to the alias. A future Registry
-- API generation takes over `MoltenCodes.Registry`, so reading the alias first
-- would hand this file a facade whose contract it was not written against.
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
if Registry == nil and type(namespace) == "table" then
    Registry = rawget(namespace, "Registry")
end
if type(Registry) ~= "table" or rawget(Registry, "API") ~= REQUIRED_REGISTRY_API then
    error("MoltenCodes InteropKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
if
    type(bootstrapPackage) ~= "function"
    or type(rawget(Registry, "Find")) ~= "function"
    or type(rawget(Registry, "Packages")) ~= "function"
then
    error("MoltenCodes InteropKit requires a valid Registry API 2 facade", 2)
end

-- Bootstrap ------------------------------------------------------------------

-- Every method name the facade publishes, used by the surface check.
local PUBLIC_METHODS = {
    "IsLibStubPresent",
    "ExposeToLibStub",
    "ExposeAll",
    "AdoptFromLibStub",
    "Find",
    "Adopted",
}

---Whether `implementation` exposes the complete InteropKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
    if
        type(implementation) ~= "table"
        or rawget(implementation, "API") ~= API_GENERATION
        or type(rawget(implementation, "REVISION")) ~= "number"
    then
        return false
    end

    for index = 1, #PUBLIC_METHODS do
        if type(rawget(implementation, PUBLIC_METHODS[index])) ~= "function" then
            return false
        end
    end
    return true
end

---Whether `currentState` has the shape this revision's schema requires.
---@param currentState any
---@return boolean
local function validateState(currentState)
    return type(currentState) == "table"
        and rawget(currentState, "schema") == STATE_SCHEMA
        and type(rawget(currentState, "adopted")) == "table"
end

---Whether a copy carrying this revision already committed its state.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
    return validateState(rawget(implementation, "_state"))
end

-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. What stays here is what only InteropKit can answer.
local InteropKit, previousRevision, selected = bootstrapPackage(Registry, {
    package = PACKAGE_NAME,
    api = API_GENERATION,
    revision = IMPLEMENTATION_REVISION,
    label = "MoltenCodes InteropKit",
    validatePublicSurface = validatePublicSurface,
    validateState = validateCurrentState,
})

if InteropKit == nil then
    -- Equal or newer compatible revision already owns the shared package table.
    return selected
end

local state = rawget(InteropKit, "_state")

if previousRevision == nil then
    if state ~= nil then
        error("MoltenCodes InteropKit package state is corrupted or incomplete", 2)
    end

    state = {
        schema = STATE_SCHEMA,
        -- Adopted LibStub libraries, keyed by major:
        -- `{ library = table, minor = number }`. Adoptions are load-time
        -- registrations and survive an in-place upgrade with this table.
        adopted = {},
    }
    rawset(InteropKit, "_state", state)
elseif not validateState(state) then
    error("MoltenCodes InteropKit package state is corrupted or incomplete", 2)
end

local adopted = rawget(state, "adopted")

-- Validation helpers ---------------------------------------------------------

---Whether the host reports `value` as a secret value.
---
---`issecretvalue` is read on every call: it exists only on clients with
---secret values, and nothing here is on a hot path.
---@param value any
---@return boolean
local function isSecret(value)
    -- The World of Warcraft client API is reachable only through the global table.
    -- selene: allow(global_usage)
    local isSecretValue = rawget(_G, "issecretvalue")
    return type(isSecretValue) == "function" and isSecretValue(value) == true
end

---Raise at `level` unless `value` is a non-empty, non-secret string.
---
---The secret check runs first: on a client with secret values, comparing a
---secret string with `""` would itself raise inside InteropKit.
---@param value any
---@param methodName string public method name, used in the argument error
---@param parameterName string
---@param level integer stack level the failure is reported at
local function validateName(value, methodName, parameterName, level)
    if isSecret(value) then
        error(methodName .. " " .. parameterName .. " must not be a secret value", level)
    end
    if type(value) ~= "string" or value == "" then
        error(methodName .. " " .. parameterName .. " must be a non-empty string", level)
    end
end

---Raise at `level` unless `value` is a Registry package identifier.
---@param value any
---@param methodName string
---@param level integer
local function validatePackageName(value, methodName, level)
    validateName(value, methodName, "packageName", level + 1)
    if not string.match(value, PACKAGE_NAME_PATTERN) then
        error(methodName .. " packageName must match " .. PACKAGE_NAME_PATTERN, level)
    end
end

---Raise at `level` unless `value` is a positive integer API generation.
---
---The secret check runs first for the same reason as in `validateName`: the
---arithmetic and comparisons below would raise inside InteropKit on a secret.
---@param value any
---@param methodName string
---@param level integer
local function validateApi(value, methodName, level)
    if isSecret(value) then
        error(methodName .. " api must not be a secret value", level)
    end
    if type(value) ~= "number" or value % 1 ~= 0 or value < 1 or value > MAXIMUM_INTEGER then
        error(methodName .. " api must be a positive integer", level)
    end
end

-- LibStub access -------------------------------------------------------------

---Return LibStub when it is loaded and has the two public methods, else `nil`.
---@return table|nil
local function findLibStub()
    -- LibStub publishes itself only as a global; there is no other way to find it.
    -- selene: allow(global_usage)
    local libStub = rawget(_G, LIBSTUB_GLOBAL)
    if
        type(libStub) ~= "table"
        or type(rawget(libStub, "NewLibrary")) ~= "function"
        or type(rawget(libStub, "GetLibrary")) ~= "function"
    then
        return nil
    end
    return libStub
end

---Return LibStub's `libs` and `minors` tables, or `nil` when this LibStub does
---not keep them the way every released LibStub does.
---@param libStub table
---@return table|nil libs
---@return table|nil minors
local function libStubTables(libStub)
    local libs = rawget(libStub, "libs")
    local minors = rawget(libStub, "minors")
    if type(libs) ~= "table" or type(minors) ~= "table" then
        return nil, nil
    end
    return libs, minors
end

-- Package lookup -------------------------------------------------------------

---The PascalCase facade name of a package identifier: `eventKit` becomes
---`EventKit`, `registry` becomes `Registry`.
---@param packageName string
---@return string
local function displayName(packageName)
    return string.upper(string.sub(packageName, 1, 1)) .. string.sub(packageName, 2)
end

---Return a package's facade and revision, or `nil` and Registry's reason.
---
---Registry does not register itself as a package, so `registry` resolves
---through `MoltenCodes.Registries[api]`, the generation-exact publication.
---@param packageName string
---@param api integer
---@return table|nil facade
---@return integer|string revisionOrReason
local function findPackage(packageName, api)
    if packageName ~= REGISTRY_PACKAGE_NAME then
        return Registry:Find(packageName, api)
    end

    -- The shared MoltenCodes namespace is the documented handoff point.
    -- selene: allow(global_usage)
    local currentNamespace = rawget(_G, "MoltenCodes")
    local published = type(currentNamespace) == "table" and rawget(currentNamespace, "Registries")
        or nil
    local facade = type(published) == "table" and rawget(published, api) or nil
    if type(facade) ~= "table" or type(rawget(facade, "REVISION")) ~= "number" then
        return nil, "generation_mismatch"
    end
    return facade, rawget(facade, "REVISION")
end

-- Exposing -------------------------------------------------------------------

---Whether LibStub is loaded: a global `LibStub` table with `NewLibrary` and
---`GetLibrary`.
---@return boolean
local function packageIsLibStubPresent()
    return findLibStub() ~= nil
end

---Register `facade` with LibStub under `major` at minor `revision`.
---
---The caller has already validated every argument. Returns what
---`ExposeToLibStub` returns, without the major.
---@param libStub table
---@param facade table
---@param major string
---@param revision integer
---@return boolean ok
---@return InteropKit.Reason|nil reason
local function exposeFacade(libStub, facade, major, revision)
    local libs, minors = libStubTables(libStub)
    if libs == nil or minors == nil then
        return false, REASON_UNSUPPORTED
    end

    local held = rawget(libs, major)
    local heldMinor = rawget(minors, major)

    if held ~= nil and held ~= facade then
        -- Another library owns the name. Asking LibStub for it with a higher
        -- minor would already raise that library's recorded minor, so the
        -- refusal happens before LibStub is called at all.
        return false, REASON_TAKEN
    end
    if held == nil and heldMinor ~= nil then
        -- A minor without a library is a state LibStub itself never produces.
        return false, REASON_UNSUPPORTED
    end
    if held == facade and type(heldMinor) == "number" and heldMinor >= revision then
        -- Already exposed at this revision or a newer one.
        return true, nil
    end

    local created = rawget(libStub, "NewLibrary")(libStub, major, revision)
    if type(created) ~= "table" or rawget(libs, major) ~= created then
        return false, REASON_UNSUPPORTED
    end

    -- The one write into LibStub's internals: LibStub has just recorded the
    -- major and minor and created an empty table for them; the Kit's facade
    -- takes that table's place so `LibStub(major)` returns the shared facade.
    -- On a re-exposure `created` already is the facade and nothing changes.
    rawset(libs, major, facade)
    return true, nil
end

---Make a Kit reachable as a LibStub library.
---
---Returns `true, major` when `LibStub(major)` now returns the Kit's facade,
---including when it already did (the call is idempotent). A newer revision of
---the Kit exposes again with the higher minor. Otherwise returns `false` and a
---reason: `"absent"` (LibStub is not loaded), `"unknown"` (Registry has no
---usable entry; the third result is Registry's own reason), `"taken"` (another
---library holds `major`) or `"unsupported"` (LibStub lacks the `libs` and
---`minors` tables the bridge needs).
---@param _ InteropKit
---@param packageName string package identifier, for example `"eventKit"`
---@param api integer API generation
---@param major string? LibStub major; defaults to `"MoltenCodes-<Facade>-<api>"`
---@return boolean ok
---@return string|InteropKit.Reason majorOrReason
---@return string? registryReason
local function packageExposeToLibStub(_, packageName, api, major)
    local methodName = "InteropKit:ExposeToLibStub"
    validatePackageName(packageName, methodName, 3)
    validateApi(api, methodName, 3)
    if major ~= nil then
        validateName(major, methodName, "major", 3)
    else
        major = DEFAULT_MAJOR_PREFIX .. displayName(packageName) .. "-" .. api
    end

    local libStub = findLibStub()
    if libStub == nil then
        return false, REASON_ABSENT
    end

    local facade, revisionOrReason = findPackage(packageName, api)
    if facade == nil then
        return false, REASON_UNKNOWN, revisionOrReason --[[@as string]]
    end

    local ok, reason = exposeFacade(libStub, facade, major, revisionOrReason --[[@as integer]])
    if not ok then
        return false, reason --[[@as InteropKit.Reason]]
    end
    return true, major
end

---Build a set from the `except` array of `ExposeAll`, raising at `level` for a
---malformed one.
---@param options any
---@param level integer
---@return table<string, boolean>
local function readExcept(options, level)
    local methodName = "InteropKit:ExposeAll"
    if options == nil then
        return {}
    end
    if type(options) ~= "table" then
        error(methodName .. " options must be a table or nil", level)
    end

    local except = rawget(options, "except")
    local excluded = {}
    if except == nil then
        return excluded
    end
    if type(except) ~= "table" then
        error(methodName .. " options.except must be an array of package names", level)
    end
    for index = 1, #except do
        validatePackageName(rawget(except, index), methodName, level + 1)
        excluded[rawget(except, index)] = true
    end
    return excluded
end

---Expose every active package `Registry:Packages()` lists, under its default
---major.
---
---Returns three counts: packages exposed (including ones already exposed),
---packages skipped (named in `options.except`, or not active), and packages
---refused (every reason `ExposeToLibStub` can give, including LibStub being
---absent). Registry itself is not a `Packages()` row; expose it explicitly.
---@param _ InteropKit
---@param options InteropKit.ExposeAllOptions?
---@return integer exposed
---@return integer skipped
---@return integer refused
local function packageExposeAll(_, options)
    local excluded = readExcept(options, 3)
    local libStub = findLibStub()
    local exposed, skipped, refused = 0, 0, 0

    local rows = Registry:Packages()
    for index = 1, #rows do
        local row = rows[index]
        local packageName = row.package
        if excluded[packageName] or row.status ~= STATUS_ACTIVE then
            skipped = skipped + 1
        elseif libStub == nil then
            refused = refused + 1
        else
            local facade = Registry:Find(packageName, row.api)
            local major = DEFAULT_MAJOR_PREFIX .. displayName(packageName) .. "-" .. row.api
            if facade ~= nil and exposeFacade(libStub, facade, major, row.revision) then
                exposed = exposed + 1
            else
                refused = refused + 1
            end
        end
    end
    return exposed, skipped, refused
end

-- Adopting -------------------------------------------------------------------

---Adopt a LibStub library as a read-only foreign entry.
---
---Returns the library table and its minor, and records both so `Find` and
---`Adopted` can answer later without LibStub. Adopting again refreshes the
---recorded minor. Returns `nil, "absent"` when LibStub is not loaded and
---`nil, "unknown"` when LibStub holds no library under `major`. Never raises for
---a missing library, and never writes anything into LibStub or the library.
---@param _ InteropKit
---@param major string
---@return table|nil library
---@return number|InteropKit.Reason minorOrReason
local function packageAdoptFromLibStub(_, major)
    validateName(major, "InteropKit:AdoptFromLibStub", "major", 3)

    local libStub = findLibStub()
    if libStub == nil then
        return nil, REASON_ABSENT
    end

    local library, minor = rawget(libStub, "GetLibrary")(libStub, major, true)
    if type(library) ~= "table" then
        return nil, REASON_UNKNOWN
    end

    local record = rawget(adopted, major)
    if record == nil then
        record = {}
        rawset(adopted, major, record)
    end
    rawset(record, "library", library)
    rawset(record, "minor", minor)
    return library, minor
end

---Silent lookup of an adopted library, the foreign counterpart of
---`Registry:Find`.
---
---Returns what `AdoptFromLibStub` recorded, or `nil, "unknown"` for a major that
---was never adopted. Allocation-free.
---@param _ InteropKit
---@param major string
---@return table|nil library
---@return number|InteropKit.Reason minorOrReason
local function packageFind(_, major)
    validateName(major, "InteropKit:Find", "major", 3)

    local record = rawget(adopted, major)
    if record == nil then
        return nil, REASON_UNKNOWN
    end
    return rawget(record, "library"), rawget(record, "minor")
end

---Order two `Adopted` rows by major.
---@param left InteropKit.AdoptedRow
---@param right InteropKit.AdoptedRow
---@return boolean
local function adoptedRowBefore(left, right)
    return left.major < right.major
end

---Diagnostic listing of every adopted library, sorted by major.
---
---Allocates a fresh array of fresh rows on every call by design; it is meant
---for consoles and options pages, never for a hot path.
---@return InteropKit.AdoptedRow[]
local function packageAdopted()
    local rows = {}
    for major, record in next, adopted do
        rows[#rows + 1] = { major = major, minor = rawget(record, "minor") }
    end
    table.sort(rows, adoptedRowBefore)
    return rows
end

-- Commit ---------------------------------------------------------------------

rawset(InteropKit, "API", API_GENERATION)
rawset(InteropKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(InteropKit, "IsLibStubPresent", packageIsLibStubPresent)
rawset(InteropKit, "ExposeToLibStub", packageExposeToLibStub)
rawset(InteropKit, "ExposeAll", packageExposeAll)
rawset(InteropKit, "AdoptFromLibStub", packageAdoptFromLibStub)
rawset(InteropKit, "Find", packageFind)
rawset(InteropKit, "Adopted", packageAdopted)

if not validatePublicSurface(InteropKit) or not validateCurrentState(InteropKit) then
    error("MoltenCodes InteropKit package state is corrupted or incomplete", 2)
end

return InteropKit
