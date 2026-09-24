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
--
-- Line budget: 1000 lines, comments included. Registry sits at the bottom of
-- every dependency chain and is loaded by every addon that embeds a Kit, so it
-- stays small and boring. A change that would push this file past the budget
-- moves behaviour into a package of its own (as the LibStub bridge did: it is
-- `interopKit`) or first shrinks what is here.
--
-- Contents
--
--   Validation ............... Identifier and revision checks.
--   Bootstrap state .......... Finding or creating the generation-private state.
--   Package-state access ..... Reading entries without trusting their shape.
--   Public types ............. LuaCATS declarations for the facade.
--   Lookup ................... Register, Get, GetInfo, Find, Packages.
--   Retirement and migration . OnRetire, the outgoing hand-over, the migration
--                              runner, and the sealed-facade metatable.
--   Bootstrap ................ The reconciliation every Kit calls.
--   Commit ................... Installing the methods and the facade self-check.
--   Public namespace ......... `MoltenCodes.Registries[n]` and the alias.

local GLOBAL_STATE_KEY = "__MOLTENCODES_REGISTRY_STATE_V2"
local PUBLIC_NAMESPACE_KEY = "MoltenCodes"
local PUBLIC_GENERATIONS_KEY = "Registries"
local PUBLIC_ALIAS_KEY = "Registry"

local STATE_SCHEMA = 1
local API_GENERATION = 2
local IMPLEMENTATION_REVISION = 11

-- Lua 5.1 numbers are doubles, which represent consecutive integers exactly only
-- up to 2^53. Past that boundary distinct values start comparing equal, so a
-- revision such as `1e300` would silently become an unbeatable revision that no
-- future embedded copy could ever replace. Identifiers are therefore bounded.
local MAXIMUM_INTEGER = 2 ^ 53
local MAXIMUM_INTEGER_TEXT = "2^53"

-- The fixed vocabulary `Registry:Find` explains a miss with.
local FIND_ABSENT = "absent"
local FIND_RETIRED = "retired"
local FIND_GENERATION_MISMATCH = "generation_mismatch"

-- Entry status values. An entry is `retired` from the moment its outgoing copy
-- is asked to hand over until the incoming copy's migrations have all run.
local STATUS_ACTIVE = "active"
local STATUS_RETIRED = "retired"

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

---Refuse an `api` or `revision` argument that is not a bounded positive
---integer, at the caller of the public method (level 3: this function, the
---method, its caller).
---@param value any
---@param methodName string
---@param fieldName "api"|"revision"
local function validatePositiveInteger(value, methodName, fieldName)
    if not isPositiveInteger(value) then
        error(
            "Registry:"
                .. methodName
                .. " "
                .. fieldName
                .. " must be a positive integer up to "
                .. MAXIMUM_INTEGER_TEXT,
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
--
-- An entry is `{ revision, implementation }`. Revisions 7 and 8 add optional
-- fields that older entries simply lack: `status`, `retire` (the selected
-- copy's hand-over hook), `migratedThrough` (the revision whose layout the
-- state is in), `migrating` and `pendingState` (an unfinished migration run and
-- the state it had reached) and `seal` (the sealed-facade metatable).
--
-- Corrupted state found while serving a public call is raised at that call's
-- caller, like an argument error. The accessors therefore take the stack level
-- the public method needs, counted from the accessor itself.

---@param packageName string
---@param level integer error level, counted from this function
---@return table|nil
local function getPackageEntries(packageName, level)
    local packageEntries = rawget(entries, packageName)
    if packageEntries ~= nil and type(packageEntries) ~= "table" then
        error("Registry: package state is corrupted", level)
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
        or not isPositiveInteger(rawget(entry, "revision"))
        or type(rawget(entry, "implementation")) ~= "table"
    then
        error("Registry: package state is corrupted", level)
    end

    return entry
end

---The entry for `(packageName, api)`, or `nil`.
---
---`level` is handed to the accessors unchanged, so it counts from them: the
---accessor, this function, then every Registry frame up to the public method,
---then its caller. A public method that calls this directly (`Get`, `GetInfo`,
---`OnRetire`, `Bootstrap`) passes 4, which names its caller's line; `adopt`,
---one frame deeper inside `Bootstrap`, passes 5. Corruption is therefore
---always raised at the line that called Registry, a package file's
---`Registry:Bootstrap(...)` included.
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

---@type Registry
local Registry = facade

-- Lookup ------------------------------------------------------------------

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

    local currentRevision = rawget(entry, "revision")
    if revision <= currentRevision then
        return nil
    end

    rawset(entry, "revision", revision)

    -- A retire hook belongs to the revision that registered it. Once another
    -- revision is selected the hook describes state that no longer exists, so
    -- it must never be handed the newer copy's table.
    rawset(entry, "retire", nil)

    -- The implementation table is intentionally never replaced. Packages
    -- upgrade this shared table in place so consumers holding older
    -- references immediately observe the newer revision.
    return rawget(entry, "implementation"), currentRevision
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

    validatePackageName(packageName, "Register")
    validatePositiveInteger(api, "Register", "api")
    validatePositiveInteger(revision, "Register", "revision")

    -- Not a tail call: a tail call would drop this frame, and the level
    -- `registerEntry` raises at counts it.
    local implementation, previousRevision = registerEntry(packageName, api, revision, 4)
    return implementation, previousRevision
end

---Returns the selected shared package table and its revision.
---@param packageName string
---@param api integer
---@return table|nil implementation
---@return integer|nil revision
local function get(_, packageName, api)
    validatePackageName(packageName, "Get")
    validatePositiveInteger(api, "Get", "api")

    local entry = findEntry(packageName, api, 4)
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
    validatePositiveInteger(api, "GetInfo", "api")

    local entry = findEntry(packageName, api, 4)
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

---Silent lookup for an optional dependency.
---
---Never raises for a package that is not there; raises at the caller only for
---malformed arguments. Allocation-free, so it is safe on any path.
---@param packageName string
---@param api integer
---@return table|nil implementation
---@return integer|Registry.FindReason revisionOrReason the revision, or why nothing was found
local function find(_, packageName, api)
    validatePackageName(packageName, "Find")
    validatePositiveInteger(api, "Find", "api")

    local packageEntries = getPackageEntries(packageName, 3)
    if packageEntries == nil or next(packageEntries) == nil then
        return nil, FIND_ABSENT
    end

    local entry = getEntry(packageEntries, api, 3)
    if entry == nil then
        return nil, FIND_GENERATION_MISMATCH
    end

    if rawget(entry, "status") == STATUS_RETIRED then
        return nil, FIND_RETIRED
    end

    return rawget(entry, "implementation"), rawget(entry, "revision")
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
---Allocates a fresh array of fresh rows on every call by design; it is meant
---for consoles and options pages, never for a hot path. Malformed private
---state raises the same corruption error `Get` raises, at the caller, instead
---of being listed as data or failing inside `table.sort`.
---@return Registry.PackageRow[]
local function packages()
    local rows = {}
    for packageName in next, entries do
        if type(packageName) ~= "string" then
            error("Registry: package state is corrupted", 2)
        end
        local packageEntries = getPackageEntries(packageName, 3) --[[@as table]]
        for api in next, packageEntries do
            if not isPositiveInteger(api) then
                error("Registry: package state is corrupted", 2)
            end
            local entry = getEntry(packageEntries, api, 3) --[[@as table]]
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

-- Retirement and migration -------------------------------------------------
--
-- When a newer revision replaces an older one, the outgoing copy may hand its
-- state over (its `retire` hook) and the incoming copy runs the migration steps
-- between the two revisions, each exactly once, in ascending order. The shared
-- facade and the Kit's prototype tables keep their identity throughout, so the
-- outgoing copy's entry points already resolve to the incoming methods.

---Registers the retire hook of the currently selected revision.
---
---`Registry:Bootstrap` does this from `request.retire`; this method is for a
---package that only knows what to hand over once its file has finished.
---@param packageName string
---@param api integer
---@param retire fun(implementation: table, incomingRevision: integer): any
local function onRetire(_, packageName, api, retire)
    validatePackageName(packageName, "OnRetire")
    validatePositiveInteger(api, "OnRetire", "api")
    if type(retire) ~= "function" then
        error("Registry:OnRetire retire must be a function", 2)
    end

    local entry = findEntry(packageName, api, 4)
    if entry == nil then
        error('Registry:OnRetire package "' .. packageName .. '" is not registered', 2)
    end

    rawset(entry, "retire", retire)
end

---Hand a failure to the host error handler, or print it outside the client.
---@param message string
local function reportFailure(message)
    -- geterrorhandler is a World of Warcraft client API reachable only through the global table.
    -- selene: allow(global_usage)
    local getErrorHandler = rawget(_G, "geterrorhandler")
    if type(getErrorHandler) == "function" then
        local handler = getErrorHandler()
        if type(handler) == "function" then
            handler(message)
            return
        end
    end
    print(message)
end

---Mark the entry retired and ask the outgoing copy for its state, once.
---
---A failing hook is reported and the upgrade continues from no hand-over
---rather than from a half-drained one.
---@param entry table
---@param implementation table
---@param incomingRevision integer
---@param label string
---@return any handover
local function retireOutgoing(entry, implementation, incomingRevision, label)
    if rawget(entry, "migrating") == true then
        -- The copy that retired already handed over; its state waits in
        -- `pendingState` for the migration run to be resumed.
        return nil
    end

    local retire = rawget(entry, "retire")
    rawset(entry, "retire", nil)
    rawset(entry, "status", STATUS_RETIRED)

    if type(retire) ~= "function" then
        return nil
    end

    local ok, handover = pcall(retire, implementation, incomingRevision)
    if ok then
        return handover
    end
    reportFailure(label .. " retire hook failed: " .. tostring(handover))
    return nil
end

---The migration steps in `(fromRevision, toRevision]`, ascending.
---@param migrations table
---@param fromRevision integer
---@param toRevision integer
---@return integer[]|nil steps
---@return string|nil problem
local function selectMigrationSteps(migrations, fromRevision, toRevision)
    local steps = {}
    for step, migrate in next, migrations do
        if not isPositiveInteger(step) or type(migrate) ~= "function" then
            return nil, "request.migrations must map positive revisions to functions"
        end
        if step > fromRevision and step <= toRevision then
            steps[#steps + 1] = step
        end
    end
    table.sort(steps)
    return steps, nil
end

---Run every migration step this entry has not run yet.
---
---`migratedThrough` is what makes each step run exactly once: a copy that
---resumes over state an earlier copy of the same revision already migrated
---starts after the last recorded step, not after the inherited revision.
---While a run is unfinished (`migrating`), the next copy starts after the last
---step that completed and receives the state that step produced
---(`pendingState`), so a failed step is retried rather than skipped.
---@param entry table
---@param migrations table|nil
---@param inheritedRevision integer
---@param revision integer
---@param handover any
---@param implementation table
---@return boolean ok
---@return any stateOrProblem the migrated state, or the failure message
local function runMigrations(
    entry,
    migrations,
    inheritedRevision,
    revision,
    handover,
    implementation
)
    local fromRevision = inheritedRevision
    local migratedThrough = rawget(entry, "migratedThrough")
    local migratedState = handover
    if rawget(entry, "migrating") == true and isNonNegativeInteger(migratedThrough) then
        -- An earlier copy's run stopped at a failing step. The state is in the
        -- layout of the last step that completed, whatever revision this copy
        -- inherited, and carries on from where that run left it.
        fromRevision = migratedThrough
        migratedState = rawget(entry, "pendingState")
    else
        if isNonNegativeInteger(migratedThrough) and migratedThrough > fromRevision then
            fromRevision = migratedThrough
        end
        rawset(entry, "migrating", true)
        rawset(entry, "migratedThrough", fromRevision)
        rawset(entry, "pendingState", migratedState)
    end

    if migrations ~= nil then
        local steps, problem = selectMigrationSteps(migrations, fromRevision, revision)
        if steps == nil then
            return false, problem
        end

        for index = 1, #steps do
            local step = steps[index]
            local ok, result = pcall(rawget(migrations, step), migratedState, implementation)
            if not ok then
                return false, "migration to revision " .. step .. " failed: " .. tostring(result)
            end
            if result ~= nil then
                migratedState = result
            end
            rawset(entry, "migratedThrough", step)
            rawset(entry, "pendingState", migratedState)
        end
    end

    if fromRevision < revision then
        rawset(entry, "migratedThrough", revision)
    end
    rawset(entry, "migrating", nil)
    rawset(entry, "pendingState", nil)
    rawset(entry, "status", STATUS_ACTIVE)
    return true, migratedState
end

---Install, keep or remove the sealed-facade metatable, as the request asks.
---
---Lua 5.1 has no metamethod for assignments to fields that already exist, so a
---seal refuses *new* fields only; see `docs/API.md`. A newer revision that does
---not ask for the seal removes the one Registry installed, because the newer
---revision owns the facade's policy.
---@param entry table
---@param implementation table
---@param wanted boolean
---@param label string
---@return boolean ok `false` when the facade carries a metatable Registry did not install
local function applySeal(entry, implementation, wanted, label)
    local seal = rawget(entry, "seal")
    local current = getmetatable(implementation)

    if not wanted then
        if seal ~= nil and current == seal then
            setmetatable(implementation, nil)
        end
        return true
    end

    if current ~= nil and current ~= seal then
        return false
    end

    -- A fresh metatable per sealing revision, so the refusal carries the label
    -- of the revision that currently owns the facade.
    seal = {
        __newindex = function(_, key)
            error(
                label
                    .. ' facade is sealed; field "'
                    .. tostring(key)
                    .. '" cannot be added from outside the package',
                2
            )
        end,
    }
    rawset(entry, "seal", seal)
    setmetatable(implementation, seal)
    return true
end

-- Bootstrap ---------------------------------------------------------------

---@param field any
---@param fieldName string
---@param expectedType string
local function validateOptionalField(field, fieldName, expectedType)
    if field ~= nil and type(field) ~= expectedType then
        error("Registry:Bootstrap request." .. fieldName .. " must be a " .. expectedType, 3)
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
---The return values are what the caller needs to finish:
---
---* `implementation` is the shared package table to initialize. When it is
---  `nil` the caller is done and must `return selected` unchanged.
---* `previousRevision` is `nil` for a first registration and otherwise the
---  revision whose state this copy inherits, exactly as `Registry:Register`
---  reports it.
---* `selected` is the copy Registry has selected, which is what the caller
---  returns when `implementation` is `nil`.
---* `state` is what the outgoing copy handed over, after every migration step
---  has transformed it; `nil` when nothing was handed over.
---
---`validateState`, `resume`, `retire`, `migrations` and `sealFacade` are
---optional; `docs/API.md` documents each and the decision table.
---
---Registry never calls this helper for itself: it is the file that
---publishes the facade the helper lives on, so its own bootstrap has to run
---before any facade method exists.
---@param request Registry.BootstrapRequest
---@return table|nil implementation
---@return integer|nil previousRevision
---@return table|nil selected
---@return any state
local function bootstrap(_, request)
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
    local retire = rawget(request, "retire")
    local migrations = rawget(request, "migrations")
    local sealFacade = rawget(request, "sealFacade")

    validatePackageName(packageName, "Bootstrap")
    validatePositiveInteger(api, "Bootstrap", "api")
    validatePositiveInteger(revision, "Bootstrap", "revision")
    if type(label) ~= "string" or label == "" then
        error("Registry:Bootstrap request.label must be a non-empty string", 2)
    end
    if type(validatePublicSurface) ~= "function" then
        error("Registry:Bootstrap request.validatePublicSurface must be a function", 2)
    end
    validateOptionalField(validateState, "validateState", "function")
    validateOptionalField(resume, "resume", "function")
    validateOptionalField(retire, "retire", "function")
    validateOptionalField(migrations, "migrations", "table")
    validateOptionalField(sealFacade, "sealFacade", "boolean")

    -- Level 3 points at the package file that called `Registry:Bootstrap`,
    -- which is the caller of this helper: level 1 is `refuse` itself and
    -- level 2 is `bootstrap`.
    local function refuse(reason)
        error(label .. " " .. reason, 3)
    end

    ---Finish handing `implementation` to the caller: run the migration steps it
    ---has not run yet, record its retire hook, and apply the seal it asked for.
    ---@param implementation table
    ---@param inheritedRevision integer|nil
    ---@param handover any
    ---@return any state
    local function adopt(implementation, inheritedRevision, handover)
        -- `register` or the existing-copy lookup just proved the entry exists.
        -- Level 5: one frame deeper than `bootstrap`, which calls this.
        local entry = findEntry(packageName, api, 5) --[[@as table]]
        local migratedState = nil
        if inheritedRevision == nil then
            -- Nothing was inherited, so no step runs; the table is still
            -- validated, so a malformed one fails on every load, not only
            -- on the first upgrade.
            if
                migrations ~= nil
                and selectMigrationSteps(migrations, revision, revision) == nil
            then
                error(label .. " request.migrations must map positive revisions to functions", 3)
            end
            rawset(entry, "migratedThrough", revision)
            rawset(entry, "status", STATUS_ACTIVE)
        else
            local ok, result = runMigrations(
                entry,
                migrations,
                inheritedRevision,
                revision,
                handover,
                implementation
            )
            if not ok then
                error(label .. " " .. result, 3)
            end
            migratedState = result
        end

        if retire ~= nil then
            rawset(entry, "retire", retire)
        end
        if not applySeal(entry, implementation, sealFacade == true, label) then
            error(label .. " cannot seal a facade that already carries a metatable", 3)
        end
        return migratedState
    end

    -- The entry is read directly rather than through `get`, so corruption is
    -- raised at the package file's `Bootstrap` call, not inside Registry.
    local existingEntry = findEntry(packageName, api, 4)
    local existing, existingRevision = nil, nil
    if existingEntry ~= nil then
        existing = rawget(existingEntry, "implementation")
        existingRevision = rawget(existingEntry, "revision")
        if rawget(existing, "API") ~= api then
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
                    return existing, inherited, existing, adopt(existing, inherited, nil)
                end
                return nil, nil, existing
            end

            if not complete then
                refuse("package state is corrupted or incomplete")
            end
            return nil, nil, existing
        end
    end

    -- An older revision is selected: its copy hands over before this one
    -- registers, so the hook still sees the state it owns.
    local handover = nil
    if existingEntry ~= nil then
        handover = retireOutgoing(existingEntry, existing, revision, label)
    end

    local implementation, previousRevision = registerEntry(packageName, api, revision, 4)
    if implementation == nil then
        -- An equal or newer compatible revision owns the shared table.
        return nil, nil, existing
    end

    if previousRevision ~= existingRevision then
        refuse("Registry state changed unexpectedly during bootstrap")
    end

    return implementation,
        previousRevision,
        existing,
        adopt(implementation, previousRevision, handover)
end

-- Commit ------------------------------------------------------------------

-- Every compatible embedded Registry copy shares this facade. A newer
-- implementation revision replaces methods on the same table, so references
-- acquired from older compatible copies continue to point at the upgraded
-- Registry facade.
if stateRevision < IMPLEMENTATION_REVISION then
    rawset(Registry, "Register", register)
    rawset(Registry, "Get", get)
    rawset(Registry, "GetInfo", getInfo)
    rawset(Registry, "Find", find)
    rawset(Registry, "Packages", packages)
    rawset(Registry, "OnRetire", onRetire)
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
    or type(rawget(Registry, "Find")) ~= "function"
    or type(rawget(Registry, "Packages")) ~= "function"
    or type(rawget(Registry, "OnRetire")) ~= "function"
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
