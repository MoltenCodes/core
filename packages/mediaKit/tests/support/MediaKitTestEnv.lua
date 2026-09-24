--- Package-specific test environment for the MediaKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's module load order and the host surface
--- only MediaKit reads, which the shared fixture does not model:
---
---   `GetLocale`   the client locale, installed before MediaKit loads because
---                 the built-in fonts are chosen at load;
---   `LibStub`     a minimal LibStub with `NewLibrary` and `GetLibrary`;
---   LibSharedMedia-3.0, registered in that LibStub on request, with
---                 `Register`, `Fetch`, `HashTable`, the `LOCALE_BIT_*`
---                 fields and a CallbackHandler-shaped `RegisterCallback`
---                 whose registrations `Register` fires synchronously, as the
---                 real library does.
---
--- `Reset` removes `GetLocale` and `LibStub`, which are not among the globals
--- the shared fixture owns.
local FrameworkTestEnv = require("FrameworkTestEnv")

local MediaKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "SignalKit", "MediaKit" },
})

--- The client locale `NewPackage` installs unless a spec asks for another.
MediaKitTestEnv.DEFAULT_CLIENT_LOCALE = "enUS"

--- The host globals this environment installs and removes.
local OWNED_GLOBALS = { "GetLocale", "LibStub" }

local sharedReset = MediaKitTestEnv.Reset

---Write a host global. The stubs stand in for World of Warcraft client APIs
---and libraries that only exist in the global table.
---@param name string
---@param value any
local function setGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Make the host's `GetLocale()` return `locale`, or remove it with `nil`.
---@param locale string?
function MediaKitTestEnv.SetClientLocale(locale)
  if locale == nil then
    setGlobal("GetLocale", nil)
    return
  end
  setGlobal("GetLocale", function()
    return locale
  end)
end

---Make the host's `issecretvalue` report `secret` (compared with `rawequal`)
---as a secret value. The shared fixture owns and clears this global.
---@param secret any
function MediaKitTestEnv.InstallSecretProbe(secret)
  setGlobal("issecretvalue", function(value)
    return rawequal(value, secret)
  end)
end

---Install a minimal LibStub and return it.
---@return table LibStub
function MediaKitTestEnv.InstallLibStub()
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

---Options accepted by `InstallLibSharedMedia`.
---@class MediaKitTestEnv.LibSharedMediaOptions
---@field withoutCallbacks boolean? Build a library without `RegisterCallback`.
---@field media table<string, table<string, string|integer>>? Entries present before MediaKit sees the library.

---Install LibSharedMedia-3.0 into LibStub (installing LibStub when needed)
---and return it. Its extra field `langmasks[type][name]` records the
---`langmask` every `Register` received.
---@param options MediaKitTestEnv.LibSharedMediaOptions?
---@return table library
function MediaKitTestEnv.InstallLibSharedMedia(options)
  options = options or {}
  -- selene: allow(global_usage)
  local libStub = rawget(_G, "LibStub") or MediaKitTestEnv.InstallLibStub()
  local library = libStub:NewLibrary("LibSharedMedia-3.0", 8020003)

  local mediaTables = { background = {}, border = {}, font = {}, sound = {}, statusbar = {} }
  local callbacks = {}
  local callbackOwners = {}
  library.langmasks = { background = {}, border = {}, font = {}, sound = {}, statusbar = {} }
  library.registerCalls = 0

  library.LOCALE_BIT_koKR = 1
  library.LOCALE_BIT_ruRU = 2
  library.LOCALE_BIT_zhCN = 4
  library.LOCALE_BIT_zhTW = 8
  library.LOCALE_BIT_western = 128

  ---Call every registered callback with `eventName, ...`, in registration order.
  function library.Fire(eventName, ...)
    for index = 1, #callbacks do
      local entry = callbacks[index]
      if entry.eventName == eventName then
        entry.method(eventName, ...)
      end
    end
  end

  function library.Register(_, mediaType, key, data, langmask)
    library.registerCalls = library.registerCalls + 1
    mediaType = string.lower(mediaType)
    mediaTables[mediaType] = mediaTables[mediaType] or {}
    library.langmasks[mediaType] = library.langmasks[mediaType] or {}
    if mediaTables[mediaType][key] ~= nil then
      return false
    end
    mediaTables[mediaType][key] = data
    library.langmasks[mediaType][key] = langmask
    library.Fire("LibSharedMedia_Registered", mediaType, key)
    return true
  end

  function library.Fetch(_, mediaType, key)
    local media = mediaTables[mediaType]
    return media and media[key]
  end

  function library.HashTable(_, mediaType)
    return mediaTables[mediaType]
  end

  if not options.withoutCallbacks then
    -- CallbackHandler-1.0's shape: `target.RegisterCallback(self, event,
    -- method)`, one registration per owner and event, and a refusal when
    -- the owner is the library itself.
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

  if options.media ~= nil then
    for mediaType, entries in pairs(options.media) do
      for key, data in pairs(entries) do
        mediaTables[mediaType][key] = data
      end
    end
  end

  return library
end

---Clear everything the shared fixture clears, plus `GetLocale` and `LibStub`.
function MediaKitTestEnv.Reset()
  sharedReset()
  for index = 1, #OWNED_GLOBALS do
    setGlobal(OWNED_GLOBALS[index], nil)
  end
end

---Reset, install the host stubs and `GetLocale` returning `clientLocale`
---(default `enUS`), then load Registry, SignalKit and MediaKit.
---@param clientLocale string?
---@return table MediaKit
---@return table Registry
---@return table SignalKit
function MediaKitTestEnv.NewPackage(clientLocale)
  MediaKitTestEnv.Reset()
  MediaKitTestEnv.InstallWowApi()
  MediaKitTestEnv.SetClientLocale(clientLocale or MediaKitTestEnv.DEFAULT_CLIENT_LOCALE)
  local Registry = require("Registry")
  local SignalKit = require("SignalKit")
  local MediaKit = require("MediaKit")
  return MediaKit, Registry, SignalKit
end

---Measure the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
---@param workload fun()
---@return number kilobytes
function MediaKitTestEnv.AllocatedKilobytes(workload)
  collectgarbage()
  collectgarbage("stop")
  local before = collectgarbage("count")
  workload()
  local after = collectgarbage("count")
  collectgarbage("restart")
  return after - before
end

---Load the MediaKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client.
---@param revision integer
---@return table MediaKit
function MediaKitTestEnv.LoadRevision(revision)
  -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
  -- `require` does.
  local path = nil
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", "MediaKit")
    local file = io.open(candidate, "r")
    if file ~= nil then
      file:close()
      path = candidate
      break
    end
  end
  if path == nil then
    error("MediaKitTestEnv.LoadRevision could not find MediaKit.lua on package.path", 2)
  end

  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()

  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  if replacements ~= 1 then
    error("MediaKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
  end

  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

return MediaKitTestEnv
