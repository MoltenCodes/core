-- MoltenCodes Test: CodecKitSuite.lua
--
-- Real-client suites for the `codecKit` package. The Busted specs under
-- packages/codecKit/tests/ prove CodecKit on a stock Lua 5.1 interpreter with
-- a seeded generator, a zlib-made fixture stream and a stand-in secret; these
-- prove, inside the game client with the installed MoltenCodes addon, what that
-- fixture can only simulate:
--
--   * the installed facade and its committed revision, and what the client's
--     Lua offers CodecKit: `string.byte`, `string.char`, `math.frexp`,
--     `math.ldexp` and `unpack` (CodecKit computes with nothing else; it never
--     uses a `bit` library, whose presence is logged), plus `C_EncodingUtil`,
--     `C_ChatInfo.SendAddonMessage`, `issecretvalue` and SchedulerKit;
--   * the documented wire bytes and bit-exact number round trips on the
--     client's own floating-point functions, every byte value through every
--     stage combination, and argument lists with `nil`s through `unpack`;
--   * that addon-channel text holds only bytes `C_ChatInfo.SendAddonMessage`
--     carries (checked against the byte rules docs/API.md states; nothing is
--     sent), and that a print export string survives chat-style wrapping;
--   * interoperability with the client's own raw DEFLATE: CodecKit's output
--     inflated by `C_EncodingUtil.DecompressString`, and the client's
--     `C_EncodingUtil.CompressString` output inflated by CodecKit, with the
--     client's Base64 and CBOR logged next to CodecKit's print channel and
--     serialiser for the same input (sizes and milliseconds);
--   * the cost on the client of a realistic 50 KB table, synchronously and
--     through `EncodeAsync`/`DecodeAsync` on a SchedulerKit scope;
--   * that no decoder raises on a few thousand strings made by the client's
--     `math.random`, and every refusal is from the documented vocabulary;
--   * the allocation-free paths docs/API.md promises, on the client's own
--     collector;
--   * argument errors, and secret values made by the client's `secretwrap`
--     refused at the calling line in this file as the client names it.
--
-- Nothing here needs combat, a group or an instance, nothing is drawn and
-- nothing is sent: `C_ChatInfo.SendAddonMessage` is only looked up. No client
-- setting is changed.
--
-- Run with `/mct run codecKit`; tests/client/MoltenCodesTest_CodecKit/EXPECTED.md
-- lists what the chat frame should show.
--
-- What a run leaves behind. Every SchedulerKit scope a test creates is closed
-- by the After hook of its suite, whatever the test's outcome, which cancels
-- any job still queued on it. CodecKit's package-wide limits are never changed:
-- the two `SetLimits` calls are refusals the tests check. CodecKit's table pool
-- keeps up to 16 idle tables, as it does after any use. Nothing is written to a
-- global or a saved variable.

local addonName = ...

-- The harness is this addon's dependency and publishes one documented global.
-- selene: allow(global_usage)
local Harness = rawget(_G, "MoltenCodesTest")
-- The shared MoltenCodes namespace is the one documented global handoff point.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
if type(Harness) ~= "table" or type(namespace) ~= "table" then
  error(addonName .. " requires the MoltenCodesTest harness and the MoltenCodes addon", 0)
end

local REGISTRY_API = 2
local CODEC_KIT_API = 1
local SCHEDULER_KIT_API = 1
local PACKAGE_ID = "codecKit"

--- The file name the client puts in front of every error raised at a line of
--- this file.
local THIS_FILE = "CodecKitSuite.lua"

--- The five bytes docs/API.md ("Addon channel") says the addon channel cannot
--- carry raw, by code: NUL, line feed, carriage return, `|` and the escape byte.
local FORBIDDEN_ADDON_BYTES = { [0] = true, [10] = true, [13] = true, [124] = true }
local ADDON_ESCAPE_BYTE = 255
local ADDON_ESCAPE_DIGIT_FIRST = 48 -- "0"
local ADDON_ESCAPE_DIGIT_LAST = 52 -- "4"

--- The client's limit on one addon message (CommKit's `MAX_MESSAGE_BYTES`).
--- CodecKit does not split; the channel tests log how many frames pass it.
local ADDON_MESSAGE_LIMIT_BYTES = 255

--- Every reason docs/API.md lists ("The non-raising contract"), except
--- `"secret"`, which only an `EncodeAsync` callback receives.
local REASON_VOCABULARY = {
  cycle = true,
  unsupportedType = true,
  maxDepth = true,
  maxValues = true,
  maxStringLength = true,
  maxOutputBytes = true,
  truncated = true,
  trailingData = true,
  unsupportedVersion = true,
  malformedHeader = true,
  channelMismatch = true,
  forbiddenByte = true,
  malformedEscape = true,
  malformedPrint = true,
  malformedDeflate = true,
  unknownType = true,
  malformedNumber = true,
  invalidKey = true,
  duplicateKey = true,
  nilValue = true,
  multipleValues = true,
}

--- The six methods docs/API.md promises never raise on a string.
local DECODER_NAMES = {
  "Decode",
  "DecodeMany",
  "Deserialize",
  "Decompress",
  "DecodeForAddon",
  "DecodeForPrint",
}

--- How many strings each fuzz test feeds to all six decoders, and how many
--- inputs run between two yields so no slice nears the runaway threshold.
local FUZZ_RANDOM_COUNT = 1000
local FUZZ_HEADER_COUNT = 1000
local FUZZ_MUTATION_COUNT = 1000
local FUZZ_PRINT_COUNT = 500
local FUZZ_BATCH = 50

--- The longest random string a fuzz test makes.
local FUZZ_MAX_LENGTH = 64

--- How many random payloads the addon-channel test encodes, and the longest.
local ADDON_PAYLOAD_COUNT = 300
local ADDON_PAYLOAD_MAX_LENGTH = 400

--- The realistic payload: a guild roster of this many members serialises to
--- about 51 KB (177 bytes per member). The performance test checks the size.
local ROSTER_MEMBER_COUNT = 288
local PAYLOAD_MIN_BYTES = 48 * 1024
local PAYLOAD_MAX_BYTES = 56 * 1024

--- How long a performance test may take, and how long it waits for an
--- asynchronous job: at SchedulerKit's 2 ms frame budget the 50 KB job spans
--- dozens of rendered frames.
local PERFORMANCE_TIMEOUT_SECONDS = 30
local ASYNC_WAIT_SECONDS = 20

--- How many calls each allocation guard measures, and the kilobytes it
--- tolerates. One table per call would cost well over a hundred kilobytes; the
--- tolerance absorbs a stray allocation by the client between two readings.
local ALLOCATION_CALLS = 2000
local ALLOCATION_TOLERANCE_KB = 1

--- A 32-byte message: under the 64 bytes below which `Compress` skips matching.
local SHORT_MESSAGE = string.rep("sync:42;", 4)

--- The encode options of an export string, as README.md shows it.
local EXPORT_OPTIONS = { compress = "deflate", channel = "print" }

-- Resolving the client and the framework ---------------------------------------------

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- The clocks, C_EncodingUtil, C_ChatInfo, Enum, the bit library and the
  -- secret-value functions are World of Warcraft client globals, reachable
  -- only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Read a function from a client namespace table such as `C_EncodingUtil`, or `nil`.
---@param namespaceName string
---@param functionName string
---@return function|nil
local function readHostFunction(namespaceName, functionName)
  local hostNamespace = readHost(namespaceName)
  if type(hostNamespace) ~= "table" then
    return nil
  end
  local candidate = hostNamespace[functionName]
  if type(candidate) ~= "function" then
    return nil
  end
  return candidate
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, REGISTRY_API)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- CodecKit is not in the language-server workspace of tests/client (its
-- .luarc.json lists TestKit's dependency closure only), so its facade is
-- typed `any` here.

---@type any
local CodecKit = Registry:Get(PACKAGE_ID, CODEC_KIT_API)
if type(CodecKit) == "nil" then
  error(addonName .. " requires CodecKit API 1 in the MoltenCodes addon; reinstall it", 0)
end

--- SchedulerKit is in TestKit's closure, so the harness always has it; the
--- asynchronous tests and the scope refusals need it.
---@type SchedulerKit|nil
local SchedulerKit = Registry:Get("schedulerKit", SCHEDULER_KIT_API)
if type(SchedulerKit) == "nil" then
  error(addonName .. " requires SchedulerKit API 1 in the MoltenCodes addon; reinstall it", 0)
end
---@cast SchedulerKit SchedulerKit

--- The CPU clock in milliseconds every timing below reads; SchedulerKit's
--- frame budget is measured on the same one.
local debugProfileStop = readHost("debugprofilestop")
local getTime = readHost("GetTime")
if type(debugProfileStop) ~= "function" or type(getTime) ~= "function" then
  error(addonName .. " requires the client's debugprofilestop and GetTime", 0)
end

--- Read once at load: the secrets suite registers its tests as skipped when
--- the client cannot make a secret value.
local isSecretValue = readHost("issecretvalue")
local secretWrap = readHost("secretwrap")
local SECRETS_AVAILABLE = type(isSecretValue) == "function" and type(secretWrap) == "function"

--- The client's own encoders, read once at load: the interoperability suite
--- registers its tests as skipped without the two DEFLATE functions.
local compressString = readHostFunction("C_EncodingUtil", "CompressString")
local decompressString = readHostFunction("C_EncodingUtil", "DecompressString")
local encodeBase64 = readHostFunction("C_EncodingUtil", "EncodeBase64")
local decodeBase64 = readHostFunction("C_EncodingUtil", "DecodeBase64")
local serializeCBOR = readHostFunction("C_EncodingUtil", "SerializeCBOR")
local deserializeCBOR = readHostFunction("C_EncodingUtil", "DeserializeCBOR")
local INTEROP_AVAILABLE = type(compressString) == "function"
  and type(decompressString) == "function"

---The value of `Enum.<enumName>.<fieldName>`, or the value the client's
---documentation gives it (packages/apiKit/metadata/retail/enums.json) when
---the client has no such entry, and which of the two it is.
---@param enumName string
---@param fieldName string
---@param documentedValue integer
---@return integer value
---@return string source `"Enum"` or `"documented"`
local function enumValue(enumName, fieldName, documentedValue)
  local enums = readHost("Enum")
  local group = type(enums) == "table" and enums[enumName] or nil
  local value = type(group) == "table" and group[fieldName] or nil
  if type(value) == "number" then
    return value, "Enum"
  end
  return documentedValue, "documented"
end

---The CPU clock, in milliseconds.
---@return number
local function cpuNow()
  return debugProfileStop()
end

---Milliseconds, for the log.
---@param elapsed number
---@return string
local function milliseconds(elapsed)
  return ("%.2f ms"):format(elapsed)
end

---The first `limit` bytes of `text` in hexadecimal, for a log line.
---@param text string
---@param limit integer
---@return string
local function hex(text, limit)
  local shown = text:sub(1, limit)
  local digits = shown:gsub(".", function(character)
    return ("%02X"):format(character:byte())
  end)
  if #text > limit then
    return digits .. ("... (%d bytes)"):format(#text)
  end
  return digits .. (" (%d bytes)"):format(#text)
end

---A string of `length` bytes from the client's `math.random`. Built in
---pieces, so `unpack` never passes a few hundred values.
---@param length integer
---@return string
local function randomBytes(length)
  local pieces = {}
  local codes = {}
  local position = 0
  while position < length do
    local count = math.min(256, length - position)
    for index = 1, count do
      codes[index] = math.random(0, 255)
    end
    pieces[#pieces + 1] = string.char(unpack(codes, 1, count))
    position = position + count
  end
  return table.concat(pieces)
end

---Every byte value once, 0 to 255 in order.
---@return string
local function everyByte()
  local codes = {}
  for code = 0, 255 do
    codes[code + 1] = code
  end
  return string.char(unpack(codes, 1, 256))
end

-- Payloads ----------------------------------------------------------------------------------

--- Class and zone names the roster payload draws from.
local ROSTER_CLASSES = {
  "WARRIOR",
  "PALADIN",
  "HUNTER",
  "ROGUE",
  "PRIEST",
  "DEATHKNIGHT",
  "SHAMAN",
  "MAGE",
  "WARLOCK",
  "MONK",
  "DRUID",
  "DEMONHUNTER",
  "EVOKER",
}
local ROSTER_ZONES = {
  "Dornogal",
  "Isle of Dorn",
  "The Ringing Deeps",
  "Hallowfall",
  "Azj-Kahet",
  "Undermine",
  "K'aresh",
}

---A realistic payload: a guild roster an addon would sync or export, with
---strings, integers, fractions, booleans and a small array per member. The
---same table every time, so its serialised size is fixed.
---@return table
local function buildRoster()
  local members = {}
  for index = 1, ROSTER_MEMBER_COUNT do
    members[index] = {
      name = ("Member%03d-Realm%d"):format(index, index % 7),
      class = ROSTER_CLASSES[1 + index % #ROSTER_CLASSES],
      level = 80,
      itemLevel = 640 + (index * 7) % 45,
      rating = index * 13.25 + 0.5,
      online = index % 3 == 0,
      zone = ROSTER_ZONES[1 + index % #ROSTER_ZONES],
      note = "raid team " .. (index % 4) .. ", joined week " .. (index % 52),
      lastSeen = 1790000000 + index * 3607,
      keystones = { index % 20, (index * 3) % 20, (index * 7) % 20 },
    }
  end
  return { version = 3, guild = "Molten Codes", members = members }
end

---About 10 KB of English-like text with numbers, as a compression input.
---@return string
local function buildProse()
  local sentences = {}
  for index = 1, 160 do
    sentences[index] = ("Week %d: the raid cleared %d bosses, and %s kept the notes for %s."):format(
      index,
      index % 9,
      ROSTER_CLASSES[1 + index % #ROSTER_CLASSES],
      ROSTER_ZONES[1 + index % #ROSTER_ZONES]
    )
  end
  return table.concat(sentences, " ")
end

--- A value of every kind in a small table, longer than 64 bytes serialised so
--- the compressor matches it. The mutation fuzz test starts from its frames.
local SAMPLE_VALUE = {
  kind = "sync",
  version = 3,
  list = { 1, 2.5, "three", true, false },
  map = { a = 1, b = { c = "d" } },
  text = string.rep("molten codes ", 8),
}

-- Scopes of the running test -----------------------------------------------------------

--- SchedulerKit scopes the running test created; the After hook closes them.
---@type SchedulerKit.Scope[]
local trackedScopes = {}

---Remember `scope` for the After hook and hand it back.
---@param scope SchedulerKit.Scope
---@return SchedulerKit.Scope scope
local function trackScope(scope)
  trackedScopes[#trackedScopes + 1] = scope
  return scope
end

---Close every scope the running test created, which cancels any job still
---queued on it. The After hook of every suite.
local function cleanUp()
  for index = #trackedScopes, 1, -1 do
    local scope = trackedScopes[index]
    trackedScopes[index] = nil
    pcall(scope.Close, scope)
  end
end

---Register a suite of this package whose tests all end with every scope closed.
---@param part string
---@param options MoltenCodesTest.SuiteOptions|nil
---@return TestKit.Suite
local function newSuite(part, options)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName, options)
  suite:After(cleanUp)
  return suite
end

---`ctx:WaitUntil(predicate, timeoutSeconds)`, returning only whether the
---predicate became truthy in time.
---
---The call goes through an untyped alias because the LuaCATS field TestKit
---declares for `WaitUntil` reads to lua-language-server as a predicate
---returning two values, so a direct call is reported as passing one argument
---too many (the SchedulerKit suite does the same).
---@param ctx TestKit.Context
---@param predicate fun(): any
---@param timeoutSeconds number
---@return boolean satisfied
local function waitUntil(ctx, predicate, timeoutSeconds)
  ---@type any
  local context = ctx
  local satisfied = context:WaitUntil(predicate, timeoutSeconds)
  return satisfied == true
end

-- Package state checks --------------------------------------------------------------------

---How many tables CodecKit's pool has leased and not returned. The pool is
---`CodecKit._state.pool` (docs/INTERNALS.md, "Package state").
---@return integer
local function leasedTableCount()
  local state = rawget(CodecKit, "_state")
  return state.pool:GetActiveCount()
end

---Fail the test when a pooled table is still leased or a limit changed.
---@param ctx TestKit.Context
---@param limitsBefore table what `GetLimits` answered before the test's work
local function expectPackageStateUnchanged(ctx, limitsBefore)
  ctx:Expect(leasedTableCount()):ToBe(0)
  ctx:Expect(CodecKit:GetLimits()):ToEqual(limitsBefore)
end

-- Addon-channel bytes ---------------------------------------------------------------------

---The first place `text` breaks the addon channel's byte rules, or `nil`:
---a raw NUL, line feed, carriage return or `|`, or an escape byte not followed
---by a digit from 0 to 4 (docs/API.md, "Addon channel").
---@param text string
---@return integer|nil position
---@return string|nil problem
local function findAddonViolation(text)
  local length = #text
  local position = 1
  while position <= length do
    local code = text:byte(position)
    if FORBIDDEN_ADDON_BYTES[code] then
      return position, ("raw byte %d"):format(code)
    end
    if code == ADDON_ESCAPE_BYTE then
      local following = text:byte(position + 1)
      if
        type(following) == "nil"
        or following < ADDON_ESCAPE_DIGIT_FIRST
        or following > ADDON_ESCAPE_DIGIT_LAST
      then
        return position, "an escape byte not followed by a digit from 0 to 4"
      end
      position = position + 2
    else
      position = position + 1
    end
  end
  return nil, nil
end

---Fail the test naming `label` when `text` breaks the addon channel's rules.
---@param ctx TestKit.Context
---@param label string
---@param text string
local function expectAddonSafe(ctx, label, text)
  local position, problem = findAddonViolation(text)
  if type(position) ~= "nil" then
    ctx:Log(
      ("%s breaks the addon channel at byte %d: %s; text %s"):format(
        label,
        position,
        tostring(problem),
        hex(text, 48)
      )
    )
    ctx:Fail(label .. " holds a byte C_ChatInfo.SendAddonMessage cannot carry")
  end
end

-- Positions and errors ------------------------------------------------------------------------

---Split a `file:line: ` prefix into the file as the client names it and the line.
---@param position string
---@return string|nil file
---@return integer|nil line
local function splitPosition(position)
  local file, line = position:match("^(.-):(%d+): ")
  return file, tonumber(line)
end

---The line of the caller of this function, as the client numbers it.
---
---`error` with level 3, raised under `pcall`, names the caller of this
---function: level 1 is `pcall` itself, 2 is this function, 3 its caller.
---@return integer
local function currentLine()
  local _, position = pcall(error, "", 3)
  local _, line = splitPosition(position or "")
  return line or 0
end

---Check that `message` is a string naming this file, and return its line.
---@param ctx TestKit.Context
---@param message any
---@return integer|nil line
local function expectThisFile(ctx, message)
  ctx:Expect(type(message)):ToBe("string")
  if type(message) ~= "string" then
    return nil
  end
  local file, line = splitPosition(message)
  ctx:Expect(type(file)):ToBe("string")
  ctx:Expect((file or ""):sub(-#THIS_FILE)):ToBe(THIS_FILE)
  return line
end

---Call `raise`, which must record its start line with `currentLine()` and
---raise on the next line, and check that the message names this file at that
---next line and ends with `expected`.
---@param ctx TestKit.Context
---@param raise fun() Records its start line in `lineBox.start`, then raises on the next line.
---@param lineBox { start: integer }
---@param expected string The message after the position, compared literally.
local function expectErrorAtCallingLine(ctx, raise, lineBox, expected)
  local succeeded, message = pcall(raise)
  ctx:Expect(succeeded):ToBe(false)
  ctx:Log("client message: " .. tostring(message))

  local line = expectThisFile(ctx, message)
  ctx:Expect(tostring(message):sub(-#expected)):ToBe(expected)
  ctx:Expect(line):ToBe(lineBox.start + 1)
end

-- Allocation ----------------------------------------------------------------------------------

---Run a full collection in a step of its own, so the measurement that follows
---starts far from the next collector cycle, which would otherwise shrink the
---count mid-measurement and hide an allocation.
---@param ctx TestKit.Context
local function collectBeforeMeasuring(ctx)
  collectgarbage("collect")
  ctx:Yield()
end

---Collect in a step of its own, warm up, then run `operation`
---`ALLOCATION_CALLS` times, log how far the heap grew and hold it to the
---tolerance.
---
---The two warm-up calls come after the collection on purpose: the first
---CodecKit call after a full collection allocates a few hundred bytes once
---(measured on stock Lua 5.1.5: 0.35 to 0.8 KB, the pool's bookkeeping being
---rebuilt), which is not the per-call cost docs/API.md's "Cost" promises is
---zero. The warm-up also interns the output strings.
---@param ctx TestKit.Context
---@param label string what `operation` does, for the log
---@param operation fun()
local function expectNoAllocation(ctx, label, operation)
  collectBeforeMeasuring(ctx)
  operation()
  operation()
  local before = collectgarbage("count")
  for _ = 1, ALLOCATION_CALLS do
    operation()
  end
  local grownKilobytes = collectgarbage("count") - before
  ctx:Log(
    ("memory delta over %d calls of %s: %.3f KB"):format(ALLOCATION_CALLS, label, grownKilobytes)
  )
  ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
end

-- codecKit.facade ----------------------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('codecKit', 1) is the CodecKit facade with API 1, its sixteen methods, FORMAT_VERSION 1, the 85-character PRINT_ALPHABET and UNBOUNDED",
  function(ctx)
    ctx:Expect(type(CodecKit)):ToBe("table")
    ctx:Expect(rawget(CodecKit, "API")):ToBe(CODEC_KIT_API)
    for _, methodName in ipairs({
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
    }) do
      ctx:Expect(type(CodecKit[methodName])):ToBe("function")
    end
    ctx:Expect(CodecKit.FORMAT_VERSION):ToBe(1)
    local alphabet = CodecKit.PRINT_ALPHABET
    ctx:Expect(#alphabet):ToBe(85)
    ctx:Expect(alphabet:sub(1, 1)):ToBe("!")
    ctx:Expect(alphabet:sub(85, 85)):ToBe("~")
    ctx:Expect(type(CodecKit.UNBOUNDED)):ToBe("table")
    local limits = CodecKit:GetLimits()
    ctx:Log(
      ("limits in this session: maxDepth %s, maxValues %s, maxStringLength %s, maxOutputBytes %s, maxListValues %s"):format(
        tostring(limits.maxDepth),
        tostring(limits.maxValues),
        tostring(limits.maxStringLength),
        tostring(limits.maxOutputBytes),
        tostring(limits.maxListValues)
      )
    )
  end
)

facade:Test("the installed CodecKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      local _, revision = Registry:Get(PACKAGE_ID, CODEC_KIT_API)
      ctx:Expect(revision):ToBe(expected.revision)
      ctx:Expect(rawget(CodecKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list codecKit")
end)

---The sorted names of a library table's functions, for the log.
---@param library table
---@return string
local function functionNames(library)
  local names = {}
  for name, member in pairs(library) do
    if type(name) == "string" and type(member) == "function" then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return table.concat(names, ", ")
end

---What a client global is, for the log: `absent`, or its type and, for a
---library table, its functions.
---@param name string
---@return string
local function describeGlobal(name)
  local value = readHost(name)
  if type(value) == "nil" then
    return name .. ": absent"
  end
  if type(value) == "table" then
    return name .. ": table with " .. functionNames(value)
  end
  return name .. ": " .. type(value)
end

facade:Test(
  "the client's Lua has string.byte, string.char, math.floor, math.frexp, math.ldexp and unpack, all CodecKit computes with; bit, C_EncodingUtil, SendAddonMessage, issecretvalue and SchedulerKit logged",
  function(ctx)
    ctx:Expect(type(string.byte)):ToBe("function")
    ctx:Expect(type(string.char)):ToBe("function")
    ctx:Expect(type(math.floor)):ToBe("function")
    ctx:Expect(type(math.frexp)):ToBe("function")
    ctx:Expect(type(math.ldexp)):ToBe("function")
    ctx:Expect(type(unpack)):ToBe("function")
    ctx:Log(describeGlobal("bit"))
    ctx:Log(describeGlobal("bit32"))
    ctx:Log(
      "CodecKit uses no bit library: shifts and masks are floor, % and multiplication, doubles through math.frexp and math.ldexp"
    )

    local present = {}
    local absent = {}
    for _, functionName in ipairs({
      "CompressString",
      "DecompressString",
      "EncodeBase64",
      "DecodeBase64",
      "SerializeCBOR",
      "DeserializeCBOR",
      "SerializeJSON",
      "DeserializeJSON",
      "EncodeHex",
      "DecodeHex",
    }) do
      if type(readHostFunction("C_EncodingUtil", functionName)) == "function" then
        present[#present + 1] = functionName
      else
        absent[#absent + 1] = functionName
      end
    end
    ctx:Log("C_EncodingUtil functions present: " .. table.concat(present, ", "))
    ctx:Log("C_EncodingUtil functions absent: " .. table.concat(absent, ", "))
    local deflateMethod, deflateSource = enumValue("CompressionMethod", "Deflate", 0)
    ctx:Log(("Enum.CompressionMethod.Deflate: %d (%s)"):format(deflateMethod, deflateSource))
    ctx:Log(
      "C_ChatInfo.SendAddonMessage: "
        .. type(readHostFunction("C_ChatInfo", "SendAddonMessage"))
        .. " (looked up only; nothing is sent)"
    )
    ctx:Log("issecretvalue: " .. type(isSecretValue) .. ", secretwrap: " .. type(secretWrap))
    local found, revisionOrReason = Registry:Find("schedulerKit", SCHEDULER_KIT_API)
    ctx:Log("Registry:Find('schedulerKit', 1) revision or reason: " .. tostring(revisionOrReason))
    ctx:Expect(type(found)):ToBe("table")
  end
)

-- codecKit.values ----------------------------------------------------------------------------

local values = newSuite("values")

--- Values whose serialised bytes docs/API.md spells out, with those bytes.
--- Built at run time so no constant folding can turn -0 into 0.
---@return { label: string, value: any, bytes: string }[]
local function documentedSpellings()
  local negativeZero = 1 / -math.huge
  local notANumber = math.huge - math.huge
  -- Built in two steps: the mixed layout is the point of this case.
  local mixed = { 1 }
  mixed.x = 2
  return {
    { label = "300", value = 300, bytes = "\4\172\2" },
    { label = "1.5", value = 1.5, bytes = "\6\63\248\0\0\0\0\0\0" },
    { label = "-0", value = negativeZero, bytes = "\6\128\0\0\0\0\0\0\0" },
    { label = "2^-1074", value = math.ldexp(1, -1074), bytes = "\6\0\0\0\0\0\0\0\1" },
    { label = "NaN", value = notANumber, bytes = "\6\127\248\0\0\0\0\0\0" },
    { label = "-NaN", value = -notANumber, bytes = "\6\127\248\0\0\0\0\0\0" },
    { label = "{}", value = {}, bytes = "\8\0" },
    { label = "{ 1, x = 2 }", value = mixed, bytes = "\10\1\4\1\1\7\1\120\4\2" },
  }
end

values:Test(
  "Serialize writes the bytes docs/API.md spells out for 300, 1.5, -0, 2^-1074, NaN of either sign, {} and { 1, x = 2 } on the client's math.frexp and string.char",
  function(ctx)
    -- How the client's Lua compares a NaN. IEEE-754 answers false to every
    -- ordered comparison; the 2026-09-25 run wrote a sign bit for NaN because
    -- CodecKit revision 3 tested the sign first, so these answers are logged.
    local notANumber = math.huge - math.huge
    local negatedNaN = -notANumber
    ctx:Log(
      ("NaN comparisons: NaN < 0 %s, NaN > 0 %s, NaN <= 0 %s, NaN == 0 %s, NaN ~= NaN %s, -NaN < 0 %s, -NaN > 0 %s, tostring %s and %s"):format(
        tostring(notANumber < 0),
        tostring(notANumber > 0),
        tostring(notANumber <= 0),
        tostring(notANumber == 0),
        tostring(notANumber ~= notANumber),
        tostring(negatedNaN < 0),
        tostring(negatedNaN > 0),
        tostring(notANumber),
        tostring(negatedNaN)
      )
    )
    for _, case in ipairs(documentedSpellings()) do
      local ok, bytes = CodecKit:Serialize(case.value)
      ctx:Expect(ok):ToBe(true)
      ctx:Log(("%s serialises to %s"):format(case.label, hex(bytes, 16)))
      ctx:Expect(bytes):ToBe(case.bytes)
    end
  end
)

values:Test(
  "every kind of number round-trips bit for bit through Serialize and Deserialize on the client: integers to 2^53, fractions, 2^53 + 2, both infinities, NaN, -0 and subnormals",
  function(ctx)
    local negativeZero = 1 / -math.huge
    local numbers = {
      0,
      1,
      -1,
      127,
      128,
      300,
      2 ^ 31,
      2 ^ 32 + 1,
      2 ^ 53,
      -(2 ^ 53),
      2 ^ 53 + 2,
      0.1,
      -2.5,
      math.pi,
      1 / 3,
      1e300,
      -1e-300,
      math.huge,
      -math.huge,
      math.ldexp(1, -1074),
      math.ldexp(1, -1022) - math.ldexp(1, -1074),
      math.ldexp(1, -1022),
      negativeZero,
    }
    for _, number in ipairs(numbers) do
      local ok, bytes = CodecKit:Serialize(number)
      ctx:Expect(ok):ToBe(true)
      local decodedOk, decoded = CodecKit:Deserialize(bytes)
      ctx:Expect(decodedOk):ToBe(true)
      ctx:Expect(decoded):ToBe(number)
      -- -0 == 0 in Lua; only the reciprocal tells them apart.
      ctx:Expect(1 / decoded):ToBe(1 / number)
      local _, again = CodecKit:Serialize(decoded)
      ctx:Expect(again):ToBe(bytes)
    end
    local notANumber = math.huge - math.huge
    local _, nanBytes = CodecKit:Serialize(notANumber)
    local nanOk, nanBack = CodecKit:Deserialize(nanBytes)
    ctx:Expect(nanOk):ToBe(true)
    ctx:Expect(nanBack ~= nanBack):ToBe(true)
    ctx:Log(("%d numbers and NaN round-tripped"):format(#numbers))
  end
)

--- The six stage combinations, with the flags byte each frame must carry.
local STAGE_COMBINATIONS = {
  { options = { compress = "none", channel = "none" }, flags = 1 },
  { options = { compress = "deflate", channel = "none" }, flags = 3 },
  { options = { compress = "none", channel = "addon" }, flags = 5 },
  { options = { compress = "deflate", channel = "addon" }, flags = 7 },
  { options = { compress = "none", channel = "print" }, flags = 9 },
  { options = { compress = "deflate", channel = "print" }, flags = 11 },
}

values:Test(
  "a string of every byte value 0 to 255, alone and in a table, round-trips through all six stage combinations with the documented header",
  function(ctx)
    local allBytes = everyByte()
    local wrapped = { raw = allBytes, again = allBytes .. allBytes, [allBytes] = "as a key" }
    for _, combination in ipairs(STAGE_COMBINATIONS) do
      local label = combination.options.compress .. "/" .. combination.options.channel
      local ok, text = CodecKit:Encode(allBytes, combination.options)
      ctx:Expect(ok):ToBe(true)
      if combination.options.channel == "print" then
        ctx:Expect(text:sub(1, 1)):ToBe("!")
      else
        ctx:Expect(text:byte(1)):ToBe(1)
        ctx:Expect(text:byte(2)):ToBe(combination.flags)
      end
      local decodedOk, decoded = CodecKit:Decode(text)
      ctx:Expect(decodedOk):ToBe(true)
      ctx:Expect(decoded == allBytes):ToBe(true)

      local tableOk, tableText = CodecKit:Encode(wrapped, combination.options)
      ctx:Expect(tableOk):ToBe(true)
      local tableDecodedOk, tableDecoded = CodecKit:Decode(tableText)
      ctx:Expect(tableDecodedOk):ToBe(true)
      ctx:Expect(tableDecoded):ToEqual(wrapped)
      ctx:Log(
        ("%s: %d-byte frame for the 256 bytes, %d for the table"):format(label, #text, #tableText)
      )
    end
  end
)

values:Test(
  "EncodeMany and DecodeMany carry an argument list with nils in the middle and at the end through the addon channel, as select('#') and unpack count them",
  function(ctx)
    local ok, text = CodecKit:EncodeMany({ channel = "addon" }, "sync", nil, 3, nil, nil)
    ctx:Expect(ok):ToBe(true)
    local results = { CodecKit:DecodeMany(text, { channel = "addon" }) }
    local count = select("#", CodecKit:DecodeMany(text, { channel = "addon" }))
    ctx:Expect(count):ToBe(6)
    ctx:Expect(results[1]):ToBe(true)
    ctx:Expect(results[2]):ToBe("sync")
    ctx:Expect(results[3]):ToBeNil()
    ctx:Expect(results[4]):ToBe(3)
    ctx:Expect(results[5]):ToBeNil()
    ctx:Expect(results[6]):ToBeNil()
    ctx:Log("EncodeMany frame: " .. hex(text, 32))
  end
)

-- codecKit.channels --------------------------------------------------------------------------

local channels = newSuite("channels")

channels:Test(
  "addon-channel text of every byte value and of 300 random payloads from math.random, plain and deflated, holds no NUL, line feed, carriage return or raw pipe and escapes 0xFF, so C_ChatInfo.SendAddonMessage's byte rules hold (nothing sent)",
  function(ctx)
    local addonOptions = { channel = "addon" }
    local deflatedAddonOptions = { compress = "deflate", channel = "addon" }
    local allBytes = everyByte()
    local frameCount = 0
    local longest = 0
    local overLimit = 0

    ---Check one text and fold its length into the counters.
    ---@param label string
    ---@param text string
    local function checkText(label, text)
      expectAddonSafe(ctx, label, text)
      frameCount = frameCount + 1
      longest = math.max(longest, #text)
      if #text > ADDON_MESSAGE_LIMIT_BYTES then
        overLimit = overLimit + 1
      end
    end

    local escapedOk, escaped = CodecKit:EncodeForAddon(allBytes)
    ctx:Expect(escapedOk):ToBe(true)
    checkText("EncodeForAddon of every byte", escaped)
    ctx:Expect(#escaped):ToBe(256 + 5)
    local backOk, back = CodecKit:DecodeForAddon(escaped)
    ctx:Expect(backOk):ToBe(true)
    ctx:Expect(back == allBytes):ToBe(true)

    for index = 1, ADDON_PAYLOAD_COUNT do
      local payload = randomBytes(math.random(0, ADDON_PAYLOAD_MAX_LENGTH))
      for _, options in ipairs({ addonOptions, deflatedAddonOptions }) do
        local ok, text = CodecKit:Encode(payload, options)
        ctx:Expect(ok):ToBe(true)
        checkText(("payload %d (%s)"):format(index, tostring(options.compress)), text)
        local decodedOk, decoded = CodecKit:Decode(text, addonOptions)
        ctx:Expect(decodedOk):ToBe(true)
        ctx:Expect(decoded == payload):ToBe(true)
      end
      if index % FUZZ_BATCH == 0 then
        ctx:Yield()
      end
    end
    ctx:Log(
      ("%d addon texts checked; longest %d bytes; %d longer than the client's %d-byte message limit, which CommKit splits"):format(
        frameCount,
        longest,
        overLimit,
        ADDON_MESSAGE_LIMIT_BYTES
      )
    )
  end
)

channels:Test(
  "a deflated print export string of the sample value uses only PRINT_ALPHABET, starts with '!', and decodes again after chat-style wrapping at 60 characters with indentation",
  function(ctx)
    local ok, text = CodecKit:Encode(SAMPLE_VALUE, EXPORT_OPTIONS)
    ctx:Expect(ok):ToBe(true)
    ctx:Expect(text:sub(1, 1)):ToBe("!")
    local allowed = {}
    local alphabet = CodecKit.PRINT_ALPHABET
    for position = 1, #alphabet do
      allowed[alphabet:byte(position)] = true
    end
    for position = 1, #text do
      if not allowed[text:byte(position)] then
        ctx:Fail(("character %d of the export string is outside PRINT_ALPHABET"):format(position))
      end
    end

    local lines = {}
    for first = 1, #text, 60 do
      lines[#lines + 1] = "  " .. text:sub(first, first + 59)
    end
    local wrapped = " \n" .. table.concat(lines, "\r\n") .. "\n"
    local decodedOk, decoded = CodecKit:Decode(wrapped, { channel = "print" })
    ctx:Expect(decodedOk):ToBe(true)
    ctx:Expect(decoded):ToEqual(SAMPLE_VALUE)
    ctx:Log(("export string %d characters, wrapped into %d lines"):format(#text, #lines))
  end
)

channels:Test(
  "a decoder told options.channel refuses a frame of another channel with channelMismatch, so an addon-message handler refuses a pasted export string",
  function(ctx)
    local _, exportText = CodecKit:Encode(SAMPLE_VALUE, EXPORT_OPTIONS)
    local _, addonText = CodecKit:Encode(SAMPLE_VALUE, { channel = "addon" })
    local ok, reason = CodecKit:Decode(exportText, { channel = "addon" })
    ctx:Expect(ok):ToBe(false)
    ctx:Expect(reason):ToBe("channelMismatch")
    ok, reason = CodecKit:Decode(addonText, { channel = "print" })
    ctx:Expect(ok):ToBe(false)
    ctx:Expect(reason):ToBe("channelMismatch")
    local decodedOk, decoded = CodecKit:Decode(addonText, { channel = "addon" })
    ctx:Expect(decodedOk):ToBe(true)
    ctx:Expect(decoded):ToEqual(SAMPLE_VALUE)
  end
)

-- codecKit.interop ---------------------------------------------------------------------------

local interop = newSuite("interop")

--- Why the interoperability tests are skipped on a client without the two functions.
local INTEROP_SKIP_REASON =
  "the client has no C_EncodingUtil.CompressString and DecompressString; interoperability was not exercised"

---Register `body` as a test when the client has its own DEFLATE functions,
---and as a skipped test naming why otherwise.
---@param name string
---@param body fun(ctx: TestKit.Context)
local function interopTest(name, body)
  if INTEROP_AVAILABLE then
    interop:Test(name, body)
  else
    interop:Skip(name, INTEROP_SKIP_REASON)
  end
end

---Call a client function under `pcall` and return its first result, or `nil`
---and the problem: the error it raised, or `"absent"` when the client has no
---such function. A call that returns nothing gives `nil`.
---@param clientFunction function|nil
---@param ... any
---@return any result
---@return any problem
local function callClient(clientFunction, ...)
  if type(clientFunction) ~= "function" then
    return nil, "absent"
  end
  local succeeded, result = pcall(clientFunction, ...)
  if not succeeded then
    return nil, result
  end
  return result, nil
end

---The compression inputs of the interoperability tests: prose, random binary,
---a short message under 64 bytes, and the serialised roster.
---@return { label: string, bytes: string }[]
local function interopInputs()
  local _, roster = CodecKit:Serialize(buildRoster())
  return {
    { label = "prose", bytes = buildProse() },
    { label = "random binary", bytes = randomBytes(4096) },
    { label = "short message", bytes = SHORT_MESSAGE },
    { label = "serialised roster", bytes = roster },
  }
end

interopTest(
  "C_EncodingUtil.DecompressString with Enum.CompressionMethod.Deflate inflates CodecKit:Compress output at levels 1, 6 and 9 for prose, random binary, a 32-byte message and the serialised 50 KB roster",
  function(ctx)
    local deflateMethod = enumValue("CompressionMethod", "Deflate", 0)
    for _, input in ipairs(interopInputs()) do
      for _, level in ipairs({ 1, 6, 9 }) do
        local ok, compressed = CodecKit:Compress(input.bytes, { level = level })
        ctx:Expect(ok):ToBe(true)
        local inflated, problem = callClient(decompressString, compressed, deflateMethod)
        if type(problem) ~= "nil" then
          ctx:Log("C_EncodingUtil.DecompressString raised: " .. tostring(problem))
        end
        ctx:Log(
          ("%s level %d: %d bytes to %d; the client inflated %s"):format(
            input.label,
            level,
            #input.bytes,
            #compressed,
            type(inflated) == "string" and (#inflated .. " bytes") or type(inflated)
          )
        )
        ctx:Expect(type(inflated)):ToBe("string")
        ctx:Expect(inflated == input.bytes):ToBe(true)
        ctx:Yield()
      end
    end
  end
)

interopTest(
  "CodecKit:Decompress inflates C_EncodingUtil.CompressString raw Deflate output at the client's Default, OptimizeForSpeed and OptimizeForSize levels for the same four inputs",
  function(ctx)
    local deflateMethod = enumValue("CompressionMethod", "Deflate", 0)
    local clientLevels = {
      { name = "Default", value = enumValue("CompressionLevel", "Default", 0) },
      { name = "OptimizeForSpeed", value = enumValue("CompressionLevel", "OptimizeForSpeed", 1) },
      { name = "OptimizeForSize", value = enumValue("CompressionLevel", "OptimizeForSize", 2) },
    }
    for _, input in ipairs(interopInputs()) do
      for _, clientLevel in ipairs(clientLevels) do
        local compressed, problem =
          callClient(compressString, input.bytes, deflateMethod, clientLevel.value)
        if type(problem) ~= "nil" then
          ctx:Log("C_EncodingUtil.CompressString raised: " .. tostring(problem))
        end
        ctx:Expect(type(compressed)):ToBe("string")
        if type(compressed) == "string" then
          ctx:Log(
            ("%s %s: the client wrote %d bytes, starting %s"):format(
              input.label,
              clientLevel.name,
              #compressed,
              hex(compressed, 4)
            )
          )
          local ok, inflated = CodecKit:Decompress(compressed)
          if not ok then
            ctx:Log("CodecKit:Decompress refused it: " .. tostring(inflated))
          end
          ctx:Expect(ok):ToBe(true)
          ctx:Expect(inflated == input.bytes):ToBe(true)
        end
        ctx:Yield()
      end
    end
  end
)

---Time `work` on the CPU clock and return the milliseconds and its first result.
---@param work fun(): any
---@return number elapsed
---@return any result
local function timed(work)
  local started = cpuNow()
  local result = work()
  return cpuNow() - started, result
end

---Log one side-by-side row: what CodecKit and the client made of one input.
---@param ctx TestKit.Context
---@param label string
---@param codecBytes integer
---@param codecMs number
---@param clientResult any
---@param clientMs number
local function logComparison(ctx, label, codecBytes, codecMs, clientResult, clientMs)
  local clientPart
  if type(clientResult) == "string" then
    clientPart = ("%d bytes in %s"):format(#clientResult, milliseconds(clientMs))
  else
    clientPart = "unavailable or refused (" .. type(clientResult) .. ")"
  end
  ctx:Log(
    ("%s: CodecKit %d bytes in %s; client %s"):format(
      label,
      codecBytes,
      milliseconds(codecMs),
      clientPart
    )
  )
end

interopTest(
  "on the 50 KB roster CodecKit and C_EncodingUtil are logged side by side (Serialize vs SerializeCBOR, Compress vs CompressString, EncodeForPrint vs EncodeBase64, and back), and CodecKit's print text is exactly 25% larger than its input",
  function(ctx)
    local roster = buildRoster()
    local deflateMethod = enumValue("CompressionMethod", "Deflate", 0)

    local serializeMs, serialized = timed(function()
      local _, bytes = CodecKit:Serialize(roster)
      return bytes
    end)
    local cborMs, cbor = 0, nil
    if type(serializeCBOR) == "function" then
      cborMs, cbor = timed(function()
        return (callClient(serializeCBOR, roster))
      end)
    end
    logComparison(ctx, "serialise", #serialized, serializeMs, cbor, cborMs)
    ctx:Yield()

    local deserializeMs, decoded = timed(function()
      local _, value = CodecKit:Deserialize(serialized)
      return value
    end)
    ctx:Expect(decoded):ToEqual(roster)
    if type(deserializeCBOR) == "function" and type(cbor) == "string" then
      local cborBackMs, cborBack = timed(function()
        return (callClient(deserializeCBOR, cbor))
      end)
      local members = type(cborBack) == "table" and cborBack.members or nil
      ctx:Log(
        ("deserialise: CodecKit %s; client DeserializeCBOR %s, giving %s with %s members"):format(
          milliseconds(deserializeMs),
          milliseconds(cborBackMs),
          type(cborBack),
          type(members) == "table" and tostring(#members) or "no"
        )
      )
    else
      ctx:Log("deserialise: CodecKit " .. milliseconds(deserializeMs) .. "; client not compared")
    end
    ctx:Yield()

    local compressMs, compressed = timed(function()
      local _, bytes = CodecKit:Compress(serialized, { level = 6 })
      return bytes
    end)
    local clientCompressMs, clientCompressed = timed(function()
      return (callClient(compressString, serialized, deflateMethod))
    end)
    logComparison(
      ctx,
      "compress (level 6 / Default)",
      #compressed,
      compressMs,
      clientCompressed,
      clientCompressMs
    )
    ctx:Yield()

    local inflateMs = timed(function()
      return (CodecKit:Decompress(compressed))
    end)
    local clientInflateMs, clientInflated = timed(function()
      return (callClient(decompressString, compressed, deflateMethod))
    end)
    logComparison(ctx, "inflate", #serialized, inflateMs, clientInflated, clientInflateMs)
    ctx:Yield()

    local printMs, printed = timed(function()
      local _, text = CodecKit:EncodeForPrint(compressed)
      return text
    end)
    local base64Ms, base64 = 0, nil
    if type(encodeBase64) == "function" then
      base64Ms, base64 = timed(function()
        return (callClient(encodeBase64, compressed))
      end)
    end
    logComparison(ctx, "printable text (base 85 / Base64)", #printed, printMs, base64, base64Ms)
    local fullGroups = math.floor(#compressed / 4)
    local remainder = #compressed % 4
    local expectedLength = 5 * fullGroups + (remainder > 0 and remainder + 1 or 0)
    ctx:Expect(#printed):ToBe(expectedLength)
    ctx:Yield()

    local unprintMs, unprinted = timed(function()
      local _, bytes = CodecKit:DecodeForPrint(printed)
      return bytes
    end)
    ctx:Expect(unprinted == compressed):ToBe(true)
    local unbase64Ms, unbase64 = 0, nil
    if type(decodeBase64) == "function" and type(base64) == "string" then
      unbase64Ms, unbase64 = timed(function()
        return (callClient(decodeBase64, base64))
      end)
    end
    logComparison(ctx, "decode printable text", #unprinted, unprintMs, unbase64, unbase64Ms)
  end
)

-- codecKit.performance -----------------------------------------------------------------------

local performance = newSuite("performance", { timeoutSeconds = PERFORMANCE_TIMEOUT_SECONDS })

performance:Test(
  "a 288-member guild roster serialises to 48-56 KB, and Serialize, Compress, EncodeForPrint, EncodeForAddon, the whole export Encode and its Decode are each timed on the client and give back an equal table",
  function(ctx)
    local roster = buildRoster()
    ctx:Yield()

    local serializeMs, serialized = timed(function()
      local _, bytes = CodecKit:Serialize(roster)
      return bytes
    end)
    ctx:Log(("Serialize: %d bytes in %s"):format(#serialized, milliseconds(serializeMs)))
    ctx:Expect(#serialized >= PAYLOAD_MIN_BYTES and #serialized <= PAYLOAD_MAX_BYTES):ToBe(true)
    ctx:Yield()

    local compressMs, compressed = timed(function()
      local _, bytes = CodecKit:Compress(serialized)
      return bytes
    end)
    ctx:Log(
      ("Compress level 6: %d bytes (%.2fx) in %s, %.3f ms per KiB"):format(
        #compressed,
        #serialized / #compressed,
        milliseconds(compressMs),
        compressMs / (#serialized / 1024)
      )
    )
    ctx:Yield()

    local printMs, printed = timed(function()
      local _, text = CodecKit:EncodeForPrint(compressed)
      return text
    end)
    ctx:Log(("EncodeForPrint: %d characters in %s"):format(#printed, milliseconds(printMs)))
    local addonMs, escaped = timed(function()
      local _, text = CodecKit:EncodeForAddon(serialized)
      return text
    end)
    ctx:Log(
      ("EncodeForAddon of the uncompressed bytes: %d bytes in %s"):format(
        #escaped,
        milliseconds(addonMs)
      )
    )
    ctx:Yield()

    local encodeMs, exportText = timed(function()
      local _, text = CodecKit:Encode(roster, EXPORT_OPTIONS)
      return text
    end)
    ctx:Log(
      ("Encode (deflate, print): %d characters in %s"):format(#exportText, milliseconds(encodeMs))
    )
    ctx:Yield()

    local decodeMs, decoded = timed(function()
      local ok, value = CodecKit:Decode(exportText, { channel = "print" })
      if not ok then
        return nil
      end
      return value
    end)
    ctx:Log(("Decode (print, inflate, deserialise): %s"):format(milliseconds(decodeMs)))
    ctx:Expect(decoded):ToEqual(roster)
    ctx:Yield()

    local plainMs, plainText = timed(function()
      local _, text = CodecKit:Encode(roster, { channel = "addon" })
      return text
    end)
    local plainDecodeMs, plainDecoded = timed(function()
      local _, value = CodecKit:Decode(plainText, { channel = "addon" })
      return value
    end)
    ctx:Log(
      ("Encode and Decode on the addon channel without compression: %d bytes, %s and %s"):format(
        #plainText,
        milliseconds(plainMs),
        milliseconds(plainDecodeMs)
      )
    )
    ctx:Expect(plainDecoded):ToEqual(roster)
    ctx:Expect(leasedTableCount()):ToBe(0)
  end
)

performance:Test(
  "EncodeAsync of the 50 KB roster on a SchedulerKit scope spreads over at least two rendered frames and hands its callback exactly the synchronous export string, and DecodeAsync gives back an equal table",
  function(ctx)
    local roster = buildRoster()
    local syncOk, syncText = CodecKit:Encode(roster, EXPORT_OPTIONS)
    ctx:Expect(syncOk):ToBe(true)
    ctx:Yield()

    local scope = trackScope(SchedulerKit:CreateScope())
    local encoded = { calls = 0, ok = false, result = nil }
    local encodeStarted = cpuNow()
    local encodeStartedFrame = getTime()
    CodecKit:EncodeAsync(roster, EXPORT_OPTIONS, scope, function(ok, text)
      encoded.calls = encoded.calls + 1
      encoded.ok = ok
      encoded.result = text
    end)
    -- WaitUntil asks the predicate once at the call, in the frame the job was
    -- scheduled, then once per rendered frame. Every later answer of "not
    -- yet" is a frame boundary the job was still pending across.
    local predicateCalls = 0
    local pendingAfterFrames = 0
    local encodeFinished = waitUntil(ctx, function()
      predicateCalls = predicateCalls + 1
      local done = encoded.calls > 0
      if not done and predicateCalls > 1 then
        pendingAfterFrames = pendingAfterFrames + 1
      end
      return done
    end, ASYNC_WAIT_SECONDS)
    ctx:Expect(encodeFinished):ToBe(true)
    ctx:Log(
      ("EncodeAsync: still pending after %d rendered frames, %.0f ms of game time, %s of CPU time between call and callback, at a %s ms frame budget"):format(
        pendingAfterFrames,
        (getTime() - encodeStartedFrame) * 1000,
        milliseconds(cpuNow() - encodeStarted),
        tostring(SchedulerKit:GetFrameBudget())
      )
    )
    ctx:Expect(encoded.calls):ToBe(1)
    ctx:Expect(encoded.ok):ToBe(true)
    ctx:Expect(encoded.result == syncText):ToBe(true)
    ctx:Expect(pendingAfterFrames >= 1):ToBe(true)

    local decodedResult = { calls = 0, ok = false, value = nil }
    local decodeStartedFrame = getTime()
    CodecKit:DecodeAsync(syncText, { channel = "print" }, scope, function(ok, value)
      decodedResult.calls = decodedResult.calls + 1
      decodedResult.ok = ok
      decodedResult.value = value
    end)
    local decodeFinished = waitUntil(ctx, function()
      return decodedResult.calls > 0
    end, ASYNC_WAIT_SECONDS)
    ctx:Expect(decodeFinished):ToBe(true)
    ctx:Log(
      ("DecodeAsync: %.0f ms of game time between call and callback"):format(
        (getTime() - decodeStartedFrame) * 1000
      )
    )
    ctx:Expect(decodedResult.ok):ToBe(true)
    ctx:Expect(decodedResult.value):ToEqual(roster)
  end
)

-- codecKit.malformed -------------------------------------------------------------------------

local malformed = newSuite("malformed")

---Feed `count` strings from `makeInput` to all six decoders under `pcall` and
---fail the test when one raises or answers outside the contract: `true` and a
---value, or `false` and a reason from the documented vocabulary. Logs how
---often each reason came back, then checks that no pooled table stayed leased
---and no limit changed.
---@param ctx TestKit.Context
---@param count integer
---@param makeInput fun(index: integer): string
local function fuzzDecoders(ctx, count, makeInput)
  local limitsBefore = CodecKit:GetLimits()
  local reasonCounts = {}
  local accepted = 0
  for index = 1, count do
    local input = makeInput(index)
    for _, methodName in ipairs(DECODER_NAMES) do
      local called, ok, reason = pcall(CodecKit[methodName], CodecKit, input)
      if not called then
        ctx:Log(("%s raised on %s: %s"):format(methodName, hex(input, 48), tostring(ok)))
        ctx:Fail("CodecKit:" .. methodName .. " raised on a string; see the log")
      elseif ok == true then
        accepted = accepted + 1
      elseif ok == false and type(reason) == "string" and REASON_VOCABULARY[reason] then
        reasonCounts[reason] = (reasonCounts[reason] or 0) + 1
      else
        ctx:Log(
          ("%s answered %s, %s on %s"):format(
            methodName,
            tostring(ok),
            tostring(reason),
            hex(input, 48)
          )
        )
        ctx:Fail("CodecKit:" .. methodName .. " answered outside the contract; see the log")
      end
    end
    if index % FUZZ_BATCH == 0 then
      ctx:Yield()
    end
  end

  local names = {}
  for reason in pairs(reasonCounts) do
    names[#names + 1] = reason
  end
  table.sort(names)
  local parts = {}
  for _, reason in ipairs(names) do
    parts[#parts + 1] = reason .. " " .. reasonCounts[reason]
  end
  ctx:Log(
    ("%d strings, %d decoder calls: %d accepted; refused: %s"):format(
      count,
      count * #DECODER_NAMES,
      accepted,
      table.concat(parts, ", ")
    )
  )
  expectPackageStateUnchanged(ctx, limitsBefore)
end

malformed:Test(
  "1000 random byte strings of 0 to 64 bytes from the client's math.random make none of the six decoders raise, and every refusal is a documented reason",
  function(ctx)
    fuzzDecoders(ctx, FUZZ_RANDOM_COUNT, function()
      return randomBytes(math.random(0, FUZZ_MAX_LENGTH))
    end)
  end
)

malformed:Test(
  "1000 random bodies behind a version byte and every flags value from 0x00 to 0x0F make none of the six decoders raise, and every refusal is a documented reason",
  function(ctx)
    fuzzDecoders(ctx, FUZZ_HEADER_COUNT, function(index)
      local flags = (index - 1) % 16
      return "\1" .. string.char(flags) .. randomBytes(math.random(0, FUZZ_MAX_LENGTH))
    end)
  end
)

---The sample value's frame in every stage combination, and as an argument list.
---@return string[]
local function sampleFrames()
  local frames = {}
  for _, combination in ipairs(STAGE_COMBINATIONS) do
    local _, text = CodecKit:Encode(SAMPLE_VALUE, combination.options)
    frames[#frames + 1] = text
  end
  local _, list = CodecKit:EncodeMany({ channel = "addon" }, "sync", nil, SAMPLE_VALUE)
  frames[#frames + 1] = list
  return frames
end

---A copy of `text` with one random change: one to three bytes replaced, cut
---short, a byte inserted, or random bytes appended.
---@param text string
---@return string
local function mutate(text)
  local kind = math.random(1, 4)
  if kind == 1 then
    local mutated = text
    for _ = 1, math.random(1, 3) do
      local position = math.random(1, #mutated)
      mutated = mutated:sub(1, position - 1)
        .. string.char(math.random(0, 255))
        .. mutated:sub(position + 1)
    end
    return mutated
  elseif kind == 2 then
    return text:sub(1, math.random(0, #text - 1))
  elseif kind == 3 then
    local position = math.random(1, #text + 1)
    return text:sub(1, position - 1) .. string.char(math.random(0, 255)) .. text:sub(position)
  end
  return text .. randomBytes(math.random(1, 8))
end

malformed:Test(
  "1000 random mutations of valid frames (bytes replaced, cut short, a byte inserted, bytes appended) in every stage combination make none of the six decoders raise",
  function(ctx)
    local frames = sampleFrames()
    fuzzDecoders(ctx, FUZZ_MUTATION_COUNT, function(index)
      return mutate(frames[1 + (index - 1) % #frames])
    end)
  end
)

malformed:Test(
  "500 random strings of print characters behind '!', with stray whitespace, make none of the six decoders raise",
  function(ctx)
    local alphabet = CodecKit.PRINT_ALPHABET
    local whitespace = " \t\n\r"
    fuzzDecoders(ctx, FUZZ_PRINT_COUNT, function()
      local characters = { "!" }
      for index = 2, math.random(1, FUZZ_MAX_LENGTH) do
        if math.random(1, 16) == 1 then
          local pick = math.random(1, #whitespace)
          characters[index] = whitespace:sub(pick, pick)
        else
          local pick = math.random(1, #alphabet)
          characters[index] = alphabet:sub(pick, pick)
        end
      end
      return table.concat(characters)
    end)
  end
)

-- codecKit.allocation ------------------------------------------------------------------------

local allocation = newSuite("allocation")

--- The small table docs/API.md ("Cost") says encodes again without allocating.
local SMALL_VALUE = { id = 7, name = "bar", flags = { true, false }, scale = 1.5 }

allocation:Test(
  "Encode of a small table again allocates nothing on the none, addon and print channels, 2000 calls each",
  function(ctx)
    for _, channel in ipairs({ "none", "addon", "print" }) do
      local options = { channel = channel }
      expectNoAllocation(ctx, "Encode on the " .. channel .. " channel", function()
        CodecKit:Encode(SMALL_VALUE, options)
      end)
    end
  end
)

allocation:Test(
  "Decode of the addon frames of true, 42, -1.5 and 'name' again allocates nothing over 2000 rounds",
  function(ctx)
    local frames = {}
    for _, value in ipairs({ true, 42, -1.5, "name" }) do
      local _, text = CodecKit:Encode(value, { channel = "addon" })
      frames[#frames + 1] = text
    end
    local function decodeAll()
      for index = 1, #frames do
        CodecKit:Decode(frames[index])
      end
    end
    expectNoAllocation(ctx, "four scalar Decodes", decodeAll)
  end
)

allocation:Test(
  "Compress of a 32-byte message again, and Encode of the small table deflated for the addon channel, allocate nothing over 2000 calls each",
  function(ctx)
    expectNoAllocation(ctx, "Compress of 32 bytes", function()
      CodecKit:Compress(SHORT_MESSAGE)
    end)

    local deflatedAddon = { compress = "deflate", channel = "addon" }
    local _, serialized = CodecKit:Serialize(SMALL_VALUE)
    ctx:Log(
      ("the small table serialises to %d bytes, under the 64-byte matching floor"):format(
        #serialized
      )
    )
    ctx:Expect(#serialized < 64):ToBe(true)
    expectNoAllocation(ctx, "Encode deflated on the addon channel", function()
      CodecKit:Encode(SMALL_VALUE, deflatedAddon)
    end)
  end
)

-- codecKit.errors ----------------------------------------------------------------------------

local errors = newSuite("errors")

errors:Test("Encode called with a dot names CodecKitSuite.lua at the calling line", function(ctx)
  local encode = CodecKit.Encode
  local lines = { start = 0 }
  expectErrorAtCallingLine(ctx, function()
    lines.start = currentLine()
    encode(SAMPLE_VALUE)
  end, lines, "CodecKit:Encode must be called on the CodecKit facade; use CodecKit:Encode(...)")
end)

errors:Test(
  "an unknown option key, a channel outside its set, level 10 and Compress options that are not a table are refused at the calling line",
  function(ctx)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      CodecKit:Encode(SAMPLE_VALUE, { compres = "deflate" })
    end, lines, "CodecKit:Encode options.compres is not a recognised option")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      CodecKit:Encode(SAMPLE_VALUE, { channel = "chat" })
    end, lines, 'CodecKit:Encode options.channel must be "none", "addon" or "print"')
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      CodecKit:Encode(SAMPLE_VALUE, { compress = "deflate", level = 10 })
    end, lines, "CodecKit:Encode options.level must be an integer from 1 to 9")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      CodecKit:Compress(SHORT_MESSAGE, "fast")
    end, lines, "CodecKit:Compress options must be a table or nil")
  end
)

errors:Test(
  "Decode of a number and DecodeForAddon of a table are refused at the calling line, because the non-raising contract covers strings only",
  function(ctx)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      CodecKit:Decode(42)
    end, lines, "CodecKit:Decode text must be a string")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      CodecKit:DecodeForAddon({})
    end, lines, "CodecKit:DecodeForAddon text must be a string")
  end
)

errors:Test(
  "SetLimits with UNBOUNDED for maxDepth is refused at the calling line with its reason, and the limits stay as they were",
  function(ctx)
    local before = CodecKit:GetLimits()
    local lines = { start = 0 }
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        CodecKit:SetLimits({ maxDepth = CodecKit.UNBOUNDED })
      end,
      lines,
      "CodecKit:SetLimits limits.maxDepth cannot be CodecKit.UNBOUNDED because the reader and writer recurse on the Lua call stack; use an integer from 1 to 128"
    )
    ctx:Expect(CodecKit:GetLimits()):ToEqual(before)
  end
)

errors:Test(
  "EncodeAsync with a table that is not a scope, and with a closed SchedulerKit scope, is refused at the calling line and never calls back",
  function(ctx)
    local calls = 0
    local function callback()
      calls = calls + 1
    end
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      CodecKit:EncodeAsync(SAMPLE_VALUE, nil, {}, callback)
    end, lines, "CodecKit:EncodeAsync scope must be a SchedulerKit scope")
    local closedScope = SchedulerKit:CreateScope()
    closedScope:Close()
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      CodecKit:EncodeAsync(SAMPLE_VALUE, nil, closedScope, callback)
    end, lines, "CodecKit:EncodeAsync scope is closed")
    ctx:Yield()
    ctx:Expect(calls):ToBe(0)
  end
)

-- codecKit.secrets ---------------------------------------------------------------------------

local secrets = newSuite("secrets")

--- Why the secrets tests are skipped on a client without the two functions.
local SECRETS_SKIP_REASON =
  "the client has no issecretvalue and secretwrap; the secret path was not exercised"

---Register `body` as a test when the client can make a secret value, and as a
---skipped test naming why otherwise: the two functions are missing, or the
---client has them but `issecretvalue` does not report what `secretwrap`
---returns as secret (`Harness:CanMakeSecrets`, measured once; Classic Era and
---Mists Classic document both functions, so their presence alone proves
---nothing).
---@param name string
---@param body fun(ctx: TestKit.Context)
local function secretTest(name, body)
  if not SECRETS_AVAILABLE then
    secrets:Skip(name, SECRETS_SKIP_REASON)
  elseif not Harness:CanMakeSecrets() then
    secrets:Skip(name, Harness.NO_SECRETS_REASON)
  else
    secrets:Test(name, body)
  end
end

---A genuine secret value made by the client's `secretwrap`, or a failed test.
---
---`secretwrap` is documented in the client's own API documentation
---(FrameScriptDocumentation, packages/apiKit/metadata/retail/namespaces.json)
---with no restriction and no side effect: it converts the values given to it.
---@param ctx TestKit.Context
---@param value any
---@return any secret
local function makeSecret(ctx, value)
  local succeeded, secret = pcall(secretWrap, value)
  if not succeeded then
    ctx:Fail("secretwrap raised, so the secret path was not exercised: " .. tostring(secret))
  end
  if isSecretValue(secret) ~= true then
    ctx:Fail("secretwrap returned a value issecretvalue does not report as secret")
  end
  return secret
end

secretTest(
  "Encode refuses a secretwrap value at the top, in an array, as a map value and three tables deep, each at the calling line, and leaves no pooled table leased",
  function(ctx)
    local limitsBefore = CodecKit:GetLimits()
    local secretNumber = makeSecret(ctx, 42)
    local secretName = makeSecret(ctx, "Thrall")
    local expected = "CodecKit:Encode value must not contain a secret value"
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      CodecKit:Encode(secretNumber, { channel = "addon" })
    end, lines, expected)
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      CodecKit:Encode({ 1, secretNumber, 3 }, { channel = "addon" })
    end, lines, expected)
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      CodecKit:Encode({ kind = "sync", name = secretName }, EXPORT_OPTIONS)
    end, lines, expected)
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      CodecKit:Encode({ a = { b = { c = secretNumber } } }, { compress = "deflate" })
    end, lines, expected)
    -- docs/API.md also names a secret key; log whether the client even lets a
    -- table hold one.
    local keyed, problem = pcall(function()
      local holder = {}
      holder[secretName] = 1
      return holder
    end)
    ctx:Log(
      "a table with a secret key: "
        .. (keyed and "the client allowed it" or ("the client refused it: " .. tostring(problem)))
    )
    expectPackageStateUnchanged(ctx, limitsBefore)
  end
)

secretTest("EncodeMany and Serialize refuse a secret argument at the calling line", function(ctx)
  local secret = makeSecret(ctx, 7)
  local lines = { start = 0 }
  expectErrorAtCallingLine(ctx, function()
    lines.start = currentLine()
    CodecKit:EncodeMany({ channel = "addon" }, "sync", nil, secret)
  end, lines, "CodecKit:EncodeMany value must not contain a secret value")
  expectErrorAtCallingLine(ctx, function()
    lines.start = currentLine()
    CodecKit:Serialize({ secret })
  end, lines, "CodecKit:Serialize value must not contain a secret value")
  ctx:Expect(leasedTableCount()):ToBe(0)
end)

secretTest(
  "EncodeAsync refuses a secret deep in the value at the calling line, schedules no job and never calls back",
  function(ctx)
    local scope = trackScope(SchedulerKit:CreateScope())
    local secret = makeSecret(ctx, "hidden")
    local calls = 0
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      CodecKit:EncodeAsync({ list = { 1, { note = secret } } }, EXPORT_OPTIONS, scope, function()
        calls = calls + 1
      end)
    end, lines, "CodecKit:EncodeAsync value must not contain a secret value")
    ctx:Expect(scope:GetActiveCount()):ToBe(0)
    ctx:Yield()
    ctx:Expect(calls):ToBe(0)
  end
)

secretTest(
  "a secret string handed to Decode, DecodeMany, Deserialize, Decompress, DecodeForAddon and DecodeForPrint is refused at the calling line before anything reads it",
  function(ctx)
    local _, frame = CodecKit:Encode(SAMPLE_VALUE, { channel = "addon" })
    local secret = makeSecret(ctx, frame)
    local cases = {
      { method = "Decode", argument = "text" },
      { method = "DecodeMany", argument = "text" },
      { method = "Deserialize", argument = "bytes" },
      { method = "Decompress", argument = "bytes" },
      { method = "DecodeForAddon", argument = "text" },
      { method = "DecodeForPrint", argument = "text" },
    }
    local lines = { start = 0 }
    for _, case in ipairs(cases) do
      local method = CodecKit[case.method]
      expectErrorAtCallingLine(ctx, function()
        lines.start = currentLine()
        method(CodecKit, secret)
      end, lines, ("CodecKit:%s %s must not be a secret value"):format(
        case.method,
        case.argument
      ))
    end
    ctx:Expect(leasedTableCount()):ToBe(0)
  end
)

secretTest(
  "a secret options.level, a secret options.channel and a secret SetLimits maxDepth are refused at the calling line and the limits stay as they were",
  function(ctx)
    local before = CodecKit:GetLimits()
    local secretLevel = makeSecret(ctx, 6)
    local secretChannel = makeSecret(ctx, "addon")
    local secretDepth = makeSecret(ctx, 8)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      CodecKit:Encode(SAMPLE_VALUE, { compress = "deflate", level = secretLevel })
    end, lines, "CodecKit:Encode options.level must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      CodecKit:Encode(SAMPLE_VALUE, { channel = secretChannel })
    end, lines, "CodecKit:Encode options.channel must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      CodecKit:SetLimits({ maxDepth = secretDepth })
    end, lines, "CodecKit:SetLimits limits.maxDepth must not be a secret value")
    ctx:Expect(CodecKit:GetLimits()):ToEqual(before)
  end
)
