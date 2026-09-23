--- A second WidgetKit environment with every optional dependency loaded.
---
--- Position bindings debounce their saves through SchedulerKit (which needs
--- TimerKit), store into SettingsKit scope views, and media pickers list
--- MediaKit's names. This environment loads all of them, in dependency order,
--- before WidgetKit:
---
---   Registry, SignalKit, TimerKit, SchedulerKit, PoolKit, SchemaKit,
---   SettingsKit, OptionsKit, MediaKit, WidgetKit
---
--- EventKit and LifecycleKit are optional for every Kit here since package F,
--- so the runner no longer puts them on `LUA_PATH` for this suite.
---
--- Saved variables a spec opens with `SettingsKit:Open` are globals the shared
--- fixture does not own, so `SavedVariable` records them and `Reset` removes
--- them.
local FrameworkTestEnv = require("FrameworkTestEnv")

local WidgetKitHostTestEnv = FrameworkTestEnv.New({
    modules = {
        "Registry",
        "SignalKit",
        "TimerKit",
        "SchedulerKit",
        "PoolKit",
        "SchemaKit",
        "SettingsKit",
        "OptionsKit",
        "MediaKit",
        "WidgetKit",
    },
})

--- Saved-variable globals created through `SavedVariable`.
local savedVariables = {}

---@param name string
---@param value any
local function setGlobal(name, value)
    -- The fixture stands in for the World of Warcraft client, whose saved variables only exist in the global table.
    -- selene: allow(global_usage)
    rawset(_G, name, value)
end

---@param name string
---@return any
local function getGlobal(name)
    -- selene: allow(global_usage)
    return rawget(_G, name)
end

local sharedReset = WidgetKitHostTestEnv.Reset

---Clear every module, global and stub this environment owns, saved variables
---included.
function WidgetKitHostTestEnv.Reset()
    sharedReset()
    for index = #savedVariables, 1, -1 do
        setGlobal(savedVariables[index], nil)
        savedVariables[index] = nil
    end
end

---Reset, install the host stubs, load the whole chain and create `UIParent`.
---@return table WidgetKit
---@return table modules every loaded module by name
function WidgetKitHostTestEnv.NewPackage()
    WidgetKitHostTestEnv.Reset()
    WidgetKitHostTestEnv.InstallWowApi()
    local modules = {}
    for _, name in ipairs({
        "Registry",
        "SignalKit",
        "TimerKit",
        "SchedulerKit",
        "PoolKit",
        "SchemaKit",
        "SettingsKit",
        "OptionsKit",
        "MediaKit",
        "WidgetKit",
    }) do
        modules[name] = require(name)
    end
    local uiParent = getGlobal("CreateFrame")("Frame", "UIParent")
    uiParent:SetSize(1920, 1080)
    return modules.WidgetKit, modules
end

---Name a saved variable for `SettingsKit:Open`, so `Reset` removes it.
---@param name string
---@return string name
function WidgetKitHostTestEnv.SavedVariable(name)
    savedVariables[#savedVariables + 1] = name
    return name
end

---Fire the most recently created native timer, as the client would.
---@return boolean fired
function WidgetKitHostTestEnv.FireLatestTimer()
    local timers = WidgetKitHostTestEnv.NativeTimers()
    return WidgetKitHostTestEnv.FireNative(#timers)
end

return WidgetKitHostTestEnv
