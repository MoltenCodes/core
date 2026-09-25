--- Game-event dispatch: EventKit against AceEvent-3.0 (with CallbackHandler-1.0).
---
--- Both sides subscribe function listeners to one real event,
--- `UNIT_POWER_UPDATE`, and receive it with the payload `"player", "MANA"`.
--- Timing calls the `OnEvent` script of the frame the library registered, the
--- way the client does, so the measurement is the library's dispatch and not
--- the fake client's `Emit` walk. Both sides isolate listener errors through
--- the same `securecallfunction` stub, so neither skips work the other does.

local Dispatch = require("workloads.Dispatch")
local AceObjects = require("workloads.AceObjects")

local EventDispatch = {}

local EVENT = "UNIT_POWER_UPDATE"

---@param host table
---@return table adapter, table[] libraries
local function kitAdapter(host)
  local loaded = host.RequireAll({ "Registry", "SignalKit", "EventKit" })
  local SignalKit, EventKit = loaded[2], loaded[3]
  local adapter = {}

  function adapter.connect(callback)
    return EventKit:Connect(EVENT, callback)
  end

  function adapter.disconnect(connection)
    connection:Disconnect()
  end

  function adapter.fire(...)
    host.environment.Emit(EVENT, ...)
  end

  function adapter.hotFire()
    local frame, onEvent = host.EventHandler(EVENT)
    return function(...)
      onEvent(frame, EVENT, ...)
    end
  end

  return adapter,
    {
      { name = "EventKit", revision = EventKit.REVISION },
      { name = "SignalKit", revision = SignalKit.REVISION },
    }
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
    object:RegisterEvent(EVENT, callback)
    return object
  end

  function adapter.disconnect(object)
    object:UnregisterEvent(EVENT)
    pool.Give(object)
  end

  function adapter.fire(...)
    host.environment.Emit(EVENT, ...)
  end

  function adapter.hotFire()
    local frame, onEvent = host.EventHandler(EVENT)
    return function(...)
      onEvent(frame, EVENT, ...)
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
function EventDispatch.Build(side, host, settings)
  local adapter, libraries
  if side == "moltencodes" then
    adapter, libraries = kitAdapter(host)
  else
    adapter, libraries = aceAdapter(host, settings.ace3)
  end
  return {
    libraries = libraries,
    cases = Dispatch.Cases(adapter, EVENT .. " with 2 payload values"),
    checks = function()
      return Dispatch.Checks(adapter, host, side == "moltencodes")
    end,
  }
end

return EventDispatch
