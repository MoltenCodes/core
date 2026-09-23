local TestEnv = require("CommKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src
local PREFIX = "CKLimit"

---Run `action` and assert it failed with `message` reported at the line of
---this spec file that called into CommKit. `action` receives a `mark`
---function; calling `mark()` records the line after it.
---@param message string
---@param action fun(mark: fun())
local function assertReportedAtCaller(message, action)
    local expectedLine = nil
    local function mark()
        expectedLine = debug.getinfo(2, "l").currentline + 1
    end
    local ok, value = pcall(action, mark)
    assert.is_false(ok)
    assert.are.equal(SOURCE .. ":" .. tostring(expectedLine) .. ": " .. message, value)
end

---A restarted first chunk on the ordinary channel: every second one from the
---same sender is dropped as `restarted`, which is what the drop reports count.
---@return string
local function firstChunk()
    return string.char(0x02, 0x81, 0x80, 0x83) .. TestEnv.Text(251)
end

local function noop() end

describe("CommKit limits", function()
    local CommKit
    before_each(function()
        CommKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("publishes one UNBOUNDED sentinel table", function()
        assert.are.equal("table", type(CommKit.UNBOUNDED))
        assert.are.equal(CommKit.UNBOUNDED, TestEnv.ReloadPackage().UNBOUNDED)
    end)

    it("defaults a scope to 32 registrations and reports it", function()
        local scope = CommKit:CreateScope()
        assert.are.equal(32, scope:GetMaxRegistrations())
        assert.are.equal(32, CommKit:ForAddon("MyAddon"):GetMaxRegistrations())
    end)

    it("honours maxRegistrations on CreateScope and ForAddon", function()
        local scope = CommKit:CreateScope({ maxRegistrations = 2 })
        assert.is_truthy(scope:Register("A", noop))
        assert.is_truthy(scope:Register("B", noop))
        assert.are.same({ nil, "full" }, { scope:Register("C", noop) })

        local addon = CommKit:ForAddon("MyAddon", { maxRegistrations = 40 })
        for index = 1, 40 do
            assert.is_truthy(addon:Register("P" .. index, noop))
        end
        assert.are.same({ nil, "full" }, { addon:Register("P41", noop) })
        assert.are.equal(addon, CommKit:ForAddon("MyAddon"))
        assert.are.equal(addon, CommKit:ForAddon("MyAddon", { maxRegistrations = 40 }))
    end)

    it("holds any number of registrations in a scope opened with UNBOUNDED", function()
        local scope = CommKit:CreateScope({ maxRegistrations = CommKit.UNBOUNDED })
        assert.are.equal(CommKit.UNBOUNDED, scope:GetMaxRegistrations())
        for index = 1, 100 do
            assert.is_truthy(scope:Register("P" .. index, noop))
        end
        assert.are.equal(100, scope:GetRegistrationCount())
    end)

    it("refuses an invalid maxRegistrations at the caller's line", function()
        for _, invalid in ipairs({ 0, -1, 1.5, 0 / 0, math.huge, "8", {} }) do
            assertReportedAtCaller(
                "CommKit:CreateScope options.maxRegistrations must be a positive integer or CommKit.UNBOUNDED",
                function(mark)
                    mark()
                    CommKit:CreateScope({ maxRegistrations = invalid })
                end
            )
        end
        assertReportedAtCaller(
            'CommKit:CreateScope options contains unknown field "maxEntries"',
            function(mark)
                mark()
                CommKit:CreateScope({ maxEntries = 1 })
            end
        )
        assertReportedAtCaller("CommKit:ForAddon options must be a table or nil", function(mark)
            mark()
            CommKit:ForAddon("MyAddon", 5)
        end)
        CommKit:ForAddon("MyAddon")
        assertReportedAtCaller(
            "CommKit:ForAddon options.maxRegistrations differs from the existing scope's (32)",
            function(mark)
                mark()
                CommKit:ForAddon("MyAddon", { maxRegistrations = CommKit.UNBOUNDED })
            end
        )
    end)

    it("defaults a SyncSet to 16 listeners and honours maxListeners", function()
        local scope = CommKit:CreateScope()
        local few = assert(scope:SyncSet("CKFew", { fields = { "a" }, maxListeners = 1 }))
        assert.is_truthy(few:OnChanged(noop))
        assert.are.same({ nil, "full" }, { few:OnChanged(noop) })

        local many =
            assert(scope:SyncSet("CKMany", { fields = { "a" }, maxListeners = CommKit.UNBOUNDED }))
        for _ = 1, 40 do
            assert.is_truthy(many:OnChanged(noop))
        end

        assertReportedAtCaller(
            "CommKit.Scope:SyncSet options.maxListeners must be a positive integer or CommKit.UNBOUNDED",
            function(mark)
                mark()
                scope:SyncSet("CKBad", { fields = { "a" }, maxListeners = 0 })
            end
        )
    end)

    it("reports the new package-wide limits and honours SetLimits", function()
        local limits = CommKit:GetLimits()
        assert.are.equal(64, limits.maxDropReportSenders)
        assert.are.equal(64, limits.maxSyncPeers)
        assert.are.equal(8192, limits.maxSyncReplyBytes)

        CommKit:SetLimits({ maxDropReportSenders = 2, maxSyncPeers = 3, maxSyncReplyBytes = 100 })
        limits = CommKit:GetLimits()
        assert.are.equal(2, limits.maxDropReportSenders)
        assert.are.equal(3, limits.maxSyncPeers)
        assert.are.equal(100, limits.maxSyncReplyBytes)
    end)

    it("tracks at most maxDropReportSenders senders in the drop reports", function()
        local scope = CommKit:CreateScope()
        scope:Register(PREFIX, noop)
        TestEnv.TakeReportedErrors()
        CommKit:SetLimits({ maxDropReportSenders = 1 })
        for _, sender in ipairs({ "A-Realm", "B-Realm", "C-Realm" }) do
            TestEnv.Deliver(PREFIX, firstChunk(), "PARTY", sender)
            TestEnv.Deliver(PREFIX, firstChunk(), "PARTY", sender)
        end
        assert.are.same({
            { value = "CommKit dropped 1 incomplete message from A-Realm: 1 restarted" },
            { value = "CommKit dropped 1 incomplete message from (other senders): 1 restarted" },
        }, TestEnv.TakeReportedErrors())
        assert.are.equal(2, CommKit._state.dropReports.count)
    end)

    it("caches at most maxSyncPeers peers, shrinking to a lowered bound", function()
        local loaded
        CommKit, loaded = TestEnv.Load()
        local CodecKit = loaded.CodecKit
        local sync = assert(CommKit:CreateScope():SyncSet("CKSync", { fields = { "level" } }))
        local function deliver(sender, level)
            local ok, text = CodecKit:Encode({ 3, { level = level }, {} }, { channel = "addon" })
            assert.is_true(ok)
            TestEnv.Deliver("CKSync", "\001" .. text, "WHISPER", sender)
        end
        for index = 1, 10 do
            deliver("Peer" .. index, index)
        end
        assert.are.equal(10, sync._peerCount)

        CommKit:SetLimits({ maxSyncPeers = 3 })
        deliver("Peer11", 11)
        assert.are.equal(3, sync._peerCount)
        assert.are.equal(11, sync:GetRemote("Peer11", "level"))
        assert.are.equal(10, sync:GetRemote("Peer10", "level"))
        assert.is_nil(sync:GetRemote("Peer1", "level"))
    end)

    it("drops SyncSet replies past maxSyncReplyBytes", function()
        local loaded
        CommKit, loaded = TestEnv.Load()
        local CodecKit = loaded.CodecKit
        local sync = assert(CommKit:CreateScope():SyncSet("CKSync", { fields = { "blob" } }))
        CommKit:SetLimits({ burst = 255, maxCps = 1, maxSyncReplyBytes = 100 })
        sync:Set("blob", TestEnv.Text(200))
        local ok, text = CodecKit:Encode({ 1, {} }, { channel = "addon" })
        assert.is_true(ok)
        TestEnv.Deliver("CKSync", "\001" .. text, "WHISPER", "Peer-Realm")
        assert.are.equal(1, CommKit:GetStatistics().syncReplyDropped)
    end)

    it("refuses UNBOUNDED for every package-wide limit at the caller's line", function()
        local reasons = {
            maxQueuedBytes = "every addon in the session shares the queue and the chunk header numbers at most 5624 chunks",
            maxQueuedMessages = "every addon in the session shares the queue",
            maxReassemblyStreams = "other players' messages grow it",
            maxReassemblyBytesPerSender = "other players' messages grow it",
            maxInFlightPerSender = "other players' messages grow it and stream ids must stay below the radix",
            reassemblyTimeout = "other players' messages grow it",
            maxCps = "it is a rate, not a retention bound",
            burst = "it is a rate, not a retention bound",
            messageOverhead = "it is a rate, not a retention bound",
            maxDropReportSenders = "other players' messages grow it",
            maxSyncPeers = "other players' messages grow it",
            maxSyncReplyBytes = "other players' messages grow it",
        }
        local before = CommKit:GetLimits()
        for name, reason in pairs(reasons) do
            assertReportedAtCaller(
                "CommKit:SetLimits limits."
                    .. name
                    .. " does not accept CommKit.UNBOUNDED: "
                    .. reason,
                function(mark)
                    mark()
                    CommKit:SetLimits({ [name] = CommKit.UNBOUNDED })
                end
            )
        end
        assert.are.same(before, CommKit:GetLimits())
        -- Every limit GetLimits reports is covered above.
        for name in pairs(before) do
            assert.is_string(reasons[name])
        end
    end)

    it("refuses out-of-range new limits at the caller's line", function()
        assertReportedAtCaller(
            "CommKit:SetLimits limits.maxDropReportSenders must be an integer from 1 to 1024",
            function(mark)
                mark()
                CommKit:SetLimits({ maxDropReportSenders = 0 })
            end
        )
        assertReportedAtCaller(
            "CommKit:SetLimits limits.maxSyncPeers must be an integer from 1 to 1024",
            function(mark)
                mark()
                CommKit:SetLimits({ maxSyncPeers = 1025 })
            end
        )
        assertReportedAtCaller(
            "CommKit:SetLimits limits.maxSyncReplyBytes must be an integer from 1 to 1048576",
            function(mark)
                mark()
                CommKit:SetLimits({ maxSyncReplyBytes = 1.5 })
            end
        )
    end)

    it("keeps set limits, scope bounds and the sentinel across an in-place upgrade", function()
        local sentinel = CommKit.UNBOUNDED
        CommKit:SetLimits({ maxSyncPeers = 5, maxDropReportSenders = 7, maxQueuedMessages = 9 })
        local scope = CommKit:CreateScope({ maxRegistrations = sentinel })
        local bounded = CommKit:ForAddon("MyAddon", { maxRegistrations = 3 })

        local nextRevision = CommKit.REVISION + 1
        local upgraded = TestEnv.LoadRevision(nextRevision)
        assert.are.equal(nextRevision, upgraded.REVISION)
        assert.are.equal(sentinel, upgraded.UNBOUNDED)
        assert.are.equal(sentinel, upgraded._state.unbounded)
        local limits = upgraded:GetLimits()
        assert.are.equal(5, limits.maxSyncPeers)
        assert.are.equal(7, limits.maxDropReportSenders)
        assert.are.equal(9, limits.maxQueuedMessages)

        assert.are.equal(sentinel, scope:GetMaxRegistrations())
        for index = 1, 40 do
            assert.is_truthy(scope:Register("P" .. index, noop))
        end
        assert.are.equal(3, bounded:GetMaxRegistrations())
        assert.are.equal(bounded, upgraded:ForAddon("MyAddon", { maxRegistrations = 3 }))
    end)
end)
