--- The host interface of the benchmark workloads, implemented over the real client.
---
--- A workload talks to its host only through the interface `BenchHost.lua`
--- gives it on the host (`docs/BENCHMARKS.md`, "Adding a workload"). This
--- module gives the same interface inside World of Warcraft, so a shared
--- workload module runs unchanged:
---
---   RequireAll(modules)   Kits from the Registry the Kits side addon loaded
---                         (`MoltenCodes.Registries[2]`), each at the API its
---                         committed manifest declares; `"LibStub"` is the
---                         global the side addon loaded
---   LoadFiles(dir, files) nothing to load: the Ace3 side addon's `.toc`
---                         already loaded the pinned files, so this only checks
---                         that the side carries every file the workload names
---   Global(name)          the client global
---   EventHandler(event)   the frame the side's library registered for the
---                         event and its `OnEvent` script, found with
---                         `GetFramesRegisteredForEvent` among the frames that
---                         did not exist before the side loaded
---   TakeReportedErrors()  the errors the host error handler received while
---                         the harness ran the case (it installs `CaptureError`)
---   environment.Emit      delivers an event to those same side frames, as
---                         the client does
---
--- What only the fake client has — the simulated clock (`timers`), the
--- recording chat outbox (`chat`), the counting chat frame (`chatFrame`), the
--- frame tick (`Tick`) and the rest of `environment` — raises through
--- `ClientBench.Unsupported` when a case touches it, so that case is recorded
--- as not run in the client, with the reason.
---
--- `client` is the one addition, for client-only workloads: the side addon's
--- and the harness's names.

local ClientBench = require("ClientBench")

local ClientHost = {}

--- The Registry API generation the benchmark resolves Kits through.
local REGISTRY_API = 2

--- The most error messages one case keeps; a runaway loop must not fill the
--- saved variables.
local MAX_CAPTURED_ERRORS = 32

---What the harness knows about the loaded side, from the installer.
---@class ClientHost.Context
---@field side "moltencodes"|"ace3"
---@field sideAddon string the loaded side addon's folder name
---@field harnessAddon string the harness addon's folder name
---@field files string[] the Ace3 files the side addon loaded, relative to the Ace3 root
---@field packages { id: string, facade: string, api: integer }[] the Kits the side addon loaded
---@field baselineFrames table<table, boolean> every frame that existed before the side loaded

---Read a client global.
---@param name string
---@return any
local function readGlobal(name)
  -- The benchmark reads the World of Warcraft API, which exists only in the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---A table that raises `Unsupported` for every field except the ones given.
---@param description string what the table stands for, for the reason
---@param fields table? the fields the client can provide
---@return table
local function unsupportedTable(description, fields)
  return setmetatable(fields or {}, {
    __index = function(_, key)
      ClientBench.Unsupported(description .. " (" .. tostring(key) .. ")")
    end,
  })
end

---Build the client host for one loaded side.
---@param context ClientHost.Context
---@return table host
function ClientHost.New(context)
  local host = {}
  local captured = {}

  local fileSet = {}
  for index = 1, #context.files do
    fileSet[context.files[index]] = true
  end
  local packageByFacade = {}
  for index = 1, #context.packages do
    packageByFacade[context.packages[index].facade] = context.packages[index]
  end

  host.client = { sideAddon = context.sideAddon, harnessAddon = context.harnessAddon }

  function host.Global(name)
    return readGlobal(name)
  end

  ---The Registry the Kits side loaded, or an error naming the fix.
  ---@return table
  local function registry()
    local namespace = readGlobal("MoltenCodes")
    local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
    local found = type(generations) == "table" and rawget(generations, REGISTRY_API) or nil
    if type(found) ~= "table" then
      error("ClientHost: no Registry API " .. REGISTRY_API .. " is loaded; is the Kits side?", 0)
    end
    return found
  end

  function host.RequireAll(modules)
    local loaded = {}
    for index = 1, #modules do
      local name = modules[index]
      if name == "Registry" then
        loaded[index] = registry()
      elseif name == "LibStub" then
        if not fileSet["LibStub/LibStub.lua"] then
          error("ClientHost: the " .. context.sideAddon .. " addon carries no LibStub", 0)
        end
        loaded[index] = readGlobal("LibStub")
      else
        local package = packageByFacade[name]
        if package == nil then
          error("ClientHost: the " .. context.sideAddon .. " addon carries no " .. name, 0)
        end
        local kit = registry():Get(package.id, package.api)
        if kit == nil then
          error("ClientHost: the Registry has no " .. package.id .. " API " .. package.api, 0)
        end
        loaded[index] = kit
      end
    end
    return loaded
  end

  function host.LoadFiles(_, files)
    for index = 1, #files do
      if not fileSet[files[index]] then
        error("ClientHost: the " .. context.sideAddon .. " addon does not load " .. files[index], 0)
      end
    end
  end

  ---The frames created after the side loaded that are registered for
  ---`eventName` and have an `OnEvent` script.
  ---@param eventName string
  ---@return table[]
  local function sideFrames(eventName)
    local framesRegisteredFor = readGlobal("GetFramesRegisteredForEvent")
    if type(framesRegisteredFor) ~= "function" then
      ClientBench.Unsupported("GetFramesRegisteredForEvent, which this client lacks")
    end
    local found = {}
    local registered = { framesRegisteredFor(eventName) }
    for index = 1, #registered do
      local frame = registered[index]
      if not context.baselineFrames[frame] and not frame:IsForbidden() then
        if frame:GetScript("OnEvent") ~= nil then
          found[#found + 1] = frame
        end
      end
    end
    return found
  end

  function host.EventHandler(eventName)
    local frames = sideFrames(eventName)
    if #frames ~= 1 then
      error(
        "ClientHost: "
          .. #frames
          .. " frames created after the side loaded are registered for "
          .. eventName
          .. "; expected exactly the library's one",
        2
      )
    end
    return frames[1], frames[1]:GetScript("OnEvent")
  end

  ---Deliver an event to every side frame registered for it, as the client does.
  ---@param eventName string
  local function emit(eventName, ...)
    local frames = sideFrames(eventName)
    for index = 1, #frames do
      frames[index]:GetScript("OnEvent")(frames[index], eventName, ...)
    end
  end

  function host.Tick()
    ClientBench.Unsupported("the fake client's frame tick (host.Tick)")
  end

  ---The error handler the harness installs while a case runs.
  ---@param message any
  function host.CaptureError(message)
    if #captured < MAX_CAPTURED_ERRORS then
      captured[#captured + 1] = tostring(message)
    end
  end

  function host.TakeReportedErrors()
    local taken = {}
    for index = 1, #captured do
      taken[index] = { message = captured[index] }
      captured[index] = nil
    end
    return taken
  end

  host.environment = unsupportedTable("the fake client's environment", { Emit = emit })
  host.timers = unsupportedTable("the simulated clock")
  host.chat = unsupportedTable("the fake client's chat outbox")
  host.chatFrame = unsupportedTable("the fake client's counting chat frame")

  return host
end

return ClientHost
