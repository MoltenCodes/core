-- MoltenCodes CodecKit
--
-- Turns Lua values into transport-safe strings and back in three composable
-- stages behind a two-byte, self-describing header:
--
--   serialise        a type byte and a payload per value: varint integers,
--                    exact IEEE-754 doubles, length-prefixed raw strings, and
--                    tables in array, map or mixed layout. Cycles are refused.
--   compress         raw DEFLATE (RFC 1951) written in pure Lua: LZ77 over hash
--                    chains, then per block the cheapest of stored, fixed
--                    Huffman and dynamic Huffman.
--   channel-encode   `addon` escapes the five bytes the addon channel cannot
--                    carry; `print` maps everything onto 85 printable ASCII
--                    characters for chat and export strings.
--
-- Decoding never raises on malformed input: every failure is `false, reason`
-- with a reason from a fixed vocabulary. Depth, value count, string length and
-- every stage's output size are bounded by limits shared by every consumer.
--
-- CodecKit needs Registry API 2 and PoolKit API 1 (fragment buffers are leased
-- from a table pool and returned on every path, so calls are re-entrant). The
-- asynchronous variants find SchedulerKit API 1 through `Registry:Find` when
-- they are called; without it they raise at the caller.
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
--   DEFLATE tables ........ RFC 1951 length, distance and fixed-code tables
--   Huffman codes ......... length-limited code construction and decoders
--   Compressor ............ LZ77 matching, block choice and bit output
--   Decompressor .......... stored, fixed and dynamic block inflation
--   Addon channel ......... the escape table
--   Print channel ......... the 85-character alphabet
--   Frames ................ the header and the composition of the stages
--   Argument checks ....... receivers, options, limits, secret values
--   Package public API .... the facade published through Registry
--   Commit ................ facade assignment and self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "codecKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local REQUIRED_POOLKIT_API = 1
local OPTIONAL_SCHEDULERKIT_API = 1
local STATE_SCHEMA = 1

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
}

-- Internal marker for a secret found while serialising. It never reaches a
-- caller as a reason: the public method raises at the caller's line instead.
local SECRET_FOUND = {}

-- Limits every consumer in the session shares. Each is bounded by default and
-- has a ceiling `SetLimits` refuses to pass, so no setting makes a hostile
-- input unbounded. `maxDepth` is also bounded by the Lua call stack the
-- recursive reader and writer use.
local LIMIT_NAMES = { "maxDepth", "maxValues", "maxStringLength", "maxOutputBytes" }
local DEFAULT_LIMITS = {
    maxDepth = 16,
    maxValues = 65536,
    maxStringLength = 65536,
    maxOutputBytes = 1048576,
}
local LIMIT_CEILINGS = {
    maxDepth = 128,
    maxValues = 16777216,
    maxStringLength = 1073741824,
    -- 64 MiB. Inflating keeps one array slot (16 bytes) per output byte, so a
    -- higher ceiling would let one frame demand more than a gigabyte.
    maxOutputBytes = 67108864,
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
-- most five at a time, so sixteen covers nested and interleaved calls without
-- keeping memory nobody uses.
local POOL_MAX_RETAINED = 16

-- Byte sinks hold pending bytes as numbers and fragments as strings. Both
-- flush at this size: `string.char(unpack(...))` stays far below the Lua 5.1
-- C-stack limit, and a retained fragment array stays small.
local SINK_BATCH_SIZE = 1024
local SINK_FRAGMENT_SIZE = 1024

-- How often the asynchronous variants ask `context:ShouldYield()`: every this
-- many serialised values, input positions or decoded symbols.
local PAUSE_VALUES = 256
local PAUSE_POSITIONS = 2048
local PAUSE_SYMBOLS = 4096
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
}

-- Public types ---------------------------------------------------------------

---Why a call returned `false`. See `docs/API.md` for each reason.
---@alias CodecKit.Reason "cycle"|"unsupportedType"|"maxDepth"|"maxValues"|"maxStringLength"|"maxOutputBytes"|"truncated"|"trailingData"|"unsupportedVersion"|"malformedHeader"|"channelMismatch"|"forbiddenByte"|"malformedEscape"|"malformedPrint"|"malformedDeflate"|"unknownType"|"malformedNumber"|"invalidKey"|"duplicateKey"|"nilValue"|"multipleValues"|"secret"

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

---The shared limits. `SetLimits` accepts any subset.
---@class CodecKit.Limits
---@field maxDepth integer Deepest table nesting; default 16, at most 128.
---@field maxValues integer Most values (keys included) in one payload; default 65536.
---@field maxStringLength integer Longest single string; default 65536.
---@field maxOutputBytes integer Largest output of any stage; default 1048576.

---The CodecKit package facade published through Registry.
---@class CodecKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field FORMAT_VERSION integer The frame version this copy writes and reads.
---@field PRINT_ALPHABET string The 85 characters of the print channel, digit 0 first.
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
---@field SetLimits fun(self: CodecKit, limits: table)
---@field GetLimits fun(self: CodecKit): CodecKit.Limits

-- Dependencies ---------------------------------------------------------------

local byte = string.byte
local char = string.char
local sub = string.sub
local find = string.find
local gsub = string.gsub
local concat = table.concat
local sort = table.sort
local floor = math.floor
local frexp = math.frexp
local ldexp = math.ldexp
local HUGE = math.huge

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

---Return the host's `issecretvalue`, or `nil` on a client without secret
---values. Read at every public call, as SchemaKit does, so the probe may be
---installed after CodecKit loaded.
---@return (fun(value: any): boolean)|nil
local function readSecretProbe()
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

---Whether `limits` holds every limit as a positive integer.
---@param limits any
---@return boolean
local function validateLimits(limits)
    if type(limits) ~= "table" then
        return false
    end
    for index = 1, #LIMIT_NAMES do
        local value = rawget(limits, LIMIT_NAMES[index])
        if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
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
        and validateLimits(rawget(currentState, "limits"))
        and type(rawget(currentState, "pool")) == "table"
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
        },
        -- One table pool for every embedded copy. It keeps the tables a call
        -- leases; the pool's shallow reset clears them on release.
        pool = PoolKit:NewTablePool({ maxRetained = POOL_MAX_RETAINED }),
    }
    rawset(CodecKit, "_state", state)
elseif not validateStateBase(state) then
    error("MoltenCodes CodecKit package state is corrupted or incomplete", 2)
end

local sharedLimits = rawget(state, "limits")
local tablePool = rawget(state, "pool")

-- Work and buffers -----------------------------------------------------------
--
-- Every call builds one work record: the limits it runs under, the secret
-- probe, counters, and whether its tables come from the pool. Synchronous
-- calls lease every table from the shared pool and return each one on every
-- path. Asynchronous calls use plain tables instead, because a job cancelled
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

---Open the work record of one call, copying the shared limits so a
---`SetLimits` during an asynchronous job does not change it mid-way.
---@param pooled boolean
---@return table work
local function openWork(pooled)
    local work = leaseTable(pooled)
    work.pooled = pooled
    work.context = false
    work.isSecret = readSecretProbe() or false
    work.maxDepth = rawget(sharedLimits, "maxDepth")
    work.maxValues = rawget(sharedLimits, "maxValues")
    work.maxStringLength = rawget(sharedLimits, "maxStringLength")
    work.maxOutputBytes = rawget(sharedLimits, "maxOutputBytes")
    work.valueCount = 0
    work.visited = false
    work.textLength = 0
    return work
end

---Close a work record and everything it still holds.
---@param work table
local function closeWork(work)
    local pooled = work.pooled
    local visited = work.visited
    if visited then
        work.visited = false
        returnTable(pooled, visited)
    end
    returnTable(pooled, work)
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
    sink.total = 0
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
    sink.total = sink.total + #fragment
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

---The number of bytes written so far.
---@param sink table
---@return integer
local function sinkSize(sink)
    return sink.total + sink.batchCount
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

-- Serialiser -----------------------------------------------------------------

---Write a non-negative integer as a varint: seven bits per byte, least
---significant group first, the high bit set on every byte but the last.
---@param sink table
---@param value integer 0 to 2^53
local function putVarint(sink, value)
    while value >= 128 do
        local low = value % 128
        putByte(sink, low + 128)
        value = (value - low) / 128
    end
    putByte(sink, value)
end

---Write a number as an IEEE-754 binary64, big-endian, computed with `frexp`
---so it is exact for every double: NaN (written as the canonical quiet NaN),
---both infinities, both zeros and subnormals.
---@param sink table
---@param value number
local function putFloat(sink, value)
    putByte(sink, TYPE_FLOAT)
    local sign = 0
    if value < 0 or (value == 0 and 1 / value < 0) then
        sign = 128
        value = -value
    end

    local exponent, fraction
    if value ~= value then
        exponent, fraction = 2047, 2251799813685248 -- 2^51: the quiet bit
    elseif value == HUGE then
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
    putByte(sink, sign + floor(exponent / 16))
    putByte(sink, (exponent % 16) * 16 + floor(high / 65536))
    putByte(sink, floor(high / 256) % 256)
    putByte(sink, high % 256)
    putByte(sink, floor(low / 16777216))
    putByte(sink, floor(low / 65536) % 256)
    putByte(sink, floor(low / 256) % 256)
    putByte(sink, low % 256)
end

---Write a number: a varint for an integer within +-2^53 other than -0, the
---exact double otherwise.
---@param sink table
---@param value number
local function putNumber(sink, value)
    if
        value == value
        and value % 1 == 0
        and value >= -MAX_SAFE_INTEGER
        and value <= MAX_SAFE_INTEGER
    then
        if value > 0 then
            putByte(sink, TYPE_POSITIVE_INTEGER)
            putVarint(sink, value)
            return
        elseif value < 0 then
            putByte(sink, TYPE_NEGATIVE_INTEGER)
            putVarint(sink, -value)
            return
        elseif 1 / value > 0 then
            putByte(sink, TYPE_POSITIVE_INTEGER)
            putByte(sink, 0)
            return
        end
    end
    putFloat(sink, value)
end

---Whether `key` lies in the array part `1..arrayLength` of a table.
---@param key any
---@param arrayLength integer
---@return boolean
local function isArrayKey(key, arrayLength)
    return type(key) == "number" and key >= 1 and key <= arrayLength and key % 1 == 0
end

local writeValue

---Write a table: the array part `1..n` holds every leading non-nil index,
---found with `#` and verified with `rawget`; every other key is in the map
---part. The layout byte says which parts are present.
---@param work table
---@param sink table
---@param value table
---@param depth integer nesting of this table, 1 for a top-level table
---@return boolean ok
---@return any reason
local function writeTable(work, sink, value, depth)
    if depth > work.maxDepth then
        return false, REASON.maxDepth
    end
    local visited = work.visited
    if not visited then
        visited = leaseTable(work.pooled)
        work.visited = visited
    end
    if visited[value] then
        return false, REASON.cycle
    end
    visited[value] = true

    local border = #value
    local arrayLength = 0
    -- `type` rather than `~= nil`: an element may be a secret, and comparing a
    -- secret raises. Elements are asked about secrecy only in `writeValue`.
    while arrayLength < border and type(rawget(value, arrayLength + 1)) ~= "nil" do
        arrayLength = arrayLength + 1
    end
    local mapCount = 0
    local key = next(value)
    while type(key) ~= "nil" do
        if not isArrayKey(key, arrayLength) then
            mapCount = mapCount + 1
        end
        key = next(value, key)
    end

    if mapCount == 0 then
        putByte(sink, TYPE_ARRAY)
        putVarint(sink, arrayLength)
    elseif arrayLength == 0 then
        putByte(sink, TYPE_MAP)
        putVarint(sink, mapCount)
    else
        putByte(sink, TYPE_MIXED)
        putVarint(sink, arrayLength)
    end

    local ok, reason
    for index = 1, arrayLength do
        ok, reason = writeValue(work, sink, rawget(value, index), depth)
        if not ok then
            return false, reason
        end
    end

    if mapCount > 0 then
        if arrayLength > 0 then
            putVarint(sink, mapCount)
        end
        key = next(value)
        while type(key) ~= "nil" do
            if not isArrayKey(key, arrayLength) then
                ok, reason = writeValue(work, sink, key, depth)
                if not ok then
                    return false, reason
                end
                ok, reason = writeValue(work, sink, rawget(value, key), depth)
                if not ok then
                    return false, reason
                end
            end
            key = next(value, key)
        end
    end

    visited[value] = nil
    return true
end

---Write one value. A secret is detected before anything else touches it.
---@param work table
---@param sink table
---@param value any
---@param depth integer nesting of the table holding this value, 0 at the top
---@return boolean ok
---@return any reason a `CodecKit.Reason`, or `SECRET_FOUND`
function writeValue(work, sink, value, depth)
    local isSecret = work.isSecret
    if isSecret and isSecret(value) then
        return false, SECRET_FOUND
    end
    local count = work.valueCount + 1
    if count > work.maxValues then
        return false, REASON.maxValues
    end
    work.valueCount = count
    if work.context and count % PAUSE_VALUES == 0 then
        pause(work)
    end

    local kind = type(value)
    if kind == "string" then
        local length = #value
        if length > work.maxStringLength then
            return false, REASON.maxStringLength
        end
        putByte(sink, TYPE_STRING)
        putVarint(sink, length)
        if length > 0 then
            putString(sink, value)
        end
    elseif kind == "number" then
        putNumber(sink, value)
    elseif kind == "boolean" then
        putByte(sink, value and TYPE_TRUE or TYPE_FALSE)
    elseif kind == "nil" then
        putByte(sink, TYPE_NIL)
    elseif kind == "table" then
        local ok, reason = writeTable(work, sink, value, depth + 1)
        if not ok then
            return false, reason
        end
    else
        return false, REASON.unsupportedType
    end

    if sinkSize(sink) > work.maxOutputBytes then
        return false, REASON.maxOutputBytes
    end
    return true
end

---Serialise one value, or an argument list when `count` is given.
---@param work table
---@param value any the value, or the packed argument list
---@param count integer|nil the argument count for a list
---@return boolean ok
---@return any bytesOrReason
local function serializeBody(work, value, count)
    local sink = openSink(work.pooled)
    local ok, reason
    if count == nil then
        ok, reason = writeValue(work, sink, value, 0)
    elseif count > work.maxValues then
        ok, reason = false, REASON.maxValues
    else
        ok = true
        putByte(sink, TYPE_LIST)
        putVarint(sink, count)
        for index = 1, count do
            ok, reason = writeValue(work, sink, rawget(value, index), 0)
            if not ok then
                break
            end
        end
    end
    if not ok then
        closeSink(sink)
        return false, reason
    end
    return true, finishSink(sink)
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
    local afterCount, count = readVarint(text, position)
    if afterCount == nil then
        return nil, count
    end
    position = afterCount
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
        nextPosition, mapCount = readVarint(text, position)
        if nextPosition == nil then
            return nil, mapCount
        end
        position = nextPosition
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
        if rawget(result, key) ~= nil then
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

    if kind == TYPE_STRING then
        local first, length = readVarint(text, position)
        if first == nil then
            return nil, length
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
---@param work table
---@param text string
---@param allowList boolean
---@return boolean ok
---@return any valueOrReason
---@return integer|nil count the argument count of a list
local function deserializeBody(work, text, allowList)
    local textLength = #text
    if textLength > work.maxOutputBytes then
        return false, REASON.maxOutputBytes
    end
    work.textLength = textLength

    local position, value
    if byte(text, 1) == TYPE_LIST then
        if not allowList then
            return false, REASON.multipleValues
        end
        local afterCount, count = readVarint(text, 2)
        if afterCount == nil then
            return false, count
        end
        position = afterCount
        if count > work.maxValues then
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

    position, value = readValue(work, text, 1, 0)
    if position == nil then
        return false, value
    end
    if position <= textLength then
        return false, REASON.trailingData
    end
    return true, value
end

-- The DEFLATE implementation below is one `do` scope that exports only these
-- two entry points. Its tables and helpers would otherwise count against the
-- 200 locals Lua 5.1 allows the main chunk.
local compressInto, inflateInto

do
    -- DEFLATE tables -------------------------------------------------------------
    --
    -- Everything in this section is RFC 1951 data, built once when the file loads.
    -- Symbol-indexed tables are zero-based, as the RFC numbers its symbols.

    local WINDOW_SIZE = 32768
    local MIN_MATCH = 3
    local MAX_MATCH = 258
    local END_OF_BLOCK = 256
    local LITERAL_SYMBOLS = 286
    local DISTANCE_SYMBOLS = 30
    local CODE_LENGTH_SYMBOLS = 19
    local MAX_CODE_BITS = 15
    local MAX_CODE_LENGTH_BITS = 7

    -- A length-3 match further back than this costs more bits than three
    -- literals usually do; zlib makes the same call.
    local TOO_FAR = 4096

    -- A block ends after this many tokens or this many input bytes, whichever
    -- comes first. The byte bound keeps a stored block under the format's 65535.
    local BLOCK_MAX_TOKENS = 16384
    local BLOCK_MAX_BYTES = 32768

    -- Powers of two, looked up rather than computed in the bit loops.
    local POW2 = {}
    for exponent = 0, 48 do
        POW2[exponent] = 2 ^ exponent
    end

    -- Length symbols 257..285 as indexes 0..28: base length and extra bits.
    local LENGTH_BASE = {}
    local LENGTH_EXTRA = {}
    -- Distance symbols 0..29: base distance and extra bits.
    local DISTANCE_BASE = {}
    local DISTANCE_EXTRA = {}
    do
        -- stylua: ignore start
        local lengthBases = {
            3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
            35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
        }
        local lengthExtras = {
            0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
            3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
        }
        local distanceBases = {
            1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
            257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
        }
        local distanceExtras = {
            0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
            7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
        }
        -- stylua: ignore end
        for index = 1, #lengthBases do
            LENGTH_BASE[index - 1] = lengthBases[index]
            LENGTH_EXTRA[index - 1] = lengthExtras[index]
        end
        for index = 1, #distanceBases do
            DISTANCE_BASE[index - 1] = distanceBases[index]
            DISTANCE_EXTRA[index - 1] = distanceExtras[index]
        end
    end

    -- Match length 3..258 to its length index 0..28. Filled in ascending order so
    -- 258 ends on its own symbol (285) rather than on 284's range.
    local LENGTH_INDEX = {}
    for index = 0, 28 do
        local base = LENGTH_BASE[index]
        for length = base, math.min(base + POW2[LENGTH_EXTRA[index]] - 1, MAX_MATCH) do
            LENGTH_INDEX[length] = index
        end
    end

    -- Distance to symbol: direct for 1..256; above that every symbol boundary is
    -- a multiple of 128 plus one, so `(distance - 1) / 128` indexes a small table.
    local DISTANCE_SMALL = {}
    local DISTANCE_LARGE = {}
    for symbol = 0, DISTANCE_SYMBOLS - 1 do
        local first = DISTANCE_BASE[symbol]
        local last = first + POW2[DISTANCE_EXTRA[symbol]] - 1
        for distance = first, math.min(last, 256) do
            DISTANCE_SMALL[distance] = symbol
        end
        if last > 256 then
            for group = floor((math.max(first, 257) - 1) / 128), floor((last - 1) / 128) do
                DISTANCE_LARGE[group] = symbol
            end
        end
    end

    ---@param distance integer 1 to 32768
    ---@return integer symbol 0 to 29
    local function distanceSymbol(distance)
        if distance <= 256 then
            return DISTANCE_SMALL[distance]
        end
        return DISTANCE_LARGE[floor((distance - 1) / 128)]
    end

    -- The order the code-length code lengths are sent in (RFC 1951 3.2.7).
    local CODE_LENGTH_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

    -- The fixed Huffman code lengths (RFC 1951 3.2.6).
    local FIXED_LITERAL_LENGTHS = {}
    for symbol = 0, 287 do
        local length = 8
        if symbol >= 144 and symbol <= 255 then
            length = 9
        elseif symbol >= 256 and symbol <= 279 then
            length = 7
        end
        FIXED_LITERAL_LENGTHS[symbol] = length
    end
    local FIXED_DISTANCE_LENGTHS = {}
    for symbol = 0, 31 do
        FIXED_DISTANCE_LENGTHS[symbol] = 5
    end

    -- Compression levels: how far to follow a hash chain (`chain`), when a match
    -- is long enough to stop looking (`nice`), when to quarter the chain because
    -- the previous match was already good (`good`), and whether to defer a match
    -- by one byte to look for a longer one (`lazy`, with `lazyLimit` the match
    -- length above which no deferred search runs). Greedy levels insert the
    -- positions inside a match into the hash only up to `lazyLimit` bytes.
    --
    -- Levels 8 and 9 cap the chain at 192 and 256 candidates, where zlib uses
    -- 1024 and 4096: on low-entropy input (two random symbols, say) every
    -- chain is full of short matches, and the longer chains made level 9
    -- twenty-seven times slower than level 6 in pure Lua for well under 5%
    -- smaller output. The caps keep level 9 within about three times level 6.
    local LEVELS = {
        { lazy = false, good = 4, lazyLimit = 4, nice = 8, chain = 4 },
        { lazy = false, good = 4, lazyLimit = 5, nice = 16, chain = 8 },
        { lazy = false, good = 4, lazyLimit = 6, nice = 32, chain = 32 },
        { lazy = true, good = 4, lazyLimit = 4, nice = 16, chain = 16 },
        { lazy = true, good = 8, lazyLimit = 16, nice = 32, chain = 32 },
        { lazy = true, good = 8, lazyLimit = 16, nice = 128, chain = 128 },
        { lazy = true, good = 8, lazyLimit = 32, nice = 128, chain = 256 },
        { lazy = true, good = 32, lazyLimit = 128, nice = 258, chain = 192 },
        { lazy = true, good = 32, lazyLimit = 258, nice = 258, chain = 256 },
    }

    -- Huffman codes --------------------------------------------------------------

    ---Reverse the low `length` bits of `code`. DEFLATE packs Huffman codes most
    ---significant bit first into a stream read least significant bit first.
    ---@param code integer
    ---@param length integer
    ---@return integer
    local function reverseBits(code, length)
        local reversed = 0
        for _ = 1, length do
            local bit = code % 2
            reversed = reversed * 2 + bit
            code = (code - bit) / 2
        end
        return reversed
    end

    ---The first canonical code of every length (RFC 1951 3.2.2).
    ---@param lengths table<integer, integer> zero-based code lengths
    ---@param symbolCount integer
    ---@return table<integer, integer> nextCode
    local function firstCodes(lengths, symbolCount)
        local lengthCount = {}
        for bits = 0, MAX_CODE_BITS do
            lengthCount[bits] = 0
        end
        for symbol = 0, symbolCount - 1 do
            local length = lengths[symbol]
            lengthCount[length] = lengthCount[length] + 1
        end
        lengthCount[0] = 0
        local nextCode = {}
        local code = 0
        for bits = 1, MAX_CODE_BITS do
            code = (code + lengthCount[bits - 1]) * 2
            nextCode[bits] = code
        end
        return nextCode
    end

    ---Assign canonical codes, stored bit-reversed so they can be written as is.
    ---@param lengths table<integer, integer>
    ---@param symbolCount integer
    ---@return table<integer, integer> codes
    local function canonicalCodes(lengths, symbolCount)
        local nextCode = firstCodes(lengths, symbolCount)
        local codes = {}
        for symbol = 0, symbolCount - 1 do
            local length = lengths[symbol]
            if length > 0 then
                local code = nextCode[length]
                nextCode[length] = code + 1
                codes[symbol] = reverseBits(code, length)
            else
                codes[symbol] = 0
            end
        end
        return codes
    end

    ---Build length-limited Huffman code lengths for `frequencies`.
    ---
    ---Symbols are sorted by frequency (packed with the symbol into one number so
    ---the default comparator sorts them), a Huffman tree is built with the
    ---two-queue method, and the resulting length counts are folded under
    ---`maxBits` and repaired until the Kraft sum is exactly one. The shortest
    ---lengths then go to the most frequent symbols. Fewer than two used symbols
    ---are padded with unused ones so the code is always complete.
    ---@param frequencies table<integer, integer> zero-based
    ---@param symbolCount integer
    ---@param maxBits integer
    ---@return table<integer, integer> lengths zero-based
    local function huffmanLengths(frequencies, symbolCount, maxBits)
        local lengths = {}
        local sorted = {}
        local used = 0
        for symbol = 0, symbolCount - 1 do
            lengths[symbol] = 0
            local frequency = frequencies[symbol]
            if frequency > 0 then
                used = used + 1
                sorted[used] = frequency * 512 + symbol
            end
        end
        local padding = 0
        while used < 2 do
            -- Weight 0 sorts a padding symbol first; its length costs nothing.
            if frequencies[padding] == 0 then
                used = used + 1
                sorted[used] = padding
            end
            padding = padding + 1
        end
        sort(sorted)

        local weight, parent = {}, {}
        for index = 1, used do
            weight[index] = floor(sorted[index] / 512)
        end
        local nextLeaf, nextNode = 1, used + 1
        local lastNode = used
        for node = used + 1, 2 * used - 1 do
            local first, second
            if
                nextLeaf <= used and (nextNode > lastNode or weight[nextLeaf] <= weight[nextNode])
            then
                first, nextLeaf = nextLeaf, nextLeaf + 1
            else
                first, nextNode = nextNode, nextNode + 1
            end
            if
                nextLeaf <= used and (nextNode > lastNode or weight[nextLeaf] <= weight[nextNode])
            then
                second, nextLeaf = nextLeaf, nextLeaf + 1
            else
                second, nextNode = nextNode, nextNode + 1
            end
            weight[node] = weight[first] + weight[second]
            parent[first] = node
            parent[second] = node
            lastNode = node
        end

        local root = 2 * used - 1
        local depth = { [root] = 0 }
        local lengthCount = {}
        for bits = 1, maxBits do
            lengthCount[bits] = 0
        end
        for node = root - 1, 1, -1 do
            depth[node] = depth[parent[node]] + 1
        end
        for leaf = 1, used do
            local bits = depth[leaf]
            if bits > maxBits then
                bits = maxBits
            end
            lengthCount[bits] = lengthCount[bits] + 1
        end

        local total = 0
        for bits = 1, maxBits do
            total = total + lengthCount[bits] * POW2[maxBits - bits]
        end
        local full = POW2[maxBits]
        while total > full do
            -- Remove one leaf at the deepest length and split a shallower leaf
            -- into two one level deeper: the Kraft sum drops by one unit.
            lengthCount[maxBits] = lengthCount[maxBits] - 1
            for bits = maxBits - 1, 1, -1 do
                if lengthCount[bits] > 0 then
                    lengthCount[bits] = lengthCount[bits] - 1
                    lengthCount[bits + 1] = lengthCount[bits + 1] + 2
                    break
                end
            end
            total = total - 1
        end

        local leaf = used
        for bits = 1, maxBits do
            for _ = 1, lengthCount[bits] do
                lengths[sorted[leaf] % 512] = bits
                leaf = leaf - 1
            end
        end
        return lengths
    end

    ---Build a decoder for canonical code `lengths`, or refuse them.
    ---
    ---The decoder maps `2^length + reversedCode` to the symbol, so a lookup for a
    ---given length matches exactly the codes of that length. An over-subscribed
    ---set is refused; an incomplete one only when it is not the single one-bit
    ---code RFC 1951 allows for a block with one distance.
    ---@param lengths table<integer, integer> zero-based
    ---@param symbolCount integer
    ---@return table|false|nil decoder `false` when no symbol has a code, `nil` when invalid
    local function buildDecoder(lengths, symbolCount)
        local lengthCount = {}
        for bits = 1, MAX_CODE_BITS do
            lengthCount[bits] = 0
        end
        local used, minLength, maxLength = 0, MAX_CODE_BITS + 1, 0
        for symbol = 0, symbolCount - 1 do
            local length = lengths[symbol]
            if length > 0 then
                used = used + 1
                lengthCount[length] = lengthCount[length] + 1
                if length < minLength then
                    minLength = length
                end
                if length > maxLength then
                    maxLength = length
                end
            end
        end
        if used == 0 then
            return false
        end
        local left = 1
        for bits = 1, MAX_CODE_BITS do
            left = left * 2 - lengthCount[bits]
            if left < 0 then
                return nil
            end
        end
        if left > 0 and not (used == 1 and maxLength == 1) then
            return nil
        end

        local nextCode = firstCodes(lengths, symbolCount)
        local lookup = {}
        for symbol = 0, symbolCount - 1 do
            local length = lengths[symbol]
            if length > 0 then
                local code = nextCode[length]
                nextCode[length] = code + 1
                lookup[POW2[length] + reverseBits(code, length)] = symbol
            end
        end
        return { lookup = lookup, minLength = minLength, maxLength = maxLength }
    end

    local FIXED_LITERAL_CODES = canonicalCodes(FIXED_LITERAL_LENGTHS, 288)
    local FIXED_DISTANCE_CODES = canonicalCodes(FIXED_DISTANCE_LENGTHS, DISTANCE_SYMBOLS)
    local FIXED_LITERAL_DECODER = buildDecoder(FIXED_LITERAL_LENGTHS, 288) --[[@as table]]
    local FIXED_DISTANCE_DECODER = buildDecoder(FIXED_DISTANCE_LENGTHS, 32) --[[@as table]]

    -- Compressor -----------------------------------------------------------------
    --
    -- One compressor record per call holds the input as an array of byte values,
    -- the hash chains, the tokens of the current block and the bit writer. It is
    -- a plain table, not leased: its arrays are proportional to the input, and a
    -- pool retaining them would keep that memory for the session.

    ---Write `bits` low bits of `value` to the output, least significant first.
    ---@param compressor table
    ---@param value integer
    ---@param bits integer
    local function writeBits(compressor, value, bits)
        local count = compressor.bitCount
        local buffer = compressor.bitBuffer + value * POW2[count]
        count = count + bits
        local sink = compressor.sink
        while count >= 8 do
            local low = buffer % 256
            putByte(sink, low)
            buffer = (buffer - low) / 256
            count = count - 8
        end
        compressor.bitBuffer = buffer
        compressor.bitCount = count
    end

    ---Pad the current byte with zero bits.
    ---@param compressor table
    local function alignToByte(compressor)
        if compressor.bitCount > 0 then
            writeBits(compressor, 0, 8 - compressor.bitCount)
        end
    end

    ---Start a new block: no tokens, zeroed frequencies, one end-of-block symbol.
    ---@param compressor table
    local function resetBlock(compressor)
        compressor.tokenCount = 0
        compressor.extraBits = 0
        compressor.blockStart = compressor.covered + 1
        local literalFrequencies = compressor.literalFrequencies
        for symbol = 0, LITERAL_SYMBOLS - 1 do
            literalFrequencies[symbol] = 0
        end
        literalFrequencies[END_OF_BLOCK] = 1
        local distanceFrequencies = compressor.distanceFrequencies
        for symbol = 0, DISTANCE_SYMBOLS - 1 do
            distanceFrequencies[symbol] = 0
        end
    end

    ---Run-length encode the literal and distance code lengths with the
    ---code-length alphabet, and size the resulting dynamic block header.
    ---@param literalLengths table<integer, integer>
    ---@param distanceLengths table<integer, integer>
    ---@return table header
    local function dynamicHeader(literalLengths, distanceLengths)
        local literalCount = LITERAL_SYMBOLS
        while literalCount > 257 and literalLengths[literalCount - 1] == 0 do
            literalCount = literalCount - 1
        end
        local distanceCount = DISTANCE_SYMBOLS
        while distanceCount > 1 and distanceLengths[distanceCount - 1] == 0 do
            distanceCount = distanceCount - 1
        end

        local sequence = {}
        for symbol = 0, literalCount - 1 do
            sequence[symbol + 1] = literalLengths[symbol]
        end
        for symbol = 0, distanceCount - 1 do
            sequence[literalCount + symbol + 1] = distanceLengths[symbol]
        end

        local symbols, extras, count = {}, {}, 0
        local frequencies = {}
        for symbol = 0, CODE_LENGTH_SYMBOLS - 1 do
            frequencies[symbol] = 0
        end
        local function emit(symbol, extra)
            count = count + 1
            symbols[count] = symbol
            extras[count] = extra
            frequencies[symbol] = frequencies[symbol] + 1
        end

        local index, total = 1, #sequence
        while index <= total do
            local length = sequence[index]
            local run = 1
            while index + run <= total and sequence[index + run] == length do
                run = run + 1
            end
            index = index + run
            if length == 0 then
                while run >= 11 do
                    local take = math.min(run, 138)
                    emit(18, take - 11)
                    run = run - take
                end
                if run >= 3 then
                    emit(17, run - 3)
                    run = 0
                end
            else
                emit(length, 0)
                run = run - 1
                while run >= 3 do
                    local take = math.min(run, 6)
                    emit(16, take - 3)
                    run = run - take
                end
            end
            for _ = 1, run do
                emit(length, 0)
            end
        end

        local codeLengths = huffmanLengths(frequencies, CODE_LENGTH_SYMBOLS, MAX_CODE_LENGTH_BITS)
        local orderCount = CODE_LENGTH_SYMBOLS
        while orderCount > 4 and codeLengths[CODE_LENGTH_ORDER[orderCount]] == 0 do
            orderCount = orderCount - 1
        end

        local bits = 5 + 5 + 4 + 3 * orderCount
        for position = 1, count do
            local symbol = symbols[position]
            bits = bits + codeLengths[symbol]
            if symbol == 16 then
                bits = bits + 2
            elseif symbol == 17 then
                bits = bits + 3
            elseif symbol == 18 then
                bits = bits + 7
            end
        end

        return {
            literalCount = literalCount,
            distanceCount = distanceCount,
            orderCount = orderCount,
            codeLengths = codeLengths,
            symbols = symbols,
            extras = extras,
            symbolCount = count,
            bits = bits,
        }
    end

    ---Write a dynamic block's header after its three block-header bits.
    ---@param compressor table
    ---@param header table
    local function writeDynamicHeader(compressor, header)
        writeBits(compressor, header.literalCount - 257, 5)
        writeBits(compressor, header.distanceCount - 1, 5)
        writeBits(compressor, header.orderCount - 4, 4)
        local codeLengths = header.codeLengths
        for index = 1, header.orderCount do
            writeBits(compressor, codeLengths[CODE_LENGTH_ORDER[index]], 3)
        end
        local codes = canonicalCodes(codeLengths, CODE_LENGTH_SYMBOLS)
        local symbols, extras = header.symbols, header.extras
        for index = 1, header.symbolCount do
            local symbol = symbols[index]
            writeBits(compressor, codes[symbol], codeLengths[symbol])
            if symbol == 16 then
                writeBits(compressor, extras[index], 2)
            elseif symbol == 17 then
                writeBits(compressor, extras[index], 3)
            elseif symbol == 18 then
                writeBits(compressor, extras[index], 7)
            end
        end
    end

    ---Write the current block's tokens and its end-of-block symbol.
    ---@param compressor table
    ---@param literalCodes table<integer, integer>
    ---@param literalLengths table<integer, integer>
    ---@param distanceCodes table<integer, integer>
    ---@param distanceLengths table<integer, integer>
    local function writeTokens(
        compressor,
        literalCodes,
        literalLengths,
        distanceCodes,
        distanceLengths
    )
        local tokenValue, tokenDistance = compressor.tokenValue, compressor.tokenDistance
        for token = 1, compressor.tokenCount do
            local value = tokenValue[token]
            local distance = tokenDistance[token]
            if distance == 0 then
                writeBits(compressor, literalCodes[value], literalLengths[value])
            else
                local index = LENGTH_INDEX[value]
                local symbol = 257 + index
                writeBits(compressor, literalCodes[symbol], literalLengths[symbol])
                local extra = LENGTH_EXTRA[index]
                if extra > 0 then
                    writeBits(compressor, value - LENGTH_BASE[index], extra)
                end
                local distanceIndex = distanceSymbol(distance)
                writeBits(compressor, distanceCodes[distanceIndex], distanceLengths[distanceIndex])
                extra = DISTANCE_EXTRA[distanceIndex]
                if extra > 0 then
                    writeBits(compressor, distance - DISTANCE_BASE[distanceIndex], extra)
                end
            end
        end
        writeBits(compressor, literalCodes[END_OF_BLOCK], literalLengths[END_OF_BLOCK])
    end

    ---Emit the current block as whichever of stored, fixed and dynamic Huffman
    ---costs the fewest bits, then start the next block.
    ---@param compressor table
    ---@param final boolean
    local function flushBlock(compressor, final)
        local finalBit = final and 1 or 0
        local literalFrequencies = compressor.literalFrequencies
        local distanceFrequencies = compressor.distanceFrequencies

        local literalLengths = huffmanLengths(literalFrequencies, LITERAL_SYMBOLS, MAX_CODE_BITS)
        local distanceLengths = huffmanLengths(distanceFrequencies, DISTANCE_SYMBOLS, MAX_CODE_BITS)
        local header = dynamicHeader(literalLengths, distanceLengths)

        local fixedBits = 3 + compressor.extraBits
        local dynamicBits = 3 + header.bits + compressor.extraBits
        for symbol = 0, LITERAL_SYMBOLS - 1 do
            local frequency = literalFrequencies[symbol]
            if frequency > 0 then
                fixedBits = fixedBits + frequency * FIXED_LITERAL_LENGTHS[symbol]
                dynamicBits = dynamicBits + frequency * literalLengths[symbol]
            end
        end
        for symbol = 0, DISTANCE_SYMBOLS - 1 do
            local frequency = distanceFrequencies[symbol]
            if frequency > 0 then
                fixedBits = fixedBits + frequency * 5
                dynamicBits = dynamicBits + frequency * distanceLengths[symbol]
            end
        end
        local rawLength = compressor.covered - compressor.blockStart + 1
        local padding = (8 - (compressor.bitCount + 3) % 8) % 8
        local storedBits = 3 + padding + 32 + 8 * rawLength

        if storedBits < fixedBits and storedBits < dynamicBits then
            writeBits(compressor, finalBit, 3)
            alignToByte(compressor)
            writeBits(compressor, rawLength, 16)
            writeBits(compressor, 65535 - rawLength, 16)
            if rawLength > 0 then
                putString(
                    compressor.sink,
                    sub(compressor.input, compressor.blockStart, compressor.covered)
                )
            end
        elseif dynamicBits < fixedBits then
            writeBits(compressor, finalBit + 4, 3)
            writeDynamicHeader(compressor, header)
            writeTokens(
                compressor,
                canonicalCodes(literalLengths, LITERAL_SYMBOLS),
                literalLengths,
                canonicalCodes(distanceLengths, DISTANCE_SYMBOLS),
                distanceLengths
            )
        else
            writeBits(compressor, finalBit + 2, 3)
            writeTokens(
                compressor,
                FIXED_LITERAL_CODES,
                FIXED_LITERAL_LENGTHS,
                FIXED_DISTANCE_CODES,
                FIXED_DISTANCE_LENGTHS
            )
        end
        resetBlock(compressor)
    end

    ---End the block when it holds enough tokens or covers enough input.
    ---@param compressor table
    local function checkBlockFull(compressor)
        if
            compressor.tokenCount >= BLOCK_MAX_TOKENS
            or compressor.covered - compressor.blockStart + 1 >= BLOCK_MAX_BYTES
        then
            flushBlock(compressor, false)
        end
    end

    ---@param compressor table
    ---@param value integer the literal byte
    local function emitLiteral(compressor, value)
        local token = compressor.tokenCount + 1
        compressor.tokenValue[token] = value
        compressor.tokenDistance[token] = 0
        compressor.tokenCount = token
        local literalFrequencies = compressor.literalFrequencies
        literalFrequencies[value] = literalFrequencies[value] + 1
        compressor.covered = compressor.covered + 1
        checkBlockFull(compressor)
    end

    ---@param compressor table
    ---@param length integer 3 to 258
    ---@param distance integer 1 to 32768
    local function emitMatch(compressor, length, distance)
        local token = compressor.tokenCount + 1
        compressor.tokenValue[token] = length
        compressor.tokenDistance[token] = distance
        compressor.tokenCount = token
        local index = LENGTH_INDEX[length]
        local literalFrequencies = compressor.literalFrequencies
        literalFrequencies[257 + index] = literalFrequencies[257 + index] + 1
        local distanceIndex = distanceSymbol(distance)
        local distanceFrequencies = compressor.distanceFrequencies
        distanceFrequencies[distanceIndex] = distanceFrequencies[distanceIndex] + 1
        compressor.extraBits = compressor.extraBits
            + LENGTH_EXTRA[index]
            + DISTANCE_EXTRA[distanceIndex]
        compressor.covered = compressor.covered + length
        checkBlockFull(compressor)
    end

    ---Record `position` in the hash chain of the three bytes starting there. The
    ---key is the three bytes themselves, so every chain entry is a true
    ---three-byte match and no candidate needs re-checking.
    ---@param compressor table
    ---@param position integer
    local function insertPosition(compressor, position)
        if position + 2 > compressor.length then
            return
        end
        local data = compressor.data
        local key = (data[position] * 256 + data[position + 1]) * 256 + data[position + 2]
        local head = compressor.head
        compressor.previous[position % WINDOW_SIZE] = head[key]
        head[key] = position
    end

    ---Find the longest match for `position` that is longer than `minimum`,
    ---following at most the level's chain length back through the window.
    ---@param compressor table
    ---@param position integer
    ---@param minimum integer
    ---@return integer length 0 when nothing longer was found
    ---@return integer distance
    local function findMatch(compressor, position, minimum)
        local data = compressor.data
        local maxLength = compressor.length - position + 1
        if maxLength > MAX_MATCH then
            maxLength = MAX_MATCH
        end
        if maxLength < MIN_MATCH or minimum >= maxLength then
            return 0, 0
        end
        local key = (data[position] * 256 + data[position + 1]) * 256 + data[position + 2]
        local candidate = compressor.head[key]
        local previous = compressor.previous
        local limit = position - WINDOW_SIZE
        local chain = compressor.chain
        if minimum >= compressor.good then
            chain = floor(chain / 4)
        end
        local nice = compressor.nice
        local best, bestDistance = minimum, 0

        while candidate ~= nil and candidate >= limit and chain > 0 do
            if data[candidate + best] == data[position + best] then
                local length = MIN_MATCH
                while length < maxLength and data[candidate + length] == data[position + length] do
                    length = length + 1
                end
                if length > best then
                    best = length
                    bestDistance = position - candidate
                    if length >= nice or length >= maxLength then
                        break
                    end
                end
            end
            local earlier = previous[candidate % WINDOW_SIZE]
            if earlier == nil or earlier >= candidate then
                break
            end
            candidate = earlier
            chain = chain - 1
        end

        if bestDistance == 0 then
            return 0, 0
        end
        return best, bestDistance
    end

    ---Tokenise greedily: take every match found (levels 1 to 3).
    ---@param compressor table
    local function tokenizeGreedy(compressor)
        local data, length = compressor.data, compressor.length
        local work = compressor.work
        local position = 1
        local nextPause = PAUSE_POSITIONS
        while position <= length do
            if work.context and position >= nextPause then
                pause(work)
                nextPause = position + PAUSE_POSITIONS
            end
            local matchLength, distance = findMatch(compressor, position, MIN_MATCH - 1)
            insertPosition(compressor, position)
            if matchLength == MIN_MATCH and distance > TOO_FAR then
                matchLength = 0
            end
            if matchLength >= MIN_MATCH then
                emitMatch(compressor, matchLength, distance)
                local last = position + matchLength - 1
                if matchLength <= compressor.lazyLimit then
                    for inside = position + 1, last do
                        insertPosition(compressor, inside)
                    end
                end
                position = last + 1
            else
                emitLiteral(compressor, data[position])
                position = position + 1
            end
        end
    end

    ---Tokenise with lazy matching (levels 4 to 9): a match is held back one byte
    ---and dropped for a literal when the next position starts a longer one.
    ---@param compressor table
    local function tokenizeLazy(compressor)
        local data, length = compressor.data, compressor.length
        local work = compressor.work
        local lazyLimit = compressor.lazyLimit
        local position = 1
        local nextPause = PAUSE_POSITIONS
        local previousLength, previousDistance = 0, 0
        local pending = false
        while position <= length do
            if work.context and position >= nextPause then
                pause(work)
                nextPause = position + PAUSE_POSITIONS
            end
            local matchLength, distance = 0, 0
            if previousLength < lazyLimit then
                matchLength, distance =
                    findMatch(compressor, position, math.max(previousLength, MIN_MATCH - 1))
                if matchLength == MIN_MATCH and distance > TOO_FAR then
                    matchLength = 0
                end
            end
            insertPosition(compressor, position)

            if previousLength >= MIN_MATCH and matchLength <= previousLength then
                -- The held match, which starts at the previous position, wins.
                emitMatch(compressor, previousLength, previousDistance)
                local last = position + previousLength - 2
                for inside = position + 1, last do
                    insertPosition(compressor, inside)
                end
                position = last + 1
                pending = false
                previousLength, previousDistance = 0, 0
            else
                if pending then
                    emitLiteral(compressor, data[position - 1])
                end
                pending = true
                previousLength, previousDistance = matchLength, distance
                position = position + 1
            end
        end
        if pending then
            emitLiteral(compressor, data[position - 1])
        end
    end

    -- Below this many input bytes the compressor skips matching and writes
    -- one fixed-Huffman block of literals (or a stored block, when smaller).
    -- Short addon messages rarely repeat anything, and the full path would
    -- allocate several kilobytes of hash, token and code tables per call.
    local TINY_INPUT_BYTES = 64

    ---Compress a short input as one literal-only fixed block, or one stored
    ---block when that is smaller, without the matcher's working tables.
    ---@param work table
    ---@param sink table
    ---@param input string
    ---@param length integer
    local function compressTiny(work, sink, input, length)
        local fixedBits = 3 + FIXED_LITERAL_LENGTHS[END_OF_BLOCK]
        for index = 1, length do
            fixedBits = fixedBits + FIXED_LITERAL_LENGTHS[byte(input, index)]
        end
        local storedBits = 3 + 5 + 32 + 8 * length

        local writer = leaseTable(work.pooled)
        writer.sink = sink
        writer.bitBuffer = 0
        writer.bitCount = 0
        if storedBits < fixedBits then
            writeBits(writer, 1, 3)
            alignToByte(writer)
            writeBits(writer, length, 16)
            writeBits(writer, 65535 - length, 16)
            putString(sink, input)
        else
            writeBits(writer, 3, 3)
            for index = 1, length do
                local value = byte(input, index)
                writeBits(writer, FIXED_LITERAL_CODES[value], FIXED_LITERAL_LENGTHS[value])
            end
            writeBits(
                writer,
                FIXED_LITERAL_CODES[END_OF_BLOCK],
                FIXED_LITERAL_LENGTHS[END_OF_BLOCK]
            )
            alignToByte(writer)
        end
        returnTable(work.pooled, writer)
    end

    ---Compress `input` as raw DEFLATE into `sink`.
    ---@param work table
    ---@param sink table
    ---@param input string
    ---@param level integer 1 to 9
    function compressInto(work, sink, input, level)
        local settings = LEVELS[level]
        local length = #input
        if length < TINY_INPUT_BYTES then
            compressTiny(work, sink, input, length)
            return
        end
        local data = {}
        for index = 1, length, 8 do
            local a, b, c, d, e, f, g, h = byte(input, index, index + 7)
            data[index], data[index + 1], data[index + 2], data[index + 3] = a, b, c, d
            data[index + 4], data[index + 5], data[index + 6], data[index + 7] = e, f, g, h
        end

        local compressor = {
            work = work,
            sink = sink,
            input = input,
            data = data,
            length = length,
            head = {},
            previous = {},
            chain = settings.chain,
            good = settings.good,
            nice = settings.nice,
            lazyLimit = settings.lazyLimit,
            tokenValue = {},
            tokenDistance = {},
            tokenCount = 0,
            literalFrequencies = {},
            distanceFrequencies = {},
            extraBits = 0,
            covered = 0,
            blockStart = 1,
            bitBuffer = 0,
            bitCount = 0,
        }
        resetBlock(compressor)
        if settings.lazy then
            tokenizeLazy(compressor)
        else
            tokenizeGreedy(compressor)
        end
        flushBlock(compressor, true)
        alignToByte(compressor)
    end

    -- Decompressor ---------------------------------------------------------------
    --
    -- A reader record holds the input, the next byte position and a bit buffer
    -- that is refilled one byte at a time. Every read is bounds-checked, so a
    -- malformed stream ends in a reason, never in a Lua error.

    ---Make at least `wanted` bits available; `false` when the input ends first
    ---(whatever could be read stays in the buffer).
    ---@param reader table
    ---@param wanted integer
    ---@return boolean
    local function fillBits(reader, wanted)
        local count = reader.bitCount
        if count >= wanted then
            return true
        end
        local input, position, buffer = reader.input, reader.position, reader.bitBuffer
        local available = true
        while count < wanted do
            local value = byte(input, position)
            if value == nil then
                available = false
                break
            end
            buffer = buffer + value * POW2[count]
            count = count + 8
            position = position + 1
        end
        reader.position, reader.bitBuffer, reader.bitCount = position, buffer, count
        return available
    end

    ---Read `count` bits as an integer, least significant first; `nil` when the
    ---input ends.
    ---@param reader table
    ---@param count integer
    ---@return integer|nil
    local function readBits(reader, count)
        if count == 0 then
            return 0
        end
        if not fillBits(reader, count) then
            return nil
        end
        local scale = POW2[count]
        local buffer = reader.bitBuffer
        local value = buffer % scale
        reader.bitBuffer = (buffer - value) / scale
        reader.bitCount = reader.bitCount - count
        return value
    end

    ---Decode one Huffman symbol.
    ---@param reader table
    ---@param decoder table
    ---@return integer|nil symbol
    ---@return string|nil reason
    local function readSymbol(reader, decoder)
        local maxLength = decoder.maxLength
        fillBits(reader, maxLength)
        local buffer, available = reader.bitBuffer, reader.bitCount
        local lookup = decoder.lookup
        local longest = maxLength
        if available < longest then
            longest = available
        end
        for length = decoder.minLength, longest do
            local scale = POW2[length]
            local low = buffer % scale
            local symbol = lookup[scale + low]
            if symbol ~= nil then
                reader.bitBuffer = (buffer - low) / scale
                reader.bitCount = available - length
                return symbol
            end
        end
        if available < maxLength then
            return nil, REASON.truncated
        end
        return nil, REASON.malformedDeflate
    end

    ---Read a dynamic block's code tables (RFC 1951 3.2.7).
    ---@param reader table
    ---@return table|nil literalDecoder `nil` when the tables are refused
    ---@return table|false|nil distanceDecoder `false` when the block has no distance codes
    ---@return string|nil reason
    local function readDynamicTables(reader)
        local literalCount = readBits(reader, 5)
        local distanceCount = readBits(reader, 5)
        local orderCount = readBits(reader, 4)
        if literalCount == nil or distanceCount == nil or orderCount == nil then
            return nil, nil, REASON.truncated
        end
        literalCount = literalCount + 257
        distanceCount = distanceCount + 1
        orderCount = orderCount + 4
        if literalCount > LITERAL_SYMBOLS or distanceCount > DISTANCE_SYMBOLS then
            return nil, nil, REASON.malformedDeflate
        end

        local codeLengths = {}
        for symbol = 0, CODE_LENGTH_SYMBOLS - 1 do
            codeLengths[symbol] = 0
        end
        for index = 1, orderCount do
            local length = readBits(reader, 3)
            if length == nil then
                return nil, nil, REASON.truncated
            end
            codeLengths[CODE_LENGTH_ORDER[index]] = length
        end
        local codeLengthDecoder = buildDecoder(codeLengths, CODE_LENGTH_SYMBOLS)
        if not codeLengthDecoder then
            return nil, nil, REASON.malformedDeflate
        end

        local lengths = {}
        local total = literalCount + distanceCount
        local index = 0
        while index < total do
            local symbol, reason = readSymbol(reader, codeLengthDecoder)
            if symbol == nil then
                return nil, nil, reason
            end
            if symbol < 16 then
                lengths[index] = symbol
                index = index + 1
            else
                local repeated, extra
                if symbol == 16 then
                    if index == 0 then
                        return nil, nil, REASON.malformedDeflate
                    end
                    repeated = lengths[index - 1]
                    extra = readBits(reader, 2)
                    extra = extra and extra + 3
                elseif symbol == 17 then
                    repeated = 0
                    extra = readBits(reader, 3)
                    extra = extra and extra + 3
                else
                    repeated = 0
                    extra = readBits(reader, 7)
                    extra = extra and extra + 11
                end
                if extra == nil then
                    return nil, nil, REASON.truncated
                end
                if index + extra > total then
                    return nil, nil, REASON.malformedDeflate
                end
                for _ = 1, extra do
                    lengths[index] = repeated
                    index = index + 1
                end
            end
        end

        if lengths[END_OF_BLOCK] == 0 then
            return nil, nil, REASON.malformedDeflate
        end
        local distanceLengths = {}
        for symbol = 0, distanceCount - 1 do
            distanceLengths[symbol] = lengths[literalCount + symbol]
        end
        local literalDecoder = buildDecoder(lengths, literalCount)
        local distanceDecoder = buildDecoder(distanceLengths, distanceCount)
        if not literalDecoder or distanceDecoder == nil then
            return nil, nil, REASON.malformedDeflate
        end
        return literalDecoder, distanceDecoder
    end

    ---Inflate one Huffman-coded block into `output`.
    ---@param work table
    ---@param reader table
    ---@param output integer[]
    ---@param outputLength integer
    ---@param literalDecoder table
    ---@param distanceDecoder table|false|nil
    ---@return integer|nil outputLength
    ---@return string|nil reason
    local function inflateCodes(work, reader, output, outputLength, literalDecoder, distanceDecoder)
        local limit = work.maxOutputBytes
        local context = work.context
        local untilPause = PAUSE_SYMBOLS
        while true do
            if context then
                untilPause = untilPause - 1
                if untilPause == 0 then
                    pause(work)
                    untilPause = PAUSE_SYMBOLS
                end
            end
            local symbol, reason = readSymbol(reader, literalDecoder)
            if symbol == nil then
                return nil, reason
            end
            if symbol < END_OF_BLOCK then
                if outputLength >= limit then
                    return nil, REASON.maxOutputBytes
                end
                outputLength = outputLength + 1
                output[outputLength] = symbol
            elseif symbol == END_OF_BLOCK then
                return outputLength
            else
                local index = symbol - 257
                if index > 28 or not distanceDecoder then
                    return nil, REASON.malformedDeflate
                end
                local extra = readBits(reader, LENGTH_EXTRA[index])
                if extra == nil then
                    return nil, REASON.truncated
                end
                local length = LENGTH_BASE[index] + extra
                local distanceIndex
                distanceIndex, reason = readSymbol(reader, distanceDecoder)
                if distanceIndex == nil then
                    return nil, reason
                end
                if distanceIndex >= DISTANCE_SYMBOLS then
                    return nil, REASON.malformedDeflate
                end
                extra = readBits(reader, DISTANCE_EXTRA[distanceIndex])
                if extra == nil then
                    return nil, REASON.truncated
                end
                local distance = DISTANCE_BASE[distanceIndex] + extra
                if distance > outputLength then
                    return nil, REASON.malformedDeflate
                end
                if outputLength + length > limit then
                    return nil, REASON.maxOutputBytes
                end
                local from = outputLength - distance
                for offset = 1, length do
                    output[outputLength + offset] = output[from + offset]
                end
                outputLength = outputLength + length
            end
        end
    end

    ---Copy one stored block into `output`.
    ---@param work table
    ---@param reader table
    ---@param output integer[]
    ---@param outputLength integer
    ---@return integer|nil outputLength
    ---@return string|nil reason
    local function inflateStored(work, reader, output, outputLength)
        local drop = reader.bitCount % 8
        if drop > 0 then
            readBits(reader, drop)
        end
        local length = readBits(reader, 16)
        local complement = readBits(reader, 16)
        if length == nil or complement == nil then
            return nil, REASON.truncated
        end
        if length + complement ~= 65535 then
            return nil, REASON.malformedDeflate
        end
        -- Give back the whole bytes the bit buffer read ahead: they are the first
        -- bytes of the stored data.
        local position = reader.position - reader.bitCount / 8
        reader.bitBuffer, reader.bitCount = 0, 0
        if position + length - 1 > reader.inputLength then
            return nil, REASON.truncated
        end
        if outputLength + length > work.maxOutputBytes then
            return nil, REASON.maxOutputBytes
        end
        local input = reader.input
        for offset = 0, length - 1 do
            output[outputLength + 1 + offset] = byte(input, position + offset)
        end
        reader.position = position + length
        return outputLength + length
    end

    ---Inflate a raw DEFLATE stream into `sink`.
    ---@param work table
    ---@param sink table
    ---@param input string
    ---@return boolean ok
    ---@return string|nil reason
    function inflateInto(work, sink, input)
        local reader = {
            input = input,
            inputLength = #input,
            position = 1,
            bitBuffer = 0,
            bitCount = 0,
        }
        local output = {}
        local outputLength = 0
        local final = false
        while not final do
            local header = readBits(reader, 3)
            if header == nil then
                return false, REASON.truncated
            end
            final = header % 2 == 1
            local blockType = (header - header % 2) / 2
            local newLength, reason
            if blockType == 0 then
                newLength, reason = inflateStored(work, reader, output, outputLength)
            elseif blockType == 1 then
                newLength, reason = inflateCodes(
                    work,
                    reader,
                    output,
                    outputLength,
                    FIXED_LITERAL_DECODER,
                    FIXED_DISTANCE_DECODER
                )
            elseif blockType == 2 then
                local literalDecoder, distanceDecoder, tableReason = readDynamicTables(reader)
                if literalDecoder == nil then
                    return false, tableReason
                end
                newLength, reason = inflateCodes(
                    work,
                    reader,
                    output,
                    outputLength,
                    literalDecoder,
                    distanceDecoder
                )
            else
                return false, REASON.malformedDeflate
            end
            if newLength == nil then
                return false, reason
            end
            outputLength = newLength
        end

        local unread = floor(reader.bitCount / 8)
        if reader.position - 1 - unread < reader.inputLength then
            return false, REASON.trailingData
        end

        for first = 1, outputLength, SINK_BATCH_SIZE do
            local last = first + SINK_BATCH_SIZE - 1
            if last > outputLength then
                last = outputLength
            end
            appendFragment(sink, char(unpack(output, first, last)))
        end
        return true
    end
end

-- Compression stage ----------------------------------------------------------

---Compress `bytes` into a string, bounded by `maxOutputBytes` on both sides.
---@param work table
---@param bytes string
---@param level integer
---@return boolean ok
---@return string bytesOrReason
local function compressBytes(work, bytes, level)
    if #bytes > work.maxOutputBytes then
        return false, REASON.maxOutputBytes
    end
    local sink = openSink(work.pooled)
    compressInto(work, sink, bytes, level)
    local result = finishSink(sink)
    if #result > work.maxOutputBytes then
        return false, REASON.maxOutputBytes
    end
    return true, result
end

---Inflate `bytes` into a string, bounded by `maxOutputBytes`.
---@param work table
---@param bytes string
---@return boolean ok
---@return string bytesOrReason
local function decompressBytes(work, bytes)
    if #bytes > work.maxOutputBytes then
        return false, REASON.maxOutputBytes
    end
    local sink = openSink(work.pooled)
    local ok, reason = inflateInto(work, sink, bytes)
    if not ok then
        closeSink(sink)
        return false, reason --[[@as string]]
    end
    return true, finishSink(sink)
end

-- Addon channel --------------------------------------------------------------
--
-- The addon channel cannot carry NUL, line feed, carriage return or the pipe
-- that introduces the client's escape sequences. Each of those, and the escape
-- byte 255 itself, becomes 255 followed by one ASCII digit. Every other byte
-- passes through unchanged.

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
local ADDON_FORBIDDEN_PATTERN = "[%z\n\r|]"
local ADDON_BAD_ESCAPE_PATTERN = "\255[^0-4]"
local ADDON_SEQUENCE_PATTERN = "\255[0-4]"

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

---@param work table
---@param text string
---@return boolean ok
---@return string bytesOrReason
local function decodeForAddon(work, text)
    if #text > work.maxOutputBytes then
        return false, REASON.maxOutputBytes
    end
    if find(text, ADDON_FORBIDDEN_PATTERN) then
        return false, REASON.forbiddenByte
    end
    if find(text, ADDON_BAD_ESCAPE_PATTERN) or byte(text, -1) == ADDON_ESCAPE_BYTE then
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
local PRINT_CODES = {}
local PRINT_DIGITS = {}
do
    local digit = 0
    for code = 33, 126 do
        if not PRINT_EXCLUDED[code] then
            PRINT_CODES[digit] = code
            PRINT_DIGITS[code] = digit
            digit = digit + 1
        end
    end
    if digit ~= PRINT_BASE then
        error("MoltenCodes CodecKit print alphabet must have 85 characters", 2)
    end
end
local PRINT_ALPHABET = char(unpack(PRINT_CODES, 0, PRINT_BASE - 1))
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
    return floor(flags / flag) % 2 == 1
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
    local ok, body = serializeBody(work, value, count)
    if not ok then
        return false, body
    end
    local flags = FLAG_SERIALIZED
    if compress == "deflate" then
        flags = flags + FLAG_DEFLATE
        ok, body = compressBytes(work, body, level)
        if not ok then
            return false, body
        end
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

    local ok, flags, body, reason
    if first == FORMAT_VERSION then
        flags = byte(text, 2)
        reason = checkFlags(flags)
        if reason == nil and hasFlag(flags, FLAG_PRINT) then
            reason = REASON.malformedHeader
        end
        if reason ~= nil then
            return false, reason
        end
        body = sub(text, 3)
        if hasFlag(flags, FLAG_ADDON) then
            ok, body = decodeForAddon(work, body)
            if not ok then
                return false, body
            end
        end
    elseif PRINT_DIGITS[first] ~= nil or WHITESPACE[first] then
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
        ok, body = decompressBytes(work, body)
        if not ok then
            return false, body
        end
    end
    return deserializeBody(work, body, allowList)
end

---Look for a secret anywhere in `value` before an asynchronous encode is
---scheduled, so the refusal is raised at the caller. Bounded like the encoder:
---it stops at `maxDepth` and after `maxValues` values, where the encoder
---itself refuses.
---@param work table
---@param value any
---@param depth integer
---@return boolean
local function containsSecret(work, value, depth)
    if work.isSecret(value) then
        return true
    end
    if type(value) ~= "table" or depth >= work.maxDepth then
        return false
    end
    local key = next(value)
    while type(key) ~= "nil" do
        work.valueCount = work.valueCount + 2
        if work.valueCount > work.maxValues then
            return false
        end
        if
            containsSecret(work, key, depth + 1)
            or containsSecret(work, rawget(value, key), depth + 1)
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
    if receiver ~= CodecKit then
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

---Refuse option keys outside `known`.
---@param options table
---@param known table<string, true>
---@param label string
---@param level integer
local function validateOptionKeys(options, known, label, level)
    local key = next(options)
    while key ~= nil do
        if type(key) ~= "string" or known[key] ~= true then
            error(label .. " options." .. tostring(key) .. " is not a recognised option", level)
        end
        key = next(options, key)
    end
end

---@param level any
---@param label string
---@param errorLevel integer
---@return integer
local function readLevel(level, label, errorLevel)
    if level == nil then
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
    if channel ~= nil and (type(channel) ~= "string" or CHANNELS[channel] ~= true) then
        error(label .. ' options.channel must be "none", "addon" or "print"', level)
    end
    return channel
end

---Validate encode options and return the stages they select.
---@param options any
---@param label string
---@param level integer
---@return string compress
---@return string channel
---@return integer compressionLevel
local function readEncodeOptions(options, label, level)
    if options == nil then
        return "none", "none", DEFAULT_LEVEL
    end
    if type(options) ~= "table" then
        error(label .. " options must be a table or nil", level)
    end
    validateOptionKeys(options, ENCODE_OPTION_KEYS, label, level + 1)
    local compress = rawget(options, "compress")
    if compress == nil then
        compress = "none"
    elseif type(compress) ~= "string" or COMPRESSIONS[compress] ~= true then
        error(label .. ' options.compress must be "none" or "deflate"', level)
    end
    local channel = readChannel(rawget(options, "channel"), label, level + 1) or "none"
    return compress, channel, readLevel(rawget(options, "level"), label, level + 1)
end

---Validate decode options and return the channel a frame must use, if any.
---@param options any
---@param label string
---@param level integer
---@return string|nil
local function readDecodeOptions(options, label, level)
    if options == nil then
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
    if SchedulerKit == nil then
        error(
            label
                .. " requires SchedulerKit API 1, which is not loaded ("
                .. tostring(reason)
                .. ")",
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
    local key = next(limits)
    while key ~= nil do
        if type(key) ~= "string" or LIMIT_CEILINGS[key] == nil then
            error(
                "CodecKit:SetLimits limits." .. tostring(key) .. " is not a recognised limit",
                level
            )
        end
        local value = rawget(limits, key)
        local ceiling = LIMIT_CEILINGS[key]
        if type(value) ~= "number" or value % 1 ~= 0 or value < 1 or value > ceiling then
            error(
                "CodecKit:SetLimits limits." .. key .. " must be an integer from 1 to " .. ceiling,
                level
            )
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
    local compress, channel, level = readEncodeOptions(options, "CodecKit:Encode", 3)
    local work = openWork(true)
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
    local compress, channel, level = readEncodeOptions(options, "CodecKit:EncodeMany", 3)
    local count = select("#", ...)
    local values = { ... }
    local work = openWork(true)
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
    local ok, result = serializeBody(work, value, nil)
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
    local ok, value = deserializeBody(work, bytes, false)
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
    validateBytes(bytes, "CodecKit:Compress bytes", 3)
    local level = DEFAULT_LEVEL
    if options ~= nil then
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
    local compressName, channel, level = readEncodeOptions(options, label, 3)
    validateAsyncTarget(scope, callback, label, 3)
    local work = openWork(false)
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

---Change any subset of the shared limits. Affects every consumer.
---@param self CodecKit
---@param limits table
local function setLimits(self, limits)
    validateFacade(self, "CodecKit:SetLimits", 3)
    validateLimitUpdate(limits, 3)
    for index = 1, #LIMIT_NAMES do
        local name = LIMIT_NAMES[index]
        local value = rawget(limits, name)
        if value ~= nil then
            rawset(sharedLimits, name, value)
        end
    end
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
    }
end

-- Commit ---------------------------------------------------------------------

rawset(CodecKit, "API", API_GENERATION)
rawset(CodecKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(CodecKit, "FORMAT_VERSION", FORMAT_VERSION)
rawset(CodecKit, "PRINT_ALPHABET", PRINT_ALPHABET)
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
rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(CodecKit) or not validateCurrentState(CodecKit) then
    error("MoltenCodes CodecKit package state is corrupted or incomplete", 2)
end

return CodecKit
