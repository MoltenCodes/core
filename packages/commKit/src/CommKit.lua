-- MoltenCodes CommKit
--
-- Addon messaging of arbitrary length for World of Warcraft addons:
--
--   prefixes       `scope:Register(prefix, callback)` registers the prefix with
--                  the client on first use and delivers whole messages only.
--   chunking       a message longer than one addon message travels as a first,
--                  middle and last chunk carrying a stream id and an index; the
--                  protocol is specified byte by byte in `docs/API.md`.
--   reassembly     bounded in streams, bytes per sender, streams in flight per
--                  sender and time; dropped streams are reported at most once
--                  per sender per minute.
--   queues         three priorities (ALERT, NORMAL, BULK) with per-destination
--                  round-robin inside each, bounded in messages and bytes; a
--                  send that would pass a bound is refused with a named reason.
--   budget         one token bucket shared by every scope and every embedded
--                  copy, degraded at low frame rates and after zoning, charged
--                  for traffic other code sends when HookKit is present.
--   SyncSet        named fields versioned by a content hash; a request carries
--                  the hashes the requester holds and the answer carries only
--                  the fields that differ.
--
-- The send driver is a SchedulerKit job that exists only while something is
-- queued, so an idle CommKit costs no per-frame handler.
--
-- CommKit needs Registry API 2, SignalKit API 1, EventKit API 1, LifecycleKit
-- API 1, SchedulerKit API 1 and PoolKit API 1. TimerKit API 1 is in
-- SchedulerKit's dependency closure and is found through `Registry:Find` when
-- first needed. CodecKit API 1 (SyncSet payloads and hashes), HookKit API 1
-- (the outside-traffic hook) and SchemaKit API 1 (SyncSet validation) are
-- optional and found at call time.
--
-- Contents
-- --------
--   Constants ............. identity, wire protocol, bounds, defaults, reasons
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, the required Kits, the host clock
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Host access ........... errors, secrets, isolated calls, the chat API
--   Argument checks ....... receivers, strings, callbacks, option tables
--   Found packages ........ TimerKit, CodecKit, HookKit, SchemaKit
--   Kit-owned scopes ...... the EventKit, TimerKit and SchedulerKit scopes
--   Budget ................ the shared token bucket and its degraded modes
--   Queues and pipes ...... priorities, destinations, bounds
--   Send completion ....... terminal states and their callbacks
--   Driver ................ the job that turns queued messages into chunks
--   Outside traffic ....... the HookKit secure hooks on the client's senders
--   Reassembly ............ receiving, streams, expiry, peer eviction
--   Registrations ......... prefixes, connections, delivery
--   Content hashes ........ FNV-1a over a canonical encoding
--   SyncSet ............... fields, request, ack, deliver
--   Send path ............. request validation, queueing, cancellation, close
--   Public methods ........ method tables for connections, send handles,
--                           SyncSets and scopes
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment and self-check
--
-- Layout and invariants are described in `docs/INTERNALS.md`.

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "commKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 1

-- The API generation of every package CommKit uses: required (Registry,
-- SignalKit, EventKit, LifecycleKit, SchedulerKit, PoolKit), found through
-- SchedulerKit's closure (TimerKit) and optional (CodecKit, HookKit,
-- SchemaKit).
local DEPENDENCY_API = {
    registry = 2,
    signalKit = 1,
    eventKit = 1,
    lifecycleKit = 1,
    schedulerKit = 1,
    poolKit = 1,
    timerKit = 1,
    codecKit = 1,
    hookKit = 1,
    schemaKit = 1,
}

-- The package state layout, and the layout every scope, handle, connection
-- and SyncSet carries, so a later revision that changes a layout can upgrade
-- old objects.
local LAYOUT = { state = 1, scope = 1, handle = 1, connection = 1, syncSet = 1 }

-- Wire protocol. The client carries at most 255 bytes of text per addon
-- message. Every message CommKit sends starts with one control byte; a chunk
-- of a longer message, and the abort that ends a cancelled one, add a stream
-- id byte and a two-digit number. The channel cannot carry NUL, line feed,
-- carriage return or the pipe that introduces the client's UI escape
-- sequences. Prefixes are at most 16 bytes.
--
-- Stream ids and chunk numbers are digits in one of two schemes. On the
-- ordinary channel a digit is a byte in 0x80..0xFF: every one survives the
-- channel and none is a control byte. The logged channel may insist on valid
-- UTF-8 text, which bytes above 0x7F alone are not, so there a digit is a
-- printable ASCII byte in 0x30..0x7A (below the pipe, 0x7C).
local WIRE = {
    maxMessageBytes = 255,
    single = 0x01,
    first = 0x02,
    middle = 0x03,
    last = 0x04,
    abort = 0x05,
    chunkHeaderBytes = 4,
    forbiddenBytePattern = "[%z\n\r|]",
    maxPrefixBytes = 16,
    plain = { offset = 0x80, radix = 128 },
    logged = { offset = 0x30, radix = 75 },
}
WIRE.singlePayloadBytes = WIRE.maxMessageBytes - 1
WIRE.chunkPayloadBytes = WIRE.maxMessageBytes - WIRE.chunkHeaderBytes
WIRE.plain.maxChunks = WIRE.plain.radix * WIRE.plain.radix - 1
WIRE.logged.maxChunks = WIRE.logged.radix * WIRE.logged.radix - 1
WIRE.singleControlText = string.char(WIRE.single)
-- What a message whose size cannot be read (a secret argument) is charged:
-- the most one addon message can cost.
WIRE.unknownSizeBytes = WIRE.maxPrefixBytes + WIRE.maxMessageBytes

-- Distributions the client accepts for addon messages, and the two that need
-- a target.
local DISTRIBUTIONS = {
    PARTY = true,
    RAID = true,
    INSTANCE_CHAT = true,
    GUILD = true,
    OFFICER = true,
    WHISPER = true,
    CHANNEL = true,
    YELL = true,
    SAY = true,
}
local TARGETED_DISTRIBUTIONS = { WHISPER = true, CHANNEL = true }

-- Streams received on these distributions come from group members, so a
-- sender who leaves the group can have them evicted.
local GROUP_DISTRIBUTIONS = { PARTY = true, RAID = true, INSTANCE_CHAT = true }

-- Priorities. A persistent weighted rotation serves them chunk by chunk:
-- ALERT four times, NORMAL twice and BULK once per turn of seven, skipping a
-- priority with nothing ready, so BULK is slowed and never starved.
local PRIORITY = { ALERT = "ALERT", NORMAL = "NORMAL", BULK = "BULK" }
local PRIORITY_ROTATION = {
    PRIORITY.ALERT,
    PRIORITY.ALERT,
    PRIORITY.ALERT,
    PRIORITY.ALERT,
    PRIORITY.NORMAL,
    PRIORITY.NORMAL,
    PRIORITY.BULK,
}

-- The most registrations one scope holds at once.
local MAX_REGISTRATIONS = 32

-- Send handle states.
local SEND_STATE = {
    queued = "queued",
    sending = "sending",
    sent = "sent",
    cancelled = "cancelled",
    failed = "failed",
}

-- Refusal reasons.
local REASON = {
    queueFull = "queueFull",
    tooLarge = "tooLarge",
    closed = "closed",
    forbiddenByte = "forbiddenByte",
    badDistribution = "badDistribution",
    unavailable = "unavailable",
    full = "full",
    cancelled = "cancelled",
    shutdown = "shutdown",
    schema = "schema",
}

-- Why a received stream was dropped or refused, as the statistics and the
-- aggregated error report name it, in the order the report lists them.
local DROP = {
    expired = "expired",
    departed = "departed",
    malformed = "malformed",
    restarted = "restarted",
    quota = "quota",
    aborted = "aborted",
    discarded = "discarded",
}

-- The client's result codes, used when `Enum` is absent, and the reasons a
-- refused prefix registration reports without `Enum`.
local CLIENT_RESULT = {
    sendSuccess = 0,
    sendAddonThrottle = 3,
    sendChannelThrottle = 8,
    registerSuccess = 0,
    registerDuplicate = 1,
    registerNames = { [2] = "invalidPrefix", [3] = "maxPrefixes" },
}

-- The degraded modes and the throttle backoff.
--
-- Traffic sent by other code may drive the bucket below zero, down to
-- `debtSeconds` of the full rate, so it is repaid before CommKit sends again.
-- Below 20 frames per second the bucket refills at half the rate; for five
-- seconds after PLAYER_ENTERING_WORLD it refills at a tenth and holds at most
-- half a second of the full rate. A pipe the client throttled is set aside
-- for 0.35 s, doubling on every consecutive throttle of that pipe up to
-- 5.6 s, and reset by a send that succeeds. One driver run sends at most 32
-- chunks and continues on the next frame; the bucket's burst normally ends a
-- run long before. A timer that wakes within a millisecond of its due time
-- counts as due, as in SchedulerKit.
local POLICY = {
    debtSeconds = 2,
    lowFrameRate = 20,
    lowFrameRateFactor = 0.5,
    zoningSeconds = 5,
    zoningFactor = 0.1,
    zoningCapacitySeconds = 0.5,
    frameRateSampleSeconds = 1,
    modeNormal = "normal",
    modeLowFrameRate = "lowFrameRate",
    modeZoning = "zoning",
    throttleBackoffSeconds = 0.35,
    maxThrottleBackoffSeconds = 5.6,
    maxChunksPerRun = 32,
    dueToleranceSeconds = 0.001,
    -- Dropped streams are reported at most once per sender per minute, and
    -- at most this many senders are tracked; the rest share one entry.
    dropReportSeconds = 60,
    maxDropReportSenders = 64,
    otherSenders = "(other senders)",
    dropReportOrder = { "expired", "departed", "malformed", "restarted", "quota" },
}

-- SyncSet verbs (the first element of every SyncSet message) and bounds.
local SYNC = {
    request = 1,
    ack = 2,
    deliver = 3,
    maxFields = 32,
    maxFieldNameBytes = 64,
    maxPeers = 64,
    maxListeners = 16,
    replyIntervalSeconds = 1,
    -- Text bytes of SyncSet replies queued at once, across every SyncSet.
    maxReplyBytes = 8192,
    -- CodecKit options for SyncSet frames.
    codecOptions = { channel = "addon" },
}

-- FNV-1a, 32 bits. The prime 16777619 is 2^24 + 403, which is what lets the
-- multiplication modulo 2^32 stay exact in double arithmetic.
local FNV = {
    offsetBasis = 2166136261,
    primeLow = 403,
    twoPow24 = 16777216,
    twoPow32 = 4294967296,
    -- The canonical encoding brackets a table with two bytes CodecKit's
    -- serialiser never uses as type bytes.
    canonicalOpen = string.char(0x0C),
    canonicalClose = string.char(0x0D),
}

-- Limits: the defaults, and the range SetLimits accepts for each. The largest
-- byte bounds, 1048576, cap a message at 4178 chunks, below the 5624 the
-- logged channel's header can number, so `Send` never needs to count chunks
-- against the header.
local DEFAULT_LIMITS = {
    maxQueuedBytes = 65536,
    maxQueuedMessages = 256,
    maxReassemblyStreams = 64,
    maxReassemblyBytesPerSender = 16384,
    maxInFlightPerSender = 4,
    reassemblyTimeout = 30,
    maxCps = 800,
    burst = 4000,
    messageOverhead = 40,
}
local LIMIT_NAMES = {
    "maxQueuedBytes",
    "maxQueuedMessages",
    "maxReassemblyStreams",
    "maxReassemblyBytesPerSender",
    "maxInFlightPerSender",
    "reassemblyTimeout",
    "maxCps",
    "burst",
    "messageOverhead",
}
local LIMIT_RANGES = {
    maxQueuedBytes = { minimum = 1, maximum = 1048576, integer = true },
    maxQueuedMessages = { minimum = 1, maximum = 4096, integer = true },
    maxReassemblyStreams = { minimum = 1, maximum = 1024, integer = true },
    maxReassemblyBytesPerSender = { minimum = 1, maximum = 1048576, integer = true },
    maxInFlightPerSender = { minimum = 1, maximum = 64, integer = true },
    reassemblyTimeout = { minimum = 1, maximum = 600, integer = false },
    maxCps = { minimum = 1, maximum = 100000, integer = true },
    burst = { minimum = WIRE.maxMessageBytes, maximum = 1000000, integer = true },
    messageOverhead = { minimum = 0, maximum = 255, integer = true },
}

-- Statistics counters, in the order GetStatistics copies them.
local STATISTIC_NAMES = {
    "messagesQueued",
    "messagesSent",
    "messagesCancelled",
    "messagesFailed",
    "refusedQueueFull",
    "refusedTooLarge",
    "refusedClosed",
    "refusedForbiddenByte",
    "refusedBadDistribution",
    "refusedUnavailable",
    "chunksSent",
    "bytesSent",
    "throttled",
    "outsideMessages",
    "outsideBytes",
    "messagesReceived",
    "chunksReceived",
    "bytesReceived",
    "chunksRefused",
    "streamsOpened",
    "streamsCompleted",
    "streamsExpired",
    "streamsEvicted",
    "streamsMalformed",
    "streamsRestarted",
    "streamsAborted",
    "streamsDiscarded",
    "chunksRefusedQuota",
    "secretsDropped",
    "syncRequests",
    "syncAcknowledgements",
    "syncDeliveries",
    "syncRejected",
    "syncReplyDropped",
}

-- The statistics counter a refusal, a terminal send state and a dropped
-- stream each increment.
local STATISTIC_FOR = {
    refusal = {
        [REASON.queueFull] = "refusedQueueFull",
        [REASON.tooLarge] = "refusedTooLarge",
        [REASON.closed] = "refusedClosed",
        [REASON.forbiddenByte] = "refusedForbiddenByte",
        [REASON.badDistribution] = "refusedBadDistribution",
        [REASON.unavailable] = "refusedUnavailable",
    },
    terminal = {
        [SEND_STATE.sent] = "messagesSent",
        [SEND_STATE.cancelled] = "messagesCancelled",
        [SEND_STATE.failed] = "messagesFailed",
    },
    drop = {
        [DROP.expired] = "streamsExpired",
        [DROP.departed] = "streamsEvicted",
        [DROP.malformed] = "streamsMalformed",
        [DROP.restarted] = "streamsRestarted",
        [DROP.quota] = "chunksRefusedQuota",
        [DROP.aborted] = "streamsAborted",
        [DROP.discarded] = "streamsDiscarded",
    },
}

-- The complete sets of fields the option tables accept. File-local constants
-- keep option validation allocation-free.
local OPTION_KEYS = {
    sendRequest = {
        prefix = true,
        text = true,
        distribution = true,
        target = true,
        priority = true,
        constraints = true,
        onProgress = true,
        onComplete = true,
    },
    constraints = { logged = true, battleNet = true },
    syncSet = { fields = true, schema = true },
}

-- Table pool retention. Pools hold records between uses, never more.
local POOL_RETAINED = { records = 64, streams = 32 }

-- Options every send driver job is created with.
local DRIVER_JOB_OPTIONS = { name = "CommKit send driver" }

-- The published surface, listed once so the public-surface predicate reads as
-- a checklist.
local SURFACE = {
    facade = {
        "CreateScope",
        "ForAddon",
        "CloseAddonScopes",
        "GetQueueDepth",
        "GetBudget",
        "SetLimits",
        "GetLimits",
        "GetStatistics",
    },
    scope = {
        "Register",
        "Send",
        "SyncSet",
        "UnregisterAll",
        "CancelAll",
        "Close",
        "IsClosed",
        "GetAddonName",
        "GetRegistrationCount",
        "GetPendingCount",
    },
    connection = { "Disconnect", "IsConnected", "GetPrefix" },
    handle = { "Cancel", "GetState", "GetBytesSent", "GetBytesTotal" },
    syncSet = { "Set", "Get", "GetHash", "GetRemote", "Request", "OnChanged", "Close", "IsClosed" },
}

-- Public types ---------------------------------------------------------------
--
-- CommKit publishes its methods by writing them onto Registry-owned prototype
-- tables, so the editor-facing contract is declared here as LuaCATS classes
-- rather than inferred from those assignments.

---A send priority: `"ALERT"`, `"NORMAL"` or `"BULK"`.
---@alias CommKit.PriorityName "ALERT"|"NORMAL"|"BULK"

---A distribution the client accepts for addon messages.
---@alias CommKit.Distribution "PARTY"|"RAID"|"INSTANCE_CHAT"|"GUILD"|"OFFICER"|"WHISPER"|"CHANNEL"|"YELL"|"SAY"

---The state of one send: `queued`, `sending`, `sent`, `cancelled` or `failed`.
---@alias CommKit.SendState "queued"|"sending"|"sent"|"cancelled"|"failed"

---Receives one whole message.
---@alias CommKit.ReceiveCallback fun(prefix: string, text: string, distribution: string, sender: string)

---Called after every chunk of a send leaves.
---@alias CommKit.ProgressCallback fun(handle: CommKit.SendHandle, bytesSent: integer, bytesTotal: integer)

---Called once when a send reaches a terminal state.
---@alias CommKit.CompleteCallback fun(handle: CommKit.SendHandle, state: CommKit.SendState, reason: string?)

---Called when a peer's field changes.
---@alias CommKit.ChangedCallback fun(sender: string, field: string, value: any)

---What the payload of a send requires of the channel.
---@class CommKit.Constraints
---@field logged boolean? `true` sends on the logged channel (`SendAddonMessageLogged`), for payloads carrying text a player wrote.
---@field battleNet boolean? `true` permits Battle.net transport; API 1 revision 1 never selects it.

---The table `scope:Send` accepts.
---@class CommKit.SendRequest
---@field prefix string The addon message prefix, 1 to 16 bytes.
---@field text string The message; any length up to the queue limit, without NUL, line breaks or `|`.
---@field distribution CommKit.Distribution
---@field target string|number|nil The player for `WHISPER`, the channel for `CHANNEL`; ignored otherwise.
---@field priority CommKit.PriorityName? Defaults to `"NORMAL"`.
---@field constraints CommKit.Constraints?
---@field onProgress CommKit.ProgressCallback?
---@field onComplete CommKit.CompleteCallback?

---The table `scope:SyncSet` accepts.
---@class CommKit.SyncSetOptions
---@field fields string[] The field names, 1 to 32 of them, each 1 to 64 bytes.
---@field schema table<string, table>? A sealed SchemaKit schema per field that received and local values must pass.

---The limits `SetLimits` accepts and `GetLimits` returns.
---@class CommKit.Limits
---@field maxQueuedBytes integer? Text bytes queued across every priority.
---@field maxQueuedMessages integer? Messages queued across every priority.
---@field maxReassemblyStreams integer? Incomplete received messages held at once.
---@field maxReassemblyBytesPerSender integer? Bytes one sender's incomplete messages may hold.
---@field maxInFlightPerSender integer? Incomplete messages one sender may have open.
---@field reassemblyTimeout number? Seconds a stream may go without a chunk before it expires.
---@field maxCps integer? Bytes per second the bucket refills with.
---@field burst integer? The most bytes the bucket holds.
---@field messageOverhead integer? Bytes charged per message on top of prefix and text.

---A registration, or an `OnChanged` listener.
---@class CommKit.Connection
---@field Disconnect fun(self: CommKit.Connection): boolean
---@field IsConnected fun(self: CommKit.Connection): boolean
---@field GetPrefix fun(self: CommKit.Connection): string

---One queued message.
---@class CommKit.SendHandle
---@field Cancel fun(self: CommKit.SendHandle): boolean
---@field GetState fun(self: CommKit.SendHandle): CommKit.SendState
---@field GetBytesSent fun(self: CommKit.SendHandle): integer
---@field GetBytesTotal fun(self: CommKit.SendHandle): integer

---Named fields versioned by content hash, exchanged over one prefix.
---@class CommKit.SyncSet
---@field Set fun(self: CommKit.SyncSet, field: string, value: any): boolean|nil, boolean|string|nil
---@field Get fun(self: CommKit.SyncSet, field: string): any
---@field GetHash fun(self: CommKit.SyncSet, field: string): integer?
---@field GetRemote fun(self: CommKit.SyncSet, sender: string, field: string): any
---@field Request fun(self: CommKit.SyncSet, target: string): CommKit.SendHandle|nil, string?
---@field OnChanged fun(self: CommKit.SyncSet, callback: CommKit.ChangedCallback): CommKit.Connection|nil, string?
---@field Close fun(self: CommKit.SyncSet): boolean
---@field IsClosed fun(self: CommKit.SyncSet): boolean

---The owner of registrations, sends and SyncSets, released together by `Close`.
---@class CommKit.Scope
---@field Register fun(self: CommKit.Scope, prefix: string, callback: CommKit.ReceiveCallback): CommKit.Connection|nil, string?
---@field Send fun(self: CommKit.Scope, request: CommKit.SendRequest): CommKit.SendHandle|nil, string?
---@field SyncSet fun(self: CommKit.Scope, prefix: string, options: CommKit.SyncSetOptions): CommKit.SyncSet|nil, string?
---@field UnregisterAll fun(self: CommKit.Scope): integer
---@field CancelAll fun(self: CommKit.Scope): integer
---@field Close fun(self: CommKit.Scope): boolean
---@field IsClosed fun(self: CommKit.Scope): boolean
---@field GetAddonName fun(self: CommKit.Scope): string?
---@field GetRegistrationCount fun(self: CommKit.Scope): integer
---@field GetPendingCount fun(self: CommKit.Scope): integer

---The priority constants.
---@class CommKit.Priorities
---@field ALERT "ALERT"
---@field NORMAL "NORMAL"
---@field BULK "BULK"

---The CommKit package facade published through Registry.
---@class CommKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field MAX_MESSAGE_BYTES integer The client's addon message limit, 255.
---@field MAX_REGISTRATIONS integer The most registrations one scope holds.
---@field Priority CommKit.Priorities
---@field Scope CommKit.Scope Shared scope prototype.
---@field Connection CommKit.Connection Shared connection prototype.
---@field SendHandle CommKit.SendHandle Shared send handle prototype.
---@field SyncSet CommKit.SyncSet Shared SyncSet prototype.
---@field CreateScope fun(self: CommKit): CommKit.Scope
---@field ForAddon fun(self: CommKit, addonName: string): CommKit.Scope
---@field CloseAddonScopes fun(self: CommKit, addonName: string): boolean
---@field GetQueueDepth fun(self: CommKit, priority: CommKit.PriorityName?): integer, integer
---@field GetBudget fun(self: CommKit): number, number, number, string
---@field SetLimits fun(self: CommKit, limits: CommKit.Limits)
---@field GetLimits fun(self: CommKit): CommKit.Limits
---@field GetStatistics fun(self: CommKit): table<string, integer>

-- Dependencies ---------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil

-- Ask for Registry by generation and fall back to the alias. A future Registry
-- API generation takes over `MoltenCodes.Registry`, so reading the alias first
-- would hand this file a facade whose contract it was not written against.
local Registry = type(generations) == "table" and rawget(generations, DEPENDENCY_API.registry)
    or nil
if Registry == nil and type(namespace) == "table" then
    Registry = rawget(namespace, "Registry")
end
if type(Registry) ~= "table" or rawget(Registry, "API") ~= DEPENDENCY_API.registry then
    error("MoltenCodes CommKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local getPackage = rawget(Registry, "Get")
if type(bootstrapPackage) ~= "function" or type(getPackage) ~= "function" then
    error("MoltenCodes CommKit requires a valid Registry API 2 facade", 2)
end

-- SignalKit carries the listeners of every prefix and every SyncSet.
local SignalKit = getPackage(Registry, "signalKit", DEPENDENCY_API.signalKit)
if
    type(SignalKit) ~= "table"
    or rawget(SignalKit, "API") ~= DEPENDENCY_API.signalKit
    or type(rawget(SignalKit, "New")) ~= "function"
    or type(rawget(SignalKit, "Connect")) ~= "function"
    or type(rawget(SignalKit, "Fire")) ~= "function"
    or type(rawget(SignalKit, "DisconnectAll")) ~= "function"
then
    error("MoltenCodes CommKit requires SignalKit API 1 to be loaded first", 2)
end

-- EventKit delivers CHAT_MSG_ADDON, CHAT_MSG_ADDON_LOGGED, GROUP_ROSTER_UPDATE
-- and PLAYER_ENTERING_WORLD.
local EventKit = getPackage(Registry, "eventKit", DEPENDENCY_API.eventKit)
if
    type(EventKit) ~= "table"
    or rawget(EventKit, "API") ~= DEPENDENCY_API.eventKit
    or type(rawget(EventKit, "CreateScope")) ~= "function"
then
    error("MoltenCodes CommKit requires EventKit API 1 to be loaded first", 2)
end

-- LifecycleKit closes an addon's scope at shutdown.
local LifecycleKit = getPackage(Registry, "lifecycleKit", DEPENDENCY_API.lifecycleKit)
local LifecycleInstance = type(LifecycleKit) == "table" and rawget(LifecycleKit, "Instance") or nil
if
    type(LifecycleKit) ~= "table"
    or rawget(LifecycleKit, "API") ~= DEPENDENCY_API.lifecycleKit
    or type(rawget(LifecycleKit, "ForAddon")) ~= "function"
    or type(LifecycleInstance) ~= "table"
    or type(rawget(LifecycleInstance, "IsShutdown")) ~= "function"
    or type(rawget(LifecycleInstance, "OnShutdown")) ~= "function"
then
    error("MoltenCodes CommKit requires LifecycleKit API 1 to be loaded first", 2)
end

-- SchedulerKit runs the send driver.
local SchedulerKit = getPackage(Registry, "schedulerKit", DEPENDENCY_API.schedulerKit)
local SchedulerScope = type(SchedulerKit) == "table" and rawget(SchedulerKit, "Scope") or nil
if
    type(SchedulerKit) ~= "table"
    or rawget(SchedulerKit, "API") ~= DEPENDENCY_API.schedulerKit
    or type(rawget(SchedulerKit, "CreateScope")) ~= "function"
    or type(SchedulerScope) ~= "table"
    or type(rawget(SchedulerScope, "Schedule")) ~= "function"
    or type(rawget(SchedulerScope, "NextFrame")) ~= "function"
    or type(rawget(SchedulerScope, "After")) ~= "function"
then
    error("MoltenCodes CommKit requires SchedulerKit API 1 to be loaded first", 2)
end

-- PoolKit leases the message, stream and chunk-list records.
local PoolKit = getPackage(Registry, "poolKit", DEPENDENCY_API.poolKit)
if
    type(PoolKit) ~= "table"
    or rawget(PoolKit, "API") ~= DEPENDENCY_API.poolKit
    or type(rawget(PoolKit, "NewTablePool")) ~= "function"
then
    error("MoltenCodes CommKit requires PoolKit API 1 to be loaded first", 2)
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

---Read an optional host table from the global table, or `nil`.
---@param name string
---@return table|nil
local function readHostTable(name)
    -- Host APIs are World of Warcraft client tables reachable only through the global table.
    -- selene: allow(global_usage)
    local value = rawget(_G, name)
    if type(value) == "table" then
        return value
    end
    return nil
end

-- The monotonic wall clock every deadline and the bucket are measured on.
-- SchedulerKit requires it too, so a client that runs SchedulerKit has it.
local nativeClock = readHostFunction("GetTimePreciseSec")
if nativeClock == nil then
    error("MoltenCodes CommKit requires GetTimePreciseSec", 2)
end

---Seconds on the monotonic wall clock.
---@return number
local function now()
    return nativeClock()
end

-- Validation -----------------------------------------------------------------

---Whether every name in `methodNames` is a function field of `prototype`.
---@param prototype any
---@param methodNames string[]
---@return boolean
local function hasMethods(prototype, methodNames)
    if type(prototype) ~= "table" then
        return false
    end
    for index = 1, #methodNames do
        if type(rawget(prototype, methodNames[index])) ~= "function" then
            return false
        end
    end
    return true
end

---Whether `implementation` exposes the complete CommKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
    if
        type(implementation) ~= "table"
        or rawget(implementation, "API") ~= API_GENERATION
        or type(rawget(implementation, "REVISION")) ~= "number"
        or type(rawget(implementation, "Priority")) ~= "table"
    then
        return false
    end

    return hasMethods(implementation, SURFACE.facade)
        and hasMethods(rawget(implementation, "Scope"), SURFACE.scope)
        and hasMethods(rawget(implementation, "Connection"), SURFACE.connection)
        and hasMethods(rawget(implementation, "SendHandle"), SURFACE.handle)
        and hasMethods(rawget(implementation, "SyncSet"), SURFACE.syncSet)
end

-- The table fields every API 1 revision keeps in package state.
local STATE_TABLE_FIELDS = {
    "dispatch",
    "metatables",
    "addonScopes",
    "limits",
    "statistics",
    "queues",
    "blockedPipes",
    "budget",
    "driver",
    "streams",
    "streamList",
    "senders",
    "expiry",
    "dropReports",
    "prefixSignals",
    "prefixCounts",
    "clientPrefixes",
    "kitScopes",
    "pools",
    "trampolines",
}

---Whether `currentState` has the fields every API 1 revision shares.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
    if
        type(currentState) ~= "table"
        or rawget(currentState, "schema") ~= LAYOUT.state
        or type(rawget(currentState, "runtimeRevision")) ~= "number"
    then
        return false
    end
    for index = 1, #STATE_TABLE_FIELDS do
        if type(rawget(currentState, STATE_TABLE_FIELDS[index])) ~= "table" then
            return false
        end
    end
    return true
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
-- and register this one. What stays here is what only CommKit can answer.
local CommKit, previousRevision, selected = bootstrapPackage(Registry, {
    package = PACKAGE_NAME,
    api = API_GENERATION,
    revision = IMPLEMENTATION_REVISION,
    label = "MoltenCodes CommKit",
    validatePublicSurface = validatePublicSurface,
    validateState = validateCurrentState,
})

if CommKit == nil then
    -- An equal or newer compatible revision already owns the shared package table.
    return selected
end

---A fresh priority queue: its ring of pipes, a cursor into the ring, and
---the messages and text bytes it holds.
---@return table
local function newQueue()
    return { ring = {}, cursor = 1, pipes = {}, messages = 0, bytes = 0 }
end

---Build the package state of a first load.
---@return table
local function newState()
    local limits = {}
    for index = 1, #LIMIT_NAMES do
        local name = LIMIT_NAMES[index]
        limits[name] = DEFAULT_LIMITS[name]
    end
    local statistics = {}
    for index = 1, #STATISTIC_NAMES do
        statistics[STATISTIC_NAMES[index]] = 0
    end

    return {
        schema = LAYOUT.state,
        runtimeRevision = 0,
        -- Every closure CommKit hands to another Kit calls through this table,
        -- so a newer revision replaces the behaviour behind them.
        dispatch = {},
        metatables = { scope = {}, connection = {}, handle = {}, syncSet = {} },
        -- Addon name to that addon's canonical scope.
        addonScopes = {},
        limits = limits,
        statistics = statistics,
        queues = {
            [PRIORITY.ALERT] = newQueue(),
            [PRIORITY.NORMAL] = newQueue(),
            [PRIORITY.BULK] = newQueue(),
        },
        -- Pipes the client throttled, waiting out their backoff.
        blockedPipes = {},
        queuedMessages = 0,
        queuedBytes = 0,
        rotationCursor = 1,
        -- The next stream id of each digit scheme.
        nextStreamId = 0,
        nextLoggedStreamId = 0,
        -- Multi-chunk messages whose first chunk left and last did not, and
        -- the bytes their first chunks declared: kept within what one
        -- receiver accepts from one sender.
        inFlightStreams = 0,
        inFlightBytes = 0,
        -- Text bytes of SyncSet replies in the queue.
        syncReplyBytes = 0,
        -- Starts full so the first messages of a session leave at once.
        budget = {
            tokens = DEFAULT_LIMITS.burst,
            lastRefill = false,
            zoningUntil = 0,
            framesPerSecond = false,
        },
        -- `running` is true while a run is on the stack; a send made by one of
        -- its callbacks then schedules nothing, so there is never a second
        -- job.
        driver = {
            job = false,
            delayed = false,
            sampler = false,
            running = false,
        },
        -- True while CommKit itself is inside the client's send function, so
        -- the outside-traffic hook does not charge the same bytes twice.
        sendingOwnTraffic = false,
        -- The HookKit scope holding the outside-traffic hooks, once installed.
        outsideHooks = false,
        -- Incomplete received messages: key to stream, in opening order, and
        -- sender to { streams, bytes }.
        streams = {},
        streamList = {},
        senders = {},
        expiry = { timer = false, due = false },
        -- Sender to { reportedAt, pending, reasons }: the aggregated drop
        -- reports, and the one timer that flushes them.
        dropReports = { bySender = {}, count = 0, timer = false, due = false },
        prefixSignals = {},
        prefixCounts = {},
        -- Prefixes this session registered with the client.
        clientPrefixes = {},
        registrationTotal = 0,
        chatConnections = false,
        kitScopes = { event = false, timer = false, scheduler = false, world = false },
        pools = {
            records = PoolKit:NewTablePool({ maxRetained = POOL_RETAINED.records }),
            streams = PoolKit:NewTablePool({ maxRetained = POOL_RETAINED.streams }),
            parts = PoolKit:NewTablePool({ maxRetained = POOL_RETAINED.streams }),
        },
        trampolines = {},
    }
end

local Scope = rawget(CommKit, "Scope")
local Connection = rawget(CommKit, "Connection")
local SendHandle = rawget(CommKit, "SendHandle")
local SyncSetPrototype = rawget(CommKit, "SyncSet")
local state = rawget(CommKit, "_state")

if previousRevision == nil then
    if Scope ~= nil or state ~= nil then
        error("MoltenCodes CommKit package state is corrupted or incomplete", 2)
    end

    Scope, Connection, SendHandle, SyncSetPrototype = {}, {}, {}, {}
    state = newState()
    rawset(CommKit, "Scope", Scope)
    rawset(CommKit, "Connection", Connection)
    rawset(CommKit, "SendHandle", SendHandle)
    rawset(CommKit, "SyncSet", SyncSetPrototype)
    rawset(CommKit, "_state", state)
elseif
    type(Scope) ~= "table"
    or type(Connection) ~= "table"
    or type(SendHandle) ~= "table"
    or type(SyncSetPrototype) ~= "table"
    or not validateStateBase(state)
then
    error("MoltenCodes CommKit package state is corrupted or incomplete", 2)
end

-- The metatables and prototypes are kept across upgrades, so objects built by
-- an older copy gain this copy's methods without being replaced.
local metatables = rawget(state, "metatables")
local SCOPE_METATABLE = rawget(metatables, "scope")
local CONNECTION_METATABLE = rawget(metatables, "connection")
local HANDLE_METATABLE = rawget(metatables, "handle")
local SYNC_SET_METATABLE = rawget(metatables, "syncSet")
rawset(SCOPE_METATABLE, "__index", Scope)
rawset(CONNECTION_METATABLE, "__index", Connection)
rawset(HANDLE_METATABLE, "__index", SendHandle)
rawset(SYNC_SET_METATABLE, "__index", SyncSetPrototype)

local dispatch = rawget(state, "dispatch")
local limits = rawget(state, "limits")
local statistics = rawget(state, "statistics")
local queues = rawget(state, "queues")
local blockedPipes = rawget(state, "blockedPipes")
local budget = rawget(state, "budget")
local driver = rawget(state, "driver")
local streams = rawget(state, "streams")
local streamList = rawget(state, "streamList")
local senders = rawget(state, "senders")
local expiry = rawget(state, "expiry")
local dropReports = rawget(state, "dropReports")
local prefixSignals = rawget(state, "prefixSignals")
local prefixCounts = rawget(state, "prefixCounts")
local clientPrefixes = rawget(state, "clientPrefixes")
local addonScopes = rawget(state, "addonScopes")
local kitScopes = rawget(state, "kitScopes")
local pools = rawget(state, "pools")
local trampolines = rawget(state, "trampolines")

-- Host access ----------------------------------------------------------------

---Hand a failure nobody called for to the host error handler.
---
---The failure is passed on unchanged: it may be a secret string built from a
---secret argument, and CommKit never inspects it.
---@param failure any
local function reportError(failure)
    local getErrorHandler = readHostFunction("geterrorhandler")
    if getErrorHandler ~= nil then
        local handler = getErrorHandler()
        if type(handler) == "function" then
            handler(failure)
            return
        end
    end

    -- Outside a WoW client there is no error handler to report through.
    -- Printing is what the client's own default handler does, and staying
    -- silent would turn a callback bug into an invisible one.
    print(failure)
end

---Whether `value` is a secret value. The probe is looked up at every call, so
---a client without secret values treats nothing as secret.
---@param value any
---@return boolean
local function isSecret(value)
    local probe = readHostFunction("issecretvalue")
    if probe == nil then
        return false
    end
    return probe(value) == true
end

---Call a consumer's callback so that its error, and on clients that have
---`securecallfunction` its taint, stays out of CommKit and out of the next
---callback. Allocates nothing.
---@param callback function
---@param ... any
local function isolatedCall(callback, ...)
    local secureCall = readHostFunction("securecallfunction")
    if secureCall ~= nil then
        -- securecallfunction reports an error through the host error handler
        -- itself.
        secureCall(callback, ...)
        return
    end
    local ok, failure = pcall(callback, ...)
    if not ok then
        reportError(failure)
    end
end

---Return a function of the client's chat API: `C_ChatInfo[name]`, or the
---legacy global of the same name when `C_ChatInfo` lacks it.
---@param name string
---@return function|nil
local function readChatFunction(name)
    local chatInfo = readHostTable("C_ChatInfo")
    if chatInfo ~= nil then
        local value = rawget(chatInfo, name)
        if type(value) == "function" then
            return value
        end
    end
    return readHostFunction(name)
end

---Return the client's value for `Enum[enumName][key]`, or `fallback`.
---@param enumName string
---@param key string
---@param fallback integer
---@return any
local function readEnumValue(enumName, key, fallback)
    local enums = readHostTable("Enum")
    local values = enums ~= nil and rawget(enums, enumName) or nil
    if type(values) ~= "table" then
        return fallback
    end
    local value = rawget(values, key)
    if value == nil then
        return fallback
    end
    return value
end

---Return the name `Enum[enumName]` gives `value`, or `nil`. Used on failure
---paths only: it walks the enum table.
---@param enumName string
---@param value any
---@return string|nil
local function readEnumName(enumName, value)
    local enums = readHostTable("Enum")
    local values = enums ~= nil and rawget(enums, enumName) or nil
    if type(values) ~= "table" then
        return nil
    end
    for key, candidate in pairs(values) do
        if candidate == value and type(key) == "string" then
            return key
        end
    end
    return nil
end

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- CommKit. `level` is always the value `error` needs *inside the function that
-- receives it*, so every further hop towards `error` adds exactly one.

---Refuse a receiver other than the CommKit facade (a `.` call, say).
---@param receiver any
---@param label string qualified public method name, used in the argument error
---@param level integer
local function validateFacade(receiver, label, level)
    if receiver ~= CommKit then
        error(label .. " must be called on the CommKit facade; use " .. label .. "(...)", level)
    end
end

---Refuse a receiver that is not built on `metatable`.
---@param receiver any
---@param metatable table
---@param label string
---@param kind string what the receiver must be, as the message names it
---@param level integer
local function validateReceiver(receiver, metatable, label, kind, level)
    if type(receiver) ~= "table" or getmetatable(receiver) ~= metatable then
        error(label .. " must be called on a " .. kind, level)
    end
end

---@param receiver any
---@param label string
---@param level integer
local function validateScope(receiver, label, level)
    validateReceiver(receiver, SCOPE_METATABLE, label, "CommKit scope", level + 1)
end

---Refuse anything but a non-empty, non-secret string of at most `maximum`
---bytes.
---@param value any
---@param label string the parameter, qualified by its method
---@param maximum integer
---@param level integer
local function validateBoundedString(value, label, maximum, level)
    if type(value) ~= "string" then
        error(label .. " must be a string of 1 to " .. maximum .. " bytes", level)
    end
    if isSecret(value) then
        error(label .. " must not be a secret value", level)
    end
    local length = #value
    if length == 0 or length > maximum then
        error(label .. " must be a string of 1 to " .. maximum .. " bytes", level)
    end
end

---@param value any
---@param label string
---@param level integer
local function validateCallback(value, label, level)
    if type(value) ~= "function" then
        error(label .. " must be a function", level)
    end
end

---@param value any
---@param label string
---@param level integer
local function validateOptionalCallback(value, label, level)
    local kind = type(value)
    if kind ~= "nil" and kind ~= "function" then
        error(label .. " must be a function or nil", level)
    end
end

---Refuse a table with a field outside `allowed`. Keys of a table are never
---secret (a secret cannot be a key), so an unknown string key can be named.
---@param options table
---@param allowed table<string, true>
---@param label string
---@param level integer
local function validateKeys(options, allowed, label, level)
    for key in pairs(options) do
        if type(key) ~= "string" or not allowed[key] then
            local name = type(key) == "string" and key or ("<" .. type(key) .. ">")
            error(label .. ' contains unknown field "' .. name .. '"', level)
        end
    end
end

-- Found packages -------------------------------------------------------------
--
-- TimerKit is in SchedulerKit's dependency closure, so it is always loaded
-- before CommKit; it is not a direct dependency, so it is found with
-- `Registry:Find` when first needed, as TestKit does. CodecKit, HookKit and
-- SchemaKit are optional dependencies found at call time.

---Find a package by id and API generation, or `nil`.
---@param packageName string
---@param api integer
---@return table|nil
local function findOptional(packageName, api)
    local find = rawget(Registry, "Find")
    if type(find) ~= "function" then
        return nil
    end
    local found = find(Registry, packageName, api)
    if type(found) ~= "table" then
        return nil
    end
    return found
end

---Find a package a method cannot work without, or raise at the caller.
---@param packageName string
---@param displayName string
---@param api integer
---@param label string public method name, used in the failure
---@param level integer
---@return table
local function requireFound(packageName, displayName, api, label, level)
    local found = findOptional(packageName, api)
    if found == nil then
        error(
            label .. " requires " .. displayName .. " API " .. api .. ", which is not loaded",
            level
        )
    end
    return found
end

-- Kit-owned scopes -----------------------------------------------------------
--
-- CommKit owns one scope in each of EventKit, TimerKit and SchedulerKit. They
-- are created on first use and replaced if something outside closed them.

---@return table EventKit scope for the chat and roster events
local function getEventScope()
    local scope = rawget(kitScopes, "event")
    if scope == false or scope:IsClosed() then
        scope = EventKit:CreateScope()
        rawset(kitScopes, "event", scope)
    end
    return scope
end

---@return table TimerKit scope for the expiry timer and the frame-rate sampler
local function getTimerScope()
    local scope = rawget(kitScopes, "timer")
    if scope == false or scope:IsClosed() then
        local TimerKit = requireFound("timerKit", "TimerKit", DEPENDENCY_API.timerKit, "CommKit", 2)
        scope = TimerKit:CreateScope()
        rawset(kitScopes, "timer", scope)
    end
    return scope
end

---@return table SchedulerKit scope for the send driver
local function getSchedulerScope()
    local scope = rawget(kitScopes, "scheduler")
    if scope == false or scope:IsClosed() then
        scope = SchedulerKit:CreateScope()
        rawset(kitScopes, "scheduler", scope)
    end
    return scope
end

---Start watching PLAYER_ENTERING_WORLD for the zoning mode, once per session.
local function ensureWorldWatcher()
    if rawget(kitScopes, "world") ~= false then
        return
    end
    local connection =
        getEventScope():Connect("PLAYER_ENTERING_WORLD", rawget(trampolines, "enteringWorld"))
    rawset(kitScopes, "world", connection)
end

-- Budget ---------------------------------------------------------------------

---The refill factor, the capacity and the name of the current mode.
---@param currentTime number
---@return number factor, number capacity, string mode
local function currentMode(currentTime)
    local maxCps = rawget(limits, "maxCps")
    local burst = rawget(limits, "burst")
    if currentTime < rawget(budget, "zoningUntil") then
        local capacity = math.min(burst, maxCps * POLICY.zoningCapacitySeconds)
        return POLICY.zoningFactor, capacity, POLICY.modeZoning
    end
    local framesPerSecond = rawget(budget, "framesPerSecond")
    if framesPerSecond ~= false and framesPerSecond < POLICY.lowFrameRate then
        return POLICY.lowFrameRateFactor, burst, POLICY.modeLowFrameRate
    end
    return 1, burst, POLICY.modeNormal
end

---Add what the elapsed time earned to the bucket, in the current mode.
---@param currentTime number
local function refill(currentTime)
    local lastRefill = rawget(budget, "lastRefill")
    rawset(budget, "lastRefill", currentTime)
    local factor, capacity = currentMode(currentTime)
    local tokens = rawget(budget, "tokens")
    if lastRefill ~= false and currentTime > lastRefill then
        tokens = tokens + (currentTime - lastRefill) * rawget(limits, "maxCps") * factor
    end
    if tokens > capacity then
        tokens = capacity
    end
    rawset(budget, "tokens", tokens)
end

---The bytes one message of `prefix` and `text` costs the bucket.
---@param prefixLength integer
---@param textLength integer
---@return integer
local function messageCost(prefixLength, textLength)
    return prefixLength + textLength + rawget(limits, "messageOverhead")
end

---Charge `cost` bytes someone else sent, down to the debt floor.
---@param cost number
local function chargeOutside(cost)
    refill(now())
    local floor = -POLICY.debtSeconds * rawget(limits, "maxCps")
    local tokens = rawget(budget, "tokens") - cost
    if tokens < floor then
        tokens = floor
    end
    rawset(budget, "tokens", tokens)
end

---Seconds until the bucket can pay `cost` bytes at the current rate. A cost
---above the capacity (a small `burst`, or the zoning mode's half second) is
---paid by a full bucket, so no chunk can wait forever.
---@param cost number
---@param currentTime number
---@return number
local function secondsUntilAffordable(cost, currentTime)
    local factor, capacity = currentMode(currentTime)
    local rate = rawget(limits, "maxCps") * factor
    local missing = math.min(cost, capacity) - rawget(budget, "tokens")
    -- Less than a byte short is rounding in the refill arithmetic, not a
    -- reason to wait a few nanoseconds.
    if missing < 1 then
        return 0
    end
    return missing / rate
end

---Sample the frame rate. Runs on a TimerKit ticker while something is queued,
---never on the send path: `GetFramerate` is not free.
local function sampleFrameRate()
    local getFramerate = readHostFunction("GetFramerate")
    if getFramerate == nil then
        rawset(budget, "framesPerSecond", false)
        return
    end
    local framesPerSecond = getFramerate()
    if type(framesPerSecond) ~= "number" or isSecret(framesPerSecond) then
        rawset(budget, "framesPerSecond", false)
        return
    end
    rawset(budget, "framesPerSecond", framesPerSecond)
end

---Start the frame-rate sampler if it is not running, sampling once at once.
local function startSampler()
    if rawget(driver, "sampler") ~= false then
        return
    end
    sampleFrameRate()
    local timer =
        getTimerScope():Every(POLICY.frameRateSampleSeconds, rawget(trampolines, "sample"))
    rawset(driver, "sampler", timer)
end

---Cancel any scheduled driver run and stop the frame-rate sampler: nothing is
---queued, so nothing may stay armed.
local function stopDriver()
    local job = rawget(driver, "job")
    if job ~= false then
        rawset(driver, "job", false)
        rawset(driver, "delayed", false)
        job:Cancel()
    end
    local timer = rawget(driver, "sampler")
    if timer ~= false then
        rawset(driver, "sampler", false)
        timer:Cancel()
    end
end

---Enter the zoning mode: the host just loaded a world. What the bucket earned
---before is settled at the normal rate first; the next refill then holds it to
---the zoning capacity.
local function onEnteringWorld()
    local currentTime = now()
    refill(currentTime)
    rawset(budget, "zoningUntil", currentTime + POLICY.zoningSeconds)
end

-- Queues and pipes -----------------------------------------------------------
--
-- Each priority holds a ring of pipes, one pipe per destination (distribution,
-- target and channel kind). A pipe is a FIFO of message records; its head is
-- sent chunk by chunk, and the ring advances after every chunk, so one busy
-- destination cannot starve another of the same priority. A pipe the client
-- throttled leaves the ring for `blockedPipes` until its backoff has passed.

---The key of the pipe a message joins.
---@param distribution string
---@param target string|number|nil
---@param logged boolean
---@return string
local function pipeKey(distribution, target, logged)
    local targetText = target ~= nil and tostring(target) or ""
    if logged then
        return distribution .. "\t" .. targetText .. "\tlogged"
    end
    return distribution .. "\t" .. targetText
end

---Remove `pipe` from its queue's ring, keeping the cursor on the pipe that
---would have been served next.
---@param queue table
---@param pipe table
local function ringRemove(queue, pipe)
    local ring = rawget(queue, "ring")
    for index = 1, #ring do
        if ring[index] == pipe then
            table.remove(ring, index)
            local cursor = rawget(queue, "cursor")
            if index < cursor then
                cursor = cursor - 1
            end
            if cursor > #ring or cursor < 1 then
                cursor = 1
            end
            rawset(queue, "cursor", cursor)
            return
        end
    end
end

---Remove `pipe` from the blocked list.
---@param pipe table
local function blockedRemove(pipe)
    for index = 1, #blockedPipes do
        if blockedPipes[index] == pipe then
            table.remove(blockedPipes, index)
            return
        end
    end
end

---Forget an empty pipe wherever it waits.
---@param pipe table
local function removePipe(pipe)
    local queue = rawget(queues, rawget(pipe, "priority"))
    if rawget(pipe, "blocked") then
        blockedRemove(pipe)
    else
        ringRemove(queue, pipe)
    end
    rawset(rawget(queue, "pipes"), rawget(pipe, "key"), nil)
end

---Return the pipe for `key` in `priority`, creating it at the end of the ring.
---@param priority string
---@param key string
---@return table
local function obtainPipe(priority, key)
    local queue = rawget(queues, priority)
    local pipes = rawget(queue, "pipes")
    local pipe = rawget(pipes, key)
    if pipe == nil then
        pipe = {
            key = key,
            priority = priority,
            fifo = {},
            blocked = false,
            blockedUntil = 0,
            backoff = POLICY.throttleBackoffSeconds,
        }
        rawset(pipes, key, pipe)
        local ring = rawget(queue, "ring")
        ring[#ring + 1] = pipe
    end
    return pipe
end

---Append a message record to its pipe and count it.
---@param record table
local function enqueueRecord(record)
    local priority = rawget(record, "priority")
    local pipe = obtainPipe(priority, rawget(record, "pipeKey"))
    local fifo = rawget(pipe, "fifo")
    fifo[#fifo + 1] = record
    rawset(record, "pipe", pipe)

    local length = rawget(record, "textLength")
    local queue = rawget(queues, priority)
    rawset(queue, "messages", rawget(queue, "messages") + 1)
    rawset(queue, "bytes", rawget(queue, "bytes") + length)
    rawset(state, "queuedMessages", rawget(state, "queuedMessages") + 1)
    rawset(state, "queuedBytes", rawget(state, "queuedBytes") + length)
end

---Take a message record out of its pipe and uncount it; an emptied pipe is
---forgotten.
---@param record table
local function dequeueRecord(record)
    local pipe = rawget(record, "pipe")
    local fifo = rawget(pipe, "fifo")
    for index = 1, #fifo do
        if fifo[index] == record then
            table.remove(fifo, index)
            break
        end
    end
    if #fifo == 0 then
        removePipe(pipe)
    end

    local length = rawget(record, "textLength")
    local queue = rawget(queues, rawget(record, "priority"))
    rawset(queue, "messages", rawget(queue, "messages") - 1)
    rawset(queue, "bytes", rawget(queue, "bytes") - length)
    rawset(state, "queuedMessages", rawget(state, "queuedMessages") - 1)
    rawset(state, "queuedBytes", rawget(state, "queuedBytes") - length)
end

---Add one to a statistics counter.
---@param name string
---@param amount integer?
local function count(name, amount)
    rawset(statistics, name, rawget(statistics, name) + (amount or 1))
end

---Remove `value` from the array `list`, if present.
---@param list table
---@param value any
local function removeFromList(list, value)
    for index = 1, #list do
        if list[index] == value then
            table.remove(list, index)
            return
        end
    end
end

-- Send completion ------------------------------------------------------------

---The digit scheme of a record: the logged channel's printable one, or the
---ordinary channel's high bytes.
---@param logged boolean
---@return table
local function digitScheme(logged)
    if logged then
        return WIRE.logged
    end
    return WIRE.plain
end

---The bytes the first chunk of an `n`-chunk message declares: the least such
---a message can hold. Sender and receiver count streams by the same measure.
---@param totalChunks integer
---@return integer
local function declaredBytes(totalChunks)
    return (totalChunks - 1) * WIRE.chunkPayloadBytes + 1
end

---Queue the abort of a stream that was cancelled after its first chunk left,
---at the head of the same pipe, so receivers drop it at once and silently.
---Receivers hold the stream until the abort arrives, so the abort takes over
---the message's in-flight allowance and keeps its stream id in use. An abort
---has no handle, scope, text or callbacks: only what `transmit` and the queue
---read.
---@param record table the cancelled message
local function queueAbort(record)
    local abort = rawget(pools, "records"):Acquire()
    abort.kind = "abort"
    abort.inFlight = true
    abort.prefix = rawget(record, "prefix")
    abort.textLength = 0
    abort.distribution = rawget(record, "distribution")
    abort.target = rawget(record, "target")
    abort.priority = rawget(record, "priority")
    abort.logged = rawget(record, "logged")
    abort.pipeKey = rawget(record, "pipeKey")
    abort.totalChunks = rawget(record, "totalChunks")
    abort.streamId = rawget(record, "streamId")
    enqueueRecord(abort)
    -- Move it from the tail to the head of its pipe.
    local fifo = rawget(rawget(abort, "pipe"), "fifo")
    table.remove(fifo)
    table.insert(fifo, 1, abort)
end

---Release the in-flight allowance a started multi-chunk message, or the
---abort that took it over, holds.
---@param record table
local function releaseInFlight(record)
    if not rawget(record, "inFlight") then
        return
    end
    rawset(record, "inFlight", false)
    rawset(state, "inFlightStreams", rawget(state, "inFlightStreams") - 1)
    rawset(
        state,
        "inFlightBytes",
        rawget(state, "inFlightBytes") - declaredBytes(rawget(record, "totalChunks"))
    )
end

---Move a queued message to a terminal state, release its record and tell the
---caller. The callback runs last, isolated, when CommKit's state is settled.
---A message cancelled after its first chunk left queues an abort. Outside a
---driver run, the message that empties the queue also disarms the driver.
---@param record table
---@param terminalState string
---@param reason string|nil
local function completeSend(record, terminalState, reason)
    local handle = rawget(record, "handle")
    local onComplete = rawget(record, "onComplete")
    dequeueRecord(record)
    if rawget(record, "inFlight") == true and terminalState == SEND_STATE.cancelled then
        rawset(record, "inFlight", false)
        queueAbort(record)
    else
        releaseInFlight(record)
    end
    rawset(handle, "_state", terminalState)
    rawset(handle, "_record", false)
    removeFromList(rawget(rawget(record, "scope"), "_pending"), handle)
    count(STATISTIC_FOR.terminal[terminalState])
    rawget(pools, "records"):Release(record)
    if rawget(state, "queuedMessages") == 0 and not rawget(driver, "running") then
        stopDriver()
    end

    if onComplete ~= false then
        isolatedCall(onComplete, handle, terminalState, reason)
    end
end

---Take an abort record out of the queue once it was sent or refused; the
---receivers no longer hold its stream.
---@param record table
local function finishAbort(record)
    dequeueRecord(record)
    releaseInFlight(record)
    rawget(pools, "records"):Release(record)
end

-- Driver ---------------------------------------------------------------------
--
-- One SchedulerKit job at a time, and only while something is queued. A run
-- refills the bucket, reinstates pipes whose backoff has passed, and sends
-- chunks in rotation until the bucket, the queue or the per-run cap runs out;
-- then it arranges the next run: after the time the bucket needs, after the
-- earliest reinstatement, or on the next frame. While a run is on the stack a
-- send made by one of its callbacks schedules nothing: the run sees the new
-- message on its next chunk, or arranges the run after it when it ends.

---Arrange the next driver run, replacing any run already scheduled. `why`
---records what it waits for, so a new send knows whether waking the driver
---early can help.
---@param delay number seconds; 0 means the next frame
---@param why string `"budget"`, `"blocked"`, `"frame"` or `"retry"`
local function scheduleDriver(delay, why)
    local existing = rawget(driver, "job")
    if existing ~= false then
        existing:Cancel()
    end
    local scope = getSchedulerScope()
    local job
    if delay <= 0 then
        job = scope:NextFrame(rawget(trampolines, "driver"), DRIVER_JOB_OPTIONS)
    else
        job = scope:After(delay, rawget(trampolines, "driver"), DRIVER_JOB_OPTIONS)
    end
    rawset(driver, "job", job)
    rawset(driver, "delayed", why)
end

---The client's send result as `"sent"`, `"throttled"` or `"failed"` and a
---reason. `AddonMessageThrottle`, `ChannelThrottle` and any value the enum
---does not name are throttles.
---@param result any
---@return string outcome
---@return string|nil reason
local function classifySendResult(result)
    if result == nil or result == true then
        return SEND_STATE.sent, nil
    end
    if result == false then
        return SEND_STATE.failed, "GeneralError"
    end
    if result == readEnumValue("SendAddonMessageResult", "Success", CLIENT_RESULT.sendSuccess) then
        return SEND_STATE.sent, nil
    end
    if
        result
            == readEnumValue(
                "SendAddonMessageResult",
                "AddonMessageThrottle",
                CLIENT_RESULT.sendAddonThrottle
            )
        or result
            == readEnumValue(
                "SendAddonMessageResult",
                "ChannelThrottle",
                CLIENT_RESULT.sendChannelThrottle
            )
    then
        return "throttled", nil
    end
    -- A result the client's enum names is a real refusal. One it does not
    -- name comes from a client newer than this file, and is treated like a
    -- throttle: set aside and retried, rather than losing the message.
    local name = readEnumName("SendAddonMessageResult", result)
    if name == nil then
        return "throttled", nil
    end
    return SEND_STATE.failed, name
end

---Hand one chunk to the client.
---@param record table
---@param chunk string
---@return string outcome
---@return string|nil reason
local function transmit(record, chunk)
    local functionName = rawget(record, "logged") and "SendAddonMessageLogged" or "SendAddonMessage"
    local send = readChatFunction(functionName)
    if send == nil then
        return SEND_STATE.failed, REASON.unavailable
    end
    rawset(state, "sendingOwnTraffic", true)
    local ok, result = pcall(
        send,
        rawget(record, "prefix"),
        chunk,
        rawget(record, "distribution"),
        rawget(record, "target")
    )
    rawset(state, "sendingOwnTraffic", false)
    if not ok then
        reportError(result)
        return SEND_STATE.failed, "error"
    end
    local outcome, reason = classifySendResult(result)
    return outcome, reason
end

-- Only `assignStreamId` is used outside this block.
local assignStreamId

do
    ---Whether the head of `pipe` holds `streamId` of the digit scheme `logged`
    ---selects: a started message or an abort, whose stream receivers may still
    ---hold. Either is always the head of its pipe.
    ---@param pipe table
    ---@param logged boolean
    ---@param streamId integer
    ---@return boolean
    local function headHolds(pipe, logged, streamId)
        local head = rawget(pipe, "fifo")[1]
        return rawget(head, "inFlight") == true
            and rawget(head, "logged") == logged
            and rawget(head, "streamId") == streamId
    end

    ---Whether a started message or a queued abort holds `streamId`.
    ---@param logged boolean
    ---@param streamId integer
    ---@return boolean
    local function streamIdInUse(logged, streamId)
        for _, queue in pairs(queues) do
            local ring = rawget(queue, "ring")
            for index = 1, #ring do
                if headHolds(ring[index], logged, streamId) then
                    return true
                end
            end
        end
        for index = 1, #blockedPipes do
            if headHolds(blockedPipes[index], logged, streamId) then
                return true
            end
        end
        return false
    end

    ---Give a multi-chunk message whose first chunk has not left the stream id
    ---it will start with: the scheme's next id that no stream of this client
    ---still in flight holds, so a receiver never sees two open streams with one
    ---id. Streams in flight, aborts included, number at most
    ---`maxInFlightPerSender` (64), below either radix, so a free id exists. The
    ---counter moves only when the first chunk leaves (`acceptChunk`), and the
    ---id is chosen again on every attempt until then.
    ---@param record table
    function assignStreamId(record)
        if
            rawget(record, "kind") ~= "message"
            or rawget(record, "totalChunks") == 1
            or rawget(record, "nextIndex") ~= 1
        then
            return
        end
        local logged = rawget(record, "logged")
        local radix = digitScheme(logged).radix
        local candidate = rawget(state, logged and "nextLoggedStreamId" or "nextStreamId")
        for _ = 1, radix do
            if not streamIdInUse(logged, candidate) then
                break
            end
            candidate = (candidate + 1) % radix
        end
        rawset(record, "streamId", candidate)
    end
end

---Build the next chunk of a message, or the abort of a cancelled one, and the
---payload bytes it carries.
---@param record table
---@return string chunk
---@return integer payloadBytes
local function buildChunk(record)
    local text = rawget(record, "text")
    local totalChunks = rawget(record, "totalChunks")
    local isAbort = rawget(record, "kind") == "abort"
    if totalChunks == 1 and not isAbort then
        return WIRE.singleControlText .. text, #text
    end

    local scheme = digitScheme(rawget(record, "logged"))
    local index = rawget(record, "nextIndex")
    local control, number
    if isAbort then
        control, number = WIRE.abort, totalChunks
    elseif index == 1 then
        control, number = WIRE.first, totalChunks
    elseif index == totalChunks then
        control, number = WIRE.last, index
    else
        control, number = WIRE.middle, index
    end
    local high = math.floor(number / scheme.radix)
    local header = string.char(
        control,
        scheme.offset + rawget(record, "streamId"),
        scheme.offset + high,
        scheme.offset + number - high * scheme.radix
    )
    if isAbort then
        return header, 0
    end
    local first = (index - 1) * WIRE.chunkPayloadBytes + 1
    local last = math.min(first + WIRE.chunkPayloadBytes - 1, #text)
    return header .. string.sub(text, first, last), last - first + 1
end

---Whether the head of `pipe` may be served now. A multi-chunk message that
---has not started waits while starting it would pass what one receiver
---accepts from one sender: `maxInFlightPerSender` streams and
---`maxReassemblyBytesPerSender` declared bytes. Everything else may go.
---@param pipe table
---@return boolean
local function headMayStart(pipe)
    local record = rawget(pipe, "fifo")[1]
    local totalChunks = rawget(record, "totalChunks")
    -- A started message or an abort already holds its allowance.
    if totalChunks == 1 or rawget(record, "inFlight") then
        return true
    end
    return rawget(state, "inFlightStreams") < rawget(limits, "maxInFlightPerSender")
        and rawget(state, "inFlightBytes") + declaredBytes(totalChunks)
            <= rawget(limits, "maxReassemblyBytesPerSender")
end

---Find the pipe the rotation serves next without moving any cursor: in the
---next priority that has one, the first pipe from the ring's cursor whose
---head may be served.
---@return table|nil queue
---@return integer ringIndex
---@return integer slot
local function peekNextPipe()
    local rotationLength = #PRIORITY_ROTATION
    local slot = rawget(state, "rotationCursor")
    for _ = 1, rotationLength do
        local queue = rawget(queues, PRIORITY_ROTATION[slot])
        local ring = rawget(queue, "ring")
        local ringLength = #ring
        local index = rawget(queue, "cursor")
        for _ = 1, ringLength do
            if index > ringLength then
                index = 1
            end
            if headMayStart(ring[index]) then
                return queue, index, slot
            end
            index = index + 1
        end
        slot = slot % rotationLength + 1
    end
    return nil, 0, 0
end

---Move the priority rotation and the queue's ring past the pipe just served.
---@param queue table
---@param ringIndex integer
---@param slot integer
local function advanceCursors(queue, ringIndex, slot)
    rawset(state, "rotationCursor", slot % #PRIORITY_ROTATION + 1)
    rawset(queue, "cursor", ringIndex % #rawget(queue, "ring") + 1)
end

---Take a throttled pipe out of the ring until its backoff has passed.
---@param queue table
---@param pipe table
---@param currentTime number
local function setPipeAside(queue, pipe, currentTime)
    ringRemove(queue, pipe)
    local backoff = rawget(pipe, "backoff")
    rawset(pipe, "blocked", true)
    rawset(pipe, "blockedUntil", currentTime + backoff)
    rawset(pipe, "backoff", math.min(backoff * 2, POLICY.maxThrottleBackoffSeconds))
    blockedPipes[#blockedPipes + 1] = pipe
    count("throttled")
end

---Put pipes whose backoff has passed back at the end of their ring.
---@param currentTime number
local function reinstatePipes(currentTime)
    local index = 1
    while index <= #blockedPipes do
        local pipe = blockedPipes[index]
        if rawget(pipe, "blockedUntil") <= currentTime + POLICY.dueToleranceSeconds then
            table.remove(blockedPipes, index)
            rawset(pipe, "blocked", false)
            local ring = rawget(rawget(queues, rawget(pipe, "priority")), "ring")
            ring[#ring + 1] = pipe
        else
            index = index + 1
        end
    end
end

---Record a chunk that left: charge the bucket, advance the message, report
---progress, and complete the message after its last chunk.
---@param record table
---@param pipe table
---@param cost integer what the chunk costs the bucket
---@param chunkBytes integer the chunk's length on the wire, header included
---@param payloadBytes integer the message bytes the chunk carries
local function acceptChunk(record, pipe, cost, chunkBytes, payloadBytes)
    rawset(budget, "tokens", rawget(budget, "tokens") - cost)
    rawset(pipe, "backoff", POLICY.throttleBackoffSeconds)
    count("chunksSent")
    count("bytesSent", chunkBytes)
    if rawget(record, "kind") == "abort" then
        finishAbort(record)
        return
    end

    local handle = rawget(record, "handle")
    local totalChunks = rawget(record, "totalChunks")
    local bytesSent = rawget(record, "bytesSent") + payloadBytes
    local nextIndex = rawget(record, "nextIndex") + 1
    rawset(record, "bytesSent", bytesSent)
    rawset(record, "nextIndex", nextIndex)
    rawset(handle, "_bytesSent", bytesSent)
    local finished = nextIndex > totalChunks
    if not finished then
        rawset(handle, "_state", SEND_STATE.sending)
        if nextIndex == 2 then
            local logged = rawget(record, "logged")
            rawset(
                state,
                logged and "nextLoggedStreamId" or "nextStreamId",
                (rawget(record, "streamId") + 1) % digitScheme(logged).radix
            )
            rawset(record, "inFlight", true)
            rawset(state, "inFlightStreams", rawget(state, "inFlightStreams") + 1)
            rawset(
                state,
                "inFlightBytes",
                rawget(state, "inFlightBytes") + declaredBytes(totalChunks)
            )
        end
    end

    local onProgress = rawget(record, "onProgress")
    if onProgress ~= false then
        isolatedCall(onProgress, handle, bytesSent, rawget(record, "textLength"))
    end
    -- The progress callback may have cancelled the message.
    if finished and rawget(handle, "_record") == record then
        completeSend(record, SEND_STATE.sent, nil)
    end
end

---Arrange the run after this one, or stop: nothing queued means no job and no
---sampler.
---@param currentTime number
---@param hitRunCap boolean
local function finishRun(currentTime, hitRunCap)
    if rawget(state, "queuedMessages") == 0 then
        stopDriver()
        return
    end
    if hitRunCap then
        scheduleDriver(0, "frame")
        return
    end
    local earliest = false
    for index = 1, #blockedPipes do
        local blockedUntil = rawget(blockedPipes[index], "blockedUntil")
        if earliest == false or blockedUntil < earliest then
            earliest = blockedUntil
        end
    end
    if earliest ~= false then
        scheduleDriver(math.max(earliest - currentTime, POLICY.dueToleranceSeconds), "blocked")
    end
end

---Send chunks until the bucket, the queue or the per-run cap runs out, then
---arrange the next run.
local function driveChunks()
    local currentTime = now()
    refill(currentTime)
    reinstatePipes(currentTime)

    for _ = 1, POLICY.maxChunksPerRun do
        local queue, ringIndex, slot = peekNextPipe()
        if queue == nil then
            finishRun(currentTime, false)
            return
        end
        local pipe = rawget(queue, "ring")[ringIndex]
        local record = rawget(pipe, "fifo")[1]
        assignStreamId(record)
        local chunk, payloadBytes = buildChunk(record)
        local cost = messageCost(#rawget(record, "prefix"), #chunk)
        local wait = secondsUntilAffordable(cost, currentTime)
        if wait > 0 then
            scheduleDriver(wait, "budget")
            return
        end

        advanceCursors(queue, ringIndex, slot)
        local outcome, reason = transmit(record, chunk)
        if outcome == SEND_STATE.sent then
            acceptChunk(record, pipe, cost, #chunk, payloadBytes)
        elseif outcome == "throttled" then
            setPipeAside(queue, pipe, currentTime)
        elseif rawget(record, "kind") == "abort" then
            finishAbort(record)
        else
            completeSend(record, SEND_STATE.failed, reason)
        end
    end
    finishRun(currentTime, true)
end

---One driver run. Called by the SchedulerKit job through the dispatch table.
---An internal error is reported and the driver retried a second later, or
---disarmed when nothing is queued, rather than left marked as running for the
---session.
local function runDriver()
    rawset(driver, "job", false)
    rawset(driver, "delayed", false)
    rawset(driver, "running", true)
    local ok, failure = pcall(driveChunks)
    rawset(driver, "running", false)
    if ok then
        return
    end
    reportError(failure)
    if rawget(state, "queuedMessages") > 0 then
        scheduleDriver(1, "retry")
    else
        stopDriver()
    end
end

-- Outside traffic ------------------------------------------------------------
--
-- The client's send functions are secure-hooked through HookKit, when HookKit
-- is present, so bytes other code sends are charged to the shared bucket.
-- `sendingOwnTraffic` is true while CommKit is inside the same functions, so
-- its own chunks are charged once.

---Charge an addon message another sender sent.
---@param prefix any
---@param text any
local function chargeOutsideAddon(prefix, text)
    if rawget(state, "sendingOwnTraffic") then
        return
    end
    local cost
    if type(prefix) ~= "string" or type(text) ~= "string" or isSecret(prefix) or isSecret(text) then
        cost = WIRE.unknownSizeBytes + rawget(limits, "messageOverhead")
    else
        cost = messageCost(#prefix, #text)
    end
    chargeOutside(cost)
    count("outsideMessages")
    count("outsideBytes", cost)
end

---Charge a chat message another sender sent.
---@param text any
local function chargeOutsideChat(text)
    if rawget(state, "sendingOwnTraffic") then
        return
    end
    local cost
    if type(text) ~= "string" or isSecret(text) then
        cost = WIRE.unknownSizeBytes + rawget(limits, "messageOverhead")
    else
        cost = messageCost(0, #text)
    end
    chargeOutside(cost)
    count("outsideMessages")
    count("outsideBytes", cost)
end

-- Only `installOutsideHooks` is used outside this block.
local installOutsideHooks

do
    ---Secure-hook one send function, on `C_ChatInfo` or as the legacy global.
    ---A refusal (no `hooksecurefunc`, say) leaves that function unmeasured.
    ---@param hookScope table
    ---@param name string
    ---@param handler function
    local function hookSender(hookScope, name, handler)
        local chatInfo = readHostTable("C_ChatInfo")
        if chatInfo ~= nil and type(rawget(chatInfo, name)) == "function" then
            pcall(hookScope.SecureHook, hookScope, chatInfo, name, handler)
        elseif readHostFunction(name) ~= nil then
            pcall(hookScope.SecureHook, hookScope, name, handler)
        end
    end

    ---Install the outside-traffic hooks once, when HookKit is present. Tried again
    ---every time the driver wakes from idle until HookKit is found.
    function installOutsideHooks()
        if rawget(state, "outsideHooks") ~= false then
            return
        end
        local HookKit = findOptional("hookKit", DEPENDENCY_API.hookKit)
        if HookKit == nil or type(rawget(HookKit, "CreateScope")) ~= "function" then
            return
        end
        local hookScope = HookKit:CreateScope()
        rawset(state, "outsideHooks", hookScope)
        hookSender(hookScope, "SendAddonMessage", rawget(trampolines, "outsideAddon"))
        hookSender(hookScope, "SendAddonMessageLogged", rawget(trampolines, "outsideAddon"))
        hookSender(hookScope, "SendChatMessage", rawget(trampolines, "outsideChat"))
    end
end

---Make sure a driver run is coming. During a run nothing is scheduled: the
---run picks the new message up or arranges its successor. A run already
---scheduled is kept, unless it waits only for a throttled pipe: the new
---message may use another pipe.
local function wakeDriver()
    if rawget(driver, "running") then
        return
    end
    local job = rawget(driver, "job")
    if job ~= false then
        if rawget(driver, "delayed") ~= "blocked" then
            return
        end
        job:Cancel()
    end
    local scope = getSchedulerScope()
    rawset(driver, "job", scope:Schedule(rawget(trampolines, "driver"), DRIVER_JOB_OPTIONS))
    rawset(driver, "delayed", false)
    startSampler()
    installOutsideHooks()
end

-- Reassembly -----------------------------------------------------------------
--
-- A received message is either one single chunk, delivered at once without a
-- table, or a stream: opened by its first chunk, keyed by prefix,
-- distribution, sender and stream id, and completed when every chunk arrived,
-- in any order after the first. Streams are bounded in count, in bytes per
-- sender (counted from the size the first chunk declares), in streams per
-- sender and in time since their last chunk. A chunk that would pass a bound,
-- or that names a stream CommKit does not hold, is refused and counted; a
-- stream that goes wrong after it opened is dropped and reported once.

---Fire the prefix's signal with one whole message.
---@param prefix string
---@param text string
---@param distribution string
---@param sender string
local function deliverMessage(prefix, text, distribution, sender)
    local signal = rawget(prefixSignals, prefix)
    if signal == nil then
        return
    end
    count("messagesReceived")
    count("bytesReceived", #text)
    signal:Fire(prefix, text, distribution, sender)
end

---Forget a stream and give back what it held; the last one disarms the
---expiry timer. Reports nothing.
---@param stream table
local function closeStream(stream)
    local sender = rawget(stream, "sender")
    rawset(streams, rawget(stream, "key"), nil)
    removeFromList(streamList, stream)

    local senderRecord = rawget(senders, sender)
    if senderRecord ~= nil then
        local remaining = rawget(senderRecord, "streams") - 1
        rawset(senderRecord, "streams", remaining)
        rawset(senderRecord, "bytes", rawget(senderRecord, "bytes") - rawget(stream, "reserved"))
        if remaining <= 0 then
            rawset(senders, sender, nil)
        end
    end

    rawget(pools, "parts"):Release(rawget(stream, "parts"))
    rawget(pools, "streams"):Release(stream)

    -- The expiry timer runs only while a stream is open.
    local timer = rawget(expiry, "timer")
    if #streamList == 0 and timer ~= false then
        rawset(expiry, "timer", false)
        rawset(expiry, "due", false)
        timer:Cancel()
    end
end

-- Only `noteDrop` and `flushDropReports` are used outside this block.
local noteDrop, flushDropReports

do
    ---Describe the drops pending in a report entry, reasons in a fixed order.
    ---@param entry table
    ---@return string
    local function describeDrops(entry)
        local reasons = rawget(entry, "reasons")
        local parts = {}
        for index = 1, #POLICY.dropReportOrder do
            local why = POLICY.dropReportOrder[index]
            local amount = rawget(reasons, why)
            if amount ~= nil then
                parts[#parts + 1] = amount .. " " .. why
            end
        end
        return table.concat(parts, ", ")
    end

    ---Report what one sender's entry holds, and start its quiet minute.
    ---@param sender string
    ---@param entry table
    ---@param currentTime number
    local function flushDropEntry(sender, entry, currentTime)
        local pending = rawget(entry, "pending")
        reportError(
            "CommKit dropped "
                .. pending
                .. (pending == 1 and " incomplete message from " or " incomplete messages from ")
                .. sender
                .. ": "
                .. describeDrops(entry)
        )
        rawset(entry, "pending", 0)
        rawset(entry, "reasons", {})
        rawset(entry, "reportedAt", currentTime)
    end

    ---Arm the flush timer for `due` unless it is already due no later.
    ---@param due number
    local function armDropFlush(due)
        local timer = rawget(dropReports, "timer")
        local armedFor = rawget(dropReports, "due")
        if timer ~= false and armedFor ~= false and armedFor <= due then
            return
        end
        if timer ~= false then
            timer:Cancel()
        end
        local delay = math.max(due - now(), 0)
        rawset(
            dropReports,
            "timer",
            getTimerScope():After(delay, rawget(trampolines, "flushDrops"))
        )
        rawset(dropReports, "due", due)
    end

    ---The flush timer fired: report every entry whose quiet minute is over and
    ---that has drops pending, forget entries with nothing pending, and arm the
    ---timer for the next one.
    function flushDropReports()
        rawset(dropReports, "timer", false)
        rawset(dropReports, "due", false)
        local currentTime = now()
        local bySender = rawget(dropReports, "bySender")
        local window = POLICY.dropReportSeconds
        ---@type number|nil
        local earliest = nil
        for sender, entry in pairs(bySender) do
            ---@type number|nil
            local due = rawget(entry, "reportedAt") + window
            if due <= currentTime + POLICY.dueToleranceSeconds then
                if rawget(entry, "pending") > 0 then
                    flushDropEntry(sender, entry, currentTime)
                    due = currentTime + window
                else
                    rawset(bySender, sender, nil)
                    rawset(dropReports, "count", rawget(dropReports, "count") - 1)
                    due = nil
                end
            end
            if due ~= nil and (earliest == nil or due < earliest) then
                earliest = due
            end
        end
        if earliest ~= nil then
            armDropFlush(earliest)
        end
    end

    ---Note a dropped stream or a refused first chunk of `sender`. The first drop
    ---of a sender is reported at once; later ones within the minute are counted
    ---and reported together when it ends, so a stranger can cause at most one
    ---report per minute. Past 64 senders the rest share one entry.
    ---@param sender string
    ---@param why string
    function noteDrop(sender, why)
        local bySender = rawget(dropReports, "bySender")
        local entry = rawget(bySender, sender)
        if entry == nil and rawget(dropReports, "count") >= POLICY.maxDropReportSenders then
            sender = POLICY.otherSenders
            entry = rawget(bySender, sender)
        end
        if entry == nil then
            entry = { reportedAt = false, pending = 0, reasons = {} }
            rawset(bySender, sender, entry)
            rawset(dropReports, "count", rawget(dropReports, "count") + 1)
        end
        rawset(entry, "pending", rawget(entry, "pending") + 1)
        local reasons = rawget(entry, "reasons")
        rawset(reasons, why, (rawget(reasons, why) or 0) + 1)

        local currentTime = now()
        local reportedAt = rawget(entry, "reportedAt")
        if reportedAt == false then
            flushDropEntry(sender, entry, currentTime)
            armDropFlush(currentTime + POLICY.dropReportSeconds)
        else
            armDropFlush(reportedAt + POLICY.dropReportSeconds)
        end
    end
end

---Drop an incomplete stream: count it by reason and note it for the sender's
---aggregated report. An aborted stream is dropped silently.
---@param stream table
---@param why string
local function dropStream(stream, why)
    local sender = rawget(stream, "sender")
    closeStream(stream)
    count(STATISTIC_FOR.drop[why])
    if why ~= DROP.aborted then
        noteDrop(sender, why)
    end
end

---Drop every stream of `prefix` without a report: nobody listens any more.
---@param prefix string
local function discardStreamsOf(prefix)
    local index = 1
    while index <= #streamList do
        local stream = streamList[index]
        if rawget(stream, "prefix") == prefix then
            closeStream(stream)
            count(STATISTIC_FOR.drop[DROP.discarded])
        else
            index = index + 1
        end
    end
end

---Arm the expiry timer for `deadline` unless it is already due no later.
---@param deadline number
local function armExpiry(deadline)
    local timer = rawget(expiry, "timer")
    local due = rawget(expiry, "due")
    if timer ~= false and due ~= false and due <= deadline then
        return
    end
    if timer ~= false then
        timer:Cancel()
    end
    local delay = math.max(deadline - now(), 0)
    rawset(expiry, "timer", getTimerScope():After(delay, rawget(trampolines, "expire")))
    rawset(expiry, "due", deadline)
end

---The expiry timer fired: drop every stream past its deadline, then arm the
---timer for the earliest one left.
local function onExpiryTimer()
    rawset(expiry, "timer", false)
    rawset(expiry, "due", false)
    local currentTime = now()
    local index = 1
    while index <= #streamList do
        local stream = streamList[index]
        if rawget(stream, "deadline") <= currentTime + POLICY.dueToleranceSeconds then
            dropStream(stream, DROP.expired)
        else
            index = index + 1
        end
    end

    local earliest = false
    for position = 1, #streamList do
        local deadline = rawget(streamList[position], "deadline")
        if earliest == false or deadline < earliest then
            earliest = deadline
        end
    end
    if earliest ~= false then
        armExpiry(earliest)
    end
end

---Open a stream from its first chunk.
---@param key string
---@param prefix string
---@param distribution string
---@param sender string
---@param total integer the chunk count the first chunk declares
---@param text string the whole chunk, header included
---@param scheme table the digit scheme of the channel it arrived on
local function openStream(key, prefix, distribution, sender, total, text, scheme)
    if
        total < 2
        or total > scheme.maxChunks
        or #text - WIRE.chunkHeaderBytes ~= WIRE.chunkPayloadBytes
    then
        count("chunksRefused")
        return
    end
    local existing = rawget(streams, key)
    if existing ~= nil then
        dropStream(existing, DROP.restarted)
    end

    local senderRecord = rawget(senders, sender)
    local senderStreams = senderRecord ~= nil and rawget(senderRecord, "streams") or 0
    local senderBytes = senderRecord ~= nil and rawget(senderRecord, "bytes") or 0
    local reserved = declaredBytes(total)
    if
        #streamList >= rawget(limits, "maxReassemblyStreams")
        or senderStreams >= rawget(limits, "maxInFlightPerSender")
        or senderBytes + reserved > rawget(limits, "maxReassemblyBytesPerSender")
    then
        count("chunksRefused")
        count(STATISTIC_FOR.drop[DROP.quota])
        noteDrop(sender, DROP.quota)
        return
    end

    if senderRecord == nil then
        senderRecord = { streams = 0, bytes = 0 }
        rawset(senders, sender, senderRecord)
    end
    rawset(senderRecord, "streams", senderStreams + 1)
    rawset(senderRecord, "bytes", senderBytes + reserved)

    local parts = rawget(pools, "parts"):Acquire()
    parts[1] = string.sub(text, WIRE.chunkHeaderBytes + 1)
    local stream = rawget(pools, "streams"):Acquire()
    stream.key = key
    stream.prefix = prefix
    stream.distribution = distribution
    stream.sender = sender
    stream.total = total
    stream.received = 1
    stream.reserved = reserved
    stream.parts = parts
    stream.deadline = now() + rawget(limits, "reassemblyTimeout")
    rawset(streams, key, stream)
    streamList[#streamList + 1] = stream
    count("streamsOpened")
    armExpiry(rawget(stream, "deadline"))
end

---Add a middle or last chunk to its stream, completing the message when it is
---the last one missing.
---@param control integer
---@param key string
---@param number integer the chunk's index
---@param text string the whole chunk, header included
local function continueStream(control, key, number, text)
    local stream = rawget(streams, key)
    if stream == nil then
        count("chunksRefused")
        return
    end
    local total = rawget(stream, "total")
    if control == WIRE.abort then
        -- The sender cancelled the message; the abort names its chunk count.
        if number == total then
            dropStream(stream, DROP.aborted)
        else
            count("chunksRefused")
        end
        return
    end
    local payloadLength = #text - WIRE.chunkHeaderBytes
    local parts = rawget(stream, "parts")
    if
        number < 2
        or number > total
        or (control == WIRE.last) ~= (number == total)
        or (control == WIRE.middle and payloadLength ~= WIRE.chunkPayloadBytes)
        or parts[number] ~= nil
    then
        count("chunksRefused")
        dropStream(stream, DROP.malformed)
        return
    end

    parts[number] = string.sub(text, WIRE.chunkHeaderBytes + 1)
    local received = rawget(stream, "received") + 1
    rawset(stream, "received", received)
    rawset(stream, "deadline", now() + rawget(limits, "reassemblyTimeout"))
    if received < total then
        return
    end

    local message = table.concat(parts, "", 1, total)
    local prefix = rawget(stream, "prefix")
    local distribution = rawget(stream, "distribution")
    local sender = rawget(stream, "sender")
    closeStream(stream)
    count("streamsCompleted")
    deliverMessage(prefix, message, distribution, sender)
end

---Route one chunk of a multi-chunk message, or an abort.
---@param control integer
---@param prefix string
---@param text string
---@param distribution string
---@param sender string
---@param logged boolean whether it arrived on the logged channel
local function receiveChunk(control, prefix, text, distribution, sender, logged)
    local length = #text
    if
        length < WIRE.chunkHeaderBytes
        or (length == WIRE.chunkHeaderBytes) ~= (control == WIRE.abort)
    then
        count("chunksRefused")
        return
    end
    local scheme = digitScheme(logged)
    local lowest, highest = scheme.offset, scheme.offset + scheme.radix - 1
    local streamByte, highByte, lowByte = string.byte(text, 2, 4)
    if
        streamByte < lowest
        or streamByte > highest
        or highByte < lowest
        or highByte > highest
        or lowByte < lowest
        or lowByte > highest
    then
        count("chunksRefused")
        return
    end
    local streamId = streamByte - lowest
    local number = (highByte - lowest) * scheme.radix + lowByte - lowest
    local key = prefix
        .. "\t"
        .. distribution
        .. "\t"
        .. sender
        .. (logged and "\tlogged\t" or "\t")
        .. streamId
    if control == WIRE.first then
        openStream(key, prefix, distribution, sender, number, text, scheme)
    else
        continueStream(control, key, number, text)
    end
end

---CHAT_MSG_ADDON and CHAT_MSG_ADDON_LOGGED. A single chunk is delivered
---without allocating a table.
---@param prefix any
---@param text any
---@param channel any
---@param sender any
---@param logged boolean true for CHAT_MSG_ADDON_LOGGED
local function onAddonMessage(prefix, text, channel, sender, logged)
    if
        type(prefix) ~= "string"
        or type(text) ~= "string"
        or type(channel) ~= "string"
        or type(sender) ~= "string"
    then
        return
    end
    -- A secret may not be used as a table key, compared or measured, so the
    -- check comes before the prefix lookup.
    if isSecret(prefix) or isSecret(text) or isSecret(channel) or isSecret(sender) then
        count("secretsDropped")
        return
    end
    local listeners = rawget(prefixCounts, prefix)
    if listeners == nil or listeners == 0 then
        return
    end

    count("chunksReceived")
    local control = string.byte(text, 1)
    if control == WIRE.single then
        deliverMessage(prefix, string.sub(text, 2), channel, sender)
    elseif control ~= nil and control >= WIRE.first and control <= WIRE.abort then
        receiveChunk(control, prefix, text, channel, sender, logged)
    else
        count("chunksRefused")
    end
end

-- Only `isGroupMember` is used outside this block.
local isGroupMember

do
    ---Whether the client places `name` in the player's group. A secret answer
    ---cannot be read and counts as a member.
    ---@param name string
    ---@param unitInParty function|nil
    ---@param unitInRaid function|nil
    ---@return boolean
    local function askGroupMembership(name, unitInParty, unitInRaid)
        if unitInParty ~= nil then
            local answer = unitInParty(name)
            if isSecret(answer) or answer then
                return true
            end
        end
        if unitInRaid ~= nil then
            local answer = unitInRaid(name)
            if isSecret(answer) or answer ~= nil then
                return true
            end
        end
        return false
    end

    ---Whether `sender` is in the player's group, asking with the full
    ---`Name-Realm` first and then with the name alone.
    ---@param sender string
    ---@param unitInParty function|nil
    ---@param unitInRaid function|nil
    ---@return boolean
    function isGroupMember(sender, unitInParty, unitInRaid)
        if askGroupMembership(sender, unitInParty, unitInRaid) then
            return true
        end
        local shortName = string.match(sender, "^([^%-]+)%-")
        if shortName == nil then
            return false
        end
        return askGroupMembership(shortName, unitInParty, unitInRaid)
    end
end

---GROUP_ROSTER_UPDATE: drop the group streams of senders no longer in the
---group.
local function onRosterUpdate()
    if #streamList == 0 then
        return
    end
    local unitInParty = readHostFunction("UnitInParty")
    local unitInRaid = readHostFunction("UnitInRaid")
    if unitInParty == nil and unitInRaid == nil then
        return
    end
    local index = 1
    while index <= #streamList do
        local stream = streamList[index]
        if
            GROUP_DISTRIBUTIONS[rawget(stream, "distribution")]
            and not isGroupMember(rawget(stream, "sender"), unitInParty, unitInRaid)
        then
            dropStream(stream, DROP.departed)
        else
            index = index + 1
        end
    end
end

-- Registrations --------------------------------------------------------------

---Connect the chat and roster events, once while any registration exists.
local function connectChatEvents()
    if rawget(state, "chatConnections") ~= false then
        return
    end
    local scope = getEventScope()
    rawset(state, "chatConnections", {
        scope:Connect("CHAT_MSG_ADDON", rawget(trampolines, "addonMessage")),
        scope:Connect("CHAT_MSG_ADDON_LOGGED", rawget(trampolines, "addonMessageLogged")),
        scope:Connect("GROUP_ROSTER_UPDATE", rawget(trampolines, "roster")),
    })
end

---Disconnect the chat and roster events: nothing is registered any more.
local function disconnectChatEvents()
    local connections = rawget(state, "chatConnections")
    if connections == false then
        return
    end
    rawset(state, "chatConnections", false)
    for index = 1, #connections do
        connections[index]:Disconnect()
    end
end

-- Only `registerClientPrefix` is used outside this block.
local registerClientPrefix

do
    ---Lower-case the first letter of an enum key, the form reasons take.
    ---@param name string
    ---@return string
    local function reasonFromEnumName(name)
        return string.lower(string.sub(name, 1, 1)) .. string.sub(name, 2)
    end

    ---Register `prefix` with the client once per session.
    ---@param prefix string
    ---@return boolean|nil registered
    ---@return string|nil reason
    function registerClientPrefix(prefix)
        if rawget(clientPrefixes, prefix) then
            return true, nil
        end
        local isRegistered = readChatFunction("IsAddonMessagePrefixRegistered")
        if isRegistered ~= nil and isRegistered(prefix) == true then
            rawset(clientPrefixes, prefix, true)
            return true, nil
        end
        local register = readChatFunction("RegisterAddonMessagePrefix")
        if register == nil then
            -- Outside a client there is nothing to register with.
            rawset(clientPrefixes, prefix, true)
            return true, nil
        end

        local result = register(prefix)
        if
            result == nil
            or result == true
            or result == readEnumValue(
                "RegisterAddonMessagePrefixResult",
                "Success",
                CLIENT_RESULT.registerSuccess
            )
            or result
                == readEnumValue(
                    "RegisterAddonMessagePrefixResult",
                    "DuplicatePrefix",
                    CLIENT_RESULT.registerDuplicate
                )
        then
            rawset(clientPrefixes, prefix, true)
            return true, nil
        end
        if result == false then
            return nil, "refused"
        end
        local name = readEnumName("RegisterAddonMessagePrefixResult", result)
        if name ~= nil then
            return nil, reasonFromEnumName(name)
        end
        return nil, CLIENT_RESULT.registerNames[result] or "unknownResult"
    end
end

---Register `callback` for whole messages on `prefix` in `scope`.
---@param scope CommKit.Scope
---@param prefix string
---@param callback function
---@return CommKit.Connection|nil connection
---@return string|nil reason
local function registerInScope(scope, prefix, callback)
    if rawget(scope, "_closed") then
        return nil, REASON.closed
    end
    local registrations = rawget(scope, "_registrations")
    if #registrations >= MAX_REGISTRATIONS then
        return nil, REASON.full
    end
    local registered, reason = registerClientPrefix(prefix)
    if not registered then
        return nil, reason
    end

    connectChatEvents()
    ensureWorldWatcher()
    local signal = rawget(prefixSignals, prefix)
    if signal == nil then
        signal = SignalKit:New()
        rawset(prefixSignals, prefix, signal)
    end
    local signalConnection = signal:Connect(function(...)
        rawget(dispatch, "isolatedCall")(callback, ...)
    end)

    local connection = setmetatable({
        _schema = LAYOUT.connection,
        _kind = "registration",
        _owner = scope,
        _prefix = prefix,
        _signalConnection = signalConnection,
        _connected = true,
    }, CONNECTION_METATABLE)
    registrations[#registrations + 1] = connection
    rawset(prefixCounts, prefix, (rawget(prefixCounts, prefix) or 0) + 1)
    rawset(state, "registrationTotal", rawget(state, "registrationTotal") + 1)
    return connection, nil
end

---Disconnect a registration or an OnChanged listener.
---@param connection CommKit.Connection
---@return boolean disconnected
local function disconnectConnection(connection)
    if not rawget(connection, "_connected") then
        return false
    end
    rawset(connection, "_connected", false)
    rawget(connection, "_signalConnection"):Disconnect()

    local owner = rawget(connection, "_owner")
    if rawget(connection, "_kind") ~= "registration" then
        removeFromList(rawget(owner, "_listeners"), connection)
        return true
    end

    removeFromList(rawget(owner, "_registrations"), connection)
    local prefix = rawget(connection, "_prefix")
    local remaining = rawget(prefixCounts, prefix) - 1
    rawset(prefixCounts, prefix, remaining)
    if remaining == 0 then
        discardStreamsOf(prefix)
    end
    local total = rawget(state, "registrationTotal") - 1
    rawset(state, "registrationTotal", total)
    if total == 0 then
        disconnectChatEvents()
    end
    return true
end

-- Content hashes -------------------------------------------------------------
--
-- A SyncSet field's version is the 32-bit FNV-1a hash of a canonical encoding
-- of its value: a scalar is CodecKit's serialisation of it (the writer is
-- canonical for scalars), and a table is the byte 0x0C, then every key and
-- value in sorted key order, each encoded the same way, then 0x0D. Keys sort
-- by type (booleans, then numbers, then strings), then by value, strings
-- byte by byte. Tables as keys are refused. `docs/API.md` has test vectors.
--
-- Lua 5.1 has no bit operations, so the hash is arithmetic on doubles: the
-- exclusive or touches only the low byte, and the multiplication by
-- 16777619 = 2^24 + 403 is split so every intermediate stays below 2^53.

-- Only `hashValue` is used outside this block.
local hashValue

do
    ---The exclusive or of two bytes.
    ---@param left integer
    ---@param right integer
    ---@return integer
    local function xorByte(left, right)
        local result = 0
        local bitValue = 1
        for _ = 1, 8 do
            local leftBit = left % 2
            local rightBit = right % 2
            if leftBit ~= rightBit then
                result = result + bitValue
            end
            left = (left - leftBit) / 2
            right = (right - rightBit) / 2
            bitValue = bitValue * 2
        end
        return result
    end

    ---Feed `bytes` into an FNV-1a hash.
    ---@param hash integer
    ---@param bytes string
    ---@return integer
    local function fnvUpdate(hash, bytes)
        for index = 1, #bytes do
            local low = hash % 256
            hash = hash - low + xorByte(low, string.byte(bytes, index))
            hash = ((hash % 256) * FNV.twoPow24 + hash * FNV.primeLow) % FNV.twoPow32
        end
        return hash
    end

    -- Sort rank of each key type in the canonical encoding.
    local KEY_TYPE_RANK = { boolean = 1, number = 2, string = 3 }

    ---Whether string `left` sorts before `right`, byte by byte. `<` on strings
    ---follows the C library's collation, which is not the same on every client.
    ---@param left string
    ---@param right string
    ---@return boolean
    local function stringBefore(left, right)
        local leftLength, rightLength = #left, #right
        for index = 1, math.min(leftLength, rightLength) do
            local leftByte, rightByte = string.byte(left, index), string.byte(right, index)
            if leftByte ~= rightByte then
                return leftByte < rightByte
            end
        end
        return leftLength < rightLength
    end

    ---The canonical order of two table keys.
    ---@param left any
    ---@param right any
    ---@return boolean
    local function keyBefore(left, right)
        local leftRank, rightRank = KEY_TYPE_RANK[type(left)], KEY_TYPE_RANK[type(right)]
        if leftRank ~= rightRank then
            return leftRank < rightRank
        end
        if leftRank == 1 then
            return left == false and right == true
        end
        if leftRank == 2 then
            return left < right
        end
        return stringBefore(left, right)
    end

    ---Hash the canonical encoding of `value` into `hash`.
    ---@param codec table CodecKit
    ---@param value any a value CodecKit already serialised successfully
    ---@param hash integer
    ---@return integer|nil hash
    ---@return string|nil reason
    local function hashCanonical(codec, value, hash)
        if type(value) ~= "table" then
            local _, bytes = codec:Serialize(value)
            return fnvUpdate(hash, bytes), nil
        end

        local keys = {}
        for key in pairs(value) do
            if KEY_TYPE_RANK[type(key)] == nil then
                return nil, "tableKey"
            end
            keys[#keys + 1] = key
        end
        table.sort(keys, keyBefore)

        hash = fnvUpdate(hash, FNV.canonicalOpen)
        for index = 1, #keys do
            local key = keys[index]
            local keyHash, keyReason = hashCanonical(codec, key, hash)
            if keyHash == nil then
                return nil, keyReason
            end
            local valueHash, valueReason = hashCanonical(codec, value[key], keyHash)
            if valueHash == nil then
                return nil, valueReason
            end
            hash = valueHash
        end
        return fnvUpdate(hash, FNV.canonicalClose), nil
    end

    ---The content hash of `value`, or `nil` and CodecKit's reason when it cannot
    ---be serialised (a cycle, a function, a limit), or `"tableKey"`.
    ---@param codec table CodecKit
    ---@param value any
    ---@return integer|nil hash
    ---@return string|nil reason
    function hashValue(codec, value)
        local ok, bytesOrReason = codec:Serialize(value)
        if not ok then
            return nil, bytesOrReason
        end
        local hash, reason = hashCanonical(codec, value, FNV.offsetBasis)
        return hash, reason
    end
end

-- SyncSet --------------------------------------------------------------------
--
-- A SyncSet holds this client's values for a fixed list of fields and a
-- bounded cache of the values peers delivered. The three verbs travel as
-- CodecKit frames for the addon channel, sent and received through the
-- SyncSet's own registration:
--
--   request   { 1, hashes }             the requester's hashes of our fields
--   ack       { 2 }                     every hash matched
--   deliver   { 3, values, removed }    only the fields whose hash differs

-- Forward declaration: the SyncSet sends through the same queue as scope:Send.
local enqueueSend

-- Only `encodeSyncMessage` and `receiveSync` are used outside this block.
local encodeSyncMessage, receiveSync

do
    ---Return the peer record for `sender`, creating it when `create` is true.
    ---When the cache is full, the least recently seen peer that was not
    ---answered within the reply interval is evicted; when every peer was, `nil`
    ---is returned, so an eviction can never lift a peer's reply interval.
    ---@param syncSet CommKit.SyncSet
    ---@param sender string
    ---@param create boolean
    ---@return table|nil
    local function obtainPeer(syncSet, sender, create)
        local peers = rawget(syncSet, "_peers")
        local touch = rawget(syncSet, "_touch") + 1
        rawset(syncSet, "_touch", touch)
        local peer = rawget(peers, sender)
        if peer ~= nil then
            rawset(peer, "touched", touch)
            return peer
        end
        if not create then
            return nil
        end

        if rawget(syncSet, "_peerCount") >= SYNC.maxPeers then
            local currentTime = now()
            local oldestName, oldestTouch = nil, nil
            for name, candidate in pairs(peers) do
                local touched = rawget(candidate, "touched")
                local repliedAt = rawget(candidate, "repliedAt")
                local throttled = repliedAt ~= false
                    and currentTime - repliedAt < SYNC.replyIntervalSeconds
                if not throttled and (oldestTouch == nil or touched < oldestTouch) then
                    oldestName, oldestTouch = name, touched
                end
            end
            if oldestName == nil then
                return nil
            end
            rawset(peers, oldestName, nil)
            rawset(syncSet, "_peerCount", rawget(syncSet, "_peerCount") - 1)
        end
        peer = { values = {}, hashes = {}, touched = touch, repliedAt = false, reply = false }
        rawset(peers, sender, peer)
        rawset(syncSet, "_peerCount", rawget(syncSet, "_peerCount") + 1)
        return peer
    end

    ---Encode a SyncSet message, or `nil` when CodecKit is gone or refuses it.
    ---@param message table
    ---@return string|nil
    function encodeSyncMessage(message)
        local codec = findOptional("codecKit", DEPENDENCY_API.codecKit)
        if codec == nil then
            return nil
        end
        local ok, text = codec:Encode(message, SYNC.codecOptions)
        if not ok then
            return nil
        end
        return text
    end

    ---Whether a reply to `peer` is still in the queue.
    ---@param peer table
    ---@return boolean
    local function replyPending(peer)
        local reply = rawget(peer, "reply")
        if reply == false then
            return false
        end
        local replyState = rawget(reply, "_state")
        return replyState == SEND_STATE.queued or replyState == SEND_STATE.sending
    end

    ---Queue a reply to `sender`, counting its bytes against the shared reply
    ---allowance until it is terminal.
    ---@param syncSet CommKit.SyncSet
    ---@param peer table
    ---@param sender string
    ---@param text string
    local function queueReply(syncSet, peer, sender, text)
        local length = #text
        if rawget(state, "syncReplyBytes") + length > SYNC.maxReplyBytes then
            count("syncReplyDropped")
            return
        end
        local handle
        handle = enqueueSend(
            rawget(syncSet, "_scope"),
            rawget(syncSet, "_prefix"),
            text,
            "WHISPER",
            sender,
            PRIORITY.NORMAL,
            false,
            false,
            function()
                rawset(state, "syncReplyBytes", rawget(state, "syncReplyBytes") - length)
                if rawget(peer, "reply") == handle then
                    rawset(peer, "reply", false)
                end
            end
        )
        if handle == nil then
            count("syncReplyDropped")
            return
        end
        rawset(state, "syncReplyBytes", rawget(state, "syncReplyBytes") + length)
        rawset(peer, "reply", handle)
    end

    ---Answer a request with an ack or a delta. Requests are answered only when
    ---whispered, at most once a second per peer, with at most one reply per
    ---peer in the queue and at most 8 KB of replies queued in all.
    ---@param syncSet CommKit.SyncSet
    ---@param claimed any the requester's hashes
    ---@param sender string
    ---@param distribution string
    local function answerRequest(syncSet, claimed, sender, distribution)
        if type(claimed) ~= "table" or distribution ~= "WHISPER" then
            count("syncRejected")
            return
        end
        count("syncRequests")
        local peer = obtainPeer(syncSet, sender, true)
        if peer == nil then
            count("syncReplyDropped")
            return
        end
        local currentTime = now()
        local repliedAt = rawget(peer, "repliedAt")
        if repliedAt ~= false and currentTime - repliedAt < SYNC.replyIntervalSeconds then
            count("syncRejected")
            return
        end
        if replyPending(peer) then
            count("syncReplyDropped")
            return
        end
        rawset(peer, "repliedAt", currentTime)

        local ownValues = rawget(syncSet, "_values")
        local ownHashes = rawget(syncSet, "_hashes")
        local fieldList = rawget(syncSet, "_fieldList")
        local values, removed = {}, {}
        local differs = false
        for index = 1, #fieldList do
            local field = fieldList[index]
            local mine = rawget(ownHashes, field)
            local theirs = rawget(claimed, field)
            if mine ~= nil and mine ~= theirs then
                values[field] = rawget(ownValues, field)
                differs = true
            elseif mine == nil and theirs ~= nil then
                removed[#removed + 1] = field
                differs = true
            end
        end

        local text
        if differs then
            text = encodeSyncMessage({ SYNC.deliver, values, removed })
        else
            text = encodeSyncMessage({ SYNC.ack })
        end
        if text ~= nil then
            queueReply(syncSet, peer, sender, text)
        end
    end

    ---Store a delivered value when it passes the field's schema and differs.
    ---@param syncSet CommKit.SyncSet
    ---@param codec table CodecKit
    ---@param peer table
    ---@param sender string
    ---@param field string
    ---@param value any
    local function acceptDelivered(syncSet, codec, peer, sender, field, value)
        local schemas = rawget(syncSet, "_schemas")
        local schema = schemas ~= false and rawget(schemas, field) or nil
        if schema ~= nil and schema:Check(value) ~= true then
            count("syncRejected")
            return
        end
        local hash = hashValue(codec, value)
        if hash == nil then
            count("syncRejected")
            return
        end
        local peerHashes = rawget(peer, "hashes")
        if rawget(peerHashes, field) == hash then
            return
        end
        rawset(rawget(peer, "values"), field, value)
        rawset(peerHashes, field, hash)
        rawget(syncSet, "_signal"):Fire(sender, field, value)
    end

    ---Apply a delivery: removed fields, then changed values. A field named in
    ---both is removed, once.
    ---@param syncSet CommKit.SyncSet
    ---@param codec table CodecKit
    ---@param values any
    ---@param removed any
    ---@param sender string
    local function applyDelivery(syncSet, codec, values, removed, sender)
        if type(values) ~= "table" or type(removed) ~= "table" then
            count("syncRejected")
            return
        end
        local peer = obtainPeer(syncSet, sender, true)
        if peer == nil then
            count("syncRejected")
            return
        end
        count("syncDeliveries")
        local fields = rawget(syncSet, "_fields")
        local fieldList = rawget(syncSet, "_fieldList")
        local peerValues = rawget(peer, "values")
        local peerHashes = rawget(peer, "hashes")
        local removedSet = {}
        for index = 1, #fieldList do
            local field = rawget(removed, index)
            if field == nil then
                break
            end
            if type(field) == "string" and rawget(fields, field) then
                removedSet[field] = true
                if rawget(peerHashes, field) ~= nil then
                    rawset(peerValues, field, nil)
                    rawset(peerHashes, field, nil)
                    rawget(syncSet, "_signal"):Fire(sender, field, nil)
                end
            end
        end

        for index = 1, #fieldList do
            local field = fieldList[index]
            local value = rawget(values, field)
            if value ~= nil and not removedSet[field] then
                acceptDelivered(syncSet, codec, peer, sender, field, value)
            end
        end
    end

    ---A SyncSet frame arrived on the SyncSet's prefix. Received data is
    ---untrusted: every shape is checked before use and a bad frame is counted.
    ---@param syncSet CommKit.SyncSet
    ---@param text string
    ---@param sender string
    ---@param distribution string
    function receiveSync(syncSet, text, sender, distribution)
        if rawget(syncSet, "_closed") then
            return
        end
        local codec = findOptional("codecKit", DEPENDENCY_API.codecKit)
        if codec == nil then
            return
        end
        local ok, message = codec:Decode(text, SYNC.codecOptions)
        if not ok or type(message) ~= "table" then
            count("syncRejected")
            return
        end
        local verb = rawget(message, 1)
        if verb == SYNC.request then
            answerRequest(syncSet, rawget(message, 2), sender, distribution)
        elseif verb == SYNC.ack then
            count("syncAcknowledgements")
            obtainPeer(syncSet, sender, false)
        elseif verb == SYNC.deliver then
            applyDelivery(syncSet, codec, rawget(message, 2), rawget(message, 3), sender)
        else
            count("syncRejected")
        end
    end
end

---Close a SyncSet: its registration and listeners go, its caches are
---dropped.
---@param syncSet CommKit.SyncSet
---@return boolean closed
local function closeSyncSet(syncSet)
    if rawget(syncSet, "_closed") then
        return false
    end
    rawset(syncSet, "_closed", true)
    disconnectConnection(rawget(syncSet, "_registration"))
    local listeners = rawget(syncSet, "_listeners")
    while #listeners > 0 do
        disconnectConnection(listeners[#listeners])
    end
    rawset(syncSet, "_peers", {})
    rawset(syncSet, "_peerCount", 0)
    removeFromList(rawget(rawget(syncSet, "_scope"), "_syncSets"), syncSet)
    return true
end

-- Send path ------------------------------------------------------------------

---Count a refusal and return it.
---@param reason string
---@return nil
---@return string reason
local function refuseSend(reason)
    count(STATISTIC_FOR.refusal[reason])
    return nil, reason
end

---Whether `target` is acceptable for `distribution`.
---@param distribution string
---@param target any
---@return boolean
local function targetFits(distribution, target)
    if distribution == "WHISPER" then
        return type(target) == "string" and target ~= ""
    end
    if distribution == "CHANNEL" then
        -- The client addresses a channel by its number.
        return type(target) == "number"
            or (type(target) == "string" and string.find(target, "^%d+$") ~= nil)
    end
    return true
end

---Queue a message after its arguments were validated. Returns the handle, or
---`nil` and the refusal. Shared by `scope:Send` and the SyncSet replies.
---@param scope CommKit.Scope
---@param prefix string
---@param text string
---@param distribution string
---@param target string|number|nil
---@param priority string
---@param logged boolean
---@param onProgress function|false
---@param onComplete function|false
---@return CommKit.SendHandle|nil handle
---@return string|nil reason
enqueueSend = function(
    scope,
    prefix,
    text,
    distribution,
    target,
    priority,
    logged,
    onProgress,
    onComplete
)
    if rawget(scope, "_closed") then
        return refuseSend(REASON.closed)
    end
    if not DISTRIBUTIONS[distribution] or not targetFits(distribution, target) then
        return refuseSend(REASON.badDistribution)
    end
    if not TARGETED_DISTRIBUTIONS[distribution] then
        target = nil
    end
    if string.find(text, WIRE.forbiddenBytePattern) ~= nil then
        return refuseSend(REASON.forbiddenByte)
    end

    local length = #text
    local totalChunks = 1
    if length > WIRE.singlePayloadBytes then
        totalChunks = math.ceil(length / WIRE.chunkPayloadBytes)
    end
    -- The two byte bounds also keep every message within the chunk numbers
    -- the header can write: see `LIMIT_RANGES`.
    local maxQueuedBytes = rawget(limits, "maxQueuedBytes")
    if
        length > maxQueuedBytes
        or (
            totalChunks > 1
            and declaredBytes(totalChunks) > rawget(limits, "maxReassemblyBytesPerSender")
        )
    then
        return refuseSend(REASON.tooLarge)
    end
    if
        rawget(state, "queuedMessages") >= rawget(limits, "maxQueuedMessages")
        or rawget(state, "queuedBytes") + length > maxQueuedBytes
    then
        return refuseSend(REASON.queueFull)
    end
    local functionName = logged and "SendAddonMessageLogged" or "SendAddonMessage"
    if readChatFunction(functionName) == nil then
        return refuseSend(REASON.unavailable)
    end

    local handle = setmetatable({
        _schema = LAYOUT.handle,
        _state = SEND_STATE.queued,
        _bytesSent = 0,
        _bytesTotal = length,
        _record = false,
    }, HANDLE_METATABLE)
    local record = rawget(pools, "records"):Acquire()
    record.kind = "message"
    record.inFlight = false
    record.handle = handle
    record.scope = scope
    record.prefix = prefix
    record.text = text
    record.textLength = length
    record.distribution = distribution
    record.target = target
    record.priority = priority
    record.logged = logged
    record.pipeKey = pipeKey(distribution, target, logged)
    record.totalChunks = totalChunks
    record.nextIndex = 1
    record.bytesSent = 0
    -- Assigned when the first chunk is built; see `assignStreamId`.
    record.streamId = false
    record.onProgress = onProgress
    record.onComplete = onComplete
    rawset(handle, "_record", record)

    enqueueRecord(record)
    local pending = rawget(scope, "_pending")
    pending[#pending + 1] = handle
    count("messagesQueued")
    wakeDriver()
    return handle, nil
end

---Validate a `scope:Send` request, raising at the caller for a programming
---error. Returns the fields `enqueueSend` takes.
---@param request any
---@param level integer
---@return string prefix, string text, any distribution, any target, string priority, boolean logged, function|false onProgress, function|false onComplete
local function readSendRequest(request, level)
    local label = "CommKit.Scope:Send request"
    if type(request) ~= "table" then
        error(label .. " must be a table", level)
    end
    validateKeys(request, OPTION_KEYS.sendRequest, label, level + 1)

    local prefix = rawget(request, "prefix")
    validateBoundedString(prefix, label .. ".prefix", WIRE.maxPrefixBytes, level + 1)

    local text = rawget(request, "text")
    if type(text) ~= "string" then
        error(label .. ".text must be a string", level)
    end
    if isSecret(text) then
        error(label .. ".text must not be a secret value", level)
    end

    local distribution = rawget(request, "distribution")
    if type(distribution) ~= "string" then
        error(label .. ".distribution must be a string", level)
    end
    if isSecret(distribution) then
        error(label .. ".distribution must not be a secret value", level)
    end

    -- A field may hold a secret, which may not even be compared with `nil`:
    -- only `type` and `isSecret` look at a value before it is known not to be.
    local target = rawget(request, "target")
    local targetType = type(target)
    if targetType ~= "nil" and targetType ~= "string" and targetType ~= "number" then
        error(label .. ".target must be a string, a number or nil", level)
    end
    if isSecret(target) then
        error(label .. ".target must not be a secret value", level)
    end

    local priority = rawget(request, "priority")
    if type(priority) == "nil" then
        priority = PRIORITY.NORMAL
    elseif type(priority) ~= "string" or isSecret(priority) or PRIORITY[priority] ~= priority then
        error(label .. ".priority must be CommKit.Priority.ALERT, NORMAL or BULK", level)
    end

    local logged = false
    local constraints = rawget(request, "constraints")
    local constraintsType = type(constraints)
    if constraintsType ~= "nil" then
        if constraintsType ~= "table" then
            error(label .. ".constraints must be a table or nil", level)
        end
        validateKeys(constraints, OPTION_KEYS.constraints, label .. ".constraints", level + 1)
        local loggedValue = rawget(constraints, "logged")
        local battleNet = rawget(constraints, "battleNet")
        if type(loggedValue) ~= "nil" and type(loggedValue) ~= "boolean" then
            error(label .. ".constraints.logged must be a boolean or nil", level)
        end
        if type(battleNet) ~= "nil" and type(battleNet) ~= "boolean" then
            error(label .. ".constraints.battleNet must be a boolean or nil", level)
        end
        if isSecret(loggedValue) or isSecret(battleNet) then
            error(label .. ".constraints must not hold a secret value", level)
        end
        logged = loggedValue == true
    end

    local onProgress = rawget(request, "onProgress")
    local onComplete = rawget(request, "onComplete")
    validateOptionalCallback(onProgress, label .. ".onProgress", level + 1)
    validateOptionalCallback(onComplete, label .. ".onComplete", level + 1)

    return prefix,
        text,
        distribution,
        target,
        priority,
        logged,
        onProgress or false,
        onComplete or false
end

---Cancel every send pending when the call began, oldest first. A completion
---callback that sends again does not extend the loop.
---@param scope CommKit.Scope
---@param reason string
---@return integer cancelled
local function cancelPending(scope, reason)
    local pending = rawget(scope, "_pending")
    local cancelled = 0
    for _ = 1, #pending do
        local handle = pending[1]
        if handle == nil then
            break
        end
        completeSend(rawget(handle, "_record"), SEND_STATE.cancelled, reason)
        cancelled = cancelled + 1
    end
    return cancelled
end

---Close every SyncSet of a scope, then disconnect its registrations.
---@param scope CommKit.Scope
---@return integer disconnected registrations, SyncSet ones included
local function releaseRegistrations(scope)
    local syncSets = rawget(scope, "_syncSets")
    local registrations = rawget(scope, "_registrations")
    local released = #registrations
    while #syncSets > 0 do
        closeSyncSet(syncSets[#syncSets])
    end
    while #registrations > 0 do
        disconnectConnection(registrations[#registrations])
    end
    return released
end

---Close a scope: cancel its sends, close its SyncSets, disconnect its
---registrations and stop observing its addon's shutdown. Terminal.
---@param scope CommKit.Scope
---@param reason string the reason cancelled sends report
---@return boolean closed `false` when it was already closed
local function closeScope(scope, reason)
    if rawget(scope, "_closed") then
        return false
    end
    rawset(scope, "_closed", true)
    cancelPending(scope, reason)
    releaseRegistrations(scope)
    local subscription = rawget(scope, "_shutdownSubscription")
    rawset(scope, "_shutdownSubscription", false)
    if subscription ~= false then
        subscription:Disconnect()
    end
    return true
end

-- Method tables --------------------------------------------------------------
--
-- Public methods are collected in one table per prototype and copied onto the
-- shared prototypes at commit, so a newer revision replaces every one of them.

local ConnectionMethods = {}
local HandleMethods = {}
local SyncSetMethods = {}
local ScopeMethods = {}
local FacadeMethods = {}

-- Connection methods ---------------------------------------------------------

---@param receiver any
---@param label string
---@param level integer
local function validateConnection(receiver, label, level)
    validateReceiver(receiver, CONNECTION_METATABLE, label, "CommKit connection", level + 1)
end

---Stop delivering to this registration or listener. Idempotent.
---@param self CommKit.Connection
---@return boolean disconnected `false` when it was already disconnected
function ConnectionMethods.Disconnect(self)
    validateConnection(self, "CommKit.Connection:Disconnect", 3)
    local disconnected = disconnectConnection(self)
    return disconnected
end

---@param self CommKit.Connection
---@return boolean
function ConnectionMethods.IsConnected(self)
    validateConnection(self, "CommKit.Connection:IsConnected", 3)
    return rawget(self, "_connected") == true
end

---@param self CommKit.Connection
---@return string
function ConnectionMethods.GetPrefix(self)
    validateConnection(self, "CommKit.Connection:GetPrefix", 3)
    return rawget(self, "_prefix")
end

-- Send handle methods --------------------------------------------------------

---@param receiver any
---@param label string
---@param level integer
local function validateHandle(receiver, label, level)
    validateReceiver(receiver, HANDLE_METATABLE, label, "CommKit send handle", level + 1)
end

---Cancel a queued or partly sent message. Chunks already sent stay sent; a
---partly sent message is followed by an abort chunk, so receivers drop the
---incomplete stream at once.
---@param self CommKit.SendHandle
---@return boolean cancelled `false` when the message was already terminal
function HandleMethods.Cancel(self)
    validateHandle(self, "CommKit.SendHandle:Cancel", 3)
    local record = rawget(self, "_record")
    if record == false then
        return false
    end
    completeSend(record, SEND_STATE.cancelled, REASON.cancelled)
    return true
end

---@param self CommKit.SendHandle
---@return CommKit.SendState
function HandleMethods.GetState(self)
    validateHandle(self, "CommKit.SendHandle:GetState", 3)
    return rawget(self, "_state")
end

---@param self CommKit.SendHandle
---@return integer
function HandleMethods.GetBytesSent(self)
    validateHandle(self, "CommKit.SendHandle:GetBytesSent", 3)
    return rawget(self, "_bytesSent")
end

---@param self CommKit.SendHandle
---@return integer
function HandleMethods.GetBytesTotal(self)
    validateHandle(self, "CommKit.SendHandle:GetBytesTotal", 3)
    return rawget(self, "_bytesTotal")
end

-- SyncSet methods ------------------------------------------------------------

---@param receiver any
---@param label string
---@param level integer
local function validateSyncSet(receiver, label, level)
    validateReceiver(receiver, SYNC_SET_METATABLE, label, "CommKit SyncSet", level + 1)
end

---Refuse a field the SyncSet was not declared with.
---@param syncSet CommKit.SyncSet
---@param field any
---@param label string
---@param level integer
local function validateField(syncSet, field, label, level)
    validateBoundedString(field, label .. " field", SYNC.maxFieldNameBytes, level + 1)
    if not rawget(rawget(syncSet, "_fields"), field) then
        error(label .. " field is not declared in this SyncSet", level)
    end
end

---Set this client's value of a field. `nil` clears it. The value is kept as
---given: change a table and call `Set` again to publish the change.
---@param self CommKit.SyncSet
---@param field string
---@param value any
---@return boolean|nil ok
---@return boolean|string|nil changedOrReason `true` when the hash changed, or the refusal
function SyncSetMethods.Set(self, field, value)
    validateSyncSet(self, "CommKit.SyncSet:Set", 3)
    validateField(self, field, "CommKit.SyncSet:Set", 3)
    if rawget(self, "_closed") then
        return nil, REASON.closed
    end
    if isSecret(value) then
        error("CommKit.SyncSet:Set value must not be a secret value", 2)
    end
    local values = rawget(self, "_values")
    local hashes = rawget(self, "_hashes")
    if value == nil then
        local changed = rawget(hashes, field) ~= nil
        rawset(values, field, nil)
        rawset(hashes, field, nil)
        return true, changed
    end

    local schemas = rawget(self, "_schemas")
    local schema = schemas ~= false and rawget(schemas, field) or nil
    if schema ~= nil and schema:Check(value) ~= true then
        return nil, REASON.schema
    end
    local codec =
        requireFound("codecKit", "CodecKit", DEPENDENCY_API.codecKit, "CommKit.SyncSet:Set", 3)
    local hashed, hash, reason = pcall(hashValue, codec, value)
    if not hashed then
        error("CommKit.SyncSet:Set value must not contain a secret value", 2)
    end
    if hash == nil then
        return nil, reason
    end
    if rawget(hashes, field) == hash then
        return true, false
    end
    rawset(values, field, value)
    rawset(hashes, field, hash)
    return true, true
end

---This client's value of a field, or `nil`.
---@param self CommKit.SyncSet
---@param field string
---@return any
function SyncSetMethods.Get(self, field)
    validateSyncSet(self, "CommKit.SyncSet:Get", 3)
    validateField(self, field, "CommKit.SyncSet:Get", 3)
    return rawget(rawget(self, "_values"), field)
end

---The content hash of this client's value of a field, or `nil` when unset.
---@param self CommKit.SyncSet
---@param field string
---@return integer|nil
function SyncSetMethods.GetHash(self, field)
    validateSyncSet(self, "CommKit.SyncSet:GetHash", 3)
    validateField(self, field, "CommKit.SyncSet:GetHash", 3)
    return rawget(rawget(self, "_hashes"), field)
end

---The last value `sender` delivered for a field, or `nil`.
---@param self CommKit.SyncSet
---@param sender string
---@param field string
---@return any
function SyncSetMethods.GetRemote(self, sender, field)
    validateSyncSet(self, "CommKit.SyncSet:GetRemote", 3)
    validateBoundedString(sender, "CommKit.SyncSet:GetRemote sender", 255, 3)
    validateField(self, field, "CommKit.SyncSet:GetRemote", 3)
    local peer = rawget(rawget(self, "_peers"), sender)
    if peer == nil then
        return nil
    end
    return rawget(rawget(peer, "values"), field)
end

---Ask `target` for the fields whose hash differs from the ones this client
---holds for it. The answer arrives as `OnChanged` calls, or as an ack.
---@param self CommKit.SyncSet
---@param target string
---@return CommKit.SendHandle|nil handle
---@return string|nil reason
function SyncSetMethods.Request(self, target)
    validateSyncSet(self, "CommKit.SyncSet:Request", 3)
    validateBoundedString(target, "CommKit.SyncSet:Request target", 255, 3)
    if rawget(self, "_closed") then
        return nil, REASON.closed
    end
    local peer = rawget(rawget(self, "_peers"), target)
    local hashes = peer ~= nil and rawget(peer, "hashes") or {}
    local text = encodeSyncMessage({ SYNC.request, hashes })
    if text == nil then
        return nil, REASON.unavailable
    end
    local handle, reason = enqueueSend(
        rawget(self, "_scope"),
        rawget(self, "_prefix"),
        text,
        "WHISPER",
        target,
        PRIORITY.NORMAL,
        false,
        false,
        false
    )
    return handle, reason
end

---Call `callback(sender, field, value)` when a peer's field changes; `value`
---is `nil` when the peer cleared it. At most 16 listeners per SyncSet.
---@param self CommKit.SyncSet
---@param callback CommKit.ChangedCallback
---@return CommKit.Connection|nil connection
---@return string|nil reason
function SyncSetMethods.OnChanged(self, callback)
    validateSyncSet(self, "CommKit.SyncSet:OnChanged", 3)
    validateCallback(callback, "CommKit.SyncSet:OnChanged callback", 3)
    if rawget(self, "_closed") then
        return nil, REASON.closed
    end
    local listeners = rawget(self, "_listeners")
    if #listeners >= SYNC.maxListeners then
        return nil, REASON.full
    end
    local signalConnection = rawget(self, "_signal"):Connect(function(...)
        rawget(dispatch, "isolatedCall")(callback, ...)
    end)
    local connection = setmetatable({
        _schema = LAYOUT.connection,
        _kind = "changed",
        _owner = self,
        _prefix = rawget(self, "_prefix"),
        _signalConnection = signalConnection,
        _connected = true,
    }, CONNECTION_METATABLE)
    listeners[#listeners + 1] = connection
    return connection, nil
end

---Close the SyncSet: its registration and listeners are disconnected and the
---peer cache is dropped. Terminal.
---@param self CommKit.SyncSet
---@return boolean closed `false` when it was already closed
function SyncSetMethods.Close(self)
    validateSyncSet(self, "CommKit.SyncSet:Close", 3)
    return closeSyncSet(self)
end

---@param self CommKit.SyncSet
---@return boolean
function SyncSetMethods.IsClosed(self)
    validateSyncSet(self, "CommKit.SyncSet:IsClosed", 3)
    return rawget(self, "_closed") == true
end

-- Scope methods --------------------------------------------------------------

---Register `callback` for whole messages on `prefix`. The prefix is
---registered with the client on first use. Returns `nil, "full"` past 32
---registrations, `nil, "closed"` on a closed scope, and the client's refusal
---(`"invalidPrefix"`, `"maxPrefixes"`, ...) when it refuses the prefix.
---@param self CommKit.Scope
---@param prefix string
---@param callback CommKit.ReceiveCallback
---@return CommKit.Connection|nil connection
---@return string|nil reason
function ScopeMethods.Register(self, prefix, callback)
    validateScope(self, "CommKit.Scope:Register", 3)
    validateBoundedString(prefix, "CommKit.Scope:Register prefix", WIRE.maxPrefixBytes, 3)
    validateCallback(callback, "CommKit.Scope:Register callback", 3)
    local connection, reason = registerInScope(self, prefix, callback)
    return connection, reason
end

---Queue a message. Returns a send handle, or `nil` and `"closed"`,
---`"badDistribution"`, `"forbiddenByte"`, `"tooLarge"`, `"queueFull"` or
---`"unavailable"`.
---@param self CommKit.Scope
---@param request CommKit.SendRequest
---@return CommKit.SendHandle|nil handle
---@return string|nil reason
function ScopeMethods.Send(self, request)
    validateScope(self, "CommKit.Scope:Send", 3)
    local prefix, text, distribution, target, priority, logged, onProgress, onComplete =
        readSendRequest(request, 3)
    local handle, reason = enqueueSend(
        self,
        prefix,
        text,
        distribution,
        target,
        priority,
        logged,
        onProgress,
        onComplete
    )
    return handle, reason
end

---Validate the `fields` option: 1 to 32 distinct names of 1 to 64 bytes.
---@param fields any
---@param level integer
---@return table<string, true> fieldSet
---@return string[] fieldList
local function readSyncFields(fields, level)
    local label = "CommKit.Scope:SyncSet options.fields"
    if type(fields) ~= "table" or #fields == 0 or #fields > SYNC.maxFields then
        error(label .. " must be an array of 1 to " .. SYNC.maxFields .. " field names", level)
    end
    local fieldSet, fieldList = {}, {}
    for index = 1, #fields do
        local field = fields[index]
        validateBoundedString(field, label .. " entry", SYNC.maxFieldNameBytes, level + 1)
        if fieldSet[field] then
            error(label .. " must not name a field twice", level)
        end
        fieldSet[field] = true
        fieldList[index] = field
    end
    return fieldSet, fieldList
end

---Validate the `schema` option: a sealed SchemaKit schema per declared field.
---@param schema any
---@param fieldSet table<string, true>
---@param level integer
---@return table|false
local function readSyncSchemas(schema, fieldSet, level)
    if type(schema) == "nil" then
        return false
    end
    local label = "CommKit.Scope:SyncSet options.schema"
    if type(schema) ~= "table" then
        error(label .. " must be a table of sealed SchemaKit schemas or nil", level)
    end
    local SchemaKit = requireFound(
        "schemaKit",
        "SchemaKit",
        DEPENDENCY_API.schemaKit,
        "CommKit.Scope:SyncSet options.schema",
        level + 1
    )
    local describe = rawget(rawget(SchemaKit, "Schema") or {}, "Describe")
    local schemas = {}
    for field, fieldSchema in pairs(schema) do
        if type(field) ~= "string" or not fieldSet[field] then
            error(label .. " names a field that is not declared", level)
        end
        if type(describe) ~= "function" or not pcall(describe, fieldSchema) then
            error(label .. "." .. field .. " must be a sealed SchemaKit schema", level)
        end
        schemas[field] = fieldSchema
    end
    return schemas
end

---Create a SyncSet on `prefix`. Requires CodecKit; `options.schema` requires
---SchemaKit. Returns `nil` and a reason when the prefix cannot be registered.
---@param self CommKit.Scope
---@param prefix string
---@param options CommKit.SyncSetOptions
---@return CommKit.SyncSet|nil syncSet
---@return string|nil reason
function ScopeMethods.SyncSet(self, prefix, options)
    validateScope(self, "CommKit.Scope:SyncSet", 3)
    validateBoundedString(prefix, "CommKit.Scope:SyncSet prefix", WIRE.maxPrefixBytes, 3)
    if type(options) ~= "table" then
        error("CommKit.Scope:SyncSet options must be a table", 2)
    end
    validateKeys(options, OPTION_KEYS.syncSet, "CommKit.Scope:SyncSet options", 3)
    local fieldSet, fieldList = readSyncFields(rawget(options, "fields"), 3)
    local schemas = readSyncSchemas(rawget(options, "schema"), fieldSet, 3)
    requireFound("codecKit", "CodecKit", DEPENDENCY_API.codecKit, "CommKit.Scope:SyncSet", 3)

    local syncSet = setmetatable({
        _schema = LAYOUT.syncSet,
        _scope = self,
        _prefix = prefix,
        _fields = fieldSet,
        _fieldList = fieldList,
        _schemas = schemas,
        _values = {},
        _hashes = {},
        _peers = {},
        _peerCount = 0,
        _touch = 0,
        _signal = SignalKit:New(),
        _listeners = {},
        _registration = false,
        _closed = false,
    }, SYNC_SET_METATABLE)

    local registration, reason = registerInScope(
        self,
        prefix,
        function(_, text, distribution, sender)
            rawget(dispatch, "receiveSync")(syncSet, text, sender, distribution)
        end
    )
    if registration == nil then
        return nil, reason
    end
    rawset(syncSet, "_registration", registration)
    local syncSets = rawget(self, "_syncSets")
    syncSets[#syncSets + 1] = syncSet
    return syncSet, nil
end

---Disconnect every registration and close every SyncSet; the scope stays
---usable.
---@param self CommKit.Scope
---@return integer released
function ScopeMethods.UnregisterAll(self)
    validateScope(self, "CommKit.Scope:UnregisterAll", 3)
    return releaseRegistrations(self)
end

---Cancel every pending send; the scope stays usable.
---@param self CommKit.Scope
---@return integer cancelled
function ScopeMethods.CancelAll(self)
    validateScope(self, "CommKit.Scope:CancelAll", 3)
    return cancelPending(self, REASON.cancelled)
end

---Close the scope: cancel its sends (reason `"closed"`), close its SyncSets,
---disconnect its registrations, then refuse new ones. Terminal.
---@param self CommKit.Scope
---@return boolean closed `false` when it was already closed
function ScopeMethods.Close(self)
    validateScope(self, "CommKit.Scope:Close", 3)
    return closeScope(self, REASON.closed)
end

---@param self CommKit.Scope
---@return boolean
function ScopeMethods.IsClosed(self)
    validateScope(self, "CommKit.Scope:IsClosed", 3)
    return rawget(self, "_closed") == true
end

---@param self CommKit.Scope
---@return string|nil
function ScopeMethods.GetAddonName(self)
    validateScope(self, "CommKit.Scope:GetAddonName", 3)
    local addonName = rawget(self, "_addonName")
    if addonName == false then
        return nil
    end
    return addonName
end

---@param self CommKit.Scope
---@return integer
function ScopeMethods.GetRegistrationCount(self)
    validateScope(self, "CommKit.Scope:GetRegistrationCount", 3)
    return #rawget(self, "_registrations")
end

---@param self CommKit.Scope
---@return integer
function ScopeMethods.GetPendingCount(self)
    validateScope(self, "CommKit.Scope:GetPendingCount", 3)
    return #rawget(self, "_pending")
end

-- Package public API ---------------------------------------------------------

---@param addonName string|false
---@return CommKit.Scope
local function newScope(addonName)
    ensureWorldWatcher()
    return setmetatable({
        _schema = LAYOUT.scope,
        _addonName = addonName,
        _closed = false,
        _registrations = {},
        _pending = {},
        _syncSets = {},
        _shutdownSubscription = false,
    }, SCOPE_METATABLE)
end

---Create a manually owned scope, closed only by its owner.
---@param self CommKit
---@return CommKit.Scope scope
function FacadeMethods.CreateScope(self)
    validateFacade(self, "CommKit:CreateScope", 3)
    return newScope(false)
end

---Return the canonical scope of an addon, creating it on demand. It is closed
---when the addon's LifecycleKit instance shuts down; sends still queued are
---cancelled with the reason `"shutdown"`.
---@param self CommKit
---@param addonName string addon folder name
---@return CommKit.Scope scope
function FacadeMethods.ForAddon(self, addonName)
    validateFacade(self, "CommKit:ForAddon", 3)
    if type(addonName) ~= "string" or isSecret(addonName) or addonName == "" then
        error("CommKit:ForAddon addonName must be a non-empty string", 2)
    end
    local scope = rawget(addonScopes, addonName)
    if scope ~= nil then
        return scope
    end

    scope = newScope(addonName)
    rawset(addonScopes, addonName, scope)
    local lifecycle = LifecycleKit:ForAddon(addonName)
    if lifecycle:IsShutdown() then
        rawset(scope, "_closed", true)
        return scope
    end
    local subscription = lifecycle:OnShutdown(function()
        rawget(dispatch, "closeScope")(scope, REASON.shutdown)
    end)
    rawset(scope, "_shutdownSubscription", subscription)
    return scope
end

---Close the canonical scope of an addon, as its shutdown does.
---@param self CommKit
---@param addonName string addon folder name
---@return boolean closed `false` when the addon has no scope or it was already closed
function FacadeMethods.CloseAddonScopes(self, addonName)
    validateFacade(self, "CommKit:CloseAddonScopes", 3)
    if type(addonName) ~= "string" or isSecret(addonName) or addonName == "" then
        error("CommKit:CloseAddonScopes addonName must be a non-empty string", 2)
    end
    local scope = rawget(addonScopes, addonName)
    if scope == nil then
        return false
    end
    return closeScope(scope, REASON.shutdown)
end

---Messages and text bytes queued in one priority, or in all of them.
---@param self CommKit
---@param priority CommKit.PriorityName?
---@return integer messages
---@return integer bytes
function FacadeMethods.GetQueueDepth(self, priority)
    validateFacade(self, "CommKit:GetQueueDepth", 3)
    if type(priority) == "nil" then
        return rawget(state, "queuedMessages"), rawget(state, "queuedBytes")
    end
    if type(priority) ~= "string" or isSecret(priority) or PRIORITY[priority] ~= priority then
        error(
            "CommKit:GetQueueDepth priority must be CommKit.Priority.ALERT, NORMAL, BULK or nil",
            2
        )
    end
    local queue = rawget(queues, priority)
    return rawget(queue, "messages"), rawget(queue, "bytes")
end

---The bucket now: bytes available (negative while repaying outside traffic),
---the refill rate in bytes per second, the capacity, and the mode
---(`"normal"`, `"lowFrameRate"` or `"zoning"`).
---@param self CommKit
---@return number available
---@return number bytesPerSecond
---@return number capacity
---@return string mode
function FacadeMethods.GetBudget(self)
    validateFacade(self, "CommKit:GetBudget", 3)
    local currentTime = now()
    refill(currentTime)
    local factor, capacity, mode = currentMode(currentTime)
    return rawget(budget, "tokens"), rawget(limits, "maxCps") * factor, capacity, mode
end

---Change any subset of the shared limits. Every value is checked before any
---is changed. Lowering a queue limit drops nothing already queued; lowering
---`maxReassemblyBytesPerSender` fails, as `"tooLarge"`, every queued message
---that has not started and now declares more.
---@param self CommKit
---@param newLimits CommKit.Limits
function FacadeMethods.SetLimits(self, newLimits)
    validateFacade(self, "CommKit:SetLimits", 3)
    if type(newLimits) ~= "table" then
        error("CommKit:SetLimits limits must be a table", 2)
    end
    validateKeys(newLimits, LIMIT_RANGES, "CommKit:SetLimits limits", 3)
    for name, value in pairs(newLimits) do
        local range = LIMIT_RANGES[name]
        if type(value) == "number" and isSecret(value) then
            error("CommKit:SetLimits limits." .. name .. " must not be a secret value", 2)
        end
        if
            type(value) ~= "number"
            or value ~= value
            or value < range.minimum
            or value > range.maximum
            or (range.integer and value ~= math.floor(value))
        then
            local kind = range.integer and "an integer" or "a number"
            error(
                "CommKit:SetLimits limits."
                    .. name
                    .. " must be "
                    .. kind
                    .. " from "
                    .. range.minimum
                    .. " to "
                    .. range.maximum,
                2
            )
        end
    end
    refill(now())
    for name, value in pairs(newLimits) do
        rawset(limits, name, value)
    end

    -- A message that has not started and declares more than the new bound
    -- could never start (see `headMayStart`) and would hold its pipe for the
    -- session, so it fails the way `Send` would now refuse it. The records are
    -- collected first: completing one runs a callback that may change the
    -- queue.
    local bound = rawget(newLimits, "maxReassemblyBytesPerSender")
    if bound == nil then
        return
    end
    local unstartable = {}
    for _, queue in pairs(queues) do
        for _, pipe in pairs(rawget(queue, "pipes")) do
            local fifo = rawget(pipe, "fifo")
            for index = 1, #fifo do
                local record = fifo[index]
                local totalChunks = rawget(record, "totalChunks")
                if
                    rawget(record, "kind") == "message"
                    and not rawget(record, "inFlight")
                    and totalChunks > 1
                    and declaredBytes(totalChunks) > bound
                then
                    unstartable[#unstartable + 1] = record
                end
            end
        end
    end
    for index = 1, #unstartable do
        local record = unstartable[index]
        -- An earlier callback may have cancelled it already.
        if rawget(rawget(record, "handle"), "_record") == record then
            completeSend(record, SEND_STATE.failed, REASON.tooLarge)
        end
    end
end

---A fresh copy of the shared limits.
---@param self CommKit
---@return CommKit.Limits
function FacadeMethods.GetLimits(self)
    validateFacade(self, "CommKit:GetLimits", 3)
    local copy = {}
    for index = 1, #LIMIT_NAMES do
        local name = LIMIT_NAMES[index]
        copy[name] = rawget(limits, name)
    end
    return copy
end

---A fresh copy of the counters, plus the current queue and stream totals.
---@param self CommKit
---@return table<string, integer>
function FacadeMethods.GetStatistics(self)
    validateFacade(self, "CommKit:GetStatistics", 3)
    local copy = {}
    for index = 1, #STATISTIC_NAMES do
        local name = STATISTIC_NAMES[index]
        copy[name] = rawget(statistics, name)
    end
    copy.queuedMessages = rawget(state, "queuedMessages")
    copy.queuedBytes = rawget(state, "queuedBytes")
    copy.openStreams = #streamList
    return copy
end

-- Commit ---------------------------------------------------------------------

---Copy every function of `methods` onto `prototype`.
---@param prototype table
---@param methods table<string, function>
local function commitMethods(prototype, methods)
    for name, method in pairs(methods) do
        rawset(prototype, name, method)
    end
end

commitMethods(Connection, ConnectionMethods)
commitMethods(SendHandle, HandleMethods)
commitMethods(SyncSetPrototype, SyncSetMethods)
commitMethods(Scope, ScopeMethods)
commitMethods(CommKit, FacadeMethods)

rawset(CommKit, "API", API_GENERATION)
rawset(CommKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(CommKit, "MAX_MESSAGE_BYTES", WIRE.maxMessageBytes)
rawset(CommKit, "MAX_REGISTRATIONS", MAX_REGISTRATIONS)
rawset(CommKit, "Priority", {
    ALERT = PRIORITY.ALERT,
    NORMAL = PRIORITY.NORMAL,
    BULK = PRIORITY.BULK,
})

-- Everything another Kit calls back into goes through this table, so a newer
-- revision replaces the behaviour behind callbacks an older one handed out.
rawset(dispatch, "isolatedCall", isolatedCall)
rawset(dispatch, "runDriver", runDriver)
rawset(dispatch, "sampleFrameRate", sampleFrameRate)
rawset(dispatch, "onExpiryTimer", onExpiryTimer)
rawset(dispatch, "flushDropReports", flushDropReports)
rawset(dispatch, "onAddonMessage", onAddonMessage)
rawset(dispatch, "onRosterUpdate", onRosterUpdate)
rawset(dispatch, "onEnteringWorld", onEnteringWorld)
rawset(dispatch, "chargeOutsideAddon", chargeOutsideAddon)
rawset(dispatch, "chargeOutsideChat", chargeOutsideChat)
rawset(dispatch, "receiveSync", receiveSync)
rawset(dispatch, "closeScope", closeScope)

-- The trampolines are created once per session and handed to EventKit,
-- TimerKit, SchedulerKit and HookKit; they only look up the dispatch table.
-- Each missing one is created, so a later revision can add one.
for name, trampoline in pairs({
    driver = function()
        rawget(dispatch, "runDriver")()
    end,
    sample = function()
        rawget(dispatch, "sampleFrameRate")()
    end,
    expire = function()
        rawget(dispatch, "onExpiryTimer")()
    end,
    flushDrops = function()
        rawget(dispatch, "flushDropReports")()
    end,
    -- Only the first four event arguments are passed on: the fifth, the
    -- target, is a foreign value that must not reach the `logged` slot.
    addonMessage = function(_, prefix, text, channel, sender)
        rawget(dispatch, "onAddonMessage")(prefix, text, channel, sender, false)
    end,
    addonMessageLogged = function(_, prefix, text, channel, sender)
        rawget(dispatch, "onAddonMessage")(prefix, text, channel, sender, true)
    end,
    roster = function()
        rawget(dispatch, "onRosterUpdate")()
    end,
    enteringWorld = function()
        rawget(dispatch, "onEnteringWorld")()
    end,
    outsideAddon = function(prefix, text)
        rawget(dispatch, "chargeOutsideAddon")(prefix, text)
    end,
    outsideChat = function(text)
        rawget(dispatch, "chargeOutsideChat")(text)
    end,
}) do
    if rawget(trampolines, name) == nil then
        rawset(trampolines, name, trampoline)
    end
end

rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(CommKit) or not validateCurrentState(CommKit) then
    error("MoltenCodes CommKit package state is corrupted or incomplete", 2)
end

return CommKit
