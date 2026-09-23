local TestEnv = require("ModuleKitTestEnv")

---A two-module container where `Consumer` depends on `Database`, and
---`Database` fails to enable until `repair()` is called.
---@param ModuleKit ModuleKit
---@return ModuleKit.Addon addon
---@return ModuleKit.Module database
---@return ModuleKit.Module consumer
---@return fun() repair
local function newFailingDependencyFixture(ModuleKit)
    local addon = ModuleKit:ForAddon("MyAddon")
    local database = addon:CreateModule("Database")
    local consumer = addon:CreateModule("Consumer")
    consumer:DependsOn("Database")

    local broken = true
    database.OnEnable = function()
        if broken then
            error("database offline")
        end
    end

    return addon, database, consumer, function()
        broken = false
    end
end

describe("ModuleKit intent versus fact", function()
    local ModuleKit

    before_each(function()
        ModuleKit = TestEnv.NewPackage()
    end)

    after_each(TestEnv.Reset)

    it("starts every module wanted, not enabled and unblocked", function()
        local module = ModuleKit:ForAddon("MyAddon"):CreateModule("UI")

        assert.are.same({ wanted = true, actual = false }, module:GetEnableState())
    end)

    it("keeps a module blocked by a failed dependency wanted", function()
        local addon, _, consumer = newFailingDependencyFixture(ModuleKit)

        assert.has_error(function()
            addon:EnableAll()
        end)

        assert.are.same(
            { wanted = true, actual = false, blockedBy = "Database" },
            consumer:GetEnableState()
        )
    end)

    it("enables a blocked module when its dependency's own Enable succeeds", function()
        local addon, database, consumer, repair = newFailingDependencyFixture(ModuleKit)
        local consumerEnables = 0
        consumer.OnEnable = function()
            consumerEnables = consumerEnables + 1
        end
        assert.has_error(function()
            addon:EnableAll()
        end)

        repair()
        database:Enable()

        assert.are.equal("enabled", consumer:GetState())
        assert.are.equal(1, consumerEnables)
        assert.are.same({ wanted = true, actual = true }, consumer:GetEnableState())
    end)

    it("enables a blocked module when EnableAll runs again", function()
        local addon, _, consumer, repair = newFailingDependencyFixture(ModuleKit)
        assert.has_error(function()
            addon:EnableAll()
        end)

        repair()
        addon:EnableAll()

        assert.are.same({ wanted = true, actual = true }, consumer:GetEnableState())
    end)

    it("recovers a whole chain blocked through a targeted Enable", function()
        local addon, database, consumer, repair = newFailingDependencyFixture(ModuleKit)
        local report = addon:CreateModule("Report")
        report:DependsOn("Consumer")

        assert.has_error(function()
            report:Enable()
        end)
        assert.are.equal("Consumer", report:GetEnableState().blockedBy)
        assert.are.equal("Database", consumer:GetEnableState().blockedBy)

        repair()
        database:Enable()

        assert.is_true(consumer:IsEnabled())
        assert.is_true(report:IsEnabled())
    end)

    it("recovers a module the strict policy refused", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        addon:SetDependencyPolicy("strict")
        local database = addon:CreateModule("Database")
        local consumer = addon:CreateModule("Consumer")
        consumer:DependsOn("Database")
        database:Initialize()
        consumer:Initialize()

        assert.has_error(function()
            consumer:Enable()
        end)
        assert.are.equal("Database", consumer:GetEnableState().blockedBy)

        database:Enable()

        assert.is_true(consumer:IsEnabled())
    end)

    it("lets an explicit Disable win over recovery", function()
        local addon, database, consumer, repair = newFailingDependencyFixture(ModuleKit)
        assert.has_error(function()
            addon:EnableAll()
        end)

        consumer:Disable()
        repair()
        database:Enable()

        -- Blocked before it could initialize, and never attempted since.
        assert.are.equal("created", consumer:GetState())
        assert.are.same({ wanted = false, actual = false }, consumer:GetEnableState())
    end)

    it(
        "brings back dependents a cascaded Disable took down when the dependency is enabled",
        function()
            local addon = ModuleKit:ForAddon("MyAddon")
            local database = addon:CreateModule("Database")
            local consumer = addon:CreateModule("Consumer")
            local report = addon:CreateModule("Report")
            consumer:DependsOn("Database")
            report:DependsOn("Consumer")
            report:Enable()

            database:Disable()

            assert.are.same(
                { wanted = true, actual = false, blockedBy = "Database" },
                consumer:GetEnableState()
            )
            assert.are.same(
                { wanted = true, actual = false, blockedBy = "Consumer" },
                report:GetEnableState()
            )

            database:Enable()

            assert.are.same({ wanted = true, actual = true }, consumer:GetEnableState())
            assert.are.same({ wanted = true, actual = true }, report:GetEnableState())
        end
    )

    it("brings back cascaded dependents on EnableAll", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local database = addon:CreateModule("Database")
        local consumer = addon:CreateModule("Consumer")
        consumer:DependsOn("Database")
        addon:EnableAll()

        database:Disable()
        addon:EnableAll()

        assert.is_true(consumer:IsEnabled())
    end)

    it("keeps a directly disabled dependent off when its dependency is enabled again", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local database = addon:CreateModule("Database")
        local consumer = addon:CreateModule("Consumer")
        consumer:DependsOn("Database")
        consumer:Enable()

        consumer:Disable()
        database:Disable()
        database:Enable()

        assert.are.same({ wanted = false, actual = false }, consumer:GetEnableState())
    end)

    it("records DisableAll as intent", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local module = addon:CreateModule("UI")
        addon:EnableAll()

        addon:DisableAll()

        assert.are.same({ wanted = false, actual = false }, module:GetEnableState())
    end)

    it("leaves the dependency enabled when a recovered dependent fails", function()
        local addon, database, consumer, repair = newFailingDependencyFixture(ModuleKit)
        consumer.OnEnable = function()
            error("consumer still broken", 0)
        end
        assert.has_error(function()
            addon:EnableAll()
        end)

        repair()
        assert.has_error(function()
            database:Enable()
        end, "consumer still broken")

        assert.is_true(database:IsEnabled())
        assert.are.same({ wanted = true, actual = false }, consumer:GetEnableState())
    end)

    it("preserves intent and blocking across an in-place upgrade", function()
        local addon, database, consumer, repair = newFailingDependencyFixture(ModuleKit)
        local optional = addon:CreateModule("Optional")
        assert.has_error(function()
            addon:EnableAll()
        end)
        optional:Disable()

        rawset(rawget(ModuleKit, "_state"), "runtimeRevision", ModuleKit.REVISION - 1)
        local upgraded = TestEnv.ReloadPackage()

        assert.are.equal(ModuleKit, upgraded)
        assert.are.same(
            { wanted = true, actual = false, blockedBy = "Database" },
            consumer:GetEnableState()
        )
        assert.are.same({ wanted = false, actual = false }, optional:GetEnableState())

        repair()
        database:Enable()
        assert.is_true(consumer:IsEnabled())
    end)

    it("derives intent for modules an earlier revision created", function()
        local addon = ModuleKit:ForAddon("MyAddon")
        local kept = addon:CreateModule("Kept")
        local dropped = addon:CreateModule("Dropped")
        kept:Enable()
        dropped:Enable()
        dropped:Disable()
        for _, module in ipairs({ kept, dropped }) do
            for _, field in ipairs({
                "_wantedEnabled",
                "_enableBlockedBy",
                "_scopeOpen",
                "_scope",
                "scope",
            }) do
                rawset(module, field, nil)
            end
        end

        rawset(rawget(ModuleKit, "_state"), "runtimeRevision", ModuleKit.REVISION - 1)
        TestEnv.ReloadPackage()

        assert.are.same({ wanted = true, actual = true }, kept:GetEnableState())
        assert.are.same({ wanted = false, actual = false }, dropped:GetEnableState())
        assert.is_table(kept.scope)
        assert.is_nil(kept.scope.Timers)
    end)
end)
