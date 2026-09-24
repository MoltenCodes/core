-- Executable documentation for examples/.
--
-- The example addon in this directory is the copy-pasteable answer to "how do I
-- embed and use the framework". A broken example is worse than no example, so
-- this spec loads the real files: it reads the load order out of `embeds.xml`,
-- loads each listed package from its package source, then runs every addon file
-- the `.toc` lists exactly the way the World of Warcraft client would — in
-- `.toc` order, each with the addon name and the addon's private table as the
-- file's `...` vararg.
--
-- The World of Warcraft API comes from the shared `FrameworkTestEnv` fixture,
-- the same one the package suites use, with the Retail (`mainline`) client
-- profile. What stays here is the handful of host globals only this addon
-- touches and the fixture does not model — `SlashCmdList` and the chat frame
-- the commands print to, `hooksecurefunc` and the hooked `ToggleGameMenu`,
-- `GetLocale`, and a `print` capture — plus the file loading that is the point
-- of the exercise.

local FrameworkTestEnv = require("FrameworkTestEnv")

local EXAMPLES_DIRECTORY = "examples"
local ADDON_NAME = "ExampleAddon"
local SAVED_VARIABLE = "ExampleAddonDB"

--- Hearthstone, the spell the example's ReadinessKit gate waits for.
local SPELL = {
    name = "Hearthstone",
    spellID = 8690,
    iconID = 134414,
    castTime = 10000,
    minRange = 0,
    maxRange = 0,
}

-- The example loads its packages with `loadfile` rather than `require`, because
-- that is what a World of Warcraft `.toc` does, so this environment carries no
-- module chain.
local TestEnv = FrameworkTestEnv.New({ wowProfile = "mainline" })

--- Globals this spec installs beside the fixture's, removed again by `removeHost`.
local SPEC_GLOBALS = {
    "SlashCmdList",
    "DEFAULT_CHAT_FRAME",
    "hooksecurefunc",
    "ToggleGameMenu",
    "GetLocale",
    SAVED_VARIABLE,
}

local printedLines = {}
local chatLines = {}
local originalPrint = nil
local clientLocale = "enUS"

---Write a host global. The fixture stands in for the World of Warcraft client,
---whose API and saved variables only exist in the global table.
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

---Collect a vararg into one line, the way `print` and `AddMessage` show it.
---@return string
local function joinArguments(...)
    local parts = {}
    for index = 1, select("#", ...) do
        parts[index] = tostring(select(index, ...))
    end
    return table.concat(parts, " ")
end

---The client's `hooksecurefunc`, for the global form HookKit uses here: the
---global is replaced by a function that calls the original, then the hook.
---@param name string
---@param hook function
local function hookSecureFunction(name, hook)
    local original = getGlobal(name)
    setGlobal(name, function(...)
        original(...)
        hook(...)
    end)
end

---Install the host stubs, the screen and the globals only this spec needs.
---HookKit and LocaleKit read theirs when they load, so this runs first.
local function installHost()
    TestEnv.Reset()
    TestEnv.InstallWowApi()

    -- The `mainline` profile's `UIParent` is a bare probe target; WidgetKit
    -- needs a real frame to rest released widgets on.
    local uiParent = getGlobal("CreateFrame")("Frame", "UIParent")
    uiParent:SetSize(1920, 1080)

    printedLines = {}
    chatLines = {}
    clientLocale = "enUS"
    setGlobal("SlashCmdList", {})
    setGlobal("DEFAULT_CHAT_FRAME", {
        AddMessage = function(_, text)
            chatLines[#chatLines + 1] = text
        end,
    })
    setGlobal("hooksecurefunc", hookSecureFunction)
    setGlobal("ToggleGameMenu", function() end)
    setGlobal("GetLocale", function()
        return clientLocale
    end)

    originalPrint = print
    setGlobal("print", function(...)
        printedLines[#printedLines + 1] = joinArguments(...)
    end)
end

---Undo everything `installHost` changed, including every `SLASH_*` global the
---example's commands wrote and the example's saved variable.
local function removeHost()
    if originalPrint ~= nil then
        setGlobal("print", originalPrint)
        originalPrint = nil
    end
    for index = 1, #SPEC_GLOBALS do
        setGlobal(SPEC_GLOBALS[index], nil)
    end
    local slashNames = {}
    -- selene: allow(global_usage)
    for name in pairs(_G) do
        if type(name) == "string" and string.find(name, "^SLASH_") then
            slashNames[#slashNames + 1] = name
        end
    end
    for index = 1, #slashNames do
        setGlobal(slashNames[index], nil)
    end
    TestEnv.Reset()
end

---Every message the example reported through the host error handler.
---@return string[]
local function reportedErrorText()
    local values = TestEnv.ReportedErrors()
    local text = {}
    for index = 1, #values do
        text[index] = tostring(values[index])
    end
    return text
end

---Assert that nothing was reported through the host error handler.
local function assertNoReportedErrors()
    local reported = reportedErrorText()
    assert.are.equal(0, #reported, table.concat(reported, "; "))
end

---Whether any line in `lines` contains `text`.
---@param lines string[]
---@param text string
---@return boolean
local function anyLineContains(lines, text)
    for index = 1, #lines do
        if string.find(lines[index], text, 1, true) then
            return true
        end
    end
    return false
end

---Advance the clock by `milliseconds`, then fire every native timer that is
---still live once, in creation order.
---
---The timer stub records no due time, so this fires every live timer whatever
---its interval, the minute-long reminder included. Each spec that calls it
---asserts only on the output of the timer it waits for, so firing the others
---early changes nothing it checks.
---@param milliseconds number
local function advanceAndFireTimers(milliseconds)
    TestEnv.AdvanceMs(milliseconds)
    local natives = TestEnv.NativeTimers()
    for index = 1, #natives do
        TestEnv.FireNative(index)
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

---Return the scripts listed in `embeds.xml`, in load order, as paths under the
---framework directory (`registry/Registry.lua`, `apiKit/flavours/Retail.lua`).
---
---The package is the directory right after `MoltenCodes`; a Kit may embed
---further files in subdirectories of it (ApiKit's flavour files), so the path
---is kept rather than reduced to a file name.
---@return string[]
local function embeddedScriptNames()
    local names = {}
    local xml = readFile(EXAMPLES_DIRECTORY .. "/embeds.xml")
    for reference in string.gmatch(xml, '<Script%s+file="([^"]+)"') do
        local path = string.gsub(reference, "\\", "/")
        names[#names + 1] = string.match(path, "MoltenCodes/(.+)$") or path
    end
    return names
end

---Return the addon's own files the `.toc` lists after `embeds.xml`, in load
---order, with the `.toc`'s backslashes turned into path separators.
---@return string[]
local function addonFilePaths()
    local paths = {}
    local toc = readFile(EXAMPLES_DIRECTORY .. "/" .. ADDON_NAME .. ".toc")
    for line in string.gmatch(toc, "[^\r\n]+") do
        local entry = string.match(line, "^%s*([^#%s][^\r\n]-)%s*$")
        if entry ~= nil and string.find(entry, "%.lua$") then
            paths[#paths + 1] = EXAMPLES_DIRECTORY .. "/" .. string.gsub(entry, "\\", "/")
        end
    end
    return paths
end

---Map an embedded script path to its package source path.
---
---`registry/Registry.lua` lives at `packages/registry/src/Registry.lua` and
---`apiKit/flavours/Retail.lua` at `packages/apiKit/src/flavours/Retail.lua`:
---the first segment is the package, the rest is its path inside `src/`.
---@param scriptPath string for example `"signalKit/SignalKit.lua"`
---@return string path
local function packageSourcePath(scriptPath)
    local packageId, rest = string.match(scriptPath, "^([^/]+)/(.+%.lua)$")
    if packageId == nil then
        error("not a package Lua file: " .. scriptPath, 0)
    end
    return "packages/" .. packageId .. "/src/" .. rest
end

---Load and run one file, passing `...` the way the client does.
---@param path string
local function runFile(path, ...)
    local chunk, message = loadfile(path)
    if chunk == nil then
        error("could not load " .. path .. ": " .. tostring(message), 0)
    end
    chunk(...)
end

---Load every embedded package in the order `embeds.xml` lists them.
local function loadEmbeddedPackages()
    local names = embeddedScriptNames()
    assert.is_true(#names > 0, "embeds.xml lists no scripts")
    for index = 1, #names do
        runFile(packageSourcePath(names[index]))
    end
end

---Load the framework, then run the addon's files in `.toc` order, and return
---the addon's private table.
---@return table addonTable
local function loadExampleAddon()
    loadEmbeddedPackages()
    local addonTable = {}
    local paths = addonFilePaths()
    for index = 1, #paths do
        runFile(paths[index], ADDON_NAME, addonTable)
    end
    return addonTable
end

---Drive the client's load and login events for the addon.
local function logIn()
    TestEnv.MarkAddonLoaded(ADDON_NAME)
    TestEnv.Emit("ADDON_LOADED", ADDON_NAME)
    TestEnv.SetLoggedIn(true)
    TestEnv.Emit("PLAYER_LOGIN")
end

---Type a slash command the way the client dispatches it: find the key whose
---`SLASH_<key><n>` global is the typed name and call `SlashCmdList[key]`.
---@param text string for example `"/exampleaddon set greet off"`
local function runSlash(text)
    local name, rest = string.match(text, "^(/%S+)%s*(.-)$")
    local slashCommands = getGlobal("SlashCmdList")
    for key, handler in pairs(slashCommands) do
        if getGlobal("SLASH_" .. key .. "1") == name then
            handler(rest)
            return
        end
    end
    error("no slash command " .. tostring(name), 2)
end

-- Specs ---------------------------------------------------------------------

describe("ExampleAddon", function()
    before_each(installHost)
    after_each(removeHost)

    it("loads every package embeds.xml lists, in that order", function()
        loadEmbeddedPackages()

        local registry = getGlobal(TestEnv.NAMESPACE_KEY).Registries[2]
        assert.are.equal(2, registry.API)
        local names = embeddedScriptNames()
        for index = 2, #names do
            local packageId = string.match(packageSourcePath(names[index]), "^packages/([^/]+)/")
            assert.is_not_nil(registry:Get(packageId, 1), packageId)
        end
    end)

    it("reaches the ready phase, opens its database and greets", function()
        -- The release before SettingsKit saved the count at the top level.
        setGlobal(SAVED_VARIABLE, { greetings = 4 })
        local addonTable = loadExampleAddon()

        assert.are.equal("loading", addonTable.Lifecycle:GetState())
        assert.is_false(addonTable.Main:IsEnabled())

        logIn()

        assert.are.equal("ready", addonTable.Lifecycle:GetState())
        assert.is_true(addonTable.Main:IsEnabled())
        local saved = getGlobal(SAVED_VARIABLE)
        assert.is_nil(saved.greetings)
        assert.are.equal(5, saved.global.greetings)
        assert.are.equal(1, saved.version)
        assert.is_true(
            anyLineContains(printedLines, "ExampleAddon is ready on the mainline client")
        )
        assert.is_true(anyLineContains(printedLines, "secret values: yes"))
        assertNoReportedErrors()
    end)

    it("dispatches /exampleaddon through SlashCmdList into the database", function()
        loadExampleAddon()
        logIn()

        runSlash("/exampleaddon set windowScale 1.5")
        runSlash("/exampleaddon get windowScale")
        runSlash("/exampleaddon set windowScale 5")

        local profile = getGlobal(SAVED_VARIABLE).profiles.Default
        assert.are.equal(1.5, profile.windowScale)
        assert.is_true(anyLineContains(chatLines, "windowScale = 1.5"))
        assert.is_true(anyLineContains(chatLines, "expected number <= 2"))
        assertNoReportedErrors()
    end)

    it("opens the options window from its command and releases it again", function()
        local addonTable = loadExampleAddon()
        logIn()
        local WidgetKit = addonTable.Kits.WidgetKit
        local window = addonTable.Main.window

        runSlash("/exampleaddonwindow")
        local frame = window:GetFrame()
        assert.is_true(WidgetKit:IsWidget(frame))
        assert.are.equal("Frame", frame:GetType())
        assert.is_true(frame:GetNumChildren() > 0)

        -- Opening the game menu closes the window through the secure hook.
        getGlobal("ToggleGameMenu")()
        assert.is_false(window:IsShown())
        assert.is_false(WidgetKit:IsWidget(frame))

        -- Opening it again reuses the pooled frame.
        runSlash("/exampleaddonwindow")
        assert.are.equal(frame, window:GetFrame())
        runSlash("/exampleaddonwindow")
        assert.is_false(window:IsShown())
        assertNoReportedErrors()
    end)

    it("coalesces a burst of health events into one report", function()
        loadExampleAddon()
        logIn()
        runSlash("/exampleaddon set announceHealth on")

        local before = #printedLines
        TestEnv.Emit("UNIT_HEALTH", "player")
        TestEnv.Emit("UNIT_MAXHEALTH", "player")
        TestEnv.Emit("UNIT_HEALTH", "player")
        assert.are.equal(before, #printedLines)

        advanceAndFireTimers(500)

        local reports = 0
        for index = before + 1, #printedLines do
            if string.find(printedLines[index], "Health changed: player.", 1, true) then
                reports = reports + 1
            end
        end
        assert.are.equal(1, reports)
        assertNoReportedErrors()
    end)

    it("waits for spell data behind a ReadinessKit gate", function()
        local addonTable = loadExampleAddon()
        logIn()
        local gate = addonTable.Main.spellGate
        assert.is_false(gate:IsReady())

        TestEnv.AddSpell(SPELL)
        advanceAndFireTimers(1000)

        assert.is_true(gate:IsReady())
        assert.is_true(anyLineContains(printedLines, "Spell data is ready: Hearthstone."))
        assertNoReportedErrors()
    end)

    it("uses the German translation on a German client", function()
        clientLocale = "deDE"
        local addonTable = loadExampleAddon()
        logIn()

        assert.is_true(anyLineContains(printedLines, "Begrüßung Nr. 1: ExampleAddon ist bereit"))
        local L = addonTable.Kits.LocaleKit:GetLocale(ADDON_NAME)
        -- A key the German file leaves out falls back to English.
        assert.are.equal("Announce health changes", L["Announce health changes"])
        assertNoReportedErrors()
    end)

    it("releases everything it owns and compacts its database on logout", function()
        local addonTable = loadExampleAddon()
        logIn()
        runSlash("/exampleaddon set windowScale 1.5")
        runSlash("/exampleaddon set greet off")
        runSlash("/exampleaddon set greet on")
        runSlash("/exampleaddonwindow")
        local profile = getGlobal(SAVED_VARIABLE).profiles.Default
        assert.is_true(profile.greet)

        TestEnv.Emit("PLAYER_LOGOUT")

        assert.are.equal("shutdown", addonTable.Lifecycle:GetState())
        assert.is_false(addonTable.Main:IsEnabled())
        assert.is_false(addonTable.Main.window:IsShown())
        assert.is_nil(addonTable.Main.spellGate)

        -- Every native timer the addon armed is cancelled: the module scope's
        -- reminder, the coalescing interval and the gate's poll.
        local natives = TestEnv.NativeTimers()
        for index = 1, #natives do
            assert.is_true(natives[index].cancelled or natives[index].fired, "timer " .. index)
        end

        -- The commands are inert: typing one does nothing.
        local before = #chatLines
        runSlash("/exampleaddon get windowScale")
        assert.are.equal(before, #chatLines)

        -- Compaction keeps what differs from the defaults and drops the rest.
        assert.are.equal(1.5, profile.windowScale)
        assert.is_nil(profile.greet)
        assertNoReportedErrors()
    end)
end)
