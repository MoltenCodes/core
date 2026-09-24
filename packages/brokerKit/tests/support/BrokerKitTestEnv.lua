--- Package-specific test environment for the BrokerKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's module load order and the host surface
--- only BrokerKit reads, which the shared fixture does not model:
---
---   `LibStub`            a minimal LibStub with `NewLibrary` and `GetLibrary`;
---   LibDataBroker-1.1    registered in that LibStub on request, with the
---                        library's own semantics (see `InstallLibDataBroker`):
---                        `NewDataObject`, `DataObjectIterator`,
---                        `GetDataObjectByName`, `pairs`,
---                        proxies whose `__newindex` compares and fires the four
---                        `LibDataBroker_AttributeChanged*` events, and a
---                        CallbackHandler-shaped `RegisterCallback`;
---   a fake display       `WatchLibDataBroker` records what a display addon
---                        registered on the library would see.
---
--- `Reset` removes `LibStub`, which is not among the globals the shared fixture
--- owns.
local FrameworkTestEnv = require("FrameworkTestEnv")

local BrokerKitTestEnv = FrameworkTestEnv.New({
    modules = { "Registry", "SignalKit", "BrokerKit" },
})

--- The LibStub major the stub registers, the one BrokerKit looks up.
local LIBDATABROKER_MAJOR = "LibDataBroker-1.1"

--- The host globals this environment installs and removes.
local OWNED_GLOBALS = { "LibStub" }

local sharedReset = BrokerKitTestEnv.Reset

---Write a host global. The stubs stand in for World of Warcraft client APIs
---and libraries that only exist in the global table.
---@param name string
---@param value any
local function setGlobal(name, value)
    -- selene: allow(global_usage)
    rawset(_G, name, value)
end

---Read a host global.
---@param name string
---@return any
local function getGlobal(name)
    -- selene: allow(global_usage)
    return rawget(_G, name)
end

---Make the host's `issecretvalue` report `secret` (compared with `rawequal`)
---as a secret value. The shared fixture owns and clears this global.
---@param secret any
function BrokerKitTestEnv.InstallSecretProbe(secret)
    setGlobal("issecretvalue", function(value)
        return rawequal(value, secret)
    end)
end

---Whether the installed secret probe, if any, reports `value` as secret.
---@param value any
---@return boolean
local function isSecret(value)
    local probe = getGlobal("issecretvalue")
    return type(probe) == "function" and probe(value) == true
end

---Install a minimal LibStub and return it.
---@return table LibStub
function BrokerKitTestEnv.InstallLibStub()
    local libraries = {}
    local minors = {}
    local libStub = {}

    function libStub.NewLibrary(_, major, minor)
        if minors[major] ~= nil and minors[major] >= minor then
            return nil
        end
        local oldMinor = minors[major]
        libraries[major] = libraries[major] or {}
        minors[major] = minor
        return libraries[major], oldMinor
    end

    function libStub.GetLibrary(_, major, silent)
        if libraries[major] == nil and not silent then
            error('LibStub stub: cannot find a library instance of "' .. tostring(major) .. '"', 2)
        end
        return libraries[major], minors[major]
    end

    setGlobal("LibStub", libStub)
    return libStub
end

---Options accepted by `InstallLibDataBroker`.
---@class BrokerKitTestEnv.LibDataBrokerOptions
---@field withoutCallbacks boolean? Build a library without `RegisterCallback`.
---@field isolateErrors boolean? Run each callback under `pcall` and collect what it raised in `reportedErrors`, as the real CallbackHandler does through `xpcall` and the client's error handler.
---@field objects table<string, table>? Data objects present, with their attributes, before BrokerKit sees the library.

---Install LibDataBroker-1.1 into LibStub (installing LibStub when needed) and
---return it.
---
---The code is this suite's own; the behaviour is LibDataBroker-1.1's, minor 4:
---
---* `NewDataObject(name, dataobj)` returns `nil` for a name already held;
---  otherwise moves the fields of `dataobj` into attribute storage, turns that
---  table (or a new one) into the proxy, fires
---  `LibDataBroker_DataObjectCreated(name, proxy)` and returns the proxy.
---* A proxy reads attributes through `__index`; a write through `__newindex`
---  that changes the value stores it and fires the four
---  `LibDataBroker_AttributeChanged*` events with `(name, key, value, proxy)`.
---  The real library compares the old and new value with `==`, which raises
---  for a secret value; this stub raises a named error instead, so a secret
---  BrokerKit let through is reported rather than hidden.
---* `DataObjectIterator()` is `pairs` over name to proxy; `GetDataObjectByName`
---  maps a name to its proxy; `pairs(dataobj)` iterates the attribute storage
---  and raises for an object never written to, as the real library does.
---* `RegisterCallback(owner, event, method)` has CallbackHandler-1.0's shape:
---  one registration per owner and event, refused for the library itself, and
---  `method(event, ...)` on `Fire`.
---
---Extra fields for the specs: `Fire(event, ...)`, `CallbackCount()`,
---`newDataObjectCalls`, `attributeWrites` and, with `isolateErrors`,
---`reportedErrors`.
---@param options BrokerKitTestEnv.LibDataBrokerOptions?
---@return table library
function BrokerKitTestEnv.InstallLibDataBroker(options)
    options = options or {}
    local libStub = getGlobal("LibStub") or BrokerKitTestEnv.InstallLibStub()
    local library = libStub:NewLibrary(LIBDATABROKER_MAJOR, 4)

    local attributeStorage = {}
    local nameStorage = {}
    local proxyStorage = {}
    local callbacks = {}
    local callbackOwners = {}
    library.newDataObjectCalls = 0
    library.attributeWrites = 0
    library.reportedErrors = {}

    ---Call every registered callback with `eventName, ...`, in registration
    ---order. With `isolateErrors`, a raising callback is reported and the
    ---remaining callbacks still run, as CallbackHandler-1.0 does.
    function library.Fire(eventName, ...)
        for index = 1, #callbacks do
            local entry = callbacks[index]
            if entry.eventName == eventName then
                if options.isolateErrors then
                    local ok, message = pcall(entry.method, eventName, ...)
                    if not ok then
                        library.reportedErrors[#library.reportedErrors + 1] = message
                    end
                else
                    entry.method(eventName, ...)
                end
            end
        end
    end

    local proxyMetatable = {
        __metatable = "access denied",
        __index = function(self, key)
            local attributes = attributeStorage[self]
            return attributes and attributes[key]
        end,
        __newindex = function(self, key, value)
            library.attributeWrites = library.attributeWrites + 1
            if not attributeStorage[self] then
                attributeStorage[self] = {}
            end
            local previous = attributeStorage[self][key]
            if isSecret(value) or isSecret(previous) then
                error("LibDataBroker stub: a secret value reached the attribute comparison", 2)
            end
            if previous == value then
                return
            end
            attributeStorage[self][key] = value
            local name = nameStorage[self]
            if not name then
                return
            end
            library.Fire("LibDataBroker_AttributeChanged", name, key, value, self)
            library.Fire("LibDataBroker_AttributeChanged_" .. name, name, key, value, self)
            library.Fire(
                "LibDataBroker_AttributeChanged_" .. name .. "_" .. key,
                name,
                key,
                value,
                self
            )
            library.Fire("LibDataBroker_AttributeChanged__" .. key, name, key, value, self)
        end,
    }

    function library.NewDataObject(_, name, dataObject)
        library.newDataObjectCalls = library.newDataObjectCalls + 1
        if proxyStorage[name] then
            return nil
        end
        if dataObject then
            if type(dataObject) ~= "table" then
                error("LibDataBroker stub: dataobj must be nil or a table", 2)
            end
            attributeStorage[dataObject] = {}
            for key, value in pairs(dataObject) do
                attributeStorage[dataObject][key] = value
                dataObject[key] = nil
            end
        end
        dataObject = setmetatable(dataObject or {}, proxyMetatable)
        proxyStorage[name] = dataObject
        nameStorage[dataObject] = name
        library.Fire("LibDataBroker_DataObjectCreated", name, dataObject)
        return dataObject
    end

    function library.DataObjectIterator()
        return pairs(proxyStorage)
    end

    function library.GetDataObjectByName(_, name)
        return proxyStorage[name]
    end

    function library.pairs(_, dataObjectOrName)
        local dataObject = proxyStorage[dataObjectOrName] or dataObjectOrName
        if attributeStorage[dataObject] == nil then
            error("LibDataBroker stub: data object not found", 2)
        end
        return next, attributeStorage[dataObject], nil
    end

    if not options.withoutCallbacks then
        function library.RegisterCallback(owner, eventName, method)
            if owner == library then
                error("RegisterCallback stub: do not register on the library itself", 2)
            end
            if type(method) ~= "function" then
                error("RegisterCallback stub: method must be a function", 2)
            end
            callbackOwners[owner] = callbackOwners[owner] or {}
            if callbackOwners[owner][eventName] ~= nil then
                callbackOwners[owner][eventName].method = method
                return
            end
            local entry = { eventName = eventName, method = method }
            callbackOwners[owner][eventName] = entry
            callbacks[#callbacks + 1] = entry
        end
    end

    ---How many callbacks are registered, for idempotence checks.
    ---@return integer
    function library.CallbackCount()
        return #callbacks
    end

    if options.objects ~= nil then
        for name, attributes in pairs(options.objects) do
            local copy = {}
            for key, value in pairs(attributes) do
                copy[key] = value
            end
            library:NewDataObject(name, copy)
        end
    end

    return library
end

---What a fake display addon saw through LibDataBroker's callbacks.
---@class BrokerKitTestEnv.DisplayLog
---@field created { name: string, dataObject: table }[] every `LibDataBroker_DataObjectCreated`
---@field changed { name: string, attribute: any, value: any, dataObject: table }[] every `LibDataBroker_AttributeChanged`

---Register a fake display addon on `library` and return the log it fills.
---@param library table a library from `InstallLibDataBroker`
---@return BrokerKitTestEnv.DisplayLog log
function BrokerKitTestEnv.WatchLibDataBroker(library)
    local log = { created = {}, changed = {} }
    local owner = {}
    library.RegisterCallback(owner, "LibDataBroker_DataObjectCreated", function(_, name, dataObject)
        log.created[#log.created + 1] = { name = name, dataObject = dataObject }
    end)
    library.RegisterCallback(
        owner,
        "LibDataBroker_AttributeChanged",
        function(_, name, attribute, value, dataObject)
            log.changed[#log.changed + 1] =
                { name = name, attribute = attribute, value = value, dataObject = dataObject }
        end
    )
    return log
end

---Clear everything the shared fixture clears, plus `LibStub`.
function BrokerKitTestEnv.Reset()
    sharedReset()
    for index = 1, #OWNED_GLOBALS do
        setGlobal(OWNED_GLOBALS[index], nil)
    end
end

---Measure the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
---@param workload fun()
---@return number kilobytes
function BrokerKitTestEnv.AllocatedKilobytes(workload)
    collectgarbage()
    collectgarbage("stop")
    local before = collectgarbage("count")
    workload()
    local after = collectgarbage("count")
    collectgarbage("restart")
    return after - before
end

---Load the BrokerKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client.
---@param revision integer
---@return table BrokerKit
function BrokerKitTestEnv.LoadRevision(revision)
    -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
    -- `require` does.
    local path = nil
    for template in package.path:gmatch("[^;]+") do
        local candidate = template:gsub("%?", "BrokerKit")
        local file = io.open(candidate, "r")
        if file ~= nil then
            file:close()
            path = candidate
            break
        end
    end
    if path == nil then
        error("BrokerKitTestEnv.LoadRevision could not find BrokerKit.lua on package.path", 2)
    end

    local file = assert(io.open(path, "r"))
    local text = file:read("*a")
    file:close()

    local patched, replacements = text:gsub(
        "local IMPLEMENTATION_REVISION = %d+",
        "local IMPLEMENTATION_REVISION = " .. revision
    )
    if replacements ~= 1 then
        error("BrokerKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
    end

    local chunk = assert(loadstring(patched, "@" .. path))
    return chunk()
end

return BrokerKitTestEnv
