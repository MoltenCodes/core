--- Package-specific test environment for the LocaleKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's module load order and the one host
--- function only LocaleKit reads: `GetLocale`. The shared fixture does not
--- stub it, so this environment installs it and removes it again on `Reset`.
local FrameworkTestEnv = require("FrameworkTestEnv")

local LocaleKitTestEnv = FrameworkTestEnv.New({
    modules = { "Registry", "LocaleKit" },
})

--- The client locale `NewPackage` installs unless a spec asks for another.
LocaleKitTestEnv.DEFAULT_CLIENT_LOCALE = "enUS"

local sharedReset = LocaleKitTestEnv.Reset
local sharedNewPackage = LocaleKitTestEnv.NewPackage

---Make the host's `GetLocale()` return `locale`, or remove it with `nil`.
---
---LocaleKit reads `GetLocale` at call time, so this may run before or after
---the package loads.
---@param locale string?
function LocaleKitTestEnv.SetClientLocale(locale)
    if locale == nil then
        -- The stub stands in for a World of Warcraft client API that only exists in the global table.
        -- selene: allow(global_usage)
        rawset(_G, "GetLocale", nil)
        return
    end
    -- The stub stands in for a World of Warcraft client API that only exists in the global table.
    -- selene: allow(global_usage)
    rawset(_G, "GetLocale", function()
        return locale
    end)
end

---Make the host's `issecretvalue` report `secret` (compared with `rawequal`)
---as a secret value. The shared fixture owns and clears this global.
---@param secret any
function LocaleKitTestEnv.InstallSecretProbe(secret)
    -- The stub stands in for a World of Warcraft client API that only exists in the global table.
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
        return rawequal(value, secret)
    end)
end

---Remove the host error handler, so reports fall back to `print`.
function LocaleKitTestEnv.RemoveHostErrorHandler()
    -- The fixture owns this global and clears it on every reset.
    -- selene: allow(global_usage)
    rawset(_G, "geterrorhandler", nil)
end

---Clear everything the shared fixture clears, plus the `GetLocale` stub.
function LocaleKitTestEnv.Reset()
    sharedReset()
    LocaleKitTestEnv.SetClientLocale(nil)
end

---Load Registry and LocaleKit on a client whose locale is `clientLocale`
---(default `enUS`).
---@param clientLocale string?
---@return table LocaleKit
---@return table Registry
function LocaleKitTestEnv.NewPackage(clientLocale)
    local LocaleKit, Registry = sharedNewPackage()
    LocaleKitTestEnv.SetClientLocale(clientLocale or LocaleKitTestEnv.DEFAULT_CLIENT_LOCALE)
    return LocaleKit, Registry
end

---Measure the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
---@param workload fun()
---@return number kilobytes
function LocaleKitTestEnv.AllocatedKilobytes(workload)
    collectgarbage()
    collectgarbage("stop")
    local before = collectgarbage("count")
    workload()
    local after = collectgarbage("count")
    collectgarbage("restart")
    return after - before
end

---Load the LocaleKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client.
---@param revision integer
---@return table LocaleKit
function LocaleKitTestEnv.LoadRevision(revision)
    -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
    -- `require` does.
    local path = nil
    for template in package.path:gmatch("[^;]+") do
        local candidate = template:gsub("%?", "LocaleKit")
        local file = io.open(candidate, "r")
        if file ~= nil then
            file:close()
            path = candidate
            break
        end
    end
    if path == nil then
        error("LocaleKitTestEnv.LoadRevision could not find LocaleKit.lua on package.path", 2)
    end

    local file = assert(io.open(path, "r"))
    local text = file:read("*a")
    file:close()

    local patched, replacements = text:gsub(
        "local IMPLEMENTATION_REVISION = %d+",
        "local IMPLEMENTATION_REVISION = " .. revision
    )
    if replacements ~= 1 then
        error("LocaleKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
    end

    local chunk = assert(loadstring(patched, "@" .. path))
    return chunk()
end

return LocaleKitTestEnv
