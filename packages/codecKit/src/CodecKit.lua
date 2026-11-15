-- MoltenCodes CodecKit
--
-- Turns Lua values into transport-safe strings and back in three composable
-- stages behind a two-byte, self-describing header:
--
--   serialise        a type byte and a payload per value: varint integers,
--                    exact IEEE-754 doubles, length-prefixed raw strings, and
--                    tables in array, map or mixed layout. Cycles are refused.
--   compress         raw DEFLATE (RFC 1951), in the optional Compression
--                    part (`parts/CodecKit-Compression.lua`): the client's
--                    `C_EncodingUtil.CompressString` where it exists, else
--                    pure Lua; inflating is always the part's Lua inflater.
--   channel-encode   `addon` escapes the four bytes the addon channel cannot
--                    carry and the escape byte itself; `print` maps
--                    everything onto 85 printable ASCII characters for chat
--                    and export strings.
--
-- Decoding never raises on malformed input: every failure is `false, reason`
-- with a reason from a fixed vocabulary. Depth, value count, string length and
-- every stage's output size are bounded by limits shared by every consumer.
--
-- CodecKit needs Registry API 2 and PoolKit API 1 (the compression and print
-- stages lease their sinks from a table pool and return them on every path,
-- so calls are re-entrant). The
-- asynchronous variants find SchedulerKit API 1 through `Registry:Find` when
-- they are called; without it they raise at the caller.
--
-- This file is the core (ADR 0001, docs/decisions/0001-kit-core-and-parts.md).
-- The Compression part loads after it and fills `_state.compression`; the
-- core publishes what a part may call in `_state.helpers`, the parts loaded
-- in `_state.parts`, and the interface generation in `_state.partInterface`.
-- Without the part, every method that compresses raises at the caller with
-- the file to embed, and a compressed frame decodes to
-- `false, "compressionUnavailable"`.
--
-- `docs/API.md` specifies the wire format byte by byte; `docs/INTERNALS.md`
-- describes the compressor and the buffers.
--
-- Contents
-- --------
--   Constants ............. identity, header flags, type bytes, reasons, limits
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, PoolKit and the host facilities read
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Work and buffers ...... per-call work records, leased tables, byte sinks
--   Serialiser ............ numbers, the value writer and the value reader
--   Compression stage ..... the two entries the Compression part fills
--   Addon channel ......... the escape table
--   Print channel ......... the 85-character alphabet
--   Frames ................ the header and the composition of the stages
--   Argument checks ....... receivers, options, limits, secret values,
--                           the missing-part refusal
--   Package public API .... the facade published through Registry
--   Commit ................ facade assignment, part helpers and self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "codecKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 10
local REQUIRED_REGISTRY_API = 2
local REQUIRED_POOLKIT_API = 1
local OPTIONAL_SCHEDULERKIT_API = 1
local STATE_SCHEMA = 1
-- The generation of what the core offers its parts: the `_state.helpers`
-- entries and the `_state.compression` layout. Entries are only ever added;
-- a core that must change one adds a new entry and raises this number.
local PART_INTERFACE = 1
-- What a member of a part that is not loaded tells the caller to embed.
local PART_FILES = {
  Compression = "codecKit\\parts\\CodecKit-Compression.lua",
}

-- The first byte of every frame. A decoder refuses any other value with
-- `"unsupportedVersion"`, so a future incompatible format is a new number
-- rather than a silent misparse.
local FORMAT_VERSION = 1

-- The second byte of every frame is a set of stage flags. Bit 0 is always set
-- in version 1, which also keeps the byte away from zero; bits 4 to 7 are
-- reserved and must be zero.
local FLAG_SERIALIZED = 1
local FLAG_DEFLATE = 2
local FLAG_ADDON = 4
local FLAG_PRINT = 8
local FLAG_RESERVED_FLOOR = 16

-- Serialised type bytes. Every value starts with exactly one of these.
local TYPE_NIL = 1
local TYPE_FALSE = 2
local TYPE_TRUE = 3
local TYPE_POSITIVE_INTEGER = 4
local TYPE_NEGATIVE_INTEGER = 5
local TYPE_FLOAT = 6
local TYPE_STRING = 7
local TYPE_ARRAY = 8
local TYPE_MAP = 9
local TYPE_MIXED = 10
local TYPE_LIST = 11

-- The fixed failure vocabulary. `docs/API.md` lists what each one means.
local REASON = {
  cycle = "cycle",
  unsupportedType = "unsupportedType",
  maxDepth = "maxDepth",
  maxValues = "maxValues",
  maxStringLength = "maxStringLength",
  maxOutputBytes = "maxOutputBytes",
  truncated = "truncated",
  trailingData = "trailingData",
  unsupportedVersion = "unsupportedVersion",
  malformedHeader = "malformedHeader",
  channelMismatch = "channelMismatch",
  forbiddenByte = "forbiddenByte",
  malformedEscape = "malformedEscape",
  malformedPrint = "malformedPrint",
  malformedDeflate = "malformedDeflate",
  unknownType = "unknownType",
  malformedNumber = "malformedNumber",
  invalidKey = "invalidKey",
  duplicateKey = "duplicateKey",
  nilValue = "nilValue",
  multipleValues = "multipleValues",
  -- A compressed frame reached a session whose CodecKit has no Compression
  -- part. Peer data never raises, so decoding reports it.
  compressionUnavailable = "compressionUnavailable",
}

-- Internal marker for a secret found while serialising. It never reaches a
-- caller as a reason: the public method raises at the caller's line instead.
local SECRET_FOUND = {}

-- Limits every consumer in the session shares. Each is bounded by default and
-- has a ceiling `SetLimits` refuses to pass, so no setting makes a hostile
-- input unbounded.
local LIMIT_NAMES =
  { "maxDepth", "maxValues", "maxStringLength", "maxOutputBytes", "maxListValues" }
local DEFAULT_LIMITS = {
  maxDepth = 16,
  maxValues = 65536,
  maxStringLength = 65536,
  maxOutputBytes = 1048576,
  -- The most entries an argument list may hold on either side.
  maxListValues = 4096,
}
local LIMIT_CEILINGS = {
  -- The reader and writer recurse twice per nesting level. A bare Lua 5.1.5
  -- interpreter overflows its call stack near 9995 levels; 128 leaves the
  -- rest to the consumer's own call depth.
  maxDepth = 128,
  maxValues = 16777216,
  maxStringLength = 1073741824,
  -- 64 MiB. Inflating keeps one array slot (16 bytes) per output byte, so a
  -- higher ceiling would let one frame demand more than a gigabyte.
  maxOutputBytes = 67108864,
  -- `DecodeMany` returns the entries with `unpack`, which Lua 5.1 refuses
  -- past 7997 results (the 8000-slot C stack limit less its three arguments,
  -- measured); 7900 keeps a margin for hosts built with a smaller stack.
  -- `EncodeMany` refuses the same count, so everything it writes reads back.
  maxListValues = 7900,
}

-- The limits `CodecKit.UNBOUNDED` may lift, because each is already bounded
-- by `maxOutputBytes`: every value takes at least one byte and every string
-- is part of the bytes, and every decoding stage refuses input larger than
-- `maxOutputBytes`. The others must stay numbers, and this is why.
local UNBOUNDED_ALLOWED = { maxValues = true, maxStringLength = true }
local BOUNDED_REASONS = {
  maxDepth = "the reader and writer recurse on the Lua call stack",
  maxOutputBytes = "it bounds the memory every stage and a DEFLATE bomb may claim",
  maxListValues = "DecodeMany returns the entries through unpack, which Lua 5.1 bounds",
}

-- The largest magnitude every integer up to which is exactly representable in
-- a double. Integral numbers within it are written as varints; everything else
-- as an IEEE-754 double.
local MAX_SAFE_INTEGER = 9007199254740992

-- Option values, validated against these sets.
local COMPRESSIONS = { none = true, deflate = true }
local CHANNELS = { none = true, addon = true, print = true }
local ENCODE_OPTION_KEYS = { compress = true, channel = true, level = true }
local COMPRESS_OPTION_KEYS = { level = true }
local DECODE_OPTION_KEYS = { channel = true }
local DEFAULT_LEVEL = 6

-- How many tables the package keeps for reuse between calls. A call leases at
-- most three at a time (a sink, its batch, and its chunk array or the bit
-- writer of a short compression input), so sixteen covers nested and
-- interleaved calls without keeping memory nobody uses.
local POOL_MAX_RETAINED = 16

-- Byte sinks hold pending bytes as numbers and fragments as strings. Both
-- flush at this size: `string.char(unpack(...))` stays far below the Lua 5.1
-- C-stack limit, and a retained fragment array stays small.
local SINK_BATCH_SIZE = 1024
local SINK_FRAGMENT_SIZE = 1024

-- The serialiser's fragment buffer folds into one chunk string at this many
-- fragments. A fragment is usually one byte, so a larger fold means fewer
-- intermediate chunk strings for a large payload; the reused buffer keeps
-- this many slots (64 KiB) between calls, less than the sixteen full 1024-slot
-- tables revision 4 could leave in the pool.
local WRITER_FOLD_SIZE = 4096

-- How often the asynchronous variants ask `context:ShouldYield()`: every this
-- many serialised values or print groups. The compressor and the inflater
-- keep their own two intervals inside the DEFLATE scope.
local PAUSE_VALUES = 256
local PAUSE_GROUPS = 2048

-- The published surface, listed once so the public-surface predicate reads as
-- a checklist.
local FACADE_METHODS = {
  "Encode",
  "Decode",
  "EncodeMany",
  "DecodeMany",
  "Serialize",
  "Deserialize",
  "Compress",
  "Decompress",
  "EncodeForAddon",
  "DecodeForAddon",
  "EncodeForPrint",
  "DecodeForPrint",
  "EncodeAsync",
  "DecodeAsync",
  "SetLimits",
  "GetLimits",
  "HasPart",
}

-- Public types ---------------------------------------------------------------

---Why a call returned `false`. See `docs/API.md` for each reason.
---@alias CodecKit.Reason "cycle"|"unsupportedType"|"maxDepth"|"maxValues"|"maxStringLength"|"maxOutputBytes"|"truncated"|"trailingData"|"unsupportedVersion"|"malformedHeader"|"channelMismatch"|"forbiddenByte"|"malformedEscape"|"malformedPrint"|"malformedDeflate"|"unknownType"|"malformedNumber"|"invalidKey"|"duplicateKey"|"nilValue"|"multipleValues"|"compressionUnavailable"|"secret"

---Options accepted by `Encode`, `EncodeMany` and `EncodeAsync`.
---@class CodecKit.EncodeOptions
---@field compress ("none"|"deflate")? Compression stage; default `"none"`.
---@field channel ("none"|"addon"|"print")? Channel encoding; default `"none"`.
---@field level integer? DEFLATE level from 1 (fastest) to 9 (smallest); default 6.

---Options accepted by `Decode`, `DecodeMany` and `DecodeAsync`.
---@class CodecKit.DecodeOptions
---@field channel ("none"|"addon"|"print")? Refuse a frame encoded for another channel.

---Options accepted by `Compress`.
---@class CodecKit.CompressOptions
---@field level integer? DEFLATE level from 1 to 9; default 6.

---The shared limits. `SetLimits` accepts any subset; `GetLimits` returns all
---five in a fresh table, `CodecKit.UNBOUNDED` where a limit was lifted.
---@class CodecKit.Limits
---@field maxDepth integer Deepest table nesting; default 16, at most 128.
---@field maxValues integer|table Most values (keys included) in one payload; default 65536, at most 16777216, or `CodecKit.UNBOUNDED`.
---@field maxStringLength integer|table Longest single string; default 65536, at most 2^30, or `CodecKit.UNBOUNDED`.
---@field maxOutputBytes integer Largest output of any stage; default 1048576, at most 2^26.
---@field maxListValues integer Most entries in an `EncodeMany`/`DecodeMany` argument list; default 4096, at most 7900.

---The CodecKit package facade published through Registry.
---@class CodecKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field FORMAT_VERSION integer The frame version this copy writes and reads.
---@field PRINT_ALPHABET string The 85 characters of the print channel, digit 0 first.
---@field UNBOUNDED table Sentinel `SetLimits` accepts for `maxValues` and `maxStringLength`; one table shared by every revision.
---@field Encode fun(self: CodecKit, value: any, options: CodecKit.EncodeOptions?): boolean, string
---@field Decode fun(self: CodecKit, text: string, options: CodecKit.DecodeOptions?): boolean, any
---@field EncodeMany fun(self: CodecKit, options: CodecKit.EncodeOptions?, ...: any): boolean, string
---@field DecodeMany fun(self: CodecKit, text: string, options: CodecKit.DecodeOptions?): boolean, ...
---@field Serialize fun(self: CodecKit, value: any): boolean, string
---@field Deserialize fun(self: CodecKit, bytes: string): boolean, any
---@field Compress fun(self: CodecKit, bytes: string, options: CodecKit.CompressOptions?): boolean, string
---@field Decompress fun(self: CodecKit, bytes: string): boolean, string
---@field EncodeForAddon fun(self: CodecKit, bytes: string): boolean, string
---@field DecodeForAddon fun(self: CodecKit, text: string): boolean, string
---@field EncodeForPrint fun(self: CodecKit, bytes: string): boolean, string
---@field DecodeForPrint fun(self: CodecKit, text: string): boolean, string
---@field EncodeAsync fun(self: CodecKit, value: any, options: CodecKit.EncodeOptions?, scope: table, callback: fun(ok: boolean, result: string)): table
---@field DecodeAsync fun(self: CodecKit, text: string, options: CodecKit.DecodeOptions?, scope: table, callback: fun(ok: boolean, result: any)): table
---@field SetLimits fun(self: CodecKit, limits: CodecKit.Limits)
---@field GetLimits fun(self: CodecKit): CodecKit.Limits
---@field HasPart fun(self: CodecKit, name: string): boolean Whether the named part (`"Compression"`) is loaded.

-- Dependencies ---------------------------------------------------------------

local byte = string.byte
local char = string.char
local sub = string.sub
local find = string.find
local gsub = string.gsub
local concat = table.concat
local floor = math.floor
local frexp = math.frexp
local ldexp = math.ldexp
local HUGE = math.huge
-- Standard functions the per-value paths call, read once: a global read is a
-- hash lookup in `_G` on every call, a local is not.
local type = type
local next = next
local rawget = rawget
local rawequal = rawequal

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
  error("MoltenCodes CodecKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local getPackage = rawget(Registry, "Get")
if type(bootstrapPackage) ~= "function" or type(getPackage) ~= "function" then
  error("MoltenCodes CodecKit requires a valid Registry API 2 facade", 2)
end

-- PoolKit leases the fragment arrays and work records every call uses.
local PoolKit = getPackage(Registry, "poolKit", REQUIRED_POOLKIT_API)
if
  type(PoolKit) ~= "table"
  or rawget(PoolKit, "API") ~= REQUIRED_POOLKIT_API
  or type(rawget(PoolKit, "NewTablePool")) ~= "function"
then
  error("MoltenCodes CodecKit requires PoolKit API 1 to be loaded first", 2)
end

-- The client defines `issecretvalue` before any addon loads, so it is resolved
-- once, here. When it is absent at load, `readSecretProbe` looks the global up
-- on every call instead, so a probe installed later is still honoured.
-- issecretvalue is a World of Warcraft client API reachable only through the global table.
-- selene: allow(global_usage)
local loadedSecretProbe = rawget(_G, "issecretvalue")
if type(loadedSecretProbe) ~= "function" then
  loadedSecretProbe = nil
end

---Return the host's `issecretvalue`, or `nil` on a client without secret
---values: the probe resolved at load, else the global's current value.
---@return (fun(value: any): boolean)|nil
local function readSecretProbe()
  if loadedSecretProbe ~= nil then
    return loadedSecretProbe
  end
  -- issecretvalue is a World of Warcraft client API reachable only through the global table.
  -- selene: allow(global_usage)
  local probe = rawget(_G, "issecretvalue")
  if type(probe) == "function" then
    return probe
  end
  return nil
end

-- Validation -----------------------------------------------------------------

---Whether `implementation` exposes the complete CodecKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
  if
    type(implementation) ~= "table"
    or rawget(implementation, "API") ~= API_GENERATION
    or type(rawget(implementation, "REVISION")) ~= "number"
    or rawget(implementation, "FORMAT_VERSION") ~= FORMAT_VERSION
    or type(rawget(implementation, "PRINT_ALPHABET")) ~= "string"
    or type(rawget(implementation, "UNBOUNDED")) ~= "table"
  then
    return false
  end
  for index = 1, #FACADE_METHODS do
    if type(rawget(implementation, FACADE_METHODS[index])) ~= "function" then
      return false
    end
  end
  return true
end

---Whether `limits` holds every limit as a positive integer, or as the
---`unbounded` sentinel where that limit may be lifted.
---@param limits any
---@param unbounded any the sentinel the package state keeps
---@return boolean
local function validateLimits(limits, unbounded)
  if type(limits) ~= "table" then
    return false
  end
  for index = 1, #LIMIT_NAMES do
    local name = LIMIT_NAMES[index]
    local value = rawget(limits, name)
    local lifted = UNBOUNDED_ALLOWED[name] == true and value == unbounded
    if not lifted and (type(value) ~= "number" or value < 1 or value % 1 ~= 0) then
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
    and type(rawget(currentState, "runtimeRevision")) == "number"
    and type(rawget(currentState, "unbounded")) == "table"
    and validateLimits(rawget(currentState, "limits"), rawget(currentState, "unbounded"))
    and type(rawget(currentState, "pool")) == "table"
end

---Whether `currentState` carries the part interface of this revision: the
---parts installed, the helpers a part reads and the two compression entries,
---each `false` or a function.
---@param currentState table
---@return boolean
local function validatePartState(currentState)
  local partInterface = rawget(currentState, "partInterface")
  local compression = rawget(currentState, "compression")
  if
    type(partInterface) ~= "number"
    or partInterface < PART_INTERFACE
    or type(rawget(currentState, "parts")) ~= "table"
    or type(rawget(currentState, "helpers")) ~= "table"
    or type(compression) ~= "table"
  then
    return false
  end
  local compress, decompress = rawget(compression, "compress"), rawget(compression, "decompress")
  return (compress == false or type(compress) == "function")
    and (decompress == false or type(decompress) == "function")
end

---Whether `implementation` carries package state of this revision's schema,
---and publishes the sentinel that state keeps.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
  local currentState = rawget(implementation, "_state")
  return validateStateBase(currentState)
    and validatePartState(currentState)
    and rawget(implementation, "UNBOUNDED") == rawget(currentState, "unbounded")
end

-- Bootstrap ------------------------------------------------------------------

-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. What stays here is what only CodecKit can answer.
local CodecKit, previousRevision, selected = bootstrapPackage(Registry, {
  package = PACKAGE_NAME,
  api = API_GENERATION,
  revision = IMPLEMENTATION_REVISION,
  label = "MoltenCodes CodecKit",
  validatePublicSurface = validatePublicSurface,
  validateState = validateCurrentState,
})

if CodecKit == nil then
  -- An equal or newer compatible revision already owns the shared package table.
  return selected
end

local state = rawget(CodecKit, "_state")

if previousRevision == nil then
  if state ~= nil then
    error("MoltenCodes CodecKit package state is corrupted or incomplete", 2)
  end

  state = {
    schema = STATE_SCHEMA,
    runtimeRevision = 0,
    -- The shared limits; `SetLimits` writes here and every call copies
    -- them into its work record when it starts.
    limits = {
      maxDepth = DEFAULT_LIMITS.maxDepth,
      maxValues = DEFAULT_LIMITS.maxValues,
      maxStringLength = DEFAULT_LIMITS.maxStringLength,
      maxOutputBytes = DEFAULT_LIMITS.maxOutputBytes,
      maxListValues = DEFAULT_LIMITS.maxListValues,
    },
    -- `CodecKit.UNBOUNDED` lives here so every revision publishes the same
    -- table and a limit lifted through one copy stays lifted after an
    -- upgrade.
    unbounded = {},
    -- One table pool for every embedded copy. It keeps the tables a call
    -- leases; the pool's shallow reset clears them on release.
    pool = PoolKit:NewTablePool({ maxRetained = POOL_MAX_RETAINED }),
  }
  rawset(CodecKit, "_state", state)
elseif not validateStateBase(state) then
  error("MoltenCodes CodecKit package state is corrupted or incomplete", 2)
end

-- The part interface (ADR 0001). Revisions up to 9 held the
-- compression stage in this file and have none of it, so it is created
-- here for them. A newer core keeps what its parts filled: `parts` and
-- `compression` survive, `helpers` is refilled at the commit below.
if type(rawget(state, "parts")) ~= "table" then
  rawset(state, "parts", {})
end
if type(rawget(state, "helpers")) ~= "table" then
  rawset(state, "helpers", {})
end
if type(rawget(state, "compression")) ~= "table" then
  -- A whole revision's compression code is not reachable from here, and
  -- nothing it made outlives a call: its tables were file-local, and an
  -- asynchronous call it scheduled runs its own code to the end. So a session
  -- without the Compression part simply has none.
  rawset(state, "compression", { compress = false, decompress = false })
end
local partInterface = rawget(state, "partInterface")
if type(partInterface) ~= "number" or partInterface < PART_INTERFACE then
  rawset(state, "partInterface", PART_INTERFACE)
end

local sharedLimits = rawget(state, "limits")
local tablePool = rawget(state, "pool")
local UNBOUNDED = rawget(state, "unbounded")
local compression = rawget(state, "compression")

-- Work and buffers -----------------------------------------------------------
--
-- Every call opens one work record: the limits it runs under, the secret
-- probe, counters, and whether its tables come from the pool. The record
-- carries the serialiser's writer and cycle set with it.
--
-- A synchronous call takes the file's one idle work record, built once and
-- reused, so serialising and deserialising lease nothing: a PoolKit
-- `Acquire` and `Release` pair costs about as much as serialising a small
-- value, and those two stages run for every addon message. A call that finds
-- the idle record taken builds a fresh one; that only happens for a call
-- nested inside another (no user code runs inside a synchronous call, so
-- only a host probe could nest one) or after a call that raised before giving
-- its record back. Whichever record is given back while none is idle becomes
-- the idle one. The compression and print stages lease their sinks from the
-- shared pool and return each one on every path.
--
-- Asynchronous calls use plain tables throughout, because a job cancelled
-- while it is suspended is never resumed, and a leased table it held would
-- stay in the pool's active set for the rest of the session.

---Lease an empty table: from the pool for a synchronous call, fresh otherwise.
---@param pooled boolean
---@return table
local function leaseTable(pooled)
  if pooled then
    return tablePool:Acquire()
  end
  return {}
end

---Return a leased table to the pool; a no-op for an asynchronous call.
---@param pooled boolean
---@param borrowed table
local function returnTable(pooled, borrowed)
  if pooled then
    tablePool:Release(borrowed)
  end
end

---Build a work record with every field it will hold, so reusing it never
---rehashes it. `writer` is the serialiser's fragment buffer (see "Writer"),
---`visited` the tables open on the serialiser's current path, by depth.
---@return table work
local function newWork()
  return {
    pooled = false,
    context = false,
    isSecret = false,
    maxDepth = 0,
    maxValues = 0,
    maxStringLength = 0,
    maxOutputBytes = 0,
    maxListValues = 0,
    valueCount = 0,
    textLength = 0,
    visited = {},
    writer = {
      count = 0,
      size = 0,
      chunks = {},
      chunkCount = 0,
      textSlots = {},
      textCount = 0,
      byteText = false,
      escapeStrings = false,
    },
  }
end

-- The idle work record of synchronous calls, or `false` while a call holds it.
---@type table|false
local idleWork = newWork()

---Open the work record of one call, copying the shared limits so a
---`SetLimits` during an asynchronous job does not change it mid-way.
---@param pooled boolean `true` for a synchronous call
---@return table work
local function openWork(pooled, probe)
  local work = pooled and idleWork or false
  if work then
    idleWork = false
  else
    work = newWork()
  end
  work.pooled = pooled
  work.context = false
  -- A caller that already read the probe for its options passes it (`false`
  -- for none), so one call reads it once.
  if probe == nil then
    probe = readSecretProbe() or false
  end
  work.isSecret = probe
  -- The limits table is the package's own and has no metatable, so indexing
  -- it is a raw read. Only `maxValues` and `maxStringLength` may hold the
  -- `UNBOUNDED` sentinel; `SetLimits` refuses it for the other three.
  local limits = sharedLimits
  local maxValues, maxStringLength = limits.maxValues, limits.maxStringLength
  work.maxDepth = limits.maxDepth
  work.maxValues = maxValues == UNBOUNDED and HUGE or maxValues
  work.maxStringLength = maxStringLength == UNBOUNDED and HUGE or maxStringLength
  work.maxOutputBytes = limits.maxOutputBytes
  work.maxListValues = limits.maxListValues
  work.valueCount = 0
  work.textLength = 0
  return work
end

---Close a work record. A synchronous call's record becomes the idle one
---again when none is idle; it holds nothing of the call by then: the writer
---clears itself when it finishes or is abandoned, and the open-table stack
---is emptied here because a refused value leaves its open tables in it.
---@param work table
local function closeWork(work)
  local open = work.visited
  for depth = 1, #open do
    open[depth] = nil
  end
  if work.pooled and not idleWork then
    idleWork = work
  end
end

---Give the frame back to the scheduler when an asynchronous call has used its
---budget. Never called from inside `pcall` or a C function, so the yield
---cannot cross a C-call boundary.
---@param work table
local function pause(work)
  local context = work.context
  if context and context:ShouldYield() then
    context:Yield()
  end
end

-- A sink collects one stage's output. Bytes accumulate as numbers in `batch`
-- and become one string per `SINK_BATCH_SIZE`; strings accumulate in the
-- sink's own array part and fold into one chunk per `SINK_FRAGMENT_SIZE`, so
-- no leased array grows past that size however large the output is.

---@param pooled boolean
---@return table sink
local function openSink(pooled)
  local sink = leaseTable(pooled)
  sink.pooled = pooled
  sink.batch = leaseTable(pooled)
  sink.batchCount = 0
  sink.count = 0
  sink.chunks = false
  sink.chunkCount = 0
  return sink
end

---Return every table a sink leased.
---@param sink table
local function closeSink(sink)
  local pooled = sink.pooled
  local chunks = sink.chunks
  if chunks then
    returnTable(pooled, chunks)
  end
  returnTable(pooled, sink.batch)
  returnTable(pooled, sink)
end

---Append one string fragment, folding full fragment arrays into a chunk.
---@param sink table
---@param fragment string
local function appendFragment(sink, fragment)
  local count = sink.count + 1
  sink[count] = fragment
  if count < SINK_FRAGMENT_SIZE then
    sink.count = count
    return
  end
  local chunks = sink.chunks
  if not chunks then
    chunks = leaseTable(sink.pooled)
    sink.chunks = chunks
  end
  local chunkCount = sink.chunkCount + 1
  chunks[chunkCount] = concat(sink, "", 1, count)
  sink.chunkCount = chunkCount
  sink.count = 0
end

---Turn the pending bytes into one fragment.
---@param sink table
local function flushBatch(sink)
  local count = sink.batchCount
  if count > 0 then
    sink.batchCount = 0
    appendFragment(sink, char(unpack(sink.batch, 1, count)))
  end
end

---@param sink table
---@param value integer 0 to 255
local function putByte(sink, value)
  local count = sink.batchCount + 1
  sink.batch[count] = value
  sink.batchCount = count
  if count == SINK_BATCH_SIZE then
    flushBatch(sink)
  end
end

---@param sink table
---@param text string
local function putString(sink, text)
  flushBatch(sink)
  appendFragment(sink, text)
end

---Close the sink and return everything written as one string.
---@param sink table
---@return string
local function finishSink(sink)
  flushBatch(sink)
  local result
  local chunks = sink.chunks
  if chunks then
    local chunkCount = sink.chunkCount
    if sink.count > 0 then
      chunkCount = chunkCount + 1
      chunks[chunkCount] = concat(sink, "", 1, sink.count)
    end
    result = concat(chunks, "", 1, chunkCount)
  else
    result = concat(sink, "", 1, sink.count)
  end
  closeSink(sink)
  return result
end

-- The addon channel's escapes (see "Addon channel" below), defined here
-- because the serialiser's writer applies them as it writes.
local ADDON_ESCAPE_BYTE = 255
local ADDON_ESCAPES = {
  [char(0)] = char(ADDON_ESCAPE_BYTE, 48), -- "0"
  [char(10)] = char(ADDON_ESCAPE_BYTE, 49), -- "1"
  [char(13)] = char(ADDON_ESCAPE_BYTE, 50), -- "2"
  [char(124)] = char(ADDON_ESCAPE_BYTE, 51), -- "3"
  [char(255)] = char(ADDON_ESCAPE_BYTE, 52), -- "4"
}
local ADDON_UNESCAPES = {}
for raw, escaped in pairs(ADDON_ESCAPES) do
  ADDON_UNESCAPES[escaped] = raw
end
local ADDON_ESCAPE_PATTERN = "[%z\n\r|\255]"

---Whether `text` holds, from byte `start` on, a byte the addon channel cannot
---carry (NUL, LF, CR or `|`). Four plain finds: Lua 5.1 tries a character
---class such as `"[%z\n\r|]"` at every start position, which costs about a
---hundred times as much on a 20 KB frame.
---@param text string
---@param start integer
---@return boolean
local function holdsForbiddenByte(text, start)
  return find(text, "\0", start, true) ~= nil
    or find(text, "\n", start, true) ~= nil
    or find(text, "\r", start, true) ~= nil
    or find(text, "|", start, true) ~= nil
end

---Whether `text` holds, from byte `start` on, a byte the addon channel
---escapes: a forbidden byte or the escape byte itself.
---@param text string
---@param start integer
---@return boolean
local function holdsEscapeByte(text, start)
  return holdsForbiddenByte(text, start) or find(text, "\255", start, true) ~= nil
end

-- Short strings already known to need no addon-channel escape. Whether a
-- string needs escaping depends only on its bytes, and a payload repeats its
-- keys and many values, so one hash lookup replaces the scan for them. Bounded:
-- at most `CLEAN_TEXT_LIMIT` strings of at most `CLEAN_TEXT_MAX_LENGTH` bytes,
-- recorded once and never wiped (a version that emptied itself when full
-- thrashed on large payloads). It holds up to about 14 KB of strings for the
-- session; strings are never collected from weak tables in Lua 5.1, so the
-- size cap is the bound. A secret never reaches it: `writeValue` asks first.
local CLEAN_TEXT_LIMIT = 256
local CLEAN_TEXT_MAX_LENGTH = 32
local cleanText = {}
local cleanTextCount = 0
local ADDON_BAD_ESCAPE_PATTERN = "\255[^0-4]"
local ADDON_SEQUENCE_PATTERN = "\255[0-4]"

-- Writer ---------------------------------------------------------------------
--
-- The serialiser writes into its own buffer, `work.writer`, rather than a
-- byte sink: every byte becomes a one-character string looked up in a table
-- built at load (Lua interns short strings, so the lookup allocates nothing),
-- every string value becomes one fragment, and the finished buffer is joined
-- with one `table.concat`. The header of the frame can be its first fragment,
-- so the output of `Encode` is the only string built.
--
-- For the addon channel without compression, the writer also applies the
-- channel's escapes as it goes: a byte is looked up in a table that maps the
-- five escaped bytes to their two-byte sequences, and a string value that
-- contains one of them is escaped with one `gsub`. Escaping is a map of
-- single bytes, so escaping every fragment gives exactly the bytes escaping
-- the joined body would; the output is byte-identical to escaping afterwards,
-- without building the unescaped body at all.
--
-- `size` counts the serialised bytes, before escaping, because
-- `maxOutputBytes` bounds the serialised stage by itself; the escaped frame is
-- measured once it is joined.
--
-- `writeValue` appends to the buffer inline, reading and writing its count
-- and size once per value, and the buffer is folded into a chunk at the end of a value
-- when it has reached `WRITER_FOLD_SIZE` fragments. Between two such checks
-- the writer appends at most a scalar (ten fragments: a string's type byte,
-- an eight-byte length and its text) plus nine per table header it opens on
-- the way down, so the buffer stays within a few hundred slots of the fold
-- size even at the deepest nesting `maxDepth` allows.

-- One-character strings for every byte value, and the same with the addon
-- channel's five escapes applied. Filled by the first writer opened
-- (`fillByteText`), not at load, so a session that loads CodecKit and never
-- encodes does not hold them; each table keeps its identity.
local BYTE_TEXT = {}
local ADDON_BYTE_TEXT = {}
local byteTextFilled = false

---Fill `BYTE_TEXT` and `ADDON_BYTE_TEXT`, once.
local function fillByteText()
  for value = 0, 255 do
    BYTE_TEXT[value] = char(value)
    ADDON_BYTE_TEXT[value] = char(value)
  end
  for raw, escaped in pairs(ADDON_ESCAPES) do
    ADDON_BYTE_TEXT[byte(raw)] = escaped
  end
  byteTextFilled = true
end

---Start writing into the work record's writer.
---@param writer table `work.writer`
---@param byteText table `BYTE_TEXT`, or `ADDON_BYTE_TEXT` to escape as it writes
---@param header string|nil written first, as is, and not counted in `size`
local function openWriter(writer, byteText, header)
  if not byteTextFilled then
    fillByteText()
  end
  writer.byteText = byteText
  writer.escapeStrings = byteText == ADDON_BYTE_TEXT
  writer.size = 0
  writer.chunkCount = 0
  if header ~= nil then
    writer[1] = header
    writer.count = 1
  else
    writer.count = 0
  end
end

---Drop the buffer's references to string values. The other fragments are
---the one- and two-byte strings of `BYTE_TEXT`, `ADDON_BYTE_TEXT` and the
---frame headers, which the file keeps alive anyway, so only the slots
---`writeValue` recorded in `textSlots` can hold anything of the caller's;
---clearing those alone keeps the reused buffer from pinning the caller's
---strings without a pass over every byte.
---@param writer table
local function releaseTexts(writer)
  local textSlots = writer.textSlots
  for index = 1, writer.textCount do
    writer[textSlots[index]] = nil
  end
  writer.textCount = 0
end

---Join the buffer into one chunk and start it again, so the buffer stays
---near `WRITER_FOLD_SIZE` slots however large the output.
---@param writer table
local function foldWriter(writer)
  local chunkCount = writer.chunkCount + 1
  writer.chunks[chunkCount] = concat(writer, "", 1, writer.count)
  writer.chunkCount = chunkCount
  releaseTexts(writer)
  writer.count = 0
end

---Write a varint, after a type byte unless `typeByte` is `false`: seven bits
---per byte, least significant group first, the high bit set on every byte but
---the last.
---@param writer table
---@param typeByte integer|false
---@param value integer 0 to 2^53
local function writeTagged(writer, typeByte, value)
  local byteText = writer.byteText
  local count = writer.count
  local start = count
  if typeByte then
    count = count + 1
    writer[count] = byteText[typeByte]
  end
  while value >= 128 do
    local low = value % 128
    count = count + 1
    writer[count] = byteText[low + 128]
    value = (value - low) / 128
  end
  count = count + 1
  writer[count] = byteText[value]
  writer.count = count
  writer.size = writer.size + (count - start)
end

---Drop every string value and chunk, so the reused buffer keeps no reference
---to the caller's strings. Called on every path that leaves the writer.
---@param writer table
local function closeWriter(writer)
  releaseTexts(writer)
  local chunks = writer.chunks
  for index = 1, writer.chunkCount do
    chunks[index] = nil
  end
  writer.count = 0
  writer.chunkCount = 0
end

---Join everything written into one string and close the writer.
---@param writer table
---@return string
local function finishWriter(writer)
  local result
  local chunkCount = writer.chunkCount
  if chunkCount > 0 then
    local chunks = writer.chunks
    if writer.count > 0 then
      chunkCount = chunkCount + 1
      chunks[chunkCount] = concat(writer, "", 1, writer.count)
      writer.chunkCount = chunkCount
    end
    result = concat(chunks, "", 1, chunkCount)
  else
    result = concat(writer, "", 1, writer.count)
  end
  closeWriter(writer)
  return result
end

-- Serialiser -----------------------------------------------------------------

---Write a number as an IEEE-754 binary64, big-endian, computed with `frexp`
---so it is exact for every double: NaN (written as the canonical quiet NaN),
---both infinities, both zeros and subnormals.
---@param writer table
---@param value number
local function writeFloat(writer, value)
  local byteText = writer.byteText
  local count = writer.count
  writer[count + 1] = byteText[TYPE_FLOAT]
  writer.count = count + 9
  writer.size = writer.size + 9
  -- NaN is recognised before anything else looks at the value, and written as
  -- the one canonical quiet NaN whatever its sign bit and payload. Neither is
  -- observable portably from Lua, and an ordered comparison with a NaN is not
  -- reliable on every host: on Retail 12.1.0 b69933 (measured 2026-09-25)
  -- the sign test below answered "negative" for `0 / 0`, so a writer that
  -- tested the sign first wrote `FF F8 ...` instead of `7F F8 ...`.
  if value ~= value then
    writer[count + 2] = byteText[127]
    writer[count + 3] = byteText[248] -- low exponent bits and the quiet bit
    for index = count + 4, count + 9 do
      writer[index] = byteText[0]
    end
    return
  end

  local sign = 0
  if value < 0 or (value == 0 and 1 / value < 0) then
    sign = 128
    value = -value
  end

  local exponent, fraction
  if value == HUGE then
    exponent, fraction = 2047, 0
  elseif value == 0 then
    exponent, fraction = 0, 0
  else
    -- value = mantissa * 2^power with 0.5 <= mantissa < 1, so the biased
    -- exponent of the normal form (2 * mantissa) * 2^(power - 1) is
    -- power + 1022.
    local mantissa, power = frexp(value)
    exponent = power + 1022
    if exponent >= 1 then
      fraction = (mantissa * 2 - 1) * 4503599627370496 -- 2^52
    else
      -- A subnormal is an integer multiple of 2^-1074.
      exponent = 0
      fraction = ldexp(value, 1074)
    end
  end

  local high = floor(fraction / 4294967296)
  local low = fraction % 4294967296
  writer[count + 2] = byteText[sign + floor(exponent / 16)]
  writer[count + 3] = byteText[(exponent % 16) * 16 + floor(high / 65536)]
  writer[count + 4] = byteText[floor(high / 256) % 256]
  writer[count + 5] = byteText[high % 256]
  writer[count + 6] = byteText[floor(low / 16777216)]
  writer[count + 7] = byteText[floor(low / 65536) % 256]
  writer[count + 8] = byteText[floor(low / 256) % 256]
  writer[count + 9] = byteText[low % 256]
end

---Write a number: a varint for an integer within +-2^53 other than -0, the
---exact double otherwise.
---@param writer table
---@param value number
local function writeNumber(writer, value)
  if
    value == value
    and value % 1 == 0
    and value >= -MAX_SAFE_INTEGER
    and value <= MAX_SAFE_INTEGER
  then
    if value > 0 then
      writeTagged(writer, TYPE_POSITIVE_INTEGER, value)
      return
    elseif value < 0 then
      writeTagged(writer, TYPE_NEGATIVE_INTEGER, -value)
      return
    elseif 1 / value > 0 then
      writeTagged(writer, TYPE_POSITIVE_INTEGER, 0)
      return
    end
  end
  writeFloat(writer, value)
end

---Whether `key` lies in the array part `1..arrayLength` of a table.
---@param key any
---@param arrayLength integer
---@return boolean
local function isArrayKey(key, arrayLength)
  return type(key) == "number" and key >= 1 and key <= arrayLength and key % 1 == 0
end

---The length of the array part of `value`: the leading run of non-nil indexes
---up to `#value`, so a hole ends it whatever border `#` picked. Elements are
---tested with `type` rather than `~= nil`, the repository rule for a value
---that may be a secret, which never compares anything.
---@param value table
---@return integer
local function arrayPartLength(value)
  local border = #value
  local arrayLength = 0
  while arrayLength < border and type(rawget(value, arrayLength + 1)) ~= "nil" do
    arrayLength = arrayLength + 1
  end
  return arrayLength
end

local writeValue

---Write a table: the array part `1..n` holds every leading non-nil index,
---found with `#` and verified with `rawget`; every other key is in the map
---part. The layout byte says which parts are present.
---
---A cycle is a table that is already open on the path from the top, and the
---tables open on that path are `work.visited[1..depth - 1]`: each level
---writes its table at its depth on the way down and clears it on the way up.
---Comparing with the few open tables (`rawequal`, so no `__eq` runs) replaces
---a set keyed by table, whose dead keys made Lua rehash it as distinct
---tables came and went.
---
---Contents are read raw: an element of the array part is known to be present,
---and so is every key `next` yields, so indexing them never reaches a
---metatable.
---@param work table
---@param writer table
---@param value table
---@param depth integer nesting of this table, 1 for a top-level table
---@return boolean ok
---@return any reason
local function writeTable(work, writer, value, depth)
  if depth > work.maxDepth then
    return false, REASON.maxDepth
  end
  local open = work.visited
  for index = 1, depth - 1 do
    if rawequal(open[index], value) then
      return false, REASON.cycle
    end
  end
  open[depth] = value

  local arrayLength = arrayPartLength(value)
  -- Every key `1..arrayLength` is present, so the map part is whatever else
  -- `next` finds.
  local keyCount = 0
  for _ in next, value do
    keyCount = keyCount + 1
  end
  local mapCount = keyCount - arrayLength

  if mapCount == 0 then
    writeTagged(writer, TYPE_ARRAY, arrayLength)
  elseif arrayLength == 0 then
    writeTagged(writer, TYPE_MAP, mapCount)
  else
    writeTagged(writer, TYPE_MIXED, arrayLength)
  end

  local ok, reason
  for index = 1, arrayLength do
    ok, reason = writeValue(work, writer, value[index], depth)
    if not ok then
      return false, reason
    end
  end

  if mapCount > 0 then
    if arrayLength > 0 then
      writeTagged(writer, false, mapCount)
    end
    for key, item in next, value do
      if arrayLength == 0 or not isArrayKey(key, arrayLength) then
        ok, reason = writeValue(work, writer, key, depth)
        if not ok then
          return false, reason
        end
        ok, reason = writeValue(work, writer, item, depth)
        if not ok then
          return false, reason
        end
      end
    end
  end

  open[depth] = nil
  return true
end

---Write one value. A secret is detected before anything else touches it.
---
---Short strings, small positive integers, booleans and `nil` are appended
---inline: they are most of what addon messages carry, and each call saved is
---a large share of their cost.
---@param work table
---@param writer table
---@param value any
---@param depth integer nesting of the table holding this value, 0 at the top
---@return boolean ok
---@return any reason a `CodecKit.Reason`, or `SECRET_FOUND`
function writeValue(work, writer, value, depth)
  local isSecret = work.isSecret
  if isSecret and isSecret(value) then
    return false, SECRET_FOUND
  end
  local valueCount = work.valueCount + 1
  if valueCount > work.maxValues then
    return false, REASON.maxValues
  end
  work.valueCount = valueCount
  if work.context and valueCount % PAUSE_VALUES == 0 then
    pause(work)
  end

  -- The buffer's count and size are read once and written once per scalar,
  -- not once per fragment: this runs for every value of every payload.
  local kind = type(value)
  local count, size
  if kind == "string" then
    local length = #value
    if length > work.maxStringLength then
      return false, REASON.maxStringLength
    end
    if length < 128 then
      local byteText = writer.byteText
      count = writer.count
      writer[count + 1] = byteText[TYPE_STRING]
      writer[count + 2] = byteText[length]
      count = count + 2
      size = writer.size + 2 + length
    else
      writeTagged(writer, TYPE_STRING, length)
      count = writer.count
      size = writer.size + length
    end
    if length > 0 then
      -- The string's bytes as one fragment, escaped first when the writer
      -- escapes for the addon channel and the string holds such a byte.
      if writer.escapeStrings and cleanText[value] == nil then
        if holdsEscapeByte(value, 1) then
          value = gsub(value, ADDON_ESCAPE_PATTERN, ADDON_ESCAPES)
        elseif length <= CLEAN_TEXT_MAX_LENGTH and cleanTextCount < CLEAN_TEXT_LIMIT then
          cleanText[value] = true
          cleanTextCount = cleanTextCount + 1
        end
      end
      count = count + 1
      writer[count] = value
      local textCount = writer.textCount + 1
      writer.textSlots[textCount] = count
      writer.textCount = textCount
    end
    writer.count = count
    writer.size = size
  elseif kind == "number" then
    -- `value == value` first: NaN takes the general path, which recognises
    -- it before any ordered comparison.
    if value == value and value > 0 and value < 128 and value % 1 == 0 then
      local byteText = writer.byteText
      count = writer.count
      writer[count + 1] = byteText[TYPE_POSITIVE_INTEGER]
      writer[count + 2] = byteText[value]
      count = count + 2
      writer.count = count
      size = writer.size + 2
      writer.size = size
    else
      writeNumber(writer, value)
      count, size = writer.count, writer.size
    end
  elseif kind == "boolean" or kind == "nil" then
    count = writer.count + 1
    if kind == "nil" then
      writer[count] = writer.byteText[TYPE_NIL]
    else
      writer[count] = writer.byteText[value and TYPE_TRUE or TYPE_FALSE]
    end
    writer.count = count
    size = writer.size + 1
    writer.size = size
  elseif kind == "table" then
    local ok, reason = writeTable(work, writer, value, depth + 1)
    if not ok then
      return false, reason
    end
    count, size = writer.count, writer.size
  else
    return false, REASON.unsupportedType
  end

  if size > work.maxOutputBytes then
    return false, REASON.maxOutputBytes
  end
  if count >= WRITER_FOLD_SIZE then
    foldWriter(writer)
  end
  return true
end

---Serialise one value, or an argument list when `count` is given.
---@param work table
---@param value any the value, or the packed argument list
---@param count integer|nil the argument count for a list
---@param byteText table `BYTE_TEXT`, or `ADDON_BYTE_TEXT` to escape the output
---for the addon channel as it is written
---@param header string|nil frame header written before the serialised bytes
---@return boolean ok
---@return any textOrReason the serialised bytes, after `header` and escaped
---as `byteText` says
local function serializeBody(work, value, count, byteText, header)
  local writer = work.writer
  openWriter(writer, byteText, header)
  local ok, reason
  if count == nil then
    ok, reason = writeValue(work, writer, value, 0)
  elseif count > work.maxValues or count > work.maxListValues then
    ok, reason = false, REASON.maxValues
  else
    ok = true
    writeTagged(writer, TYPE_LIST, count)
    for index = 1, count do
      ok, reason = writeValue(work, writer, rawget(value, index), 0)
      if not ok then
        break
      end
    end
  end
  if not ok then
    closeWriter(writer)
    return false, reason
  end
  return true, finishWriter(writer)
end

---Read a varint; refuse one longer than 8 bytes, above 2^53, or overlong (a
---final zero byte after the first).
---@param text string
---@param position integer
---@return integer|nil nextPosition
---@return any valueOrReason
local function readVarint(text, position)
  local value, multiplier = 0, 1
  for index = 0, 7 do
    local current = byte(text, position + index)
    if current == nil then
      return nil, REASON.truncated
    end
    local group = current % 128
    if group * multiplier > MAX_SAFE_INTEGER - value then
      return nil, REASON.malformedNumber
    end
    value = value + group * multiplier
    if current < 128 then
      if current == 0 and index > 0 then
        return nil, REASON.malformedNumber
      end
      return position + index + 1, value
    end
    multiplier = multiplier * 128
  end
  return nil, REASON.malformedNumber
end

---Read the eight bytes of a big-endian IEEE-754 binary64.
---@param text string
---@param position integer
---@return integer|nil nextPosition
---@return any valueOrReason
local function readFloat(text, position)
  local b1, b2, b3, b4, b5, b6, b7, b8 = byte(text, position, position + 7)
  if b8 == nil then
    return nil, REASON.truncated
  end
  local negative = b1 >= 128
  local exponent = (b1 % 128) * 16 + floor(b2 / 16)
  local high = (b2 % 16) * 65536 + b3 * 256 + b4
  local low = ((b5 * 256 + b6) * 256 + b7) * 256 + b8
  local fraction = high * 4294967296 + low

  local value
  if exponent == 2047 then
    if fraction == 0 then
      value = HUGE
    else
      value = HUGE - HUGE -- NaN, computed at run time
    end
  elseif exponent == 0 then
    value = ldexp(fraction, -1074)
  else
    value = ldexp(fraction + 4503599627370496, exponent - 1075)
  end
  if negative then
    value = -value
  end
  return position + 8, value
end

local readValue

---Read a table in one of the three layouts.
---@param work table
---@param text string
---@param position integer the byte after the layout byte
---@param depth integer nesting of this table, 1 for a top-level table
---@param layout integer `TYPE_ARRAY`, `TYPE_MAP` or `TYPE_MIXED`
---@return integer|nil nextPosition
---@return any tableOrReason
local function readTable(work, text, position, depth, layout)
  if depth > work.maxDepth then
    return nil, REASON.maxDepth
  end
  local textLength = work.textLength
  -- A count below 128 is one varint byte; read it inline, and let
  -- `readVarint` take everything else, including the end of the text.
  local count = byte(text, position)
  if count ~= nil and count < 128 then
    position = position + 1
  else
    local afterCount
    afterCount, count = readVarint(text, position)
    if afterCount == nil then
      return nil, count
    end
    position = afterCount
  end
  local arrayCount, mapCount = count, 0
  if layout == TYPE_MAP then
    arrayCount, mapCount = 0, count
  end
  -- Every value takes at least one byte: refuse an impossible count before
  -- looping over it.
  if arrayCount > textLength - position + 1 then
    return nil, REASON.truncated
  end

  local result = {}
  local nextPosition, value
  for index = 1, arrayCount do
    nextPosition, value = readValue(work, text, position, depth)
    if nextPosition == nil then
      return nil, value
    end
    if value == nil then
      return nil, REASON.nilValue
    end
    position = nextPosition
    result[index] = value
  end

  if layout == TYPE_MIXED then
    mapCount = byte(text, position)
    if mapCount ~= nil and mapCount < 128 then
      position = position + 1
    else
      nextPosition, mapCount = readVarint(text, position)
      if nextPosition == nil then
        return nil, mapCount
      end
      position = nextPosition
    end
  end
  if mapCount * 2 > textLength - position + 1 then
    return nil, REASON.truncated
  end

  local key
  for _ = 1, mapCount do
    nextPosition, key = readValue(work, text, position, depth)
    if nextPosition == nil then
      return nil, key
    end
    if key == nil or key ~= key then
      return nil, REASON.invalidKey
    end
    nextPosition, value = readValue(work, text, nextPosition, depth)
    if nextPosition == nil then
      return nil, value
    end
    position = nextPosition
    if value == nil then
      return nil, REASON.nilValue
    end
    -- `result` is a fresh table without a metatable, so indexing it is a
    -- raw read.
    if result[key] ~= nil then
      return nil, REASON.duplicateKey
    end
    result[key] = value
  end
  return position, result
end

---Read one value. Every byte read is bounds-checked, so malformed input ends
---in a reason and never in a Lua error.
---@param work table
---@param text string
---@param position integer
---@param depth integer nesting of the table holding this value, 0 at the top
---@return integer|nil nextPosition
---@return any valueOrReason
function readValue(work, text, position, depth)
  local count = work.valueCount + 1
  if count > work.maxValues then
    return nil, REASON.maxValues
  end
  work.valueCount = count
  if work.context and count % PAUSE_VALUES == 0 then
    pause(work)
  end

  local kind = byte(text, position)
  if kind == nil then
    return nil, REASON.truncated
  end
  position = position + 1

  -- Strings and non-negative integers come first, and their lengths and
  -- values below 128 are one varint byte read inline; `readVarint` takes
  -- everything else, including the end of the text.
  if kind == TYPE_STRING then
    local length = byte(text, position)
    local first
    if length ~= nil and length < 128 then
      first = position + 1
    else
      first, length = readVarint(text, position)
      if first == nil then
        return nil, length
      end
    end
    if length > work.maxStringLength then
      return nil, REASON.maxStringLength
    end
    local last = first + length - 1
    if last > work.textLength then
      return nil, REASON.truncated
    end
    return last + 1, sub(text, first, last)
  elseif kind == TYPE_POSITIVE_INTEGER then
    local value = byte(text, position)
    if value ~= nil and value < 128 then
      return position + 1, value
    end
    return readVarint(text, position)
  elseif kind == TYPE_NEGATIVE_INTEGER then
    local nextPosition, magnitude = readVarint(text, position)
    if nextPosition == nil then
      return nil, magnitude
    end
    if magnitude == 0 then
      return nil, REASON.malformedNumber
    end
    return nextPosition, -magnitude
  elseif kind == TYPE_FLOAT then
    return readFloat(text, position)
  elseif kind == TYPE_TRUE then
    return position, true
  elseif kind == TYPE_FALSE then
    return position, false
  elseif kind == TYPE_NIL then
    return position, nil
  elseif kind == TYPE_ARRAY or kind == TYPE_MAP or kind == TYPE_MIXED then
    return readTable(work, text, position, depth + 1, kind)
  end
  return nil, REASON.unknownType
end

---Deserialise a whole body. With `allowList`, an argument list is returned as
---a fresh array and its count; otherwise a list is refused.
---
---The body is `text` from byte `start` to the end, read in place: a frame's
---body is not copied out of the frame first. Every position the reader keeps
---is a position in `text`, so its bounds checks against `work.textLength`
---hold unchanged.
---@param work table
---@param text string
---@param start integer the first byte of the body
---@param allowList boolean
---@return boolean ok
---@return any valueOrReason
---@return integer|nil count the argument count of a list
local function deserializeBody(work, text, start, allowList)
  local textLength = #text
  if textLength - start + 1 > work.maxOutputBytes then
    return false, REASON.maxOutputBytes
  end
  work.textLength = textLength

  local position, value
  if byte(text, start) == TYPE_LIST then
    if not allowList then
      return false, REASON.multipleValues
    end
    local afterCount, count = readVarint(text, start + 1)
    if afterCount == nil then
      return false, count
    end
    position = afterCount
    if count > work.maxValues or count > work.maxListValues then
      return false, REASON.maxValues
    end
    if count > textLength - position + 1 then
      return false, REASON.truncated
    end
    local values = {}
    for index = 1, count do
      local nextPosition
      nextPosition, value = readValue(work, text, position, 0)
      if nextPosition == nil then
        return false, value
      end
      position = nextPosition
      values[index] = value
    end
    if position <= textLength then
      return false, REASON.trailingData
    end
    return true, values, count
  end

  position, value = readValue(work, text, start, 0)
  if position == nil then
    return false, value
  end
  if position <= textLength then
    return false, REASON.trailingData
  end
  return true, value
end

-- The compression stage lives in the Compression part
-- (`parts/CodecKit-Compression.lua`), which fills these two entries of the
-- shared state. Without it they are `false`: the public methods that compress
-- raise at the caller with the file to embed, and a compressed frame decodes
-- to `false, "compressionUnavailable"`, never raising on peer data.

---Compress `bytes` through the Compression part, bounded by `maxOutputBytes`.
---@param work table
---@param bytes string
---@param level integer
---@return boolean ok
---@return string bytesOrReason
local function compressBytes(work, bytes, level)
  local stage = compression.compress
  if not stage then
    return false, REASON.compressionUnavailable
  end
  local ok, result = stage(work, bytes, level)
  return ok, result
end

---Inflate `bytes` through the Compression part, bounded by `maxOutputBytes`.
---@param work table
---@param bytes string
---@return boolean ok
---@return string bytesOrReason
local function decompressBytes(work, bytes)
  local stage = compression.decompress
  if not stage then
    return false, REASON.compressionUnavailable
  end
  local ok, result = stage(work, bytes)
  return ok, result
end

-- Addon channel --------------------------------------------------------------
--
-- The addon channel cannot carry NUL, line feed, carriage return or the pipe
-- that introduces the client's escape sequences. Each of those, and the escape
-- byte 255 itself, becomes 255 followed by one ASCII digit. Every other byte
-- passes through unchanged. The tables and patterns are defined before the
-- writer, which applies the same escapes while serialising.

---@param work table
---@param bytes string
---@return boolean ok
---@return string textOrReason
local function encodeForAddon(work, bytes)
  if #bytes > work.maxOutputBytes then
    return false, REASON.maxOutputBytes
  end
  local text = gsub(bytes, ADDON_ESCAPE_PATTERN, ADDON_ESCAPES)
  if #text > work.maxOutputBytes then
    return false, REASON.maxOutputBytes
  end
  return true, text
end

---Unescape addon-channel text from byte `start` on (1 when omitted). A frame
---passes its whole text with `start` 3, so the escaped body is not copied out
---first; the two header bytes are neither forbidden nor the escape byte, so
---the unescaped text keeps them in front, unchanged, and the body still
---starts at byte 3.
---@param work table
---@param text string
---@param start integer|nil the first byte to unescape
---@return boolean ok
---@return string bytesOrReason
local function decodeForAddon(work, text, start)
  start = start or 1
  if #text - start + 1 > work.maxOutputBytes then
    return false, REASON.maxOutputBytes
  end
  if holdsForbiddenByte(text, start) then
    return false, REASON.forbiddenByte
  end
  -- The last byte is the body's own whenever the body is not empty, and a
  -- header byte (never the escape byte) otherwise.
  if find(text, ADDON_BAD_ESCAPE_PATTERN, start) or byte(text, -1) == ADDON_ESCAPE_BYTE then
    return false, REASON.malformedEscape
  end
  return true, (gsub(text, ADDON_SEQUENCE_PATTERN, ADDON_UNESCAPES))
end

-- Print channel --------------------------------------------------------------
--
-- Four bytes, read as a big-endian 32-bit number, become five base-85 digits,
-- most significant first. A final group of one to three bytes is padded with
-- zero bytes and only its first `n + 1` digits are written; the decoder pads
-- those with the highest digit and keeps `n` bytes. The alphabet is printable
-- ASCII without quotes, backslash, pipe, braces, percent and slash (see
-- `docs/API.md`), and whitespace in the input is ignored so a wrapped string
-- still decodes.

local PRINT_EXCLUDED = {
  [34] = true, -- "  quote
  [37] = true, -- %  chat and macro substitutions, format patterns
  [39] = true, -- '  quote
  [47] = true, -- /  a chat line starting with it is a command
  [92] = true, -- \  escape character of Lua strings and many editors
  [96] = true, -- `  quote
  [123] = true, -- { chat raid-target substitutions
  [124] = true, -- | the client's UI escape sequences
  [125] = true, -- } chat raid-target substitutions
}
local PRINT_BASE = 85
-- Digit to byte and byte to digit. Filled on the first print-safe encode or
-- decode (`buildPrintTables`), not at load, as most sessions never use the
-- print channel; each table keeps its identity.
local PRINT_CODES = {}
local PRINT_DIGITS = {}
local printTablesBuilt = false

---Fill `PRINT_CODES` and `PRINT_DIGITS` from the alphabet rule, once.
local function buildPrintTables()
  local digit = 0
  for code = 33, 126 do
    if not PRINT_EXCLUDED[code] then
      PRINT_CODES[digit] = code
      PRINT_DIGITS[code] = digit
      digit = digit + 1
    end
  end
  printTablesBuilt = true
end

-- The alphabet is public (`CodecKit.PRINT_ALPHABET`), so it is built at load,
-- by the same rule, without the two tables.
local PRINT_ALPHABET
do
  local codes = {}
  for code = 33, 126 do
    if not PRINT_EXCLUDED[code] then
      codes[#codes + 1] = code
    end
  end
  if #codes ~= PRINT_BASE then
    error("MoltenCodes CodecKit print alphabet must have 85 characters", 2)
  end
  PRINT_ALPHABET = char(unpack(codes))
end
local PRINT_MAX_GROUP = 4294967295
-- Exactly the characters `%s` strips on decode, so a print frame may start
-- with any of them.
local WHITESPACE = { [9] = true, [10] = true, [11] = true, [12] = true, [13] = true, [32] = true }

---Write the first `count` base-85 digits of `value`, most significant first.
---@param sink table
---@param value integer 0 to 2^32 - 1
---@param count integer 2 to 5
local function putPrintGroup(sink, value, count)
  local digit5 = value % PRINT_BASE
  value = (value - digit5) / PRINT_BASE
  local digit4 = value % PRINT_BASE
  value = (value - digit4) / PRINT_BASE
  local digit3 = value % PRINT_BASE
  value = (value - digit3) / PRINT_BASE
  local digit2 = value % PRINT_BASE
  local digit1 = (value - digit2) / PRINT_BASE
  putByte(sink, PRINT_CODES[digit1])
  putByte(sink, PRINT_CODES[digit2])
  if count >= 3 then
    putByte(sink, PRINT_CODES[digit3])
  end
  if count >= 4 then
    putByte(sink, PRINT_CODES[digit4])
  end
  if count >= 5 then
    putByte(sink, PRINT_CODES[digit5])
  end
end

---@param work table
---@param bytes string
---@return boolean ok
---@return string textOrReason
local function encodeForPrint(work, bytes)
  if not printTablesBuilt then
    buildPrintTables()
  end
  local length = #bytes
  local groups = floor(length / 4)
  local rest = length % 4
  local outputLength = groups * 5
  if rest > 0 then
    outputLength = outputLength + rest + 1
  end
  if outputLength > work.maxOutputBytes then
    return false, REASON.maxOutputBytes
  end

  local sink = openSink(work.pooled)
  for group = 0, groups - 1 do
    if work.context and group % PAUSE_GROUPS == 0 then
      pause(work)
    end
    local a, b, c, d = byte(bytes, group * 4 + 1, group * 4 + 4)
    putPrintGroup(sink, ((a * 256 + b) * 256 + c) * 256 + d, 5)
  end
  if rest > 0 then
    local a, b, c = byte(bytes, groups * 4 + 1, length)
    putPrintGroup(sink, ((a * 256 + (b or 0)) * 256 + (c or 0)) * 256, rest + 1)
  end
  return true, finishSink(sink)
end

---Read up to five digits starting at `position`, padding a short group with
---the highest digit; `nil` for a character outside the alphabet or a group
---above 2^32 - 1.
---@param text string
---@param position integer
---@param count integer 2 to 5
---@return integer|nil value
local function readPrintGroup(text, position, count)
  local value = 0
  for offset = 0, 4 do
    local digit = PRINT_BASE - 1
    if offset < count then
      digit = PRINT_DIGITS[byte(text, position + offset)]
      if digit == nil then
        return nil
      end
    end
    value = value * PRINT_BASE + digit
  end
  if value > PRINT_MAX_GROUP then
    return nil
  end
  return value
end

---Write the first `count` bytes of a 32-bit group, most significant first.
---@param sink table
---@param value integer
---@param count integer 1 to 4
local function putPrintBytes(sink, value, count)
  local byte4 = value % 256
  value = (value - byte4) / 256
  local byte3 = value % 256
  value = (value - byte3) / 256
  local byte2 = value % 256
  local byte1 = (value - byte2) / 256
  putByte(sink, byte1)
  if count >= 2 then
    putByte(sink, byte2)
  end
  if count >= 3 then
    putByte(sink, byte3)
  end
  if count >= 4 then
    putByte(sink, byte4)
  end
end

---@param work table
---@param text string
---@return boolean ok
---@return string bytesOrReason
local function decodeForPrint(work, text)
  if not printTablesBuilt then
    buildPrintTables()
  end
  -- The raw input, whitespace included, is bounded before any work on it.
  if #text > work.maxOutputBytes then
    return false, REASON.maxOutputBytes
  end
  local compact = gsub(text, "%s+", "")
  local length = #compact
  local groups = floor(length / 5)
  local rest = length % 5
  if rest == 1 then
    return false, REASON.malformedPrint
  end
  local outputLength = groups * 4
  if rest > 0 then
    outputLength = outputLength + rest - 1
  end
  if outputLength > work.maxOutputBytes then
    return false, REASON.maxOutputBytes
  end

  local sink = openSink(work.pooled)
  for group = 0, groups - 1 do
    if work.context and group % PAUSE_GROUPS == 0 then
      pause(work)
    end
    local value = readPrintGroup(compact, group * 5 + 1, 5)
    if value == nil then
      closeSink(sink)
      return false, REASON.malformedPrint
    end
    putPrintBytes(sink, value, 4)
  end
  if rest > 0 then
    local value = readPrintGroup(compact, groups * 5 + 1, rest)
    if value == nil then
      closeSink(sink)
      return false, REASON.malformedPrint
    end
    putPrintBytes(sink, value, rest - 1)
  end
  return true, finishSink(sink)
end

-- Frames ---------------------------------------------------------------------
--
-- A frame is the version byte, the flags byte and the stage output. For the
-- print channel the whole frame, header included, is print-encoded, so a
-- print frame is printable from its first character (always "!" in version
-- 1, the digit 0). For the addon channel only the body is escaped: the header
-- bytes are never among the escaped ones.

---The two header bytes for every flag combination.
local HEADERS = {}
for flags = 1, FLAG_RESERVED_FLOOR - 1, 2 do
  HEADERS[flags] = char(FORMAT_VERSION, flags)
end

---@param flags integer
---@param flag integer
---@return boolean
local function hasFlag(flags, flag)
  -- Plain arithmetic on the flags byte (0 to 255) and a power of two: the
  -- bit is set when the remainder below the next power reaches `flag`.
  return flags % (flag * 2) >= flag
end

---Serialise straight into the frame of an uncompressed `Encode`: the header
---is the writer's first fragment and, for the addon channel, the writer
---escapes as it goes, so the frame is the only string built. The result is
---byte for byte what serialising, escaping and prefixing the header one stage
---after another gives, and it is refused for the same reasons: the writer
---checks the serialised size after every value as the serialiser always did,
---and the joined frame is measured once, which covers the escaped body too
---because it is two bytes shorter.
---@param work table
---@param value any the value, or the packed argument list
---@param count integer|nil the argument count for a list
---@param channel string
---@return boolean ok
---@return any textOrReason
local function encodeUncompressedFrame(work, value, count, channel)
  if channel == "print" then
    local ok, frame =
      serializeBody(work, value, count, BYTE_TEXT, HEADERS[FLAG_SERIALIZED + FLAG_PRINT])
    if not ok then
      return false, frame
    end
    return encodeForPrint(work, frame)
  end

  local ok, text
  if channel == "addon" then
    ok, text =
      serializeBody(work, value, count, ADDON_BYTE_TEXT, HEADERS[FLAG_SERIALIZED + FLAG_ADDON])
  else
    ok, text = serializeBody(work, value, count, BYTE_TEXT, HEADERS[FLAG_SERIALIZED])
  end
  if not ok then
    return false, text
  end
  if #text > work.maxOutputBytes then
    return false, REASON.maxOutputBytes
  end
  return true, text
end

---Run the stages `Encode` asked for and return the frame.
---@param work table
---@param value any the value, or the packed argument list
---@param count integer|nil the argument count for a list
---@param compress string
---@param channel string
---@param level integer
---@return boolean ok
---@return any textOrReason
local function encodeFrame(work, value, count, compress, channel, level)
  if compress ~= "deflate" then
    return encodeUncompressedFrame(work, value, count, channel)
  end
  local ok, body = serializeBody(work, value, count, BYTE_TEXT, nil)
  if not ok then
    return false, body
  end
  local flags = FLAG_SERIALIZED + FLAG_DEFLATE
  ok, body = compressBytes(work, body, level)
  if not ok then
    return false, body
  end

  if channel == "print" then
    return encodeForPrint(work, HEADERS[flags + FLAG_PRINT] .. body)
  end
  if channel == "addon" then
    flags = flags + FLAG_ADDON
    ok, body = encodeForAddon(work, body)
    if not ok then
      return false, body
    end
  end
  local text = HEADERS[flags] .. body
  if #text > work.maxOutputBytes then
    return false, REASON.maxOutputBytes
  end
  return true, text
end

---Read and check the flags byte.
---@param flags integer|nil
---@return string|nil reason
local function checkFlags(flags)
  if flags == nil then
    return REASON.truncated
  end
  if
    flags >= FLAG_RESERVED_FLOOR
    or not hasFlag(flags, FLAG_SERIALIZED)
    or (hasFlag(flags, FLAG_ADDON) and hasFlag(flags, FLAG_PRINT))
  then
    return REASON.malformedHeader
  end
  return nil
end

---Reverse the stages a frame's header names.
---@param work table
---@param text string
---@param expectedChannel string|nil
---@param allowList boolean
---@return boolean ok
---@return any valueOrReason
---@return integer|nil count the argument count of a list
local function decodeFrame(work, text, expectedChannel, allowList)
  local first = byte(text, 1)
  if first == nil then
    return false, REASON.truncated
  end

  -- `body` from byte `start` is the serialised or compressed stage input.
  -- A binary frame, and an addon frame with nothing to unescape, keep the
  -- received text and start at byte 3, so the common message is never copied.
  local ok, flags, body, reason
  local start = 1
  if first == FORMAT_VERSION then
    flags = byte(text, 2)
    reason = checkFlags(flags)
    if reason == nil and hasFlag(flags, FLAG_PRINT) then
      reason = REASON.malformedHeader
    end
    if reason ~= nil then
      return false, reason
    end
    body, start = text, 3
    if hasFlag(flags, FLAG_ADDON) then
      -- Without an escape byte or a forbidden byte after the header, the
      -- addon stage would return its input unchanged, so only its input
      -- limit is left to check; with one, it runs in full and refuses
      -- exactly as it always did.
      if holdsEscapeByte(text, 3) then
        ok, body = decodeForAddon(work, text, 3)
        if not ok then
          return false, body
        end
      elseif #text - 2 > work.maxOutputBytes then
        return false, REASON.maxOutputBytes
      end
    end
  elseif (first >= 33 and first <= 126 and not PRINT_EXCLUDED[first]) or WHITESPACE[first] then
    -- A print digit (the alphabet rule, read without the digit table, which
    -- is built only for print frames) or whitespace.
    local frame
    ok, frame = decodeForPrint(work, text)
    if not ok then
      return false, frame
    end
    local version = byte(frame, 1)
    if version == nil then
      return false, REASON.truncated
    end
    if version ~= FORMAT_VERSION then
      return false, REASON.unsupportedVersion
    end
    flags = byte(frame, 2)
    reason = checkFlags(flags)
    if reason == nil and not hasFlag(flags, FLAG_PRINT) then
      reason = REASON.malformedHeader
    end
    if reason ~= nil then
      return false, reason
    end
    body = sub(frame, 3)
  else
    return false, REASON.unsupportedVersion
  end

  if expectedChannel ~= nil then
    local channel = "none"
    if hasFlag(flags, FLAG_ADDON) then
      channel = "addon"
    elseif hasFlag(flags, FLAG_PRINT) then
      channel = "print"
    end
    if channel ~= expectedChannel then
      return false, REASON.channelMismatch
    end
  end

  if hasFlag(flags, FLAG_DEFLATE) then
    if start > 1 then
      body = sub(body, start)
      start = 1
    end
    ok, body = decompressBytes(work, body)
    if not ok then
      return false, body
    end
  end
  return deserializeBody(work, body, start, allowList)
end

---Look for a secret anywhere in `value` before an asynchronous encode is
---scheduled, so the refusal is raised at the caller. The walk visits values
---in the encoder's order and counts them the way `writeValue` does, and stops
---where the encoder would refuse with `"maxValues"` or `"maxDepth"`, so every
---value the job could reach has been asked about. With `maxValues` lifted it
---stops where `"maxOutputBytes"` must have refused: every value started wrote
---at least one byte, and at most `maxDepth + 1` values are started but not yet
---finished (and so not yet measured) at any time, so the encoder can reach no
---more than `maxOutputBytes + maxDepth + 2` values.
---@param work table
---@param value any
---@param depth integer nesting of the table holding this value, 0 at the top
---@return boolean
local function containsSecret(work, value, depth)
  if work.isSecret(value) then
    return true
  end
  local count = work.valueCount + 1
  if count > work.maxValues or count > work.maxOutputBytes + work.maxDepth + 2 then
    return false
  end
  work.valueCount = count
  if type(value) ~= "table" or depth >= work.maxDepth then
    return false
  end
  local arrayLength = arrayPartLength(value)
  for index = 1, arrayLength do
    if containsSecret(work, rawget(value, index), depth + 1) then
      return true
    end
  end
  local key = next(value)
  while type(key) ~= "nil" do
    if
      not isArrayKey(key, arrayLength)
      and (
        containsSecret(work, key, depth + 1) or containsSecret(work, rawget(value, key), depth + 1)
      )
    then
      return true
    end
    key = next(value, key)
  end
  return false
end

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method. `level` is always the
-- value `error` needs *inside the function that receives it*, so every further
-- hop towards `error` adds exactly one.

---Refuse a receiver other than the CodecKit facade (a `.` call, say).
---@param receiver any
---@param label string qualified public method name
---@param level integer
local function validateFacade(receiver, label, level)
  -- `type` first: the receiver is the caller's value, and only a table is
  -- ever compared with the facade.
  if type(receiver) ~= "table" or receiver ~= CodecKit then
    error(label .. " must be called on the CodecKit facade; use " .. label .. "(...)", level)
  end
end

---Refuse anything but a non-secret string. `type` is safe on a secret; the
---secret probe runs before anything else looks at the string.
---@param value any
---@param label string qualified argument name
---@param level integer
local function validateBytes(value, label, level)
  if type(value) ~= "string" then
    error(label .. " must be a string", level)
  end
  local isSecret = readSecretProbe()
  if isSecret ~= nil and isSecret(value) then
    error(label .. " must not be a secret value", level)
  end
end

---Refuse a secret option or limit value before anything compares it: comparing
---a secret with a value of its own type raises in the client. Callers test for an
---absent value with `type`, never with `== nil`, by the repository rule. The
---message is built only on refusal, so the check allocates nothing.
---@param value any
---@param label string the method, qualified
---@param name string the option or limit, qualified by its table (`options.level`)
---@param level integer
local function refuseSecretSetting(value, label, name, level)
  -- An absent setting is never a secret; `type` answers that without asking
  -- the host.
  if type(value) == "nil" then
    return
  end
  local isSecret = readSecretProbe()
  if isSecret ~= nil and isSecret(value) then
    error(label .. " " .. name .. " must not be a secret value", level)
  end
end

---Name a table key in a refusal without running the caller's code: a string
---as itself, a number or boolean as written, anything else by its type
---(`<table>`), because `tostring` would run a `__tostring` metamethod. A key
---the probe reports secret never reaches this: it is refused first.
---@param key any
---@return string
local function describeKey(key)
  local kind = type(key)
  if kind == "string" then
    return key
  end
  if kind == "number" or kind == "boolean" then
    return tostring(key)
  end
  return "<" .. kind .. ">"
end

---Refuse option keys outside `known`, and a secret key before it is used to
---index `known` (the client would raise inside CodecKit).
---@param options table
---@param known table<string, true>
---@param label string
---@param level integer
---@param probe function|false|nil the call's `issecretvalue`; read here when `nil`
local function validateOptionKeys(options, known, label, level, probe)
  if probe == nil then
    probe = readSecretProbe() or false
  end
  local key = next(options)
  while type(key) ~= "nil" do
    if probe and probe(key) then
      error(label .. " options must not have a secret key", level)
    end
    if type(key) ~= "string" or known[key] ~= true then
      error(label .. " options." .. describeKey(key) .. " is not a recognised option", level)
    end
    key = next(options, key)
  end
end

---@param level any
---@param label string
---@param errorLevel integer
---@return integer
local function readLevel(level, label, errorLevel)
  refuseSecretSetting(level, label, "options.level", errorLevel + 1)
  if type(level) == "nil" then
    return DEFAULT_LEVEL
  end
  if type(level) ~= "number" or level % 1 ~= 0 or level < 1 or level > 9 then
    error(label .. " options.level must be an integer from 1 to 9", errorLevel)
  end
  return level
end

---@param channel any
---@param label string
---@param level integer
---@return string|nil
local function readChannel(channel, label, level)
  refuseSecretSetting(channel, label, "options.channel", level + 1)
  if type(channel) == "nil" then
    return nil
  end
  if type(channel) ~= "string" or CHANNELS[channel] ~= true then
    error(label .. ' options.channel must be "none", "addon" or "print"', level)
  end
  return channel
end

---Raise at the caller: `member` belongs to `part`, which is not loaded. The
---message names the file to embed (ADR 0001, point 5).
---@param member string what the caller asked for, as it reads in a message
---@param part string the part's name
---@param level integer
local function refuseMissingPart(member, part, level)
  error(
    member
      .. " is in CodecKit's "
      .. part
      .. " part, which is not loaded: add "
      .. PART_FILES[part]
      .. " to embeds.xml after codecKit\\CodecKit.lua",
    level
  )
end

---Validate encode options and return the stages they select. One pass, in the
---order the separate helpers checked (unknown keys, then `compress`, `channel`
---and `level`, each refused when secret before it is compared), with the
---probe read once by the caller.
---@param options any
---@param label string
---@param level integer
---@param probe function|false the call's `issecretvalue`, `false` for none
---@return string compress
---@return string channel
---@return integer compressionLevel
local function readEncodeOptions(options, label, level, probe)
  if type(options) == "nil" then
    return "none", "none", DEFAULT_LEVEL
  end
  if type(options) ~= "table" then
    error(label .. " options must be a table or nil", level)
  end
  validateOptionKeys(options, ENCODE_OPTION_KEYS, label, level + 1, probe)
  local compress = rawget(options, "compress")
  if type(compress) == "nil" then
    compress = "none"
  else
    if probe and probe(compress) then
      error(label .. " options.compress must not be a secret value", level)
    end
    if type(compress) ~= "string" or COMPRESSIONS[compress] ~= true then
      error(label .. ' options.compress must be "none" or "deflate"', level)
    end
  end
  local channel = rawget(options, "channel")
  if type(channel) == "nil" then
    channel = "none"
  else
    if probe and probe(channel) then
      error(label .. " options.channel must not be a secret value", level)
    end
    if type(channel) ~= "string" or CHANNELS[channel] ~= true then
      error(label .. ' options.channel must be "none", "addon" or "print"', level)
    end
  end
  local compressionLevel = rawget(options, "level")
  if type(compressionLevel) == "nil" then
    compressionLevel = DEFAULT_LEVEL
  else
    if probe and probe(compressionLevel) then
      error(label .. " options.level must not be a secret value", level)
    end
    if
      type(compressionLevel) ~= "number"
      or compressionLevel % 1 ~= 0
      or compressionLevel < 1
      or compressionLevel > 9
    then
      error(label .. " options.level must be an integer from 1 to 9", level)
    end
  end
  if compress == "deflate" and not compression.compress then
    refuseMissingPart(label .. ' options.compress "deflate"', "Compression", level + 1)
  end
  return compress, channel, compressionLevel
end

---Validate decode options and return the channel a frame must use, if any.
---@param options any
---@param label string
---@param level integer
---@return string|nil
local function readDecodeOptions(options, label, level)
  if type(options) == "nil" then
    return nil
  end
  if type(options) ~= "table" then
    error(label .. " options must be a table or nil", level)
  end
  validateOptionKeys(options, DECODE_OPTION_KEYS, label, level + 1)
  return readChannel(rawget(options, "channel"), label, level + 1)
end

---Raise at the caller when the encoder found a secret. Called as a statement,
---never as a tail call: a tail call would drop the public method's frame and
---shift the reported level.
---@param ok boolean
---@param result any
---@param label string
---@param level integer
local function refuseSecret(ok, result, label, level)
  if not ok and result == SECRET_FOUND then
    error(label .. " value must not contain a secret value", level)
  end
end

---Find SchedulerKit for an asynchronous call, or raise at the caller.
---@param label string
---@param level integer
---@return table schedulerScopePrototype
local function resolveSchedulerScope(label, level)
  local findPackage = rawget(Registry, "Find")
  if type(findPackage) ~= "function" then
    error(label .. " requires Registry:Find (Registry API 2 revision 7 or newer)", level)
  end
  local SchedulerKit, reason = findPackage(Registry, "schedulerKit", OPTIONAL_SCHEDULERKIT_API)
  if type(SchedulerKit) == "nil" then
    error(
      label .. " requires SchedulerKit API 1, which is not loaded (" .. tostring(reason) .. ")",
      level
    )
  end
  local Scope = rawget(SchedulerKit, "Scope")
  if type(Scope) ~= "table" or type(rawget(Scope, "Schedule")) ~= "function" then
    error(label .. " requires a valid SchedulerKit API 1 facade", level)
  end
  return Scope
end

---Refuse anything but an open SchedulerKit scope, and a non-function callback.
---@param scope any
---@param callback any
---@param label string
---@param level integer
local function validateAsyncTarget(scope, callback, label, level)
  local Scope = resolveSchedulerScope(label, level + 1)
  local metatable = type(scope) == "table" and getmetatable(scope) or nil
  if type(metatable) ~= "table" or rawget(metatable, "__index") ~= Scope then
    error(label .. " scope must be a SchedulerKit scope", level)
  end
  if scope:IsClosed() then
    error(label .. " scope is closed", level)
  end
  if type(callback) ~= "function" then
    error(label .. " callback must be a function", level)
  end
end

---@param limits any
---@param level integer
local function validateLimitUpdate(limits, level)
  if type(limits) ~= "table" then
    error("CodecKit:SetLimits limits must be a table", level)
  end
  local probe = readSecretProbe()
  local key = next(limits)
  while type(key) ~= "nil" do
    if probe ~= nil and probe(key) then
      error("CodecKit:SetLimits limits must not have a secret key", level)
    end
    if type(key) ~= "string" or LIMIT_CEILINGS[key] == nil then
      error("CodecKit:SetLimits limits." .. describeKey(key) .. " is not a recognised limit", level)
    end
    local value = rawget(limits, key)
    local ceiling = LIMIT_CEILINGS[key]
    refuseSecretSetting(value, "CodecKit:SetLimits", "limits." .. key, level + 1)
    if value == UNBOUNDED then
      if UNBOUNDED_ALLOWED[key] ~= true then
        error(
          "CodecKit:SetLimits limits."
            .. key
            .. " cannot be CodecKit.UNBOUNDED because "
            .. BOUNDED_REASONS[key]
            .. "; use an integer from 1 to "
            .. ceiling,
          level
        )
      end
    elseif type(value) ~= "number" or value % 1 ~= 0 or value < 1 or value > ceiling then
      local accepted = "an integer from 1 to " .. ceiling
      if UNBOUNDED_ALLOWED[key] == true then
        accepted = accepted .. " or CodecKit.UNBOUNDED"
      end
      error("CodecKit:SetLimits limits." .. key .. " must be " .. accepted, level)
    end
    key = next(limits, key)
  end
end

-- Package public API ---------------------------------------------------------

local ENCODE_ASYNC_OPTIONS = { name = "CodecKit:EncodeAsync" }
local DECODE_ASYNC_OPTIONS = { name = "CodecKit:DecodeAsync" }

---Encode one value through the stages `options` selects.
---@param self CodecKit
---@param value any
---@param options CodecKit.EncodeOptions?
---@return boolean ok
---@return string textOrReason
local function encode(self, value, options)
  validateFacade(self, "CodecKit:Encode", 3)
  local probe = readSecretProbe() or false
  local compress, channel, level = readEncodeOptions(options, "CodecKit:Encode", 3, probe)
  local work = openWork(true, probe)
  local ok, result = encodeFrame(work, value, nil, compress, channel, level)
  closeWork(work)
  refuseSecret(ok, result, "CodecKit:Encode", 3)
  return ok, result
end

---Decode a frame made by `Encode`. Never raises on malformed input.
---@param self CodecKit
---@param text string
---@param options CodecKit.DecodeOptions?
---@return boolean ok
---@return any valueOrReason
local function decode(self, text, options)
  validateFacade(self, "CodecKit:Decode", 3)
  validateBytes(text, "CodecKit:Decode text", 3)
  local channel = readDecodeOptions(options, "CodecKit:Decode", 3)
  local work = openWork(true)
  local ok, value = decodeFrame(work, text, channel, false)
  closeWork(work)
  return ok, value
end

---Encode an argument list, `nil`s and trailing `nil`s included.
---@param self CodecKit
---@param options CodecKit.EncodeOptions?
---@param ... any
---@return boolean ok
---@return string textOrReason
local function encodeMany(self, options, ...)
  validateFacade(self, "CodecKit:EncodeMany", 3)
  local probe = readSecretProbe() or false
  local compress, channel, level = readEncodeOptions(options, "CodecKit:EncodeMany", 3, probe)
  local count = select("#", ...)
  local values = { ... }
  local work = openWork(true, probe)
  local ok, result = encodeFrame(work, values, count, compress, channel, level)
  closeWork(work)
  refuseSecret(ok, result, "CodecKit:EncodeMany", 3)
  return ok, result
end

---Decode a frame made by `EncodeMany` (or `Encode`) into its values.
---@param self CodecKit
---@param text string
---@param options CodecKit.DecodeOptions?
---@return boolean ok
---@return any ... the values, or the reason
local function decodeMany(self, text, options)
  validateFacade(self, "CodecKit:DecodeMany", 3)
  validateBytes(text, "CodecKit:DecodeMany text", 3)
  local channel = readDecodeOptions(options, "CodecKit:DecodeMany", 3)
  local work = openWork(true)
  local ok, values, count = decodeFrame(work, text, channel, true)
  closeWork(work)
  if ok and count ~= nil then
    return true, unpack(values, 1, count)
  end
  return ok, values
end

---Serialise one value, without a header.
---@param self CodecKit
---@param value any
---@return boolean ok
---@return string bytesOrReason
local function serialize(self, value)
  validateFacade(self, "CodecKit:Serialize", 3)
  local work = openWork(true)
  local ok, result = serializeBody(work, value, nil, BYTE_TEXT, nil)
  closeWork(work)
  refuseSecret(ok, result, "CodecKit:Serialize", 3)
  return ok, result
end

---Deserialise bytes made by `Serialize`. Never raises on malformed input.
---@param self CodecKit
---@param bytes string
---@return boolean ok
---@return any valueOrReason
local function deserialize(self, bytes)
  validateFacade(self, "CodecKit:Deserialize", 3)
  validateBytes(bytes, "CodecKit:Deserialize bytes", 3)
  local work = openWork(true)
  local ok, value = deserializeBody(work, bytes, 1, false)
  closeWork(work)
  return ok, value
end

---Compress bytes as raw DEFLATE.
---@param self CodecKit
---@param bytes string
---@param options CodecKit.CompressOptions?
---@return boolean ok
---@return string bytesOrReason
local function compress(self, bytes, options)
  validateFacade(self, "CodecKit:Compress", 3)
  if not compression.compress then
    refuseMissingPart("CodecKit:Compress", "Compression", 3)
  end
  validateBytes(bytes, "CodecKit:Compress bytes", 3)
  local level = DEFAULT_LEVEL
  if type(options) ~= "nil" then
    if type(options) ~= "table" then
      error("CodecKit:Compress options must be a table or nil", 2)
    end
    validateOptionKeys(options, COMPRESS_OPTION_KEYS, "CodecKit:Compress", 3)
    level = readLevel(rawget(options, "level"), "CodecKit:Compress", 3)
  end
  local work = openWork(true)
  local ok, result = compressBytes(work, bytes, level)
  closeWork(work)
  return ok, result
end

---Inflate a raw DEFLATE stream. Never raises on malformed input.
---@param self CodecKit
---@param bytes string
---@return boolean ok
---@return string bytesOrReason
local function decompress(self, bytes)
  validateFacade(self, "CodecKit:Decompress", 3)
  if not compression.decompress then
    refuseMissingPart("CodecKit:Decompress", "Compression", 3)
  end
  validateBytes(bytes, "CodecKit:Decompress bytes", 3)
  local work = openWork(true)
  local ok, result = decompressBytes(work, bytes)
  closeWork(work)
  return ok, result
end

---Build one of the four channel stage methods.
---@param label string
---@param argumentName string
---@param stage fun(work: table, text: string): boolean, string
---@return fun(self: CodecKit, text: string): boolean, string
local function channelMethod(label, argumentName, stage)
  local argumentLabel = label .. " " .. argumentName
  return function(self, text)
    validateFacade(self, label, 3)
    validateBytes(text, argumentLabel, 3)
    local work = openWork(true)
    local ok, result = stage(work, text)
    closeWork(work)
    return ok, result
  end
end

---Encode on a SchedulerKit scope in slices under the frame budget.
---@param self CodecKit
---@param value any
---@param options CodecKit.EncodeOptions?
---@param scope table a SchedulerKit scope
---@param callback fun(ok: boolean, result: string)
---@return table job the SchedulerKit job
local function encodeAsync(self, value, options, scope, callback)
  local label = "CodecKit:EncodeAsync"
  validateFacade(self, label, 3)
  local probe = readSecretProbe() or false
  local compressName, channel, level = readEncodeOptions(options, label, 3, probe)
  validateAsyncTarget(scope, callback, label, 3)
  local work = openWork(false, probe)
  if work.isSecret and containsSecret(work, value, 0) then
    error(label .. " value must not contain a secret value", 2)
  end
  work.valueCount = 0
  return scope:Schedule(function(context)
    work.context = context
    local ok, result = encodeFrame(work, value, nil, compressName, channel, level)
    work.context = false
    if not ok and result == SECRET_FOUND then
      -- The value changed after the call and now holds a secret.
      result = "secret"
    end
    callback(ok, result)
  end, ENCODE_ASYNC_OPTIONS)
end

---Decode on a SchedulerKit scope in slices under the frame budget.
---@param self CodecKit
---@param text string
---@param options CodecKit.DecodeOptions?
---@param scope table a SchedulerKit scope
---@param callback fun(ok: boolean, result: any)
---@return table job the SchedulerKit job
local function decodeAsync(self, text, options, scope, callback)
  local label = "CodecKit:DecodeAsync"
  validateFacade(self, label, 3)
  validateBytes(text, label .. " text", 3)
  local channel = readDecodeOptions(options, label, 3)
  validateAsyncTarget(scope, callback, label, 3)
  local work = openWork(false)
  return scope:Schedule(function(context)
    work.context = context
    local ok, value = decodeFrame(work, text, channel, false)
    work.context = false
    callback(ok, value)
  end, DECODE_ASYNC_OPTIONS)
end

---Change any subset of the shared limits. Affects every consumer. Validates
---every field before changing any, so a refused call changes nothing.
---@param self CodecKit
---@param limits CodecKit.Limits
local function setLimits(self, limits)
  validateFacade(self, "CodecKit:SetLimits", 3)
  validateLimitUpdate(limits, 3)
  for index = 1, #LIMIT_NAMES do
    local name = LIMIT_NAMES[index]
    local value = rawget(limits, name)
    if type(value) ~= "nil" then
      rawset(sharedLimits, name, value)
    end
  end
end

---Whether the named part is loaded in this session: `"Compression"`. Code
---that uses a part only when it is there asks this, never whether the method
---is a function: the core keeps every member, raising when its part is absent.
---@param self CodecKit
---@param name string
---@return boolean
local function hasPart(self, name)
  validateFacade(self, "CodecKit:HasPart", 3)
  local probe = readSecretProbe()
  if probe and probe(name) then
    error("CodecKit:HasPart name must not be a secret value", 2)
  end
  if type(name) ~= "string" then
    error("CodecKit:HasPart name must be a string", 2)
  end
  return type(rawget(rawget(state, "parts"), name)) == "table"
end

---Return a fresh copy of the shared limits.
---@param self CodecKit
---@return CodecKit.Limits
local function getLimits(self)
  validateFacade(self, "CodecKit:GetLimits", 3)
  return {
    maxDepth = rawget(sharedLimits, "maxDepth"),
    maxValues = rawget(sharedLimits, "maxValues"),
    maxStringLength = rawget(sharedLimits, "maxStringLength"),
    maxOutputBytes = rawget(sharedLimits, "maxOutputBytes"),
    maxListValues = rawget(sharedLimits, "maxListValues"),
  }
end

-- Commit ---------------------------------------------------------------------

rawset(CodecKit, "API", API_GENERATION)
rawset(CodecKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(CodecKit, "FORMAT_VERSION", FORMAT_VERSION)
rawset(CodecKit, "PRINT_ALPHABET", PRINT_ALPHABET)
rawset(CodecKit, "UNBOUNDED", UNBOUNDED)
rawset(CodecKit, "Encode", encode)
rawset(CodecKit, "Decode", decode)
rawset(CodecKit, "EncodeMany", encodeMany)
rawset(CodecKit, "DecodeMany", decodeMany)
rawset(CodecKit, "Serialize", serialize)
rawset(CodecKit, "Deserialize", deserialize)
rawset(CodecKit, "Compress", compress)
rawset(CodecKit, "Decompress", decompress)
rawset(
  CodecKit,
  "EncodeForAddon",
  channelMethod("CodecKit:EncodeForAddon", "bytes", encodeForAddon)
)
rawset(CodecKit, "DecodeForAddon", channelMethod("CodecKit:DecodeForAddon", "text", decodeForAddon))
rawset(
  CodecKit,
  "EncodeForPrint",
  channelMethod("CodecKit:EncodeForPrint", "bytes", encodeForPrint)
)
rawset(CodecKit, "DecodeForPrint", channelMethod("CodecKit:DecodeForPrint", "text", decodeForPrint))
rawset(CodecKit, "EncodeAsync", encodeAsync)
rawset(CodecKit, "DecodeAsync", decodeAsync)
rawset(CodecKit, "SetLimits", setLimits)
rawset(CodecKit, "GetLimits", getLimits)
rawset(CodecKit, "HasPart", hasPart)

-- What the parts call, refilled by every core revision so a part loaded
-- before an upgrade is served by the newer core (`bindHelpers` in each part).
do
  local helpers = rawget(state, "helpers")
  rawset(helpers, "reasons", REASON)
  rawset(helpers, "sinkBatchSize", SINK_BATCH_SIZE)
  rawset(helpers, "leaseTable", leaseTable)
  rawset(helpers, "returnTable", returnTable)
  rawset(helpers, "pause", pause)
  rawset(helpers, "openSink", openSink)
  rawset(helpers, "closeSink", closeSink)
  rawset(helpers, "appendFragment", appendFragment)
  rawset(helpers, "putByte", putByte)
  rawset(helpers, "putString", putString)
  rawset(helpers, "finishSink", finishSink)
end
rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(CodecKit) or not validateCurrentState(CodecKit) then
  error("MoltenCodes CodecKit package state is corrupted or incomplete", 2)
end

return CodecKit
