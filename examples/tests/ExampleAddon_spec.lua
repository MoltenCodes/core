-- Executable documentation for examples/.
--
-- The example addon in this directory is the copy-pasteable answer to "how do I
-- embed the framework". A broken example is worse than no example, so this spec
-- loads the real files: it reads the load order out of `embeds.xml`, loads each
-- listed package from its package source, then runs `Core.lua` exactly the way
-- the World of Warcraft client would — with the addon name and the addon's
-- private table as the file's `...` vararg.
--
-- The World of Warcraft API is stubbed inline rather than reused from a
-- package's `tests/support/` directory: those helpers are package-private by
-- the rule in docs/TESTING.md, and the example is not part of any package.

local EXAMPLES_DIRECTORY = "examples"
local ADDON_NAME = "ExampleAddon"

local REGISTRY_STATE_KEY = "__MOLTENCODES_REGISTRY_STATE_V2"
local NAMESPACE_KEY = "MoltenCodes"

-- Host environment ----------------------------------------------------------

local frames
local nativeTimers
local loadedAddons
local loggedIn
local reportedErrors
local printedLines
local originalPrint

---Build one stub Frame that records its registrations and script handlers.
---@return table
local function newFrame()
    local frame = {
        scripts = {},
        registrations = {},
    }

    function frame:SetScript(scriptName, handler)
        self.scripts[scriptName] = handler
    end

    function frame:RegisterEvent(eventName)
        self.registrations[eventName] = { units = false }
        return true
    end

    function frame:RegisterUnitEvent(eventName, ...)
        local units = {}
        for index = 1, select("#", ...) do
            units[select(index, ...)] = true
        end
        self.registrations[eventName] = { units = units }
        return true
    end

    function frame:UnregisterEvent(eventName)
        self.registrations[eventName] = nil
    end

    frames[#frames + 1] = frame
    return frame
end

local function installWowApi()
    frames = {}
    nativeTimers = {}
    loadedAddons = {}
    loggedIn = false
    reportedErrors = {}
    printedLines = {}

    rawset(_G, "CreateFrame", function(frameType)
        if frameType ~= "Frame" then
            error('CreateFrame stub supports only "Frame", received ' .. tostring(frameType), 2)
        end
        return newFrame()
    end)

    rawset(_G, "C_AddOns", {
        IsAddOnLoaded = function(addonName)
            local finished = loadedAddons[addonName] == true
            return finished, finished
        end,
    })

    rawset(_G, "IsLoggedIn", function()
        return loggedIn
    end)

    local function newNativeTimer(seconds, callback, repeating)
        local native = {
            seconds = seconds,
            callback = callback,
            repeating = repeating,
            cancelled = false,
        }

        function native:Cancel()
            self.cancelled = true
        end

        function native:IsCancelled()
            return self.cancelled
        end

        nativeTimers[#nativeTimers + 1] = native
        return native
    end

    rawset(_G, "C_Timer", {
        NewTimer = function(seconds, callback)
            return newNativeTimer(seconds, callback, false)
        end,
        NewTicker = function(seconds, callback)
            return newNativeTimer(seconds, callback, true)
        end,
    })

    rawset(_G, "geterrorhandler", function()
        return function(message)
            reportedErrors[#reportedErrors + 1] = tostring(message)
        end
    end)

    originalPrint = print
    rawset(_G, "print", function(...)
        local parts = {}
        for index = 1, select("#", ...) do
            parts[index] = tostring(select(index, ...))
        end
        printedLines[#printedLines + 1] = table.concat(parts, " ")
    end)
end

local function removeWowApi()
    if originalPrint ~= nil then
        rawset(_G, "print", originalPrint)
        originalPrint = nil
    end
    for _, key in ipairs({ "CreateFrame", "C_AddOns", "IsLoggedIn", "C_Timer", "geterrorhandler" }) do
        rawset(_G, key, nil)
    end
    rawset(_G, NAMESPACE_KEY, nil)
    rawset(_G, REGISTRY_STATE_KEY, nil)
    rawset(_G, "ExampleAddonDB", nil)
    frames = nil
    nativeTimers = nil
end

---Deliver `eventName` to every stub Frame registered for it.
---@param eventName string
---@param unit string|nil unit token for a unit-filtered event
---@param ... any client payload
local function fireEvent(eventName, unit, ...)
    for index = 1, #frames do
        local frame = frames[index]
        local registration = frame.registrations[eventName]
        local handler = frame.scripts.OnEvent
        if registration ~= nil and handler ~= nil then
            local matches = registration.units == false
                or (unit ~= nil and registration.units[unit] == true)
            if matches then
                if unit ~= nil and registration.units ~= false then
                    handler(frame, eventName, unit, ...)
                else
                    handler(frame, eventName, ...)
                end
            end
        end
    end
end

---Fire every live repeating native timer once.
local function fireTickers()
    for index = 1, #nativeTimers do
        local native = nativeTimers[index]
        if native.repeating and not native.cancelled then
            native.callback(native)
        end
    end
end

-- Loading the example -------------------------------------------------------

---@param path string
---@return string
local function readFile(path)
    local file = io.open(path, "r")
    if file == nil then
        error("missing file: " .. path, 0)
    end
    local contents = file:read("*a")
    file:close()
    return contents
end

---Return the script file names listed in `embeds.xml`, in load order.
---@return string[]
local function embeddedScriptNames()
    local names = {}
    local xml = readFile(EXAMPLES_DIRECTORY .. "/embeds.xml")
    for reference in string.gmatch(xml, '<Script%s+file="([^"]+)"') do
        names[#names + 1] = string.match(reference, "([^\\/]+)$")
    end
    return names
end

---Map a facade file name to its package source path.
---
---The framework's naming rule is that a PascalCase Lua facade belongs to the
---lowerCamelCase package of the same name, so the mapping needs no table that
---could fall out of date.
---@param scriptName string for example `"SignalKit.lua"`
---@return string path
local function packageSourcePath(scriptName)
    local facade = string.match(scriptName, "^(.+)%.lua$")
    if facade == nil then
        error("not a Lua file: " .. scriptName, 0)
    end
    local packageId = string.lower(string.sub(facade, 1, 1)) .. string.sub(facade, 2)
    return "packages/" .. packageId .. "/src/" .. scriptName
end

---Load every embedded package in the order `embeds.xml` lists them.
local function loadEmbeddedPackages()
    local names = embeddedScriptNames()
    assert.is_true(#names > 0, "embeds.xml lists no scripts")
    for index = 1, #names do
        local path = packageSourcePath(names[index])
        local chunk, message = loadfile(path)
        if chunk == nil then
            error("could not load " .. path .. ": " .. tostring(message), 0)
        end
        chunk()
    end
end

---Run `Core.lua` the way the client does, and return the addon's private table.
---@return table addonTable
local function loadExampleAddon()
    local path = EXAMPLES_DIRECTORY .. "/Core.lua"
    local chunk, message = loadfile(path)
    if chunk == nil then
        error("could not load " .. path .. ": " .. tostring(message), 0)
    end
    local addonTable = {}
    chunk(ADDON_NAME, addonTable)
    return addonTable
end

-- Specs ---------------------------------------------------------------------

describe("ExampleAddon", function()
    before_each(installWowApi)
    after_each(removeWowApi)

    it("loads every package embeds.xml lists, in that order", function()
        loadEmbeddedPackages()

        local registry = rawget(_G, NAMESPACE_KEY).Registries[2]
        assert.are.equal(2, registry.API)
        for _, packageName in ipairs({
            "signalKit",
            "eventKit",
            "lifecycleKit",
            "moduleKit",
            "timerKit",
        }) do
            assert.is_not_nil(registry:Get(packageName, 1))
        end
    end)

    it("reaches the ready phase and enables its module", function()
        loadEmbeddedPackages()
        local addonTable = loadExampleAddon()

        assert.are.equal("loading", addonTable.Lifecycle:GetState())
        assert.is_false(addonTable.Greeter:IsEnabled())

        loadedAddons[ADDON_NAME] = true
        fireEvent("ADDON_LOADED", nil, ADDON_NAME)
        assert.are.equal("loaded", addonTable.Lifecycle:GetState())
        assert.is_true(addonTable.Greeter:IsInitialized())

        loggedIn = true
        fireEvent("PLAYER_LOGIN", nil)
        assert.are.equal("ready", addonTable.Lifecycle:GetState())
        assert.is_true(addonTable.Greeter:IsEnabled())

        assert.are.equal(1, rawget(_G, "ExampleAddonDB").greetings)
        assert.are.equal(0, #reportedErrors, table.concat(reportedErrors, "; "))
    end)

    it("delivers the events and the timer its module subscribes to", function()
        loadEmbeddedPackages()
        local addonTable = loadExampleAddon()

        loadedAddons[ADDON_NAME] = true
        fireEvent("ADDON_LOADED", nil, ADDON_NAME)
        loggedIn = true
        fireEvent("PLAYER_LOGIN", nil)

        local before = #printedLines
        fireEvent("PLAYER_ENTERING_WORLD", nil, false, true)
        fireEvent("UNIT_HEALTH", "player")
        fireTickers()

        assert.are.equal(before + 3, #printedLines)
        assert.are.equal(0, #reportedErrors, table.concat(reportedErrors, "; "))
        assert.is_true(addonTable.Timers:GetActiveCount() > 0)
    end)

    it("releases everything it owns on shutdown", function()
        loadEmbeddedPackages()
        local addonTable = loadExampleAddon()

        loadedAddons[ADDON_NAME] = true
        fireEvent("ADDON_LOADED", nil, ADDON_NAME)
        loggedIn = true
        fireEvent("PLAYER_LOGIN", nil)
        fireEvent("PLAYER_LOGOUT", nil)

        assert.are.equal("shutdown", addonTable.Lifecycle:GetState())
        assert.is_false(addonTable.Greeter:IsEnabled())
        assert.is_true(addonTable.Timers:IsClosed())
        assert.are.equal(0, addonTable.Timers:GetActiveCount())
        assert.are.equal(0, #reportedErrors, table.concat(reportedErrors, "; "))
    end)
end)
