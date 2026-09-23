-- MoltenCodes HookKit
--
-- Reversible hooking of global functions, object methods and frame scripts for
-- World of Warcraft addons, with the three hook semantics named and the taint
-- each one causes spelled out:
--
--   secure post-hook   `SecureHook`, `SecureHookScript`: wraps the host's
--                      `hooksecurefunc` and `Frame:HookScript`. The target stays
--                      secure. Made reversible by an active flag on a closure
--                      that stays installed for the rest of the session.
--   safe pre-hook      `Hook`, `HookScript`: the handler runs first, its errors
--                      go to the host error handler, the original always runs
--                      and its results are returned untouched. Replaces the
--                      target with addon code, so the target becomes tainted.
--   raw replacement    `RawHook`, `RawHookScript`: the handler runs instead of
--                      the original and receives it as its first argument.
--                      Taints the target like a pre-hook.
--
-- A non-secure hook of a secure target is refused unless the caller passes
-- `options.forceSecure`, and replacing a protected script of a protected frame
-- is refused outright. `docs/API.md` leads with the taint model.
--
-- HookKit needs Registry API 2. It uses ClientKit API 1 when one is registered,
-- found through `Registry:Find` at call time, for `IsSecret`; without it the
-- host's `issecretvalue` is asked directly.
--
-- Contents
-- --------
--   Constants ............. identity, bounds, kinds, option keys, method lists
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry and the host facilities HookKit reads
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Error reporting ....... the host error sink and the secret-value probe
--   Argument checks ....... receivers, names, handlers, option tables
--   Target inspection ..... secure status (remembered), protected frames
--   Record table .......... the weak-keyed per-scope records, no auto-vivify
--   Installed closures .... the functions HookKit puts in the host's way
--   Installation .......... one function per semantic
--   Release ............... Unhook: restore when still ours, else go inert
--   Scope methods ......... the handle a scope owner receives
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment and self-check
--
-- Layout and invariants are described in `docs/INTERNALS.md`.

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "hookKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local OPTIONAL_CLIENTKIT_API = 1
local STATE_SCHEMA = 1

-- Every scope and record carries the layout it was built with, so a later
-- revision that changes a layout can upgrade old objects instead of guessing
-- from which fields exist.
local SCOPE_SCHEMA = 1
local RECORD_SCHEMA = 1

-- The most hooks one scope holds at once. A module or addon that needs more
-- than this is almost certainly hooking in a loop by mistake, and every
-- secure post-hook it installs stays in the host's call chain for the session.
local MAX_HOOKS = 256

-- How many `__index` tables the secure-status check follows to find the table
-- that actually holds an inherited method. Real frames and mixins are one or
-- two levels deep; the bound only stops a pathological or cyclic chain.
local MAX_INDEX_DEPTH = 8

-- The kind string each semantic records, as `Hooks()` and `IsHooked` report it.
local KIND_SECURE = "secure"
local KIND_SECURE_SCRIPT = "secureScript"
local KIND_HOOK = "hook"
local KIND_RAW_HOOK = "rawHook"
local KIND_HOOK_SCRIPT = "hookScript"
local KIND_RAW_HOOK_SCRIPT = "rawHookScript"

-- Kinds whose installed closure is owned by the host (`hooksecurefunc`,
-- `Frame:HookScript`) and can therefore never be removed, only made inert.
local SECURE_KINDS = { [KIND_SECURE] = true, [KIND_SECURE_SCRIPT] = true }

-- Kinds installed with `Frame:SetScript` rather than by writing a table field.
local SCRIPT_KINDS = { [KIND_HOOK_SCRIPT] = true, [KIND_RAW_HOOK_SCRIPT] = true }

-- Scripts refused outright on a protected frame, even with `forceSecure`:
-- secure action buttons run their action from the click scripts, and secure
-- handlers and state drivers run from `OnAttributeChanged`, so replacing one
-- of these breaks the frame's secure behaviour for the session. The secure
-- handler templates drive further scripts (`OnEnter`/`OnLeave`,
-- `OnShow`/`OnHide`, `OnMouseDown`/`OnMouseUp`, `OnMouseWheel`,
-- `OnDragStart`/`OnReceiveDrag`); those are not refused outright, but every
-- script of a protected frame other than these needs `forceSecure`.
local PROTECTED_SCRIPTS = {
    OnClick = true,
    PreClick = true,
    PostClick = true,
    OnDoubleClick = true,
    OnAttributeChanged = true,
}

-- The complete set of fields a hook option table accepts. A file-local
-- constant keeps option validation allocation-free.
local HOOK_OPTION_KEYS = { forceSecure = true }

-- The published surface, listed once so the public-surface predicate reads as
-- a checklist instead of a long boolean expression.
local FACADE_METHODS = { "CreateScope", "ForAddon", "CloseAddonScopes" }
local SCOPE_METHODS = {
    "SecureHook",
    "SecureHookScript",
    "Hook",
    "RawHook",
    "HookScript",
    "RawHookScript",
    "Unhook",
    "UnhookAll",
    "IsHooked",
    "Original",
    "Hooks",
    "Close",
    "IsClosed",
    "GetActiveCount",
    "GetAddonName",
}

-- Weak keys for every table keyed by a hooked object, so HookKit never keeps a
-- hooked table alive on its own account.
local WEAK_KEYS = { __mode = "k" }

-- Public types ---------------------------------------------------------------
--
-- HookKit publishes its methods by writing them onto a Registry-owned
-- prototype table, so the editor-facing contract is declared here as LuaCATS
-- classes rather than inferred from those assignments.

---Option table accepted by the non-secure hook methods.
---@class HookKit.HookOptions
---@field forceSecure boolean? Hook a secure target (or a script of a protected frame) non-securely anyway, accepting the taint.

---What a hook is: `"secure"`, `"secureScript"`, `"hook"`, `"rawHook"`, `"hookScript"` or `"rawHookScript"`.
---@alias HookKit.Kind "secure"|"secureScript"|"hook"|"rawHook"|"hookScript"|"rawHookScript"

---One row of `scope:Hooks()`.
---@class HookKit.HookInfo
---@field object table The hooked table or frame; `_G` for a global function.
---@field method string The method, global or script name.
---@field kind HookKit.Kind

---The owner of a set of hooks, released together by `UnhookAll` or `Close`.
---@class HookKit.Scope
---@field SecureHook fun(self: HookKit.Scope, objectOrGlobalName: table|string, methodOrHandler: string|function, handler: function?): true|nil, "full"?
---@field SecureHookScript fun(self: HookKit.Scope, frame: table, script: string, handler: function): true|nil, "full"?
---@field Hook fun(self: HookKit.Scope, objectOrGlobalName: table|string, methodOrHandler: string|function, handlerOrOptions: function|HookKit.HookOptions|nil, options: HookKit.HookOptions?): true|nil, "full"?
---@field RawHook fun(self: HookKit.Scope, objectOrGlobalName: table|string, methodOrHandler: string|function, handlerOrOptions: function|HookKit.HookOptions|nil, options: HookKit.HookOptions?): true|nil, "full"?
---@field HookScript fun(self: HookKit.Scope, frame: table, script: string, handler: function, options: HookKit.HookOptions?): true|nil, "full"?
---@field RawHookScript fun(self: HookKit.Scope, frame: table, script: string, handler: function, options: HookKit.HookOptions?): true|nil, "full"?
---@field Unhook fun(self: HookKit.Scope, objectOrGlobalName: table|string, method: string?): boolean
---@field UnhookAll fun(self: HookKit.Scope): integer
---@field IsHooked fun(self: HookKit.Scope, objectOrGlobalName: table|string, method: string?): boolean, HookKit.Kind?
---@field Original fun(self: HookKit.Scope, objectOrGlobalName: table|string, method: string?): function?
---@field Hooks fun(self: HookKit.Scope): HookKit.HookInfo[]
---@field Close fun(self: HookKit.Scope): boolean
---@field IsClosed fun(self: HookKit.Scope): boolean
---@field GetActiveCount fun(self: HookKit.Scope): integer
---@field GetAddonName fun(self: HookKit.Scope): string?

---The HookKit package facade published through Registry.
---@class HookKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field MAX_HOOKS integer The most hooks one scope holds at once.
---@field Scope HookKit.Scope Shared scope prototype.
---@field CreateScope fun(self: HookKit): HookKit.Scope
---@field ForAddon fun(self: HookKit, addonName: string): HookKit.Scope
---@field CloseAddonScopes fun(self: HookKit, addonName: string): boolean

-- Dependencies ---------------------------------------------------------------

-- The global table is what a global-function hook reads and writes, and what
-- `issecurevariable` inspects in its one-argument form.
-- selene: allow(global_usage)
local GLOBALS = _G

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
    error("MoltenCodes HookKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
if type(bootstrapPackage) ~= "function" then
    error("MoltenCodes HookKit requires a valid Registry API 2 facade", 2)
end

---Read an optional host function from the global table, or `nil`.
---@param name string
---@return function|nil
local function readHostFunction(name)
    -- Host APIs are World of Warcraft client functions reachable only through the global table.
    -- selene: allow(global_usage)
    local value = rawget(_G, name)
    if type(value) == "function" then
        return value
    end
    return nil
end

-- Every host facility is optional at load, so HookKit loads on any client and
-- outside one. The methods that need a facility refuse at the caller without
-- it; nothing else changes.
local nativeHookSecureFunc = readHostFunction("hooksecurefunc")
local nativeIsSecureVariable = readHostFunction("issecurevariable")
local nativeInCombatLockdown = readHostFunction("InCombatLockdown")
local nativeIsSecretValue = readHostFunction("issecretvalue")

-- Validation -----------------------------------------------------------------

---Whether every name in `methodNames` is a function field of `prototype`.
---@param prototype table
---@param methodNames string[]
---@return boolean
local function hasMethods(prototype, methodNames)
    for index = 1, #methodNames do
        if type(rawget(prototype, methodNames[index])) ~= "function" then
            return false
        end
    end
    return true
end

---Whether `implementation` exposes the complete HookKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
    if
        type(implementation) ~= "table"
        or rawget(implementation, "API") ~= API_GENERATION
        or type(rawget(implementation, "REVISION")) ~= "number"
        or type(rawget(implementation, "MAX_HOOKS")) ~= "number"
        or type(rawget(implementation, "Scope")) ~= "table"
    then
        return false
    end

    return hasMethods(implementation, FACADE_METHODS)
        and hasMethods(rawget(implementation, "Scope"), SCOPE_METHODS)
end

---Whether `currentState` has the fields every API 1 revision shares.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
    return type(currentState) == "table"
        and rawget(currentState, "schema") == STATE_SCHEMA
        and type(rawget(currentState, "dispatch")) == "table"
        and type(rawget(currentState, "runtimeRevision")) == "number"
        and type(rawget(currentState, "scopeMetatable")) == "table"
        and type(rawget(currentState, "addonScopes")) == "table"
        and type(rawget(currentState, "secureStatus")) == "table"
        and type(rawget(currentState, "secureScripts")) == "table"
end

---Whether `implementation` carries package state of this revision's schema.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
    return validateStateBase(rawget(implementation, "_state"))
end

-- Bootstrap ------------------------------------------------------------------

-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. What stays here is what only HookKit can answer.
local HookKit, previousRevision, selected = bootstrapPackage(Registry, {
    package = PACKAGE_NAME,
    api = API_GENERATION,
    revision = IMPLEMENTATION_REVISION,
    label = "MoltenCodes HookKit",
    validatePublicSurface = validatePublicSurface,
    validateState = validateCurrentState,
})

if HookKit == nil then
    -- An equal or newer compatible revision already owns the shared package table.
    return selected
end

local Scope = rawget(HookKit, "Scope")
local state = rawget(HookKit, "_state")

if previousRevision == nil then
    if Scope ~= nil or state ~= nil then
        error("MoltenCodes HookKit package state is corrupted or incomplete", 2)
    end

    Scope = {}
    state = {
        schema = STATE_SCHEMA,
        -- Every closure HookKit installs calls through this table, so a newer
        -- revision replaces the behaviour behind closures an older revision
        -- put in the host's call chain, including the permanent secure ones.
        dispatch = {},
        runtimeRevision = 0,
        scopeMetatable = {},
        -- Addon name to that addon's canonical scope.
        addonScopes = {},
        -- Hooked object to { [method] = boolean }: whether the target was
        -- secure before HookKit first hooked it non-securely. Weak-keyed so a
        -- hooked table is never kept alive for this memo.
        secureStatus = setmetatable({}, WEAK_KEYS),
        -- Frame to { [script] = count }: how many active SecureHookScript
        -- hooks HookKit holds on that script, across every scope. A script
        -- pre-hook or replacement calls `SetScript`, which may drop the host's
        -- `HookScript` hooks, so it is refused while this count is positive.
        secureScripts = setmetatable({}, WEAK_KEYS),
    }
    rawset(HookKit, "Scope", Scope)
    rawset(HookKit, "_state", state)
elseif type(Scope) ~= "table" or not validateStateBase(state) then
    error("MoltenCodes HookKit package state is corrupted or incomplete", 2)
end

-- The metatable and prototype are kept across upgrades, so scopes built by an
-- older copy keep their records and gain this copy's methods without being
-- replaced.
local SCOPE_METATABLE = rawget(state, "scopeMetatable")
local dispatch = rawget(state, "dispatch")
local addonScopes = rawget(state, "addonScopes")
local secureStatus = rawget(state, "secureStatus")
local secureScripts = rawget(state, "secureScripts")
rawset(SCOPE_METATABLE, "__index", Scope)

-- Error reporting ------------------------------------------------------------

---Hand a handler failure to the host error handler.
---
---The failure is passed on unchanged: it may be a secret string built from a
---secret argument, and HookKit never inspects it.
---@param failure any
local function reportError(failure)
    -- geterrorhandler is a World of Warcraft client API reachable only through the global table.
    -- selene: allow(global_usage)
    local getErrorHandler = rawget(_G, "geterrorhandler")
    if type(getErrorHandler) == "function" then
        local handler = getErrorHandler()
        if type(handler) == "function" then
            handler(failure)
            return
        end
    end

    -- Outside a WoW client there is no error handler to report through.
    -- Printing is what the client's own default handler does, and staying
    -- silent would turn a handler bug into an invisible one.
    print(failure)
end

---Whether `value` is a secret value, asking ClientKit when one is registered.
---
---Used only on argument paths, never on a hooked call, so the `Registry:Find`
---lookup costs nothing where it matters.
---@param value any
---@return boolean
local function isSecret(value)
    local findPackage = rawget(Registry, "Find")
    if type(findPackage) == "function" then
        local ClientKit = findPackage(Registry, "clientKit", OPTIONAL_CLIENTKIT_API)
        if type(ClientKit) == "table" then
            local clientIsSecret = rawget(ClientKit, "IsSecret")
            if type(clientIsSecret) == "function" then
                return clientIsSecret(ClientKit, value) == true
            end
        end
    end
    if nativeIsSecretValue ~= nil then
        return nativeIsSecretValue(value) == true
    end
    return false
end

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- HookKit. `level` is always the value `error` needs *inside the function that
-- receives it*, so every further hop towards `error` adds exactly one.

---@param scope any receiver the public method was called on
---@param methodName string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateScope(scope, methodName, level)
    if type(scope) ~= "table" or getmetatable(scope) ~= SCOPE_METATABLE then
        error(methodName .. " must be called on a HookKit scope", level)
    end
end

---@param scope HookKit.Scope
---@param methodName string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function ensureOpen(scope, methodName, level)
    if rawget(scope, "_closed") == true then
        error(methodName .. " cannot hook in a closed scope", level)
    end
end

---Refuse anything but a non-empty, non-secret string. The secret check comes
---before the emptiness comparison, which would raise on a secret.
---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateName(value, label, level)
    if type(value) ~= "string" then
        error(label .. " must be a non-empty string", level)
    end
    if isSecret(value) then
        error(label .. " must not be a secret value", level)
    end
    if value == "" then
        error(label .. " must be a non-empty string", level)
    end
end

---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateTable(value, label, level)
    if type(value) ~= "table" then
        error(label .. " must be a table", level)
    end
end

---@param value any
---@param methodName string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateHandler(value, methodName, level)
    if type(value) ~= "function" then
        error(methodName .. " handler must be a function", level)
    end
end

---Validate an option table and return whether it asks for `forceSecure`.
---@param options any
---@param methodName string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@return boolean forceSecure
local function readHookOptions(options, methodName, level)
    if options == nil then
        return false
    end
    if type(options) ~= "table" then
        error(methodName .. " options must be a table", level)
    end

    -- Report the alphabetically first unknown field without allocating: track
    -- the smallest key seen instead of collecting and sorting every offender.
    local firstUnknown = nil
    for key in next, options do
        if HOOK_OPTION_KEYS[key] ~= true then
            local text = type(key) == "string" and key or ("<" .. type(key) .. ">")
            if firstUnknown == nil or text < firstUnknown then
                firstUnknown = text
            end
        end
    end
    if firstUnknown ~= nil then
        error(methodName .. ' options contains unknown field "' .. firstUnknown .. '"', level)
    end

    local forceSecure = rawget(options, "forceSecure")
    if forceSecure ~= nil and type(forceSecure) ~= "boolean" then
        error(methodName .. " options.forceSecure must be a boolean", level)
    end
    return forceSecure == true
end

-- Target inspection ----------------------------------------------------------

---Find the table whose raw field holds `object[method]`: the object itself, or
---a table on its `__index` chain. `nil` when the chain passes through an
---`__index` function, a protected metatable, or more than `MAX_INDEX_DEPTH`
---tables.
---@param object table
---@param method string
---@return table|nil holder
local function findHolder(object, method)
    local current = object
    for _ = 0, MAX_INDEX_DEPTH do
        if rawget(current, method) ~= nil then
            return current
        end
        local metatable = getmetatable(current)
        if type(metatable) ~= "table" then
            return nil
        end
        local index = rawget(metatable, "__index")
        if type(index) ~= "table" then
            return nil
        end
        current = index
    end
    return nil
end

---Whether `object[method]` is secure, as it was before HookKit first hooked it
---non-securely.
---
---A non-secure hook taints the field it writes, so `issecurevariable` answers
---`false` afterwards even though the function behind it is Blizzard's. The
---first answer is therefore remembered per target, and every later check reads
---the memo. Without `issecurevariable` nothing is secure.
---
---The client reports an absent raw key as secure, so asking about the object
---itself would refuse every method it inherits. For an inherited method the
---question goes to the table that holds it (`findHolder`); a method behind an
---`__index` function cannot be located and is treated as not secure.
---@param object table the hooked table, or `_G` for a global
---@param method string
---@return boolean
local function wasSecure(object, method)
    local remembered = rawget(secureStatus, object)
    if remembered ~= nil then
        local status = rawget(remembered, method)
        if status ~= nil then
            return status
        end
    end

    local secure = false
    if nativeIsSecureVariable ~= nil then
        if object == GLOBALS then
            secure = nativeIsSecureVariable(method) == true
        else
            local holder = findHolder(object, method)
            if holder ~= nil then
                secure = nativeIsSecureVariable(holder, method) == true
            end
        end
    end

    if remembered == nil then
        remembered = {}
        rawset(secureStatus, object, remembered)
    end
    rawset(remembered, method, secure)
    return secure
end

---Whether HookKit may call methods on `frame` from the current execution:
---not forbidden, and (patch 12.1.0 and later) accessible in this context.
---Frames without the probes are accessible.
---@param frame table
---@return boolean
local function canTouchFrame(frame)
    local isForbidden = frame.IsForbidden
    if type(isForbidden) == "function" and isForbidden(frame) then
        return false
    end
    local canBeAccessed = frame.CanBeAccessedInContext
    if type(canBeAccessed) == "function" and not canBeAccessed(frame) then
        return false
    end
    return true
end

---Whether the host reports `frame` as protected. A frame without
---`IsProtected` (an addon table standing in for one) is not protected.
---@param frame table
---@return boolean
local function isProtectedFrame(frame)
    local isProtected = frame.IsProtected
    if type(isProtected) ~= "function" then
        return false
    end
    return isProtected(frame) == true
end

---Whether the player is in combat lockdown. Absent: never.
---@return boolean
local function inCombatLockdown()
    if nativeInCombatLockdown == nil then
        return false
    end
    return nativeInCombatLockdown() == true
end

-- Record table ---------------------------------------------------------------
--
-- A scope's records are `scope._records[object][method] = record`. The outer
-- table is weak-keyed and a record never references its object, so HookKit
-- keeps nothing alive on its own account. Reads never create anything: a
-- lookup of an object the scope never hooked is two table reads and a `nil`.

---@param scope HookKit.Scope
---@param object table
---@param method string
---@return table|nil record
local function findRecord(scope, object, method)
    local methods = rawget(rawget(scope, "_records"), object)
    if methods == nil then
        return nil
    end
    return rawget(methods, method)
end

---@param scope HookKit.Scope
---@param object table
---@param method string
---@param record table
local function storeRecord(scope, object, method, record)
    local records = rawget(scope, "_records")
    local methods = rawget(records, object)
    if methods == nil then
        methods = {}
        rawset(records, object, methods)
    end
    rawset(methods, method, record)
end

---@param scope HookKit.Scope
---@param object table
---@param method string
local function removeRecord(scope, object, method)
    local records = rawget(scope, "_records")
    local methods = rawget(records, object)
    rawset(methods, method, nil)
    if next(methods) == nil then
        rawset(records, object, nil)
    end
end

---Count a scope's live records.
---
---Counted rather than stored: the record table is weak-keyed, so the records of
---a hooked table that was garbage-collected disappear without HookKit being
---told, and a stored count would keep charging them against `MAX_HOOKS`. A
---scope holds at most `MAX_HOOKS` records, and neither caller is a hot path.
---@param scope HookKit.Scope
---@return integer
local function countRecords(scope)
    local count = 0
    for _, methods in next, rawget(scope, "_records") do
        for _ in next, methods do
            count = count + 1
        end
    end
    return count
end

---Create a record. Every field exists from the start, so no later write adds a
---key to it.
---@param scope HookKit.Scope
---@param kind HookKit.Kind
---@param handler function
---@return table record
local function newRecord(scope, kind, handler)
    local sequence = rawget(scope, "_sequence") + 1
    rawset(scope, "_sequence", sequence)
    return {
        _schema = RECORD_SCHEMA,
        _kind = kind,
        _handler = handler,
        -- The function the hook wraps or replaces; `false` for a secure hook
        -- and for a script that had no handler.
        _original = false,
        -- Whether the method was a raw field of the object (rather than found
        -- through `__index`) before the hook, which decides how it is restored.
        _hadRaw = false,
        -- The function HookKit installed; set once installation succeeded.
        _installed = false,
        -- The one flag the installed closure reads before dispatching.
        _active = true,
        _sequence = sequence,
    }
end

-- Installed closures ---------------------------------------------------------
--
-- One closure per hook, created when the hook is installed. Each reads the
-- record's `_active` flag, then calls through `dispatch`, so an upgrade changes
-- what an already-installed closure does. After `Unhook` a closure that could
-- not be removed stays in the host's chain with `_active == false`: it then
-- forwards to the original (pre-hook, replacement) or does nothing (post-hook).

---Call a post-hook or pre-hook handler with the call's arguments, reporting a
---failure to the host error handler instead of letting it break the host's
---call. The arguments, secrets included, are passed through untouched.
---@param record table
---@param ... any the hooked call's arguments
local function isolatedCall(record, ...)
    local ok, failure = pcall(rawget(record, "_handler"), ...)
    if not ok then
        reportError(failure)
    end
end

---Call a replacement handler with the original first and return its results.
---A failure propagates to the caller, as it would from the original.
---@param record table
---@param ... any the hooked call's arguments
---@return any ...
local function replacementCall(record, ...)
    local original = rawget(record, "_original")
    if original == false then
        original = nil
    end
    return rawget(record, "_handler")(original, ...)
end

---The closure a secure post-hook hands to `hooksecurefunc` or `HookScript`.
---@param record table
---@return function
local function newPostHookClosure(record)
    return function(...)
        if record._active then
            dispatch.isolatedCall(record, ...)
        end
    end
end

---The closure a pre-hook installs in place of the original.
---@param record table
---@return function
local function newPreHookClosure(record)
    return function(...)
        if record._active then
            dispatch.isolatedCall(record, ...)
        end
        local original = record._original
        if original then
            return original(...)
        end
    end
end

---The closure a replacement installs in place of the original.
---@param record table
---@return function
local function newReplacementClosure(record)
    return function(...)
        if record._active then
            return dispatch.replacementCall(record, ...)
        end
        local original = record._original
        if original then
            return original(...)
        end
    end
end

-- Installation ---------------------------------------------------------------

---Split the two call forms `(object, method, ...)` and `(globalName, ...)`.
---@param target any the first argument after `self`
---@param second any
---@param third any
---@param fourth any
---@return any object, any method, any third, any fourth
local function splitTarget(target, second, third, fourth)
    if type(target) == "string" then
        return GLOBALS, target, second, third
    end
    return target, second, third, fourth
end

---Check what every hook of a table field needs, before anything is installed.
---@param scope HookKit.Scope
---@param object any
---@param method any
---@param handler any
---@param methodName string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
local function validateMethodTarget(scope, object, method, handler, methodName, level)
    validateScope(scope, methodName, level + 1)
    ensureOpen(scope, methodName, level + 1)
    validateTable(object, methodName .. " object", level + 1)
    validateName(method, methodName .. " method", level + 1)
    validateHandler(handler, methodName, level + 1)
    if type(object[method]) ~= "function" then
        error(methodName .. ' target "' .. method .. '" is not a function', level)
    end
    if findRecord(scope, object, method) ~= nil then
        error(
            methodName .. ' "' .. method .. '" is already hooked in this scope; Unhook it first',
            level
        )
    end
end

---Check what every hook of a frame script needs, before anything is installed.
---@param scope HookKit.Scope
---@param frame any
---@param script any
---@param handler any
---@param hostMethods string[] frame methods the semantic calls
---@param methodName string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
local function validateScriptTarget(scope, frame, script, handler, hostMethods, methodName, level)
    validateScope(scope, methodName, level + 1)
    ensureOpen(scope, methodName, level + 1)
    validateTable(frame, methodName .. " frame", level + 1)
    validateName(script, methodName .. " script", level + 1)
    validateHandler(handler, methodName, level + 1)
    if not canTouchFrame(frame) then
        error(methodName .. " frame is forbidden or not accessible in this context", level)
    end
    for index = 1, #hostMethods do
        if type(frame[hostMethods[index]]) ~= "function" then
            error(methodName .. " frame must have a " .. hostMethods[index] .. " method", level)
        end
    end
    if findRecord(scope, frame, script) ~= nil then
        error(
            methodName .. ' "' .. script .. '" is already hooked in this scope; Unhook it first',
            level
        )
    end
end

local SECURE_SCRIPT_HOST_METHODS = { "HookScript" }
local REPLACE_SCRIPT_HOST_METHODS = { "GetScript", "SetScript" }

---Refuse a non-secure hook of a script the secure environment depends on.
---
---During combat lockdown HookKit declines to replace any script of a protected
---frame, as a conservative rule rather than a host restriction it relies on.
---@param frame table
---@param script string
---@param forceSecure boolean
---@param methodName string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
local function refuseProtectedScript(frame, script, forceSecure, methodName, level)
    if not isProtectedFrame(frame) then
        return
    end
    if PROTECTED_SCRIPTS[script] == true then
        error(
            methodName
                .. ' refuses to replace protected script "'
                .. script
                .. '" of a protected frame; use SecureHookScript',
            level
        )
    end
    if inCombatLockdown() then
        error(
            methodName .. " cannot replace a script of a protected frame during combat lockdown",
            level
        )
    end
    if not forceSecure then
        error(
            methodName
                .. ' refuses to replace script "'
                .. script
                .. '" of a protected frame; use SecureHookScript, or pass options.forceSecure',
            level
        )
    end
end

---Refuse a non-secure hook of a secure target unless the caller forces it.
---@param object table
---@param method string
---@param forceSecure boolean
---@param methodName string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function refuseSecureTarget(object, method, forceSecure, methodName, level)
    if wasSecure(object, method) and not forceSecure then
        error(
            methodName
                .. ' refuses to hook secure "'
                .. method
                .. '" non-securely; use SecureHook, or pass options.forceSecure',
            level
        )
    end
end

---Whether the scope has room for one more hook.
---@param scope HookKit.Scope
---@return boolean
local function hasRoom(scope)
    return countRecords(scope) < MAX_HOOKS
end

---Install a secure post-hook of a table field or global.
---@param scope HookKit.Scope
---@param target any
---@param second any
---@param third any
---@return true|nil installed
---@return "full"|nil reason
local function installSecureHook(scope, target, second, third)
    local methodName = "HookKit.Scope:SecureHook"
    local object, method, handler = splitTarget(target, second, third, nil)
    validateMethodTarget(scope, object, method, handler, methodName, 4)
    if nativeHookSecureFunc == nil then
        error(methodName .. " requires the host's hooksecurefunc", 3)
    end
    if not hasRoom(scope) then
        return nil, "full"
    end

    local record = newRecord(scope, KIND_SECURE, handler)
    local installed = newPostHookClosure(record)
    if object == GLOBALS then
        nativeHookSecureFunc(method, installed)
    else
        nativeHookSecureFunc(object, method, installed)
    end
    record._installed = installed
    storeRecord(scope, object, method, record)
    return true
end

---Install a pre-hook or a replacement of a table field or global.
---@param scope HookKit.Scope
---@param kind HookKit.Kind `"hook"` or `"rawHook"`
---@param methodName string qualified public method name, used in the argument errors
---@param target any
---@param second any
---@param third any
---@param fourth any
---@return true|nil installed
---@return "full"|nil reason
local function installFieldHook(scope, kind, methodName, target, second, third, fourth)
    local object, method, handler, options = splitTarget(target, second, third, fourth)
    validateMethodTarget(scope, object, method, handler, methodName, 4)
    local forceSecure = readHookOptions(options, methodName, 4)
    refuseSecureTarget(object, method, forceSecure, methodName, 4)
    if not hasRoom(scope) then
        return nil, "full"
    end

    local record = newRecord(scope, kind, handler)
    record._original = object[method]
    record._hadRaw = rawget(object, method) ~= nil
    local installed
    if kind == KIND_HOOK then
        installed = newPreHookClosure(record)
    else
        installed = newReplacementClosure(record)
    end
    record._installed = installed
    rawset(object, method, installed)
    storeRecord(scope, object, method, record)
    return true
end

---Install a secure post-hook of a frame script.
---@param scope HookKit.Scope
---@param frame any
---@param script any
---@param handler any
---@return true|nil installed
---@return "full"|nil reason
local function installSecureScriptHook(scope, frame, script, handler)
    local methodName = "HookKit.Scope:SecureHookScript"
    validateScriptTarget(scope, frame, script, handler, SECURE_SCRIPT_HOST_METHODS, methodName, 4)
    if not hasRoom(scope) then
        return nil, "full"
    end

    local record = newRecord(scope, KIND_SECURE_SCRIPT, handler)
    local installed = newPostHookClosure(record)
    frame:HookScript(script, installed)
    record._installed = installed
    storeRecord(scope, frame, script, record)
    local counts = rawget(secureScripts, frame)
    if counts == nil then
        counts = {}
        rawset(secureScripts, frame, counts)
    end
    rawset(counts, script, (rawget(counts, script) or 0) + 1)
    return true
end

---Install a pre-hook or a replacement of a frame script through `SetScript`.
---@param scope HookKit.Scope
---@param kind HookKit.Kind `"hookScript"` or `"rawHookScript"`
---@param methodName string qualified public method name, used in the argument errors
---@param frame any
---@param script any
---@param handler any
---@param options any
---@return true|nil installed
---@return "full"|nil reason
local function installScriptReplacement(scope, kind, methodName, frame, script, handler, options)
    validateScriptTarget(scope, frame, script, handler, REPLACE_SCRIPT_HOST_METHODS, methodName, 4)
    local forceSecure = readHookOptions(options, methodName, 4)
    refuseProtectedScript(frame, script, forceSecure, methodName, 4)
    local counts = rawget(secureScripts, frame)
    if counts ~= nil and rawget(counts, script) ~= nil then
        error(
            methodName
                .. ' refuses to replace script "'
                .. script
                .. '": HookKit holds a SecureHookScript post-hook on it, which SetScript may drop; '
                .. "Unhook it first, or install the pre-hook before the post-hook",
            3
        )
    end
    if not hasRoom(scope) then
        return nil, "full"
    end

    local record = newRecord(scope, kind, handler)
    local previous = frame:GetScript(script)
    if type(previous) == "function" then
        record._original = previous
    end
    local installed
    if kind == KIND_HOOK_SCRIPT then
        installed = newPreHookClosure(record)
    else
        installed = newReplacementClosure(record)
    end
    -- The host may refuse the script name; nothing is recorded until it accepts.
    frame:SetScript(script, installed)
    record._installed = installed
    storeRecord(scope, frame, script, record)
    return true
end

-- Release --------------------------------------------------------------------

---Undo one hook: remove the record, turn the closure inert, and restore the
---original only when the installed function is still HookKit's.
---
---A later hook by someone else wraps our closure; restoring the original under
---it would cut their hook out of the chain. The closure therefore stays where
---it is, inert, forwarding to the original for ever. A secure hook's closure is
---owned by the host and always stays.
---@param scope HookKit.Scope
---@param object table
---@param method string
---@param record table
local function releaseRecord(scope, object, method, record)
    removeRecord(scope, object, method)
    record._active = false

    local kind = rawget(record, "_kind")
    if kind == KIND_SECURE_SCRIPT then
        local counts = rawget(secureScripts, object)
        local count = counts and rawget(counts, method)
        if count ~= nil then
            if count <= 1 then
                rawset(counts, method, nil)
                if next(counts) == nil then
                    rawset(secureScripts, object, nil)
                end
            else
                rawset(counts, method, count - 1)
            end
        end
    end
    if SECURE_KINDS[kind] == true then
        return
    end

    local installed = rawget(record, "_installed")
    local original = rawget(record, "_original")
    if SCRIPT_KINDS[kind] == true then
        if not canTouchFrame(object) then
            -- A frame that became inaccessible keeps the inert closure.
            return
        end
        if object:GetScript(method) ~= installed then
            return
        end
        local secureCounts = rawget(secureScripts, object)
        if secureCounts ~= nil and rawget(secureCounts, method) ~= nil then
            -- A `SecureHookScript` post-hook was added after this pre-hook
            -- (the install order HookKit allows). `SetScript` may drop the
            -- host's `HookScript` hooks, so restoring would silently cut it
            -- out; the inert closure already forwards to the original.
            return
        end
        if isProtectedFrame(object) and inCombatLockdown() then
            -- As a conservative rule HookKit does not call `SetScript` on a
            -- protected frame during combat lockdown; the inert closure
            -- already forwards to the original.
            return
        end
        if original == false then
            original = nil
        end
        object:SetScript(method, original)
        return
    end

    if rawget(object, method) ~= installed then
        return
    end
    if rawget(record, "_hadRaw") == true then
        rawset(object, method, original)
    else
        -- The original came through `__index`; deleting the field lets it show
        -- through again, and leaves no value written by addon code behind.
        rawset(object, method, nil)
    end
end

---Collect every record of a scope, ordered by creation.
---
---Allocates three parallel arrays; used by `Hooks`, `UnhookAll` and `Close`,
---none of which is a hot path.
---@param scope HookKit.Scope
---@return table[] objects, string[] methods, table[] records, integer count
local function collectRecords(scope)
    local objects, methods, records = {}, {}, {}
    local count = 0
    for object, byMethod in next, rawget(scope, "_records") do
        for method, record in next, byMethod do
            -- Insertion sort by sequence: a scope holds at most MAX_HOOKS.
            local position = count + 1
            local sequence = rawget(record, "_sequence")
            while position > 1 and rawget(records[position - 1], "_sequence") > sequence do
                objects[position] = objects[position - 1]
                methods[position] = methods[position - 1]
                records[position] = records[position - 1]
                position = position - 1
            end
            objects[position] = object
            methods[position] = method
            records[position] = record
            count = count + 1
        end
    end
    return objects, methods, records, count
end

---Release every hook of a scope, newest first. Every release is attempted; the
---first failure is re-raised unchanged afterwards.
---@param scope HookKit.Scope
---@return integer released
local function releaseAll(scope)
    local objects, methods, records, count = collectRecords(scope)
    local firstFailure = nil
    local failed = false
    for index = count, 1, -1 do
        local ok, failure =
            pcall(releaseRecord, scope, objects[index], methods[index], records[index])
        if not ok and not failed then
            failed = true
            firstFailure = failure
        end
    end
    if failed then
        error(firstFailure, 0)
    end
    return count
end

---Resolve the two lookup forms `(object, method)` and `(globalName)` and
---validate them.
---@param target any
---@param method any
---@param methodName string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@return table object, string method
local function readLookup(target, method, methodName, level)
    if type(target) == "string" then
        validateName(target, methodName .. " globalName", level + 1)
        return GLOBALS, target
    end
    validateTable(target, methodName .. " object", level + 1)
    validateName(method, methodName .. " method", level + 1)
    return target, method
end

-- Scope methods --------------------------------------------------------------

---Post-hook a method with `hooksecurefunc`: `SecureHook(object, method, handler)`
---or `SecureHook(globalName, handler)`. The handler runs after the original with
---the same arguments; the target stays secure. Returns `nil, "full"` when the
---scope holds `MAX_HOOKS` hooks.
---@param self HookKit.Scope
---@param target table|string
---@param second string|function
---@param third function?
---@return true|nil installed
---@return "full"|nil reason
local function scopeSecureHook(self, target, second, third)
    -- Not a tail call: a tail call would hide this frame from `error` levels.
    local installed, reason = installSecureHook(self, target, second, third)
    return installed, reason
end

---Post-hook a frame script with `frame:HookScript`. The target stays secure.
---@param self HookKit.Scope
---@param frame table
---@param script string
---@param handler function
---@return true|nil installed
---@return "full"|nil reason
local function scopeSecureHookScript(self, frame, script, handler)
    local installed, reason = installSecureScriptHook(self, frame, script, handler)
    return installed, reason
end

---Pre-hook a method: `Hook(object, method, handler[, options])` or
---`Hook(globalName, handler[, options])`. The handler runs first and its errors
---are reported, the original always runs and its results are returned
---untouched. Taints the target.
---@param self HookKit.Scope
---@param target table|string
---@param second string|function
---@param third function|HookKit.HookOptions|nil
---@param fourth HookKit.HookOptions?
---@return true|nil installed
---@return "full"|nil reason
local function scopeHook(self, target, second, third, fourth)
    local installed, reason =
        installFieldHook(self, KIND_HOOK, "HookKit.Scope:Hook", target, second, third, fourth)
    return installed, reason
end

---Replace a method: `RawHook(object, method, handler[, options])` or
---`RawHook(globalName, handler[, options])`. The handler is called as
---`handler(original, ...)` and its results are returned. Taints the target.
---@param self HookKit.Scope
---@param target table|string
---@param second string|function
---@param third function|HookKit.HookOptions|nil
---@param fourth HookKit.HookOptions?
---@return true|nil installed
---@return "full"|nil reason
local function scopeRawHook(self, target, second, third, fourth)
    local installed, reason = installFieldHook(
        self,
        KIND_RAW_HOOK,
        "HookKit.Scope:RawHook",
        target,
        second,
        third,
        fourth
    )
    return installed, reason
end

---Pre-hook a frame script through `SetScript`, calling the previous script
---after the handler. Taints the script.
---@param self HookKit.Scope
---@param frame table
---@param script string
---@param handler function
---@param options HookKit.HookOptions?
---@return true|nil installed
---@return "full"|nil reason
local function scopeHookScript(self, frame, script, handler, options)
    local installed, reason = installScriptReplacement(
        self,
        KIND_HOOK_SCRIPT,
        "HookKit.Scope:HookScript",
        frame,
        script,
        handler,
        options
    )
    return installed, reason
end

---Replace a frame script through `SetScript`. The handler is called as
---`handler(previous, ...)`, where `previous` is the earlier script or `nil`.
---@param self HookKit.Scope
---@param frame table
---@param script string
---@param handler function
---@param options HookKit.HookOptions?
---@return true|nil installed
---@return "full"|nil reason
local function scopeRawHookScript(self, frame, script, handler, options)
    local installed, reason = installScriptReplacement(
        self,
        KIND_RAW_HOOK_SCRIPT,
        "HookKit.Scope:RawHookScript",
        frame,
        script,
        handler,
        options
    )
    return installed, reason
end

---Undo this scope's hook of `object[method]` (or of a global, or of a frame
---script). Returns `false` when this scope has no such hook.
---@param self HookKit.Scope
---@param target table|string
---@param method string?
---@return boolean released
local function scopeUnhook(self, target, method)
    validateScope(self, "HookKit.Scope:Unhook", 3)
    local object, name = readLookup(target, method, "HookKit.Scope:Unhook", 3)
    local record = findRecord(self, object, name)
    if record == nil then
        return false
    end
    releaseRecord(self, object, name, record)
    return true
end

---Undo every hook of this scope, newest first; the scope stays usable.
---@param self HookKit.Scope
---@return integer released
local function scopeUnhookAll(self)
    validateScope(self, "HookKit.Scope:UnhookAll", 3)
    return releaseAll(self)
end

---Whether this scope hooks `object[method]`, and with which kind.
---@param self HookKit.Scope
---@param target table|string
---@param method string?
---@return boolean hooked
---@return HookKit.Kind|nil kind
local function scopeIsHooked(self, target, method)
    validateScope(self, "HookKit.Scope:IsHooked", 3)
    local object, name = readLookup(target, method, "HookKit.Scope:IsHooked", 3)
    local record = findRecord(self, object, name)
    if record == nil then
        return false, nil
    end
    return true, rawget(record, "_kind")
end

---The function this scope's hook wraps or replaces, or `nil` for a secure hook,
---a script that had no handler, or a target this scope does not hook.
---@param self HookKit.Scope
---@param target table|string
---@param method string?
---@return function|nil original
local function scopeOriginal(self, target, method)
    validateScope(self, "HookKit.Scope:Original", 3)
    local object, name = readLookup(target, method, "HookKit.Scope:Original", 3)
    local record = findRecord(self, object, name)
    if record == nil then
        return nil
    end
    local original = rawget(record, "_original")
    if original == false then
        return nil
    end
    return original
end

---Enumerate this scope's hooks in creation order, for diagnostics. Allocates a
---new array of new rows on every call.
---@param self HookKit.Scope
---@return HookKit.HookInfo[] hooks
local function scopeHooks(self)
    validateScope(self, "HookKit.Scope:Hooks", 3)
    local objects, methods, records, count = collectRecords(self)
    local rows = {}
    for index = 1, count do
        rows[index] = {
            object = objects[index],
            method = methods[index],
            kind = rawget(records[index], "_kind"),
        }
    end
    return rows
end

---Close the scope: undo every hook, then refuse new ones. Terminal.
---@param self HookKit.Scope
---@return boolean closed `false` when the scope was already closed.
local function scopeClose(self)
    validateScope(self, "HookKit.Scope:Close", 3)
    if rawget(self, "_closed") == true then
        return false
    end
    rawset(self, "_closed", true)
    releaseAll(self)
    return true
end

---@param self HookKit.Scope
---@return boolean
local function scopeIsClosed(self)
    validateScope(self, "HookKit.Scope:IsClosed", 3)
    return rawget(self, "_closed") == true
end

---@param self HookKit.Scope
---@return integer
local function scopeGetActiveCount(self)
    validateScope(self, "HookKit.Scope:GetActiveCount", 3)
    return countRecords(self)
end

---@param self HookKit.Scope
---@return string|nil
local function scopeGetAddonName(self)
    validateScope(self, "HookKit.Scope:GetAddonName", 3)
    local addonName = rawget(self, "_addonName")
    if addonName == false then
        return nil
    end
    return addonName
end

-- Package public API ---------------------------------------------------------

---@param addonName string|false
---@return HookKit.Scope
local function newScope(addonName)
    return setmetatable({
        _schema = SCOPE_SCHEMA,
        _addonName = addonName,
        _closed = false,
        _sequence = 0,
        _records = setmetatable({}, WEAK_KEYS),
    }, SCOPE_METATABLE)
end

---Refuse a receiver other than the HookKit facade (a `.` call, say).
---@param receiver any
---@param label string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
    -- `rawequal`: the receiver is caller-supplied, and `~=` could run an
    -- `__eq` metamethod or raise on a secret value.
    if not rawequal(receiver, HookKit) then
        error(label .. " must be called on the HookKit facade; use " .. label .. "(...)", level)
    end
end

---Create a manually owned hook scope, closed only by its owner.
---@return HookKit.Scope scope
local function createScope()
    return newScope(false)
end

---Return the canonical hook scope of an addon, creating it on demand.
---
---HookKit does not observe addon shutdown; whoever does (LifecycleKit, or the
---addon itself on `PLAYER_LOGOUT`) closes this scope through
---`HookKit:CloseAddonScopes(addonName)`.
---@param self HookKit
---@param addonName string addon folder name
---@return HookKit.Scope scope
local function forAddon(self, addonName)
    validateFacade(self, "HookKit:ForAddon", 3)
    validateName(addonName, "HookKit:ForAddon addonName", 3)
    local scope = rawget(addonScopes, addonName)
    if scope == nil then
        scope = newScope(addonName)
        rawset(addonScopes, addonName, scope)
    end
    return scope
end

---Close the canonical scope of an addon, undoing every hook it owns.
---
---Closing is terminal: a later `ForAddon(addonName)` returns the closed scope,
---which refuses new hooks. Nothing is recorded for an addon that never asked
---for a scope, so the addon-scope map grows only with `ForAddon` calls.
---@param self HookKit
---@param addonName string addon folder name
---@return boolean closed `false` when the addon has no scope or it was already closed.
local function closeAddonScopes(self, addonName)
    validateFacade(self, "HookKit:CloseAddonScopes", 3)
    validateName(addonName, "HookKit:CloseAddonScopes addonName", 3)
    local scope = rawget(addonScopes, addonName)
    if scope == nil then
        return false
    end
    return scopeClose(scope)
end

-- Commit ---------------------------------------------------------------------

rawset(Scope, "SecureHook", scopeSecureHook)
rawset(Scope, "SecureHookScript", scopeSecureHookScript)
rawset(Scope, "Hook", scopeHook)
rawset(Scope, "RawHook", scopeRawHook)
rawset(Scope, "HookScript", scopeHookScript)
rawset(Scope, "RawHookScript", scopeRawHookScript)
rawset(Scope, "Unhook", scopeUnhook)
rawset(Scope, "UnhookAll", scopeUnhookAll)
rawset(Scope, "IsHooked", scopeIsHooked)
rawset(Scope, "Original", scopeOriginal)
rawset(Scope, "Hooks", scopeHooks)
rawset(Scope, "Close", scopeClose)
rawset(Scope, "IsClosed", scopeIsClosed)
rawset(Scope, "GetActiveCount", scopeGetActiveCount)
rawset(Scope, "GetAddonName", scopeGetAddonName)

rawset(HookKit, "API", API_GENERATION)
rawset(HookKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(HookKit, "MAX_HOOKS", MAX_HOOKS)
rawset(HookKit, "CreateScope", createScope)
rawset(HookKit, "ForAddon", forAddon)
rawset(HookKit, "CloseAddonScopes", closeAddonScopes)

rawset(dispatch, "isolatedCall", isolatedCall)
rawset(dispatch, "replacementCall", replacementCall)
rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(HookKit) or not validateCurrentState(HookKit) then
    error("MoltenCodes HookKit package state is corrupted or incomplete", 2)
end

return HookKit
