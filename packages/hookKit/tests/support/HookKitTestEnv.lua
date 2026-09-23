--- Package-specific test environment for the HookKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order and the host
--- surface only HookKit touches, which the shared fixture does not model:
---
---   `hooksecurefunc`     a post-hook that keeps the target secure when the
---                        original was secure, and allocates nothing per call;
---   `issecurevariable`   secure when the raw field holds a function the spec
---                        marked secure with `MarkSecure`, and secure for an
---                        absent raw key, as on the client;
---   `InCombatLockdown`   driven by `SetCombatLockdown`;
---   fake frames          `NewFrame` builds a table with `GetScript`,
---                        `SetScript`, `HookScript` and `IsProtected` in its
---                        metatable, and `RunScript` fires one of its scripts.
---                        Its `SetScript` drops the script's `HookScript`
---                        post-hooks, the case HookKit must never cause.
---
--- These globals are installed before HookKit loads (it reads them at load
--- time) and removed again by `Reset`, because they are not among the globals
--- the shared fixture owns.
---
--- ClientKit is an optional dependency of HookKit, declared under
--- `optionalDependencies`, so the test runner puts it on `LUA_PATH` for this
--- suite; `NewPackageWithoutClientKit` models an addon that embeds none.
local FrameworkTestEnv = require("FrameworkTestEnv")

local HookKitTestEnv = FrameworkTestEnv.New({
    modules = { "Registry", "ClientKit", "HookKit" },
})

--- The host globals this environment installs and removes.
local HOOK_GLOBALS = { "hooksecurefunc", "issecurevariable", "InCombatLockdown" }

--- Functions `issecurevariable` reports as secure. Weak-keyed so a spec's
--- functions never outlive it.
local secureFunctions = setmetatable({}, { __mode = "k" })

--- Script and post-hook tables of every fake frame, keyed by the frame.
local frameScripts = setmetatable({}, { __mode = "k" })

local inCombat = false

--- What `IsForbidden` answers, keyed by a fake frame's method table.
local frameForbidden = setmetatable({}, { __mode = "k" })

---Write a host global. The fixture stands in for the World of Warcraft client,
---whose API only exists in the global table.
---@param name string
---@param value any
local function setGlobal(name, value)
    -- selene: allow(global_usage)
    rawset(_G, name, value)
end

---Read a host global the same way.
---@param name string
---@return any
local function getGlobal(name)
    -- selene: allow(global_usage)
    return rawget(_G, name)
end

---Split `hooksecurefunc`'s two call forms.
---@return table target, string name, function hook
local function splitHookArguments(first, second, third)
    if type(first) == "string" then
        -- selene: allow(global_usage)
        return _G, first, second
    end
    return first, second, third
end

---The `hooksecurefunc` stub: replace the field with a wrapper that calls the
---original, then the hook with the same arguments, and returns the original's
---results. Up to four results are carried, so a call allocates nothing.
local function hookSecureFunction(first, second, third)
    local target, name, hook = splitHookArguments(first, second, third)
    local original = target[name]
    if type(original) ~= "function" then
        error("hooksecurefunc stub: " .. tostring(name) .. " is not a function", 2)
    end
    if type(hook) ~= "function" then
        error("hooksecurefunc stub: hook must be a function", 2)
    end
    local function wrapper(...)
        local resultOne, resultTwo, resultThree, resultFour = original(...)
        hook(...)
        return resultOne, resultTwo, resultThree, resultFour
    end
    if secureFunctions[original] then
        secureFunctions[wrapper] = true
    end
    rawset(target, name, wrapper)
end

---The `issecurevariable` stub, faithful to the client on the two points
---HookKit depends on: a raw field is secure when it holds a function marked
---secure, and an absent raw key is reported as secure (nothing tainted it),
---whatever the table inherits through `__index`.
local function isSecureVariable(first, second)
    local target, name = first, second
    if second == nil then
        -- selene: allow(global_usage)
        target, name = _G, first
    end
    local value = rawget(target, name)
    if value == nil then
        return true
    end
    return secureFunctions[value] == true
end

---Install the HookKit host globals. Must run before HookKit loads.
function HookKitTestEnv.InstallHookApi()
    setGlobal("hooksecurefunc", hookSecureFunction)
    setGlobal("issecurevariable", isSecureVariable)
    setGlobal("InCombatLockdown", function()
        return inCombat
    end)
end

local sharedReset = HookKitTestEnv.Reset

---Clear every module, global and stub this environment owns, including the
---HookKit host globals.
function HookKitTestEnv.Reset()
    sharedReset()
    for index = 1, #HOOK_GLOBALS do
        setGlobal(HOOK_GLOBALS[index], nil)
    end
    inCombat = false
end

---Reset, install the host stubs and the HookKit host globals, then load the
---module chain.
---@return table HookKit
---@return table Registry
---@return table ClientKit
function HookKitTestEnv.NewPackage()
    HookKitTestEnv.Reset()
    HookKitTestEnv.InstallWowApi()
    HookKitTestEnv.InstallHookApi()
    local Registry = require("Registry")
    local ClientKit = require("ClientKit")
    local HookKit = require("HookKit")
    return HookKit, Registry, ClientKit
end

---Load Registry and HookKit only, as a consumer that embeds no ClientKit does.
---@return table HookKit
---@return table Registry
function HookKitTestEnv.NewPackageWithoutClientKit()
    HookKitTestEnv.Reset()
    HookKitTestEnv.InstallWowApi()
    HookKitTestEnv.InstallHookApi()
    local Registry = require("Registry")
    local HookKit = require("HookKit")
    return HookKit, Registry
end

---Load the module chain on a host with none of `hooksecurefunc`,
---`issecurevariable` and `InCombatLockdown`.
---@return table HookKit
function HookKitTestEnv.NewPackageWithoutHookApi()
    HookKitTestEnv.Reset()
    HookKitTestEnv.InstallWowApi()
    require("Registry")
    require("ClientKit")
    return require("HookKit")
end

---Mark `fn` as a function the host considers secure, and return it.
---@param fn function
---@return function
function HookKitTestEnv.MarkSecure(fn)
    secureFunctions[fn] = true
    return fn
end

---Change what a fake frame built with `forbidden` answers to `IsForbidden`.
---@param frame table
---@param value boolean
function HookKitTestEnv.SetForbidden(frame, value)
    frameForbidden[getmetatable(frame).__index] = value
end

---Enter or leave combat lockdown.
---@param value boolean
function HookKitTestEnv.SetCombatLockdown(value)
    inCombat = value
end

---Read a global, for specs that hook one.
---@param name string
---@return any
function HookKitTestEnv.GetGlobal(name)
    return getGlobal(name)
end

---Write a global, for specs that hook one.
---@param name string
---@param value any
function HookKitTestEnv.SetGlobal(name, value)
    setGlobal(name, value)
end

---Options accepted by `NewFrame`.
---@class HookKitTestEnv.FrameOptions
---@field protected boolean? What `IsProtected` answers. Defaults to `false`.
---@field withoutIsProtected boolean? Build a frame that has no `IsProtected`.
---@field forbidden boolean? What `IsForbidden` answers; the frame has `IsForbidden` only when this is given.

---Build a fake frame. Its methods live in its metatable, as a real frame's do,
---so hooking one of them writes a raw field onto the frame.
---@param options HookKitTestEnv.FrameOptions?
---@return table frame
function HookKitTestEnv.NewFrame(options)
    options = options or {}
    local scripts = {}
    local postHooks = {}
    local methods = {}

    function methods.GetScript(_, script)
        return scripts[script]
    end

    function methods.SetScript(_, script, handler)
        if handler ~= nil and type(handler) ~= "function" then
            error("Frame:SetScript stub: handler must be a function or nil", 2)
        end
        scripts[script] = handler
        -- Modelled as the worst case HookKit guards against: `SetScript`
        -- drops the post-hooks `HookScript` added to that script.
        postHooks[script] = nil
    end

    function methods.HookScript(_, script, handler)
        local list = postHooks[script]
        if list == nil then
            list = {}
            postHooks[script] = list
        end
        list[#list + 1] = handler
    end

    if options.withoutIsProtected ~= true then
        local protected = options.protected == true
        function methods.IsProtected()
            return protected, protected
        end
    end

    if options.forbidden ~= nil then
        function methods.IsForbidden()
            return frameForbidden[methods] == true
        end
        frameForbidden[methods] = options.forbidden
    end

    function methods.Show() end

    local frame = setmetatable({}, { __index = methods })
    frameScripts[frame] = { scripts = scripts, postHooks = postHooks }
    return frame
end

---Fire `script` on a fake frame the way the host does: the handler set with
---`SetScript` first, then every `HookScript` post-hook, each called with the
---frame and `...`. Returns the handler's first result.
---@param frame table
---@param script string
---@param ... any
---@return any
function HookKitTestEnv.RunScript(frame, script, ...)
    local entry = frameScripts[frame]
    if entry == nil then
        error("HookKitTestEnv.RunScript expects a frame from NewFrame", 2)
    end
    local result = nil
    local handler = entry.scripts[script]
    if handler ~= nil then
        result = handler(frame, ...)
    end
    local list = entry.postHooks[script]
    if list ~= nil then
        for index = 1, #list do
            list[index](frame, ...)
        end
    end
    return result
end

---Measure the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
---@param workload fun()
---@return number kilobytes
function HookKitTestEnv.AllocatedKilobytes(workload)
    collectgarbage()
    collectgarbage("stop")
    local before = collectgarbage("count")
    workload()
    local after = collectgarbage("count")
    collectgarbage("restart")
    return after - before
end

---Load the HookKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client.
---@param revision integer
---@return table HookKit
function HookKitTestEnv.LoadRevision(revision)
    -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
    -- `require` does.
    local path = nil
    for template in package.path:gmatch("[^;]+") do
        local candidate = template:gsub("%?", "HookKit")
        local file = io.open(candidate, "r")
        if file ~= nil then
            file:close()
            path = candidate
            break
        end
    end
    if path == nil then
        error("HookKitTestEnv.LoadRevision could not find HookKit.lua on package.path", 2)
    end

    local file = assert(io.open(path, "r"))
    local text = file:read("*a")
    file:close()

    local patched, replacements = text:gsub(
        "local IMPLEMENTATION_REVISION = %d+",
        "local IMPLEMENTATION_REVISION = " .. revision
    )
    if replacements ~= 1 then
        error("HookKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
    end

    local chunk = assert(loadstring(patched, "@" .. path))
    return chunk()
end

return HookKitTestEnv
