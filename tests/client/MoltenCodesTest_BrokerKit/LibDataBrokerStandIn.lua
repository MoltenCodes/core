-- MoltenCodes Test: LibDataBrokerStandIn.lua
--
-- A minimal LibStub and a minimal LibDataBroker-1.1 for the BrokerKit bridge
-- tests, written for this addon from the libraries' documented contracts. No
-- code of LibStub, LibDataBroker-1.1 or CallbackHandler-1.0 is copied or
-- vendored here: only the behaviour BrokerKit relies on (packages/brokerKit/
-- docs/API.md, "LibDataBroker-1.1") is reproduced, the same behaviour the
-- Busted fixture packages/brokerKit/tests/support/BrokerKitTestEnv.lua models.
--
-- Why a stand-in and not the real library. The test addon ships nothing
-- third-party, and a real LibDataBroker-1.1 would make every test object
-- visible in the player's display addons for the rest of the session. The
-- suite therefore installs the stand-in's LibStub as the global `LibStub` only
-- for the length of one test, and only when the client has no `LibStub` of its
-- own; the After hook of the suite removes it again. When a real LibStub is
-- loaded, the bridge tests are skipped and the real library is only logged.
--
-- What the stand-in reproduces:
--
--   * LibStub: `GetLibrary(major, silent)` answers the one library it holds,
--     `nil` for any other major when `silent`, and raises otherwise. A LibStub
--     made without a library answers "LibDataBroker-1.1" with `nil`, which is
--     how a client with LibStub but no LibDataBroker looks to BrokerKit.
--   * LibDataBroker-1.1: `NewDataObject(name, dataobj)` returns `nil` for a
--     name already held; otherwise it moves the fields of `dataobj` into its own
--     storage, turns that table (or a new one) into the data object, fires
--     `LibDataBroker_DataObjectCreated(name, dataobj)` synchronously and
--     returns it. A data object reads through `__index` and writes through
--     `__newindex`, which stores a changed value and fires
--     `LibDataBroker_AttributeChanged(name, attribute, value, dataobj)`.
--     `DataObjectIterator`, `GetDataObjectByName`, `GetNameByDataObject` and
--     `pairs(dataobj)` (which raises for a data object nobody has written to,
--     as the real library's assertion does) complete the surface.
--   * CallbackHandler-1.0's registration shape: `RegisterCallback(owner,
--     event, method)` with one registration per owner and event (a second one
--     replaces the first), refused for the library itself as the owner, and
--     `UnregisterCallback(owner, event)`; a method is called as
--     `method(event, ...)`.
--
-- Where the stand-in differs, on purpose:
--
--   * Callbacks run directly, in registration order, and an error propagates
--     to the writer. The real CallbackHandler runs each one isolated and hands
--     an error to the client's error handler, so a raising test listener would
--     open an error window; nothing in the suite raises inside a callback.
--   * The per-name and per-attribute events
--     (`LibDataBroker_AttributeChanged_<name>`, `..._<name>_<attribute>`,
--     `..._<attribute>`) are built and fired only while somebody registered
--     one. The real library always builds the strings; nobody in the suite
--     listens to them, and skipping them keeps the allocation tests measuring
--     BrokerKit rather than the stand-in.
--   * The real `__newindex` compares the old and the new value with `==`,
--     which raises for two secrets of one type. The stand-in never compares a
--     secret; it counts every secret that reaches a data object instead, so a
--     test can prove BrokerKit never mirrored one.
--
-- Lifetime. There is one stand-in library per session, created on first use,
-- because BrokerKit's bridge is one-way: once exposed into or adopted from a
-- library, BrokerKit keeps it for the session (docs/API.md, "LibDataBroker-1.1";
-- there is no un-exposing). Reusing the one library keeps a second run in the
-- same session consistent with the first. Only the global `LibStub` is
-- installed and removed per test.

local _, addonTable = ...

--- The LibStub major of LibDataBroker, the one BrokerKit asks for.
local LIBDATABROKER_MAJOR = "LibDataBroker-1.1"

--- The minor version the stand-in reports. The real library's latest is 4.
local LIBDATABROKER_MINOR = 4

--- The two events BrokerKit registers for, and the prefix of the specific ones.
local CREATED_EVENT = "LibDataBroker_DataObjectCreated"
local CHANGED_EVENT = "LibDataBroker_AttributeChanged"
local SPECIFIC_CHANGED_PREFIX = "LibDataBroker_AttributeChanged_"

---@class MoltenCodesTest.BrokerKit.StandInCounters
---@field newDataObjectCalls integer every `NewDataObject` call, successful or not
---@field changedWrites integer data-object writes that changed a value (each fires the events)
---@field createdFired integer `LibDataBroker_DataObjectCreated` events fired
---@field changedFired integer `LibDataBroker_AttributeChanged` events fired
---@field secretsReceived integer secret values written into a data object

---@class MoltenCodesTest.BrokerKit.StandIn
---@field counters MoltenCodesTest.BrokerKit.StandInCounters
local StandIn = {}

--- The session's one stand-in library, created on first use.
---@type table|nil
local sessionLibrary = nil

--- The session's counters; tests read them before and after an action.
---@type MoltenCodesTest.BrokerKit.StandInCounters
local counters = {
  newDataObjectCalls = 0,
  changedWrites = 0,
  createdFired = 0,
  changedFired = 0,
  secretsReceived = 0,
}
StandIn.counters = counters

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- `issecretvalue` is a World of Warcraft client global, reachable only
  -- through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Whether `value` is a secret. `false` on a client without `issecretvalue`.
---@param value any
---@return boolean
local function isSecret(value)
  local probe = readHost("issecretvalue")
  return type(probe) == "function" and probe(value) == true
end

---Build the session library.
---@return table library
local function createLibrary()
  local library = {}

  --- Data object to its attribute storage.
  ---@type table<table, table>
  local attributeStorage = {}
  --- Data object to its name, and name to data object.
  ---@type table<table, string>
  local nameStorage = {}
  ---@type table<string, table>
  local proxyStorage = {}

  --- Registrations in order: `{ owner = ..., eventName = ..., method = ... }`.
  ---@type { owner: any, eventName: string, method: function }[]
  local registrations = {}
  --- How many registrations name a specific `..._AttributeChanged_...` event.
  local specificRegistrations = 0

  ---Call every method registered for `eventName` with `eventName, ...`.
  ---@param eventName string
  ---@param ... any
  local function fire(eventName, ...)
    for index = 1, #registrations do
      local registration = registrations[index]
      if registration.eventName == eventName then
        registration.method(eventName, ...)
      end
    end
  end

  local dataObjectMetatable = {
    __metatable = "access denied",
    __index = function(dataObject, key)
      local attributes = attributeStorage[dataObject]
      if type(attributes) == "nil" then
        return nil
      end
      return attributes[key]
    end,
    __newindex = function(dataObject, key, value)
      local attributes = attributeStorage[dataObject]
      if type(attributes) == "nil" then
        attributes = {}
        attributeStorage[dataObject] = attributes
      end
      local previous = attributes[key]
      local secret = isSecret(value)
      if secret then
        counters.secretsReceived = counters.secretsReceived + 1
      end
      if not secret and not isSecret(previous) and previous == value then
        return
      end
      attributes[key] = value
      counters.changedWrites = counters.changedWrites + 1
      local name = nameStorage[dataObject]
      counters.changedFired = counters.changedFired + 1
      fire(CHANGED_EVENT, name, key, value, dataObject)
      if specificRegistrations > 0 then
        fire(SPECIFIC_CHANGED_PREFIX .. name, name, key, value, dataObject)
        fire(SPECIFIC_CHANGED_PREFIX .. name .. "_" .. key, name, key, value, dataObject)
        fire(SPECIFIC_CHANGED_PREFIX .. "_" .. key, name, key, value, dataObject)
      end
    end,
  }

  ---Create the data object `name`, or answer `nil` for a name already held.
  ---@param name string
  ---@param dataObject table|nil
  ---@return table|nil
  function library.NewDataObject(_, name, dataObject)
    counters.newDataObjectCalls = counters.newDataObjectCalls + 1
    if type(proxyStorage[name]) ~= "nil" then
      return nil
    end
    if type(dataObject) ~= "nil" then
      if type(dataObject) ~= "table" then
        error("LibDataBroker stand-in: dataobj must be nil or a table", 2)
      end
      local attributes = {}
      for key, value in next, dataObject do
        attributes[key] = value
      end
      for key in next, attributes do
        dataObject[key] = nil
      end
      attributeStorage[dataObject] = attributes
    end
    local created = setmetatable(dataObject or {}, dataObjectMetatable)
    proxyStorage[name] = created
    nameStorage[created] = name
    counters.createdFired = counters.createdFired + 1
    fire(CREATED_EVENT, name, created)
    return created
  end

  ---Iterate `name, dataobj` over every data object, in hash order.
  ---@return function, table, nil
  function library.DataObjectIterator()
    return next, proxyStorage, nil
  end

  ---The data object named `name`, or `nil`.
  ---@param name string
  ---@return table|nil
  function library.GetDataObjectByName(_, name)
    return proxyStorage[name]
  end

  ---The name of `dataObject`, or `nil`.
  ---@param dataObject table
  ---@return string|nil
  function library.GetNameByDataObject(_, dataObject)
    return nameStorage[dataObject]
  end

  ---Iterate the attributes of a data object or of the data object named so.
  ---Raises for a data object nobody has written to, as the real library does.
  ---@param dataObjectOrName table|string
  ---@return function, table, nil
  function library.pairs(_, dataObjectOrName)
    local dataObject = dataObjectOrName
    if type(dataObjectOrName) == "string" then
      dataObject = proxyStorage[dataObjectOrName]
    end
    local attributes = attributeStorage[dataObject]
    if type(attributes) == "nil" then
      error("LibDataBroker stand-in: data object not found", 2)
    end
    return next, attributes, nil
  end

  ---Register `method` for `eventName` under `owner`; a second registration of
  ---the same owner and event replaces the first.
  ---@param owner any
  ---@param eventName string
  ---@param method function
  function library.RegisterCallback(owner, eventName, method)
    if rawequal(owner, library) then
      error("LibDataBroker stand-in: do not register callbacks on the library itself", 2)
    end
    if type(eventName) ~= "string" or type(method) ~= "function" then
      error("LibDataBroker stand-in: RegisterCallback(owner, eventName, method)", 2)
    end
    for index = 1, #registrations do
      local registration = registrations[index]
      if rawequal(registration.owner, owner) and registration.eventName == eventName then
        registration.method = method
        return
      end
    end
    registrations[#registrations + 1] = { owner = owner, eventName = eventName, method = method }
    if eventName:sub(1, #SPECIFIC_CHANGED_PREFIX) == SPECIFIC_CHANGED_PREFIX then
      specificRegistrations = specificRegistrations + 1
    end
  end

  ---Remove the registration of `owner` for `eventName`, if any.
  ---@param owner any
  ---@param eventName string
  function library.UnregisterCallback(owner, eventName)
    for index = #registrations, 1, -1 do
      local registration = registrations[index]
      if rawequal(registration.owner, owner) and registration.eventName == eventName then
        table.remove(registrations, index)
        if eventName:sub(1, #SPECIFIC_CHANGED_PREFIX) == SPECIFIC_CHANGED_PREFIX then
          specificRegistrations = specificRegistrations - 1
        end
      end
    end
  end

  return library
end

---The session's stand-in LibDataBroker-1.1, created on first use.
---@return table library
function StandIn.GetLibrary()
  if type(sessionLibrary) == "nil" then
    sessionLibrary = createLibrary()
  end
  return sessionLibrary
end

---A new LibStub-shaped table. With `withLibrary`, it holds the session's
---LibDataBroker-1.1 stand-in; without, it holds no library at all.
---@param withLibrary boolean
---@return table libStub
function StandIn.NewLibStub(withLibrary)
  local libStub = { minors = {} }
  local library = nil
  if withLibrary then
    library = StandIn.GetLibrary()
    libStub.minors[LIBDATABROKER_MAJOR] = LIBDATABROKER_MINOR
  end

  ---The library registered as `major`, and its minor version.
  ---@param major string
  ---@param silent boolean|nil
  ---@return table|nil library
  ---@return integer|nil minor
  function libStub.GetLibrary(_, major, silent)
    if major == LIBDATABROKER_MAJOR and type(library) ~= "nil" then
      return library, LIBDATABROKER_MINOR
    end
    if not silent then
      error('LibStub stand-in: cannot find a library instance of "' .. tostring(major) .. '"', 2)
    end
    return nil
  end

  return libStub
end

--- The major name, for the suite's log lines.
StandIn.LIBDATABROKER_MAJOR = LIBDATABROKER_MAJOR

addonTable.LibDataBrokerStandIn = StandIn
