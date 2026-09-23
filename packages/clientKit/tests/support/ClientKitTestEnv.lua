--- Package-specific test environment for the ClientKit suite.
---
--- The World of Warcraft stubs, including the per-flavour client profiles in
--- `framework/ClientStub.lua`, live in the shared `FrameworkTestEnv` fixture at
--- `tests/support/`. What stays here is this package's own module load order,
--- a loader that selects a profile first, a frame double for the restricted
--- frame probe, and the source loader the upgrade specs use.
local FrameworkTestEnv = require("FrameworkTestEnv")

local ClientKitTestEnv = FrameworkTestEnv.New({
    modules = { "Registry", "ClientKit" },
})

--- Path of the runtime source, relative to the repository root the runner
--- starts Busted from.
ClientKitTestEnv.SOURCE_PATH = "packages/clientKit/src/ClientKit.lua"

---Reset, install the host as `profileName` models it, then load Registry and
---ClientKit.
---@param profileName string? a name from `WOW_PROFILES`, or `nil` for the shared host with no client identity
---@return table ClientKit
---@return table Registry
function ClientKitTestEnv.NewPackageFor(profileName)
    ClientKitTestEnv.Reset()
    ClientKitTestEnv.SetWowProfile(profileName)
    ClientKitTestEnv.InstallWowApi()
    local Registry = require("Registry")
    return require("ClientKit"), Registry
end

---Options for `NewFrame`.
---@class ClientKitTestEnv.FrameOptions
---@field forbidden boolean? What `IsForbidden()` answers; the method is absent when `nil`.
---@field accessible boolean? What `CanBeAccessedInContext()` answers; the method is absent when `nil`.

---A stand-in for a frame found by enumeration, reduced to the two methods
---`ClientKit:CanAccessFrame` asks. Each method exists only when its option is
---given, which is how a spec models a client that predates it.
---@param options ClientKitTestEnv.FrameOptions?
---@return table frame
function ClientKitTestEnv.NewFrame(options)
    options = options or {}
    local frame = { calls = {} }

    if options.forbidden ~= nil then
        function frame:IsForbidden()
            self.calls[#self.calls + 1] = "IsForbidden"
            return options.forbidden
        end
    end

    if options.accessible ~= nil then
        function frame:CanBeAccessedInContext()
            self.calls[#self.calls + 1] = "CanBeAccessedInContext"
            return options.accessible
        end
    end

    return frame
end

---Load a copy of the ClientKit source that claims `revision`, against the
---state already published, exactly as a newer embedded copy would load.
---@param revision integer
---@return any
function ClientKitTestEnv.LoadSourceAtRevision(revision)
    local file = io.open(ClientKitTestEnv.SOURCE_PATH, "r")
    if file == nil then
        error("ClientKitTestEnv cannot read " .. ClientKitTestEnv.SOURCE_PATH, 2)
    end
    local source = file:read("*a")
    file:close()

    local patched, count = source:gsub(
        "local IMPLEMENTATION_REVISION = %d+",
        "local IMPLEMENTATION_REVISION = " .. revision,
        1
    )
    if count ~= 1 then
        error("ClientKitTestEnv found no IMPLEMENTATION_REVISION to patch", 2)
    end

    local chunk, message = loadstring(patched, "@" .. ClientKitTestEnv.SOURCE_PATH)
    if chunk == nil then
        error(message, 2)
    end
    return chunk()
end

return ClientKitTestEnv
