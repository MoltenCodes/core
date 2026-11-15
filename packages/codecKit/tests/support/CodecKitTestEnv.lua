--- Package-specific test environment for the CodecKit suite.
---
--- The `package.loaded` bookkeeping, the error capture and the World of
--- Warcraft stubs live in the shared `FrameworkTestEnv` fixture at
--- `tests/support/`. What stays here is this package's two module chains and
--- the helpers only its specs describe: a local `issecretvalue` stub, a value
--- that refuses every operation a secret refuses, allocation measurement, a
--- seeded byte generator, deep equality that understands NaN and -0, an
--- in-place upgrade and a patched load that models a host.
---
--- The default environment loads Registry, PoolKit and CodecKit without the
--- WoW stubs: CodecKit is pure Lua. `CodecKitTestEnv.Async` is a second
--- environment that also loads TimerKit and SchedulerKit, SchedulerKit's
--- required closure, for the asynchronous variants. SchedulerKit is declared under
--- `optionalDependencies`, so the test runner puts it and its closure on
--- `LUA_PATH`.
local FrameworkTestEnv = require("FrameworkTestEnv")

local CodecKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "PoolKit", "CodecKit", "CodecKit-Compression" },
  wowApi = false,
})

--- The module chain the asynchronous specs load, CodecKit and its part last.
local ASYNC_MODULES = {
  "Registry",
  "PoolKit",
  "TimerKit",
  "SchedulerKit",
  "CodecKit",
  "CodecKit-Compression",
}

local Async = FrameworkTestEnv.New({ modules = ASYNC_MODULES })
CodecKitTestEnv.Async = Async

--- The core without its Compression part, as an addon that embeds only
--- `codecKit\CodecKit.lua` loads it.
local Core = FrameworkTestEnv.New({
  modules = { "Registry", "PoolKit", "CodecKit" },
  wowApi = false,
})
CodecKitTestEnv.Core = Core

--- The asynchronous chain without the Compression part.
local CoreAsync = FrameworkTestEnv.New({
  modules = { "Registry", "PoolKit", "TimerKit", "SchedulerKit", "CodecKit" },
})
CodecKitTestEnv.CoreAsync = CoreAsync

---Write a host global. The fixture stands in for the World of Warcraft client,
---whose API only exists in the global table.
---@param name string
---@param value any
local function setGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Read a host global the same way.
---@param name string
---@return any
local function getGlobal(name)
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Load the asynchronous chain with a CPU clock that advances by `stepMs` on
---every read, so `context:ShouldYield()` turns true after a predictable
---amount of work instead of never (the fixture's clock only moves when a
---spec moves it). SchedulerKit binds `debugprofilestop` when it loads, so the
---wrapper is installed between the stubs and the modules.
---@param stepMs number
---@return table CodecKit
---@return table SchedulerKit
function Async.NewPackageWithTickingClock(stepMs)
  Async.PrepareTickingClock(stepMs)
  local loaded = {}
  for index = 1, #ASYNC_MODULES do
    loaded[ASYNC_MODULES[index]] = require(ASYNC_MODULES[index])
  end
  return loaded.CodecKit, loaded.SchedulerKit
end

---Reset, install the WoW stubs and a CPU clock that advances by `stepMs` on
---every read, loading nothing: a spec then loads the chain itself, for
---example with an older CodecKit revision first.
---@param stepMs number
function Async.PrepareTickingClock(stepMs)
  Async.Reset()
  Async.InstallWowApi()
  local baseClock = getGlobal("debugprofilestop")
  setGlobal("debugprofilestop", function()
    Async.AdvanceProfileMs(stepMs)
    return baseClock()
  end)
end

---Tick the scheduler until `isDone()` or `maxTicks`, and return how many
---ticks it took.
---@param isDone fun(): boolean
---@param maxTicks integer
---@return integer ticks
function Async.TickUntil(isDone, maxTicks)
  local ticks = 0
  while not isDone() and ticks < maxTicks do
    Async.Tick()
    ticks = ticks + 1
  end
  return ticks
end

---Install an `issecretvalue` stub that reports every value in `secrets` as
---secret. CodecKit resolves the probe at load and, when there was none then,
---looks the global up at every call, so the stub may be installed after the
---package has loaded; `Reset` removes it.
---@param secrets table<any, true>
function CodecKitTestEnv.InstallSecretProbe(secrets)
  setGlobal("issecretvalue", function(value)
    return value ~= nil and secrets[value] == true
  end)
end

---Return a table that stands in for a secret value: every operation a secret
---refuses in the client raises here too, so a spec proves CodecKit asked
---`issecretvalue` before touching it.
---@return table secret
function CodecKitTestEnv.NewSecret()
  local function refuse()
    error("attempt to use a secret value", 2)
  end
  return setmetatable({}, {
    __index = refuse,
    __newindex = refuse,
    __len = refuse,
    __concat = refuse,
    __call = refuse,
    __eq = refuse,
    __lt = refuse,
    __le = refuse,
    __tostring = refuse,
  })
end

---Measure the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
---@param workload fun()
---@return number kilobytes
function CodecKitTestEnv.AllocatedKilobytes(workload)
  collectgarbage()
  collectgarbage("stop")
  local before = collectgarbage("count")
  workload()
  local after = collectgarbage("count")
  collectgarbage("restart")
  return after - before
end

---A small deterministic generator (a 31-bit linear congruential sequence), so
---every random input a spec builds is the same on every run and platform.
---@param seed integer
---@return fun(limit: integer): integer next returns an integer from 0 to limit - 1
function CodecKitTestEnv.NewRandom(seed)
  local stateValue = seed % 2147483648
  return function(limit)
    stateValue = (stateValue * 1103515245 + 12345) % 2147483648
    return math.floor(stateValue / 2147483648 * limit)
  end
end

---Build a string of `length` bytes drawn from `random`.
---@param random fun(limit: integer): integer
---@param length integer
---@param alphabetSize integer? bytes 0 .. alphabetSize - 1; default 256
---@return string
function CodecKitTestEnv.RandomBytes(random, length, alphabetSize)
  local limit = alphabetSize or 256
  local parts = {}
  for index = 1, length do
    parts[index] = string.char(random(limit))
  end
  return table.concat(parts)
end

---Build a text of `wordCount` words from a fixed vocabulary.
---@param random fun(limit: integer): integer
---@param wordCount integer
---@return string
function CodecKitTestEnv.RandomText(random, wordCount)
  local words = {
    "the",
    "quick",
    "brown",
    "fox",
    "jumps",
    "over",
    "lazy",
    "dog",
    "raid",
    "frame",
    "addon",
    "settings",
    "profile",
    "aura",
    "cooldown",
    "spell",
  }
  local parts = {}
  for index = 1, wordCount do
    parts[index] = words[random(#words) + 1]
  end
  return table.concat(parts, " ")
end

---Deep equality for decoded values: NaN equals NaN, -0 differs from 0, and
---tables compare by contents. A key that is a table is matched by contents
---rather than identity, since decoding builds new key tables.
---@param left any
---@param right any
---@return boolean
function CodecKitTestEnv.Same(left, right)
  if type(left) ~= type(right) then
    return false
  end
  if type(left) == "number" then
    if left ~= left then
      return right ~= right
    end
    if left == 0 and right == 0 then
      return 1 / left == 1 / right
    end
    return left == right
  end
  if type(left) ~= "table" then
    return left == right
  end
  local count = 0
  for key, value in pairs(left) do
    count = count + 1
    if type(key) == "table" then
      local matched = false
      for otherKey, otherValue in pairs(right) do
        if
          type(otherKey) == "table"
          and CodecKitTestEnv.Same(key, otherKey)
          and CodecKitTestEnv.Same(value, otherValue)
        then
          matched = true
          break
        end
      end
      if not matched then
        return false
      end
    elseif not CodecKitTestEnv.Same(value, right[key]) then
      return false
    end
  end
  for _ in pairs(right) do
    count = count - 1
  end
  return count == 0
end

---Hexadecimal form of a byte string, for readable expected values.
---@param bytes string
---@return string
function CodecKitTestEnv.Hex(bytes)
  return (
    bytes:gsub(".", function(character)
      return string.format("%02x", character:byte())
    end)
  )
end

---The byte string a hexadecimal form describes.
---@param text string
---@return string
function CodecKitTestEnv.Unhex(text)
  return (
    text:gsub("%s", ""):gsub("..", function(pair)
      return string.char(tonumber(pair, 16))
    end)
  )
end

-- The client's encoding functions -----------------------------------------
--
-- `C_EncodingUtil` and `Enum` are not among the globals the shared fixture
-- owns, so this environment installs and removes them itself: both
-- environments' `Reset` is wrapped to clear them.

---Clear the stand-in `C_EncodingUtil` and `Enum`.
local function clearEncodingGlobals()
  setGlobal("C_EncodingUtil", nil)
  setGlobal("Enum", nil)
end

for _, environment in ipairs({ CodecKitTestEnv, Async, Core, CoreAsync }) do
  local frameworkReset = environment.Reset
  environment.Reset = function()
    clearEncodingGlobals()
    frameworkReset()
  end
end

---Write `input` as raw DEFLATE stored blocks (RFC 1951 3.2.4), at most
---65535 bytes each. A second DEFLATE encoder, independent of CodecKit's, so
---its bytes always differ from the Lua compressor's for the inputs the specs
---use and any inflater reads them.
---@param input string
---@return string
local function storedDeflate(input)
  local parts = {}
  local position = 1
  repeat
    local length = math.min(65535, #input - position + 1)
    local final = position + length > #input and 1 or 0
    local complement = 65535 - length
    parts[#parts + 1] = string.char(
      final,
      length % 256,
      math.floor(length / 256),
      complement % 256,
      math.floor(complement / 256)
    )
    parts[#parts + 1] = input:sub(position, position + length - 1)
    position = position + length
  until position > #input
  return table.concat(parts)
end
CodecKitTestEnv.StoredDeflate = storedDeflate

---What a stand-in `CompressString` does, by mode name. Every mode but
---`stored` models a client answer CodecKit must not trust.
local COMPRESS_MODES = {
  stored = function(source)
    return storedDeflate(source)
  end,
  raise = function()
    error("stand-in CompressString raised", 2)
  end,
  nothing = function() end,
  number = function()
    return 42
  end,
  empty = function()
    return ""
  end,
  table = function()
    return {}
  end,
  oversized = function(source)
    return storedDeflate(source) .. string.rep("\0", #source + 1)
  end,
}

---Install a stand-in for the client's `C_EncodingUtil`.
---
---`CompressString` answers as `options.mode` says (`"stored"` by default),
---or as `options.compress(source, method, level)` when given, and records
---every call. `DecompressString` is installed too and records its calls, so a
---spec can prove CodecKit never inflates natively. `options.withoutCompress`
---leaves `CompressString` out; `options.compressValue` puts that value in its
---place instead. `options.enum`, when given, is installed as the global
---`Enum`.
---@param options { mode: string?, compress: function?, withoutCompress: boolean?, compressValue: any, enum: table? }?
---@return { compressCalls: table[], decompressCalls: integer }
function CodecKitTestEnv.InstallEncodingUtil(options)
  options = options or {}
  local record = { compressCalls = {}, decompressCalls = 0 }
  local answer = options.compress or COMPRESS_MODES[options.mode or "stored"]
  if answer == nil then
    error("CodecKitTestEnv.InstallEncodingUtil: unknown mode " .. tostring(options.mode), 2)
  end
  local namespace = {
    DecompressString = function()
      record.decompressCalls = record.decompressCalls + 1
      error("CodecKit must not inflate natively", 2)
    end,
  }
  if options.compressValue ~= nil then
    namespace.CompressString = options.compressValue
  elseif not options.withoutCompress then
    namespace.CompressString = function(source, method, level)
      record.compressCalls[#record.compressCalls + 1] =
        { source = source, method = method, level = level }
      return answer(source, method, level)
    end
  end
  setGlobal("C_EncodingUtil", namespace)
  if options.enum ~= nil then
    setGlobal("Enum", options.enum)
  end
  return record
end

---Set the global `C_EncodingUtil` or `Enum` to any value, such as one of the
---wrong type, to model a client that answers something unexpected. `Reset`
---clears it.
---@param name "C_EncodingUtil"|"Enum"
---@param value any
function CodecKitTestEnv.SetEncodingGlobal(name, value)
  if name ~= "C_EncodingUtil" and name ~= "Enum" then
    error("CodecKitTestEnv.SetEncodingGlobal sets only C_EncodingUtil and Enum", 2)
  end
  setGlobal(name, value)
end

---Remove the stand-in `C_EncodingUtil` and `Enum`, as on a client without
---them, without resetting anything else.
function CodecKitTestEnv.RemoveEncodingUtil()
  clearEncodingGlobals()
end

---Read the CodecKit source text from `package.path`.
---@return string text
---@return string path
local function readSource()
  -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
  -- `require` does.
  local path = nil
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", "CodecKit")
    local file = io.open(candidate, "r")
    if file ~= nil then
      file:close()
      path = candidate
      break
    end
  end
  if path == nil then
    error("CodecKitTestEnv could not find CodecKit.lua on package.path", 3)
  end

  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return text, path
end

---Replace the one occurrence of the plain text `find` in `text`, raising when
---it occurs any other number of times, so a spec never runs against a patch
---that silently did nothing.
---@param text string
---@param find string plain text, not a pattern
---@param replacement string
---@return string
local function replaceOnce(text, find, replacement)
  local first = text:find(find, 1, true)
  if first == nil or text:find(find, first + 1, true) ~= nil then
    error("CodecKitTestEnv expected exactly one occurrence of: " .. find, 3)
  end
  return text:sub(1, first - 1) .. replacement .. text:sub(first + #find)
end

-- The last revision that carried the compression stage in CodecKit.lua
-- itself. Its file is kept verbatim as a fixture, so an "older copy" in the
-- upgrade specs is the whole file an addon of that time embedded.
local LAST_WHOLE_REVISION = 9
local SUPPORT_DIRECTORY = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
local WHOLE_FIXTURE = SUPPORT_DIRECTORY .. "../fixtures/CodecKit-revision9.lua"

---Read the whole-file revision 9 fixture.
---@return string text
---@return string path
local function readWholeSource()
  local file = assert(io.open(WHOLE_FIXTURE, "r"))
  local text = file:read("*a")
  file:close()
  return text, WHOLE_FIXTURE
end

---Load the CodecKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client. `find` and
---`replacement`, when given, replace one more piece of source text, to model
---what that older revision did differently. A revision up to 9 is loaded from
---the whole-file fixture (compression included, no parts); a later one from
---the core in `src/`.
---@param revision integer
---@param find string? plain source text that must occur exactly once
---@param replacement string?
---@return table CodecKit
function CodecKitTestEnv.LoadRevision(revision, find, replacement)
  local text, path
  if revision <= LAST_WHOLE_REVISION then
    text, path = readWholeSource()
  else
    text, path = readSource()
  end
  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  if replacements ~= 1 then
    error("CodecKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
  end
  if find ~= nil then
    patched = replaceOnce(patched, find, replacement)
  end

  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

---Load the CodecKit source with one piece of source text replaced, to model a
---host whose behaviour stock Lua cannot reproduce. The copy carries the
---shipped revision, and a duplicate load of the same revision keeps the
---installed functions, so call it after `Reset` and requiring Registry and
---PoolKit: the patched copy is then the one that installs.
---@param find string plain source text that must occur exactly once
---@param replacement string
---@return table CodecKit
function CodecKitTestEnv.LoadPatched(find, replacement)
  local text, path = readSource()
  local chunk = assert(loadstring(replaceOnce(text, find, replacement), "@" .. path))
  return chunk()
end

---Run the core file again over the state it already published, as a second
---addon embedding the same revision does. (`ReloadPackage` reruns the last
---module of the chain, which is the Compression part.)
---@return table CodecKit
function CodecKitTestEnv.ReloadCore()
  package.loaded["CodecKit"] = nil
  return require("CodecKit")
end

---Load the Compression part again, after a `Reset` or an upgrade that
---cleared it, as the next file of an addon's `embeds.xml` would.
---@return table CodecKit
function CodecKitTestEnv.LoadPart()
  package.loaded["CodecKit-Compression"] = nil
  return require("CodecKit-Compression")
end

---Load the Compression part's source as a copy carrying `revision`.
---@param revision integer
---@return table CodecKit
function CodecKitTestEnv.LoadPartRevision(revision)
  local path = nil
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", "CodecKit-Compression")
    local file = io.open(candidate, "r")
    if file ~= nil then
      file:close()
      path = candidate
      break
    end
  end
  assert(path ~= nil, "CodecKitTestEnv could not find CodecKit-Compression.lua on package.path")
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  local patched, count =
    text:gsub("local PART_REVISION = %d+", "local PART_REVISION = " .. revision)
  assert(count == 1, "the part declares PART_REVISION once")
  return assert(loadstring(patched, "@" .. path))()
end

return CodecKitTestEnv
