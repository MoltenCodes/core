--- The one host environment both benchmark sides run in.
---
--- Both sides are built on the repository's shared fake client
--- (`tests/support/FrameworkTestEnv.lua`), so a Kit and an Ace3 library see
--- the same `CreateFrame`, frames and error handler. On top of it this module
--- installs, for **both sides alike and whether or not a side uses them**, the
--- few host calls the fake client does not provide:
---
---   clock and timers   `GetTime`, `GetTimePreciseSec`, `C_Timer.After`,
---                      `NewTimer`, `NewTicker` (`SimulatedTimers.lua`)
---   isolation          `securecallfunction`: the fake client's own stub
---                      (`pcall`, errors to the host error handler); Ace3's
---                      CallbackHandler requires it and every Kit that isolates
---                      listeners prefers it, so both take the same path
---   identity           `UnitName`, `UnitNameUnmodified`, `GetRealmName`,
---                      `UnitClass`, `UnitRace`, `UnitFactionGroup`,
---                      `GetLocale`, `GetCurrentRegion`,
---                      `GetCurrentRegionName`, `GetBuildInfo` (a Retail 12.1
---                      build, the numbers the fake client's `mainline`
---                      profile uses)
---   chat               `C_ChatInfo` (register, query, send, send logged),
---                      `Enum.SendAddonMessageResult`,
---                      `Enum.RegisterAddonMessagePrefixResult`, an outbox that
---                      records every sent message, `GetFramerate` (60),
---                      `UnitInParty`, `UnitInRaid`, `Ambiguate`
---   helpers            `hooksecurefunc`, `wipe` / `table.wipe`, `strlenutf8`
---   frames             `Frame:UnregisterAllEvents`, added to every frame
---   language           `xpcall(f, handler, ...)` forwarding its extra
---                      arguments, as the client's Lua does
---
--- No fake-client profile is selected, so there is no `issecretvalue` and no
--- `C_EventUtils`: the Kits take their path for a client without secret values,
--- which the host can price, instead of calling a Lua stand-in for a native
--- check on every value. `docs/BENCHMARKS.md` lists every stub and why none of
--- them favours either side.

local FrameworkTestEnv = require("FrameworkTestEnv")
local SimulatedTimers = require("SimulatedTimers")

local BenchHost = {}

--- The player every identity call describes, and the sender of received
--- addon messages.
BenchHost.PLAYER = { name = "Tester", realm = "Silvermoon", class = "MAGE", race = "Human" }
BenchHost.SENDER = "Friend-Silvermoon"

--- `Enum.SendAddonMessageResult` and `Enum.RegisterAddonMessagePrefixResult`
--- with the 12.x values.
local SEND_RESULT = {
  Success = 0,
  InvalidPrefix = 1,
  InvalidMessage = 2,
  AddonMessageThrottle = 3,
  InvalidChatType = 4,
  NotInGroup = 5,
  TargetRequired = 6,
  InvalidChannel = 7,
  ChannelThrottle = 8,
  GeneralError = 9,
}
local REGISTER_RESULT = { Success = 0, DuplicatePrefix = 1, InvalidPrefix = 2, MaxPrefixes = 3 }

---Write a host global.
---@param name string
---@param value any
local function setGlobal(name, value)
  -- The benchmark stands in for the World of Warcraft client, whose API only exists in the global table.
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Install the player identity calls.
local function installIdentity()
  local player = BenchHost.PLAYER
  setGlobal("UnitName", function()
    return player.name
  end)
  setGlobal("UnitNameUnmodified", function()
    return player.name
  end)
  setGlobal("GetRealmName", function()
    return player.realm
  end)
  setGlobal("UnitClass", function()
    return "Mage", player.class, 8
  end)
  setGlobal("UnitRace", function()
    return player.race, player.race, 1
  end)
  setGlobal("UnitFactionGroup", function()
    return "Alliance", "Alliance"
  end)
  setGlobal("GetLocale", function()
    return "enUS"
  end)
  setGlobal("GetCurrentRegion", function()
    return 3
  end)
  setGlobal("GetCurrentRegionName", function()
    return "EU"
  end)
  setGlobal("GetBuildInfo", function()
    return "12.1.0", "64123", "Sep 23 2026", 120100
  end)
end

---Build the chat stub and install it.
---
---The outbox is three parallel arrays so that recording a send allocates no
---table; `TakeOutbox` hands the recorded messages over and empties it.
---@return table chat
local function installChat()
  local chat = { count = 0, prefixes = {}, texts = {}, distributions = {}, registered = {} }

  local function send(prefix, text, distribution)
    local count = chat.count + 1
    chat.count = count
    chat.prefixes[count] = prefix
    chat.texts[count] = text
    chat.distributions[count] = distribution
    return SEND_RESULT.Success
  end

  setGlobal("C_ChatInfo", {
    RegisterAddonMessagePrefix = function(prefix)
      chat.registered[prefix] = true
      return REGISTER_RESULT.Success
    end,
    IsAddonMessagePrefixRegistered = function(prefix)
      return chat.registered[prefix] == true
    end,
    SendAddonMessage = send,
    SendAddonMessageLogged = send,
    SendChatMessage = function() end,
  })
  setGlobal("Enum", {
    SendAddonMessageResult = SEND_RESULT,
    RegisterAddonMessagePrefixResult = REGISTER_RESULT,
  })
  setGlobal("GetFramerate", function()
    return 60
  end)
  setGlobal("UnitInParty", function()
    return true
  end)
  setGlobal("UnitInRaid", function()
    return 1
  end)
  setGlobal("Ambiguate", function(name)
    return name
  end)

  ---Forget every recorded message, keeping the arrays' capacity.
  function chat.Clear()
    for index = 1, chat.count do
      chat.prefixes[index], chat.texts[index], chat.distributions[index] = nil, nil, nil
    end
    chat.count = 0
  end

  return chat
end

---Install the small helpers some Ace3 files expect from the client.
local function installHelpers()
  ---The client's `hooksecurefunc`: replace the field with a wrapper that calls
  ---the original and then the hook, returning the original's results.
  setGlobal("hooksecurefunc", function(first, second, third)
    local target, name, hook = first, second, third
    if type(first) == "string" then
      -- A string first argument names a global function, as in the client.
      -- selene: allow(global_usage)
      target, name, hook = _G, first, second
    end
    local original = target[name]
    rawset(target, name, function(...)
      local resultOne, resultTwo = original(...)
      hook(...)
      return resultOne, resultTwo
    end)
  end)

  local function wipe(value)
    for key in pairs(value) do
      value[key] = nil
    end
    return value
  end
  setGlobal("wipe", wipe)
  if rawget(table, "wipe") == nil then
    rawset(table, "wipe", wipe)
  end
  setGlobal("strlenutf8", function(text)
    return #text
  end)
end

---Replace `xpcall` with one that forwards extra arguments, as the client's does.
---
---The client's Lua 5.1 accepts `xpcall(f, handler, ...)` and passes `...` to
---`f`; stock Lua 5.1 drops them. ChatThrottleLib relies on the client form for
---every send. Arguments are staged in upvalues and read back by one reusable
---trampoline, so a call with up to six arguments allocates nothing; the
---trampoline copies them into locals before it calls `f`, so a nested `xpcall`
---cannot overwrite them. A call without extra arguments goes straight to the
---stock function, so code written for stock Lua 5.1 (the Kits) runs exactly as
---before.
local function installClientXpcall()
  local stockXpcall = xpcall
  local stagedFunction, stagedCount = nil, 0
  local first, second, third, fourth, fifth, sixth

  local function trampoline()
    local callback, count = stagedFunction, stagedCount
    local a, b, c, d, e, f = first, second, third, fourth, fifth, sixth
    stagedFunction, first, second, third, fourth, fifth, sixth = nil, nil, nil, nil, nil, nil, nil
    if count == 1 then
      return callback(a)
    elseif count == 2 then
      return callback(a, b)
    elseif count == 3 then
      return callback(a, b, c)
    elseif count == 4 then
      return callback(a, b, c, d)
    elseif count == 5 then
      return callback(a, b, c, d, e)
    end
    return callback(a, b, c, d, e, f)
  end

  setGlobal("xpcall", function(callback, handler, ...)
    local count = select("#", ...)
    if count == 0 then
      return stockXpcall(callback, handler)
    end
    if count > 6 then
      local arguments = { ... }
      return stockXpcall(function()
        return callback(unpack(arguments, 1, count))
      end, handler)
    end
    stagedFunction, stagedCount = callback, count
    first, second, third, fourth, fifth, sixth = ...
    return stockXpcall(trampoline, handler)
  end)
end

---Give every frame `UnregisterAllEvents`, which the fake client's frames lack
---and AceComm-3.0 calls on its frame at load.
local function installUnregisterAllEvents()
  -- The fake client publishes CreateFrame only as a global, as the client does.
  -- selene: allow(global_usage)
  local createFrame = rawget(_G, "CreateFrame")
  setGlobal("CreateFrame", function(...)
    local frame = createFrame(...)
    function frame:UnregisterAllEvents()
      for eventName in pairs(self.registrations) do
        self:UnregisterEvent(eventName)
      end
    end
    return frame
  end)
end

---Build the host: the fake client, then everything this module adds.
---@return table host
function BenchHost.New()
  local environment = FrameworkTestEnv.New({})
  environment.Reset()
  environment.InstallWowApi()
  environment.InstallSecureCallFunction()

  local host = { environment = environment }
  host.timers = SimulatedTimers.New()
  host.timers.Install()
  installIdentity()
  host.chat = installChat()
  installHelpers()
  installUnregisterAllEvents()
  installClientXpcall()

  ---Read a host global, such as `LibStub` after an Ace3 file created it.
  ---@param name string
  ---@return any
  function host.Global(name)
    -- Ace3 publishes LibStub and ChatThrottleLib only as globals, and the client API lives there too.
    -- selene: allow(global_usage)
    return rawget(_G, name)
  end

  ---Load Kits with `require`, in load order, and return them in that order.
  ---@param modules string[]
  ---@return table[]
  function host.RequireAll(modules)
    local loaded = {}
    for index = 1, #modules do
      loaded[index] = require(modules[index])
    end
    return loaded
  end

  ---Load Lua files the way the client loads an addon's files, in order.
  ---@param directory string
  ---@param files string[] paths relative to `directory`
  function host.LoadFiles(directory, files)
    for index = 1, #files do
      local path = directory .. "/" .. files[index]
      local chunk, problem = loadfile(path)
      if chunk == nil then
        error("BenchHost could not load " .. path .. ": " .. tostring(problem), 0)
      end
      chunk()
    end
  end

  ---The frame registered for `eventName` and its `OnEvent` script.
  ---
  ---Workloads call the script directly rather than through the fake client's
  ---`Emit`, which walks every frame: the measurement is then the library's
  ---dispatch and nothing of the stub's.
  ---@param eventName string
  ---@return table frame
  ---@return function onEvent
  function host.EventHandler(eventName)
    local frames = environment.Frames()
    for index = 1, #frames do
      local frame = frames[index]
      if frame.registrations[eventName] ~= nil and frame.scripts.OnEvent ~= nil then
        return frame, frame.scripts.OnEvent
      end
    end
    error("BenchHost: no frame is registered for " .. eventName, 2)
  end

  ---Run every frame's `OnUpdate` once, as one client frame would.
  ---@param elapsed number? seconds since the previous frame
  function host.Tick(elapsed)
    environment.Tick(elapsed or 0.016)
  end

  ---Errors the host error handler received, emptied on each call.
  ---@return table[]
  function host.TakeReportedErrors()
    return environment.TakeReportedErrors()
  end

  return host
end

return BenchHost
