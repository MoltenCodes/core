--- Hooks: HookKit against AceHook-3.0.
---
--- Both libraries offer the same three hook semantics under the same names:
--- a safe pre-hook (`Hook`, `HookScript`: the handler runs first, the original
--- always runs after it), a raw replacement (`RawHook`, `RawHookScript`: the
--- handler runs instead and may call the original), and a secure post-hook
--- (`SecureHook`, `SecureHookScript`: the host's `hooksecurefunc` or
--- `Frame:HookScript` calls the handler after the original). Both undo a hook
--- with `Unhook`: a pre-hook or replacement is restored when nobody hooked the
--- target after it, and a secure post-hook, which the host cannot remove, stays
--- in the host's chain as an inert closure that reads one flag.
---
--- "The same work" is therefore:
---
--- - installing and removing one hook of each kind on the same target, with a
---   handler given as a function on both sides (AceHook also accepts a method
---   name; HookKit does not, so that form is not measured);
--- - calling the hooked target with one argument and returning its result.
---
--- What differs, and is reported as *different work* rather than a ratio:
--- HookKit runs pre-hook and post-hook handlers under `pcall` and reports a
--- failure to the host error handler, so a failing handler never stops the
--- original or the caller; AceHook calls them directly, so a failing pre-hook
--- handler stops the original and raises to the caller. A raw replacement
--- raises to the caller on both sides, so its call is compared. The inert
--- closure a removed post-hook leaves behind does the same on both sides (one
--- flag read, no call), so it is compared too.
---
--- Left out on purpose: HookKit's scope ownership (`ForAddon`, closing at
--- logout) has no AceHook counterpart beyond `UnhookAll`, and its refusals of
--- secure targets and protected frames depend on the client's
--- `issecurevariable` and `IsProtected`, which the host answers with `false`
--- for every target (they are the benchmark's own tables and frames).

local Bench = require("Bench")

local Hooks = {}

--- Install-and-remove operations per timed batch.
local HOOK_ITERATIONS = 20000

--- Calls through a hooked target per timed batch.
local CALL_ITERATIONS = 500000

--- Cycles used for the retained-memory measurements.
local RETAINED_PROBE = 1000

--- The global function the global-function cases hook.
local GLOBAL_NAME = "MoltenCodesBenchHookTarget"

local function noop() end

---The original every case hooks: returns its argument.
---@param _ table the object
---@param value any
---@return any
local function identityMethod(_, value)
  return value
end

---@param value any
---@return any
local function identityFunction(value)
  return value
end

---Write a host global, as an addon defining a global function would.
---@param name string
---@param value any
local function setGlobal(name, value)
  -- The hooked global function lives in the global table, as in the client.
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---A fresh object with one method, as another addon's table would be.
---@return table
local function newTarget()
  return { Method = identityMethod }
end

---@param host table
---@return table adapter, table[] libraries
local function kitAdapter(host)
  local loaded = host.RequireAll({ "Registry", "HookKit" })
  local HookKit = loaded[2]
  local scope = HookKit:CreateScope({ maxHooks = HookKit.UNBOUNDED })
  local adapter = {}

  function adapter.hookFunction(name, handler)
    scope:Hook(name, handler)
  end

  function adapter.unhookFunction(name)
    return scope:Unhook(name)
  end

  function adapter.hook(object, method, handler)
    scope:Hook(object, method, handler)
  end

  ---A replacement that calls the original with the call's arguments.
  function adapter.rawHookPassThrough(object, method)
    scope:RawHook(object, method, function(original, self, value)
      return original(self, value)
    end)
  end

  ---A replacement whose handler receives the original and the arguments.
  function adapter.rawHook(object, method, handler)
    scope:RawHook(object, method, handler)
  end

  function adapter.secureHook(object, method, handler)
    scope:SecureHook(object, method, handler)
  end

  function adapter.hookScript(frame, script, handler)
    scope:HookScript(frame, script, handler)
  end

  function adapter.unhook(object, method)
    return scope:Unhook(object, method)
  end

  function adapter.activeCount()
    return scope:GetActiveCount()
  end

  return adapter, { { name = "HookKit", revision = HookKit.REVISION } }
end

---@param host table
---@param directory string the Ace3 checkout
---@return table adapter, table[] libraries
local function aceAdapter(host, directory)
  host.LoadFiles(directory, { "LibStub/LibStub.lua", "AceHook-3.0/AceHook-3.0.lua" })
  local LibStub = host.Global("LibStub")
  local AceHook, minor = LibStub:GetLibrary("AceHook-3.0")
  local owner = AceHook:Embed({})
  local originals = owner.hooks
  local adapter = {}

  function adapter.hookFunction(name, handler)
    owner:Hook(name, handler)
  end

  function adapter.unhookFunction(name)
    return owner:Unhook(name)
  end

  function adapter.hook(object, method, handler)
    owner:Hook(object, method, handler)
  end

  ---A replacement that calls the original the documented AceHook way,
  ---through `self.hooks[object][method]`.
  function adapter.rawHookPassThrough(object, method)
    owner:RawHook(object, method, function(self, value)
      return originals[object][method](self, value)
    end)
  end

  ---A replacement whose handler receives the original and the arguments, as
  ---HookKit's does, so the checks can share one handler.
  function adapter.rawHook(object, method, handler)
    owner:RawHook(object, method, function(...)
      return handler(originals[object][method], ...)
    end)
  end

  function adapter.secureHook(object, method, handler)
    owner:SecureHook(object, method, handler)
  end

  function adapter.hookScript(frame, script, handler)
    owner:HookScript(frame, script, handler)
  end

  function adapter.unhook(object, method)
    return owner:Unhook(object, method)
  end

  function adapter.activeCount()
    local count = 0
    for _, value in pairs(AceHook.actives) do
      if value then
        count = count + 1
      end
    end
    return count
  end

  return adapter, { { name = "AceHook-3.0", minor = minor } }
end

---Retained bytes per cycle of `cycle`, run `RETAINED_PROBE` times.
---@param cycle fun()
---@return number
local function retainedPerCycle(cycle)
  local baseline = Bench.RetainedBytes()
  for _ = 1, RETAINED_PROBE do
    cycle()
  end
  return (Bench.RetainedBytes() - baseline) / RETAINED_PROBE
end

---A hook-and-unhook case over one fixed target.
---@param name string
---@param operation string
---@param install fun(target: table)
---@param remove fun(target: table)
---@param makeTarget fun(): table
---@return Bench.Case
local function installCase(name, operation, install, remove, makeTarget)
  return {
    name = name,
    iterations = HOOK_ITERATIONS,
    operation = operation,
    prepare = function()
      local target = makeTarget()
      local original = target.Method
      return {
        run = function(iterations)
          for _ = 1, iterations do
            install(target)
            remove(target)
          end
        end,
        metrics = function()
          return {
            originalRestored = rawget(target, "Method") == original,
            retainedBytesPerCycle = retainedPerCycle(function()
              install(target)
              remove(target)
            end),
          }
        end,
      }
    end,
  }
end

---A call-through case: `hookTarget` hooks a fresh target, then the batch calls it.
---@param name string
---@param operation string
---@param hookTarget fun(target: table)
---@param options { equivalent: boolean?, note: string? }?
---@return Bench.Case
local function callCase(name, operation, hookTarget, options)
  options = options or {}
  return {
    name = name,
    iterations = CALL_ITERATIONS,
    operation = operation,
    equivalent = options.equivalent,
    note = options.note,
    prepare = function()
      local target = newTarget()
      hookTarget(target)
      local sum = 0
      return {
        run = function(iterations)
          local method = target.Method
          for index = 1, iterations do
            sum = sum + method(target, index)
          end
        end,
        metrics = function()
          -- Keeps the results observable, so no call could be skipped.
          return { resultsReturned = sum > 0 }
        end,
      }
    end,
  }
end

---@param adapter table
---@param host table
---@return Bench.Case[]
local function cases(adapter, host)
  local createFrame = host.Global("CreateFrame")
  local isolationNote = "HookKit isolates the handler with pcall and reports its errors; "
    .. "AceHook calls it directly"

  return {
    {
      name = "hook-unhook-function",
      iterations = HOOK_ITERATIONS,
      operation = "pre-hook a global function and unhook it",
      prepare = function()
        setGlobal(GLOBAL_NAME, identityFunction)
        local function cycle()
          adapter.hookFunction(GLOBAL_NAME, noop)
          adapter.unhookFunction(GLOBAL_NAME)
        end
        return {
          run = function(iterations)
            for _ = 1, iterations do
              cycle()
            end
          end,
          metrics = function()
            return {
              originalRestored = host.Global(GLOBAL_NAME) == identityFunction,
              retainedBytesPerCycle = retainedPerCycle(cycle),
            }
          end,
        }
      end,
    },
    installCase("hook-unhook-method", "pre-hook a method and unhook it", function(target)
      adapter.hook(target, "Method", noop)
    end, function(target)
      adapter.unhook(target, "Method")
    end, newTarget),
    installCase(
      "rawhook-unhook-method",
      "replace a method (raw hook) and unhook it",
      function(target)
        adapter.rawHookPassThrough(target, "Method")
      end,
      function(target)
        adapter.unhook(target, "Method")
      end,
      newTarget
    ),
    {
      name = "hook-unhook-script",
      iterations = HOOK_ITERATIONS,
      operation = "pre-hook a frame's OnShow script and unhook it",
      prepare = function()
        local frame = createFrame("Frame")
        local original = function() end
        frame:SetScript("OnShow", original)
        local function cycle()
          adapter.hookScript(frame, "OnShow", noop)
          adapter.unhook(frame, "OnShow")
        end
        return {
          run = function(iterations)
            for _ = 1, iterations do
              cycle()
            end
          end,
          metrics = function()
            return {
              originalRestored = frame:GetScript("OnShow") == original,
              retainedBytesPerCycle = retainedPerCycle(cycle),
            }
          end,
        }
      end,
    },
    {
      name = "securehook-unhook-method",
      iterations = HOOK_ITERATIONS,
      operation = "post-hook a method (hooksecurefunc) and unhook it, on a fresh object each time",
      prepare = function()
        local targets = {}
        return {
          -- A fresh object per operation, built outside the timed region:
          -- a post-hook cannot be removed, so hooking one target again and
          -- again would grow its host chain and time the chain, not the hook.
          beforeBatch = function(iterations)
            for index = 1, iterations do
              targets[index] = newTarget()
            end
          end,
          run = function(iterations)
            for index = 1, iterations do
              local target = targets[index]
              adapter.secureHook(target, "Method", noop)
              adapter.unhook(target, "Method")
            end
          end,
          afterBatch = function(iterations)
            for index = 1, iterations do
              targets[index] = nil
            end
          end,
          -- The same target hooked and unhooked repeatedly: what each cycle
          -- leaves in the host's chain, on both sides.
          metrics = function()
            local target = newTarget()
            return {
              retainedBytesPerRepeatedCycleOnOneTarget = retainedPerCycle(function()
                adapter.secureHook(target, "Method", noop)
                adapter.unhook(target, "Method")
              end),
            }
          end,
        }
      end,
    },
    callCase("call-prehooked-method", "call a pre-hooked method (empty handler)", function(target)
      adapter.hook(target, "Method", noop)
    end, { equivalent = false, note = isolationNote }),
    callCase(
      "call-posthooked-method",
      "call a post-hooked method (hooksecurefunc, empty handler)",
      function(target)
        adapter.secureHook(target, "Method", noop)
      end,
      { equivalent = false, note = isolationNote }
    ),
    callCase(
      "call-rawhooked-method",
      "call a raw-hooked method whose handler calls the original",
      function(target)
        adapter.rawHookPassThrough(target, "Method")
      end
    ),
    callCase(
      "call-unhooked-posthook",
      "call a method whose post-hook was unhooked (inert closure left in the chain)",
      function(target)
        adapter.secureHook(target, "Method", noop)
        adapter.unhook(target, "Method")
      end
    ),
    {
      name = "call-prehooked-script",
      iterations = CALL_ITERATIONS,
      operation = "run a frame script that is pre-hooked (empty handler)",
      equivalent = false,
      note = isolationNote,
      prepare = function()
        local frame = createFrame("Frame")
        local shown = 0
        frame:SetScript("OnShow", function()
          shown = shown + 1
        end)
        adapter.hookScript(frame, "OnShow", noop)
        local script = frame:GetScript("OnShow")
        return {
          run = function(iterations)
            for _ = 1, iterations do
              script(frame)
            end
          end,
          metrics = function()
            return { originalRan = shown > 0 }
          end,
        }
      end,
    },
  }
end

---@param adapter table
---@param host table
---@return table[] checks
local function runChecks(adapter, host)
  local results = {}
  local function record(name, passed, detail, promised)
    results[#results + 1] = {
      name = name,
      passed = passed,
      detail = detail,
      promised = promised,
    }
  end
  local isKit = adapter.side == "moltencodes"

  -- A pre-hook runs first, the original after, and the original's results
  -- (every one, nils included) reach the caller.
  do
    local order = {}
    local target = {
      Method = function(_, value)
        order[#order + 1] = "original"
        return value, nil, "third"
      end,
    }
    adapter.hook(target, "Method", function()
      order[#order + 1] = "handler"
    end)
    local count = select("#", target:Method(1))
    local first, _, third = target:Method(2)
    adapter.unhook(target, "Method")
    record(
      "prehook-runs-first-and-passes-results",
      order[1] == "handler"
        and order[2] == "original"
        and count == 3
        and first == 2
        and third == "third",
      "order: " .. table.concat(order, " ", 1, 2) .. ", results returned: " .. count,
      true
    )
  end

  -- Unhook restores exactly the function that was there.
  do
    local target = newTarget()
    local original = target.Method
    adapter.hook(target, "Method", noop)
    local unhooked = adapter.unhook(target, "Method")
    record(
      "unhook-restores-method",
      unhooked and rawget(target, "Method") == original,
      "unhook returned "
        .. tostring(unhooked)
        .. ", original back: "
        .. tostring(rawget(target, "Method") == original),
      true
    )
  end

  -- A method the object inherits through `__index`: unhooking should leave
  -- the object as it was, with no field of its own.
  do
    local class = { Method = identityMethod }
    local target = setmetatable({}, { __index = class })
    adapter.hook(target, "Method", noop)
    adapter.unhook(target, "Method")
    local ownField = rawget(target, "Method") ~= nil
    record(
      "unhook-inherited-method-leaves-no-field",
      not ownField,
      "object has its own Method field after unhook: " .. tostring(ownField),
      isKit
    )
  end

  -- A second hook of the same target from the same owner is refused.
  do
    local target = newTarget()
    adapter.hook(target, "Method", noop)
    local ok = pcall(adapter.hook, target, "Method", noop)
    adapter.unhook(target, "Method")
    record(
      "second-hook-refused",
      not ok,
      "second hook of the same method " .. (ok and "was accepted" or "raised"),
      true
    )
  end

  -- Someone else hooks the target after us; our unhook must not cut them out.
  do
    local target = newTarget()
    local theirs = 0
    adapter.hook(target, "Method", noop)
    local ours = target.Method
    target.Method = function(self, value)
      theirs = theirs + 1
      return ours(self, value)
    end
    adapter.unhook(target, "Method")
    local result = target:Method(7)
    record(
      "unhook-under-foreign-hook-keeps-chain",
      theirs == 1 and result == 7,
      "later hook still called: " .. theirs .. ", result: " .. tostring(result),
      true
    )
  end

  -- A failing pre-hook handler: does the original still run, and does the
  -- caller get its result?
  do
    local ran = 0
    local target = {
      Method = function(_, value)
        ran = ran + 1
        return value
      end,
    }
    adapter.hook(target, "Method", function()
      error("handler failure", 0)
    end)
    local ok, result = pcall(target.Method, target, 5)
    adapter.unhook(target, "Method")
    local reported = #host.TakeReportedErrors()
    record(
      "prehook-error-isolated",
      ok and result == 5 and ran == 1,
      "call returned normally: "
        .. tostring(ok)
        .. ", original ran: "
        .. ran
        .. ", errors reported: "
        .. reported,
      isKit
    )
  end

  -- A failing post-hook handler: does the caller still get the result?
  do
    local target = newTarget()
    adapter.secureHook(target, "Method", function()
      error("handler failure", 0)
    end)
    local ok, result = pcall(target.Method, target, 5)
    adapter.unhook(target, "Method")
    host.TakeReportedErrors()
    record(
      "posthook-error-isolated",
      ok and result == 5,
      "call returned normally: " .. tostring(ok),
      isKit
    )
  end

  -- An unhooked post-hook is inert.
  do
    local calls = 0
    local target = newTarget()
    adapter.secureHook(target, "Method", function()
      calls = calls + 1
    end)
    target:Method(1)
    adapter.unhook(target, "Method")
    target:Method(1)
    record(
      "unhooked-posthook-inert",
      calls == 1,
      "handler calls: 1 before unhook expected, " .. calls .. " in all",
      true
    )
  end

  -- A raw replacement decides the result and can call the original.
  do
    local target = newTarget()
    adapter.rawHook(target, "Method", function(original, self, value)
      return original(self, value) * 2
    end)
    local result = target:Method(21)
    adapter.unhook(target, "Method")
    record("rawhook-replaces-result", result == 42, "result: " .. tostring(result), true)
  end

  -- A script pre-hook runs before the script, and unhook puts the script back.
  do
    local frame = host.Global("CreateFrame")("Frame")
    local order = {}
    local original = function()
      order[#order + 1] = "script"
    end
    frame:SetScript("OnShow", original)
    adapter.hookScript(frame, "OnShow", function()
      order[#order + 1] = "handler"
    end)
    frame:GetScript("OnShow")(frame)
    adapter.unhook(frame, "OnShow")
    record(
      "script-hook-order-and-restore",
      order[1] == "handler" and order[2] == "script" and frame:GetScript("OnShow") == original,
      "order: "
        .. table.concat(order, " ")
        .. ", script restored: "
        .. tostring(frame:GetScript("OnShow") == original),
      true
    )
  end

  record(
    "nothing-active-after-unhooks",
    adapter.activeCount() == 0,
    "hooks still active: " .. adapter.activeCount(),
    true
  )
  return results
end

---Build the workload for one side.
---@param side string `"moltencodes"` or `"ace3"`
---@param host table
---@param settings table
---@return table suite `{ cases, checks, libraries }`
function Hooks.Build(side, host, settings)
  local adapter, libraries
  if side == "moltencodes" then
    adapter, libraries = kitAdapter(host)
  else
    adapter, libraries = aceAdapter(host, settings.ace3)
  end
  adapter.side = side

  return {
    libraries = libraries,
    cases = cases(adapter, host),
    checks = function()
      return runChecks(adapter, host)
    end,
  }
end

return Hooks
