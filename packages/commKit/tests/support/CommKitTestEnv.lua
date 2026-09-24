--- Package-specific test environment for the CommKit suite.
---
--- The `package.loaded` bookkeeping, the frame, timer, clock and error stubs
--- live in the shared `FrameworkTestEnv` fixture at `tests/support/`. What
--- stays here is this package's module chain and the host surface only
--- CommKit touches, which the shared fixture does not model:
---
---   `C_ChatInfo`      prefix registration and the two send functions, with a
---                     recorded outbox, every attempt recorded, and scripted
---                     results (a throttle, a failure) consumed in order;
---   `Enum`            `SendAddonMessageResult` and
---                     `RegisterAddonMessagePrefixResult` as on 12.x;
---   `GetFramerate`    driven by `SetFramerate`;
---   `UnitInParty`, `UnitInRaid`   answered from `SetGroupMembers`;
---   `hooksecurefunc`  a post-hook stub, installed only for the HookKit chain.
---
--- These globals are installed before the chain loads and removed again by
--- `Reset`, because they are not among the globals the shared fixture owns.
---
--- The fixture's timers fire only when a spec fires them, so this environment
--- wraps `C_Timer` before TimerKit binds it and records when each native timer
--- is due on the fixture clock. `Advance(seconds)` then moves the clock,
--- firing every timer that falls due in order and running the scheduler's
--- frame driver after each, which is how SchedulerKit's `After` and
--- `NextFrame` jobs and TimerKit's tickers run in these specs.
---
--- CodecKit, HookKit and SchemaKit are declared under `optionalDependencies`,
--- so the test runner puts them on `LUA_PATH`; `Load` leaves each out on
--- request to model an addon that embeds none. LifecycleKit is optional too:
--- it decides who closes an addon scope at logout. `Load` leaves it out unless
--- asked, and `LoadLifecycleKit` adds it after CommKit, as an addon that
--- embeds it later would.
local FrameworkTestEnv = require("FrameworkTestEnv")

--- Every module any spec loads, in load order. `Reset` clears all of them.
local ALL_MODULES = {
    "Registry",
    "SignalKit",
    "EventKit",
    "TimerKit",
    "SchedulerKit",
    "PoolKit",
    "CodecKit",
    "HookKit",
    "SchemaKit",
    "CommKit",
}

--- LifecycleKit loads after CommKit when a spec asks for it. It is kept out of
--- `ALL_MODULES`, whose last entry is the package `ReloadPackage` reloads, so
--- `Reset` unloads it separately.
local LIFECYCLE_MODULE = "LifecycleKit"

--- What LifecycleKit 0.6.0 publishes as `CLOSES_ADDON_SCOPES`: the package ids
--- whose addon scopes (or bus) it closes at shutdown.
local CLOSES_ADDON_SCOPES = {
    timerKit = true,
    schedulerKit = true,
    eventKit = true,
    hookKit = true,
    commandKit = true,
    commKit = true,
    signalKit = true,
}

local CommKitTestEnv = FrameworkTestEnv.New({ modules = ALL_MODULES })

--- The host globals this environment installs and removes.
local CHAT_GLOBALS = {
    "C_ChatInfo",
    "Enum",
    "GetFramerate",
    "UnitInParty",
    "UnitInRaid",
    "hooksecurefunc",
    "SendAddonMessage",
    "SendChatMessage",
    "RegisterAddonMessagePrefix",
}

--- The player name deliveries are addressed to.
CommKitTestEnv.PLAYER = "Me-Realm"

--- `Enum.SendAddonMessageResult` as the 12.x client publishes it.
CommKitTestEnv.SEND_RESULT = {
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

--- `Enum.RegisterAddonMessagePrefixResult` as the 12.x client publishes it.
CommKitTestEnv.REGISTER_RESULT = {
    Success = 0,
    DuplicatePrefix = 1,
    InvalidPrefix = 2,
    MaxPrefixes = 3,
}

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

--- The chat stub's state, rebuilt by `Reset`.
local chat

local function resetChat()
    chat = {
        registered = {},
        registerCalls = {},
        registerResults = {},
        sendResults = {},
        attempts = {},
        outbox = {},
        chatOutbox = {},
        framerate = 60,
        members = {},
    }
end
resetChat()

---One send through the stub: consume a scripted result (default Success),
---record the attempt, and put a successful message in the outbox.
local function stubSend(logged, prefix, text, distribution, target)
    local result = table.remove(chat.sendResults, 1)
    if result == nil then
        result = CommKitTestEnv.SEND_RESULT.Success
    end
    local entry = {
        prefix = prefix,
        text = text,
        distribution = distribution,
        target = target,
        logged = logged,
        result = result,
    }
    chat.attempts[#chat.attempts + 1] = entry
    if result == CommKitTestEnv.SEND_RESULT.Success then
        chat.outbox[#chat.outbox + 1] = entry
    end
    return result
end

---Install `C_ChatInfo`, `Enum`, `GetFramerate`, `UnitInParty` and `UnitInRaid`.
local function installChatApi()
    setGlobal("C_ChatInfo", {
        RegisterAddonMessagePrefix = function(prefix)
            chat.registerCalls[#chat.registerCalls + 1] = prefix
            local result = table.remove(chat.registerResults, 1)
            if result == nil then
                result = CommKitTestEnv.REGISTER_RESULT.Success
            end
            if result == CommKitTestEnv.REGISTER_RESULT.Success then
                chat.registered[prefix] = true
            end
            return result
        end,
        IsAddonMessagePrefixRegistered = function(prefix)
            return chat.registered[prefix] == true
        end,
        SendAddonMessage = function(prefix, text, distribution, target)
            return stubSend(false, prefix, text, distribution, target)
        end,
        SendAddonMessageLogged = function(prefix, text, distribution, target)
            return stubSend(true, prefix, text, distribution, target)
        end,
        SendChatMessage = function(text, distribution, language, target)
            chat.chatOutbox[#chat.chatOutbox + 1] = {
                text = text,
                distribution = distribution,
                language = language,
                target = target,
            }
        end,
    })
    setGlobal("Enum", {
        SendAddonMessageResult = CommKitTestEnv.SEND_RESULT,
        RegisterAddonMessagePrefixResult = CommKitTestEnv.REGISTER_RESULT,
    })
    setGlobal("GetFramerate", function()
        return chat.framerate
    end)
    setGlobal("UnitInParty", function(name)
        return chat.members[name] == true
    end)
    setGlobal("UnitInRaid", function(name)
        if chat.members[name] == true then
            return 1
        end
        return nil
    end)
end

---The `hooksecurefunc` stub: replace the field with a wrapper that calls the
---original, then the hook with the same arguments, and returns the original's
---results.
local function hookSecureFunction(first, second, third)
    local target, name, hook = first, second, third
    if type(first) == "string" then
        -- selene: allow(global_usage)
        target, name, hook = _G, first, second
    end
    local original = target[name]
    if type(original) ~= "function" then
        error("hooksecurefunc stub: " .. tostring(name) .. " is not a function", 2)
    end
    rawset(target, name, function(...)
        local resultOne, resultTwo = original(...)
        hook(...)
        return resultOne, resultTwo
    end)
end

---Wrap `C_Timer` so every native timer records when it falls due on the
---fixture's wall clock. Must run before TimerKit binds `C_Timer`.
local function wrapTimers()
    local timers = getGlobal("C_Timer")
    local newTimer, newTicker = timers.NewTimer, timers.NewTicker
    local clock = getGlobal("GetTimePreciseSec")
    setGlobal("C_Timer", {
        NewTimer = function(seconds, callback)
            local native = newTimer(seconds, callback)
            if type(native) == "table" then
                native.dueMs = clock() * 1000 + seconds * 1000
            end
            return native
        end,
        NewTicker = function(seconds, callback)
            local native = newTicker(seconds, callback)
            if type(native) == "table" then
                native.intervalMs = seconds * 1000
                native.dueMs = clock() * 1000 + seconds * 1000
            end
            return native
        end,
    })
end

local baseReset = CommKitTestEnv.Reset

---Clear every module, global and stub this environment owns.
function CommKitTestEnv.Reset()
    package.loaded[LIFECYCLE_MODULE] = nil
    baseReset()
    for index = 1, #CHAT_GLOBALS do
        setGlobal(CHAT_GLOBALS[index], nil)
    end
    resetChat()
end

---Options accepted by `Load`.
---@class CommKitTestEnv.LoadOptions
---@field codecKit boolean? Load CodecKit; defaults to `true`.
---@field hookKit boolean? Load HookKit and a `hooksecurefunc` stub; defaults to `false`.
---@field schemaKit boolean? Load SchemaKit; defaults to `false`.
---@field secureCall boolean? Install the fixture's `securecallfunction`; defaults to `false`.
---@field commKitRevision integer? Load CommKit as a copy carrying this revision (see `LoadRevision`), the way an older embedded copy loads first; defaults to the shipped revision.
---@field lifecycleKit (boolean|table)? Load LifecycleKit after CommKit; `true` makes it announce `CLOSES_ADDON_SCOPES`, `false` models an older revision without it. Defaults to `nil`: not loaded.

---Reset, install the host stubs, then load the module chain.
---@param options CommKitTestEnv.LoadOptions?
---@return table CommKit
---@return table<string, table> loaded every loaded module by name
function CommKitTestEnv.Load(options)
    options = options or {}
    CommKitTestEnv.Reset()
    CommKitTestEnv.InstallWowApi()
    installChatApi()
    wrapTimers()
    if options.secureCall then
        CommKitTestEnv.InstallSecureCallFunction()
    end
    if options.hookKit then
        setGlobal("hooksecurefunc", hookSecureFunction)
    end

    local skip = {
        CodecKit = options.codecKit == false,
        HookKit = not options.hookKit,
        SchemaKit = not options.schemaKit,
    }
    local loaded = {}
    for index = 1, #ALL_MODULES do
        local name = ALL_MODULES[index]
        if not skip[name] then
            if name == "CommKit" and options.commKitRevision ~= nil then
                loaded[name] = CommKitTestEnv.LoadRevision(options.commKitRevision)
            else
                loaded[name] = require(name)
            end
        end
    end
    if options.lifecycleKit ~= nil then
        loaded.LifecycleKit = CommKitTestEnv.LoadLifecycleKit(options.lifecycleKit)
    end
    return loaded.CommKit, loaded
end

---Load LifecycleKit on top of a loaded chain, then make it announce
---`CLOSES_ADDON_SCOPES` or not (see `SetClosesAddonScopes`).
---@param closesAddonScopes boolean|table
---@return table LifecycleKit
function CommKitTestEnv.LoadLifecycleKit(closesAddonScopes)
    local LifecycleKit = require(LIFECYCLE_MODULE)
    CommKitTestEnv.SetClosesAddonScopes(LifecycleKit, closesAddonScopes)
    return LifecycleKit
end

---Make `LifecycleKit` announce, or stop announcing, `CLOSES_ADDON_SCOPES`.
---
---`true` models LifecycleKit 0.6.0 and later, `false` an older revision
---without the field. The field is written onto the loaded facade with
---`rawset`, whatever the revision on `LUA_PATH` publishes.
---@param LifecycleKit table
---@param closesAddonScopes boolean|table `true` for the full list, `false` for none, or a list of its own
function CommKitTestEnv.SetClosesAddonScopes(LifecycleKit, closesAddonScopes)
    local value = nil
    if closesAddonScopes == true then
        value = CLOSES_ADDON_SCOPES
    elseif type(closesAddonScopes) == "table" then
        value = closesAddonScopes
    end
    rawset(LifecycleKit, "CLOSES_ADDON_SCOPES", value)
end

---The default chain: everything but HookKit and SchemaKit. The package under
---test first, then Registry, as `FrameworkTestEnv` environments return them.
---@return table CommKit
---@return table Registry
function CommKitTestEnv.NewPackage()
    local CommKit, loaded = CommKitTestEnv.Load()
    return CommKit, loaded.Registry
end

---The chat stub's state: `attempts`, `outbox`, `chatOutbox`, `registered`,
---`registerCalls`.
---@return table
function CommKitTestEnv.Chat()
    return chat
end

---Script the results of the next sends, in order.
---@param ... integer
function CommKitTestEnv.QueueSendResults(...)
    for index = 1, select("#", ...) do
        chat.sendResults[#chat.sendResults + 1] = select(index, ...)
    end
end

---Script the result of the next prefix registration.
---@param result integer
function CommKitTestEnv.QueueRegisterResult(result)
    chat.registerResults[#chat.registerResults + 1] = result
end

---Return and clear every message the stub accepted since the last call.
---@return table[]
function CommKitTestEnv.TakeOutbox()
    local taken = chat.outbox
    chat.outbox = {}
    return taken
end

---@param framesPerSecond number
function CommKitTestEnv.SetFramerate(framesPerSecond)
    chat.framerate = framesPerSecond
end

---@param names string[]
function CommKitTestEnv.SetGroupMembers(names)
    chat.members = {}
    for index = 1, #names do
        chat.members[names[index]] = true
    end
end

---Deliver an addon message as the client does, through the fixture.
---@param prefix string
---@param text string
---@param channel string
---@param sender string
function CommKitTestEnv.Deliver(prefix, text, channel, sender)
    CommKitTestEnv.Emit(
        "CHAT_MSG_ADDON",
        prefix,
        text,
        channel,
        sender,
        CommKitTestEnv.PLAYER,
        0,
        0,
        "",
        0
    )
end

---Deliver on the logged channel.
---@param prefix string
---@param text string
---@param channel string
---@param sender string
function CommKitTestEnv.DeliverLogged(prefix, text, channel, sender)
    CommKitTestEnv.Emit(
        "CHAT_MSG_ADDON_LOGGED",
        prefix,
        text,
        channel,
        sender,
        CommKitTestEnv.PLAYER,
        0,
        0,
        "",
        0
    )
end

---Deliver every message in the outbox as received from `sender`, in order,
---on the channel it was sent on, and clear it. Returns how many were
---delivered.
---@param sender string
---@return integer
function CommKitTestEnv.Loopback(sender)
    local taken = CommKitTestEnv.TakeOutbox()
    for index = 1, #taken do
        local entry = taken[index]
        if entry.logged then
            CommKitTestEnv.DeliverLogged(entry.prefix, entry.text, entry.distribution, sender)
        else
            CommKitTestEnv.Deliver(entry.prefix, entry.text, entry.distribution, sender)
        end
    end
    return #taken
end

---Run the scheduler's frame driver until it removes itself (bounded).
function CommKitTestEnv.Pump()
    for _ = 1, 200 do
        if CommKitTestEnv.ActiveOnUpdateCount() == 0 then
            return
        end
        CommKitTestEnv.Tick()
    end
end

---The earliest native timer due no later than `targetMs`, and its index.
---@param targetMs number
---@return table|nil native
---@return integer index
local function earliestDue(targetMs)
    local natives = CommKitTestEnv.NativeTimers()
    local best, bestIndex = nil, 0
    for index = 1, #natives do
        local native = natives[index]
        local live = not native.cancelled and (native.repeating or not native.fired)
        if live and native.dueMs ~= nil and native.dueMs <= targetMs + 1e-6 then
            if best == nil or native.dueMs < best.dueMs then
                best, bestIndex = native, index
            end
        end
    end
    return best, bestIndex
end

---Milliseconds on the fixture's wall clock.
---@return number
local function wallMs()
    return getGlobal("GetTimePreciseSec")() * 1000
end

---Move the clock forward by `seconds`, firing every native timer that falls
---due on the way in order and running the frame driver after each. `0` runs
---what is due now, which is what a zero-delay timer (the next frame) needs.
---@param seconds number
function CommKitTestEnv.Advance(seconds)
    local targetMs = wallMs() + seconds * 1000
    CommKitTestEnv.Pump()
    for _ = 1, 10000 do
        local native, index = earliestDue(targetMs)
        if native == nil then
            break
        end
        local currentMs = wallMs()
        if native.dueMs > currentMs then
            CommKitTestEnv.AdvanceMs(native.dueMs - currentMs)
        end
        if native.repeating then
            native.dueMs = native.dueMs + native.intervalMs
        end
        CommKitTestEnv.FireNative(index)
        CommKitTestEnv.Pump()
    end
    local currentMs = wallMs()
    if targetMs > currentMs then
        CommKitTestEnv.AdvanceMs(targetMs - currentMs)
    end
    CommKitTestEnv.Pump()
end

---Measure the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
---@param workload fun()
---@return number kilobytes
function CommKitTestEnv.AllocatedKilobytes(workload)
    collectgarbage()
    collectgarbage("stop")
    local before = collectgarbage("count")
    workload()
    local after = collectgarbage("count")
    collectgarbage("restart")
    return after - before
end

---A string of `length` bytes that the addon channel carries, cycling through
---the printable letters so every chunk differs.
---@param length integer
---@return string
function CommKitTestEnv.Text(length)
    local parts = {}
    for index = 1, length do
        parts[index] = string.char(65 + (index - 1) % 26)
    end
    return table.concat(parts)
end

---Load the CommKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client.
---@param revision integer
---@return table CommKit
function CommKitTestEnv.LoadRevision(revision)
    local path = nil
    for template in package.path:gmatch("[^;]+") do
        local candidate = template:gsub("%?", "CommKit")
        local file = io.open(candidate, "r")
        if file ~= nil then
            file:close()
            path = candidate
            break
        end
    end
    if path == nil then
        error("CommKitTestEnv.LoadRevision could not find CommKit.lua on package.path", 2)
    end

    local file = assert(io.open(path, "r"))
    local text = file:read("*a")
    file:close()

    local patched, replacements = text:gsub(
        "local IMPLEMENTATION_REVISION = %d+",
        "local IMPLEMENTATION_REVISION = " .. revision
    )
    if replacements ~= 1 then
        error("CommKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
    end

    local chunk = assert(loadstring(patched, "@" .. path))
    return chunk()
end

return CommKitTestEnv
