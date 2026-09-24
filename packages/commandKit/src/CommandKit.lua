-- MoltenCodes CommandKit
--
-- Slash commands for World of Warcraft addons, done once: registration owned by
-- a scope, an argument parser that keeps quoted text, hyperlinks and colour
-- codes whole, sub-commands whose usage text is generated from their
-- declarations, arguments checked against SchemaKit schemas, output written to
-- a replaceable sink, optional tab completion, and a binding that drives an
-- OptionsKit tree from the command line.
--
-- The client's slash tables are shared and collision-prone. CommandKit writes
-- `SlashCmdList[<key>]` and `SLASH_<key>1` through `rawset`, with a key derived
-- from the addon and command names, refuses a slash name another owner already
-- uses (`nil, "taken"`), and never removes what it wrote: the client caches the
-- function behind a slash name, so an unregistered command keeps a permanent
-- dispatcher that does nothing until the name is registered again.
--
-- CommandKit needs Registry API 2 and SchemaKit API 1. OptionsKit API 1
-- (`BindOptions`), LocaleKit API 1 (`Printf`) and ClientKit API 1 (`IsSecret`)
-- are optional and found through `Registry:Find` when they are used.
--
-- CommandKit does not depend on LifecycleKit, yet an addon scope is closed at
-- logout whenever the framework can observe logout at all (design
-- constitution, principle 4b). `ForAddon` arranges it through whichever of
-- LifecycleKit API 1 and EventKit API 1 is registered, both found through
-- `Registry:Find`: see "Logout close" below and "At logout" in `docs/API.md`.
--
-- Contents
-- --------
--   Constants ............. identity, bounds, field lists, method lists
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, SchemaKit and the host facilities read
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Host access ........... slash tables, the error handler, the secret probe
--   Argument checks ....... receivers, names, spec tables
--   Parser ................ the tokeniser behind Parse, ParseInto and dispatch
--   Output ................ sinks, the capture sink, line writing
--   Argument schemas ...... sealing, coercion and usage text from schemas
--   Command records ....... compiling a spec into an immutable record tree
--   Slash registration .... keys, the taken check, the permanent dispatchers
--   Dispatch .............. frames, sub-command walk, validation, the handler
--   Context methods ....... what a handler receives
--   Options binding ....... get, set, reset, list and exec over OptionsKit
--   Completion ............ the ChatEdit_CustomTabPressed replacement chain
--   Logout close .......... who closes an addon scope at logout
--   Scope methods ......... the handle a scope owner receives
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment and self-check
--
-- Layout and invariants are described in `docs/INTERNALS.md`.

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "commandKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 5
local REQUIRED_REGISTRY_API = 2
local REQUIRED_SCHEMAKIT_API = 1
local OPTIONAL_OPTIONSKIT_API = 1
local OPTIONAL_LOCALEKIT_API = 1
local OPTIONAL_CLIENTKIT_API = 1
local STATE_SCHEMA = 1

-- Every scope, command record and context carries the layout it was built
-- with, so a later revision that changes a layout can upgrade old objects
-- instead of guessing from which fields exist. Scope layout 2 (revision 2)
-- added the two logout fields, `_logoutCloser` and `_shutdownSubscription`.
local SCOPE_SCHEMA = 2
local RECORD_SCHEMA = 1
local CONTEXT_SCHEMA = 1

-- Who closes an addon scope at logout, as its `_logoutCloser` records it
-- (docs/API.md, "At logout"). A manual scope records `false`: nobody closes it
-- but its owner.
--
--   "lifecycleKit"   LifecycleKit names CommandKit in `CLOSES_ADDON_SCOPES`
--                    and closes the scope after the addon's shutdown callbacks.
--   "onShutdown"     an older LifecycleKit is registered: CommandKit
--                    subscribed to the addon's `OnShutdown`, kept in
--                    `_shutdownSubscription`.
--   "playerLogout"   no LifecycleKit, but EventKit: the package-level
--                    `PLAYER_LOGOUT` watcher closes the scope.
--   "none"           neither was registered; the next `ForAddon` asks again.
--
-- Only "none" and "playerLogout" are asked again: a LifecycleKit that loads
-- later still takes the scope over, so its shutdown callbacks run before the
-- scope closes.
--
-- The values, and the API generations of the two Kits asked, share one table:
-- the main chunk is close to Lua 5.1's limit of 200 locals.
local LOGOUT = {
    lifecycleKitApi = 1,
    eventKitApi = 1,
    byLifecycle = "lifecycleKit",
    byShutdownCallback = "onShutdown",
    byEvent = "playerLogout",
    byNobody = "none",
}

-- Scope limits (see "Limits" in docs/API.md). Each is a default a scope
-- option overrides with any positive integer or `CommandKit.UNBOUNDED`: all four
-- bound what the scope's own registrations cost, never a shared resource.

-- The most top-level commands one scope registers. Every slash name stays in
-- the client's tables for the session, so a scope that needs more than this
-- by default is almost certainly registering in a loop; `maxCommands` opens it.
local DEFAULT_MAX_COMMANDS = 64

-- The most sub-commands one command declares at one level (`maxSubcommands`).
local DEFAULT_MAX_SUBCOMMANDS = 64

-- The most per-position argument schemas one command declares (`maxPositions`).
local DEFAULT_MAX_POSITIONS = 16

-- How many `SLASH_<key><n>` globals the taken check reads per foreign key
-- (`maxSlashAliases`). The client itself stops at the first gap; the bound
-- only stops a pathological one, and the scan always ends at a gap.
local DEFAULT_MAX_SLASH_ALIASES = 16

-- Package-wide limits, shared by every consumer and set through
-- `CommandKit:SetLimits`.

-- The most lines a capture sink keeps (the oldest are dropped). A sink's lines
-- belong to whoever made it, so `UNBOUNDED` is accepted.
local DEFAULT_MAX_CAPTURED = 256

-- The most candidates one completion offers. They are printed to the chat
-- frame as one line, so the limit has a ceiling and refuses `UNBOUNDED`.
local DEFAULT_MAX_COMPLETIONS = 32
local MAX_COMPLETIONS_CEILING = 256

-- The emote indexes the emote check reads: `EMOTE<index>_CMD<n>` for index
-- 1..maxEmotes (or the host's `MAXEMOTEINDEX`, when it is a smaller number)
-- and n up to the first gap. Emote indexes have gaps, so the scan cannot stop
-- at the first one: it needs an end, and `UNBOUNDED` is refused.
local DEFAULT_MAX_EMOTES = 1024
local MAX_EMOTES_CEILING = 16384

-- Hard ceilings. These do not move, whatever a consumer asks for.

-- The deepest sub-command nesting: `/cmd one two three`. Compiling, usage
-- generation and dispatch recurse once per level, so the bound keeps the Lua
-- stack a command tree can use fixed.
local MAX_DEPTH = 3

-- How many dispatches may be in progress at once: a handler that runs another
-- slash command, which runs another, and so on. Each level reuses one frame of
-- buffers, so the bound is also the number of frames CommandKit ever keeps,
-- and it stops a command that runs itself before it exhausts the C stack.
local MAX_NESTING = 4

-- The commands per emote the emote check reads. The scan over
-- `EMOTE<n>_CMD<m>` stops at the first gap, but it needs an end that does not
-- trust the global table; the client defines at most a handful per emote.
local MAX_EMOTE_COMMANDS = 8

-- The longest command or sub-command name. The name becomes part of a
-- `SlashCmdList` key and of `SLASH_<key><n>` global names, which the client
-- keeps for the session; long keys are what the bound refuses.
local MAX_NAME_LENGTH = 32

-- The package-wide limits `SetLimits` accepts, in the order `GetLimits` and
-- the validation read them.
local LIMIT_NAMES = { "maxCaptured", "maxCompletions", "maxEmotes" }
-- A ceiling for the limits that refuse `UNBOUNDED`, and the reason given.
local LIMIT_CEILINGS = {
    maxCompletions = MAX_COMPLETIONS_CEILING,
    maxEmotes = MAX_EMOTES_CEILING,
}
local LIMIT_UNBOUNDED_REFUSALS = {
    maxCompletions = "the candidates are printed to the shared chat frame as one line",
    maxEmotes = "emote indexes have gaps, so the scan needs an end",
}

-- The limits a scope option accepts, with their defaults.
local SCOPE_OPTION_FIELDS = {
    maxCommands = DEFAULT_MAX_COMMANDS,
    maxSubcommands = DEFAULT_MAX_SUBCOMMANDS,
    maxPositions = DEFAULT_MAX_POSITIONS,
    maxSlashAliases = DEFAULT_MAX_SLASH_ALIASES,
}
local SCOPE_OPTION_NAMES = { "maxCommands", "maxSubcommands", "maxPositions", "maxSlashAliases" }

-- The prefix of every slash-table key CommandKit writes.
local KEY_PREFIX = "MOLTENCODES_"

-- The fields a command spec accepts.
local SPEC_FIELDS = {
    handler = true,
    arguments = true,
    usage = true,
    description = true,
    subcommands = true,
    complete = true,
}

-- The fields `BindOptions` accepts in its option table.
local BIND_OPTION_FIELDS = { description = true }

-- Words a boolean argument and a toggle option accept, lower-case.
local BOOLEAN_WORDS = {
    on = true,
    off = false,
    ["true"] = true,
    ["false"] = false,
    yes = true,
    no = false,
    ["1"] = true,
    ["0"] = false,
}

-- The published surface, listed once so the public-surface predicate reads as
-- a checklist instead of a long boolean expression.
local FACADE_METHODS = {
    "CreateScope",
    "ForAddon",
    "CloseAddonScopes",
    "Parse",
    "ParseInto",
    "CaptureSink",
    "SetLimits",
    "GetLimits",
}
local SCOPE_METHODS = {
    "Register",
    "Unregister",
    "IsRegistered",
    "SetSink",
    "BindOptions",
    "EnableCompletion",
    "DisableCompletion",
    "Close",
    "IsClosed",
    "GetActiveCount",
    "GetAddonName",
}
local CONTEXT_METHODS = {
    "Print",
    "Printf",
    "Usage",
    "Fail",
    "GetCommandPath",
    "GetRawText",
}

-- Byte values the parser compares against, so it never builds a
-- one-character string to compare.
local BYTE_SPACE = 32
local BYTE_TAB = 9
local BYTE_NEWLINE = 10
local BYTE_RETURN = 13
local BYTE_DOUBLE_QUOTE = 34
local BYTE_SINGLE_QUOTE = 39
local BYTE_BACKSLASH = 92
local BYTE_PIPE = 124
local BYTE_LINK = 72 -- "H": starts a hyperlink
local BYTE_COLOUR = 99 -- "c": starts a colour code
local BYTE_TEXTURE = 84 -- "T": starts a texture

-- Public types ---------------------------------------------------------------
--
-- CommandKit publishes its methods by writing them onto Registry-owned
-- prototype tables, so the editor-facing contract is declared here as LuaCATS
-- classes rather than inferred from those assignments.

---Anything that accepts a line of output. A chat frame is one.
---@class CommandKit.Sink
---@field AddMessage fun(self: CommandKit.Sink, text: string)

---The sink `CommandKit:CaptureSink()` returns, for tests.
---@class CommandKit.CaptureSink: CommandKit.Sink
---@field Messages fun(self: CommandKit.CaptureSink): string[]
---@field Clear fun(self: CommandKit.CaptureSink)

---What `Register` accepts for a command or a sub-command.
---@class CommandKit.CommandSpec
---@field handler (fun(context: CommandKit.Context, ...: any))? Runs the command with its checked arguments.
---@field arguments table? A `SchemaKit.array` schema, or a list of per-position schemas.
---@field usage string? What to type after the command path, for the usage line.
---@field description string? One line of help.
---@field subcommands table<string, CommandKit.CommandSpec>? Named sub-commands, at most three levels deep.
---@field complete (fun(context: CommandKit.Context, text: string, position: integer): string[]?)? Candidates for tab completion.

---What a handler, a completion function and the generated sub-commands
---receive. Valid only while the call that received it runs.
---@class CommandKit.Context
---@field Print fun(self: CommandKit.Context, ...: any)
---@field Printf fun(self: CommandKit.Context, template: string, ...: any)
---@field Usage fun(self: CommandKit.Context)
---@field Fail fun(self: CommandKit.Context, reason: string)
---@field GetCommandPath fun(self: CommandKit.Context): string
---@field GetRawText fun(self: CommandKit.Context): string

---Options accepted by `CreateScope` and `ForAddon`. Each limit is a positive
---integer or `CommandKit.UNBOUNDED`; see "Limits" in docs/API.md.
---@class CommandKit.ScopeOptions
---@field maxCommands (integer|table)? Most top-level commands the scope registers; default 64.
---@field maxSubcommands (integer|table)? Most sub-commands one command declares at one level; default 64.
---@field maxPositions (integer|table)? Most per-position argument schemas one command declares; default 16.
---@field maxSlashAliases (integer|table)? `SLASH_<key><n>` globals the taken check reads per foreign key; default 16.

---The package-wide limits, shared by every consumer in the session.
---`SetLimits` accepts any subset; `GetLimits` returns a fresh copy.
---@class CommandKit.Limits
---@field maxCaptured (integer|table)? Most lines a capture sink keeps; default 256, or `CommandKit.UNBOUNDED`.
---@field maxCompletions integer? Most candidates one completion offers; default 32, at most 256.
---@field maxEmotes integer? Emote indexes the emote check reads; default 1024, at most 16384.

---Option table accepted by `BindOptions`.
---@class CommandKit.BindOptions
---@field description string? The bound command's help line.

---The owner of a set of slash commands, released together by `Close`.
---@class CommandKit.Scope
---@field Register fun(self: CommandKit.Scope, name: string, spec: CommandKit.CommandSpec): true|nil, "taken"|"emote"|"full"|nil
---@field Unregister fun(self: CommandKit.Scope, name: string): boolean
---@field IsRegistered fun(self: CommandKit.Scope, name: string): boolean
---@field SetSink fun(self: CommandKit.Scope, sink: CommandKit.Sink?)
---@field BindOptions fun(self: CommandKit.Scope, tree: table, commandName: string, options: CommandKit.BindOptions?): true|nil, "taken"|"emote"|"full"|nil
---@field EnableCompletion fun(self: CommandKit.Scope): boolean
---@field DisableCompletion fun(self: CommandKit.Scope): boolean
---@field Close fun(self: CommandKit.Scope): boolean
---@field IsClosed fun(self: CommandKit.Scope): boolean
---@field GetActiveCount fun(self: CommandKit.Scope): integer
---@field GetAddonName fun(self: CommandKit.Scope): string?

---The CommandKit package facade published through Registry.
---@class CommandKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field MAX_COMMANDS integer The default `maxCommands` of a scope.
---@field MAX_DEPTH integer The deepest sub-command nesting, a hard ceiling.
---@field UNBOUNDED table Sentinel a limit accepts to lift it, where the memory is the consumer's own.
---@field Scope CommandKit.Scope Shared scope prototype.
---@field Context CommandKit.Context Shared context prototype.
---@field CreateScope fun(self: CommandKit, options: CommandKit.ScopeOptions?): CommandKit.Scope
---@field ForAddon fun(self: CommandKit, addonName: string, options: CommandKit.ScopeOptions?): CommandKit.Scope
---@field CloseAddonScopes fun(self: CommandKit, addonName: string): boolean
---@field Parse fun(self: CommandKit, text: string): string[]|nil, string?
---@field ParseInto fun(self: CommandKit, text: string, array: table): integer|nil, string?
---@field CaptureSink fun(self: CommandKit): CommandKit.CaptureSink
---@field SetLimits fun(self: CommandKit, limits: CommandKit.Limits)
---@field GetLimits fun(self: CommandKit): CommandKit.Limits

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
    error("MoltenCodes CommandKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local getPackage = rawget(Registry, "Get")
if type(bootstrapPackage) ~= "function" or type(getPackage) ~= "function" then
    error("MoltenCodes CommandKit requires a valid Registry API 2 facade", 2)
end

-- SchemaKit is required: argument schemas are sealed and checked with it, and
-- `BindOptions` builds its own. It is checked at load, so a missing one fails
-- loudly at this file instead of at the first `Register`.
local SchemaKit = getPackage(Registry, "schemaKit", REQUIRED_SCHEMAKIT_API)
if
    type(SchemaKit) ~= "table"
    or rawget(SchemaKit, "API") ~= REQUIRED_SCHEMAKIT_API
    or type(rawget(SchemaKit, "Seal")) ~= "function"
    or type(rawget(SchemaKit, "string")) ~= "function"
    or type(rawget(SchemaKit, "optional")) ~= "function"
then
    error("MoltenCodes CommandKit requires SchemaKit API 1 to be loaded first", 2)
end

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

---Whether `implementation` exposes the complete CommandKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
    if
        type(implementation) ~= "table"
        or rawget(implementation, "API") ~= API_GENERATION
        or type(rawget(implementation, "REVISION")) ~= "number"
        or type(rawget(implementation, "MAX_COMMANDS")) ~= "number"
        or type(rawget(implementation, "MAX_DEPTH")) ~= "number"
        or type(rawget(implementation, "UNBOUNDED")) ~= "table"
        or type(rawget(implementation, "Scope")) ~= "table"
        or type(rawget(implementation, "Context")) ~= "table"
    then
        return false
    end

    return hasMethods(implementation, FACADE_METHODS)
        and hasMethods(rawget(implementation, "Scope"), SCOPE_METHODS)
        and hasMethods(rawget(implementation, "Context"), CONTEXT_METHODS)
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
        and type(rawget(currentState, "contextMetatable")) == "table"
        and type(rawget(currentState, "addonScopes")) == "table"
        and type(rawget(currentState, "activeByName")) == "table"
        and type(rawget(currentState, "keyByName")) == "table"
        and type(rawget(currentState, "ownedKeys")) == "table"
        and type(rawget(currentState, "slashHandlers")) == "table"
        and type(rawget(currentState, "frames")) == "table"
        and type(rawget(currentState, "frameDepth")) == "number"
        and type(rawget(currentState, "completion")) == "table"
        and type(rawget(currentState, "unbounded")) == "table"
        and type(rawget(currentState, "limits")) == "table"
end

---Whether `implementation` carries package state of this revision's schema,
---and publishes the sentinel that state keeps.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
    local currentState = rawget(implementation, "_state")
    return validateStateBase(currentState)
        and rawget(implementation, "UNBOUNDED") == rawget(currentState, "unbounded")
        and type(rawget(currentState, "logoutWatch")) == "table"
end

-- Bootstrap ------------------------------------------------------------------

-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. What stays here is what only CommandKit can answer.
local CommandKit, previousRevision, selected = bootstrapPackage(Registry, {
    package = PACKAGE_NAME,
    api = API_GENERATION,
    revision = IMPLEMENTATION_REVISION,
    label = "MoltenCodes CommandKit",
    validatePublicSurface = validatePublicSurface,
    validateState = validateCurrentState,
})

if CommandKit == nil then
    -- An equal or newer compatible revision already owns the shared package table.
    return selected
end

local Scope = rawget(CommandKit, "Scope")
local Context = rawget(CommandKit, "Context")
local state = rawget(CommandKit, "_state")

if previousRevision == nil then
    if Scope ~= nil or Context ~= nil or state ~= nil then
        error("MoltenCodes CommandKit package state is corrupted or incomplete", 2)
    end

    Scope = {}
    Context = {}
    state = {
        schema = STATE_SCHEMA,
        -- Every closure CommandKit leaves in the client's tables calls through
        -- this table, so a newer revision replaces the behaviour behind slash
        -- dispatchers and the tab handler an older revision installed.
        dispatch = {},
        runtimeRevision = 0,
        scopeMetatable = {},
        contextMetatable = {},
        -- Addon name to that addon's canonical scope.
        addonScopes = {},
        -- Lower-case slash name to the active command record that owns it.
        activeByName = {},
        -- Lower-case slash name to the slash-table key it was first
        -- registered under. Kept for the session: the client caches the
        -- function behind a name, so a name keeps its key and its dispatcher.
        keyByName = {},
        -- Slash-table key to the lower-case name it serves, for every key
        -- CommandKit ever wrote. The taken check skips these keys, so it never
        -- mistakes CommandKit's own inert entries for another owner's, and the
        -- dispatcher under a key reads its name here.
        ownedKeys = {},
        -- Slash-table key to the permanent dispatcher closure written there.
        slashHandlers = {},
        -- Dispatch frames, one per nesting level, reused for every dispatch.
        frames = {},
        frameDepth = 0,
        -- The ChatEdit_CustomTabPressed replacement: whether it is installed,
        -- the function it replaced, the closure itself, and how many scopes
        -- have completion enabled.
        completion = {
            installed = false,
            previous = false,
            handler = false,
            enabledScopes = 0,
        },
        -- The `UNBOUNDED` sentinel. Kept here so every revision that inherits
        -- this state publishes the same table, and a limit set to it by one
        -- copy still reads as unbounded in the next.
        unbounded = {},
        -- The package-wide limits, shared by every consumer; `SetLimits`
        -- writes here and a newer revision inherits what was set.
        limits = {
            maxCaptured = DEFAULT_MAX_CAPTURED,
            maxCompletions = DEFAULT_MAX_COMPLETIONS,
            maxEmotes = DEFAULT_MAX_EMOTES,
        },
        -- The package-level `PLAYER_LOGOUT` watcher (see "Logout close"): the
        -- EventKit scope that owns it, the connection once made, and the
        -- trampoline handed to EventKit, which calls through `dispatch`.
        logoutWatch = { scope = false, connection = false, trampoline = false },
    }
    rawset(CommandKit, "Scope", Scope)
    rawset(CommandKit, "Context", Context)
    rawset(CommandKit, "_state", state)
elseif type(Scope) ~= "table" or type(Context) ~= "table" or not validateStateBase(state) then
    error("MoltenCodes CommandKit package state is corrupted or incomplete", 2)
end

-- Revision 1 kept no logout watcher and built scope layout 1. The watcher
-- table is added, and every addon scope gains the two logout fields: nobody
-- has arranged its logout close yet, which the bottom of this file and the
-- next `ForAddon` do. A manual scope needs neither field and is left as built.
if rawget(state, "logoutWatch") == nil then
    rawset(state, "logoutWatch", { scope = false, connection = false, trampoline = false })
end
for _, addonScope in next, rawget(state, "addonScopes") do
    if rawget(addonScope, "_schema") == 1 then
        rawset(addonScope, "_logoutCloser", LOGOUT.byNobody)
        rawset(addonScope, "_shutdownSubscription", false)
        rawset(addonScope, "_schema", SCOPE_SCHEMA)
    end
end

-- The metatables and prototypes are kept across upgrades, so scopes and
-- contexts built by an older copy keep their records and gain this copy's
-- methods without being replaced.
local SCOPE_METATABLE = rawget(state, "scopeMetatable")
local CONTEXT_METATABLE = rawget(state, "contextMetatable")
local dispatch = rawget(state, "dispatch")
local addonScopes = rawget(state, "addonScopes")
local activeByName = rawget(state, "activeByName")
local keyByName = rawget(state, "keyByName")
local ownedKeys = rawget(state, "ownedKeys")
local slashHandlers = rawget(state, "slashHandlers")
local frames = rawget(state, "frames")
local completion = rawget(state, "completion")
local UNBOUNDED = rawget(state, "unbounded")
local sharedLimits = rawget(state, "limits")
rawset(SCOPE_METATABLE, "__index", Scope)
rawset(CONTEXT_METATABLE, "__index", Context)

-- Host access ----------------------------------------------------------------
--
-- Every host facility is read from the global table when it is used, never
-- cached at load: the slash tables and the chat frame exist by the time an
-- addon registers a command, whatever order the files loaded in.

---Read a host global without triggering a metatable on the global table.
---@param name string
---@return any
local function readGlobal(name)
    -- The slash tables, the chat frame and the host probes are World of Warcraft client globals.
    -- selene: allow(global_usage)
    return rawget(_G, name)
end

---Write a host global without triggering a metatable on the global table.
---@param name string
---@param value any
local function writeGlobal(name, value)
    -- `SLASH_<key>1` and `ChatEdit_CustomTabPressed` are client globals an addon writes to extend the chat box.
    -- selene: allow(global_usage)
    rawset(_G, name, value)
end

---Find an optional package through `Registry:Find`, or `nil`.
---@param packageName string
---@param api integer
---@return table|nil
local function findOptional(packageName, api)
    local findPackage = rawget(Registry, "Find")
    if type(findPackage) ~= "function" then
        return nil
    end
    local found = findPackage(Registry, packageName, api)
    if type(found) == "table" then
        return found
    end
    return nil
end

---Hand a failure to the host error handler.
---
---The failure is passed on unchanged: it may be a secret string built from a
---secret argument, and CommandKit never inspects it.
---@param failure any
local function reportError(failure)
    local getErrorHandler = readGlobal("geterrorhandler")
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

---Whether `value` is a secret value, asking ClientKit when one is registered
---and the host's `issecretvalue` otherwise. It looks ClientKit up on every
---call, so the allocation-free dispatch path never calls it: typed text is
---never secret. Only failures, output and the options binding do.
---@param value any
---@return boolean
local function isSecret(value)
    local ClientKit = findOptional("clientKit", OPTIONAL_CLIENTKIT_API)
    if ClientKit ~= nil then
        local clientIsSecret = rawget(ClientKit, "IsSecret")
        if type(clientIsSecret) == "function" then
            return clientIsSecret(ClientKit, value) == true
        end
    end
    local probe = readGlobal("issecretvalue")
    return type(probe) == "function" and probe(value) == true
end

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- CommandKit. `level` is always the value `error` needs *inside the function
-- that receives it*, so every further hop towards `error` adds exactly one.

---The metatable of a caller's table, or `nil` for anything else.
---
---`getmetatable` answers a table's `__metatable` field, which may hold
---anything, a secret included, so callers test the result's type before they
---compare it, and this function never tests its truth.
---@param value any
---@return any metatable
local function readMetatable(value)
    if type(value) ~= "table" then
        return nil
    end
    return getmetatable(value)
end

---@param scope any receiver the public method was called on
---@param methodName string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateScope(scope, methodName, level)
    local metatable = readMetatable(scope)
    if type(metatable) ~= "table" or metatable ~= SCOPE_METATABLE then
        error(methodName .. " must be called on a CommandKit scope", level)
    end
end

---@param scope CommandKit.Scope
---@param methodName string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function ensureOpen(scope, methodName, level)
    if rawget(scope, "_closed") == true then
        error(methodName .. " cannot be used on a closed scope", level)
    end
end

---Refuse a receiver other than the CommandKit facade (a `.` call, say). The
---type is tested first: a `.` call passes the first argument as the receiver,
---and only a table is ever compared with the facade.
---@param receiver any
---@param label string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
    if type(receiver) ~= "table" or receiver ~= CommandKit then
        error(label .. " must be called on the CommandKit facade; use " .. label .. "(...)", level)
    end
end

---Refuse anything but a non-empty, non-secret string. The secret check comes
---before the emptiness comparison, which would raise on a secret.
---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateString(value, label, level)
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

---Refuse anything but a command or sub-command name: letters, digits and
---underscores, starting with a letter, at most `MAX_NAME_LENGTH` bytes.
---Returns the name in lower case, the form every lookup uses.
---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
---@return string name
local function readCommandName(value, label, level)
    validateString(value, label, level + 1)
    if #value > MAX_NAME_LENGTH or value:find("^%a[%w_]*$") == nil then
        error(
            label
                .. ' "'
                .. value
                .. '" must be letters, digits and underscores, starting with a letter, at most '
                .. MAX_NAME_LENGTH
                .. " long",
            level
        )
    end
    return value:lower()
end

---Refuse a table field that is present but not a string.
---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateOptionalString(value, label, level)
    local valueType = type(value)
    if valueType ~= "nil" and valueType ~= "string" then
        error(label .. " must be a string", level)
    end
end

---Refuse a table with a field outside `accepted`, naming the alphabetically
---first unknown one, without allocating.
---@param value table
---@param accepted table<string, boolean>
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function refuseUnknownFields(value, accepted, label, level)
    local firstUnknown = nil
    for key in next, value do
        if accepted[key] ~= true then
            local text = type(key) == "string" and key or ("<" .. type(key) .. " key>")
            if firstUnknown == nil or text < firstUnknown then
                firstUnknown = text
            end
        end
    end
    if firstUnknown ~= nil then
        error(label .. ' contains unknown field "' .. firstUnknown .. '"', level)
    end
end

-- Parser ---------------------------------------------------------------------
--
-- One pass over the text, byte by byte, with no state outside the call. A
-- token is one or more adjacent segments, joined: a quoted segment
-- (`"double"`, or `'single'` when it closes before a boundary) or a bare run of
-- non-whitespace bytes. Inside a bare run, escape sequences the client
-- displays as one unit are kept whole even when they contain spaces:
--
--   `|H<data>|h<text>|h`   a hyperlink; its text is usually `[Name With Spaces]`
--   `|c<colour><text>|r`   colour-wrapped text, often around a hyperlink
--   `|T<texture>|t`        an inline texture
--   `||`                   an escaped pipe
--
-- The state machine is drawn in `docs/INTERNALS.md`.

---Whether `byte` is whitespace between tokens.
---@param byte integer|nil
---@return boolean
local function isSpace(byte)
    return byte == BYTE_SPACE or byte == BYTE_TAB or byte == BYTE_NEWLINE or byte == BYTE_RETURN
end

---Whether `byte` is a quote character.
---@param byte integer|nil
---@return boolean
local function isQuote(byte)
    return byte == BYTE_DOUBLE_QUOTE or byte == BYTE_SINGLE_QUOTE
end

---Skip one escape sequence that starts with the pipe at `position`, and return
---the position after it. A hyperlink without both of its `|h` markers is
---refused. A colour code groups its text only when its `|r` comes before the
---next `|c`, so an unclosed colour never swallows text up to another colour's
---`|r`. Anything else, an unclosed colour code or texture included, skips the
---pipe alone: the byte after it is read normally, so a pipe before whitespace
---or a closing quote never hides it.
---@param text string
---@param position integer the position of a `|`
---@param length integer `#text`
---@param inQuotes boolean whether the sequence is inside a quoted segment
---@return integer|nil nextPosition
---@return string|nil reason
local function skipEscape(text, position, length, inQuotes)
    if position >= length then
        return position + 1
    end
    local marker = text:byte(position + 1)
    if marker == BYTE_PIPE then
        return position + 2
    end
    if marker == BYTE_LINK then
        local dataEnd = text:find("|h", position + 2, true)
        if dataEnd == nil then
            return nil, "unterminated link"
        end
        local textEnd = text:find("|h", dataEnd + 2, true)
        if textEnd == nil then
            return nil, "unterminated link"
        end
        return textEnd + 2
    end
    -- Inside quotes only the closing quote ends the segment, so a colour code
    -- or texture needs no grouping there; a hyperlink still does, because its
    -- text may contain a quote.
    if not inQuotes then
        if marker == BYTE_COLOUR then
            local close = text:find("|r", position + 2, true)
            if close ~= nil then
                local nextColour = text:find("|c", position + 2, true)
                if nextColour == nil or nextColour > close then
                    return close + 2
                end
            end
        elseif marker == BYTE_TEXTURE then
            local close = text:find("|t", position + 2, true)
            if close ~= nil then
                return close + 2
            end
        end
    end
    return position + 1
end

---Find the closing quote of a quoted segment opened at `position`. A
---backslash before the quote character or before another backslash escapes
---it.
---@param text string
---@param position integer the position of the opening quote
---@param length integer
---@param quote integer the quote byte
---@return integer|nil close the position of the closing quote
---@return boolean|string escapedOrReason whether an escape was seen, or why there is no close
local function findClosingQuote(text, position, length, quote)
    local cursor = position + 1
    local escaped = false
    while cursor <= length do
        local byte = text:byte(cursor)
        if byte == BYTE_BACKSLASH then
            local nextByte = text:byte(cursor + 1)
            if nextByte == quote or nextByte == BYTE_BACKSLASH then
                escaped = true
                cursor = cursor + 2
            else
                cursor = cursor + 1
            end
        elseif byte == quote then
            return cursor, escaped
        elseif byte == BYTE_PIPE then
            local nextPosition, reason = skipEscape(text, cursor, length, true)
            if nextPosition == nil then
                return nil, reason --[[@as string]]
            end
            cursor = nextPosition
        else
            cursor = cursor + 1
        end
    end
    return nil, "unterminated quote"
end

---Remove the escapes from a quoted segment's text.
---@param segment string
---@param quote integer the quote byte
---@return string
local function unescape(segment, quote)
    if quote == BYTE_DOUBLE_QUOTE then
        return (segment:gsub('\\([\\"])', "%1"))
    end
    return (segment:gsub("\\([\\'])", "%1"))
end

---Read a bare run starting at `position`, up to whitespace or the end.
---@param text string
---@param position integer
---@param length integer
---@return string|nil segment
---@return integer|string nextPositionOrReason
local function readBare(text, position, length)
    local cursor = position
    while cursor <= length do
        local byte = text:byte(cursor)
        if isSpace(byte) then
            break
        end
        if byte == BYTE_PIPE then
            local nextPosition, reason = skipEscape(text, cursor, length, false)
            if nextPosition == nil then
                return nil, reason --[[@as string]]
            end
            cursor = nextPosition
        else
            cursor = cursor + 1
        end
    end
    return text:sub(position, cursor - 1), cursor
end

---Read one token starting at `position`: adjacent segments, joined.
---
---A quote opens a quoted segment at the start of a token or right after a
---quoted segment closed. A double quote always does, and an unclosed one is
---refused. A single quote does only when its closing quote is followed by
---whitespace, the end of the text or another quote; otherwise it is an
---apostrophe (`'twas`, `it's`) and the rest of the token is a bare run.
---@param text string
---@param position integer
---@param length integer
---@return string|nil token
---@return integer|string nextPositionOrReason
local function readToken(text, position, length)
    local token = nil
    local cursor = position
    local quoteMayOpen = true
    while cursor <= length do
        local byte = text:byte(cursor)
        if isSpace(byte) then
            break
        end
        local segment
        ---@type integer|nil
        local close = nil
        ---@type boolean|string
        local escapedOrReason = false
        if quoteMayOpen and isQuote(byte) then
            close, escapedOrReason = findClosingQuote(text, cursor, length, byte)
            if close == nil and byte == BYTE_DOUBLE_QUOTE then
                return nil, escapedOrReason --[[@as string]]
            end
            if close ~= nil and byte == BYTE_SINGLE_QUOTE then
                local after = text:byte(close + 1)
                if after ~= nil and not isSpace(after) and not isQuote(after) then
                    close = nil
                end
            end
        end
        if close ~= nil then
            segment = text:sub(cursor + 1, close - 1)
            if escapedOrReason == true then
                segment = unescape(segment, byte)
            end
            cursor = close + 1
            quoteMayOpen = true
        else
            local nextPosition
            segment, nextPosition = readBare(text, cursor, length)
            if segment == nil then
                return nil, nextPosition
            end
            cursor = nextPosition --[[@as integer]]
            quoteMayOpen = false
        end
        if token == nil then
            token = segment
        else
            token = token .. segment
        end
    end
    return token, cursor
end

---Tokenise `text` into `array[1..count]` and clear every slot after `count`.
---On a refusal the array is left empty.
---
---Allocates nothing but the token strings, and a token string equal to one
---that already exists is the existing string, so parsing the same text twice
---allocates nothing the second time.
---@param text string
---@param array table
---@return integer|nil count
---@return string|nil reason
local function tokenize(text, array)
    local length = #text
    local count = 0
    local position = 1
    local failure = nil
    while position <= length do
        if isSpace(text:byte(position)) then
            position = position + 1
        else
            local token, nextPosition = readToken(text, position, length)
            if token == nil then
                failure = nextPosition
                break
            end
            count = count + 1
            array[count] = token
            position = nextPosition --[[@as integer]]
        end
    end

    local first = count + 1
    if failure ~= nil then
        first = 1
    end
    local index = first
    while rawget(array, index) ~= nil do
        array[index] = nil
        index = index + 1
    end
    if failure ~= nil then
        return nil, failure --[[@as string]]
    end
    return count
end

-- Output ---------------------------------------------------------------------

---Write one line to the scope's sink, or to the default chat frame, or to
---`print` outside the client.
---@param scope CommandKit.Scope
---@param text string
local function writeLine(scope, text)
    local sink = rawget(scope, "_sink")
    if sink == false then
        sink = readGlobal("DEFAULT_CHAT_FRAME")
    end
    if type(sink) == "table" and type(sink.AddMessage) == "function" then
        sink:AddMessage(text)
        return
    end
    print(text)
end

---Write every line of `lines` to the scope's sink.
---@param scope CommandKit.Scope
---@param lines string[]
local function writeLines(scope, lines)
    for index = 1, #lines do
        writeLine(scope, lines[index])
    end
end

---Build a sink that keeps what it receives, for tests. Keeps the most recent
---`maxCaptured` lines, read from the shared limits on every line; a sink
---already longer than a lowered limit keeps its length instead of shrinking.
---@return CommandKit.CaptureSink
local function newCaptureSink()
    local messages = {}
    local sink = {}

    function sink.AddMessage(_, text)
        local maxCaptured = rawget(sharedLimits, "maxCaptured")
        if maxCaptured ~= UNBOUNDED and #messages >= maxCaptured then
            table.remove(messages, 1)
        end
        messages[#messages + 1] = text
    end

    function sink.Messages(_)
        local copy = {}
        for index = 1, #messages do
            copy[index] = messages[index]
        end
        return copy
    end

    function sink.Clear(_)
        for index = #messages, 1, -1 do
            messages[index] = nil
        end
    end

    return sink
end

-- Argument schemas -----------------------------------------------------------
--
-- A command declares its arguments either as one `SchemaKit.array` schema, or
-- as a list of per-position schemas. Tokens arrive as strings, so each
-- position (or the array's element) is given a coercion when the command is
-- registered, read from the schema's own description: a number schema turns
-- the token into a number with `tonumber`, a boolean schema accepts the words
-- in `BOOLEAN_WORDS`, and everything else stays a string. A token that does
-- not convert stays a string, and the schema refuses it with its own message.

-- The names `getmetatable` returns for SchemaKit nodes and sealed schemas,
-- which set `__metatable`. Used only to tell a schema from a plain list.
local SCHEMA_METATABLE_NAMES = { ["SchemaKit.Schema"] = true, ["SchemaKit.Node"] = true }

---Whether `value` is a SchemaKit node or sealed schema.
---@param value any
---@return boolean
local function isSchema(value)
    return type(value) == "table" and SCHEMA_METATABLE_NAMES[getmetatable(value)] == true
end

---Seal a node or schema, or raise at the caller naming `label`.
---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
---@return table schema
local function sealSchema(value, label, level)
    if not isSchema(value) then
        error(label .. " must be a SchemaKit schema", level)
    end
    local ok, schema = pcall(rawget(SchemaKit, "Seal"), SchemaKit, value)
    if not ok then
        error(label .. " must be a SchemaKit schema", level)
    end
    return schema
end

---Whether every entry of `values` has the Lua type `typeName`.
---@param values any[]
---@param typeName string
---@return boolean
local function allOfType(values, typeName)
    for index = 1, #values do
        if type(values[index]) ~= typeName then
            return false
        end
    end
    return #values > 0
end

---The coercion a token needs before a schema described by `description`
---checks it: `"number"`, `"boolean"` or `"string"` (none).
---@param description table a SchemaKit description
---@return string
local function coercionOf(description)
    local kind = description.kind
    if kind == "number" or kind == "boolean" then
        return kind
    end
    if kind == "enum" then
        if allOfType(description.values, "number") then
            return "number"
        end
        if allOfType(description.values, "boolean") then
            return "boolean"
        end
    end
    return "string"
end

---Convert one token as `coercion` says; a token that does not convert is
---returned unchanged, for the schema to refuse.
---@param token any
---@param coercion string
---@return any
local function coerce(token, coercion)
    if type(token) ~= "string" then
        return token
    end
    if coercion == "number" then
        local number = tonumber(token)
        if number ~= nil then
            return number
        end
    elseif coercion == "boolean" then
        local word = BOOLEAN_WORDS[token:lower()]
        if word ~= nil then
            return word
        end
    end
    return token
end

---Join the string forms of `values` with `separator`.
---@param values any[]
---@param separator string
---@return string
local function joinValues(values, separator)
    local parts = {}
    for index = 1, #values do
        parts[index] = tostring(values[index])
    end
    return table.concat(parts, separator)
end

---The usage word of one argument, from its schema description: `<number>`,
---`<integer 1..10>`, `<on|off>`, `<a|b|c>`, `<text>`; square brackets when the
---argument may be left out.
---@param description table a SchemaKit description
---@return string
local function usageWord(description)
    local kind = description.kind
    local word
    if kind == "number" then
        word = description.integer and "integer" or "number"
        if type(description.min) ~= "nil" and type(description.max) ~= "nil" then
            word = word .. " " .. tostring(description.min) .. ".." .. tostring(description.max)
        end
    elseif kind == "boolean" then
        word = "on|off"
    elseif kind == "enum" then
        word = joinValues(description.values, "|")
    elseif kind == "string" then
        if type(description.oneOf) == "table" then
            word = joinValues(description.oneOf, "|")
        else
            word = "text"
        end
    elseif kind == "array" then
        word = usageWord(description.of):sub(2, -2) .. "..."
        local min = description.min
        if type(min) == "nil" or (type(min) == "number" and not isSecret(min) and min == 0) then
            return "[" .. word .. "]"
        end
        return "<" .. word .. ">"
    else
        word = kind
    end
    if description.optional then
        return "[" .. word .. "]"
    end
    return "<" .. word .. ">"
end

---Compile a spec's `arguments` field.
---@param arguments any
---@param label string argument description, used in the argument errors
---@param level integer stack level the failures are reported at
---@param maxPositions number the scope's `maxPositions`, `math.huge` when unbounded
---@return table compiled `{ mode, schemas, coercions, defaulted, count, usage }`
local function compileArguments(arguments, label, level, maxPositions)
    local compiled =
        { mode = "none", schemas = {}, coercions = {}, defaulted = {}, count = 0, usage = "" }
    if type(arguments) == "nil" then
        return compiled
    end
    if isSchema(arguments) then
        local schema = sealSchema(arguments, label, level + 1)
        local description = schema:Describe()
        if description.kind ~= "array" then
            error(label .. " must be a SchemaKit.array schema or a list of schemas", level)
        end
        compiled.mode = "array"
        compiled.schemas[1] = schema
        compiled.coercions[1] = coercionOf(description.of)
        compiled.usage = usageWord(description)
        return compiled
    end
    if type(arguments) ~= "table" or type(getmetatable(arguments)) ~= "nil" then
        error(label .. " must be a SchemaKit.array schema or a list of schemas", level)
    end
    local count = 0
    for key in next, arguments do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > maxPositions then
            if maxPositions == math.huge then
                error(label .. " must be a list of schemas", level)
            end
            error(label .. " must be a list of at most " .. maxPositions .. " schemas", level)
        end
        count = count + 1
    end
    if count == 0 or type(arguments[count]) == "nil" then
        error(label .. " must be a non-empty list of schemas without holes", level)
    end
    local words = {}
    for position = 1, count do
        local schema = sealSchema(arguments[position], label .. "[" .. position .. "]", level + 1)
        local description = schema:Describe()
        compiled.schemas[position] = schema
        compiled.coercions[position] = coercionOf(description)
        compiled.defaulted[position] = type(description.default) ~= "nil"
        words[position] = usageWord(description)
    end
    compiled.mode = "positions"
    compiled.count = count
    compiled.usage = table.concat(words, " ")
    return compiled
end

---The message for a refused argument, from a SchemaKit failure. Read at once:
---the failure table belongs to the schema and is reused.
---@param prefix string `"argument 2"` or `"arguments"`
---@param failure table
---@return string
local function describeFailure(prefix, failure)
    local path = failure.path
    local where = prefix
    if type(path) == "string" and path ~= "" then
        if path:sub(1, 1) == "[" then
            where = prefix .. path
        else
            where = prefix .. "." .. path
        end
    end
    return where
        .. ": expected "
        .. tostring(failure.expected)
        .. ", found "
        .. tostring(failure.found)
end

-- Command records ------------------------------------------------------------
--
-- `Register` compiles a spec into a record tree once. Records are never
-- modified afterwards; dispatch only reads them.

---The text after the command path in a usage line.
---@param record table
---@return string
local function usageTail(record)
    local usage = rawget(record, "_usage")
    if usage ~= "" then
        return " " .. usage
    end
    return ""
end

---Build the lines `context:Usage()` prints for `record`.
---@param record table
---@return string[]
local function buildUsageLines(record)
    local lines = { "Usage: " .. rawget(record, "_path") .. usageTail(record) }
    local description = rawget(record, "_description")
    if description ~= false then
        lines[#lines + 1] = description
    end
    local names = rawget(record, "_subcommandNames")
    local subcommands = rawget(record, "_subcommands")
    for index = 1, #names do
        local child = rawget(subcommands, names[index])
        local line = "  " .. rawget(child, "_path") .. usageTail(child)
        local childDescription = rawget(child, "_description")
        if childDescription ~= false then
            line = line .. " - " .. childDescription
        end
        lines[#lines + 1] = line
    end
    return lines
end

local compileSpec

---Compile a spec's `subcommands` field into `record`.
---@param record table
---@param subcommands any
---@param label string argument description, used in the argument errors
---@param depth integer the nesting depth of `record`
---@param level integer stack level the failures are reported at
---@param scope CommandKit.Scope the scope whose limits apply
local function compileSubcommands(record, subcommands, label, depth, level, scope)
    if type(subcommands) ~= "table" then
        error(label .. " must be a table", level)
    end
    if depth + 1 > MAX_DEPTH then
        error(label .. " nests sub-commands deeper than " .. MAX_DEPTH .. " levels", level)
    end
    local maxSubcommands = rawget(scope, "_maxSubcommands")
    local keys = {}
    for key in next, subcommands do
        if type(key) ~= "string" then
            error(label .. " keys must be sub-command names", level)
        end
        -- Refused before `table.sort` below compares the keys; the message is
        -- the one `readCommandName` gives every other secret name.
        if isSecret(key) then
            error(label .. " key must not be a secret value", level)
        end
        keys[#keys + 1] = key
        if #keys > maxSubcommands then
            error(label .. " declares more than " .. maxSubcommands .. " sub-commands", level)
        end
    end
    table.sort(keys)
    local children = rawget(record, "_subcommands")
    local names = rawget(record, "_subcommandNames")
    for index = 1, #keys do
        local key = keys[index]
        local childLabel = label .. "." .. key
        local name = readCommandName(key, label .. " key", level + 1)
        if rawget(children, name) ~= nil then
            error(label .. ' declares "' .. name .. '" twice', level)
        end
        local child = compileSpec(
            rawget(subcommands, key),
            rawget(record, "_path") .. " " .. name,
            childLabel,
            depth + 1,
            level + 1,
            scope
        )
        rawset(children, name, child)
        names[#names + 1] = name
    end
    table.sort(names)
end

---Compile one command or sub-command spec into a record.
---@param spec any
---@param path string `"/cmd sub"`, lower case
---@param label string argument description, used in the argument errors
---@param depth integer 0 for a top-level command
---@param level integer stack level the failures are reported at
---@param scope CommandKit.Scope the scope whose limits apply
---@return table record
compileSpec = function(spec, path, label, depth, level, scope)
    if type(spec) ~= "table" then
        error(label .. " must be a table", level)
    end
    refuseUnknownFields(spec, SPEC_FIELDS, label, level + 1)
    local handler = rawget(spec, "handler")
    if type(handler) ~= "nil" and type(handler) ~= "function" then
        error(label .. ".handler must be a function", level)
    end
    local complete = rawget(spec, "complete")
    if type(complete) ~= "nil" and type(complete) ~= "function" then
        error(label .. ".complete must be a function", level)
    end
    local usage = rawget(spec, "usage")
    validateOptionalString(usage, label .. ".usage", level + 1)
    local description = rawget(spec, "description")
    validateOptionalString(description, label .. ".description", level + 1)
    local arguments = compileArguments(
        rawget(spec, "arguments"),
        label .. ".arguments",
        level + 1,
        rawget(scope, "_maxPositions")
    )

    local record = {
        _schema = RECORD_SCHEMA,
        _path = path,
        _handler = handler or false,
        _complete = complete or false,
        _mode = arguments.mode,
        _schemas = arguments.schemas,
        _coercions = arguments.coercions,
        _positionCount = arguments.count,
        _defaulted = arguments.defaulted,
        _usage = usage or arguments.usage,
        _description = description or false,
        _subcommands = {},
        _subcommandNames = {},
        _usageLines = false,
        -- Set on every record of the tree when the command is registered.
        _scope = false,
    }

    local subcommands = rawget(spec, "subcommands")
    if type(subcommands) ~= "nil" then
        compileSubcommands(record, subcommands, label .. ".subcommands", depth, level + 1, scope)
    end
    local names = rawget(record, "_subcommandNames")
    if type(handler) == "nil" then
        if #names == 0 then
            error(label .. " needs a handler or subcommands", level)
        end
        -- Without a handler nothing would receive the arguments, and the
        -- generated usage below would hide that they were ignored.
        if arguments.mode ~= "none" then
            error(label .. ".arguments needs a handler to receive them", level)
        end
        if type(usage) == "nil" then
            rawset(record, "_usage", "<" .. table.concat(names, "|") .. ">")
        end
    end
    rawset(record, "_usageLines", buildUsageLines(record))
    return record
end

---Point every record of a compiled tree at its owning scope.
---@param record table
---@param scope CommandKit.Scope
local function attachScope(record, scope)
    rawset(record, "_scope", scope)
    local names = rawget(record, "_subcommandNames")
    local children = rawget(record, "_subcommands")
    for index = 1, #names do
        attachScope(rawget(children, names[index]), scope)
    end
end

-- Slash registration ---------------------------------------------------------
--
-- A slash name is bound to one slash-table key for the session: the key of its
-- first registration. The dispatcher CommandKit writes under that key is
-- permanent and looks the name up in `activeByName` on every call, so an
-- unregistered name is inert and a re-registered name (by any scope) works
-- again through the function the client may already have cached.

---Upper-case `text` with every byte that is not a letter or digit replaced by
---an underscore, for a slash-table key.
---@param text string
---@return string
local function sanitizeKeyPart(text)
    return (text:gsub("[^%w]", "_")):upper()
end

---Derive the slash-table key for `name` in `scope`: `MOLTENCODES_<ADDON>_<NAME>`
---for an addon scope, `MOLTENCODES_<NAME>` for a manual one, with a numeric
---suffix in the rare case two names sanitise to one key.
---@param scope CommandKit.Scope
---@param name string lower-case name
---@return string key
local function deriveKey(scope, name)
    local addonName = rawget(scope, "_addonName")
    local base
    if addonName == false then
        base = KEY_PREFIX .. sanitizeKeyPart(name)
    else
        base = KEY_PREFIX .. sanitizeKeyPart(addonName) .. "_" .. sanitizeKeyPart(name)
    end
    local key = base
    local suffix = 1
    while ownedKeys[key] ~= nil do
        suffix = suffix + 1
        key = base .. "_" .. suffix
    end
    return key
end

---Whether a slash table other than CommandKit's entries already maps
---`upperSlash` (`"/NAME"`) through its `SLASH_<key><n>` globals.
---
---Best effort, and documented as such: it reads the keys of one host table
---and, for each key CommandKit does not own, its `SLASH_<key>1..n` globals
---until the first gap. Commands another addon keeps elsewhere are not seen.
---@param tableName string `"SlashCmdList"` or `"SecureCmdList"`
---@param upperSlash string
---@param maxAliases number the scope's `maxSlashAliases`, `math.huge` when unbounded
---@return boolean
local function hasForeignSlash(tableName, upperSlash, maxAliases)
    local list = readGlobal(tableName)
    if type(list) ~= "table" then
        return false
    end
    local probe = readGlobal("issecretvalue")
    for key in next, list do
        if type(key) == "string" and ownedKeys[key] == nil then
            for index = 1, maxAliases do
                local value = readGlobal("SLASH_" .. key .. index)
                if type(value) ~= "string" then
                    break
                end
                local secret = type(probe) == "function" and probe(value) == true
                if not secret and value:upper() == upperSlash then
                    return true
                end
            end
        end
    end
    return false
end

---Whether a chat type claims `upperSlash`. The client resolves chat types
---(`/s`, `/g`, `/w`, …) before slash commands, so a slash command with such a
---name would never run. Reads the keys of `ChatTypeInfo` and each key's
---`SLASH_<TYPE>1..n` globals up to the first gap.
---@param upperSlash string
---@param maxAliases number the scope's `maxSlashAliases`, `math.huge` when unbounded
---@return boolean
local function isChatTypeSlash(upperSlash, maxAliases)
    local chatTypes = readGlobal("ChatTypeInfo")
    if type(chatTypes) ~= "table" then
        return false
    end
    local probe = readGlobal("issecretvalue")
    for chatType in next, chatTypes do
        if type(chatType) == "string" then
            for index = 1, maxAliases do
                local value = readGlobal("SLASH_" .. chatType .. index)
                if type(value) ~= "string" then
                    break
                end
                local secret = type(probe) == "function" and probe(value) == true
                if not secret and value:upper() == upperSlash then
                    return true
                end
            end
        end
    end
    return false
end

---Whether an emote claims `upperSlash`. The client resolves slash commands
---before emotes, so a command with an emote's name would silently shadow it.
---Reads `EMOTE<index>_CMD<n>` by constructed name, never by scanning the
---global table.
---@param upperSlash string
---@return boolean
local function isEmoteSlash(upperSlash)
    local count = rawget(sharedLimits, "maxEmotes")
    local hostCount = readGlobal("MAXEMOTEINDEX")
    if type(hostCount) == "number" and hostCount >= 0 and hostCount < count then
        count = hostCount
    end
    local probe = readGlobal("issecretvalue")
    for index = 1, count do
        for command = 1, MAX_EMOTE_COMMANDS do
            local value = readGlobal("EMOTE" .. index .. "_CMD" .. command)
            if type(value) ~= "string" then
                break
            end
            local secret = type(probe) == "function" and probe(value) == true
            if not secret and value:upper() == upperSlash then
                return true
            end
        end
    end
    return false
end

---The permanent dispatcher written under `key`.
---@param key string
---@return function
local function newSlashHandler(key)
    return function(text, editBox)
        dispatch.slash(key, text, editBox)
    end
end

---Register a compiled command, or report why not.
---@param scope CommandKit.Scope
---@param name any
---@param spec any
---@param methodName string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@return true|nil registered
---@return "taken"|"emote"|"full"|nil reason
local function registerCommand(scope, name, spec, methodName, level)
    validateScope(scope, methodName, level + 1)
    ensureOpen(scope, methodName, level + 1)
    local lowerName = readCommandName(name, methodName .. " name", level + 1)
    local commands = rawget(scope, "_commands")
    if rawget(commands, lowerName) ~= nil then
        error(
            methodName
                .. ' "'
                .. lowerName
                .. '" is already registered in this scope; Unregister it first',
            level
        )
    end
    local slashList = readGlobal("SlashCmdList")
    if type(slashList) ~= "table" then
        error(methodName .. " requires the host's SlashCmdList table", level)
    end
    local record = compileSpec(spec, "/" .. lowerName, methodName .. " spec", 0, level + 1, scope)

    if rawget(scope, "_count") >= rawget(scope, "_maxCommands") then
        return nil, "full"
    end
    if activeByName[lowerName] ~= nil then
        return nil, "taken"
    end
    local key = keyByName[lowerName]
    if key == nil then
        key = deriveKey(scope, lowerName)
        if type(rawget(slashList, key)) ~= "nil" then
            return nil, "taken"
        end
    end
    local upperSlash = "/" .. lowerName:upper()
    local maxAliases = rawget(scope, "_maxSlashAliases")
    if
        hasForeignSlash("SlashCmdList", upperSlash, maxAliases)
        or hasForeignSlash("SecureCmdList", upperSlash, maxAliases)
        or isChatTypeSlash(upperSlash, maxAliases)
    then
        return nil, "taken"
    end
    if isEmoteSlash(upperSlash) then
        return nil, "emote"
    end

    local handler = slashHandlers[key]
    if handler == nil then
        handler = newSlashHandler(key)
        slashHandlers[key] = handler
    end
    ownedKeys[key] = lowerName
    keyByName[lowerName] = key
    attachScope(record, scope)
    rawset(slashList, key, handler)
    writeGlobal("SLASH_" .. key .. "1", "/" .. lowerName)
    activeByName[lowerName] = record
    rawset(commands, lowerName, record)
    rawset(scope, "_count", rawget(scope, "_count") + 1)
    return true
end

---Remove one command of a scope. The slash globals stay, and turn inert.
---@param scope CommandKit.Scope
---@param lowerName string
---@param record table
local function releaseCommand(scope, lowerName, record)
    rawset(rawget(scope, "_commands"), lowerName, nil)
    rawset(scope, "_count", rawget(scope, "_count") - 1)
    if activeByName[lowerName] == record then
        activeByName[lowerName] = nil
    end
end

-- Dispatch -------------------------------------------------------------------
--
-- A dispatch borrows one frame: a token array, an argument array and a
-- context, all reused. Frames are indexed by nesting depth, so a handler that
-- runs another command gets the next frame and nothing is shared between the
-- two. A dispatch of text seen before allocates nothing, except the fresh
-- copy `Apply` makes when a table default is filled.

---Borrow the frame of the next nesting level, or `nil` past `MAX_NESTING`.
---@return table|nil frame
local function acquireFrame()
    local depth = rawget(state, "frameDepth") + 1
    if depth > MAX_NESTING then
        return nil
    end
    local frame = frames[depth]
    if frame == nil then
        frame = {
            tokens = {},
            arguments = {},
            -- The highest argument slot a dispatch at this depth may have
            -- written, so the next one can clear them all.
            argumentMark = 0,
            context = setmetatable({
                _schema = CONTEXT_SCHEMA,
                _live = false,
                _scope = false,
                _record = false,
                _raw = "",
            }, CONTEXT_METATABLE),
        }
        frames[depth] = frame
    end
    rawset(state, "frameDepth", depth)
    return frame
end

---Return a frame and retire its context.
---@param frame table
local function releaseFrame(frame)
    local context = frame.context
    rawset(context, "_live", false)
    rawset(context, "_scope", false)
    rawset(context, "_record", false)
    rawset(context, "_raw", "")
    rawset(state, "frameDepth", rawget(state, "frameDepth") - 1)
end

---Point a frame's context at a command.
---@param frame table
---@param record table
---@param text string
---@return CommandKit.Context
local function openContext(frame, record, text)
    local context = frame.context
    rawset(context, "_scope", rawget(record, "_scope"))
    rawset(context, "_record", record)
    rawset(context, "_raw", text)
    rawset(context, "_live", true)
    return context
end

---Follow sub-command names from `tokens[1]` on. The walk stops at a record
---without sub-commands before lower-casing the next token: that token is an
---argument, often a long item link, and its lower-case copy would be a new
---string on every dispatch.
---@param record table the top-level record
---@param tokens string[]
---@param count integer
---@return table node the deepest record reached
---@return integer index the first token that is not a sub-command name
local function walkSubcommands(record, tokens, count)
    local node = record
    local index = 1
    while index <= count and #rawget(node, "_subcommandNames") > 0 do
        local child = rawget(rawget(node, "_subcommands"), tokens[index]:lower())
        if child == nil then
            break
        end
        node = child
        index = index + 1
    end
    return node, index
end

---Write `path: reason` and the usage lines of `record`.
---@param scope CommandKit.Scope
---@param record table
---@param reason string
local function failWithUsage(scope, record, reason)
    writeLine(scope, rawget(record, "_path") .. ": " .. reason)
    writeLines(scope, rawget(record, "_usageLines"))
end

---Coerce and check a command's arguments in place.
---@param scope CommandKit.Scope
---@param record table
---@param arguments any[]
---@param count integer tokens after the command path
---@return integer|nil passCount how many arguments the handler receives
local function checkArguments(scope, record, arguments, count)
    local mode = rawget(record, "_mode")
    if mode == "none" then
        return count
    end
    local schemas = rawget(record, "_schemas")
    local coercions = rawget(record, "_coercions")
    if mode == "array" then
        local coercion = coercions[1]
        for index = 1, count do
            arguments[index] = coerce(arguments[index], coercion)
        end
        local ok, failure = schemas[1]:Check(arguments)
        if not ok then
            failWithUsage(scope, record, describeFailure("arguments", failure))
            return nil
        end
        return count
    end
    local positions = rawget(record, "_positionCount")
    if count > positions then
        local noun = positions == 1 and " argument" or " arguments"
        failWithUsage(scope, record, "expected at most " .. positions .. noun)
        return nil
    end
    local defaulted = rawget(record, "_defaulted")
    for position = 1, positions do
        local schema = schemas[position]
        local value = coerce(arguments[position], coercions[position])
        local ok, failure = schema:Check(value)
        if not ok then
            failWithUsage(scope, record, describeFailure("argument " .. position, failure))
            return nil
        end
        if value == nil and defaulted[position] then
            -- `Check` never fills a default; `Apply` hands out a fresh copy
            -- of the one `SchemaKit.optional` declared.
            local applied, filled = schema:Apply(nil)
            if applied then
                value = filled
            end
        end
        arguments[position] = value
    end
    return positions
end

---Report a handler failure to the sink and to the host error handler.
---@param scope CommandKit.Scope
---@param record table
---@param failure any
local function reportHandlerFailure(scope, record, failure)
    local message = rawget(record, "_path") .. " failed"
    if type(failure) == "string" and not isSecret(failure) then
        message = message .. ": " .. failure
    end
    writeLine(scope, message)
    reportError(failure)
end

---Run one command line in a borrowed frame.
---@param frame table
---@param record table the top-level record
---@param text string what the user typed after the slash name
local function runCommand(frame, record, text)
    local scope = rawget(record, "_scope")
    local context = openContext(frame, record, text)
    local tokens = frame.tokens
    local count, reason = tokenize(text, tokens)
    if count == nil then
        failWithUsage(scope, record, reason --[[@as string]])
        return
    end

    local node, index = walkSubcommands(record, tokens, count)
    rawset(context, "_record", node)
    local handler = rawget(node, "_handler")
    if handler == false then
        if index <= count then
            failWithUsage(scope, node, 'unknown sub-command "' .. tokens[index] .. '"')
        else
            writeLines(scope, rawget(node, "_usageLines"))
        end
        return
    end

    local arguments = frame.arguments
    local argumentCount = count - index + 1
    for position = 1, argumentCount do
        arguments[position] = tokens[index + position - 1]
    end
    -- Clear every slot an earlier dispatch at this depth wrote. A filled
    -- default can sit above a missing position, so a scan that stopped at the
    -- first `nil` would leave it for the next command to receive.
    for position = argumentCount + 1, rawget(frame, "argumentMark") or 0 do
        arguments[position] = nil
    end
    local writtenCount = rawget(node, "_positionCount")
    if writtenCount < argumentCount then
        writtenCount = argumentCount
    end
    frame.argumentMark = writtenCount

    local passCount = checkArguments(scope, node, arguments, argumentCount)
    if passCount == nil then
        return
    end
    local ok, failure = pcall(handler, context, unpack(arguments, 1, passCount))
    if not ok then
        reportHandlerFailure(scope, node, failure)
    end
end

---The body of every permanent slash dispatcher.
---@param key string
---@param text any what the client passes: the text after the slash name
---@param _ any the edit box the command was typed in
local function slashDispatch(key, text, _)
    local name = ownedKeys[key]
    if name == nil then
        return
    end
    local record = activeByName[name]
    if record == nil then
        -- Unregistered or closed: the dispatcher stays in the client's table,
        -- inert, until the name is registered again.
        return
    end
    if type(text) ~= "string" then
        text = ""
    end
    local frame = acquireFrame()
    if frame == nil then
        writeLine(
            rawget(record, "_scope"),
            rawget(record, "_path") .. ": commands nested too deeply"
        )
        return
    end
    local ok, failure = pcall(runCommand, frame, record, text)
    releaseFrame(frame)
    if not ok then
        reportError(failure)
    end
end

-- Context methods ------------------------------------------------------------

---@param context any
---@param methodName string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateContext(context, methodName, level)
    local metatable = readMetatable(context)
    if type(metatable) ~= "table" or metatable ~= CONTEXT_METATABLE then
        error(methodName .. " must be called on a CommandKit context", level)
    end
    if rawget(context, "_live") ~= true then
        error(methodName .. " cannot be used after its command returned", level)
    end
end

---Refuse a secret among `...`, naming its position.
---@param methodName string qualified public method name, used in the argument error
---@param first integer the argument number of the first value
---@param level integer stack level the failure is reported at
---@param ... any
local function refuseSecretArguments(methodName, first, level, ...)
    for index = 1, select("#", ...) do
        if isSecret((select(index, ...))) then
            error(
                methodName .. " argument " .. (first + index - 1) .. " must not be a secret value",
                level
            )
        end
    end
end

---Write the arguments, converted with `tostring` and joined by spaces, to the
---scope's sink. A secret argument is refused at the caller.
---@param self CommandKit.Context
---@param ... any
local function contextPrint(self, ...)
    validateContext(self, "CommandKit.Context:Print", 3)
    refuseSecretArguments("CommandKit.Context:Print", 1, 3, ...)
    local text = ""
    for index = 1, select("#", ...) do
        if index > 1 then
            text = text .. " "
        end
        text = text .. tostring((select(index, ...)))
    end
    writeLine(rawget(self, "_scope"), text)
end

---Format with LocaleKit's `Format` when LocaleKit is registered (indexed
---specifiers such as `%2$s` work), with `string.format` otherwise, and write
---the result to the scope's sink. A secret argument is refused at the caller.
---@param self CommandKit.Context
---@param template string
---@param ... any
local function contextPrintf(self, template, ...)
    validateContext(self, "CommandKit.Context:Printf", 3)
    if type(template) ~= "string" then
        error("CommandKit.Context:Printf template must be a string", 2)
    end
    refuseSecretArguments("CommandKit.Context:Printf", 1, 3, template)
    refuseSecretArguments("CommandKit.Context:Printf", 2, 3, ...)
    local LocaleKit = findOptional("localeKit", OPTIONAL_LOCALEKIT_API)
    local text
    if LocaleKit ~= nil and type(rawget(LocaleKit, "Format")) == "function" then
        text = LocaleKit:Format(template, ...)
    else
        text = string.format(template, ...)
    end
    writeLine(rawget(self, "_scope"), text)
end

---Write the usage lines of the command being run.
---@param self CommandKit.Context
local function contextUsage(self)
    validateContext(self, "CommandKit.Context:Usage", 3)
    writeLines(rawget(self, "_scope"), rawget(rawget(self, "_record"), "_usageLines"))
end

---Write `<command path>: <reason>`.
---@param self CommandKit.Context
---@param reason string
local function contextFail(self, reason)
    validateContext(self, "CommandKit.Context:Fail", 3)
    validateString(reason, "CommandKit.Context:Fail reason", 3)
    writeLine(rawget(self, "_scope"), rawget(rawget(self, "_record"), "_path") .. ": " .. reason)
end

---The path of the command being run: `"/cmd sub"`.
---@param self CommandKit.Context
---@return string
local function contextGetCommandPath(self)
    validateContext(self, "CommandKit.Context:GetCommandPath", 3)
    return rawget(rawget(self, "_record"), "_path")
end

---What the user typed after the slash name, unparsed.
---@param self CommandKit.Context
---@return string
local function contextGetRawText(self)
    validateContext(self, "CommandKit.Context:GetRawText", 3)
    return rawget(self, "_raw")
end

-- Options binding ------------------------------------------------------------
--
-- `BindOptions` registers a command whose sub-commands read and write an
-- OptionsKit tree. Every bound sub-command calls `tree:Describe()` once to
-- see the tree as it is now (values, labels, hidden and disabled flags):
-- allocating by design, because a typed command is not a hot path and a
-- values function may answer differently each time.

-- Option kinds that carry a value.
local VALUE_KINDS = {
    toggle = true,
    range = true,
    select = true,
    multiselect = true,
    input = true,
    color = true,
    keybinding = true,
}

---Index a description by path.
---@param node table
---@param index table<string, table>
local function indexDescription(node, index)
    index[node.path] = node
    local children = node.children
    if type(children) == "table" then
        for position = 1, #children do
            indexDescription(children[position], index)
        end
    end
end

---The description node at `path`, or `nil` after telling the user.
---@param context CommandKit.Context
---@param tree table
---@param path string|nil
---@param allowRoot boolean whether `nil` or `""` names the root group
---@return table|nil node
local function findOption(context, tree, path, allowRoot)
    if path == nil or path == "" then
        if not allowRoot then
            contextFail(context, "expected an option path")
            contextUsage(context)
            return nil
        end
        path = ""
    end
    local index = {}
    indexDescription(tree:Describe(), index)
    local node = index[path]
    if node == nil or node.hidden == true then
        contextFail(context, 'unknown option "' .. path .. '"')
        return nil
    end
    return node
end

---The sorted keys of a values table.
---@param node table
---@return any[]
local function valueKeys(node)
    local keys = {}
    local sorting = node.sorting
    if type(sorting) == "table" then
        for index = 1, #sorting do
            keys[index] = sorting[index]
        end
        return keys
    end
    for key in next, node.values or {} do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(left, right)
        return tostring(left) < tostring(right)
    end)
    return keys
end

---A value as the command line shows it. A secret, at the top or inside a
---`multiselect` or `color` table (OptionsKit's `Describe` passes nested
---secrets through), is shown as `(secret value)` before anything compares or
---formats it.
---@param node table
---@param value any
---@return string
local function formatValue(node, value)
    if isSecret(value) then
        return "(secret value)"
    end
    local kind = node.kind
    if type(value) == "nil" then
        if kind == "toggle" then
            return "default"
        end
        return "(none)"
    end
    if kind == "toggle" and type(value) == "boolean" then
        return value and "on" or "off"
    end
    if kind == "select" then
        local label = type(node.values) == "table" and node.values[value] or nil
        if isSecret(label) then
            return tostring(value)
        end
        if type(label) ~= "nil" and tostring(label) ~= tostring(value) then
            return tostring(value) .. " (" .. tostring(label) .. ")"
        end
        return tostring(value)
    end
    if kind == "multiselect" and type(value) == "table" then
        local chosen = {}
        local keys = valueKeys(node)
        for index = 1, #keys do
            local entry = value[keys[index]]
            if isSecret(entry) then
                return "(secret value)"
            end
            if entry == true then
                chosen[#chosen + 1] = tostring(keys[index])
            end
        end
        if #chosen == 0 then
            return "(none)"
        end
        return table.concat(chosen, ", ")
    end
    if kind == "color" and type(value) == "table" then
        if isSecret(value.r) or isSecret(value.g) or isSecret(value.b) or isSecret(value.a) then
            return "(secret value)"
        end
        local text = string.format("%.2f %.2f %.2f", value.r or 0, value.g or 0, value.b or 0)
        if type(value.a) ~= "nil" then
            text = text .. string.format(" %.2f", value.a)
        end
        return text
    end
    if kind == "keybinding" and value == "" then
        return "(unbound)"
    end
    return tostring(value)
end

---Read a boolean flag of the addon's tree that `Describe` passes through as
---the addon wrote it (`tristate`, `confirm`). OptionsKit checks only its type,
---so the flag may be a secret boolean, which cannot be tested for truth or
---compared with `true` inside CommandKit. A secret flag answers `whenSecret`,
---chosen per flag as the safe reading; anything but a boolean answers `false`.
---@param value any
---@param whenSecret boolean
---@return boolean
local function readTreeFlag(value, whenSecret)
    if type(value) ~= "boolean" then
        return false
    end
    if isSecret(value) then
        return whenSecret
    end
    return value
end

---Find a `select` or `multiselect` key from what the user typed: the key
---itself (as text or as a number), else a label, ignoring case.
---@param node table
---@param word string
---@return any key
local function matchValueKey(node, word)
    local values = node.values or {}
    for key in next, values do
        if tostring(key) == word then
            return key
        end
    end
    local lowerWord = word:lower()
    for key, label in next, values do
        if not isSecret(label) and tostring(label):lower() == lowerWord then
            return key
        end
    end
    return nil
end

---The "expected one of" message of a `select` or `multiselect`.
---@param node table
---@return string
local function expectedKeys(node)
    return "expected one of: " .. joinValues(valueKeys(node), ", ")
end

---Parse a colour typed as `r g b [a]` in 0..1 or as `#rrggbb[aa]`.
---@param node table
---@param ... string
---@return table|nil colour
---@return string|nil problem
local function parseColour(node, ...)
    local first = ...
    local components
    local hex = type(first) == "string" and first:match("^#?(%x+)$") or nil
    if hex ~= nil and select("#", ...) == 1 and (#hex == 6 or #hex == 8) then
        components = {}
        for index = 1, #hex / 2 do
            components[index] = tonumber(hex:sub(index * 2 - 1, index * 2), 16) / 255
        end
    else
        components = {}
        for index = 1, select("#", ...) do
            local number = tonumber((select(index, ...)))
            if number == nil then
                return nil, "expected r g b [a] between 0 and 1, or #rrggbb[aa]"
            end
            components[index] = number
        end
        if #components < 3 or #components > 4 then
            return nil, "expected r g b [a] between 0 and 1, or #rrggbb[aa]"
        end
    end
    local colour = { r = components[1], g = components[2], b = components[3] }
    if node.hasAlpha then
        colour.a = components[4] or 1
    elseif components[4] ~= nil then
        return nil, "this colour has no alpha"
    end
    return colour
end

-- What `set <path> toggle` answers when the current value (a `toggle`, or the
-- chosen key of a `multiselect`) is secret: flipping it would test the secret.
local SECRET_TOGGLE_PROBLEM = "the current value is secret; use on or off"

---Parse the words after `set <path>` into a value of the option's kind.
---@param node table
---@param ... string
---@return any value
---@return string|nil problem
local function parseValue(node, ...)
    local kind = node.kind
    local word = ...
    local wordCount = select("#", ...)
    if kind == "input" or kind == "keybinding" then
        local text = table.concat({ ... }, " ")
        if kind == "keybinding" and (text:lower() == "none" or text:lower() == "unbound") then
            return ""
        end
        return text
    end
    if kind == "color" then
        return parseColour(node, ...)
    end
    if word == nil then
        if kind == "toggle" then
            return nil, "expected on, off or toggle"
        end
        if kind == "range" then
            return nil, "expected a number"
        end
        return nil, expectedKeys(node)
    end
    if kind == "toggle" then
        local lowerWord = word:lower()
        if wordCount > 1 then
            return nil, "expected on, off or toggle"
        end
        if lowerWord == "toggle" then
            if isSecret(node.value) then
                return nil, SECRET_TOGGLE_PROBLEM
            end
            return not node.value
        end
        -- A secret `tristate` reads as absent: `default` is not offered.
        if readTreeFlag(node.tristate, false) and lowerWord == "default" then
            return nil
        end
        local value = BOOLEAN_WORDS[lowerWord]
        if value == nil then
            return nil, "expected on, off or toggle"
        end
        return value
    end
    if kind == "range" then
        local number = tonumber(word)
        if number == nil or wordCount > 1 then
            return nil, "expected a number"
        end
        return number
    end
    if kind == "select" then
        local key = matchValueKey(node, table.concat({ ... }, " "))
        if key == nil then
            return nil, expectedKeys(node)
        end
        return key
    end
    -- multiselect: `<key> on|off|toggle`
    local key = matchValueKey(node, word)
    if key == nil then
        return nil, expectedKeys(node)
    end
    local stateWord = select(2, ...)
    local current = type(node.value) == "table" and node.value or {}
    local enabled
    if type(stateWord) == "string" and stateWord:lower() == "toggle" then
        local chosen = current[key]
        if isSecret(chosen) then
            return nil, SECRET_TOGGLE_PROBLEM
        end
        enabled = chosen ~= true
    elseif type(stateWord) == "string" then
        enabled = BOOLEAN_WORDS[stateWord:lower()]
    end
    if enabled == nil or wordCount > 2 then
        return nil, "expected <key> on|off|toggle"
    end
    local value = {}
    for existingKey, isChosen in next, current do
        value[existingKey] = isChosen
    end
    value[key] = enabled
    return value
end

---One `list` line for a child node.
---@param node table
---@return string|nil
local function listLine(node)
    local kind = node.kind
    local line
    if kind == "group" then
        line = node.path .. " - " .. tostring(node.name) .. " (group)"
    elseif kind == "execute" then
        line = node.path .. " - " .. tostring(node.name) .. " (exec)"
    elseif VALUE_KINDS[kind] == true then
        line = node.path .. " = " .. formatValue(node, node.value) .. " - " .. tostring(node.name)
    else
        return nil
    end
    if node.disabled == true then
        line = line .. " (disabled)"
    end
    return line
end

---Refuse a node that is not a value option, or is disabled.
---@param context CommandKit.Context
---@param node table
---@return boolean usable
local function ensureValueOption(context, node)
    if node.kind == "execute" then
        contextFail(context, '"' .. node.path .. '" is a button; use exec')
        return false
    end
    if VALUE_KINDS[node.kind] ~= true then
        contextFail(context, '"' .. node.path .. '" has no value')
        return false
    end
    return true
end

---Build the sub-command handlers of a bound command.
---@param tree table
---@return table handlers
local function newOptionHandlers(tree)
    local handlers = {}

    ---Print a refusal the tree returned. `validate` may answer with anything:
    ---a message that is secret, or empty once converted with `tostring`, is
    ---replaced by `fallback` rather than making `Fail` raise inside this
    ---handler.
    ---@param context CommandKit.Context
    ---@param message any
    ---@param fallback string
    local function failWithRefusal(context, message, fallback)
        if isSecret(message) then
            message = fallback
        else
            message = tostring(message)
            if message == "" then
                message = fallback
            end
        end
        contextFail(context, message)
    end

    function handlers.get(context, path)
        local node = findOption(context, tree, path, false)
        if node == nil or not ensureValueOption(context, node) then
            return
        end
        contextPrint(context, node.path .. " = " .. formatValue(node, node.value))
    end

    function handlers.set(context, path, ...)
        local node = findOption(context, tree, path, false)
        if node == nil or not ensureValueOption(context, node) then
            return
        end
        if node.disabled == true then
            contextFail(context, '"' .. node.path .. '" is disabled')
            return
        end
        local value, problem = parseValue(node, ...)
        if problem ~= nil then
            contextFail(context, problem)
            return
        end
        local valid, message = tree:Validate(node.path, value)
        if not valid then
            failWithRefusal(context, message, "refused by validate")
            return
        end
        local written, refusal = tree:Set(node.path, value)
        if not written then
            failWithRefusal(context, refusal, "refused by validate")
            return
        end
        contextPrint(context, node.path .. " = " .. formatValue(node, tree:Get(node.path)))
    end

    function handlers.reset(context, path)
        local node = findOption(context, tree, path, false)
        if node == nil or not ensureValueOption(context, node) then
            return
        end
        if node.disabled == true then
            contextFail(context, '"' .. node.path .. '" is disabled')
            return
        end
        if type(node.bind) == "nil" then
            contextFail(context, '"' .. node.path .. '" has no default to reset to')
            return
        end
        local value = tree:Reset(node.path)
        contextPrint(context, node.path .. " = " .. formatValue(node, value))
    end

    function handlers.list(context, path)
        local node = findOption(context, tree, path, true)
        if node == nil then
            return
        end
        if node.kind ~= "group" then
            local line = listLine(node)
            if line ~= nil then
                contextPrint(context, line)
            end
            -- `Describe` has called a `desc` function already; its string may
            -- be secret, and `Print` would refuse it.
            local desc = node.desc
            if type(desc) == "string" then
                if isSecret(desc) then
                    contextPrint(context, "(secret value)")
                else
                    contextPrint(context, desc)
                end
            end
            if node.kind == "select" or node.kind == "multiselect" then
                contextPrint(context, "values: " .. joinValues(valueKeys(node), ", "))
            end
            return
        end
        local printed = 0
        local children = node.children or {}
        for index = 1, #children do
            local child = children[index]
            if child.hidden ~= true then
                local line = listLine(child)
                if line ~= nil then
                    contextPrint(context, line)
                    printed = printed + 1
                end
            end
        end
        if printed == 0 then
            contextPrint(context, "(no options)")
        end
    end

    function handlers.exec(context, path, confirmation)
        local node = findOption(context, tree, path, false)
        if node == nil then
            return
        end
        if node.kind ~= "execute" then
            contextFail(context, '"' .. node.path .. '" is not a button')
            return
        end
        if node.disabled == true then
            contextFail(context, '"' .. node.path .. '" is disabled')
            return
        end
        local confirm = node.confirm
        -- A secret boolean `confirm` asks: running a button the addon may
        -- have marked for confirmation is the surprise to avoid.
        local asks = type(confirm) == "string" or readTreeFlag(confirm, true)
        if asks and confirmation ~= "confirm" then
            if type(confirm) == "string" and not isSecret(confirm) then
                contextPrint(context, confirm)
            end
            contextPrint(
                context,
                "Type "
                    .. contextGetCommandPath(context)
                    .. " "
                    .. node.path
                    .. " confirm to run it."
            )
            return
        end
        tree:Execute(node.path)
    end

    return handlers
end

---A completion function offering the option paths `accepts` admits.
---@param tree table
---@param accepts fun(kind: string): boolean
---@return function
local function newPathCompleter(tree, accepts)
    return function(_, _, position)
        if position ~= 1 then
            return nil
        end
        local paths = {}
        tree:Walk(function(path, kind)
            if accepts(kind) and not tree:IsHidden(path) then
                paths[#paths + 1] = path
            end
        end)
        return paths
    end
end

---@param kind string
---@return boolean
local function acceptsValue(kind)
    return VALUE_KINDS[kind] == true
end

---@param kind string
---@return boolean
local function acceptsListable(kind)
    return kind == "group" or kind == "execute" or VALUE_KINDS[kind] == true
end

---@param kind string
---@return boolean
local function acceptsExecute(kind)
    return kind == "execute"
end

---Build the command spec `BindOptions` registers.
---@param tree table
---@param description string|nil
---@return CommandKit.CommandSpec
local function newOptionsSpec(tree, description)
    local S = SchemaKit
    local handlers = newOptionHandlers(tree)
    local valuePaths = newPathCompleter(tree, acceptsValue)
    return {
        description = description,
        subcommands = {
            get = {
                handler = handlers.get,
                arguments = { S.string() },
                usage = "<path>",
                description = "Print an option's value.",
                complete = valuePaths,
            },
            set = {
                handler = handlers.set,
                usage = "<path> <value...>",
                description = "Change an option.",
                complete = valuePaths,
            },
            reset = {
                handler = handlers.reset,
                arguments = { S.string() },
                usage = "<path>",
                description = "Restore an option's default.",
                complete = valuePaths,
            },
            list = {
                handler = handlers.list,
                arguments = { S.optional(S.string()) },
                usage = "[path]",
                description = "List the options of a group, or describe one option.",
                complete = newPathCompleter(tree, acceptsListable),
            },
            exec = {
                handler = handlers.exec,
                arguments = { S.string(), S.optional(S.string({ oneOf = { "confirm" } })) },
                usage = "<path> [confirm]",
                description = "Run a button.",
                complete = newPathCompleter(tree, acceptsExecute),
            },
        },
    }
end

-- Completion -----------------------------------------------------------------
--
-- The client calls `ChatEdit_CustomTabPressed(editBox)` from its tab handler
-- and skips its own completion when that returns `true`. The global is the
-- documented extension point and is empty in the client, so CommandKit
-- replaces it with a closure that remembers the previous function and calls
-- it for any text that is not one of its commands. A secure post-hook
-- (`hooksecurefunc`) cannot be used: its return value is discarded, so the
-- client would complete over CommandKit's completion. The trade-off is taint:
-- the global becomes addon code, as it does for every addon that completes
-- chat input. The closure is removed again when the last scope disables
-- completion and nobody has replaced the global since; otherwise it stays in
-- the chain, forwarding. See `docs/API.md`.

---The longest common prefix of `candidates`.
---@param candidates string[]
---@return string
local function commonPrefix(candidates)
    local prefix = candidates[1]
    for index = 2, #candidates do
        local candidate = candidates[index]
        local length = 0
        local limit = math.min(#prefix, #candidate)
        while length < limit and prefix:byte(length + 1) == candidate:byte(length + 1) do
            length = length + 1
        end
        prefix = prefix:sub(1, length)
    end
    return prefix
end

---Add `candidate` to `candidates` when it starts with `partial`, ignoring case.
---A secret candidate (a `complete` function may return names read from the
---client) is skipped before it is compared.
---@param candidates string[]
---@param candidate any
---@param lowerPartial string
local function offer(candidates, candidate, lowerPartial)
    if
        type(candidate) ~= "string"
        or #candidates >= rawget(sharedLimits, "maxCompletions")
        or isSecret(candidate)
    then
        return
    end
    if candidate:sub(1, #lowerPartial):lower() == lowerPartial then
        candidates[#candidates + 1] = candidate
    end
end

---Complete the word before the cursor in a borrowed frame.
---@param frame table
---@param record table the top-level record
---@param editBox table
---@param text string the whole edit-box text
---@param argumentText string the text between the slash name and the partial word
---@param partial string the word being completed
---@param partialStart integer where `partial` starts in `text`
---@return boolean handled
local function completeInFrame(frame, record, editBox, text, argumentText, partial, partialStart)
    local scope = rawget(record, "_scope")
    local tokens = frame.tokens
    local count = tokenize(argumentText, tokens)
    if count == nil then
        return false
    end
    local node, index = walkSubcommands(record, tokens, count)
    local context = openContext(frame, node, argumentText .. partial)
    local candidates = {}
    local lowerPartial = partial:lower()
    if index > count then
        local names = rawget(node, "_subcommandNames")
        for position = 1, #names do
            offer(candidates, names[position], lowerPartial)
        end
    end
    local complete = rawget(node, "_complete")
    if complete ~= false then
        local offered = complete(context, partial, count - index + 2)
        if type(offered) == "table" then
            for position = 1, #offered do
                offer(candidates, offered[position], lowerPartial)
            end
        end
    end
    if #candidates == 0 then
        return false
    end
    local before = text:sub(1, partialStart - 1)
    if #candidates == 1 then
        editBox:SetText(before .. candidates[1] .. " ")
        return true
    end
    local prefix = commonPrefix(candidates)
    if #prefix > #partial then
        editBox:SetText(before .. prefix)
    else
        writeLine(scope, table.concat(candidates, "  "))
    end
    return true
end

---Try to complete the edit box's text. `true` when CommandKit handled it.
---@param editBox any
---@return boolean handled
local function tryComplete(editBox)
    if type(editBox) == "nil" then
        local getActiveWindow = readGlobal("ChatEdit_GetActiveWindow")
        if type(getActiveWindow) == "function" then
            editBox = getActiveWindow()
        end
    end
    if
        type(editBox) ~= "table"
        or type(editBox.GetText) ~= "function"
        or type(editBox.SetText) ~= "function"
    then
        return false
    end
    local text = editBox:GetText()
    if type(text) ~= "string" or isSecret(text) then
        return false
    end
    if type(editBox.GetCursorPosition) == "function" then
        local cursor = editBox:GetCursorPosition()
        -- A secret cursor cannot be compared; completing without knowing
        -- where the cursor is could rewrite text after it, so leave it.
        if type(cursor) == "number" and (isSecret(cursor) or cursor < #text) then
            return false
        end
    end
    -- A bare `/name` without a space is the client's own slash completion.
    local slashName, argumentStart = text:match("^/([%w_]+)%s+()")
    if slashName == nil then
        return false
    end
    local record = activeByName[slashName:lower()]
    if record == nil or rawget(rawget(record, "_scope"), "_completion") ~= true then
        return false
    end
    local lastSpace = text:find("%s[^%s]*$")
    local partialStart = lastSpace + 1
    local partial = text:sub(partialStart)
    local argumentText = text:sub(argumentStart, partialStart - 1)
    local frame = acquireFrame()
    if frame == nil then
        return false
    end
    local ok, handled =
        pcall(completeInFrame, frame, record, editBox, text, argumentText, partial, partialStart)
    releaseFrame(frame)
    if not ok then
        error(handled, 0)
    end
    return handled
end

---The body of the installed `ChatEdit_CustomTabPressed` replacement.
---@param editBox any
---@param ... any
---@return any
local function tabPressed(editBox, ...)
    if completion.enabledScopes > 0 then
        local ok, handled = pcall(tryComplete, editBox)
        if not ok then
            reportError(handled)
        elseif handled then
            return true
        end
    end
    local previous = completion.previous
    if type(previous) == "function" then
        return previous(editBox, ...)
    end
    return false
end

---Install the replacement once. `false` when the host has no
---`ChatEdit_CustomTabPressed`.
---@return boolean
local function installTabHandler()
    if completion.installed then
        return true
    end
    local current = readGlobal("ChatEdit_CustomTabPressed")
    if type(current) ~= "function" then
        return false
    end
    local handler = completion.handler
    if handler == false then
        handler = function(editBox, ...)
            return dispatch.tabPressed(editBox, ...)
        end
        completion.handler = handler
    end
    if current ~= handler then
        completion.previous = current
        writeGlobal("ChatEdit_CustomTabPressed", handler)
    end
    completion.installed = true
    return true
end

---Remove the replacement when it is still the installed function; otherwise
---leave it in the chain, forwarding to the function it replaced.
local function uninstallTabHandler()
    if not completion.installed then
        return
    end
    local current = readGlobal("ChatEdit_CustomTabPressed")
    if type(current) ~= "function" or current ~= completion.handler then
        return
    end
    writeGlobal("ChatEdit_CustomTabPressed", completion.previous)
    completion.previous = false
    completion.installed = false
end

---Turn a scope's completion off, if it was on.
---@param scope CommandKit.Scope
---@return boolean disabled
local function disableCompletion(scope)
    if rawget(scope, "_completion") ~= true then
        return false
    end
    rawset(scope, "_completion", false)
    completion.enabledScopes = completion.enabledScopes - 1
    if completion.enabledScopes == 0 then
        uninstallTabHandler()
    end
    return true
end

-- Logout close ---------------------------------------------------------------
--
-- CommandKit never observes logout itself and never depends on LifecycleKit
-- (design constitution, principle 4b). What it does instead is make sure that
-- somebody who does observe logout closes each addon scope, whichever revisions
-- of the other Kits are loaded. `ForAddon` asks, in this order:
--
--   (a) LifecycleKit is registered and its `CLOSES_ADDON_SCOPES` names
--       "commandKit": it closes the scope after the addon's shutdown
--       callbacks. CommandKit only makes sure the addon has a LifecycleKit
--       instance, because LifecycleKit closes the scopes of the addons it
--       tracks.
--   (b) LifecycleKit is registered without that field (an older revision):
--       CommandKit subscribes to the addon's `OnShutdown` and closes the scope
--       from there. The subscription is kept on the scope, so closing the
--       scope earlier disconnects it.
--   (c) no LifecycleKit, but EventKit: one package-level `PLAYER_LOGOUT`
--       watcher, in CommandKit's own EventKit scope, closes the addon scopes
--       that nobody else closes.
--   (d) neither: nothing is arranged, and the consumer calls
--       `CommandKit:CloseAddonScopes(addonName)` itself on `PLAYER_LOGOUT`.
--
-- Outcomes (c) and (d) are asked again by every later `ForAddon`, so a
-- LifecycleKit that loads after the first call still takes the scope over.
--
-- The functions are fields of one table rather than locals of their own: the
-- main chunk is close to Lua 5.1's limit of 200 locals.

local LogoutClose = {}

---Whether `LifecycleKit` announces that it closes CommandKit's addon scopes.
---
---The field is a read-only table, so it is indexed normally rather than with
---`rawget`: a proxy answers through `__index`. A revision without the field
---closes none.
---@param LifecycleKit table
---@return boolean
function LogoutClose.lifecycleClosesCommandScopes(LifecycleKit)
    local closes = rawget(LifecycleKit, "CLOSES_ADDON_SCOPES")
    return type(closes) == "table" and closes[PACKAGE_NAME] == true
end

---Make the package-level `PLAYER_LOGOUT` watcher exist, once per session.
---
---The watcher lives in CommandKit's own EventKit scope and calls through a
---trampoline kept in state, which looks `dispatch` up, so a newer CommandKit
---revision replaces what an older revision's watcher does.
---@param EventKit table
function LogoutClose.ensureWatch(EventKit)
    local watch = rawget(state, "logoutWatch")
    if rawget(watch, "connection") ~= false then
        return
    end
    local trampoline = rawget(watch, "trampoline")
    if trampoline == false then
        trampoline = function()
            rawget(dispatch, "closeAddonScopesAtLogout")()
        end
        rawset(watch, "trampoline", trampoline)
    end
    local eventScope = rawget(watch, "scope")
    if eventScope == false or eventScope:IsClosed() then
        eventScope = EventKit:CreateScope()
        rawset(watch, "scope", eventScope)
    end
    rawset(watch, "connection", eventScope:Once("PLAYER_LOGOUT", trampoline))
end

---Subscribe to the addon's LifecycleKit shutdown and close its scope there.
---
---The callback calls the facade method, so the CommandKit revision loaded at
---logout does the closing.
---@param LifecycleKit table
---@param addonName string
---@return table subscription LifecycleKit subscription handle
function LogoutClose.subscribeShutdown(LifecycleKit, addonName)
    local instance = LifecycleKit:ForAddon(addonName)
    return instance:OnShutdown(function()
        CommandKit:CloseAddonScopes(addonName)
    end)
end

---Arrange, once, who closes the addon scope `scope` at logout.
---
---Does nothing for a closed scope, and nothing once LifecycleKit has taken
---the scope over; see the section comment for the four outcomes.
---@param addonName string
---@param scope CommandKit.Scope
function LogoutClose.arrange(addonName, scope)
    local closer = rawget(scope, "_logoutCloser")
    if closer ~= LOGOUT.byNobody and closer ~= LOGOUT.byEvent then
        return
    end
    if rawget(scope, "_closed") == true then
        return
    end

    local LifecycleKit = findOptional("lifecycleKit", LOGOUT.lifecycleKitApi)
    if LifecycleKit ~= nil then
        if LogoutClose.lifecycleClosesCommandScopes(LifecycleKit) then
            LifecycleKit:ForAddon(addonName)
            rawset(scope, "_logoutCloser", LOGOUT.byLifecycle)
        else
            local subscription = LogoutClose.subscribeShutdown(LifecycleKit, addonName)
            rawset(scope, "_shutdownSubscription", subscription)
            rawset(scope, "_logoutCloser", LOGOUT.byShutdownCallback)
        end
        return
    end

    if closer == LOGOUT.byEvent then
        return
    end
    local EventKit = findOptional("eventKit", LOGOUT.eventKitApi)
    if EventKit ~= nil then
        LogoutClose.ensureWatch(EventKit)
        rawset(scope, "_logoutCloser", LOGOUT.byEvent)
    end
end

---Arrange the logout close without letting a failure in another Kit break the
---caller: the failure goes to the host error handler and the scope stays
---undecided, so the next `ForAddon` asks again.
---@param addonName string
---@param scope CommandKit.Scope
function LogoutClose.arrangeProtected(addonName, scope)
    local ok, failure = pcall(LogoutClose.arrange, addonName, scope)
    if not ok then
        reportError(failure)
    end
end

---Disconnect the `OnShutdown` subscription of an addon scope, if it has one.
---
---Called when the scope closes by any path: a scope closed before logout needs
---no shutdown callback, and one closing from inside that callback finds it
---already delivered.
---@param scope CommandKit.Scope
function LogoutClose.releaseSubscription(scope)
    local subscription = rawget(scope, "_shutdownSubscription")
    if subscription == nil or subscription == false then
        return
    end
    rawset(scope, "_shutdownSubscription", false)
    subscription:Disconnect()
end

---The `PLAYER_LOGOUT` watcher's work: close every addon scope nobody else
---closes, in addon-name order so the outcome does not depend on hash order.
---
---A scope LifecycleKit took over (outcomes a and b) is left to it, so its
---shutdown callbacks still run first. Every close is attempted; each failure
---goes to the host error handler.
function LogoutClose.closeAtLogout()
    local names = {}
    for addonName, scope in next, addonScopes do
        local closer = rawget(scope, "_logoutCloser")
        if closer == LOGOUT.byEvent or closer == LOGOUT.byNobody then
            names[#names + 1] = addonName
        end
    end
    table.sort(names)
    for index = 1, #names do
        local ok, failure = pcall(CommandKit.CloseAddonScopes, CommandKit, names[index])
        if not ok then
            reportError(failure)
        end
    end
end

---Arrange the logout close of every open addon scope an upgrade inherited, in
---addon-name order: an older revision never arranged it, and the addon may
---never call `ForAddon` again.
function LogoutClose.arrangeInherited()
    local inherited = {}
    for addonName, scope in next, addonScopes do
        if rawget(scope, "_closed") ~= true then
            inherited[#inherited + 1] = addonName
        end
    end
    table.sort(inherited)
    for index = 1, #inherited do
        LogoutClose.arrangeProtected(inherited[index], rawget(addonScopes, inherited[index]))
    end
end

-- Scope methods --------------------------------------------------------------

---Register `/name`. Returns `true`, `nil, "taken"` when another owner or a
---chat type uses the slash name, `nil, "emote"` when an emote does, or
---`nil, "full"` when the scope holds its `maxCommands`.
---@param self CommandKit.Scope
---@param name string the slash name without the slash
---@param spec CommandKit.CommandSpec
---@return true|nil registered
---@return "taken"|"emote"|"full"|nil reason
local function scopeRegister(self, name, spec)
    -- Not a tail call: a tail call would hide this frame from `error` levels.
    local registered, reason = registerCommand(self, name, spec, "CommandKit.Scope:Register", 3)
    return registered, reason
end

---Unregister a command of this scope. Its slash globals stay, inert.
---@param self CommandKit.Scope
---@param name string
---@return boolean released `false` when this scope has no such command.
local function scopeUnregister(self, name)
    validateScope(self, "CommandKit.Scope:Unregister", 3)
    validateString(name, "CommandKit.Scope:Unregister name", 3)
    local lowerName = name:lower()
    local record = rawget(rawget(self, "_commands"), lowerName)
    if record == nil then
        return false
    end
    releaseCommand(self, lowerName, record)
    return true
end

---Whether this scope has registered `name`.
---@param self CommandKit.Scope
---@param name string
---@return boolean
local function scopeIsRegistered(self, name)
    validateScope(self, "CommandKit.Scope:IsRegistered", 3)
    validateString(name, "CommandKit.Scope:IsRegistered name", 3)
    return rawget(rawget(self, "_commands"), name:lower()) ~= nil
end

---Send this scope's output to `sink` (anything with `AddMessage`), or back to
---`DEFAULT_CHAT_FRAME` with `nil`.
---@param self CommandKit.Scope
---@param sink CommandKit.Sink?
local function scopeSetSink(self, sink)
    validateScope(self, "CommandKit.Scope:SetSink", 3)
    if type(sink) == "nil" then
        rawset(self, "_sink", false)
        return
    end
    if type(sink) ~= "table" or type(sink.AddMessage) ~= "function" then
        error("CommandKit.Scope:SetSink sink must be a table with an AddMessage method", 2)
    end
    rawset(self, "_sink", sink)
end

---Register `/commandName` with `get`, `set`, `reset`, `list` and `exec`
---sub-commands over an OptionsKit tree.
---@param self CommandKit.Scope
---@param tree table an OptionsKit tree handle
---@param commandName string
---@param options CommandKit.BindOptions?
---@return true|nil registered
---@return "taken"|"emote"|"full"|nil reason
local function scopeBindOptions(self, tree, commandName, options)
    local methodName = "CommandKit.Scope:BindOptions"
    validateScope(self, methodName, 3)
    ensureOpen(self, methodName, 3)
    local OptionsKit = findOptional("optionsKit", OPTIONAL_OPTIONSKIT_API)
    if OptionsKit == nil then
        error(methodName .. " requires OptionsKit API 1", 2)
    end
    local metatable = readMetatable(tree)
    local treeIndex = nil
    if type(metatable) == "table" then
        treeIndex = rawget(metatable, "__index")
    end
    if type(treeIndex) ~= "table" or treeIndex ~= rawget(OptionsKit, "Tree") then
        error(methodName .. " tree must be an OptionsKit tree", 2)
    end
    local description = nil
    if type(options) ~= "nil" then
        if type(options) ~= "table" then
            error(methodName .. " options must be a table", 2)
        end
        refuseUnknownFields(options, BIND_OPTION_FIELDS, methodName .. " options", 3)
        description = rawget(options, "description")
        validateOptionalString(description, methodName .. " options.description", 3)
    end
    local registered, reason =
        registerCommand(self, commandName, newOptionsSpec(tree, description), methodName, 3)
    return registered, reason
end

---Complete this scope's sub-command names and arguments on Tab. Returns
---`false` when the host has no `ChatEdit_CustomTabPressed`.
---@param self CommandKit.Scope
---@return boolean enabled
local function scopeEnableCompletion(self)
    validateScope(self, "CommandKit.Scope:EnableCompletion", 3)
    ensureOpen(self, "CommandKit.Scope:EnableCompletion", 3)
    if rawget(self, "_completion") == true then
        return true
    end
    if not installTabHandler() then
        return false
    end
    rawset(self, "_completion", true)
    completion.enabledScopes = completion.enabledScopes + 1
    return true
end

---Stop completing this scope's commands.
---@param self CommandKit.Scope
---@return boolean disabled `false` when completion was not enabled.
local function scopeDisableCompletion(self)
    validateScope(self, "CommandKit.Scope:DisableCompletion", 3)
    return disableCompletion(self)
end

---Close the scope: unregister every command and turn completion off.
---Terminal.
---@param self CommandKit.Scope
---@return boolean closed `false` when the scope was already closed.
local function scopeClose(self)
    validateScope(self, "CommandKit.Scope:Close", 3)
    if rawget(self, "_closed") == true then
        return false
    end
    rawset(self, "_closed", true)
    LogoutClose.releaseSubscription(self)
    disableCompletion(self)
    local commands = rawget(self, "_commands")
    local names = {}
    for name in next, commands do
        names[#names + 1] = name
    end
    for index = 1, #names do
        releaseCommand(self, names[index], rawget(commands, names[index]))
    end
    return true
end

---@param self CommandKit.Scope
---@return boolean
local function scopeIsClosed(self)
    validateScope(self, "CommandKit.Scope:IsClosed", 3)
    return rawget(self, "_closed") == true
end

---@param self CommandKit.Scope
---@return integer
local function scopeGetActiveCount(self)
    validateScope(self, "CommandKit.Scope:GetActiveCount", 3)
    return rawget(self, "_count")
end

---@param self CommandKit.Scope
---@return string|nil
local function scopeGetAddonName(self)
    validateScope(self, "CommandKit.Scope:GetAddonName", 3)
    local addonName = rawget(self, "_addonName")
    if addonName == false then
        return nil
    end
    return addonName
end

-- Package public API ---------------------------------------------------------

---Whether `value` is an exact integer of one or more. `nan` and both
---infinities are rejected before the integer test can accept them.
---@param value any
---@return boolean
local function isPositiveInteger(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value >= 1
        and value % 1 == 0
end

---The value a scope keeps for one limit option: the integer, or `math.huge`
---for `UNBOUNDED`, so every comparison on the registration path stays numeric.
---@param options table|nil
---@param field string
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
---@return number
local function readScopeLimit(options, field, label, level)
    local value = nil
    if type(options) ~= "nil" then
        value = rawget(options, field)
    end
    local refusal = label .. "." .. field .. " must be a positive integer or CommandKit.UNBOUNDED"
    -- A secret is refused before anything compares it or tests its truth.
    if isSecret(value) then
        error(refusal, level)
    end
    -- `false` has always read as an absent field, and keeps doing so.
    if type(value) == "nil" or value == false then
        return SCOPE_OPTION_FIELDS[field]
    end
    if type(value) == "table" and value == UNBOUNDED then
        return math.huge
    end
    if not isPositiveInteger(value) then
        error(refusal, level)
    end
    return value
end

---Check a scope option table and resolve its limits, raising at the caller
---before anything is created.
---@param options any
---@param label string argument description, used in the argument errors
---@param level integer stack level the failures are reported at
---@return table limits field name to the resolved limit
local function readScopeOptions(options, label, level)
    local present = type(options) ~= "nil"
    if present and (type(options) ~= "table" or type(getmetatable(options)) ~= "nil") then
        error(label .. " must be a table", level)
    end
    if present then
        for key in next, options do
            if type(key) ~= "string" or SCOPE_OPTION_FIELDS[key] == nil then
                error(label .. "." .. tostring(key) .. " is not a recognised option", level)
            end
        end
    end
    local limits = {}
    for index = 1, #SCOPE_OPTION_NAMES do
        local field = SCOPE_OPTION_NAMES[index]
        limits[field] = readScopeLimit(options, field, label, level + 1)
    end
    return limits
end

---@param addonName string|false
---@param limits table resolved scope limits from `readScopeOptions`
---@return CommandKit.Scope
local function newScope(addonName, limits)
    return setmetatable({
        _schema = SCOPE_SCHEMA,
        _addonName = addonName,
        _closed = false,
        _count = 0,
        _commands = {},
        _sink = false,
        _completion = false,
        _maxCommands = limits.maxCommands,
        _maxSubcommands = limits.maxSubcommands,
        _maxPositions = limits.maxPositions,
        _maxSlashAliases = limits.maxSlashAliases,
        -- See "Logout close": `false` for a manual scope, nobody yet for an
        -- addon scope, until `ForAddon` arranges it.
        _logoutCloser = addonName ~= false and LOGOUT.byNobody or false,
        _shutdownSubscription = false,
    }, SCOPE_METATABLE)
end

---Create a manually owned command scope, closed only by its owner.
---@param self CommandKit
---@param options CommandKit.ScopeOptions? limits of this scope
---@return CommandKit.Scope scope
local function createScope(self, options)
    validateFacade(self, "CommandKit:CreateScope", 3)
    local limits = readScopeOptions(options, "CommandKit:CreateScope options", 3)
    return newScope(false, limits)
end

---Refuse options that disagree with the limits an existing scope was created
---with, so a second caller never believes it opened a limit it did not.
---@param scope CommandKit.Scope
---@param options table|nil
---@param limits table resolved limits of `options`
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function refuseConflictingOptions(scope, options, limits, label, level)
    if type(options) == "nil" then
        return
    end
    for index = 1, #SCOPE_OPTION_NAMES do
        local field = SCOPE_OPTION_NAMES[index]
        if
            type(rawget(options, field)) ~= "nil"
            and limits[field] ~= rawget(scope, "_" .. field)
        then
            error(
                label
                    .. "."
                    .. field
                    .. " differs from the limit this addon's scope was created with",
                level
            )
        end
    end
end

---Return the canonical command scope of an addon, creating it on demand.
---
---CommandKit does not observe addon shutdown, but every call makes sure
---somebody who does closes this scope through
---`CommandKit:CloseAddonScopes(addonName)`: LifecycleKit, CommandKit's own
---`PLAYER_LOGOUT` watcher through EventKit, or, with neither loaded, the addon
---itself (docs/API.md, "At logout").
---
---`options` sets the limits when this call creates the scope. On a later call
---a limit that differs from the scope's is refused at the caller; one that
---agrees, or none at all, is accepted.
---@param self CommandKit
---@param addonName string addon folder name
---@param options CommandKit.ScopeOptions? limits of the scope, applied when it is created
---@return CommandKit.Scope scope
local function forAddon(self, addonName, options)
    validateFacade(self, "CommandKit:ForAddon", 3)
    validateString(addonName, "CommandKit:ForAddon addonName", 3)
    local limits = readScopeOptions(options, "CommandKit:ForAddon options", 3)
    local scope = rawget(addonScopes, addonName)
    if scope == nil then
        scope = newScope(addonName, limits)
        rawset(addonScopes, addonName, scope)
    else
        refuseConflictingOptions(scope, options, limits, "CommandKit:ForAddon options", 3)
    end
    LogoutClose.arrangeProtected(addonName, scope)
    return scope
end

---Close the canonical scope of an addon, unregistering every command it owns.
---Nothing is recorded for an addon that never asked for a scope.
---@param self CommandKit
---@param addonName string addon folder name
---@return boolean closed `false` when the addon has no scope or it was already closed.
local function closeAddonScopes(self, addonName)
    validateFacade(self, "CommandKit:CloseAddonScopes", 3)
    validateString(addonName, "CommandKit:CloseAddonScopes addonName", 3)
    local scope = rawget(addonScopes, addonName)
    if scope == nil then
        return false
    end
    return scopeClose(scope)
end

---Check the text argument of `Parse` and `ParseInto`.
---@param text any
---@param methodName string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateText(text, methodName, level)
    if type(text) ~= "string" then
        error(methodName .. " text must be a string", level)
    end
    if isSecret(text) then
        error(methodName .. " text must not be a secret value", level)
    end
end

---Split `text` into arguments, allocating a new array on every call. Returns
---the array, or `nil` and `"unterminated quote"` / `"unterminated link"`.
---@param self CommandKit
---@param text string
---@return string[]|nil arguments
---@return string|nil reason
local function parse(self, text)
    validateFacade(self, "CommandKit:Parse", 3)
    validateText(text, "CommandKit:Parse", 3)
    local array = {}
    local count, reason = tokenize(text, array)
    if count == nil then
        return nil, reason
    end
    return array
end

---Split `text` into `array[1..count]`, clear the slots after `count`, and
---return `count`; or `nil` and a reason, leaving `array` empty.
---@param self CommandKit
---@param text string
---@param array table
---@return integer|nil count
---@return string|nil reason
local function parseInto(self, text, array)
    validateFacade(self, "CommandKit:ParseInto", 3)
    validateText(text, "CommandKit:ParseInto", 3)
    if type(array) ~= "table" then
        error("CommandKit:ParseInto array must be a table", 2)
    end
    local count, reason = tokenize(text, array)
    return count, reason
end

---A sink that keeps what it receives, for tests.
---@param self CommandKit
---@return CommandKit.CaptureSink
local function captureSink(self)
    validateFacade(self, "CommandKit:CaptureSink", 3)
    return newCaptureSink()
end

---Check a `SetLimits` table whole, raising at the caller before anything
---changes.
---@param limits any
---@param level integer stack level the failures are reported at
local function validateLimitUpdate(limits, level)
    if type(limits) ~= "table" or type(getmetatable(limits)) ~= "nil" then
        error("CommandKit:SetLimits limits must be a table", level)
    end
    for key, value in next, limits do
        local label = "CommandKit:SetLimits limits." .. tostring(key)
        if type(key) ~= "string" or rawget(sharedLimits, key) == nil then
            error(label .. " is not a recognised limit", level)
        end
        local ceiling = LIMIT_CEILINGS[key]
        -- A secret is refused with the type message before any comparison;
        -- after this, `value == UNBOUNDED` compares a plain value.
        local secret = isSecret(value)
        if ceiling == nil then
            if secret or (value ~= UNBOUNDED and not isPositiveInteger(value)) then
                error(label .. " must be a positive integer or CommandKit.UNBOUNDED", level)
            end
        elseif not secret and value == UNBOUNDED then
            error(
                label .. " cannot be CommandKit.UNBOUNDED: " .. LIMIT_UNBOUNDED_REFUSALS[key],
                level
            )
        elseif secret or not isPositiveInteger(value) or value > ceiling then
            error(label .. " must be an integer from 1 to " .. ceiling, level)
        end
    end
end

---Change any subset of the package-wide limits. They are shared by every
---consumer in the session; lowering one never drops what is already kept.
---@param self CommandKit
---@param limits CommandKit.Limits
local function setLimits(self, limits)
    validateFacade(self, "CommandKit:SetLimits", 3)
    validateLimitUpdate(limits, 3)
    for index = 1, #LIMIT_NAMES do
        local name = LIMIT_NAMES[index]
        local value = rawget(limits, name)
        if type(value) ~= "nil" then
            rawset(sharedLimits, name, value)
        end
    end
end

---Return a fresh copy of the package-wide limits. Allocates one table.
---@param self CommandKit
---@return CommandKit.Limits
local function getLimits(self)
    validateFacade(self, "CommandKit:GetLimits", 3)
    return {
        maxCaptured = rawget(sharedLimits, "maxCaptured"),
        maxCompletions = rawget(sharedLimits, "maxCompletions"),
        maxEmotes = rawget(sharedLimits, "maxEmotes"),
    }
end

-- Commit ---------------------------------------------------------------------

rawset(Scope, "Register", scopeRegister)
rawset(Scope, "Unregister", scopeUnregister)
rawset(Scope, "IsRegistered", scopeIsRegistered)
rawset(Scope, "SetSink", scopeSetSink)
rawset(Scope, "BindOptions", scopeBindOptions)
rawset(Scope, "EnableCompletion", scopeEnableCompletion)
rawset(Scope, "DisableCompletion", scopeDisableCompletion)
rawset(Scope, "Close", scopeClose)
rawset(Scope, "IsClosed", scopeIsClosed)
rawset(Scope, "GetActiveCount", scopeGetActiveCount)
rawset(Scope, "GetAddonName", scopeGetAddonName)

rawset(Context, "Print", contextPrint)
rawset(Context, "Printf", contextPrintf)
rawset(Context, "Usage", contextUsage)
rawset(Context, "Fail", contextFail)
rawset(Context, "GetCommandPath", contextGetCommandPath)
rawset(Context, "GetRawText", contextGetRawText)

rawset(CommandKit, "API", API_GENERATION)
rawset(CommandKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(CommandKit, "MAX_COMMANDS", DEFAULT_MAX_COMMANDS)
rawset(CommandKit, "MAX_DEPTH", MAX_DEPTH)
rawset(CommandKit, "UNBOUNDED", UNBOUNDED)
rawset(CommandKit, "CreateScope", createScope)
rawset(CommandKit, "ForAddon", forAddon)
rawset(CommandKit, "CloseAddonScopes", closeAddonScopes)
rawset(CommandKit, "Parse", parse)
rawset(CommandKit, "ParseInto", parseInto)
rawset(CommandKit, "CaptureSink", captureSink)
rawset(CommandKit, "SetLimits", setLimits)
rawset(CommandKit, "GetLimits", getLimits)

rawset(dispatch, "slash", slashDispatch)
rawset(dispatch, "tabPressed", tabPressed)
rawset(dispatch, "closeAddonScopesAtLogout", LogoutClose.closeAtLogout)
rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(CommandKit) or not validateCurrentState(CommandKit) then
    error("MoltenCodes CommandKit package state is corrupted or incomplete", 2)
end

if previousRevision ~= nil then
    LogoutClose.arrangeInherited()
end

return CommandKit
