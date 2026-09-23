-- Runs `packages/testKit/fidelity/FixtureFidelity.lua`, the suite a developer
-- runs inside the client, against the shared fixture. The two environments
-- must agree: every fidelity test that passes in the client has to pass here
-- too, except the facts the fixture does not model yet, listed below by name.
-- The list is a ratchet: when the fixture learns one of them, its test starts
-- passing here and this spec fails until the entry is removed.
local TestEnv = require("TestKitTestEnv")

local FIDELITY_FILE = "packages/testKit/fidelity/FixtureFidelity.lua"
local ADDON_NAME = "FidelityAddon"

--- Host facts the real client has and the shared fixture does not model yet.
local KNOWN_FIXTURE_GAPS = {
    ["InCombatLockdown returns a boolean"] = "only LifecycleKitTestEnv stubs InCombatLockdown; AddonStub does not",
    ["C_Timer.After exists"] = "TimerStub models C_Timer.NewTimer and C_Timer.NewTicker only",
}

---Load the fidelity file the way the client loads an addon file: during the
---addon's load, with its folder name as the first vararg, before its
---`ADDON_LOADED`.
---@return table TestKit
---@return table suite what the file returned
local function loadFidelitySuite()
    local TestKit = TestEnv.NewPackage()
    local chunk = assert(loadfile(FIDELITY_FILE))
    local suite = chunk(ADDON_NAME)
    TestEnv.LoadAddon(ADDON_NAME)
    return TestKit, suite
end

describe("the fixture-fidelity suite against the shared fixture", function()
    after_each(TestEnv.Reset)

    it("agrees with the client on every fact except the listed gaps", function()
        local TestKit, suite = loadFidelitySuite()
        assert.are.equal("FixtureFidelity", suite:GetName())

        local report = TestEnv.RunToEnd(TestKit, "FixtureFidelity")
        assert.is_not_nil(report)
        local tests = report.suites[1].tests
        assert.are.equal(9, #tests)

        local seenGaps = {}
        for index = 1, #tests do
            local result = tests[index]
            if KNOWN_FIXTURE_GAPS[result.name] ~= nil then
                seenGaps[result.name] = true
                assert.are.equal(
                    "failed",
                    result.status,
                    result.name .. " now passes: remove it from the gaps"
                )
            else
                assert.are.equal(
                    "passed",
                    result.status,
                    result.name .. ": " .. tostring(result.message)
                )
            end
        end
        for name in pairs(KNOWN_FIXTURE_GAPS) do
            assert.is_true(seenGaps[name] == true, "no fidelity test is named " .. name)
        end
    end)

    it("records the fixture's ADDON_LOADED payload as the client delivers it", function()
        local TestKit = loadFidelitySuite()
        local report = TestEnv.RunToEnd(
            TestKit,
            "FixtureFidelity/ADDON_LOADED carries the addon folder name first"
        )
        assert.are.equal("passed", report.suites[1].tests[1].status)
    end)

    it(
        "says so when the host has no issecurevariable, and asserts it when the host has one",
        function()
            local TestKit = loadFidelitySuite()
            local name = "issecurevariable reports a Blizzard global as secure"
            local report = TestEnv.RunToEnd(TestKit, "FixtureFidelity/" .. name)
            local result = TestEnv.FindResult(report, "FixtureFidelity", name)
            assert.are.equal("passed", result.status)
            assert.are.same(
                { "issecurevariable is absent on this host; nothing to check" },
                result.logs
            )

            TestEnv.SetGlobal("issecurevariable", function(key)
                return key ~= "CreateFrame", "TaintingAddon"
            end)
            report = TestEnv.RunToEnd(TestKit, "FixtureFidelity/" .. name)
            result = TestEnv.FindResult(report, "FixtureFidelity", name)
            assert.are.equal("failed", result.status)
            assert.is_truthy(result.message:find('global "CreateFrame" to be secure', 1, true))
        end
    )

    it("refuses to load without the addon name the client passes", function()
        TestEnv.NewPackage()
        local chunk = assert(loadfile(FIDELITY_FILE))
        TestEnv.expectErrorContaining("must be loaded as an addon file", function()
            chunk()
        end)
    end)
end)
