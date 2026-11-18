--- Package-specific test environment for the TimerKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order.
---
--- TimerKit requires Registry and nothing else, so the chain is two modules:
--- the two files an addon embeds to use TimerKit alone. LifecycleKit and
--- EventKit are optional dependencies that only decide who closes an addon
--- scope at logout. The manifest declares both under `optionalDependencies`,
--- so the test runner puts them and their required closures on `LUA_PATH`;
--- `LoadEventKit` and `LoadLifecycleKit` load them on top of the chain the way
--- an addon that also embeds them would, and `Reset` unloads them again.
--- Pausing is TimerKit's Pausing part; `LoadPausing` adds it on top of the core
--- for the specs that pause, and `Reset` unloads it too.
local FrameworkTestEnv = require("FrameworkTestEnv")

local TimerKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "TimerKit" },
})

--- TimerKit's specs name the native-timer failure hooks without the `Timer`
--- infix the shared fixture uses, because in this suite there is nothing else
--- a failed creation or cancellation could refer to.
TimerKitTestEnv.FailNextCreate = TimerKitTestEnv.FailNextTimerCreate
TimerKitTestEnv.FailNextCancel = TimerKitTestEnv.FailNextTimerCancel

--- The optional modules the helpers below may load, in load order.
local OPTIONAL_MODULES = { "TimerKit-Pausing", "SignalKit", "EventKit", "LifecycleKit" }

local resetFixture = TimerKitTestEnv.Reset

---Reset the shared fixture and unload the optional modules.
function TimerKitTestEnv.Reset()
  resetFixture()
  for index = #OPTIONAL_MODULES, 1, -1 do
    package.loaded[OPTIONAL_MODULES[index]] = nil
  end
end

---Load TimerKit's Pausing part on top of the core a spec loaded.
---@return table TimerKit
function TimerKitTestEnv.LoadPausing()
  return require("TimerKit-Pausing")
end

---Run the byte copy of revision 14 kept in `tests/fixtures/`, the revision
---this one upgrades in place from, as an older embedded copy would load.
---@return table TimerKit
function TimerKitTestEnv.LoadRevision14()
  local directory = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
  local path = directory .. "../fixtures/TimerKit-revision14.lua"
  local chunk = assert(loadfile(path))
  return chunk()
end

---Load SignalKit and EventKit after the chain `NewPackage` loaded.
---@return table EventKit
function TimerKitTestEnv.LoadEventKit()
  require("SignalKit")
  return require("EventKit")
end

---Load SignalKit, EventKit and LifecycleKit after the chain `NewPackage`
---loaded.
---@return table LifecycleKit
---@return table EventKit
function TimerKitTestEnv.LoadLifecycleKit()
  local EventKit = TimerKitTestEnv.LoadEventKit()
  return require("LifecycleKit"), EventKit
end

---Return the kilobytes `workload` allocates, with the collector stopped so
---nothing allocated is reclaimed before it is counted.
---@param workload fun()
---@return number kilobytes
function TimerKitTestEnv.AllocatedKilobytes(workload)
  collectgarbage()
  collectgarbage("stop")
  local before = collectgarbage("count")
  workload()
  local after = collectgarbage("count")
  collectgarbage("restart")
  return after - before
end

---Run this package's own source as if it were implementation revision
---`revision`, to stand in for an older embedded copy in upgrade specs.
---
---The file is read from `package.path` and loaded with its
---`IMPLEMENTATION_REVISION` rewritten, so `require("TimerKit")` afterwards
---upgrades that copy in place.
---@param revision integer
---@return table TimerKit
function TimerKitTestEnv.LoadRevision(revision)
  -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
  -- `require` does.
  local path = nil
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", "TimerKit")
    local file = io.open(candidate, "r")
    if file ~= nil then
      file:close()
      path = candidate
      break
    end
  end
  if path == nil then
    error("TimerKitTestEnv.LoadRevision could not find TimerKit.lua on package.path", 2)
  end

  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()

  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  if replacements ~= 1 then
    error("TimerKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
  end

  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

---Whether `timer` is stored in the nine-slot array layout.
---@param TimerKit table the loaded facade
---@param timer table
---@return boolean
function TimerKitTestEnv.HasRecordLayout(TimerKit, timer)
  local state = rawget(TimerKit, "_state")
  return getmetatable(timer) == rawget(state, "timerRecordMetatable")
    and type(rawget(timer, 1)) == "number"
    and rawget(timer, "_state") == nil
end

return TimerKitTestEnv
