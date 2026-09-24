--- Package-specific test environment for the CodecKit suite.
---
--- The `package.loaded` bookkeeping, the error capture and the World of
--- Warcraft stubs live in the shared `FrameworkTestEnv` fixture at
--- `tests/support/`. What stays here is this package's two module chains and
--- the helpers only its specs describe: a local `issecretvalue` stub, a value
--- that refuses every operation a secret refuses, allocation measurement, a
--- seeded byte generator, deep equality that understands NaN and -0, and an
--- in-place upgrade.
---
--- The default environment loads Registry, PoolKit and CodecKit without the
--- WoW stubs: CodecKit is pure Lua. `CodecKitTestEnv.Async` is a second
--- environment that also loads TimerKit and SchedulerKit, SchedulerKit's
--- required closure, for the asynchronous variants. SchedulerKit is declared under
--- `optionalDependencies`, so the test runner puts it and its closure on
--- `LUA_PATH`.
local FrameworkTestEnv = require("FrameworkTestEnv")

local CodecKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "PoolKit", "CodecKit" },
  wowApi = false,
})

--- The module chain the asynchronous specs load, CodecKit last.
local ASYNC_MODULES = {
  "Registry",
  "PoolKit",
  "TimerKit",
  "SchedulerKit",
  "CodecKit",
}

local Async = FrameworkTestEnv.New({ modules = ASYNC_MODULES })
CodecKitTestEnv.Async = Async

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
  Async.Reset()
  Async.InstallWowApi()
  local baseClock = getGlobal("debugprofilestop")
  setGlobal("debugprofilestop", function()
    Async.AdvanceProfileMs(stepMs)
    return baseClock()
  end)
  local loaded = {}
  for index = 1, #ASYNC_MODULES do
    loaded[ASYNC_MODULES[index]] = require(ASYNC_MODULES[index])
  end
  return loaded.CodecKit, loaded.SchedulerKit
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
---secret. CodecKit looks the probe up at every call, so the stub may be
---installed after the package has loaded; `Reset` removes it.
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

---Load the CodecKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client.
---@param revision integer
---@return table CodecKit
function CodecKitTestEnv.LoadRevision(revision)
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
    error("CodecKitTestEnv.LoadRevision could not find CodecKit.lua on package.path", 2)
  end

  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()

  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  if replacements ~= 1 then
    error("CodecKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
  end

  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

return CodecKitTestEnv
