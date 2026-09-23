-- MoltenCodes TestKit fixture-fidelity suite
--
-- The framework's Busted specs run against a fake client, the shared fixture
-- at `tests/support/FrameworkTestEnv.lua`. A fake client is only useful while
-- it tells the truth, and only the real client can say whether it does. This
-- file registers one TestKit suite, "FixtureFidelity", that asserts a handful
-- of host facts the fixture models. The same file runs in both environments:
--
--   * in the client, listed in a development addon's `.toc` after TestKit, and
--     run with `/run MoltenCodes.Registry:Get("testKit", 1):Run("FixtureFidelity")`;
--   * under Busted, from `packages/testKit/tests/FixtureFidelity_spec.lua`,
--     which loads this file into the fixture and runs the same suite.
--
-- The two must agree. A test that passes in the client and fails against the
-- fixture is a fixture defect (or a fact the fixture does not model yet, which
-- the spec lists by name); a test that fails in the client is a wrong
-- assumption in the framework. Add a test here whenever a package starts to
-- rely on a new host fact the fixture stands in for.
--
-- The file is loaded the way the client loads every addon file: with the
-- addon's folder name as the first vararg. It must be loaded before that
-- addon's `ADDON_LOADED`, which is what listing it in the `.toc` does.

local addonName = ...
if type(addonName) ~= "string" or addonName == "" then
    error(
        "FixtureFidelity.lua must be loaded as an addon file, with the addon name as its first vararg",
        2
    )
end

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil

-- Ask for Registry by generation, as EMBEDDING.md advises, and fall back to
-- the alias: a future Registry API generation takes the alias over.
local Registry = type(generations) == "table" and rawget(generations, 2) or nil
if Registry == nil and type(namespace) == "table" then
    Registry = rawget(namespace, "Registry")
end
if type(Registry) ~= "table" or rawget(Registry, "API") ~= 2 then
    error("FixtureFidelity.lua requires Registry API 2 and TestKit API 1 to be loaded first", 2)
end
local TestKit = Registry:Get("testKit", 1)
local EventKit = Registry:Get("eventKit", 1)
if TestKit == nil or EventKit == nil then
    error("FixtureFidelity.lua requires TestKit API 1 and EventKit API 1 to be loaded first", 2)
end

---Read a host global, or `nil`.
---@param name string
---@return any
local function readHost(name)
    -- Every fact this suite checks is a World of Warcraft client global.
    -- selene: allow(global_usage)
    return rawget(_G, name)
end

--- The name of the suite this file registers.
local SUITE_NAME = "FixtureFidelity"

--- What this addon's own `ADDON_LOADED` delivered. It is recorded when it
--- arrives, because a suite that waits for the `loaded` phase starts after it.
local addonLoaded = { seen = false, eventName = false, loadedName = false, payloadCount = 0 }

local connection
connection = EventKit:Connect("ADDON_LOADED", function(eventName, loadedName, ...)
    -- The payload is an addon folder name, which the client never makes secret.
    if loadedName ~= addonName then
        return
    end
    addonLoaded.seen = true
    addonLoaded.eventName = eventName
    addonLoaded.loadedName = loadedName
    addonLoaded.payloadCount = 1 + select("#", ...)
    connection:Disconnect()
end)

local suite, reason = TestKit:Suite(SUITE_NAME, { phase = "loaded", addonName = addonName })
if suite == nil then
    error("FixtureFidelity.lua could not register its suite: " .. tostring(reason), 2)
end

suite:Test("ADDON_LOADED carries the addon folder name first", function(ctx)
    ctx:Expect(addonLoaded.seen):ToBe(true)
    ctx:Expect(addonLoaded.eventName):ToBe("ADDON_LOADED")
    ctx:Expect(addonLoaded.loadedName):ToBe(addonName)
    ctx:Expect(addonLoaded.payloadCount >= 1):ToBe(true)
end)

suite:Test("InCombatLockdown returns a boolean", function(ctx)
    local inCombatLockdown = readHost("InCombatLockdown")
    ctx:Expect(type(inCombatLockdown)):ToBe("function")
    ctx:Expect(type(inCombatLockdown())):ToBe("boolean")
end)

suite:Test("IsLoggedIn returns a boolean", function(ctx)
    local isLoggedIn = readHost("IsLoggedIn")
    ctx:Expect(type(isLoggedIn)):ToBe("function")
    ctx:Expect(type(isLoggedIn())):ToBe("boolean")
end)

suite:Test("C_Timer.After exists", function(ctx)
    local timers = readHost("C_Timer")
    ctx:Expect(type(timers)):ToBe("table")
    ctx:Expect(type(timers.After)):ToBe("function")
end)

suite:Test("C_Timer.NewTimer and C_Timer.NewTicker exist", function(ctx)
    local timers = readHost("C_Timer")
    ctx:Expect(type(timers)):ToBe("table")
    ctx:Expect(type(timers.NewTimer)):ToBe("function")
    ctx:Expect(type(timers.NewTicker)):ToBe("function")
end)

suite:Test("GetTimePreciseSec returns a number", function(ctx)
    local getTimePreciseSec = readHost("GetTimePreciseSec")
    ctx:Expect(type(getTimePreciseSec)):ToBe("function")
    ctx:Expect(type(getTimePreciseSec())):ToBe("number")
end)

suite:Test("Show and Hide fire OnShow and OnHide on a change only", function(ctx)
    -- A frame without a parent is visible whenever it is shown, so a change of its
    -- shown flag is a change of its visibility.
    local frame = readHost("CreateFrame")("Frame")
    local calls = {}
    frame:SetScript("OnShow", function()
        calls[#calls + 1] = "OnShow"
    end)
    frame:SetScript("OnHide", function()
        calls[#calls + 1] = "OnHide"
    end)
    frame:Hide()
    frame:Hide()
    frame:Show()
    frame:Show()
    frame:SetScript("OnShow", nil)
    frame:SetScript("OnHide", nil)
    ctx:Expect(calls):ToEqual({ "OnHide", "OnShow" })
end)

suite:Test("SetFocus moves the edit focus from one edit box to another", function(ctx)
    local createFrame = readHost("CreateFrame")
    local first = createFrame("EditBox")
    local second = createFrame("EditBox")
    first:SetAutoFocus(false)
    second:SetAutoFocus(false)
    first:ClearFocus()
    second:ClearFocus()

    local calls = {}
    local function record(box, name, event)
        box:SetScript(event, function()
            calls[#calls + 1] = name .. " " .. event
        end)
    end
    record(first, "first", "OnEditFocusGained")
    record(first, "first", "OnEditFocusLost")
    record(second, "second", "OnEditFocusGained")
    record(second, "second", "OnEditFocusLost")

    first:SetFocus()
    second:SetFocus()
    second:ClearFocus()
    -- A box without the focus has nothing to lose.
    second:ClearFocus()
    first:ClearFocus()

    for _, box in ipairs({ first, second }) do
        box:SetScript("OnEditFocusGained", nil)
        box:SetScript("OnEditFocusLost", nil)
        box:Hide()
    end
    ctx:Expect(calls):ToEqual({
        "first OnEditFocusGained",
        "first OnEditFocusLost",
        "second OnEditFocusGained",
        "second OnEditFocusLost",
    })
end)

suite:Test("issecurevariable reports a Blizzard global as secure", function(ctx)
    if readHost("issecurevariable") == nil then
        ctx:Log("issecurevariable is absent on this host; nothing to check")
        return
    end
    ctx:Expect(nil):ToBeSecure(nil, "CreateFrame")
end)

return suite
