--- Package-specific test environments for the InteropKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is InteropKit's own:
---
---   the module chain            Registry, then InteropKit;
---   a LibStub stub              `InstallLibStub` publishes a global `LibStub`
---                               with LibStub's semantics (see `NewLibStub`),
---                               and `Reset` removes it again, because it is
---                               not among the globals the shared fixture owns;
---   the upgrade loader          `LoadSourceAtRevision` loads the source again
---                               with its revision patched, as a newer embedded
---                               copy would load over an older one;
---   a second environment        `InteropKitTestEnv.Kits` loads SignalKit and
---                               EventKit on top of the chain, so `ExposeAll`
---                               and the in-place upgrade specs run against
---                               real Kits.
---
--- SignalKit and EventKit are neither dependencies nor optional dependencies of
--- InteropKit, so the runner does not put their sources on `LUA_PATH`. The
--- second environment therefore loads them with `loadfile` from their
--- repository paths, the way a `.toc` loads a file, rather than adding source
--- directories to `package.path` by hand.
local FrameworkTestEnv = require("FrameworkTestEnv")

local InteropKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "InteropKit" },
})

--- A second environment over the same module chain, for the specs that need
--- real Kits registered beside InteropKit.
local KitsTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "InteropKit" },
})
InteropKitTestEnv.Kits = KitsTestEnv

--- Paths of the sources this suite loads by file, relative to the repository
--- root the runner starts Busted from.
InteropKitTestEnv.SOURCE_PATH = "packages/interopKit/src/InteropKit.lua"
local KIT_SOURCE_PATHS = {
  SignalKit = "packages/signalKit/src/SignalKit.lua",
  EventKit = "packages/eventKit/src/EventKit.lua",
}

---Write a global. LibStub, like the client API, only exists in the global table.
---@param name string
---@param value any
local function setGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Build a LibStub stand-in with the semantics of every released LibStub.
---
---The code is this suite's own; the behaviour is LibStub's:
---
---* `libs[major]` holds the library table and `minors[major]` its minor.
---* `NewLibrary(major, minor)` raises for a non-string major, reads the first
---  run of digits of `minor` (so `"$Revision: 42 $"` is minor 42) and raises
---  when there is none; returns `nil` when the recorded minor is equal or
---  newer; otherwise records the minor, creates the table on first use and
---  returns it with the previous minor.
---* `GetLibrary(major, silent)` returns the table and its minor, raising at
---  the caller for an unknown major unless `silent`.
---* `IterateLibraries()` is `pairs(libs)`.
---* Calling the stub itself is `GetLibrary`.
---@return table libStub
function InteropKitTestEnv.NewLibStub()
  local libStub = { libs = {}, minors = {}, minor = 2 }

  function libStub.NewLibrary(self, major, minor)
    if type(major) ~= "string" then
      error("Bad argument #2 to `NewLibrary' (string expected)", 2)
    end
    local digits = string.match(tostring(minor), "%d+")
    local number = digits and tonumber(digits) or nil
    if number == nil then
      error("Minor version must either be a number or contain a number.", 2)
    end

    local oldMinor = self.minors[major]
    if oldMinor ~= nil and oldMinor >= number then
      return nil
    end
    self.minors[major] = number
    self.libs[major] = self.libs[major] or {}
    return self.libs[major], oldMinor
  end

  function libStub.GetLibrary(self, major, silent)
    local library = self.libs[major]
    if library == nil and not silent then
      error(string.format("Cannot find a library instance of %q.", tostring(major)), 2)
    end
    return library, self.minors[major]
  end

  function libStub.IterateLibraries(self)
    return pairs(self.libs)
  end

  return setmetatable(libStub, {
    __call = function(self, major, silent)
      return self:GetLibrary(major, silent)
    end,
  })
end

---Publish a LibStub stand-in as the global `LibStub` and return it.
---@param libStub table? a stub to install; defaults to a fresh `NewLibStub()`
---@return table libStub
function InteropKitTestEnv.InstallLibStub(libStub)
  libStub = libStub or InteropKitTestEnv.NewLibStub()
  setGlobal("LibStub", libStub)
  return libStub
end

---Remove the global `LibStub`.
function InteropKitTestEnv.RemoveLibStub()
  setGlobal("LibStub", nil)
end

---Install `isSecret` as the host's `issecretvalue`; the shared fixture owns
---and clears that global on `Reset`.
---@param isSecret fun(value: any): boolean
function InteropKitTestEnv.InstallSecretProbe(isSecret)
  setGlobal("issecretvalue", isSecret)
end

---Wrap an environment's `Reset` so it also removes the LibStub stand-in.
---@param environment table
local function extendReset(environment)
  local sharedReset = environment.Reset
  function environment.Reset()
    sharedReset()
    InteropKitTestEnv.RemoveLibStub()
  end
end
extendReset(InteropKitTestEnv)
extendReset(KitsTestEnv)
KitsTestEnv.InstallLibStub = InteropKitTestEnv.InstallLibStub
KitsTestEnv.RemoveLibStub = InteropKitTestEnv.RemoveLibStub

---Read a source file relative to the repository root.
---@param path string
---@return string
local function readSource(path)
  local file = io.open(path, "r")
  if file == nil then
    error("InteropKitTestEnv cannot read " .. path, 3)
  end
  local source = file:read("*a")
  file:close()
  return source
end

---Load the source at `path` with its `IMPLEMENTATION_REVISION` replaced, the
---way a newer embedded copy loads over an older one in the client.
---@param path string
---@param revision integer
---@return any
local function loadAtRevision(path, revision)
  local patched, count = readSource(path):gsub(
    "local IMPLEMENTATION_REVISION = %d+",
    "local IMPLEMENTATION_REVISION = " .. revision,
    1
  )
  if count ~= 1 then
    error("InteropKitTestEnv found no IMPLEMENTATION_REVISION in " .. path, 3)
  end

  local chunk, message = loadstring(patched, "@" .. path)
  if chunk == nil then
    error(message, 3)
  end
  return chunk()
end

---Load the InteropKit source again as a copy carrying `revision`.
---@param revision integer
---@return table InteropKit
function InteropKitTestEnv.LoadSourceAtRevision(revision)
  return loadAtRevision(InteropKitTestEnv.SOURCE_PATH, revision)
end

---Load one of the Kits this suite loads by file, as a `.toc` would.
---@param name "SignalKit"|"EventKit"
---@return table facade
function KitsTestEnv.LoadKit(name)
  local chunk, message = loadfile(KIT_SOURCE_PATHS[name])
  if chunk == nil then
    error(message, 2)
  end
  return chunk()
end

---Load a Kit's source again as a copy carrying `revision`.
---@param name "SignalKit"|"EventKit"
---@param revision integer
---@return table facade
function KitsTestEnv.LoadKitAtRevision(name, revision)
  return loadAtRevision(KIT_SOURCE_PATHS[name], revision)
end

---Reset, install the host stubs and LibStub, then load Registry, InteropKit,
---SignalKit and EventKit.
---@return table InteropKit
---@return table Registry
---@return table libStub
---@return table EventKit
function KitsTestEnv.NewPackageWithKits()
  local InteropKit, Registry = KitsTestEnv.NewPackage()
  local libStub = InteropKitTestEnv.InstallLibStub()
  KitsTestEnv.LoadKit("SignalKit")
  local EventKit = KitsTestEnv.LoadKit("EventKit")
  return InteropKit, Registry, libStub, EventKit
end

return InteropKitTestEnv
