--- Addon-message dispatch: a SignalKit bus against AceEvent-3.0 messages.
---
--- The comparable pair is a *shared, named* channel that any addon can
--- subscribe to without a reference to the publisher, with listener errors
--- isolated: `SignalKit:Bus(name):Subscribe` / `bus:Publish` against
--- `RegisterMessage` / `SendMessage` (CallbackHandler-1.0 underneath). A raw
--- SignalKit signal is **not** compared: it does not isolate listener errors,
--- so it does less work than CallbackHandler and the numbers would flatter it.
---
--- The bus is opened with `openTopics = true`, because AceEvent messages have
--- no topic declaration either; a declared topic with a validator would add
--- work AceEvent has no counterpart for.

local Dispatch = require("workloads.Dispatch")
local AceObjects = require("workloads.AceObjects")

local MessageDispatch = {}

local TOPIC = "BENCH_PROFILE_CHANGED"

---@param host table
---@return table adapter, table[] libraries
local function kitAdapter(host)
  local loaded = host.RequireAll({ "Registry", "SignalKit" })
  local SignalKit = loaded[2]
  local bus = SignalKit:Bus("BenchBus", { openTopics = true })
  local adapter = {}

  function adapter.connect(callback)
    return bus:Subscribe(TOPIC, callback)
  end

  function adapter.disconnect(connection)
    connection:Disconnect()
  end

  function adapter.fire(...)
    bus:Publish(TOPIC, ...)
  end

  function adapter.hotFire()
    return function(...)
      bus:Publish(TOPIC, ...)
    end
  end

  return adapter, { { name = "SignalKit", revision = SignalKit.REVISION } }
end

---@param host table
---@param directory string the Ace3 checkout
---@return table adapter, table[] libraries
local function aceAdapter(host, directory)
  host.LoadFiles(directory, {
    "LibStub/LibStub.lua",
    "CallbackHandler-1.0/CallbackHandler-1.0.lua",
    "AceEvent-3.0/AceEvent-3.0.lua",
  })
  local LibStub = host.Global("LibStub")
  local AceEvent, aceEventMinor = LibStub:GetLibrary("AceEvent-3.0")
  local _, callbackHandlerMinor = LibStub:GetLibrary("CallbackHandler-1.0")
  local pool = AceObjects.NewPool(AceEvent, 256)
  local adapter = {}

  function adapter.connect(callback)
    local object = pool.Take()
    object:RegisterMessage(TOPIC, callback)
    return object
  end

  function adapter.disconnect(object)
    object:UnregisterMessage(TOPIC)
    pool.Give(object)
  end

  function adapter.fire(...)
    AceEvent:SendMessage(TOPIC, ...)
  end

  function adapter.hotFire()
    return function(...)
      AceEvent:SendMessage(TOPIC, ...)
    end
  end

  return adapter,
    {
      { name = "AceEvent-3.0", minor = aceEventMinor },
      { name = "CallbackHandler-1.0", minor = callbackHandlerMinor },
    }
end

---Build the workload for one side.
---@param side string `"moltencodes"` or `"ace3"`
---@param host table
---@param settings table
---@return table suite `{ cases, checks, libraries }`
function MessageDispatch.Build(side, host, settings)
  local adapter, libraries
  if side == "moltencodes" then
    adapter, libraries = kitAdapter(host)
  else
    adapter, libraries = aceAdapter(host, settings.ace3)
  end
  return {
    libraries = libraries,
    cases = Dispatch.Cases(adapter, "one message with 2 values"),
    checks = function()
      return Dispatch.Checks(adapter, host, side == "moltencodes")
    end,
  }
end

return MessageDispatch
