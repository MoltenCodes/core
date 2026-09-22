local TestEnv = require("ModuleKitTestEnv")

-- EventKit isolates listener errors at the event-bus boundary, so an error that
-- LifecycleKit re-raises from a phase dispatch is reported through the host
-- error handler instead of escaping `Emit`.
local function expectReportedError(callback)
    callback()
    local reported = TestEnv.TakeReportedErrors()
    assert.are.equal(1, #reported)
    return reported[1].value
end

describe("ModuleKit lifecycle integration", function()
    local ModuleKit

    before_each(function()
        ModuleKit = TestEnv.NewPackage()
    end)

    after_each(TestEnv.Reset)

    it("initializes modules when the addon loads", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local module = addon:CreateModule("UI")
        local calls = 0
        module.OnInitialize = function()
            calls = calls + 1
        end

        TestEnv.LoadAddon("MyAddon")

        assert.are.equal(1, calls)
        assert.are.equal("initialized", module:GetState())
    end)

    it("enables modules when the addon becomes ready", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local module = addon:CreateModule("UI")
        local calls = {}
        module.OnInitialize = function()
            calls[#calls + 1] = "initialize"
        end
        module.OnEnable = function()
            calls[#calls + 1] = "enable"
        end

        TestEnv.LoadAddon("MyAddon")
        TestEnv.Login()

        assert.are.same({ "initialize", "enable" }, calls)
        assert.is_true(module:IsEnabled())
    end)

    it("uses reverse graph order during shutdown", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local calls = {}
        local database = addon:CreateModule("Database")
        local ui = addon:CreateModule("UI")
        ui:DependsOn("Database")
        database.OnDisable = function()
            calls[#calls + 1] = "Database"
        end
        ui.OnDisable = function()
            calls[#calls + 1] = "UI"
        end

        TestEnv.LoadAddon("MyAddon")
        TestEnv.Login()
        TestEnv.Logout()

        assert.are.same({ "UI", "Database" }, calls)
        assert.are.equal("disabled", ui:GetState())
        assert.are.equal("disabled", database:GetState())
    end)

    it("rejects new modules after shutdown", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        TestEnv.LoadAddon("MyAddon")
        TestEnv.Login()
        TestEnv.Logout()

        assert.has_error(function()
            addon:CreateModule("Late")
        end)
    end)

    it("catches up late definition-table modules", function()
        TestEnv.MarkAddonLoaded("MyAddon")
        TestEnv.SetLoggedIn(true)
        local addon = ModuleKit:ForAddon("MyAddon")
        local calls = {}

        local module = addon:CreateModule("Late", {
            onInitialize = function()
                calls[#calls + 1] = "initialize"
            end,
            onEnable = function()
                calls[#calls + 1] = "enable"
            end,
        })

        assert.are.same({ "initialize", "enable" }, calls)
        assert.is_true(module:IsEnabled())
    end)

    it("supports explicit activation for mutable late modules", function()
        TestEnv.MarkAddonLoaded("MyAddon")
        TestEnv.SetLoggedIn(true)
        local addon = ModuleKit:ForAddon("MyAddon")
        local module = addon:CreateModule("Late")
        local calls = 0
        module.OnInitialize = function()
            calls = calls + 1
        end
        module.OnEnable = function()
            calls = calls + 10
        end

        assert.are.equal(0, calls)
        module:Activate()

        assert.are.equal(11, calls)
        assert.is_true(module:IsEnabled())
    end)
    it("rejects direct initialization after shutdown", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local module = addon:CreateModule("Late")
        TestEnv.LoadAddon("MyAddon")
        TestEnv.Login()
        TestEnv.Logout()

        assert.has_error(function()
            module:Initialize()
        end)
    end)

    it("rejects provider registration after shutdown", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        TestEnv.LoadAddon("MyAddon")
        TestEnv.Login()
        TestEnv.Logout()

        assert.has_error(function()
            addon:ProvideValue("Late", {})
        end)
    end)

    it("does not let one addon enable failure starve another addon", function()
        local brokenAddon = ModuleKit:ForAddon("BrokenAddon")
        local healthyAddon = ModuleKit:ForAddon("HealthyAddon")
        local broken = brokenAddon:CreateModule("Broken")
        local healthy = healthyAddon:CreateModule("Healthy")

        broken.OnEnable = function()
            error("broken enable")
        end

        TestEnv.LoadAddon("BrokenAddon")
        TestEnv.LoadAddon("HealthyAddon")

        expectReportedError(TestEnv.Login)

        assert.is_false(broken:IsEnabled())
        assert.is_true(healthy:IsEnabled())
    end)

    it("continues shutdown cleanup after a module disable error", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local calls = {}
        local first = addon:CreateModule("First")
        local second = addon:CreateModule("Second")

        first.OnDisable = function()
            calls[#calls + 1] = "First"
        end
        second.OnDisable = function()
            calls[#calls + 1] = "Second"
            error("disable failed")
        end

        TestEnv.LoadAddon("MyAddon")
        TestEnv.Login()

        expectReportedError(TestEnv.Logout)

        assert.are.same({ "Second", "First" }, calls)
        assert.are.equal("disabled", first:GetState())
        assert.is_true(second:IsEnabled())
        assert.has_error(function()
            first:Enable()
        end)
    end)

    it(
        "performs terminal cleanup even when an inactive late definition makes the full graph invalid",
        function()
            local addon = ModuleKit:ForAddon("MyAddon")
            local healthy = addon:CreateModule("Healthy")
            local disables = 0
            healthy.OnDisable = function()
                disables = disables + 1
            end

            TestEnv.LoadAddon("MyAddon")
            TestEnv.Login()
            addon:CreateModule("Broken"):DependsOn("Missing")

            expectReportedError(TestEnv.Logout)

            assert.are.equal(1, disables)
            assert.is_false(healthy:IsEnabled())
        end
    )
end)

describe("ModuleKit re-entrant module creation", function()
    local ModuleKit

    before_each(function()
        ModuleKit = TestEnv.NewPackage()
    end)

    after_each(TestEnv.Reset)

    it("defers a module created from a hook until the bulk pass has finished", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local calls = {}
        local first = addon:CreateModule("First")
        local second = addon:CreateModule("Second")

        first.OnInitialize = function()
            calls[#calls + 1] = "First"
            addon:CreateModule("Late", {
                onInitialize = function()
                    calls[#calls + 1] = "Late"
                end,
            })
        end
        second.OnInitialize = function()
            calls[#calls + 1] = "Second"
        end

        TestEnv.LoadAddon("MyAddon")

        -- "Late" is created while the pass is still walking the graph, so it
        -- catches up after the pass instead of jumping ahead of "Second".
        assert.are.same({ "First", "Second", "Late" }, calls)
        assert.are.equal("initialized", addon:GetModule("Late"):GetState())
    end)

    it("catches several deferred modules up in creation order", function()
        -- The deferred queue is drained with a cursor rather than by shifting
        -- every remaining entry down a slot. The order it produces must not
        -- change, including for modules queued by an already-deferred module.
        local addon = ModuleKit:ForAddon("MyAddon")
        local calls = {}
        local first = addon:CreateModule("First")

        local function noteAndSpawn(name, spawns)
            return function()
                calls[#calls + 1] = name
                for index = 1, #spawns do
                    local spawned = spawns[index]
                    addon:CreateModule(spawned, {
                        onInitialize = function()
                            calls[#calls + 1] = spawned
                        end,
                    })
                end
            end
        end

        first.OnInitialize = noteAndSpawn("First", { "LateA", "LateB", "LateC" })
        addon:CreateModule("Second").OnInitialize = noteAndSpawn("Second", {})

        TestEnv.LoadAddon("MyAddon")

        assert.are.same({ "First", "Second", "LateA", "LateB", "LateC" }, calls)
        assert.are.equal("initialized", addon:GetModule("LateC"):GetState())
    end)

    it("does not activate a hook-created module in the middle of a bulk pass", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local database = addon:CreateModule("Database")
        local middle = addon:CreateModule("Middle")
        local spawner = addon:CreateModule("Spawner")
        middle:DependsOn("Database")

        local failDatabase = true
        database.OnEnable = function()
            if failDatabase then
                failDatabase = false
                error("database enable failed")
            end
        end

        local observed = {}
        spawner.OnEnable = function()
            addon:CreateModule("Late", { dependsOn = { "Middle" } })
            observed.middleEnabled = middle:IsEnabled()
            observed.lateState = addon:GetModule("Late"):GetState()
        end

        TestEnv.LoadAddon("MyAddon")
        expectReportedError(TestEnv.Login)

        -- While the pass was running, "Database" had failed and "Middle" was
        -- blocked by it. Activating the hook-created module there and then
        -- would have contradicted a decision the pass had already made.
        assert.is_false(observed.middleEnabled)
        assert.are.equal("created", observed.lateState)
    end)

    it("keeps explicit Activate immediate inside a hook", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local calls = {}
        local first = addon:CreateModule("First")

        first.OnInitialize = function()
            calls[#calls + 1] = "First"
            local late = addon:CreateModule("Late")
            late.OnInitialize = function()
                calls[#calls + 1] = "Late"
            end
            late:Activate()
        end

        TestEnv.LoadAddon("MyAddon")

        -- Activate is an explicit request, not definition-table catch-up.
        assert.are.same({ "First", "Late" }, calls)
    end)
end)

describe("ModuleKit hooks and coroutines", function()
    local ModuleKit

    before_each(function()
        ModuleKit = TestEnv.NewPackage()
    end)

    after_each(TestEnv.Reset)

    it("cannot yield out of a hook, because hooks run under pcall", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local module = addon:CreateModule("UI")
        module.OnInitialize = function()
            coroutine.yield()
        end

        local thread = coroutine.create(function()
            module:Initialize()
        end)
        local ok, message = coroutine.resume(thread)

        -- Lua 5.1 cannot suspend a coroutine across a C function, and pcall is
        -- one. The attempt surfaces as an ordinary hook failure.
        assert.is_false(ok)
        assert.is_not_nil(string.find(tostring(message), "yield across", 1, true))
        assert.are.equal("created", module:GetState())
        assert.is_true(module:HasLastError())
    end)
end)
