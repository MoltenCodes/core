--- Package-specific test environment for the ProfileKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order and the one helper
--- only its specs need.
---
--- Time is driven through the shared `ClockStub`: `debugprofilestop` returns the
--- stub's addon CPU clock, which a spec moves with `AdvanceProfileMs` and jumps
--- with `SetProfileMs`.
local FrameworkTestEnv = require("FrameworkTestEnv")

local MODULES = { "Registry", "ProfileKit" }

local ProfileKitTestEnv = FrameworkTestEnv.New({
  modules = MODULES,
})

---Load the module chain into a host that publishes no `debugprofilestop`.
---
---`NewPackage` resets the stubs, which would restore the clock, so the chain is
---loaded by hand after withholding it. ProfileKit binds the clock once at load.
---@return table ProfileKit
---@return table Registry
function ProfileKitTestEnv.NewPackageWithoutProfilingClock()
  ProfileKitTestEnv.Reset()
  ProfileKitTestEnv.WithoutProfilingClock()
  ProfileKitTestEnv.InstallWowApi()

  local Registry = require(MODULES[1])
  local ProfileKit = require(MODULES[2])
  return ProfileKit, Registry
end

---Kilobytes allocated while `action` runs, with the collector stopped.
---
---`action` runs once beforehand so one-time costs (a stack that grows, a
---section created on first use) are not counted.
---@param action fun()
---@return number kilobytes
function ProfileKitTestEnv.AllocatedKilobytes(action)
  action()
  collectgarbage()
  collectgarbage("stop")
  local before = collectgarbage("count")
  action()
  local after = collectgarbage("count")
  collectgarbage("restart")
  return after - before
end

return ProfileKitTestEnv
