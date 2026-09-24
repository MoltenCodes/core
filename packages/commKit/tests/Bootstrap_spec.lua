local TestEnv = require("CommKitTestEnv")

local PREFIX = "CKTest"

describe("CommKit bootstrap", function()
    after_each(TestEnv.Reset)

    it("returns the same facade on duplicate embedded load", function()
        local CommKit = TestEnv.NewPackage()
        local scope = CommKit:CreateScope()
        local connection = scope:Register(PREFIX, function() end)
        local reloaded = TestEnv.ReloadPackage()
        assert.are.equal(CommKit, reloaded)
        assert.is_true(connection:IsConnected())
        assert.are.same({ PREFIX }, TestEnv.Chat().registerCalls)
    end)

    it("publishes through Registry with its constants", function()
        local CommKit, Registry = TestEnv.NewPackage()
        local registered, revision = Registry:Get("commKit", 1)
        assert.are.equal(CommKit, registered)
        assert.are.equal(CommKit.REVISION, revision)
        assert.are.equal(255, CommKit.MAX_MESSAGE_BYTES)
        assert.are.equal(32, CommKit.MAX_REGISTRATIONS)
        assert.are.same({ ALERT = "ALERT", NORMAL = "NORMAL", BULK = "BULK" }, CommKit.Priority)
    end)

    it("loads and sends without CodecKit, HookKit or SchemaKit", function()
        local CommKit = TestEnv.Load({ codecKit = false })
        local handle = CommKit:CreateScope()
            :Send({ prefix = PREFIX, text = "x", distribution = "PARTY" })
        TestEnv.Advance(0)
        assert.are.equal("sent", handle:GetState())
    end)

    it("delivers through securecallfunction when the client has it", function()
        local CommKit = TestEnv.Load({ secureCall = true })
        TestEnv.TakeReportedErrors()
        CommKit:CreateScope():Register(PREFIX, function()
            error("isolated", 0)
        end)
        TestEnv.Deliver(PREFIX, "\001x", "PARTY", "Friend-Realm")
        assert.are.same({ { value = "isolated" } }, TestEnv.TakeReportedErrors())
    end)

    it("does not reinterpret private state owned by a newer compatible revision", function()
        local CommKit, Registry = TestEnv.NewPackage()
        local shipped = CommKit.REVISION
        local upgraded, previous = Registry:Register("commKit", 1, 99)
        assert.are.equal(CommKit, upgraded)
        assert.are.equal(shipped, previous)

        rawset(CommKit, "REVISION", 99)
        rawset(CommKit, "_state", { schema = 999 })
        package.loaded["CommKit"] = nil
        local reloaded = require("CommKit")
        assert.are.equal(CommKit, reloaded)
        assert.are.equal(99, reloaded.REVISION)
    end)

    it("upgrades in place with sends, streams, registrations and SyncSets alive", function()
        local CommKit = TestEnv.NewPackage()
        local prototypes =
            { CommKit.Scope, CommKit.SendHandle, CommKit.Connection, CommKit.SyncSet }
        CommKit:SetLimits({ burst = 400, maxCps = 100 })
        local scope = CommKit:ForAddon("MyAddon")
        local received = {}
        scope:Register(PREFIX, function(_, text)
            received[#received + 1] = text
        end)
        local sync = assert(scope:SyncSet("CKSync", { fields = { "name" } }))
        sync:Set("name", "Bob")
        local text = TestEnv.Text(700)
        local handle = scope:Send({ prefix = PREFIX, text = text, distribution = "PARTY" })
        TestEnv.Advance(0)
        assert.are.equal("sending", handle:GetState())
        TestEnv.Loopback("Friend-Realm")

        local nextRevision = CommKit.REVISION + 1
        local upgraded = TestEnv.LoadRevision(nextRevision)
        assert.are.equal(CommKit, upgraded)
        assert.are.equal(nextRevision, upgraded.REVISION)
        assert.are.same(
            prototypes,
            { upgraded.Scope, upgraded.SendHandle, upgraded.Connection, upgraded.SyncSet }
        )
        assert.are.equal(scope, upgraded:ForAddon("MyAddon"))
        assert.are.equal(400, upgraded:GetLimits().burst)

        TestEnv.Advance(10)
        assert.are.equal("sent", handle:GetState())
        TestEnv.Loopback("Friend-Realm")
        assert.are.same({ text }, received)
        assert.are.equal("Bob", sync:Get("name"))
        assert.is_true(upgraded:CloseAddonScopes("MyAddon"))
        assert.is_true(sync:IsClosed())
    end)

    it("upgrades a revision 2 copy in place with a send in flight", function()
        local older = TestEnv.Load({ commKitRevision = 2 })
        assert.are.equal(2, older.REVISION)
        older:SetLimits({ burst = 400, maxCps = 100 })
        local scope = older:ForAddon("MyAddon")
        local received = {}
        scope:Register(PREFIX, function(_, text)
            received[#received + 1] = text
        end)
        local text = TestEnv.Text(700)
        local handle = scope:Send({ prefix = PREFIX, text = text, distribution = "PARTY" })
        TestEnv.Advance(0)
        assert.are.equal("sending", handle:GetState())
        TestEnv.Loopback("Friend-Realm")

        package.loaded["CommKit"] = nil
        local CommKit = require("CommKit")
        assert.are.equal(older, CommKit)
        assert.is_true(CommKit.REVISION > 2)
        assert.are.equal(scope, CommKit:ForAddon("MyAddon"))
        assert.are.equal("playerLogout", rawget(scope, "_logoutCloser"))
        assert.are.equal(400, CommKit:GetLimits().burst)

        TestEnv.Advance(10)
        assert.are.equal("sent", handle:GetState())
        TestEnv.Loopback("Friend-Realm")
        assert.are.same({ text }, received)

        -- The inherited facade now refuses a secret before comparing it.
        -- selene: allow(global_usage)
        rawset(_G, "issecretvalue", function(value)
            return value == 7
        end)
        TestEnv.expectErrorContaining(
            "CommKit:CreateScope options.maxRegistrations must not be a secret value",
            function()
                CommKit:CreateScope({ maxRegistrations = 7 })
            end
        )
    end)

    it("requires Registry", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local ok, value = pcall(require, "CommKit")
        assert.is_false(ok)
        assert.is_truthy(tostring(value):find("Registry API 2", 1, true))
    end)

    it("names each required package that is missing", function()
        local chain = { "Registry", "SignalKit", "EventKit", "TimerKit", "SchedulerKit" }
        local expected = {
            [1] = "SignalKit API 1",
            [2] = "EventKit API 1",
            [3] = "TimerKit API 1",
            [4] = "SchedulerKit API 1",
            [5] = "PoolKit API 1",
        }
        for loadedCount, message in pairs(expected) do
            TestEnv.Reset()
            TestEnv.InstallWowApi()
            for index = 1, loadedCount do
                require(chain[index])
            end
            local ok, value = pcall(TestEnv.requireAfterFailedLoad, "CommKit")
            assert.is_false(ok)
            assert.is_truthy(tostring(value):find(message, 1, true), message)
        end
    end)

    it("refuses an incomplete facade left by an earlier failed load", function()
        local _, loaded = TestEnv.Load({ codecKit = false })
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        for _, name in ipairs({
            "Registry",
            "SignalKit",
            "EventKit",
            "TimerKit",
            "SchedulerKit",
            "PoolKit",
        }) do
            loaded[name] = require(name)
        end
        loaded.Registry:Register("commKit", 1, 1)
        local ok, value = pcall(TestEnv.requireAfterFailedLoad, "CommKit")
        assert.is_false(ok)
        assert.is_truthy(tostring(value):find("MoltenCodes CommKit", 1, true))
    end)
end)
