--- Package-specific test environment for the SchedulerKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order.
---
--- SchedulerKit requires Registry and TimerKit and nothing else, so the chain
--- is the three files an addon embeds to use SchedulerKit alone. LifecycleKit
--- and EventKit are optional dependencies that only decide who closes an addon
--- scope at logout. The manifest declares both under `optionalDependencies`,
--- so the test runner puts them and their required closures on `LUA_PATH`;
--- `LoadEventKit` and `LoadLifecycleKit` load them on top of the chain the way
--- an addon that also embeds them would, and `Reset` unloads them again.
---
--- The coalescing family lives in three parts. `NewPackage` loads the core and
--- every part, as an addon that embeds the whole Kit would, so the family's
--- specs run unchanged; `NewCore` loads the core alone, and `LoadPart(name)`
--- adds one part on top. Part files are found by `require("SchedulerKit-Lanes")`:
--- the test runner puts every package's `src/parts/` on the path.
local FrameworkTestEnv = require("FrameworkTestEnv")

local SchedulerKitTestEnv = FrameworkTestEnv.New({
  modules = {
    "Registry",
    "TimerKit",
    "SchedulerKit",
  },
})

--- The optional modules the helpers below may load, in load order.
local OPTIONAL_MODULES = { "EventKit", "LifecycleKit" }

--- The part modules, in load order (Lanes and Watch need Coalescing).
SchedulerKitTestEnv.PARTS = { "Coalescing", "Lanes", "Watch" }

local resetFixture = SchedulerKitTestEnv.Reset
local newCore = SchedulerKitTestEnv.NewPackage

---Reset the shared fixture and unload the optional modules and the parts.
function SchedulerKitTestEnv.Reset()
  resetFixture()
  for index = #OPTIONAL_MODULES, 1, -1 do
    package.loaded[OPTIONAL_MODULES[index]] = nil
  end
  for index = 1, #SchedulerKitTestEnv.PARTS do
    package.loaded["SchedulerKit-" .. SchedulerKitTestEnv.PARTS[index]] = nil
  end
end

---Load Registry, TimerKit and SchedulerKit's core only.
---@return table SchedulerKit
---@return table Registry
---@return table TimerKit
function SchedulerKitTestEnv.NewCore()
  return newCore()
end

---Load one part on top of what is loaded.
---@param name string `"Coalescing"`, `"Lanes"` or `"Watch"`
---@return table SchedulerKit
function SchedulerKitTestEnv.LoadPart(name)
  return require("SchedulerKit-" .. name)
end

---Run every part file on top of what is loaded, in load order, as an addon
---that embeds them would after the core. A part already installed at its
---revision returns without changes.
---@return table SchedulerKit
function SchedulerKitTestEnv.LoadParts()
  local SchedulerKit
  for index = 1, #SchedulerKitTestEnv.PARTS do
    local moduleName = "SchedulerKit-" .. SchedulerKitTestEnv.PARTS[index]
    package.loaded[moduleName] = nil
    SchedulerKit = require(moduleName)
  end
  return SchedulerKit
end

---Load the core and every part, as an addon embedding the whole Kit.
---@return table SchedulerKit
---@return table Registry
---@return table TimerKit
function SchedulerKitTestEnv.NewPackage()
  local SchedulerKit, Registry, TimerKit = newCore()
  SchedulerKitTestEnv.LoadParts()
  return SchedulerKit, Registry, TimerKit
end

---Load EventKit after the chain `NewPackage` loaded.
---@return table EventKit
function SchedulerKitTestEnv.LoadEventKit()
  return require("EventKit")
end

---Load EventKit and LifecycleKit after the chain `NewPackage`
---loaded.
---@return table LifecycleKit
---@return table EventKit
function SchedulerKitTestEnv.LoadLifecycleKit()
  local EventKit = SchedulerKitTestEnv.LoadEventKit()
  return require("LifecycleKit"), EventKit
end

---Measure the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
---@param workload fun()
---@return number kilobytes
function SchedulerKitTestEnv.AllocatedKilobytes(workload)
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
---`IMPLEMENTATION_REVISION` rewritten, so `require("SchedulerKit")` afterwards
---upgrades that copy in place.
---@param revision integer
---@return table SchedulerKit
function SchedulerKitTestEnv.LoadRevision(revision)
  -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
  -- `require` does.
  local path = nil
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", "SchedulerKit")
    local file = io.open(candidate, "r")
    if file ~= nil then
      file:close()
      path = candidate
      break
    end
  end
  if path == nil then
    error("SchedulerKitTestEnv.LoadRevision could not find SchedulerKit.lua on package.path", 2)
  end

  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()

  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  if replacements ~= 1 then
    error("SchedulerKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
  end

  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

-- The last whole-file revision, kept verbatim so a spec can stand in for an
-- addon that embeds it (revision 21, the coalescing family in one file).
local WHOLE_REVISION_FIXTURE = "packages/schedulerKit/tests/fixtures/SchedulerKit-revision21.lua"

---Run the whole-file revision 21 as an older embedded copy would.
---@return table SchedulerKit the facade Registry hands that copy
function SchedulerKitTestEnv.LoadWholeRevision()
  local chunk = assert(loadfile(WHOLE_REVISION_FIXTURE))
  return chunk()
end

---Run one part file as if it were part revision `revision`, standing in for a
---copy of the part another addon embeds.
---@param name string `"Coalescing"`, `"Lanes"` or `"Watch"`
---@param revision integer
---@return table SchedulerKit
function SchedulerKitTestEnv.LoadPartRevision(name, revision)
  local path = "packages/schedulerKit/src/parts/SchedulerKit-" .. name .. ".lua"
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  local patched, replacements =
    text:gsub("local PART_REVISION = %d+", "local PART_REVISION = " .. revision)
  if replacements ~= 1 then
    error("SchedulerKitTestEnv.LoadPartRevision could not find PART_REVISION", 2)
  end
  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

return SchedulerKitTestEnv
