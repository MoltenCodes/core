-- Executable documentation for examples/.
--
-- The example addon in this directory is the copy-pasteable answer to "how do I
-- embed the framework". A broken example is worse than no example, so this spec
-- loads the real files: it reads the load order out of `embeds.xml`, loads each
-- listed package from its package source, then runs `Core.lua` exactly the way
-- the World of Warcraft client would — with the addon name and the addon's
-- private table as the file's `...` vararg.
--
-- The World of Warcraft API comes from the shared `FrameworkTestEnv` fixture,
-- the same one the package suites use, so the host the example is proved
-- against cannot drift from the host the framework is tested against. What
-- stays here is what only this spec needs: the `print` capture the example
-- greets through, and the file loading that is the point of the exercise.

local FrameworkTestEnv = require("FrameworkTestEnv")

local EXAMPLES_DIRECTORY = "examples"
local ADDON_NAME = "ExampleAddon"

-- The example loads its packages with `loadfile` rather than `require`, because
-- that is what a World of Warcraft `.toc` does, so this environment carries no
-- module chain.
local TestEnv = FrameworkTestEnv.New({})

local printedLines = {}
local originalPrint = nil

---Install the host stubs plus the `print` capture the example greets through.
local function installHost()
    TestEnv.Reset()
    TestEnv.InstallWowApi()

    printedLines = {}
    originalPrint = print
    -- The example addon reaches the framework through the documented global namespace, exactly as a real addon does.
    -- selene: allow(global_usage)
    rawset(_G, "print", function(...)
        local parts = {}
        for index = 1, select("#", ...) do
            parts[index] = tostring(select(index, ...))
        end
        printedLines[#printedLines + 1] = table.concat(parts, " ")
    end)
end

---Undo everything `installHost` changed, including the example's saved variable.
local function removeHost()
    if originalPrint ~= nil then
        -- The example addon reaches the framework through the documented global namespace, exactly as a real addon does.
        -- selene: allow(global_usage)
        rawset(_G, "print", originalPrint)
        originalPrint = nil
    end
    TestEnv.Reset()
    -- The example addon reaches the framework through the documented global namespace, exactly as a real addon does.
    -- selene: allow(global_usage)
    rawset(_G, "ExampleAddonDB", nil)
end

---Fire every live repeating native timer once.
local function fireTickers()
    local natives = TestEnv.NativeTimers()
    for index = 1, #natives do
        if natives[index].repeating then
            TestEnv.FireNative(index)
        end
    end
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
    before_each(installHost)
    after_each(removeHost)

    it("loads every package embeds.xml lists, in that order", function()
        loadEmbeddedPackages()

        -- The example addon reaches the framework through the documented global namespace, exactly as a real addon does.
        -- selene: allow(global_usage)
        local registry = rawget(_G, TestEnv.NAMESPACE_KEY).Registries[2]
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

        TestEnv.MarkAddonLoaded(ADDON_NAME)
        TestEnv.Emit("ADDON_LOADED", ADDON_NAME)
        assert.are.equal("loaded", addonTable.Lifecycle:GetState())
        assert.is_true(addonTable.Greeter:IsInitialized())

        TestEnv.SetLoggedIn(true)
        TestEnv.Emit("PLAYER_LOGIN")
        assert.are.equal("ready", addonTable.Lifecycle:GetState())
        assert.is_true(addonTable.Greeter:IsEnabled())

        -- The example addon reaches the framework through the documented global namespace, exactly as a real addon does.
        -- selene: allow(global_usage)
        assert.are.equal(1, rawget(_G, "ExampleAddonDB").greetings)
        local reported = reportedErrorText()
        assert.are.equal(0, #reported, table.concat(reported, "; "))
    end)

    it("delivers the events and the timer its module subscribes to", function()
        loadEmbeddedPackages()
        local addonTable = loadExampleAddon()

        TestEnv.MarkAddonLoaded(ADDON_NAME)
        TestEnv.Emit("ADDON_LOADED", ADDON_NAME)
        TestEnv.SetLoggedIn(true)
        TestEnv.Emit("PLAYER_LOGIN")

        local before = #printedLines
        TestEnv.Emit("PLAYER_ENTERING_WORLD", false, true)
        TestEnv.Emit("UNIT_HEALTH", "player")
        fireTickers()

        assert.are.equal(before + 3, #printedLines)
        local reported = reportedErrorText()
        assert.are.equal(0, #reported, table.concat(reported, "; "))
        assert.is_true(addonTable.Timers:GetActiveCount() > 0)
    end)

    it("releases everything it owns on shutdown", function()
        loadEmbeddedPackages()
        local addonTable = loadExampleAddon()

        TestEnv.MarkAddonLoaded(ADDON_NAME)
        TestEnv.Emit("ADDON_LOADED", ADDON_NAME)
        TestEnv.SetLoggedIn(true)
        TestEnv.Emit("PLAYER_LOGIN")
        TestEnv.Emit("PLAYER_LOGOUT")

        assert.are.equal("shutdown", addonTable.Lifecycle:GetState())
        assert.is_false(addonTable.Greeter:IsEnabled())
        assert.is_true(addonTable.Timers:IsClosed())
        assert.are.equal(0, addonTable.Timers:GetActiveCount())
        local reported = reportedErrorText()
        assert.are.equal(0, #reported, table.concat(reported, "; "))
    end)
end)
