-- MoltenCodes CommandKit
--
-- Slash commands for World of Warcraft addons, done once: registration owned by
-- a scope, an argument parser that keeps quoted text, hyperlinks and colour
-- codes whole, sub-commands whose usage text is generated from their
-- declarations, output written to a replaceable sink, and, in parts (ADR
-- 0001), arguments checked against SchemaKit schemas, tab completion and a
-- binding that drives an OptionsKit tree from the command line.
--
-- The client's slash tables are shared and collision-prone. CommandKit writes
-- `SlashCmdList[<key>]` and `SLASH_<key>1` through `rawset`, with a key derived
-- from the addon and command names, refuses a slash name another owner already
-- uses (`nil, "taken"`), and never removes what it wrote: the client caches the
-- function behind a slash name, so an unregistered command keeps a permanent
-- dispatcher that does nothing until the name is registered again.
--
-- The core needs Registry API 2 only. LocaleKit API 1 (`Printf`) is optional
-- and found through `Registry:Find` when it is used. The Arguments part
-- (`parts/CommandKit-Arguments.lua`) needs SchemaKit API 1, the Options part
-- OptionsKit API 1 and the Arguments part; the Completion part needs nothing
-- beyond the core.
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
--   Dependencies .......... Registry and the host facilities read
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Host access ........... slash tables, the error handler, the secret probe
--   Argument checks ....... receivers, names, spec tables
--   Parser ................ the tokeniser behind Parse, ParseInto and dispatch
--   Output ................ sinks, the capture sink, line writing
--   Arguments ............. the hand-over to the Arguments part
--   Command records ....... compiling a spec into an immutable record tree
--   Slash registration .... keys, the taken check and its caches, dispatchers
--   Dispatch .............. frames, sub-command walk, validation, the handler
--   Context methods ....... what a handler receives
--   Logout close .......... who closes an addon scope at logout
--   Scope extras .......... command lists, prefix, printing, Dispatch, Reopen,
--                            and the methods the parts serve
--   Scope methods ......... the handle a scope owner receives
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment and self-check
--
-- Layout and invariants are described in `docs/INTERNALS.md`.

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "commandKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 12
-- The last revision whose core compiled and checked arguments itself; the
-- Arguments part has done it since (see "Arguments").
local LAST_CORE_ARGUMENTS_REVISION = 11
local REQUIRED_REGISTRY_API = 2
local OPTIONAL_LOCALEKIT_API = 1
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

-- The most completion providers (`RegisterCompletion`, the Completion part)
-- the session holds. Every Tab press walks them, so the limit has the same
-- ceiling and refuses `UNBOUNDED`.
local DEFAULT_MAX_COMPLETION_PROVIDERS = 32

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

-- The package-wide limits `SetLimits` accepts, in the order `GetLimits`
-- reports them, as the rules of the shared `limits` block
-- (`tooling/shared/lua/limits.lua`). `maxCaptured` may be lifted with
-- `UNBOUNDED`; its ceiling, the largest 32-bit integer, only gives the block
-- the upper bound it needs and refuses nothing a sink could use. The others
-- refuse `UNBOUNDED` for the reason given.
local LIMIT_RULES = {
  { name = "maxCaptured", ceiling = 2147483647, unbounded = true },
  {
    name = "maxCompletions",
    ceiling = MAX_COMPLETIONS_CEILING,
    unboundedReason = "the candidates are printed to the shared chat frame as one line",
  },
  {
    name = "maxEmotes",
    ceiling = MAX_EMOTES_CEILING,
    unboundedReason = "emote indexes have gaps, so the scan needs an end",
  },
  {
    name = "maxCompletionProviders",
    ceiling = MAX_COMPLETIONS_CEILING,
    unboundedReason = "every Tab press asks every provider",
  },
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

-- The published surface, listed once so the public-surface predicate reads as
-- a checklist instead of a long boolean expression.
local FACADE_METHODS = {
  "GetCommands",
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
  "GetBoundTree",
  "EnableCompletion",
  "DisableCompletion",
  "RegisterCompletion",
  "UnregisterCompletion",
  "IsCompletionRegistered",
  "GetCommands",
  "SetPrefix",
  "GetPrefix",
  "Print",
  "Printf",
  "Dispatch",
  "Reopen",
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
local BYTE_DOUBLE_QUOTE = 34
local BYTE_SINGLE_QUOTE = 39
local BYTE_BACKSLASH = 92
local BYTE_PIPE = 124
local BYTE_LINK = 72 -- "H": starts a hyperlink
local BYTE_COLOUR = 99 -- "c": starts a colour code
local BYTE_TEXTURE = 84 -- "T": starts a texture

-- What the parser needs to know of a byte: whitespace between tokens (space,
-- tab, newline, return) or a quote character.
local BYTE_CLASS = { [32] = "space", [9] = "space", [10] = "space", [13] = "space" }
BYTE_CLASS[BYTE_DOUBLE_QUOTE] = "quote"
BYTE_CLASS[BYTE_SINGLE_QUOTE] = "quote"

-- The patterns the parser finds its next stop with, so a run of ordinary bytes
-- is skipped by one `string.find` in C rather than byte by byte in Lua. The
-- character classes are exactly the bytes `BYTE_CLASS` and the escape handling
-- name: whitespace, the pipe that starts an escape sequence, the backslash
-- and the closing quote.
local PARSER_PATTERNS = {
  -- The first byte of the next token.
  tokenStart = "[^ \t\n\r]",
  -- The end of a bare run, or a pipe inside it.
  bareStop = "[ \t\n\r|]",
  -- What ends or interrupts a quoted segment, by quote byte.
  quotedStop = { [BYTE_DOUBLE_QUOTE] = '[\\"|]', [BYTE_SINGLE_QUOTE] = "[\\'|]" },
}

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
---@field maxCompletionProviders integer? Completion providers the session holds; default 32, at most 256.

---Option table accepted by `BindOptions`.
---@class CommandKit.BindOptions
---@field description string? The bound command's help line.
---@field syntax ("verbs"|"path")? `"path"` adds AceConfigCmd's `/cmd group option value`; default `"verbs"`.
---@field onEmpty (fun(context: CommandKit.Context))? Runs for an empty line instead of the usage or the root listing.

---The owner of a set of slash commands, released together by `Close`.
---@class CommandKit.Scope
---@field Register fun(self: CommandKit.Scope, name: string, spec: CommandKit.CommandSpec): true|nil, "taken"|"emote"|"full"|nil
---@field Unregister fun(self: CommandKit.Scope, name: string): boolean
---@field IsRegistered fun(self: CommandKit.Scope, name: string): boolean
---@field SetSink fun(self: CommandKit.Scope, sink: CommandKit.Sink?)
---@field BindOptions fun(self: CommandKit.Scope, tree: table, commandName: string, options: CommandKit.BindOptions?): true|nil, "taken"|"emote"|"full"|nil Options part
---@field GetBoundTree fun(self: CommandKit.Scope, name: string): table? Options part
---@field EnableCompletion fun(self: CommandKit.Scope): boolean Completion part
---@field DisableCompletion fun(self: CommandKit.Scope): boolean Completion part
---@field RegisterCompletion fun(self: CommandKit.Scope, name: string, pattern: string, provider: fun(partial: string, before: string, editBox: table): string[]?): true|nil, "taken"|"full"|"unavailable"|nil Completion part
---@field UnregisterCompletion fun(self: CommandKit.Scope, name: string): boolean Completion part
---@field IsCompletionRegistered fun(self: CommandKit.Scope, name: string): boolean Completion part
---@field GetCommands fun(self: CommandKit.Scope): string[]
---@field SetPrefix fun(self: CommandKit.Scope, prefix: string?): string?
---@field GetPrefix fun(self: CommandKit.Scope): string?
---@field Print fun(self: CommandKit.Scope, ...: any)
---@field Printf fun(self: CommandKit.Scope, template: string, ...: any)
---@field Dispatch fun(self: CommandKit.Scope, name: string, text: string): boolean
---@field Reopen fun(self: CommandKit.Scope): boolean
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
---@field GetCommands fun(self: CommandKit): string[]

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
      maxCompletionProviders = DEFAULT_MAX_COMPLETION_PROVIDERS,
    },
    -- The package-level `PLAYER_LOGOUT` watcher (see "Logout close"): the
    -- EventKit scope that owns it, the connection once made, and the
    -- trampoline handed to EventKit, which calls through `dispatch`.
    logoutWatch = { scope = false, connection = false, trampoline = false },
    -- Each loaded part's record, `{ revision, methods, ... }` (revision 11,
    -- ADR 0001), and the core functions the parts call.
    parts = {},
    helpers = {},
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
-- Revisions 10 and 11 kept `clientKitLookup`, the ClientKit their secret
-- probe asked. Revision 12 asks the client's probe itself (the shared
-- `isSecret` block) and no longer reads it; the field stays in an inherited
-- state, because the revision-11 functions kept for the Arguments hand-over
-- (see "Arguments") still read it.
-- Revisions before 11 had no parts and no provider limit.
if rawget(state, "parts") == nil then
  rawset(state, "parts", {})
end
if rawget(state, "helpers") == nil then
  rawset(state, "helpers", {})
end
if rawget(rawget(state, "limits"), "maxCompletionProviders") == nil then
  rawset(rawget(state, "limits"), "maxCompletionProviders", DEFAULT_MAX_COMPLETION_PROVIDERS)
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

-- The failure handed to `reportError` is passed on unchanged: it may be a
-- secret string built from a secret argument, and CommandKit never inspects
-- it. The secret probe is the client's `issecretvalue` (revision 12: earlier
-- revisions asked ClientKit first, whose `IsSecret` asks the same probe). The
-- allocation-free dispatch path never calls it: typed text is never secret.
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

-- shared:begin isSecret 1
-- Copied from tooling/shared/lua/isSecret.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Whether `value` is a secret value the host forbids comparing.
---@type fun(value: any): boolean
local isSecret
do
  -- issecretvalue is a client API reachable only through the global table.
  -- selene: allow(global_usage)
  local loadedProbe = rawget(_G, "issecretvalue")
  if type(loadedProbe) ~= "function" then
    loadedProbe = nil
  end

  isSecret = function(value)
    local probe = loadedProbe
    if probe == nil then
      -- selene: allow(global_usage)
      probe = rawget(_G, "issecretvalue")
      if type(probe) ~= "function" then
        return false
      end
    end
    return probe(value) == true
  end
end
-- shared:end isSecret

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

-- shared:begin validateFacade 1 __FACADE__=CommandKit
-- Copied from tooling/shared/lua/validateFacade.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Raise at `level` unless `receiver` is the CommandKit facade.
---@param receiver any the table the method was called on
---@param label string qualified method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
  if type(receiver) ~= "table" or receiver ~= CommandKit then
    local hint = "; use " .. label .. "(...)"
    error(label .. " must be called on the CommandKit facade" .. hint, level)
  end
end
-- shared:end validateFacade

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
-- One pass over the text, with no state outside the call: `string.find` jumps
-- to the next byte that matters (whitespace, a quote, a backslash or a pipe),
-- so ordinary bytes are never visited one by one in Lua. A
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
---it. Jumps from one backslash, pipe or quote to the next with `string.find`.
---@param text string
---@param position integer the position of the opening quote
---@param length integer
---@param quote integer the quote byte
---@return integer|nil close the position of the closing quote
---@return boolean|string escapedOrReason whether an escape was seen, or why there is no close
local function findClosingQuote(text, position, length, quote)
  local pattern = PARSER_PATTERNS.quotedStop[quote]
  local cursor = position + 1
  local escaped = false
  while true do
    local found = text:find(pattern, cursor)
    if found == nil then
      return nil, "unterminated quote"
    end
    local byte = text:byte(found)
    if byte == BYTE_BACKSLASH then
      local nextByte = text:byte(found + 1)
      if nextByte == quote or nextByte == BYTE_BACKSLASH then
        escaped = true
        cursor = found + 2
      else
        cursor = found + 1
      end
    elseif byte == quote then
      return found, escaped
    else
      local nextPosition, reason = skipEscape(text, found, length, true)
      if nextPosition == nil then
        return nil, reason --[[@as string]]
      end
      cursor = nextPosition
    end
  end
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

---Read a bare run starting at `position`, up to whitespace or the end. Jumps
---from one pipe to the next with `string.find`; an escape sequence it starts
---is skipped whole.
---@param text string
---@param position integer
---@param length integer
---@return string|nil segment
---@return integer|string nextPositionOrReason
local function readBare(text, position, length)
  local pattern = PARSER_PATTERNS.bareStop
  local cursor = position
  while true do
    local stop = text:find(pattern, cursor)
    if stop == nil then
      -- Every step below lands at most one past the end, so this is where
      -- a byte-by-byte walk would have stopped too.
      cursor = length + 1
      break
    end
    if text:byte(stop) ~= BYTE_PIPE then
      cursor = stop
      break
    end
    local nextPosition, reason = skipEscape(text, stop, length, false)
    if nextPosition == nil then
      return nil, reason --[[@as string]]
    end
    cursor = nextPosition
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
  -- A bare run stops only at whitespace or the end, so a token that starts
  -- with anything but a quote is exactly one bare run.
  if BYTE_CLASS[text:byte(position)] ~= "quote" then
    return readBare(text, position, length)
  end
  local token = nil
  local cursor = position
  local quoteMayOpen = true
  while cursor <= length do
    local byte = text:byte(cursor)
    local class = BYTE_CLASS[byte]
    if class == "space" then
      break
    end
    local segment
    ---@type integer|nil
    local close = nil
    ---@type boolean|string
    local escapedOrReason = false
    if quoteMayOpen and class == "quote" then
      close, escapedOrReason = findClosingQuote(text, cursor, length, byte)
      if close == nil and byte == BYTE_DOUBLE_QUOTE then
        return nil, escapedOrReason --[[@as string]]
      end
      if close ~= nil and byte == BYTE_SINGLE_QUOTE then
        local after = text:byte(close + 1)
        if after ~= nil and BYTE_CLASS[after] == nil then
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
  local failure = nil
  local pattern = PARSER_PATTERNS.tokenStart
  local position = text:find(pattern)
  while position ~= nil do
    local token, nextPosition = readToken(text, position, length)
    if token == nil then
      failure = nextPosition
      break
    end
    count = count + 1
    array[count] = token
    position = text:find(pattern, nextPosition --[[@as integer]])
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
  -- A scope's prefix (revision 11), absent unless its owner set one.
  local prefix = rawget(scope, "_prefix")
  if prefix ~= nil then
    text = prefix .. text
  end
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

-- Arguments ----------------------------------------------------------------
--
-- Schema-checked arguments live in the Arguments part (ADR 0001,
-- `parts/CommandKit-Arguments.lua`), which needs SchemaKit. The core compiles a
-- spec without `arguments` itself (every token reaches the handler as a
-- string) and hands a spec's `arguments` to the part, read from
-- `_state.parts` at call time. Without the part a spec with `arguments` is
-- refused at the caller's line, naming the file to embed.
--
-- Revision 11 and older kept the arguments in the core. When this revision
-- upgrades one of them and the part is not loaded, the older revision's
-- `registerCommand` and slash dispatcher are kept in
-- `state.legacyArguments`, so an addon that embeds only the older file keeps
-- registering and running its commands with arguments (see "Commit"). The
-- part drops them when it loads: it reads the records they built as its own.

-- A record's parts are never modified once compiled, so every record without
-- arguments shares one compiled form, and every record without sub-commands
-- one empty table for its sub-command map and name list: a Register of a plain
-- command allocates its record, not five empty tables beside it. Nothing
-- writes to either: `compileSubcommands` gives a record with sub-commands
-- tables of its own first.
local EMPTY = {}
local NO_ARGUMENTS =
  { mode = "none", schemas = EMPTY, coercions = EMPTY, defaulted = EMPTY, count = 0, usage = "" }

---Compile a spec's `arguments` field through the Arguments part.
---@param arguments any
---@param label string argument description, used in the argument errors
---@param level integer stack level the failures are reported at
---@param maxPositions number the scope's `maxPositions`, `math.huge` when unbounded
---@return table compiled `{ mode, schemas, coercions, defaulted, count, usage }`
local function compileArguments(arguments, label, level, maxPositions)
  if type(arguments) == "nil" then
    return NO_ARGUMENTS
  end
  local part = rawget(rawget(state, "parts"), "Arguments")
  if type(part) ~= "table" then
    error(
      label
        .. " needs CommandKit's Arguments part, which is not loaded: add commandKit\\parts\\CommandKit-Arguments.lua to your embeds.xml",
      level
    )
  end
  local compiled = part.compile(arguments, label, level + 1, maxPositions)
  return compiled
end

-- Command records ------------------------------------------------------------
--
-- `Register` compiles a spec into a record tree once. Records are never
-- modified afterwards; dispatch only reads them. Records and frames are plain
-- tables without a metatable, so the dispatch path reads their fields with
-- plain indexing rather than `rawget`, which is a C call per field.

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
  local children = {}
  local names = {}
  rawset(record, "_subcommands", children)
  rawset(record, "_subcommandNames", names)
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
    _subcommands = EMPTY,
    _subcommandNames = EMPTY,
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

-- The global names the taken check reads, built once per key and index:
-- `slashGlobalNames[key][index]` is `"SLASH_" .. key .. index`. A Register
-- reads the aliases of every foreign key, and building each name by
-- concatenation on every call was most of its cost. The table grows with the
-- keys the host tables hold, which the client keeps for the session anyway.
-- A file-level cache, not package state: a newer revision starts empty.
local Taken = {
  slashGlobalNames = {},
  emoteIndex = {
    -- The set of upper-case emote slash texts, or `false` before the first scan.
    slashes = false,
    -- The effective count and the probe the set was built with.
    count = -1,
    probe = false,
  },
}

---Whether any key of `list` (every string key; with `skipOwned`, every one
---CommandKit does not own) has a `SLASH_<key>1..n` global, read up to the
---first gap, that names `upperSlash`. A secret value is skipped before
---anything else touches it; the length test spares the upper-case copy of
---every value that cannot match. One function with the loops inline: it runs
---over every foreign key on every Register.
---@param list table
---@param skipOwned boolean
---@param upperSlash string
---@param maxAliases number the scope's `maxSlashAliases`, `math.huge` when unbounded
---@return boolean
function Taken.anyAliasNames(list, skipOwned, upperSlash, maxAliases)
  local probe = readGlobal("issecretvalue")
  local probing = type(probe) == "function"
  local length = #upperSlash
  local namesByKey = Taken.slashGlobalNames
  -- The slash globals are World of Warcraft client globals.
  -- selene: allow(global_usage)
  local globals = _G
  -- Locals, not globals: each global name read in the loop is a table lookup.
  local rawRead, typeOf = rawget, type
  for key in next, list do
    if typeOf(key) == "string" and not (skipOwned and ownedKeys[key] ~= nil) then
      local names = namesByKey[key]
      if names == nil then
        names = {}
        namesByKey[key] = names
      end
      for index = 1, maxAliases do
        local name = names[index]
        if name == nil then
          name = "SLASH_" .. key .. index
          names[index] = name
        end
        local value = rawRead(globals, name)
        if typeOf(value) ~= "string" then
          break
        end
        local secret = probing and probe(value) == true
        if not secret and #value == length and value:upper() == upperSlash then
          return true
        end
      end
    end
  end
  return false
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
  return Taken.anyAliasNames(list, true, upperSlash, maxAliases)
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
  return Taken.anyAliasNames(chatTypes, false, upperSlash, maxAliases)
end

---Whether `value` is secret on this host. `probe` is the host's
---`issecretvalue`, or not a function on a host without secret values.
---@param probe any
---@param value any
---@return boolean
local function isSecretOnHost(probe, value)
  return type(probe) == "function" and probe(value) == true
end

---Whether `handler` is a dispatcher CommandKit wrote.
---@param handler function
---@return boolean
local function isOwnHandler(handler)
  for _, own in next, slashHandlers do
    if own == handler then
      return true
    end
  end
  return false
end

---Whether the client's own command hashes claim `upperSlash`.
---
---Retail 12.1 (Blizzard_ChatFrameBase, build 69933) no longer leaves its
---commands where the scans above look: at load, and again before each typed
---line is parsed, `ChatFrameUtil.ImportAllListsToHash` moves every entry of
---`SlashCmdList`, `ChatTypeInfo` and the chat frame's private secure-command
---list into lookup tables keyed by the upper-case slash text, then wipes the
---source tables (their entries stay reachable only through an `__index`
---proxy, which `next` does not see), and `SecureCmdList` is no longer a
---global. The global lookup tables are `hash_ChatTypeInfoList` (every
---imported slash text of all three lists, to its key or chat type) and
---`hash_SlashCmdList` (slash text to function); `IsSecureCmd(command)` answers
---for the secure list. An entry that is CommandKit's own, by key or by
---dispatcher, is not a claim; a secret entry is skipped, as in the scans.
---@param upperSlash string
---@return boolean
local function isHostHashedSlash(upperSlash)
  local probe = readGlobal("issecretvalue")
  local chatTypeHash = readGlobal("hash_ChatTypeInfoList")
  if type(chatTypeHash) == "table" then
    local owner = rawget(chatTypeHash, upperSlash)
    if type(owner) ~= "nil" and not isSecretOnHost(probe, owner) then
      if type(owner) ~= "string" or ownedKeys[owner] == nil then
        return true
      end
    end
  end
  local slashHash = readGlobal("hash_SlashCmdList")
  if type(slashHash) == "table" then
    local handler = rawget(slashHash, upperSlash)
    if type(handler) ~= "nil" and not isSecretOnHost(probe, handler) then
      if type(handler) ~= "function" or not isOwnHandler(handler) then
        return true
      end
    end
  end
  local isSecureCommand = readGlobal("IsSecureCmd")
  if type(isSecureCommand) == "function" then
    local answered, secure = pcall(isSecureCommand, upperSlash)
    if answered and type(secure) == "boolean" and not isSecretOnHost(probe, secure) then
      return secure
    end
  end
  return false
end

-- The emote index: every non-secret `EMOTE<n>_CMD<m>` value, upper case, as a
-- set. The emote commands are client constants (GlobalStrings, loaded before
-- any addon, never changed at run time), so reading up to 1,024 x 8 globals by
-- constructed name on every Register rebuilt the same answer each time. The
-- index is built at the first emote check and read from then on. It is built
-- again when what bounds or filters the scan changes: the effective emote
-- count (`maxEmotes`, `MAXEMOTEINDEX`) or the host's `issecretvalue` probe.
-- A scan that meets a secret value keeps no index, so the next check scans
-- again and asks the probe afresh, as before. A file-level cache, not package
-- state: a newer revision starts empty. See docs/INTERNALS.md.

---The emote indexes the check reads: `maxEmotes`, or the host's
---`MAXEMOTEINDEX` when it is a smaller non-negative number.
---@return integer
function Taken.emoteScanCount()
  local count = rawget(sharedLimits, "maxEmotes")
  local hostCount = readGlobal("MAXEMOTEINDEX")
  if type(hostCount) == "number" and hostCount >= 0 and hostCount < count then
    count = hostCount
  end
  return count
end

---Read `EMOTE<index>_CMD<n>` for index `1..count` by constructed name, never
---by scanning the global table, into a set of upper-case slash texts.
---@param count integer
---@param probe any the host's `issecretvalue`, or not a function
---@return table<string, true> slashes
---@return boolean complete `false` when a secret value was skipped
function Taken.scanEmotes(count, probe)
  local slashes = {}
  local complete = true
  for index = 1, count do
    for command = 1, MAX_EMOTE_COMMANDS do
      local value = readGlobal("EMOTE" .. index .. "_CMD" .. command)
      if type(value) ~= "string" then
        break
      end
      if isSecretOnHost(probe, value) then
        complete = false
      else
        slashes[value:upper()] = true
      end
    end
  end
  return slashes, complete
end

---Whether an emote claims `upperSlash`. The client resolves slash commands
---before emotes, so a command with an emote's name would silently shadow it.
---Asks the client's `hash_EmoteTokenList` (upper-case slash text to emote
---token) first, then the emote index (above).
---@param upperSlash string
---@return boolean
local function isEmoteSlash(upperSlash)
  local probe = readGlobal("issecretvalue")
  local emoteHash = readGlobal("hash_EmoteTokenList")
  if type(emoteHash) == "table" then
    local token = rawget(emoteHash, upperSlash)
    if type(token) ~= "nil" and not isSecretOnHost(probe, token) then
      return true
    end
  end
  local count = Taken.emoteScanCount()
  local emoteIndex = Taken.emoteIndex
  local slashes = emoteIndex.slashes
  if slashes == false or emoteIndex.count ~= count or emoteIndex.probe ~= (probe or false) then
    local complete
    slashes, complete = Taken.scanEmotes(count, probe)
    if complete then
      emoteIndex.slashes = slashes
      emoteIndex.count = count
      emoteIndex.probe = probe or false
    else
      emoteIndex.slashes = false
    end
  end
  return slashes[upperSlash] == true
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
  -- The revision-11 hand-over (see "Arguments"): only while an older core's
  -- functions are kept and the Arguments part is absent.
  local legacy = state.legacyArguments
  if legacy ~= nil and legacy.declaresArguments(spec, 0) then
    local registered, reason = legacy.registerCommand(scope, name, spec, methodName, level + 1)
    if registered then
      legacy.records[activeByName[string.lower(name)]] = true
    end
    return registered, reason
  end
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
    or isHostHashedSlash(upperSlash)
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
  -- The tree a bound command was bound to (the Options part's `_bound`).
  local bound = rawget(scope, "_bound")
  if bound ~= nil then
    rawset(bound, lowerName, nil)
  end
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
  -- Plain writes: every context field exists from the start (never `nil`),
  -- so no metamethod can run, and the dispatch path avoids a C call per field.
  local context = frame.context
  context._live = false
  context._scope = false
  context._record = false
  context._raw = ""
  rawset(state, "frameDepth", rawget(state, "frameDepth") - 1)
end

---Point a frame's context at a command.
---@param frame table
---@param record table
---@param text string
---@return CommandKit.Context
local function openContext(frame, record, text)
  local context = frame.context
  context._scope = record._scope
  context._record = record
  context._raw = text
  context._live = true
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
  while index <= count and #node._subcommandNames > 0 do
    local child = node._subcommands[tokens[index]:lower()]
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
  local scope = record._scope
  local context = openContext(frame, record, text)
  local tokens = frame.tokens
  local count, reason = tokenize(text, tokens)
  if count == nil then
    failWithUsage(scope, record, reason --[[@as string]])
    return
  end

  local node, index = walkSubcommands(record, tokens, count)
  rawset(context, "_record", node)
  local handler = node._handler
  if handler == false then
    if index <= count then
      failWithUsage(scope, node, 'unknown sub-command "' .. tokens[index] .. '"')
    else
      writeLines(scope, node._usageLines)
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
  for position = argumentCount + 1, frame.argumentMark or 0 do
    arguments[position] = nil
  end
  local writtenCount = node._positionCount
  if writtenCount < argumentCount then
    writtenCount = argumentCount
  end
  frame.argumentMark = writtenCount

  local passCount = argumentCount
  if node._mode ~= "none" then
    -- Only the Arguments part compiles such a record, so it is loaded. The
    -- state and its tables have no metatable: plain indexing, no C call.
    passCount = state.parts.Arguments.check(scope, node, arguments, argumentCount)
    if passCount == nil then
      return
    end
  end
  local ok, failure = pcall(handler, context, unpack(arguments, 1, passCount))
  if not ok then
    reportHandlerFailure(scope, node, failure)
  end
end

---The body of every permanent slash dispatcher.
---@param key string
---@param text any what the client passes: the text after the slash name
---@param editBox any the edit box the command was typed in
local function slashDispatch(key, text, editBox)
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
  local legacy = state.legacyArguments
  if legacy ~= nil and legacy.records[record] then
    legacy.slash(key, text, editBox)
    return
  end
  if type(text) ~= "string" then
    text = ""
  end
  local frame = acquireFrame()
  if frame == nil then
    writeLine(rawget(record, "_scope"), rawget(record, "_path") .. ": commands nested too deeply")
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

-- Scope extras ---------------------------------------------------------------

---Check the text argument of `Parse`, `ParseInto` and `Dispatch`.
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

-- Revision 11 additions share one main-chunk local, because Lua 5.1 allows a
-- chunk at most 200: the command lists, the prefix, printing outside a
-- handler, dispatch from code, `Reopen`, and the bookkeeping of the method parts
-- (ADR 0001): which scope methods each part serves, the stubs that name the
-- part to embed while it is not loaded, and the release `Close` asks for.
local scopeExtras = {
  -- Scope methods served by a part, with the part that serves them.
  PART_METHODS = {
    BindOptions = "Options",
    GetBoundTree = "Options",
    EnableCompletion = "Completion",
    DisableCompletion = "Completion",
    RegisterCompletion = "Completion",
    UnregisterCompletion = "Completion",
    IsCompletionRegistered = "Completion",
  },
}

---A new sorted array of the slash names this scope serves now.
---@param self CommandKit.Scope
---@return string[]
function scopeExtras.GetCommands(self)
  validateScope(self, "CommandKit.Scope:GetCommands", 3)
  local names = {}
  for name in next, rawget(self, "_commands") do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

---A new sorted array of every slash name CommandKit serves in the session,
---whichever scope owns it. AceConsole-3.0's `IterateChatCommands`.
---@param self CommandKit
---@return string[]
function scopeExtras.GetAllCommands(self)
  validateFacade(self, "CommandKit:GetCommands", 3)
  local names = {}
  for name in next, activeByName do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

---Start every line this scope writes with `prefix`, or with nothing for
---`nil`. Returns the previous prefix.
---@param self CommandKit.Scope
---@param prefix string|nil
---@return string|nil previous
function scopeExtras.SetPrefix(self, prefix)
  validateScope(self, "CommandKit.Scope:SetPrefix", 3)
  if prefix ~= nil then
    validateString(prefix, "CommandKit.Scope:SetPrefix prefix", 3)
  end
  local previous = rawget(self, "_prefix")
  rawset(self, "_prefix", prefix)
  return previous
end

---The prefix every line of this scope starts with, or `nil`.
---@param self CommandKit.Scope
---@return string|nil
function scopeExtras.GetPrefix(self)
  validateScope(self, "CommandKit.Scope:GetPrefix", 3)
  return rawget(self, "_prefix")
end

---Write the arguments, converted with `tostring` and joined by spaces, to
---this scope's sink, outside any handler. A secret argument is refused at the
---caller.
---@param self CommandKit.Scope
---@param ... any
function scopeExtras.Print(self, ...)
  validateScope(self, "CommandKit.Scope:Print", 3)
  refuseSecretArguments("CommandKit.Scope:Print", 1, 3, ...)
  local text = ""
  for index = 1, select("#", ...) do
    if index > 1 then
      text = text .. " "
    end
    text = text .. tostring((select(index, ...)))
  end
  writeLine(self, text)
end

---Format as `context:Printf` does (LocaleKit's `Format` when registered) and
---write the result to this scope's sink, outside any handler.
---@param self CommandKit.Scope
---@param template string
---@param ... any
function scopeExtras.Printf(self, template, ...)
  validateScope(self, "CommandKit.Scope:Printf", 3)
  if type(template) ~= "string" then
    error("CommandKit.Scope:Printf template must be a string", 2)
  end
  refuseSecretArguments("CommandKit.Scope:Printf", 1, 3, template)
  refuseSecretArguments("CommandKit.Scope:Printf", 2, 3, ...)
  local LocaleKit = findOptional("localeKit", OPTIONAL_LOCALEKIT_API)
  local text
  if LocaleKit ~= nil and type(rawget(LocaleKit, "Format")) == "function" then
    text = LocaleKit:Format(template, ...)
  else
    text = string.format(template, ...)
  end
  writeLine(self, text)
end

---Run this scope's command `name` with `text`, exactly as the client's slash
---handler runs a typed `/name text`: the same dispatcher, frames and failure
---reporting. AceConfigCmd-3.0's `HandleCommand`.
---@param self CommandKit.Scope
---@param name string the slash name without the slash
---@param text string what would follow the slash name
---@return boolean ran `false` when this scope has no such command
function scopeExtras.Dispatch(self, name, text)
  validateScope(self, "CommandKit.Scope:Dispatch", 3)
  ensureOpen(self, "CommandKit.Scope:Dispatch", 3)
  validateString(name, "CommandKit.Scope:Dispatch name", 3)
  validateText(text, "CommandKit.Scope:Dispatch", 3)
  local lowerName = name:lower()
  local record = rawget(rawget(self, "_commands"), lowerName)
  if record == nil or activeByName[lowerName] ~= record then
    return false
  end
  slashDispatch(rawget(keyByName, lowerName), text)
  return true
end

---Open a closed manual scope again, empty, so its owner can keep using the
---same object; its sink and prefix are kept. `false` for an open scope.
---ModuleKit uses it to keep a module's `scope.Commands` across enables.
---@param self CommandKit.Scope
---@return boolean reopened
function scopeExtras.Reopen(self)
  validateScope(self, "CommandKit.Scope:Reopen", 3)
  if rawget(self, "_addonName") ~= false then
    error(
      "CommandKit.Scope:Reopen cannot reopen an addon scope; closing it is its addon's teardown",
      2
    )
  end
  if rawget(self, "_closed") ~= true then
    return false
  end
  rawset(self, "_closed", false)
  return true
end

---Release what the Completion part holds for a closing scope. Without the
---part, a scope a revision before 11 enabled is still counted off.
---@param scope CommandKit.Scope
function scopeExtras.releaseCompletion(scope)
  local part = rawget(rawget(state, "parts"), "Completion")
  if type(part) == "table" and type(part.releaseScope) == "function" then
    part.releaseScope(scope)
  elseif rawget(scope, "_completion") == true then
    rawset(scope, "_completion", false)
    completion.enabledScopes = completion.enabledScopes - 1
  end
end

---A scope method that names the part to embed, for a part not loaded.
---@param methodName string
---@param partName string
---@return function
function scopeExtras.newPartStub(methodName, partName)
  local message = "CommandKit.Scope:"
    .. methodName
    .. " needs CommandKit's "
    .. partName
    .. " part, which is not loaded: add commandKit\\parts\\CommandKit-"
    .. partName
    .. ".lua to your embeds.xml"
  return function()
    error(message, 2)
  end
end

---Install every part method on the scope prototype: the loaded part's
---function, or a stub. The core runs it at commit and each part after it
---records itself, so any load order of core and part revisions ends with the
---newest of each serving.
function scopeExtras.installPartMethods()
  local parts = rawget(state, "parts")
  for methodName, partName in next, scopeExtras.PART_METHODS do
    local part = rawget(parts, partName)
    local method = type(part) == "table"
        and type(part.methods) == "table"
        and part.methods[methodName]
      or nil
    if type(method) ~= "function" then
      method = scopeExtras.newPartStub(methodName, partName)
    end
    rawset(Scope, methodName, method)
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
  scopeExtras.releaseCompletion(self)
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

-- shared:begin describeKey 1
-- Copied from tooling/shared/lua/describeKey.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Name `key` for an error message without running any of the caller's code.
---@param key any
---@return string
local function describeKey(key)
  if isSecret(key) then
    return "<secret>"
  end
  local kind = type(key)
  if kind == "string" then
    return key
  end
  if kind == "number" or kind == "boolean" then
    return tostring(key)
  end
  return "<" .. kind .. ">"
end
-- shared:end describeKey

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
        error(label .. "." .. describeKey(key) .. " is not a recognised option", level)
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
    -- `false` reads as an absent field (`readScopeLimit`), so it agrees with
    -- any scope; secrets were refused by `readScopeOptions`.
    local value = rawget(options, field)
    if type(value) ~= "nil" and value ~= false and limits[field] ~= rawget(scope, "_" .. field) then
      error(
        label .. "." .. field .. " differs from the limit this addon's scope was created with",
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

-- `SetLimits` and `GetLimits` over `LIMIT_RULES`: the whole update is checked
-- before anything is written, so a refused one leaves every limit as it was.
-- shared:begin limits 1 __FACADE__=CommandKit
-- Copied from tooling/shared/lua/limits.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Check a whole `SetLimits` update; raises at `level`.
---@type fun(limits: any, level: integer)
local validateLimitUpdate
---Write the names an update gives into `target`.
---@type fun(target: table, limits: table)
local applyLimitUpdate
---A fresh table of every limit in `source`.
---@type fun(source: table): table
local copyLimits
do
  local rulesByName = {}
  local names = {}
  for index = 1, #LIMIT_RULES do
    local rule = LIMIT_RULES[index]
    rulesByName[rule.name] = rule
    names[index] = rule.name
  end
  local accepted = table.concat(names, ", ")

  local function validateValue(rule, value, level)
    local where = "CommandKit:SetLimits limits." .. rule.name
    if isSecret(value) then
      error(where .. " must not be a secret value", level)
    end
    if value == UNBOUNDED and UNBOUNDED ~= nil then
      if rule.unbounded then
        return
      end
      local reason = rule.unboundedReason and (": " .. rule.unboundedReason) or ""
      error(where .. " cannot be CommandKit.UNBOUNDED" .. reason, level)
    end
    local minimum = rule.minimum or 1
    local integer = rule.integer ~= false
    if
      type(value) ~= "number"
      or value ~= value
      or value < minimum
      or value > rule.ceiling
      or (integer and value % 1 ~= 0)
    then
      local kind = integer and "an integer" or "a number"
      local range = " from " .. minimum .. " to " .. rule.ceiling
      error(where .. " must be " .. kind .. range, level)
    end
    if rule.check then
      rule.check(value, level + 1)
    end
  end

  validateLimitUpdate = function(limits, level)
    if isSecret(limits) or type(limits) ~= "table" then
      error("CommandKit:SetLimits limits must be a table", level)
    end
    local key = next(limits)
    while type(key) ~= "nil" do
      local rule = type(key) == "string" and rulesByName[key] or nil
      if rule == nil then
        local named = "CommandKit:SetLimits limits." .. describeKey(key)
        error(named .. " is not a recognised limit; it accepts " .. accepted, level)
      end
      validateValue(rule, rawget(limits, key), level + 1)
      key = next(limits, key)
    end
  end

  applyLimitUpdate = function(target, limits)
    for index = 1, #LIMIT_RULES do
      local name = LIMIT_RULES[index].name
      local value = rawget(limits, name)
      if type(value) ~= "nil" then
        rawset(target, name, value)
      end
    end
  end

  copyLimits = function(source)
    local copy = {}
    for index = 1, #LIMIT_RULES do
      local name = LIMIT_RULES[index].name
      copy[name] = rawget(source, name)
    end
    return copy
  end
end
-- shared:end limits

---Change any subset of the package-wide limits. They are shared by every
---consumer in the session; lowering one never drops what is already kept.
---@param self CommandKit
---@param limits CommandKit.Limits
local function setLimits(self, limits)
  validateFacade(self, "CommandKit:SetLimits", 3)
  validateLimitUpdate(limits, 3)
  applyLimitUpdate(sharedLimits, limits)
end

---Return a fresh copy of the package-wide limits. Allocates one table.
---@param self CommandKit
---@return CommandKit.Limits
local function getLimits(self)
  validateFacade(self, "CommandKit:GetLimits", 3)
  return copyLimits(sharedLimits)
end

-- Commit ---------------------------------------------------------------------

rawset(Scope, "Register", scopeRegister)
rawset(Scope, "Unregister", scopeUnregister)
rawset(Scope, "IsRegistered", scopeIsRegistered)
rawset(Scope, "SetSink", scopeSetSink)
rawset(Scope, "GetCommands", scopeExtras.GetCommands)
rawset(Scope, "SetPrefix", scopeExtras.SetPrefix)
rawset(Scope, "GetPrefix", scopeExtras.GetPrefix)
rawset(Scope, "Print", scopeExtras.Print)
rawset(Scope, "Printf", scopeExtras.Printf)
rawset(Scope, "Dispatch", scopeExtras.Dispatch)
rawset(Scope, "Reopen", scopeExtras.Reopen)
scopeExtras.installPartMethods()
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
rawset(CommandKit, "GetCommands", scopeExtras.GetAllCommands)

-- The revision-11 hand-over (see "Arguments"). Captured before this
-- revision replaces the dispatcher: the older core's `registerCommand` (from
-- its helpers) and slash dispatcher still compile and run commands with
-- arguments while the Arguments part is absent. Every command an older
-- revision registered with arguments anywhere in its tree is listed, so
-- `slashDispatch` hands its lines to the older dispatcher.
if
  type(previousRevision) == "number"
  and previousRevision <= LAST_CORE_ARGUMENTS_REVISION
  and rawget(rawget(state, "parts"), "Arguments") == nil
  and state.legacyArguments == nil
  and type(rawget(dispatch, "slash")) == "function"
then
  local legacyRecords = setmetatable({}, { __mode = "k" })
  local legacyRegister = rawget(rawget(state, "helpers"), "registerCommand")
  if type(legacyRegister) ~= "function" then
    legacyRegister = function(_, _, _, methodName, level)
      error(
        methodName
          .. " spec.arguments needs CommandKit's Arguments part, which is not loaded: add commandKit\\parts\\CommandKit-Arguments.lua to your embeds.xml",
        level
      )
    end
  end
  -- Whether `spec` or a sub-command below it declares `arguments`. Reads raw
  -- fields and stops at `MAX_DEPTH`; a malformed spec answers `false` and is
  -- refused by the normal compile. Kept in the hand-over rather than as a
  -- file-level function, so a session without one keeps no code for it.
  local function declaresArguments(spec, depth)
    if type(spec) ~= "table" or depth > MAX_DEPTH then
      return false
    end
    if type(rawget(spec, "arguments")) ~= "nil" then
      return true
    end
    local subcommands = rawget(spec, "subcommands")
    if type(subcommands) ~= "table" then
      return false
    end
    for _, child in next, subcommands do
      if declaresArguments(child, depth + 1) then
        return true
      end
    end
    return false
  end
  local function hasArguments(record)
    if record._mode ~= "none" then
      return true
    end
    local names = record._subcommandNames
    for index = 1, #names do
      if hasArguments(record._subcommands[names[index]]) then
        return true
      end
    end
    return false
  end
  for _, record in next, activeByName do
    if hasArguments(record) then
      legacyRecords[record] = true
    end
  end
  state.legacyArguments = {
    registerCommand = legacyRegister,
    declaresArguments = declaresArguments,
    slash = rawget(dispatch, "slash"),
    records = legacyRecords,
  }
end
rawset(dispatch, "slash", slashDispatch)
rawset(dispatch, "closeAddonScopesAtLogout", LogoutClose.closeAtLogout)

-- What the parts call, read through this table at call time, so a newer core
-- serves parts loaded before it. The table itself is kept across revisions.
local helpers = rawget(state, "helpers")
helpers.isSecret = isSecret
helpers.findOptional = findOptional
helpers.reportError = reportError
helpers.readMetatable = readMetatable
helpers.validateScope = validateScope
helpers.ensureOpen = ensureOpen
helpers.validateString = validateString
helpers.validateOptionalString = validateOptionalString
helpers.refuseUnknownFields = refuseUnknownFields
helpers.tokenize = tokenize
helpers.writeLine = writeLine
helpers.registerCommand = registerCommand
helpers.acquireFrame = acquireFrame
helpers.releaseFrame = releaseFrame
helpers.openContext = openContext
helpers.walkSubcommands = walkSubcommands
helpers.contextPrint = contextPrint
helpers.contextUsage = contextUsage
helpers.contextFail = contextFail
helpers.contextGetCommandPath = contextGetCommandPath
helpers.installPartMethods = scopeExtras.installPartMethods
helpers.failWithUsage = failWithUsage
rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(CommandKit) or not validateCurrentState(CommandKit) then
  error("MoltenCodes CommandKit package state is corrupted or incomplete", 2)
end

-- Arrange the logout close of every open addon scope an upgrade inherited, in
-- addon-name order: an older revision never arranged it, and the addon may
-- never call `ForAddon` again. Written in the main chunk rather than as a
-- function of `LogoutClose`, so it is freed after load (revision 12).
if previousRevision ~= nil then
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

return CommandKit
