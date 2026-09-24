--- Package-specific test environment for the PoolKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order.
local FrameworkTestEnv = require("FrameworkTestEnv")

local PoolKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "PoolKit" },
  -- PoolKit is pure Lua and stays silent without a host error sink, so its
  -- specs install `geterrorhandler` explicitly through
  -- `InstallHostErrorHandler` rather than having it installed for them.
  wowApi = false,
})

--- Diagnostics PoolKit handed to the host error handler, in order.
---@return any[]
function PoolKitTestEnv.ReportedWarnings()
  return PoolKitTestEnv.ReportedErrors()
end

---A stand-in for a World of Warcraft AnimationGroup, reduced to what
---`Pool:ReleaseAfter` touches: `HookScript("OnFinished", handler)` and
---`IsPlaying()`, plus the `Play` and `Stop` methods its shape check requires.
---`Finish()` ends the animation the way the client does, calling every hooked
---`OnFinished` handler with the group and `requested = false`; `Stop()` ends it
---without firing `OnFinished`, as the client does.
---
---The shared fixture has no animation stubs because only PoolKit needs one.
---@return table group
function PoolKitTestEnv.NewAnimationGroup()
  local group = { playing = true, hooks = {} }

  function group:HookScript(scriptName, handler)
    if scriptName ~= "OnFinished" then
      error("the animation group stub only models OnFinished, got " .. tostring(scriptName), 2)
    end
    self.hooks[#self.hooks + 1] = handler
  end

  function group:IsPlaying()
    return self.playing
  end

  function group:Play()
    self.playing = true
  end

  function group:Stop()
    self.playing = false
  end

  function group:Finish()
    self.playing = false
    for index = 1, #self.hooks do
      self.hooks[index](self, false)
    end
  end

  return group
end

---Load `PoolKit.lua` from `package.path` with its `IMPLEMENTATION_REVISION`
---patched to `revision`, and run it as that revision would load.
---
---This stands in for an older embedded copy whose private state has the same
---schema as the current one, which is what an in-place upgrade between
---neighbouring revisions of the same schema inherits.
---@param revision integer
---@return table PoolKit
function PoolKitTestEnv.LoadRevision(revision)
  -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
  -- `require` does.
  local path = nil
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", "PoolKit")
    local file = io.open(candidate, "r")
    if file ~= nil then
      file:close()
      path = candidate
      break
    end
  end
  if path == nil then
    error("PoolKitTestEnv.LoadRevision could not find PoolKit.lua on package.path", 2)
  end

  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()

  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  if replacements ~= 1 then
    error("PoolKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
  end

  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

return PoolKitTestEnv
