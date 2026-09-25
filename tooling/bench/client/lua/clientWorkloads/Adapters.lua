--- One vocabulary for the client-only workloads, over either side's libraries.
---
--- Each client-only workload does the same work on both sides through the
--- facets below, so a case cannot drift apart between sides. A facet is built
--- the first time it is asked for, so a workload loads (and a side's Registry
--- lookups or file checks cover) only what it uses. `Libraries()` lists what
--- the facets used so far, with each library's revision or minor, for the
--- results.
---
---   Events()    connect(event, callback) -> token, disconnect(token)
---   Messages()  subscribe(callback) -> token, publish(...)
---   Timers()    after(seconds, callback), every(seconds, callback), cancel(timer)
---   Comm()      register(callback(text, sender)), whisper(text, target)
---   Windows()   open(title) -> handle, setLabel(handle, index, text), close(handle)
---
--- The Kits side uses EventKit, a SignalKit bus, a TimerKit scope, a CommKit
--- scope and WidgetKit; the Ace3 side AceEvent-3.0 (events and messages),
--- AceTimer-3.0, AceComm-3.0 with ChatThrottleLib and AceGUI-3.0. Both
--- throttles keep their default rates (800 bytes per second, a 4000-byte
--- burst on both), because a real whisper is what the client-only workloads
--- measure.

local AceObjects = require("workloads.AceObjects")

local Adapters = {}

--- The message topic, bus and comm prefix the client-only workloads use.
Adapters.TOPIC = "BENCH_CLIENT_MESSAGE"
Adapters.PREFIX = "MCBench"

--- The labels every window holds, and the children in all: a heading, the
--- labels, a button, a check box, a slider and an edit box.
Adapters.WINDOW_LABELS = 20
Adapters.WINDOW_CHILDREN = Adapters.WINDOW_LABELS + 5

--- The size every window is given, as a small options dialog.
local WINDOW_WIDTH, WINDOW_HEIGHT = 400, 500

--- Embedded objects per Ace3 facet: AceEvent keeps one callback per object
--- and event, so N listeners need N objects, as N addons would be.
local ACE_POOL_SIZE = 256

---Remember a library for `Libraries()`, once.
---@param libraries table[]
---@param seen table<string, boolean>
---@param entry table
local function remember(libraries, seen, entry)
  if not seen[entry.name] then
    seen[entry.name] = true
    libraries[#libraries + 1] = entry
  end
end

---The Kits side's facets.
---@param host table
---@param remembered fun(entry: table)
---@return table facets
local function kitFacets(host, remembered)
  local facets = {}

  ---@param names string[]
  ---@return table[]
  local function kits(names)
    local loaded = host.RequireAll(names)
    for index = 1, #names do
      if names[index] ~= "Registry" then
        remembered({ name = names[index], revision = loaded[index].REVISION })
      end
    end
    return loaded
  end

  function facets.Events()
    local EventKit = kits({ "Registry", "SignalKit", "EventKit" })[3]
    return {
      connect = function(eventName, callback)
        return EventKit:Connect(eventName, callback)
      end,
      disconnect = function(connection)
        connection:Disconnect()
      end,
    }
  end

  function facets.Messages()
    local SignalKit = kits({ "Registry", "SignalKit" })[2]
    local bus = SignalKit:Bus("BenchClientBus", { openTopics = true })
    return {
      subscribe = function(callback)
        return bus:Subscribe(Adapters.TOPIC, callback)
      end,
      publish = function(...)
        bus:Publish(Adapters.TOPIC, ...)
      end,
    }
  end

  function facets.Timers()
    local TimerKit = kits({ "Registry", "TimerKit" })[2]
    local scope = TimerKit:CreateScope()
    return {
      after = function(seconds, callback)
        return scope:After(seconds, callback)
      end,
      every = function(seconds, callback)
        return scope:Every(seconds, callback)
      end,
      cancel = function(timer)
        timer:Cancel()
      end,
    }
  end

  function facets.Comm()
    local loaded = kits({
      "Registry",
      "SignalKit",
      "EventKit",
      "TimerKit",
      "SchedulerKit",
      "PoolKit",
      "CommKit",
    })
    local scope = loaded[7]:CreateScope()
    return {
      register = function(callback)
        scope:Register(Adapters.PREFIX, function(_, text, _, sender)
          callback(text, sender)
        end)
      end,
      whisper = function(text, target)
        local handle, reason = scope:Send({
          prefix = Adapters.PREFIX,
          text = text,
          distribution = "WHISPER",
          target = target,
        })
        if handle == nil then
          error("CommKit refused a benchmark whisper: " .. tostring(reason), 0)
        end
      end,
    }
  end

  function facets.Windows()
    local WidgetKit = kits({ "Registry", "PoolKit", "SignalKit", "WidgetKit" })[4]

    ---@param typeName string
    ---@return table
    local function create(typeName)
      local widget, reason = WidgetKit:Create(typeName)
      if widget == nil then
        error("WidgetKit could not create a " .. typeName .. ": " .. tostring(reason), 0)
      end
      return widget
    end

    return {
      open = function(title)
        local window = create("Frame")
        window:SetTitle(title)
        window:SetWidth(WINDOW_WIDTH)
        window:SetHeight(WINDOW_HEIGHT)
        window:PauseLayout()
        local heading = create("Heading")
        heading:SetText("General")
        heading:SetFullWidth(true)
        window:AddChild(heading)
        local labels = {}
        for index = 1, Adapters.WINDOW_LABELS do
          local label = create("Label")
          label:SetText("Option number " .. index .. " of the benchmark window")
          label:SetFullWidth(true)
          window:AddChild(label)
          labels[index] = label
        end
        local button = create("Button")
        button:SetText("Reset")
        window:AddChild(button)
        local checkBox = create("CheckBox")
        checkBox:SetLabel("Show in combat")
        checkBox:SetValue(true)
        window:AddChild(checkBox)
        local slider = create("Slider")
        slider:SetLabel("Scale")
        slider:SetSliderValues(0, 100, 1)
        slider:SetValue(50)
        window:AddChild(slider)
        local editBox = create("EditBox")
        editBox:SetLabel("Name")
        editBox:SetText("Tester")
        window:AddChild(editBox)
        window:ResumeLayout()
        window:PerformLayout()
        window:Show()
        return { window = window, labels = labels }
      end,
      setLabel = function(handle, index, text)
        handle.labels[index]:SetText(text)
      end,
      childCount = function(handle)
        return handle.window:GetNumChildren()
      end,
      isShown = function(handle)
        return handle.window:IsShown()
      end,
      close = function(handle)
        WidgetKit:Release(handle.window)
      end,
    }
  end

  return facets
end

---The Ace3 side's facets.
---@param host table
---@param remembered fun(entry: table)
---@return table facets
local function aceFacets(host, remembered)
  local facets = {}

  ---Check the side loaded `files` and return LibStub.
  ---@param files string[]
  ---@return table LibStub
  local function load(files)
    host.LoadFiles("Ace3", files)
    return host.Global("LibStub")
  end

  ---@param LibStub table
  ---@param name string
  ---@return table library
  local function library(LibStub, name)
    local found, minor = LibStub:GetLibrary(name)
    remembered({ name = name, minor = minor })
    return found
  end

  local eventPool = nil

  ---One pool of AceEvent objects shared by the events and messages facets.
  ---@return table pool
  local function aceEventPool()
    if eventPool == nil then
      local LibStub = load({
        "LibStub/LibStub.lua",
        "CallbackHandler-1.0/CallbackHandler-1.0.lua",
        "AceEvent-3.0/AceEvent-3.0.lua",
      })
      library(LibStub, "CallbackHandler-1.0")
      eventPool = AceObjects.NewPool(library(LibStub, "AceEvent-3.0"), ACE_POOL_SIZE)
    end
    return eventPool
  end

  function facets.Events()
    local pool = aceEventPool()
    return {
      connect = function(eventName, callback)
        local object = pool.Take()
        object:RegisterEvent(eventName, callback)
        return { object = object, eventName = eventName }
      end,
      disconnect = function(token)
        token.object:UnregisterEvent(token.eventName)
        pool.Give(token.object)
      end,
    }
  end

  function facets.Messages()
    local pool = aceEventPool()
    local AceEvent = host.Global("LibStub"):GetLibrary("AceEvent-3.0")
    return {
      subscribe = function(callback)
        local object = pool.Take()
        object:RegisterMessage(Adapters.TOPIC, callback)
        return object
      end,
      publish = function(...)
        AceEvent:SendMessage(Adapters.TOPIC, ...)
      end,
    }
  end

  function facets.Timers()
    local LibStub = load({ "LibStub/LibStub.lua", "AceTimer-3.0/AceTimer-3.0.lua" })
    local owner = library(LibStub, "AceTimer-3.0"):Embed({})
    return {
      after = function(seconds, callback)
        return owner:ScheduleTimer(callback, seconds)
      end,
      every = function(seconds, callback)
        return owner:ScheduleRepeatingTimer(callback, seconds)
      end,
      cancel = function(timer)
        owner:CancelTimer(timer)
      end,
    }
  end

  function facets.Comm()
    local LibStub = load({
      "LibStub/LibStub.lua",
      "CallbackHandler-1.0/CallbackHandler-1.0.lua",
      "AceComm-3.0/ChatThrottleLib.lua",
      "AceComm-3.0/AceComm-3.0.lua",
    })
    local owner = library(LibStub, "AceComm-3.0"):Embed({})
    local throttle = host.Global("ChatThrottleLib")
    remembered({ name = "ChatThrottleLib", minor = throttle and throttle.version })
    return {
      register = function(callback)
        owner:RegisterComm(Adapters.PREFIX, function(_, text, _, sender)
          callback(text, sender)
        end)
      end,
      whisper = function(text, target)
        owner:SendCommMessage(Adapters.PREFIX, text, "WHISPER", target)
      end,
    }
  end

  function facets.Windows()
    local LibStub = load({
      "LibStub/LibStub.lua",
      "AceGUI-3.0/AceGUI-3.0.lua",
      "AceGUI-3.0/widgets/AceGUIContainer-Frame.lua",
      "AceGUI-3.0/widgets/AceGUIWidget-Heading.lua",
      "AceGUI-3.0/widgets/AceGUIWidget-Label.lua",
      "AceGUI-3.0/widgets/AceGUIWidget-Button.lua",
      "AceGUI-3.0/widgets/AceGUIWidget-CheckBox.lua",
      "AceGUI-3.0/widgets/AceGUIWidget-Slider.lua",
      "AceGUI-3.0/widgets/AceGUIWidget-EditBox.lua",
    })
    local AceGUI = library(LibStub, "AceGUI-3.0")
    return {
      open = function(title)
        local window = AceGUI:Create("Frame")
        window:SetTitle(title)
        window:SetWidth(WINDOW_WIDTH)
        window:SetHeight(WINDOW_HEIGHT)
        window:SetLayout("List")
        window:PauseLayout()
        local heading = AceGUI:Create("Heading")
        heading:SetText("General")
        heading:SetFullWidth(true)
        window:AddChild(heading)
        local labels = {}
        for index = 1, Adapters.WINDOW_LABELS do
          local label = AceGUI:Create("Label")
          label:SetText("Option number " .. index .. " of the benchmark window")
          label:SetFullWidth(true)
          window:AddChild(label)
          labels[index] = label
        end
        local button = AceGUI:Create("Button")
        button:SetText("Reset")
        window:AddChild(button)
        local checkBox = AceGUI:Create("CheckBox")
        checkBox:SetLabel("Show in combat")
        checkBox:SetValue(true)
        window:AddChild(checkBox)
        local slider = AceGUI:Create("Slider")
        slider:SetLabel("Scale")
        slider:SetSliderValues(0, 100, 1)
        slider:SetValue(50)
        window:AddChild(slider)
        local editBox = AceGUI:Create("EditBox")
        editBox:SetLabel("Name")
        editBox:SetText("Tester")
        window:AddChild(editBox)
        window:ResumeLayout()
        window:DoLayout()
        window:Show()
        return { window = window, labels = labels }
      end,
      setLabel = function(handle, index, text)
        handle.labels[index]:SetText(text)
      end,
      childCount = function(handle)
        return #handle.window.children
      end,
      isShown = function(handle)
        return handle.window.frame:IsShown()
      end,
      close = function(handle)
        AceGUI:Release(handle.window)
      end,
    }
  end

  return facets
end

---Build the adapter of one side.
---@param side "moltencodes"|"ace3"
---@param host table the client host
---@return table adapter with the facets above and `Libraries()`
function Adapters.New(side, host)
  local libraries, seen = {}, {}
  local function remembered(entry)
    remember(libraries, seen, entry)
  end
  local builders = side == "moltencodes" and kitFacets(host, remembered)
    or aceFacets(host, remembered)

  local adapter = {}
  local built = {}
  for name, builder in pairs(builders) do
    adapter[name] = function()
      if built[name] == nil then
        built[name] = builder()
      end
      return built[name]
    end
  end

  function adapter.Libraries()
    return libraries
  end

  return adapter
end

return Adapters
