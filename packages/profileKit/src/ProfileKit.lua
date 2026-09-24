-- MoltenCodes ProfileKit
--
-- Named performance sections measured inside the World of Warcraft client:
-- call count, total time, worst spike and last time per section, and a report
-- sorted by total. Time is addon CPU milliseconds from `debugprofilestop`.
--
-- ProfileKit costs nothing worth measuring while it is off. `Begin`, `End` and
-- `Measure` are swapped for no-op functions on `Disable` and for the measuring
-- functions on `Enable`, so a disabled caller pays one table read and one call
-- and never branches on a flag. Nothing is shipped enabled.
--
-- Contents
-- --------
--   Constants ............. identity, defaults, refusal reasons
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, the CPU clock, the secret probe
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. registration and inherited state
--   Argument checks ....... errors reported at the caller's line
--   Limits ................ validating and reading the shared section limit
--   Recording ............. one sample into a section, abandoning open ones
--   Section methods ....... measuring and no-op Begin/End
--   Measure ............... measuring and pass-through Measure
--   Switching ............. binding the measuring or no-op functions
--   Package public API .... the facade published through Registry
--   Commit ................ facade assignment, binding and self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "profileKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 2
local REQUIRED_REGISTRY_API = 2
local STATE_SCHEMA = 1

-- How many distinct sections one session may create unless a consumer opens
-- the limit with `SetLimits`. Sections are never freed, because callers hold
-- them, so the bound is what keeps a loop that builds section names from data
-- from growing the package state without limit.
local DEFAULT_MAX_SECTIONS = 256

-- The limits `SetLimits` accepts, in the order `GetLimits` reports them.
local LIMIT_NAMES = { "maxSections" }
local LIMIT_NAME_SET = { maxSections = true }

-- Refusal reasons. Plain strings, so a caller compares them without importing
-- anything; the API documentation lists each one.
local REASON_UNAVAILABLE = "unavailable"
local REASON_CAPPED = "capped"
local REASON_ACTIVE = "active"
local REASON_IDLE = "idle"
local REASON_CLOCK_RESET = "clockReset"

-- Public types ---------------------------------------------------------------
--
-- ProfileKit publishes its methods by writing them onto Registry-owned tables,
-- so the editor-facing contract is declared here rather than inferred.

---Why a ProfileKit call declined to act. See docs/API.md for each value.
---@alias ProfileKit.Reason "unavailable"|"capped"|"active"|"idle"|"clockReset"

---A named measurement section. Obtain one with `ProfileKit:Section(name)`.
---
---While ProfileKit is disabled both methods are no-ops that return nothing.
---@class ProfileKit.Section
---@field Begin fun(self: ProfileKit.Section): true?, ProfileKit.Reason?
---@field End fun(self: ProfileKit.Section): number?, ProfileKit.Reason?
---@field package _name string Section name; private to this file.
---@field package _count integer Recorded measurements; private to this file.
---@field package _total number Sum of recorded milliseconds; private to this file.
---@field package _max number Worst recorded milliseconds; private to this file.
---@field package _last number Latest recorded milliseconds; private to this file.
---@field package _startedAt number|false Clock reading at `Begin`, or `false` when idle.

---One row of `ProfileKit:Report()`. Times are milliseconds.
---@class ProfileKit.ReportEntry
---@field name string Section name.
---@field count integer Completed measurements.
---@field total number Sum of every measurement.
---@field max number Worst single measurement (the spike).
---@field last number Most recent measurement.

---The shared limits. `SetLimits` accepts any subset; `GetLimits` returns all.
---@class ProfileKit.Limits
---@field maxSections integer|table Most sections one session creates: a positive integer or `ProfileKit.UNBOUNDED`; default `256`.

---The ProfileKit package facade published through Registry.
---@class ProfileKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field DEFAULT_MAX_SECTIONS integer Default of the `maxSections` limit (`256`).
---@field UNBOUNDED table Sentinel that lifts a limit; the same table for every revision.
---@field Enable fun(self: ProfileKit): boolean, ProfileKit.Reason?
---@field Disable fun(self: ProfileKit)
---@field IsEnabled fun(self: ProfileKit): boolean
---@field Section fun(self: ProfileKit, name: string): ProfileKit.Section?, ProfileKit.Reason?
---@field Measure fun(self: ProfileKit, name: string, fn: function, ...: any): ...
---@field Report fun(self: ProfileKit): ProfileKit.ReportEntry[]
---@field Reset fun(self: ProfileKit)
---@field SetLimits fun(self: ProfileKit, limits: ProfileKit.Limits)
---@field GetLimits fun(self: ProfileKit): ProfileKit.Limits

-- Dependencies ---------------------------------------------------------------

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
    error("MoltenCodes ProfileKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
if type(bootstrapPackage) ~= "function" then
    error("MoltenCodes ProfileKit requires a valid Registry API 2 facade", 2)
end

-- `debugprofilestop` reports addon CPU milliseconds, the same clock
-- SchedulerKit's frame budget is defined against, so a client hitch or a
-- garbage-collection pause elsewhere is not charged to the measured section.
-- It is optional: without it ProfileKit loads normally and `Enable` declines
-- with "unavailable". There is deliberately no wall-clock fallback, because a
-- section measured in wall time would silently mean something different.
-- debugprofilestop is a World of Warcraft client API reachable only through the global table.
-- selene: allow(global_usage)
local readClock = rawget(_G, "debugprofilestop")
if type(readClock) ~= "function" then
    readClock = nil
end

-- `issecretvalue` (Retail 12.0 and later, and the current Classic clients) is
-- asked only by `SetLimits`, before a caller's limit value is compared with
-- anything: a secret raises when compared. Without it nothing is secret.
-- issecretvalue is a World of Warcraft client API reachable only through the global table.
-- selene: allow(global_usage)
local nativeIsSecretValue = rawget(_G, "issecretvalue")
if type(nativeIsSecretValue) ~= "function" then
    nativeIsSecretValue = nil
end

local getmetatable = getmetatable
local type = type

-- Validation -----------------------------------------------------------------

---Whether `implementation` exposes the complete ProfileKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
    return type(implementation) == "table"
        and rawget(implementation, "API") == API_GENERATION
        and type(rawget(implementation, "REVISION")) == "number"
        and type(rawget(implementation, "DEFAULT_MAX_SECTIONS")) == "number"
        and type(rawget(implementation, "UNBOUNDED")) == "table"
        and type(rawget(implementation, "Enable")) == "function"
        and type(rawget(implementation, "Disable")) == "function"
        and type(rawget(implementation, "IsEnabled")) == "function"
        and type(rawget(implementation, "Section")) == "function"
        and type(rawget(implementation, "Measure")) == "function"
        and type(rawget(implementation, "Report")) == "function"
        and type(rawget(implementation, "Reset")) == "function"
        and type(rawget(implementation, "SetLimits")) == "function"
        and type(rawget(implementation, "GetLimits")) == "function"
end

---Whether `value` is an exact integer of one or more. `nan` fails every
---comparison and both infinities are refused before the integer test.
---@param value any
---@return boolean
local function isPositiveInteger(value)
    return type(value) == "number" and value >= 1 and value ~= math.huge and value % 1 == 0
end

---Whether `limits` holds a valid value for every limit this revision knows.
---@param limits any
---@param unbounded any the package's sentinel
---@return boolean
local function validateLimitsTable(limits, unbounded)
    if type(limits) ~= "table" then
        return false
    end
    for index = 1, #LIMIT_NAMES do
        local value = rawget(limits, LIMIT_NAMES[index])
        if value ~= unbounded and not isPositiveInteger(value) then
            return false
        end
    end
    return true
end

---Whether `currentState` has the fields every API 1 revision shares.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
    return type(currentState) == "table"
        and rawget(currentState, "schema") == STATE_SCHEMA
        and type(rawget(currentState, "enabled")) == "boolean"
        and type(rawget(currentState, "unbounded")) == "table"
        and validateLimitsTable(rawget(currentState, "limits"), rawget(currentState, "unbounded"))
        and type(rawget(currentState, "sections")) == "table"
        and type(rawget(currentState, "sectionsByName")) == "table"
        and type(rawget(currentState, "sectionPrototype")) == "table"
        and type(rawget(currentState, "sectionMetatable")) == "table"
end

---Whether `implementation` carries package state of this revision's schema,
---and publishes the sentinel that state owns.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
    local currentState = rawget(implementation, "_state")
    return validateStateBase(currentState)
        and rawget(implementation, "UNBOUNDED") == rawget(currentState, "unbounded")
end

-- Bootstrap ------------------------------------------------------------------

-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. ProfileKit keeps no closures outside the shared
-- tables, so it needs neither a retire hook nor migration steps yet.
local ProfileKit, previousRevision, selected = bootstrapPackage(Registry, {
    package = PACKAGE_NAME,
    api = API_GENERATION,
    revision = IMPLEMENTATION_REVISION,
    label = "MoltenCodes ProfileKit",
    validatePublicSurface = validatePublicSurface,
    validateState = validateCurrentState,
})

if type(ProfileKit) == "nil" then
    -- Equal or newer compatible revision already owns the shared package table.
    return selected
end

local state = rawget(ProfileKit, "_state")

if type(previousRevision) == "nil" then
    if state ~= nil then
        error("MoltenCodes ProfileKit package state is corrupted or incomplete", 2)
    end

    -- The section prototype and metatable live in the shared state, never on a
    -- file local, so sections created by an older embedded copy resolve to the
    -- methods the newest copy installs.
    local sectionPrototype = {}
    state = {
        schema = STATE_SCHEMA,
        enabled = false,
        -- The sentinel `SetLimits` accepts to lift a limit. It lives here, not
        -- in a file local, so every embedded revision hands out the same table.
        unbounded = {},
        -- The shared limits, kept across upgrades like everything else here.
        limits = { maxSections = DEFAULT_MAX_SECTIONS },
        sections = {},
        sectionsByName = {},
        sectionPrototype = sectionPrototype,
        sectionMetatable = { __index = sectionPrototype },
    }
    rawset(ProfileKit, "_state", state)
elseif not validateStateBase(state) then
    error("MoltenCodes ProfileKit package state is corrupted or incomplete", 2)
end

local SECTION_PROTOTYPE = rawget(state, "sectionPrototype")
local SECTION_METATABLE = rawget(state, "sectionMetatable")
local sections = rawget(state, "sections")
local sectionsByName = rawget(state, "sectionsByName")
local sharedLimits = rawget(state, "limits")
local UNBOUNDED = rawget(state, "unbounded")
rawset(SECTION_METATABLE, "__index", SECTION_PROTOTYPE)

-- Argument checks ------------------------------------------------------------

-- Every check raises with an explicit stack level so the reported position is
-- the line that called the public method, never a line inside ProfileKit.
-- `level` is the value `error` needs inside the function that receives it.

---@param name any
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateName(name, methodName, level)
    if type(name) ~= "string" or name == "" then
        error(methodName .. " name must be a non-empty string", level)
    end
end

---@param name any
---@param fn any
---@param level integer stack level the failure is reported at
local function validateMeasureArguments(name, fn, level)
    validateName(name, "ProfileKit:Measure", level + 1)
    if type(fn) ~= "function" then
        error("ProfileKit:Measure fn must be a function", level)
    end
end

---@param section any receiver the section method was called on
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateSection(section, methodName, level)
    if getmetatable(section) ~= SECTION_METATABLE then
        error(methodName .. " must be called on a ProfileKit section", level)
    end
end

-- Limits -------------------------------------------------------------------------

---@param receiver any the table the method was called on
---@param label string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
    -- The type test runs first so a caller's non-table receiver, a secret
    -- included, is never compared with the facade.
    if type(receiver) ~= "table" or receiver ~= ProfileKit then
        error(label .. " must be called on the ProfileKit facade; use " .. label .. "(...)", level)
    end
end

---Refuse a `SetLimits` argument before any limit changes, so a call with one
---bad entry leaves every limit as it was.
---@param limits any
---@param level integer stack level the failure is reported at
local function validateLimitUpdate(limits, level)
    if type(limits) ~= "table" then
        error("ProfileKit:SetLimits limits must be a table", level)
    end
    local key = next(limits)
    while type(key) ~= "nil" do
        if type(key) ~= "string" or LIMIT_NAME_SET[key] ~= true then
            error(
                "ProfileKit:SetLimits limits." .. tostring(key) .. " is not a recognised limit",
                level
            )
        end
        local value = rawget(limits, key)
        -- The secret check comes first: comparing a secret with the sentinel,
        -- or with a number, would raise inside ProfileKit.
        local secret = nativeIsSecretValue ~= nil and nativeIsSecretValue(value) == true
        if secret or (value ~= UNBOUNDED and not isPositiveInteger(value)) then
            error(
                "ProfileKit:SetLimits limits."
                    .. key
                    .. " must be a positive integer or ProfileKit.UNBOUNDED",
                level
            )
        end
        key = next(limits, key)
    end
end

---Whether one more section fits under the current `maxSections` limit.
---@param count integer sections that exist now
---@return boolean
local function hasRoomForSection(count)
    local maxSections = rawget(sharedLimits, "maxSections")
    return maxSections == UNBOUNDED or count < maxSections
end

-- Recording ------------------------------------------------------------------
--
-- Section fields are read and written directly rather than through `rawget`:
-- every field is always present on the section itself, so the metatable is
-- never consulted, and a plain index is cheaper than a function call on the
-- one path ProfileKit exists to keep cheap.

---Add one measurement to `section`.
---
---`debugprofilestop` is one process-wide timer that any addon may zero with
---`debugprofilestart()`. A reading that went backwards therefore measures
---nothing: the sample is dropped rather than recorded as zero or negative, so
---a neighbour's reset can never pull `total` down or hide a spike.
---@param section table
---@param elapsed number milliseconds
---@return number? elapsed `nil` when the sample was dropped
---@return ProfileKit.Reason? reason `"clockReset"` when the sample was dropped
local function recordSample(section, elapsed)
    if elapsed < 0 then
        return nil, REASON_CLOCK_RESET
    end

    section._count = section._count + 1
    section._total = section._total + elapsed
    section._last = elapsed
    if elapsed > section._max then
        section._max = elapsed
    end
    return elapsed
end

---Forget every measurement that has begun but not ended.
---
---Called by `Disable` and `Reset`: an `End` that arrives after either of them
---must not record a span that straddled the switch.
local function abandonOpenMeasurements()
    for index = 1, #sections do
        sections[index]._startedAt = false
    end
end

-- Section methods -------------------------------------------------------------

---Start measuring this section (enabled binding).
---@param self ProfileKit.Section
---@return true? begun
---@return ProfileKit.Reason? reason `"active"` when the section is already begun
local function beginMeasuring(self)
    validateSection(self, "ProfileKit.Section:Begin", 3)
    if self._startedAt then
        return nil, REASON_ACTIVE
    end
    self._startedAt = readClock()
    return true
end

---Stop measuring this section and record the span (enabled binding).
---@param self ProfileKit.Section
---@return number? elapsed milliseconds recorded
---@return ProfileKit.Reason? reason `"idle"` without a matching `Begin`, `"clockReset"` when dropped
local function endMeasuring(self)
    validateSection(self, "ProfileKit.Section:End", 3)
    local finishedAt = readClock()
    local startedAt = self._startedAt
    if not startedAt then
        return nil, REASON_IDLE
    end
    self._startedAt = false
    return recordSample(self, finishedAt - startedAt)
end

---The disabled binding of `Begin` and `End`: nothing at all.
local function noOperation() end

-- Measure ----------------------------------------------------------------------

---Close a measurement `Measure` opened and pass `fn`'s outcome through.
---
---The results travel as a vararg list straight from `pcall` to the caller, so no
---table is built for them whatever their number, and trailing `nil`s survive.
---@param section table
---@param ok boolean
---@param ... any fn's results, or its error value when `ok` is false
---@return ...
local function finishMeasure(section, ok, ...)
    local finishedAt = readClock()
    local startedAt = section._startedAt
    -- `false` here means `fn` itself called `Disable`, `Reset` or this
    -- section's `End`; the span was abandoned or already recorded.
    if startedAt then
        section._startedAt = false
        recordSample(section, finishedAt - startedAt)
    end

    if not ok then
        -- Level 0 re-raises the value exactly as `fn` raised it: a string keeps
        -- the position `fn` gave it, and a table error stays the same table.
        error((...), 0)
    end
    return ...
end

---Create the section called `name`, or report that the cap refuses it.
---@param name string
---@return ProfileKit.Section? section
---@return ProfileKit.Reason? reason `"capped"` when `maxSections` is reached
local function createSection(name)
    local count = #sections
    if not hasRoomForSection(count) then
        return nil, REASON_CAPPED
    end

    local section = setmetatable({
        _name = name,
        _count = 0,
        _total = 0,
        _max = 0,
        _last = 0,
        _startedAt = false,
    }, SECTION_METATABLE)
    sections[count + 1] = section
    sectionsByName[name] = section
    return section
end

---Run `fn(...)` inside section `name` and return its results (enabled binding).
---@param _ ProfileKit
---@param name string
---@param fn function
---@param ... any
---@return ...
local function measureEnabled(_, name, fn, ...)
    validateMeasureArguments(name, fn, 3)

    local section = sectionsByName[name]
    if section == nil then
        section = createSection(name)
    end
    -- A capped name, or a section already open (a recursive `Measure` of the
    -- same name, or a manual `Begin` still running), runs unmeasured: the
    -- outer measurement already covers this call.
    if section == nil or section._startedAt then
        return fn(...)
    end

    section._startedAt = readClock()
    return finishMeasure(section, pcall(fn, ...))
end

---Run `fn(...)` and return its results (disabled binding).
---
---The arguments are still checked, so a call that fails once ProfileKit is
---enabled already fails while it is off.
---@param _ ProfileKit
---@param name string
---@param fn function
---@param ... any
---@return ...
local function measureDisabled(_, name, fn, ...)
    validateMeasureArguments(name, fn, 3)
    return fn(...)
end

-- Switching --------------------------------------------------------------------

---Bind the measuring or the no-op implementations on the shared tables.
---
---This swap is the whole "zero cost when off" mechanism: callers always look
---the method up, so they get whichever binding is current without a branch.
---@param enabled boolean
local function bindImplementations(enabled)
    if enabled then
        rawset(SECTION_PROTOTYPE, "Begin", beginMeasuring)
        rawset(SECTION_PROTOTYPE, "End", endMeasuring)
        rawset(ProfileKit, "Measure", measureEnabled)
    else
        rawset(SECTION_PROTOTYPE, "Begin", noOperation)
        rawset(SECTION_PROTOTYPE, "End", noOperation)
        rawset(ProfileKit, "Measure", measureDisabled)
    end
end

-- Package public API -------------------------------------------------------------

---Start measuring. Idempotent.
---@param _ ProfileKit
---@return boolean enabled
---@return ProfileKit.Reason? reason `"unavailable"` when the host has no `debugprofilestop`
local function enable(_)
    if readClock == nil then
        return false, REASON_UNAVAILABLE
    end
    rawset(state, "enabled", true)
    bindImplementations(true)
    return true
end

---Stop measuring. Idempotent; recorded statistics are kept.
---
---A measurement begun before `Disable` is abandoned, not recorded.
---@param _ ProfileKit
local function disable(_)
    rawset(state, "enabled", false)
    bindImplementations(false)
    abandonOpenMeasurements()
end

---Return whether ProfileKit is currently measuring.
---@param _ ProfileKit
---@return boolean enabled
local function isEnabled(_)
    return rawget(state, "enabled")
end

---Return the section called `name`, creating it on first use.
---
---Works whether or not ProfileKit is enabled, so sections can be created once
---at file scope. The same name always returns the same section.
---@param _ ProfileKit
---@param name string
---@return ProfileKit.Section? section
---@return ProfileKit.Reason? reason `"capped"` when a new section would exceed the cap
local function getSection(_, name)
    validateName(name, "ProfileKit:Section", 3)
    local section = sectionsByName[name]
    if section ~= nil then
        return section
    end
    return createSection(name)
end

---Order report rows by total descending, then by name for a stable result.
---@param left ProfileKit.ReportEntry
---@param right ProfileKit.ReportEntry
---@return boolean
local function byTotalDescending(left, right)
    if left.total ~= right.total then
        return left.total > right.total
    end
    return left.name < right.name
end

---Return one fresh row per section, sorted by total time descending.
---
---Allocates by design: the array and every row are new tables the caller owns.
---Diagnostic code only; never call it on a hot path.
---@param _ ProfileKit
---@return ProfileKit.ReportEntry[] report
local function report(_)
    local rows = {}
    for index = 1, #sections do
        local section = sections[index]
        rows[index] = {
            name = section._name,
            count = section._count,
            total = section._total,
            max = section._max,
            last = section._last,
        }
    end
    table.sort(rows, byTotalDescending)
    return rows
end

---Zero every section's statistics and abandon open measurements.
---
---Sections themselves are kept, because callers hold them, and they keep
---counting against the `maxSections` limit.
---@param _ ProfileKit
local function reset(_)
    abandonOpenMeasurements()
    for index = 1, #sections do
        local section = sections[index]
        section._count = 0
        section._total = 0
        section._max = 0
        section._last = 0
    end
end

---Change any subset of the shared limits. Affects every consumer.
---
---The whole table is checked before anything changes. Lowering a limit below
---the sections that already exist removes none of them; new names are refused
---with `"capped"` until the count is under the limit again.
---@param self ProfileKit
---@param limits ProfileKit.Limits
local function setLimits(self, limits)
    validateFacade(self, "ProfileKit:SetLimits", 3)
    validateLimitUpdate(limits, 3)
    for index = 1, #LIMIT_NAMES do
        local name = LIMIT_NAMES[index]
        local value = rawget(limits, name)
        if type(value) ~= "nil" then
            rawset(sharedLimits, name, value)
        end
    end
end

---Return a fresh copy of the shared limits. Allocates one table per call.
---@param self ProfileKit
---@return ProfileKit.Limits limits
local function getLimits(self)
    validateFacade(self, "ProfileKit:GetLimits", 3)
    return { maxSections = rawget(sharedLimits, "maxSections") }
end

-- Commit ---------------------------------------------------------------------------

rawset(ProfileKit, "API", API_GENERATION)
rawset(ProfileKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(ProfileKit, "DEFAULT_MAX_SECTIONS", DEFAULT_MAX_SECTIONS)
rawset(ProfileKit, "UNBOUNDED", UNBOUNDED)
rawset(ProfileKit, "Enable", enable)
rawset(ProfileKit, "Disable", disable)
rawset(ProfileKit, "IsEnabled", isEnabled)
rawset(ProfileKit, "Section", getSection)
rawset(ProfileKit, "Report", report)
rawset(ProfileKit, "Reset", reset)
rawset(ProfileKit, "SetLimits", setLimits)
rawset(ProfileKit, "GetLimits", getLimits)

-- An upgrade inherits the enabled flag. A copy loaded into a host without the
-- clock cannot honour it, so it comes up disabled instead of binding measuring
-- functions that would call a missing clock.
if rawget(state, "enabled") and readClock == nil then
    rawset(state, "enabled", false)
    abandonOpenMeasurements()
end
bindImplementations(rawget(state, "enabled"))

if not validatePublicSurface(ProfileKit) or not validateCurrentState(ProfileKit) then
    error("MoltenCodes ProfileKit package state is corrupted or incomplete", 2)
end

return ProfileKit
